;;; whatsappel-profiles.scm --- bounded profile metadata and authorized jobs
;;; SPDX-License-Identifier: AGPL-3.0-only
;; Loaded by whatsappel.scm, sharing its authenticated single-account boundary.
;; No image bytes, availability heuristics, or outbound self-presence calls here.

(define *profile-mutex* (make-mutex))
(define *profile-store* (make-hash-table))
(define *profile-jobs* (make-hash-table))
(define *profile-subscriptions* (make-hash-table))
(define *profile-counter* 0)
(define *profile-reset-counter* 0)
(define *profile-max-entries* 128)
(define (profile-clock) (quotient (get-internal-real-time) internal-time-units-per-second))
(define (profile-epoch) (format #f "~a-~a" *read-epoch* *profile-reset-counter*))

(define (profile-jid? value)
  (and (string? value) (<= (string-length value) 80)
       (string-match "^([0-9]{3,30}(@(s[.]whatsapp[.]net|lid))?|[0-9]{3,30}(-[0-9]{1,20})?@g[.]us)$" value)))

(define (profile-unique-json? value depth)
  ;; Only used for small profile requests/events; legacy message parsing unchanged.
  (and (< depth 24)
       (cond ((json-object? value)
              (let ((keys (map car value)))
                (and (= (length keys) (length (delete-duplicates keys string=?)))
                     (every (lambda (x) (profile-unique-json? (cdr x) (1+ depth))) value))))
             ((vector? value)
              (every (lambda (x) (profile-unique-json? x (1+ depth))) (vector->list value)))
             ((number? value) (and (real? value) (= value value) (< (abs value) 1e100)))
             (else #t))))

(define (profile-prune!)
  ;; Call under profile mutex, never the message-store mutex.
  (let ((now (profile-clock)) (expired '()))
    (hash-for-each
     (lambda (key rec)
       (when (> (- now (or (assoc-ref rec "touched") 0)) 600)
         (set! expired (cons key expired)))) *profile-store*)
    (for-each (lambda (key) (hash-remove! *profile-store* key)) expired)
    (set! expired '())
    (hash-for-each
     (lambda (id job)
       (when (and (vector-ref job 0) (> (- now (vector-ref job 1)) 30))
         (set! expired (cons id expired)))) *profile-jobs*)
    (for-each (lambda (id) (hash-remove! *profile-jobs* id)) expired)))

(define (profile-record! key)
  (or (hash-ref *profile-store* key #f)
      (begin
        (when (>= (hash-count (const #t) *profile-store*) *profile-max-entries*)
          (let ((old #f) (old-time +inf.0))
            (hash-for-each
             (lambda (k v)
               (when (< (assoc-ref v "touched") old-time)
                 (set! old k) (set! old-time (assoc-ref v "touched")))) *profile-store*)
            (when old (hash-remove! *profile-store* old))))
        (let ((rec (list (cons "touched" (profile-clock))
                         (cons "photo_revision" 0) (cons "photo_state" "unknown")
                         (cons "availability" "unknown") (cons "availability_at" -1000000)
                         (cons "activity" "none") (cons "activity_at" -1000000))))
          (hash-set! *profile-store* key rec) rec))))

(define (profile-set! rec key value)
  ;; Keep the top-level alist identity for concurrent job invalidation guards.
  (let ((pair (assoc key rec)))
    (if pair (set-cdr! pair value)
        (set-cdr! rec (cons (cons key value) (cdr rec))))))

(define (profile-snapshot key rec)
  (let* ((now (profile-clock))
         (age (max 0 (- now (assoc-ref rec "availability_at"))))
         (activity-age (max 0 (- now (assoc-ref rec "activity_at"))))
         (group? (string-suffix? "@g.us" key))
         (state (if (or group? (> age 60)) "unknown" (assoc-ref rec "availability")))
         (last-seen (and (string=? state "offline") (assoc-ref rec "last_seen"))))
    (append
     (list (cons "jid" key) (cons "availability" state)
           (cons "availability_age" age)
           (cons "activity" (if (or group? (> activity-age 8)) "none" (assoc-ref rec "activity")))
           (cons "activity_age" activity-age)
           (cons "photo_revision" (assoc-ref rec "photo_revision"))
           (cons "photo_state" (assoc-ref rec "photo_state")))
     (if last-seen (list (cons "last_seen" last-seen)) '())
     ;; Keep historical observation separately; it is NOT current presence.
     (let ((seen (and (not group?) (not (string=? state "online")) (assoc-ref rec "last_seen"))))
       (if seen (list (cons "last_seen_observed" seen)) '())))))

(define (profile-capabilities)
  (json-response 200
    (list (cons "version" 1) (cons "epoch" (profile-epoch))
          (cons "avatar" "probe-on-request") (cons "about" "probe-on-request")
          (cons "presence" "observed-events") (cons "subscribe" "explicit-consent")
          (cons "remote_idle" #f) (cons "stories" #f)
          (cons "self_available" "never-set-by-profile-api")
          (cons "event_configuration" "existing-backend-subscriptions")
          (cons "max_subscriptions_per_epoch" 16) (cons "max_contacts" 12) (cons "max_jobs" 2))))

(define (handle-profiles query)
  (let* ((raw (form-param query "jids"))
         (keys (and (string? raw) (<= (string-length raw) 1024) (string-split raw #\,))))
    (if (not (and keys (<= 1 (length keys) 12) (every profile-jid? keys)
                  (= (length keys) (length (delete-duplicates (map normalize-jid keys) string=?)))))
        (json-response 400 '(("error" . "profiles requires 1..12 unique supported identities")))
        (let ((result
               (with-mutex *profile-mutex*
                 (profile-prune!)
                 (list (cons "version" 1) (cons "epoch" (profile-epoch))
                       (cons "profiles"
                         (list->vector
                          (map (lambda (id)
                                 (let* ((key (normalize-jid id)) (rec (profile-record! key)))
                                   (profile-set! rec "touched" (profile-clock))
                                   (profile-snapshot key rec))) keys)))))))
          (json-response 200 result)))))

(define (profile-reset!)
  ;; Old jobs are retained until they finish, so reconnect cannot exceed 2 workers.
  (set! *profile-reset-counter* (1+ *profile-reset-counter*))
  (hash-clear! *profile-store*)
  (hash-clear! *profile-subscriptions*))

(define (profile-event-change type ev key)
  ;; Validate and normalize before inspecting the cache.  A malformed event must
  ;; not become HTTP 200 merely because its identity has not been requested yet.
  ;; This helper does not allocate a profile record or mutate any shared state.
  (cond
   ((equal? type "Presence")
    (let* ((flat (jget ev "state")) (flag (assoc "Unavailable" ev))
           (state (cond ((member flat '("online" "offline")) flat)
                        ((and flag (boolean? (cdr flag)))
                         (if (cdr flag) "offline" "online"))
                        (else #f)))
           (last-raw (jget ev "last_seen" "LastSeen"))
           (last-ts (and last-raw (parse-timestamp last-raw))))
      (and state (not (string-suffix? "@g.us" key))
           (list state (and (equal? state "offline") last-ts (> last-ts 0)
                            (<= last-ts (car (gettimeofday))) last-ts)))))
   ((equal? type "ChatPresence")
    (let ((state (jget ev "State" "state")) (media (jget ev "Media" "media"))
          (chat (jget ev "Chat" "chat")))
      (and (not (string-suffix? "@g.us" key))
           (member state '("composing" "paused"))
           (or (not media) (member media '("" "text" "audio")))
           (or (not chat)
               (and (profile-jid? chat) (not (string-suffix? "@g.us" chat))))
           (list (cond ((equal? state "paused") "none")
                       ((equal? media "audio") "recording") (else "typing"))))))
   ((equal? type "Picture")
    (let ((remove (assoc "Remove" ev)))
      ;; Group photographs remain valid; only group-wide presence is forbidden.
      (and (or (not remove) (boolean? (cdr remove)))
           (list (if (and remove (cdr remove)) "removed" "changed")))))
   (else #f)))

(define* (profile-event! o #:optional (aliases? #t))
  ;; Returns ignored/accepted/invalid. Only previously requested identities retained.
  (let* ((type (jget o "type")) (ev (or (jget o "event") o)))
    (cond
     ((not (and (json-object? ev) (profile-unique-json? o 0))) 'invalid)
     ((member type '("Connected" "Disconnected" "LoggedOut" "StreamReplaced" "PrivacySettings"))
      (with-mutex *profile-mutex* (profile-reset!)) 'accepted)
     (else
      (let* ((raw (cond ((equal? type "Picture") (jget ev "JID" "jid"))
                        ((equal? type "ChatPresence") (jget ev "Sender" "from"))
                        (else (jget ev "From" "from"))))
             (key (and (profile-jid? raw) (normalize-jid raw)))
             (change (and key (profile-event-change type ev key)))
             (stamp-raw (jget ev "Timestamp" "timestamp"))
             (stamp (and stamp-raw (parse-timestamp stamp-raw)))
             (stamp-key (and (string? type) (string-append type "_timestamp"))))
        (if (or (not change)
                (and stamp-raw
                     (or (not stamp) (< stamp 0) (> stamp (+ (car (gettimeofday)) 60)))))
            'invalid
            (begin
              (when aliases?
                (let ((aliases
                       (with-mutex *profile-mutex*
                         (hash-fold (lambda (candidate _rec out)
                                      (if (and (not (equal? candidate key))
                                               (equal? (profile-provider-jid candidate)
                                                       (profile-provider-jid key)))
                                          (cons candidate out) out)) '() *profile-store*))))
                  (for-each
                   (lambda (candidate)
                     (let* ((identity (cond ((equal? type "Picture") "JID")
                                            ((equal? type "ChatPresence") "Sender")
                                            (else "From")))
                            (copy (acons identity candidate
                                   (filter (lambda (pair)
                                             (not (member (car pair) '("From" "from" "Sender" "JID" "jid")))) ev))))
                       (profile-event! (list (cons "type" type) (cons "event" copy)) #f))) aliases)))
            (with-mutex *profile-mutex*
              (profile-prune!)
              (let ((rec (hash-ref *profile-store* key #f)))
                (cond
                 ((not rec) 'ignored)
                 ((and stamp (assoc-ref rec stamp-key) (< stamp (assoc-ref rec stamp-key))) 'ignored)
                 (else
                  (cond
                   ((equal? type "Presence")
                    (profile-set! rec "availability" (car change))
                    (profile-set! rec "availability_at" (profile-clock))
                    (profile-set! rec "last_seen" (cadr change)))
                   ((equal? type "ChatPresence")
                    (profile-set! rec "activity" (car change))
                    (profile-set! rec "activity_at" (profile-clock)))
                   ((equal? type "Picture")
                    (profile-set! rec "photo_revision" (1+ (assoc-ref rec "photo_revision")))
                    (profile-set! rec "photo_state" (car change))))
                  (when stamp (profile-set! rec stamp-key stamp))
                  'accepted)))))))))))

(define (profile-provider-jid key)
  ;; Metadata only: never change a send recipient or merge chat histories.
  ;; This map is read from the operator-selected wuzapi database, not guessed.
  (if (string-suffix? "@lid" key)
      (let ((phone (hash-ref *lidmap* (substring key 0 (- (string-length key) 4)) #f)))
        (if (and (string? phone)
                 (string-match "^[0-9]{3,30}(@s[.]whatsapp[.]net)?$" phone))
            (normalize-jid phone) key))
      key))

(define (profile-upstream kind requested-key)
  (let ((key (profile-provider-jid requested-key)))
  ;; No store mutex is held during upstream I/O. Do not log upstream bodies.
  (let ((path (cond ((member kind '("avatar" "photo")) "/user/avatar")
                    ((equal? kind "about") "/user/info")
                    (else "/user/presence/subscribe")))
        (payload (cond ((member kind '("avatar" "photo"))
                        (list (cons "Phone" key) (cons "Preview" (equal? kind "avatar"))))
                       ((equal? kind "about")
                        (list (cons "Phone" (vector (if (string-index key #\@) key
                                                      (string-append key "@s.whatsapp.net"))))))
                       (else (list (cons "Phone" key))))))
    (call-with-values (lambda () (parameterize ((wuzapi-response-limit 32768)) (wuzapi-request 'POST path payload)))
      (lambda (status parsed raw)
        (cond
         ((member status '(404 405 501))
          (list (cons "state" "unsupported") (cons "reason" "provider-route") (cons "provider_http" status)))
         ((or (not (upstream-ok? status parsed)) (not (profile-unique-json? parsed 0))
              (> (string-length raw) 32768))
          (list (cons "state" "unavailable") (cons "reason" "provider-rejected") (cons "provider_http" status)))
         ((equal? kind "subscribe") '(("state" . "subscribed")))
         (else
          (let ((data (or (jget parsed "data") parsed)))
            (if (member kind '("avatar" "photo"))
                (let ((url (or (jget data "url") (jget data "URL"))))
                  ;; Client worker applies the stricter exact-host/DNS/TLS policy.
                  (if (valid-download-url? url)
                      (list (cons "state" "ready") (cons "url" url))
                      '(("state" . "unavailable"))))
                (let* ((users (jget data "Users"))
                       (record (or (jget users key) (jget users (string-append key "@s.whatsapp.net"))))
                       (about (jget record "Status")))
                  (if (and (string? about) (<= (string-length about) 1024))
                      (list (cons "state" "ready") (cons "about" about))
                      '(("state" . "unavailable"))))))))))))
)

(define (start-profile-job body)
  (let* ((o (and (<= (string-length body) 2048) (safe-json-parse body)))
         (key (and (profile-jid? (jget o "jid")) (normalize-jid (jget o "jid"))))
         (kind (jget o "kind")))
    (cond
     ((not (and o (profile-unique-json? o 0) key (member kind '("avatar" "photo" "about" "subscribe"))
                (every (lambda (pair) (member (car pair) '("jid" "kind" "consent"))) o)))
      (json-response 400 '(("error" . "invalid profile job"))))
     ((and (equal? kind "subscribe")
           (or (not (eq? (jget o "consent") #t)) (string-suffix? "@g.us" key)))
      (json-response 403 '(("error" . "direct contact and explicit presence consent required"))))
     (else
      (let* ((epoch (profile-epoch))
             (entry (with-mutex *profile-mutex*
                      (profile-prune!)
                      (let ((rec (profile-record! key)))
                        (if (or (>= (hash-count (const #t) *profile-jobs*) 2)
                                ;; Rate-limit subscription attempts, even failed ones.
                                (and (equal? kind "subscribe")
                                     (or (and (not (hash-ref *profile-subscriptions* key #f))
                                              (>= (hash-count (const #t) *profile-subscriptions*) 16))
                                         (< (- (profile-clock) (or (assoc-ref rec "subscribed_at") -1000000)) 300))))
                            #f
                            (begin
                              (when (equal? kind "subscribe")
                                (hash-set! *profile-subscriptions* key #t)
                                (profile-set! rec "subscribed_at" (profile-clock)))
                              (set! *profile-counter* (1+ *profile-counter*))
                              (let ((id (read-revision *profile-counter* "profile")))
                                (hash-set! *profile-jobs* id (vector #f 0 #f))
                                (list id rec (assoc-ref rec "photo_revision")))))))))
        (if (not entry) (json-response 429 '(("state" . "busy") ("error" . "profile workers busy or request throttled")))
            (let ((id (car entry)) (record (cadr entry)) (revision (caddr entry)))
              (catch #t
                (lambda ()
                  (call-with-new-thread
                   (lambda ()
                     (let ((result (catch #t (lambda () (profile-upstream kind key))
                                          (lambda _ '(("state" . "unavailable"))))))
                       (with-mutex *profile-mutex*
                         (let ((valid? (and (equal? epoch (profile-epoch))
                                            (eq? record (hash-ref *profile-store* key #f))
                                            (= revision (assoc-ref record "photo_revision")))))
                           (hash-set! *profile-jobs* id
                             (vector #t (profile-clock)
                               (if valid? (append result (list (cons "photo_revision" revision) (cons "epoch" epoch)))
                                   '(("state" . "stale")))))))))))
                (lambda _
                  (with-mutex *profile-mutex* (hash-remove! *profile-jobs* id))
                  (throw 'upstream-failure)))
              (json-response 202 (list (cons "job" id))))))))))

(define (poll-profile-job query)
  (let* ((id (form-param query "id"))
         (job (with-mutex *profile-mutex*
                (profile-prune!)
                (let ((entry (and (string? id) (<= (string-length id) 160)
                                  (hash-ref *profile-jobs* id #f))))
                  (when (and entry (vector-ref entry 0)) (hash-remove! *profile-jobs* id)) entry))))
    (cond ((not job) (json-response 404 '(("state" . "unavailable"))))
          ((not (vector-ref job 0)) (json-response 202 '(("pending" . #t))))
          (else (json-response 200 (vector-ref job 2))))))
