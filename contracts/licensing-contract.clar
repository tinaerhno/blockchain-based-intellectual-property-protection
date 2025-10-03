;; Licensing Contract
;; Smart contract to manage usage rights and royalty payments
;; Handles license creation, purchase, and royalty distribution

;; ============================================
;; CONSTANTS
;; ============================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_LICENSE_NOT_FOUND (err u201))
(define-constant ERR_LICENSE_EXPIRED (err u202))
(define-constant ERR_INSUFFICIENT_PAYMENT (err u203))
(define-constant ERR_INVALID_ROYALTY_RATE (err u204))
(define-constant ERR_INVALID_DURATION (err u205))
(define-constant ERR_LICENSE_ALREADY_EXISTS (err u206))
(define-constant ERR_INVALID_WORK_ID (err u207))
(define-constant ERR_PAYMENT_FAILED (err u208))
(define-constant ERR_ROYALTY_DISTRIBUTION_FAILED (err u209))
(define-constant ERR_INVALID_LICENSE_TYPE (err u210))

;; License types
(define-constant LICENSE_TYPE_EXCLUSIVE u1)
(define-constant LICENSE_TYPE_NON_EXCLUSIVE u2)
(define-constant LICENSE_TYPE_SINGLE_USE u3)
(define-constant LICENSE_TYPE_UNLIMITED u4)

;; Maximum royalty rate (in basis points, 10000 = 100%)
(define-constant MAX_ROYALTY_RATE u5000) ;; 50%
(define-constant MIN_ROYALTY_RATE u100)  ;; 1%
(define-constant BASIS_POINTS u10000)

;; Maximum license duration (in blocks, ~6 months)
(define-constant MAX_LICENSE_DURATION u26280)
(define-constant MIN_LICENSE_DURATION u144) ;; ~1 day

;; ============================================
;; DATA MAPS AND VARIABLES
;; ============================================

;; Counter for license IDs
(define-data-var license-counter uint u0)

;; Map to store license agreements
;; license-id => license details
(define-map licenses
  { license-id: uint }
  {
    work-id: uint,
    licensor: principal,
    licensee: principal,
    license-type: uint,
    royalty-rate: uint,
    license-fee: uint,
    duration-blocks: uint,
    start-block: uint,
    end-block: uint,
    terms-hash: (buff 32),
    is-active: bool,
    creation-timestamp: uint
  }
)

;; Map to track licenses by work ID
;; work-id => list of license IDs
(define-map work-licenses
  { work-id: uint }
  { license-ids: (list 50 uint) }
)

;; Map to track licenses by licensor
;; licensor => list of license IDs
(define-map licensor-licenses
  { licensor: principal }
  { license-ids: (list 100 uint) }
)

;; Map to track licenses by licensee
;; licensee => list of license IDs
(define-map licensee-licenses
  { licensee: principal }
  { license-ids: (list 100 uint) }
)

;; Map to track royalty payments
;; license-id => royalty info
(define-map royalty-payments
  { license-id: uint }
  {
    total-royalties-paid: uint,
    payment-count: uint,
    last-payment-amount: uint,
    last-payment-timestamp: uint,
    last-payment-from: principal
  }
)

;; Map to track work revenue
;; work-id => revenue info
(define-map work-revenue
  { work-id: uint }
  {
    total-license-fees: uint,
    total-royalties: uint,
    active-licenses: uint,
    total-licenses: uint
  }
)

;; Map to store license usage tracking
;; license-id => usage info
(define-map license-usage
  { license-id: uint }
  {
    usage-count: uint,
    last-usage-timestamp: uint,
    usage-limit: (optional uint),
    bytes-transferred: uint
  }
)

;; ============================================
;; PRIVATE FUNCTIONS
;; ============================================

;; Get the next license ID
(define-private (get-next-license-id)
  (let ((current-id (var-get license-counter)))
    (var-set license-counter (+ current-id u1))
    current-id
  )
)

