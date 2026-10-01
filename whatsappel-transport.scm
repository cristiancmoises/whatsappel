;;; whatsappel-transport.scm --- ingestion and live-transport contracts
;;; SPDX-License-Identifier: AGPL-3.0-only
;;; Loaded by whatsappel.scm; never starts another listener or changes sessions.

(define (parse-webhook raw)
  "Accept one direct, JSON jsonData, or URL-encoded jsonData envelope."
  (let* ((object (safe-json-parse raw))
         (inner
          (cond
           ((and object (assoc "jsonData" object))
            (and (not (assoc "event" object)) (not (assoc "type" object))
                 (string? (assoc-ref object "jsonData"))
                 (safe-json-parse (assoc-ref object "jsonData"))))
           (object object)
           (else
            (let ((fields (filter (lambda (part) (string-prefix? "jsonData=" part))
                                  (string-split raw #\&))))
              (and (= 1 (length fields))
                   (let ((text (form-param raw "jsonData")))
                     (and text (safe-json-parse text)))))))))
    (and inner (not (assoc "jsonData" inner)) inner)))

(define* (unwrap-message value #:optional (depth 0))
  "Unwrap ordinary ephemeral/document containers, never view-once containers."
  (and (json-object? value) (< depth 8)
       (let ((wrapper (or (jget value "ephemeralMessage" "EphemeralMessage")
                          (jget value "documentWithCaptionMessage" "DocumentWithCaptionMessage"))))
         (if wrapper
             (unwrap-message (jget wrapper "message" "Message") (1+ depth))
             value))))

(define (upstream-send-id status parsed)
  "Return an unambiguous accepted message ID. HTTP status alone is insufficient."
  (let* ((data (jget parsed "data"))
         (ids (and (json-object? data)
                   (map cdr (filter-map (lambda (key) (assoc key data)) '("Id" "ID" "id"))))))
    (and (json-object? parsed) (upstream-ok? status parsed) (json-unique-tree? parsed)
         (not (assoc "error" parsed)) (json-object? data)
         (not (assoc "error" data))
         (or (not (assoc "success" data)) (eq? #t (assoc-ref data "success")))
         (pair? ids) (every valid-target? ids)
         (every (lambda (id) (string=? (car ids) id)) ids)
         (car ids))))

;; Multipart file delivery carries binary bytes. Extract ONLY the bounded
;; jsonData part; do not decode, persist, execute or trust an uploaded filename.
(define (bytes-slice bytes start end)
  (let ((out (make-bytevector (- end start))))
    (bytevector-copy! bytes start out 0 (- end start)) out))
(define (bytes-find bytes needle start)
  (let ((n (bytevector-length bytes)) (m (bytevector-length needle)))
    (let loop ((i start))
      (and (<= (+ i m) n)
           (if (let match ((j 0))
                 (or (= j m) (and (= (bytevector-u8-ref bytes (+ i j))
                                      (bytevector-u8-ref needle j))
                                 (match (1+ j)))))
               i (loop (1+ i)))))))

(define (multipart-webhook-json body boundary)
  (unless (and (string? boundary) (<= 1 (string-length boundary) 70)
               (string-every (lambda (c) (<= 33 (char->integer c) 126)) boundary))
    (error "Invalid multipart boundary"))
  (let* ((bytes (if (bytevector? body) body (string->utf8 (body->string body))))
         (marker (string->utf8 (string-append "--" boundary)))
         (separator (string->utf8 (string-append "\r\n--" boundary)))
         (header-end (string->utf8 "\r\n\r\n"))
         (length (bytevector-length bytes))
         (m (bytevector-length marker)))
    (unless (equal? 0 (bytes-find bytes marker 0)) (error "Invalid multipart start"))
    (let loop ((position m) (parts 0) (json #f))
      (when (or (> parts 32) (> (+ position 2) length)) (error "Invalid multipart structure"))
      (cond
       ((and (= 45 (bytevector-u8-ref bytes position)) (= 45 (bytevector-u8-ref bytes (1+ position))))
        (unless json (error "Missing jsonData")) json)
       ((and (= 13 (bytevector-u8-ref bytes position)) (= 10 (bytevector-u8-ref bytes (1+ position))))
        (let* ((begin (+ position 2)) (end (bytes-find bytes header-end begin)))
          (unless (and end (<= (- end begin) 8192)) (error "Invalid multipart headers"))
          (let* ((headers (utf8->string (bytes-slice bytes begin end)))
                 (selected (string-match "(^|\n)[Cc]ontent-[Dd]isposition: *form-data; *name=\"jsonData\"(;|\r|$)" headers))
                 (content (+ end 4)) (next (bytes-find bytes separator content)))
            (unless next (error "Missing multipart terminator"))
            (when (and selected (or json (> (- next content) 1048576)))
              (error "Duplicate or oversized jsonData"))
            (loop (+ next 2 m) (1+ parts)
                  (if selected (utf8->string (bytes-slice bytes content next)) json)))))
       (else (error "Invalid multipart delimiter"))))))

(define (webhook-body-string headers body)
  (let* ((type (assoc-ref headers 'content-type))
         (multipart? (and (pair? type) (eq? (car type) 'multipart/form-data)))
         (boundary (and multipart? (assoc-ref (cdr type) 'boundary))))
    (if multipart? (multipart-webhook-json body boundary) (body->string body))))

(define *transport-mutex* (make-mutex))
(define *transport-busy* #f)
(define *transport-last-check* 0)
(define *transport-last-event* 0)
(define *transport-last-message* 0)
(define *transport-event-count* 0)
(define *transport-message-count* 0)
(define *transport-state* '(("checked" . #f) ("connected" . null) ("logged_in" . null)
                          ("webhook_matches" . null) ("message_subscribed" . null)))

(define (transport-note-event! kind)
  (when (string? kind)
    (with-mutex *transport-mutex*
      (set! *transport-last-event* (current-time))
      (set! *transport-event-count* (1+ *transport-event-count*)))))
(define (transport-note-message!)
  (with-mutex *transport-mutex*
    (set! *transport-last-message* (current-time))
    (set! *transport-message-count* (1+ *transport-message-count*))))

(define (receipt-rank state)
  (cond ((equal? state "accepted") 1) ((equal? state "delivered") 2)
        ((equal? state "read") 3) (else 0)))
(define (handle-receipt object)
  (let* ((event (jget object "event")) (chat (jget event "Chat" "chat"))
         (ids (->list (jget event "MessageIDs" "messageIDs")))
         (state (cond ((equal? (jget object "state") "Delivered") "delivered")
                      ((equal? (jget object "state") "Read") "read") (else #f))))
    (cond
     ((not state) (json-response 200 '(("success" . #t) ("ignored" . #t))))
     ((or (not (valid-target? chat)) (not (pair? ids)) (> (length ids) 128)
          (not (every valid-target? ids)))
      (json-response 400 '(("error" . "Invalid receipt"))))
     (else
      (with-mutex *smutex*
        (let* ((key (normalize-jid chat)) (records (hash-ref *chats* key '())) (changed #f)
               (updated (map (lambda (record)
                               (if (and (eq? #t (jget record "me"))
                                        (member (jget record "id") ids)
                                        (> (receipt-rank state) (receipt-rank (jget record "delivery"))))
                                   (begin (set! changed #t)
                                          (acons "delivery" state
                                                 (filter (lambda (p) (not (equal? (car p) "delivery"))) record)))
                                   record)) records)))
          (when changed (hash-set! *chats* key updated) (invalidate-read-state! key))))
      (json-response 200 '(("success" . #t)))))))

(define (transport-bool object key)
  (let* ((alias (if (equal? key "Connected") "connected" "loggedIn"))
         (pairs (and (json-object? object)
                     (filter-map (lambda (k) (assoc k object)) (list key alias)))))
    (if (and (pair? pairs) (every (lambda (p) (boolean? (cdr p))) pairs)
             (every (lambda (p) (eq? (cdr p) (cdar pairs))) pairs))
        (cdar pairs) 'null)))

(define (webhook-config parsed)
  ;; Read the established wuzapi GET /webhook schema, never guess missing fields.
  (let* ((data (jget parsed "data")) (url (jget data "webhook"))
         (events (and (json-object? data) (assoc "subscribe" data))))
    (and (string? url) (<= (string-length url) 8192) events
         (or (vector? (cdr events)) (null? (cdr events)))
         (let ((names (->list (cdr events))))
           (and (<= (length names) 64)
                (every (lambda (s) (and (string? s) (<= 1 (string-length s) 80)
                                        (string-match "^[A-Za-z][A-Za-z0-9]*$" s))) names)
                (list url names))))))

(define (transport-label value)
  (cond ((eq? value #t) "yes") ((eq? value #f) "no") (else "unknown")))

(define (transport-subscribed hook name)
  (transport-label (if hook (if (or (member "All" (cadr hook)) (member name (cadr hook))) #t #f) 'null)))

(define (transport-session-state status session)
  "Describe session evidence; missing or inconsistent booleans stay unknown."
  (let ((connected (transport-bool session "Connected"))
        (logged (transport-bool session "LoggedIn")))
    (cond ((member status '(401 403)) "authentication-required")
          ((not (<= 200 status 299)) "provider-unavailable")
          ((or (eq? connected 'null) (eq? logged 'null)) "unknown")
          ((not connected) "disconnected")
          ((not logged) "pairing-required")
          (else "ready"))))

(define (transport-connect)
  "One explicit session-connect attempt, never logout, callback repair or resend."
  (call-with-values (lambda () (wuzapi-request 'GET "/session/status" #f))
    (lambda (status parsed raw)
      (let* ((session (and (upstream-ok? status parsed) (json-unique-tree? parsed)
                           (jget parsed "data")))
             (state (transport-session-state status session)))
        (cond
         ((equal? state "ready") '(("connect_result" . "already-connected")))
         ((equal? state "pairing-required") '(("connect_result" . "pairing-required")))
         ((not (equal? state "disconnected"))
          (list (cons "connect_result" "status-unverified-no-connect")))
         (else
          (call-with-values (lambda () (wuzapi-request 'GET "/webhook" #f))
            (lambda (ws wp wr)
              (let* ((config (and (upstream-ok? ws wp) (json-unique-tree? wp) (webhook-config wp)))
                     (configured (filter (lambda (x) (not (string-null? x)))
                                         (map string-trim-both (string-split *subscribe* #\,)))))
                (if (or (not config) (> (length configured) 64)
                        (not (every (lambda (name)
                                      (and (<= (string-length name) 80)
                                           (string-match "^[A-Za-z][A-Za-z0-9]*$" name))) configured)))
                    '(("connect_result" . "subscriptions-unverified-no-connect"))
                    (let ((events (delete-duplicates (append (cadr config) configured '("Message" "ReadReceipt")))))
                      (if (> (length events) 64)
                          '(("connect_result" . "subscriptions-unverified-no-connect"))
                          (call-with-values
                              (lambda () (wuzapi-request 'POST "/session/connect"
                                          (list (cons "Subscribe" (list->vector events))
                                                (cons "Immediate" #t))))
                            (lambda (cs cp cr)
                              (list (cons "connect_http" cs)
                                    (cons "connect_result"
                                      (cond ((upstream-ok? cs cp) "requested-check-status")
                                            ((= cs 409) "already-started-check-status")
                                            (else "unconfirmed-no-automatic-retry"))))))))))))))))))

(define (transport-inspect)
  (call-with-values (lambda () (wuzapi-request 'GET "/session/status" #f))
    (lambda (ss sp sr)
      (call-with-values (lambda () (wuzapi-request 'GET "/webhook" #f))
        (lambda (ws wp wr)
          (let* ((session (and (upstream-ok? ss sp) (json-unique-tree? sp) (jget sp "data")))
                 (hook (and (upstream-ok? ws wp) (json-unique-tree? wp) (webhook-config wp))))
            (list (cons "session_state" (transport-session-state ss session))
                  (cons "checked" #t) (cons "status_http" ss) (cons "webhook_http" ws)
                  (cons "connection_state" (transport-label (transport-bool session "Connected")))
                  (cons "login_state" (transport-label (transport-bool session "LoggedIn")))
                  (cons "callback_state" (transport-label (if hook (equal? (car hook) *hook-url*) 'null)))
                  (cons "subscription_state" (transport-label (if hook (if (or (member "All" (cadr hook)) (member "Message" (cadr hook))) #t #f) 'null)))
                  (cons "presence_subscription_state" (transport-subscribed hook "Presence"))
                  (cons "activity_subscription_state" (transport-subscribed hook "ChatPresence"))
                  (cons "picture_subscription_state" (transport-subscribed hook "Picture"))
                  (cons "connected" (transport-bool session "Connected"))
                  (cons "logged_in" (transport-bool session "LoggedIn"))
                  (cons "webhook_matches" (if hook (equal? (car hook) *hook-url*) 'null))
                  (cons "message_subscribed" (if hook (if (or (member "All" (cadr hook))
                                                                           (member "Message" (cadr hook))) #t #f) 'null)))))))))

(define* (transport-repair replace? #:optional (profiles? #f))
  ;; Explicit operator action. Preserve all subscriptions, never connect/logout.
  ;; wuzapi has no CAS; read again and verify, but no claim of external-writer safety.
  (call-with-values (lambda () (wuzapi-request 'GET "/webhook" #f))
    (lambda (status parsed raw)
      (let ((config (and (upstream-ok? status parsed) (webhook-config parsed))))
        (cond
         ((not config) '(("repair" . "unsupported-webhook-schema")))
         ((and (not replace?) (not (string-null? (car config)))
               (not (equal? (car config) *hook-url*)))
          '(("repair" . "different-callback-confirmation-required")))
         (else
          (let ((events (delete-duplicates (append (cadr config) '("Message" "ReadReceipt")
                                (if profiles? '("Presence" "ChatPresence" "Picture") '())))))
            (call-with-values
                (lambda () (wuzapi-request 'POST "/webhook"
                            (list (cons "webhookurl" *hook-url*)
                                  (cons "events" (list->vector events)))))
              (lambda (st obj text)
                (if (not (upstream-ok? st obj))
                    '(("repair" . "unconfirmed-no-automatic-retry"))
                    (call-with-values (lambda () (wuzapi-request 'GET "/webhook" #f))
                      (lambda (vs vp vr)
                        (let ((v (and (upstream-ok? vs vp) (webhook-config vp))))
                          (list (cons "repair"
                                 (if (and v (equal? (car v) *hook-url*)
                                          (every (lambda (name) (member name (cadr v))) events))
                                     "registered-not-reachability-tested" "verification-failed")))))))))))))))
)

(define* (transport-start! operation replace? #:optional (profiles? #f))
  (let ((started (with-mutex *transport-mutex*
                   (and (not *transport-busy*)
                        (begin (set! *transport-busy* #t) #t)))))
    (when started
      (catch #t
        (lambda ()
          (call-with-new-thread
           (lambda ()
             (let ((state
                    (catch #t
                      (lambda ()
                        (parameterize ((wuzapi-response-limit 65536))
                          (let ((repair (cond ((eq? operation 'repair) (transport-repair replace? profiles?))
                                              ((eq? operation 'connect) (transport-connect))
                                              (else '()))))
                            (append repair (transport-inspect)))))
                      (lambda _ '(("checked" . #f) ("error" . "transport-check-failed"))))))
               (with-mutex *transport-mutex*
                 (set! *transport-state* state)
                 (set! *transport-last-check* (current-time))
                 (set! *transport-busy* #f))))))
        (lambda _ (with-mutex *transport-mutex* (set! *transport-busy* #f)))))
    started))

(define* (handle-transport-status #:optional (refresh? #f))
  (when (with-mutex *transport-mutex*
          (and (not *transport-busy*)
               (>= (- (current-time) *transport-last-check*) (if refresh? 2 15))))
    (transport-start! 'check #f))
  (json-response 200
    (with-mutex *transport-mutex*
      (append (list (cons "version" "3.3.1") (cons "checking" *transport-busy*)
                    (cons "checked_age" (if (> *transport-last-check* 0) (- (current-time) *transport-last-check*) 'null))
                    (cons "webhooks_seen" *transport-event-count*)
                    (cons "messages_ingested" *transport-message-count*)
                    (cons "last_message_age" (if (> *transport-last-message* 0) (- (current-time) *transport-last-message*) 'null)))
              *transport-state*))))

(define (handle-transport-repair raw)
  (let* ((o (safe-json-parse raw)) (replace? (and o (assoc-ref o "replace")))
         (profiles? (and o (assoc-ref o "profiles"))))
    (cond
     ((or (not o) (not (every (lambda (p) (member (car p) '("confirm" "replace" "profiles"))) o))
          (not (eq? #t (assoc-ref o "confirm")))
          (and (assoc "replace" o) (not (boolean? replace?)))
          (and (assoc "profiles" o) (not (boolean? profiles?))))
      (json-response 400 '(("error" . "Explicit callback repair confirmation required"))))
     ((transport-start! 'repair replace? profiles?)
      (json-response 202 '(("accepted" . #t) ("note" . "Poll transport status; no message sent"))))
     (else (json-response 429 '(("error" . "Transport check busy; retry explicitly")))))))

(define (handle-transport-connect raw)
  (let ((o (safe-json-parse raw)))
    (cond
     ((or (not o) (not (json-unique-tree? o))
          (not (equal? (map car o) '("confirm")))
          (not (eq? #t (assoc-ref o "confirm"))))
      (json-response 400 '(("error" . "Explicit session-connect confirmation required"))))
     ((transport-start! 'connect #f)
      (json-response 202 '(("accepted" . #t) ("note" . "Poll status; connection is not yet verified"))))
     (else (json-response 429 '(("error" . "Transport operation busy; no connect was started")))))))
