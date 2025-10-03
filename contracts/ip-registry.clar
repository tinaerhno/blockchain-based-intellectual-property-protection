;; IP Registry Contract
;; Smart contract to register creative works and assign ownership
;; Provides immutable proof of creation and ownership management

;; ============================================
;; CONSTANTS
;; ============================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_WORK_NOT_FOUND (err u101))
(define-constant ERR_WORK_ALREADY_EXISTS (err u102))
(define-constant ERR_INVALID_WORK_ID (err u103))
(define-constant ERR_INVALID_TITLE (err u104))
(define-constant ERR_INVALID_CATEGORY (err u105))
(define-constant ERR_TRANSFER_FAILED (err u106))
(define-constant ERR_ALREADY_OWNER (err u107))

;; Maximum lengths for strings
(define-constant MAX_TITLE_LENGTH u256)
(define-constant MAX_CATEGORY_LENGTH u64)
(define-constant MAX_DESCRIPTION_LENGTH u512)

;; ============================================
;; DATA MAPS AND VARIABLES
;; ============================================

;; Counter for work IDs
(define-data-var work-counter uint u0)

;; Map to store registered works
;; work-id => work details
(define-map works
  { work-id: uint }
  {
    title: (string-ascii 256),
    creator: principal,
    current-owner: principal,
    category: (string-ascii 64),
    description: (string-ascii 512),
    creation-timestamp: uint,
    registration-timestamp: uint,
    metadata-hash: (buff 32),
    is-active: bool
  }
)

;; Map to track works by creator
;; creator => list of work IDs
(define-map creator-works
  { creator: principal }
  { work-ids: (list 100 uint) }
)

;; Map to track works by current owner
;; owner => list of work IDs
(define-map owner-works
  { owner: principal }
  { work-ids: (list 100 uint) }
)

;; Map to prevent duplicate title registrations by the same creator
;; creator + title-hash => work-id
(define-map title-registry
  { creator: principal, title-hash: (buff 32) }
  { work-id: uint }
)

;; Map to track work transfers
;; work-id => transfer history
(define-map work-transfers
  { work-id: uint }
  { 
    transfer-count: uint,
    last-transfer-timestamp: uint,
    last-transfer-from: principal,
    last-transfer-to: principal
  }
)

;; ============================================
;; PRIVATE FUNCTIONS
;; ============================================

;; Get the next work ID
(define-private (get-next-work-id)
  (let ((current-id (var-get work-counter)))
    (var-set work-counter (+ current-id u1))
    current-id
  )
)

;; Validate title length
(define-private (is-valid-title (title (string-ascii 256)))
  (and 
    (> (len title) u0)
    (<= (len title) MAX_TITLE_LENGTH)
  )
)

;; Validate category length
(define-private (is-valid-category (category (string-ascii 64)))
  (and 
    (> (len category) u0)
    (<= (len category) MAX_CATEGORY_LENGTH)
  )
)

;; Validate description length
(define-private (is-valid-description (description (string-ascii 512)))
  (<= (len description) MAX_DESCRIPTION_LENGTH)
)

;; Add work ID to creator's list
(define-private (add-work-to-creator (creator principal) (work-id uint))
  (let (
    (current-works (default-to { work-ids: (list) } 
                     (map-get? creator-works { creator: creator })))
  )
    (map-set creator-works
      { creator: creator }
      { work-ids: (unwrap! (as-max-len? 
                    (append (get work-ids current-works) work-id) u100)
                    ERR_TRANSFER_FAILED) }
    )
    (ok true)
  )
)

;; Add work ID to owner's list
(define-private (add-work-to-owner (owner principal) (work-id uint))
  (let (
    (current-works (default-to { work-ids: (list) } 
                     (map-get? owner-works { owner: owner })))
  )
    (map-set owner-works
      { owner: owner }
      { work-ids: (unwrap! (as-max-len? 
                    (append (get work-ids current-works) work-id) u100)
                    ERR_TRANSFER_FAILED) }
    )
    (ok true)
  )
)

;; Remove work ID from owner's list (simplified version)
(define-private (remove-work-from-owner (owner principal) (work-id uint))
  (let (
    (current-works (default-to { work-ids: (list) } 
                     (map-get? owner-works { owner: owner })))
  )
    ;; For simplicity, we'll just track the addition
    ;; In a production system, you'd implement proper removal
    (ok true)
  )
)

;; ============================================
;; READ-ONLY FUNCTIONS
;; ============================================

;; Get work information by ID
(define-read-only (get-work-info (work-id uint))
  (map-get? works { work-id: work-id })
)

;; Get works created by a specific creator
(define-read-only (get-works-by-creator (creator principal))
  (map-get? creator-works { creator: creator })
)

;; Get works owned by a specific owner
(define-read-only (get-works-by-owner (owner principal))
  (map-get? owner-works { owner: owner })
)

;; Verify ownership of a work
(define-read-only (verify-ownership (work-id uint) (claimed-owner principal))
  (match (map-get? works { work-id: work-id })
    work-data (is-eq (get current-owner work-data) claimed-owner)
    false
  )
)

;; Get work transfer history
(define-read-only (get-work-transfers (work-id uint))
  (map-get? work-transfers { work-id: work-id })
)