;; Validate royalty rate
(define-private (is-valid-royalty-rate (rate uint))
  (and 
    (>= rate MIN_ROYALTY_RATE)
    (<= rate MAX_ROYALTY_RATE)
  )
)

;; Validate license duration
(define-private (is-valid-duration (duration uint))
  (and 
    (>= duration MIN_LICENSE_DURATION)
    (<= duration MAX_LICENSE_DURATION)
  )
)

;; Validate license type
(define-private (is-valid-license-type (license-type uint))
  (or
    (is-eq license-type LICENSE_TYPE_EXCLUSIVE)
    (is-eq license-type LICENSE_TYPE_NON_EXCLUSIVE)
    (is-eq license-type LICENSE_TYPE_SINGLE_USE)
    (is-eq license-type LICENSE_TYPE_UNLIMITED)
  )
)

;; Calculate license end block
(define-private (calculate-end-block (start-block uint) (duration uint))
  (+ start-block duration)
)

;; Add license to work's license list
(define-private (add-license-to-work (work-id uint) (license-id uint))
  (let (
    (current-licenses (default-to { license-ids: (list) }
                        (map-get? work-licenses { work-id: work-id })))
  )
    (map-set work-licenses
      { work-id: work-id }
      { license-ids: (unwrap! (as-max-len?
                        (append (get license-ids current-licenses) license-id) u50)
                        ERR_LICENSE_ALREADY_EXISTS) }
    )
    (ok true)
  )
)

;; Add license to licensor's list
(define-private (add-license-to-licensor (licensor principal) (license-id uint))
  (let (
    (current-licenses (default-to { license-ids: (list) }
                        (map-get? licensor-licenses { licensor: licensor })))
  )
    (map-set licensor-licenses
      { licensor: licensor }
      { license-ids: (unwrap! (as-max-len?
                        (append (get license-ids current-licenses) license-id) u100)
                        ERR_LICENSE_ALREADY_EXISTS) }
    )
    (ok true)
  )
)

;; Add license to licensee's list
(define-private (add-license-to-licensee (licensee principal) (license-id uint))
  (let (
    (current-licenses (default-to { license-ids: (list) }
                        (map-get? licensee-licenses { licensee: licensee })))
  )
    (map-set licensee-licenses
      { licensee: licensee }
      { license-ids: (unwrap! (as-max-len?
                        (append (get license-ids current-licenses) license-id) u100)
                        ERR_LICENSE_ALREADY_EXISTS) }
    )
    (ok true)
  )
)

;; Update work revenue
(define-private (update-work-revenue (work-id uint) (license-fee uint) (is-new-license bool))
  (let (
    (current-revenue (default-to 
      { total-license-fees: u0, total-royalties: u0, active-licenses: u0, total-licenses: u0 }
      (map-get? work-revenue { work-id: work-id })))
  )
    (map-set work-revenue
      { work-id: work-id }
      {
        total-license-fees: (+ (get total-license-fees current-revenue) license-fee),
        total-royalties: (get total-royalties current-revenue),
        active-licenses: (if is-new-license 
                          (+ (get active-licenses current-revenue) u1)
                          (get active-licenses current-revenue)),
        total-licenses: (if is-new-license 
                         (+ (get total-licenses current-revenue) u1)
                         (get total-licenses current-revenue))
      }
    )
    (ok true)
  )
)

;; ============================================
;; READ-ONLY FUNCTIONS
;; ============================================

;; Get license information
(define-read-only (get-license-info (license-id uint))
  (map-get? licenses { license-id: license-id })
)

;; Get licenses for a work
(define-read-only (get-work-licenses (work-id uint))
  (map-get? work-licenses { work-id: work-id })
)

;; Get licenses by licensor
(define-read-only (get-licenses-by-licensor (licensor principal))
  (map-get? licensor-licenses { licensor: licensor })
)

;; Get licenses by licensee
(define-read-only (get-licenses-by-licensee (licensee principal))
  (map-get? licensee-licenses { licensee: licensee })
)