;; Get total number of registered works
(define-read-only (get-total-works)
  (var-get work-counter)
)

;; Check if title already exists for creator
(define-read-only (title-exists-for-creator (creator principal) (title-hash (buff 32)))
  (is-some (map-get? title-registry { creator: creator, title-hash: title-hash }))
)

;; ============================================
;; PUBLIC FUNCTIONS
;; ============================================

;; Register a new creative work
(define-public (register-work 
  (title (string-ascii 256))
  (category (string-ascii 64))
  (description (string-ascii 512))
  (creation-timestamp uint)
  (metadata-hash (buff 32))
)
  (let (
    (work-id (get-next-work-id))
    (title-hash (sha256 (unwrap-panic (to-consensus-buff? title))))
    (current-block stacks-block-height)
  )
    ;; Validate inputs
    (asserts! (is-valid-title title) ERR_INVALID_TITLE)
    (asserts! (is-valid-category category) ERR_INVALID_CATEGORY)
    (asserts! (is-valid-description description) ERR_INVALID_TITLE)
    (asserts! (> creation-timestamp u0) ERR_INVALID_WORK_ID)
    
    ;; Check if title already exists for this creator
    (asserts! (not (title-exists-for-creator tx-sender title-hash)) ERR_WORK_ALREADY_EXISTS)
    
    ;; Register the work
    (map-set works
      { work-id: work-id }
      {
        title: title,
        creator: tx-sender,
        current-owner: tx-sender,
        category: category,
        description: description,
        creation-timestamp: creation-timestamp,
        registration-timestamp: current-block,
        metadata-hash: metadata-hash,
        is-active: true
      }
    )
    
    ;; Register title to prevent duplicates
    (map-set title-registry
      { creator: tx-sender, title-hash: title-hash }
      { work-id: work-id }
    )
    
    ;; Add to creator's works
    (try! (add-work-to-creator tx-sender work-id))
    
    ;; Add to owner's works
    (try! (add-work-to-owner tx-sender work-id))
    
    ;; Initialize transfer history
    (map-set work-transfers
      { work-id: work-id }
      {
        transfer-count: u0,
        last-transfer-timestamp: current-block,
        last-transfer-from: tx-sender,
        last-transfer-to: tx-sender
      }
    )
    
    (ok work-id)
  )
)

;; Transfer ownership of a work
(define-public (transfer-ownership (work-id uint) (new-owner principal))
  (let (
    (work-data (unwrap! (map-get? works { work-id: work-id }) ERR_WORK_NOT_FOUND))
    (current-block stacks-block-height)
    (current-owner (get current-owner work-data))
  )
    ;; Only current owner can transfer
    (asserts! (is-eq tx-sender current-owner) ERR_UNAUTHORIZED)
    
    ;; Cannot transfer to self
    (asserts! (not (is-eq current-owner new-owner)) ERR_ALREADY_OWNER)
    
    ;; Work must be active
    (asserts! (get is-active work-data) ERR_WORK_NOT_FOUND)
    
    ;; Update work ownership
    (map-set works
      { work-id: work-id }
      (merge work-data { current-owner: new-owner })
    )
    
    ;; Remove from current owner's list
    (unwrap-panic (remove-work-from-owner current-owner work-id))
    
    ;; Add to new owner's list
    (try! (add-work-to-owner new-owner work-id))
    
    ;; Update transfer history
    (let (
      (current-transfers (default-to 
        { transfer-count: u0, last-transfer-timestamp: u0, 
          last-transfer-from: tx-sender, last-transfer-to: tx-sender }
        (map-get? work-transfers { work-id: work-id })))
    )
      (map-set work-transfers
        { work-id: work-id }
        {
          transfer-count: (+ (get transfer-count current-transfers) u1),
          last-transfer-timestamp: current-block,
          last-transfer-from: current-owner,
          last-transfer-to: new-owner
        }
      )
    )
    
    (ok true)
  )
)

;; Deactivate a work (only by creator)
(define-public (deactivate-work (work-id uint))
  (let (
    (work-data (unwrap! (map-get? works { work-id: work-id }) ERR_WORK_NOT_FOUND))
  )
    ;; Only creator can deactivate
    (asserts! (is-eq tx-sender (get creator work-data)) ERR_UNAUTHORIZED)
    
    ;; Work must be active
    (asserts! (get is-active work-data) ERR_WORK_NOT_FOUND)
    
    ;; Deactivate the work
    (map-set works
      { work-id: work-id }
      (merge work-data { is-active: false })
    )
    
    (ok true)
  )
)

;; Reactivate a work (only by creator)
(define-public (reactivate-work (work-id uint))
  (let (
    (work-data (unwrap! (map-get? works { work-id: work-id }) ERR_WORK_NOT_FOUND))
  )
    ;; Only creator can reactivate
    (asserts! (is-eq tx-sender (get creator work-data)) ERR_UNAUTHORIZED)
    
    ;; Work must be inactive
    (asserts! (not (get is-active work-data)) ERR_WORK_ALREADY_EXISTS)
    
    ;; Reactivate the work
    (map-set works
      { work-id: work-id }
      (merge work-data { is-active: true })
    )
    
    (ok true)
  )
)