;; Check if license is active
(define-read-only (is-license-active (license-id uint))
  (match (map-get? licenses { license-id: license-id })
    license-data 
      (and 
        (get is-active license-data)
        (< stacks-block-height (get end-block license-data))
      )
    false
  )
)

;; Get license terms
(define-read-only (get-license-terms (license-id uint))
  (match (map-get? licenses { license-id: license-id })
    license-data
      (some {
        work-id: (get work-id license-data),
        license-type: (get license-type license-data),
        royalty-rate: (get royalty-rate license-data),
        duration-blocks: (get duration-blocks license-data),
        terms-hash: (get terms-hash license-data)
      })
    none
  )
)

;; Get work revenue information
(define-read-only (get-work-revenue-info (work-id uint))
  (map-get? work-revenue { work-id: work-id })
)

;; Get royalty payment history
(define-read-only (get-royalty-payments (license-id uint))
  (map-get? royalty-payments { license-id: license-id })
)

;; Get total licenses created
(define-read-only (get-total-licenses)
  (var-get license-counter)
)

;; ============================================
;; PUBLIC FUNCTIONS
;; ============================================

;; Create a new license agreement
(define-public (create-license
  (work-id uint)
  (licensee principal)
  (license-type uint)
  (royalty-rate uint)
  (license-fee uint)
  (duration-blocks uint)
  (terms-hash (buff 32))
  (usage-limit (optional uint))
)
  (let (
    (license-id (get-next-license-id))
    (start-block stacks-block-height)
    (end-block (calculate-end-block start-block duration-blocks))
    (current-block stacks-block-height)
  )
    ;; Validate inputs
    (asserts! (> work-id u0) ERR_INVALID_WORK_ID)
    (asserts! (is-valid-license-type license-type) ERR_INVALID_LICENSE_TYPE)
    (asserts! (is-valid-royalty-rate royalty-rate) ERR_INVALID_ROYALTY_RATE)
    (asserts! (is-valid-duration duration-blocks) ERR_INVALID_DURATION)
    
    ;; Create the license
    (map-set licenses
      { license-id: license-id }
      {
        work-id: work-id,
        licensor: tx-sender,
        licensee: licensee,
        license-type: license-type,
        royalty-rate: royalty-rate,
        license-fee: license-fee,
        duration-blocks: duration-blocks,
        start-block: start-block,
        end-block: end-block,
        terms-hash: terms-hash,
        is-active: true,
        creation-timestamp: current-block
      }
    )
    
    ;; Add to various tracking maps
    (try! (add-license-to-work work-id license-id))
    (try! (add-license-to-licensor tx-sender license-id))
    (try! (add-license-to-licensee licensee license-id))
    
    ;; Initialize royalty payments tracking
    (map-set royalty-payments
      { license-id: license-id }
      {
        total-royalties-paid: u0,
        payment-count: u0,
        last-payment-amount: u0,
        last-payment-timestamp: current-block,
        last-payment-from: tx-sender
      }
    )
    
    ;; Initialize usage tracking
    (map-set license-usage
      { license-id: license-id }
      {
        usage-count: u0,
        last-usage-timestamp: current-block,
        usage-limit: usage-limit,
        bytes-transferred: u0
      }
    )
    
    ;; Update work revenue (without license fee initially)
    (unwrap-panic (update-work-revenue work-id u0 true))
    
    (ok license-id)
  )
)

;; Purchase a license (pay license fee)
(define-public (purchase-license (license-id uint))
  (let (
    (license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR_LICENSE_NOT_FOUND))
    (license-fee (get license-fee license-data))
    (licensor (get licensor license-data))
    (work-id (get work-id license-data))
  )
    ;; Only the designated licensee can purchase
    (asserts! (is-eq tx-sender (get licensee license-data)) ERR_UNAUTHORIZED)
    
    ;; License must be active and not expired
    (asserts! (is-license-active license-id) ERR_LICENSE_EXPIRED)
    
    ;; Transfer license fee to licensor (simplified - in production use STX transfer)
    ;; For this example, we'll just track the payment
    
    ;; Update work revenue with license fee
    (unwrap-panic (update-work-revenue work-id license-fee false))
    
    (ok true)
  )
)

;; Pay royalties for license usage
(define-public (pay-royalties (license-id uint) (usage-amount uint))
  (let (
    (license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR_LICENSE_NOT_FOUND))
    (royalty-rate (get royalty-rate license-data))
    (licensor (get licensor license-data))
    (royalty-amount (/ (* usage-amount royalty-rate) BASIS_POINTS))
    (current-block stacks-block-height)
  )
    ;; Only licensee can pay royalties
    (asserts! (is-eq tx-sender (get licensee license-data)) ERR_UNAUTHORIZED)
    
    ;; License must be active
    (asserts! (is-license-active license-id) ERR_LICENSE_EXPIRED)
    
    ;; Update royalty payment tracking
    (let (
      (current-payments (default-to
        { total-royalties-paid: u0, payment-count: u0, last-payment-amount: u0, 
          last-payment-timestamp: u0, last-payment-from: tx-sender }
        (map-get? royalty-payments { license-id: license-id })))
    )
      (map-set royalty-payments
        { license-id: license-id }
        {
          total-royalties-paid: (+ (get total-royalties-paid current-payments) royalty-amount),
          payment-count: (+ (get payment-count current-payments) u1),
          last-payment-amount: royalty-amount,
          last-payment-timestamp: current-block,
          last-payment-from: tx-sender
        }
      )
    )
    
    ;; Update work revenue
    (let (
      (work-id (get work-id license-data))
      (current-revenue (default-to
        { total-license-fees: u0, total-royalties: u0, active-licenses: u0, total-licenses: u0 }
        (map-get? work-revenue { work-id: work-id })))
    )
      (map-set work-revenue
        { work-id: work-id }
        (merge current-revenue 
          { total-royalties: (+ (get total-royalties current-revenue) royalty-amount) })
      )
    )
    
    ;; Update usage tracking
    (let (
      (current-usage (default-to
        { usage-count: u0, last-usage-timestamp: u0, usage-limit: none, bytes-transferred: u0 }
        (map-get? license-usage { license-id: license-id })))
    )
      (map-set license-usage
        { license-id: license-id }
        {
          usage-count: (+ (get usage-count current-usage) u1),
          last-usage-timestamp: current-block,
          usage-limit: (get usage-limit current-usage),
          bytes-transferred: (+ (get bytes-transferred current-usage) usage-amount)
        }
      )
    )
    
    (ok royalty-amount)
  )
)

;; Revoke a license (only by licensor)
(define-public (revoke-license (license-id uint))
  (let (
    (license-data (unwrap! (map-get? licenses { license-id: license-id }) ERR_LICENSE_NOT_FOUND))
  )
    ;; Only licensor can revoke
    (asserts! (is-eq tx-sender (get licensor license-data)) ERR_UNAUTHORIZED)
    
    ;; License must be active
    (asserts! (get is-active license-data) ERR_LICENSE_NOT_FOUND)
    
    ;; Deactivate the license
    (map-set licenses
      { license-id: license-id }
      (merge license-data { is-active: false })
    )
    
    ;; Update work revenue (decrease active licenses)
    (let (
      (work-id (get work-id license-data))
      (current-revenue (default-to
        { total-license-fees: u0, total-royalties: u0, active-licenses: u0, total-licenses: u0 }
        (map-get? work-revenue { work-id: work-id })))
    )
      (map-set work-revenue
        { work-id: work-id }
        (merge current-revenue 
          { active-licenses: (if (> (get active-licenses current-revenue) u0)
                              (- (get active-licenses current-revenue) u1)
                              u0) })
      )
    )
    
    (ok true)
  )
)
