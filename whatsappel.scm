#!/usr/bin/env guile
!#
;;; whatsappel.scm --- Guile bridge between Emacs and wuzapi (whatsmeow)
;;;
;;; SPDX-License-Identifier: AGPL-3.0-only
;;; Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
;;;
;;; Replaces the former Node/Baileys backend. No JavaScript. The WhatsApp
;;; multi-device protocol is delegated to wuzapi (Go/whatsmeow), reached over
;;; its local REST API. This process:
;;;   - exposes a token-guarded HTTP API on loopback for whatsapp.el,
;;;   - proxies send (text + media), connect, status, qr, logout to wuzapi,
;;;   - keeps a per-chat message store from inbound webhooks,
;;;   - relays inbound media downloads.
;;;
;;; Configuration (environment):
;;;   WHATSAPPEL_HOST        bind address           (default 127.0.0.1)
;;;   WHATSAPPEL_PORT        bind port              (default 7337)
;;;   WHATSAPPEL_TOKEN       REQUIRED bridge token  (Emacs auth + webhook path)
;;;   WHATSAPPEL_PUBLIC_URL  URL wuzapi calls back  (default http://HOST:PORT)
;;;   WHATSAPPEL_SUBSCRIBE   wuzapi events          (default Message)
;;;   WHATSAPPEL_CHAT_CAP    msgs kept per chat     (default 500)
;;;   WHATSAPPEL_MAX_CHATS   total retained chats   (default 1000)
;;;   WHATSAPPEL_MAX_BODY_BYTES buffered body/response cap (default 24 MiB)
;;;   WHATSAPPEL_MAX_MEDIA_BYTES decoded media cap  (default 16 MiB)
;;;   WUZAPI_BASE_URL        wuzapi base            (default http://127.0.0.1:8080)
;;;   WUZAPI_TOKEN           REQUIRED wuzapi user token
;;;   WUZAPI_TOKEN_HEADER    header name for above  (default Token)

(use-modules (web server)
             (web request)
             (web response)
             (web uri)
             (web client)
             (json)
             (ice-9 format)
             (ice-9 threads)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 binary-ports)
             (ice-9 regex)
             (ice-9 match)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(define (env name default) (or (getenv name) default))

(define (require-env name)
  (or (let ((value (getenv name)))
        (and value (> (string-length value) 0) value))
      (begin
        (format (current-error-port)
                "whatsappel: missing required environment variable ~a~%" name)
        (exit 2))))

(define (env-integer name default minimum maximum)
  (let ((n (string->number (env name default))))
    (unless (and (integer? n) (exact? n) (<= minimum n maximum))
      (error "invalid numeric configuration" name))
    n))

(define *host*          (env "WHATSAPPEL_HOST" "127.0.0.1"))
(define *port*          (env-integer "WHATSAPPEL_PORT" "7337" 1 65535))
(define *bridge-token*  (require-env "WHATSAPPEL_TOKEN"))
(define *wuzapi-base*   (env "WUZAPI_BASE_URL" "http://127.0.0.1:8080"))
(define *wuzapi-token*  (require-env "WUZAPI_TOKEN"))
(define *wuzapi-hdr*    (string->symbol (string-downcase (env "WUZAPI_TOKEN_HEADER" "Token"))))
(define *subscribe*     (env "WHATSAPPEL_SUBSCRIBE" "Message"))
(define *chat-cap*      (env-integer "WHATSAPPEL_CHAT_CAP" "500" 1 10000))
(define *public-url*    (env "WHATSAPPEL_PUBLIC_URL"
                             (format #f "http://~a:~a" *host* *port*)))
(define *max-body-bytes* (env-integer "WHATSAPPEL_MAX_BODY_BYTES" "25165824" 1024 268435456))
(define *max-media-bytes* (env-integer "WHATSAPPEL_MAX_MEDIA_BYTES" "16777216" 1 201326592))
(define *max-chats* (env-integer "WHATSAPPEL_MAX_CHATS" "1000" 1 100000))
(define *max-text-length* 65536)

;; The webhook token is a path segment; reject characters that alter the URL.
(unless (and (string-match "^[A-Za-z0-9_-]+$" *bridge-token*)
             (>= (string-length *bridge-token*) 16))
  (error "WHATSAPPEL_TOKEN must contain at least 16 URL-safe letters, digits, - or _"))

(define *hook-path*     (string-append "/hook/" *bridge-token*))
(define *hook-url*      (string-append *public-url* *hook-path*))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

;; CT-REQUIRED: token comparison must not short-circuit on content mismatch.
(define (ct-string=? a b)
  (and (string? a) (string? b)
       (let ((ba (string->utf8 a)) (bb (string->utf8 b)))
         (and (= (bytevector-length ba) (bytevector-length bb))
              (let loop ((i 0) (acc 0))
                (if (>= i (bytevector-length ba))
                    (zero? acc)
                    (loop (1+ i)
                          (logior acc (logxor (bytevector-u8-ref ba i)
                                              (bytevector-u8-ref bb i))))))))))

(define (filter-false alist) (filter cdr alist))

(define (body->string body)
  (cond ((not body) "")
        ((bytevector? body) (utf8->string body))
        ((string? body) body)
        (else "")))

(define (json-response code obj)
  (values (build-response
           #:code code
           #:headers '((content-type . (application/json (charset . "utf-8")))
                       (cache-control . (no-store))))
          (string->utf8 (scm->json-string obj))))

(define (json-object? x)
  (and (list? x) (every (lambda (entry) (and (pair? entry) (string? (car entry)))) x)))

;; A duplicated key must not choose a different recipient, event, or status.
;; JSON arrays produced by guile-json are vectors, objects are string alists.
(define* (json-unique-tree? value #:optional (depth 0))
  (and (<= depth 64)
       (cond ((json-object? value)
              (let ((seen (make-hash-table)))
                (every (lambda (entry)
                         (and (not (hash-ref seen (car entry)))
                              (begin (hash-set! seen (car entry) #t) #t)
                              (json-unique-tree? (cdr entry) (1+ depth)))) value)))
             ((vector? value)
              (let loop ((i 0))
                (or (= i (vector-length value))
                    (and (json-unique-tree? (vector-ref value i) (1+ depth))
                         (loop (1+ i))))))
             (else #t))))

(define (safe-json-parse s)
  (catch #t
    (lambda ()
      (let ((obj (json-string->scm s)))
        (and (json-object? obj) (json-unique-tree? obj) obj)))
    (lambda _ #f)))

(define (nonempty-string? s)
  (and (string? s) (> (string-length (string-trim-both s)) 0)))

(define (char-iso-control? c)
  (let ((n (char->integer c))) (or (< n 32) (<= 127 n 159))))

(define (valid-target? s)
  (and (nonempty-string? s) (<= (string-length s) 256)
       (not (string-any char-whitespace? s))
       (not (string-any char-iso-control? s))))

(define (optional-string? value maximum)
  (or (not value) (and (string? value) (<= (string-length value) maximum))))

(define (upstream-ok? status parsed)
  (and (<= 200 status 299)
       (or (= status 204) (json-object? parsed))
       (or (not (json-object? parsed))
           (not (assoc "success" parsed))
           (not (eq? #f (assoc-ref parsed "success"))))))

;; First present key from an alist (string keys); tries each variant.
(define (jget obj . keys)
  (and (json-object? obj)
       (let loop ((ks keys))
         (and (pair? ks)
              (or (assoc-ref obj (car ks)) (loop (cdr ks)))))))

;; Minimal x-www-form-urlencoded decoding (fallback webhook payloads + queries).
(define (url-decode s)
  ;; Decode percent escapes as UTF-8 bytes, preserving non-ASCII names correctly.
  (catch #t
    (lambda () (uri-decode (string-map (lambda (c) (if (char=? c #\+) #\space c)) s)))
    (lambda _ #f)))

(define (form-param body key)
  (and (string? body)
       (let ((needle (string-append key "=")))
         (let loop ((parts (string-split body #\&)))
           (cond ((null? parts) #f)
                 ((string-prefix? needle (car parts))
                  (url-decode (substring (car parts) (string-length needle))))
                 (else (loop (cdr parts))))))))

(define (take-last lst n)
  (let ((len (length lst)))
    (if (> len n) (list-tail lst (- len n)) lst)))

;; Unify chat keys: bare number for 1:1, full jid for groups.
(define (normalize-jid s)
  (cond ((not (string? s)) "unknown")
        ((or (string-suffix? "@g.us" s) (string-suffix? "@lid" s)) s)
        ((string-index s #\@) => (lambda (i) (substring s 0 i)))
        (else s)))

(define (message-recipient? value)
  ;; A friendly name or an unknown namespace must never become a phone recipient.
  (and (string? value) (<= (string-length value) 80)
       (string-match "^([+]?[0-9]{3,30}(@(s[.]whatsapp[.]net|c[.]us))?|[0-9]{3,30}@lid|[0-9]{3,30}(-[0-9]{1,20})?@g[.]us)$" value)))

(define (current-ts) (number->string (current-time)))

;; Recognise the post-quantum envelope transport tag.
(define (pq-text? s) (and (string? s) (string-prefix? "WAPQ1:" s)))

;;; ---------------------------------------------------------------------------
;;; wuzapi REST client
;;; ---------------------------------------------------------------------------

;; Returns (values status parsed-or-#f raw-string).
(define wuzapi-response-limit (make-parameter *max-body-bytes*))

(define (wuzapi-request/raw method path body-obj)
  (let* ((uri  (string-append *wuzapi-base* path))
         (body (and body-obj (string->utf8 (scm->json-string body-obj))))
         (hdrs (append
                (list (cons *wuzapi-hdr* *wuzapi-token*))
                (if body
                    (list (cons 'content-type '(application/json (charset . "utf-8"))))
                    '()))))
    (call-with-values
        (lambda ()
          ;; Guile ignores no_proxy; never send local credentials to env proxies.
          (let* ((host (uri-host (string->uri uri)))
                 (local? (member host '("127.0.0.1" "localhost" "::1"))))
            (parameterize ((current-http-proxy (if local? #f (current-http-proxy)))
                           (current-https-proxy (if local? #f (current-https-proxy))))
              (http-request uri
                            #:method method #:headers hdrs #:body body
                            #:decode-body? #f #:streaming? #t))))
      (lambda (resp rbody)
        (let* ((status (response-code resp))
               (text (dynamic-wind
                       (lambda () #t)
                       (lambda ()
                         (let ((bytes (get-bytevector-n rbody (1+ (min *max-body-bytes* (wuzapi-response-limit))))))
                           (when (and (bytevector? bytes)
                                      (> (bytevector-length bytes) (min *max-body-bytes* (wuzapi-response-limit))))
                             (error "upstream response exceeds configured limit"))
                           (if (eof-object? bytes) "" (body->string bytes))))
                       (lambda () (close-port rbody))))
               (parsed (and (> (string-length text) 0)
                            (catch #t (lambda () (let ((obj (json-string->scm text)))
                                                  (and (json-unique-tree? obj) obj)))
                                   (lambda _ #f)))))
          (values status parsed text))))))

(define (wuzapi-request method path body-obj)
  (catch #t
    (lambda () (wuzapi-request/raw method path body-obj))
    ;; Never log exceptions here: URLs/headers may contain credentials.
    (lambda _ (values 502 '(("error" . "upstream unavailable or response exceeds limit")) ""))))

(define (relay method path body-obj)
  (call-with-values (lambda () (wuzapi-request method path body-obj))
    (lambda (status parsed text)
      (json-response (if (upstream-ok? status parsed) 200 502)
                     (list (cons "wuzapi_status" status)
                           (cons "data" (or parsed text)))))))

;;; ---------------------------------------------------------------------------
;;; Per-chat message store
;;; ---------------------------------------------------------------------------

(define *chats*  (make-hash-table))   ; jid -> list of message-alists (oldest first)
(define *unread* (make-hash-table))   ; jid -> integer
(define *names*  (make-hash-table))   ; jid -> push name
(define *smutex* (make-mutex))

;;; Versioned read snapshots. Invalidation happens under *smutex*; JSON encoding
;;; happens after releasing it. Revisions are process-scoped, never timestamps.
(define *read-epoch* (format #f "~a-~a-~a" (getpid) (car (gettimeofday)) (cdr (gettimeofday))))
(define *read-generation* 0)
(define *read-chat-revisions* (make-hash-table))
(define *read-summary-cache* #f)

(define (invalidate-read-state! key)
  (set! *read-generation* (1+ *read-generation*))
  (set! *read-summary-cache* #f)
  (when key (hash-set! *read-chat-revisions* key *read-generation*)))

(define (read-revision generation suffix)
  (string-append *read-epoch* ":" (number->string generation) ":" suffix))

(define (set-contact-name! jid name)
  (with-mutex *smutex*
    (let ((key (normalize-jid jid)))
      (unless (equal? name (hash-ref *names* key #f))
        (hash-set! *names* key name)
        (invalidate-read-state! key)))))


(define (record-id rec) (let ((id (jget rec "id"))) (and (nonempty-string? id) id)))

(define (valid-epoch? value)
  (and (real? value) (finite? value) (<= 0 value 253402300799)))

(define (parse-timestamp ts)
  (cond ((valid-epoch? ts) ts)
        ((not (string? ts)) #f)
        ((let ((n (string->number ts))) (and (valid-epoch? n) n)) => identity)
        ((string-match "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$" ts)
         => (lambda (match)
              (catch #t
                (lambda ()
                  (let* ((plain (string-append (substring ts 0 19) (match:substring match 2)))
                         (tm (car (strptime "%Y-%m-%dT%H:%M:%S%z" plain)))
                         (offset (vector-ref tm 9))
                         (epoch (+ offset (car (mktime tm "UTC")))))
                    (and (valid-epoch? epoch) epoch)))
                (lambda _ #f))))
        (else #f)))

(define (timestamp-value rec) (or (parse-timestamp (jget rec "ts")) 0))

(define (record-before? a b)
  (let ((ta (timestamp-value a)) (tb (timestamp-value b)))
    (if (= ta tb) (string<? (or (record-id a) "") (or (record-id b) "")) (< ta tb))))

(define (trim-chats! incoming)
  ;; Evict the least recently active chat as one unit, including auxiliary maps.
  (when (and (not (hash-ref *chats* incoming #f))
             (>= (hash-count (const #t) *chats*) *max-chats*))
    (let ((oldest #f) (oldtime +inf.0))
      (hash-for-each
       (lambda (chat records)
         (let ((ts (if (null? records) 0 (timestamp-value (last records)))))
           (when (or (not oldest) (< ts oldtime)
                     (and (= ts oldtime) (string<? chat oldest)))
             (set! oldest chat) (set! oldtime ts)))) *chats*)
      (when oldest
        (for-each (lambda (table) (hash-remove! table oldest))
                  (list *chats* *unread* *names* *rawjid* *read-chat-revisions*))
        (invalidate-read-state! #f)))))

(define (merge-records current incoming)
  ;; History never replaces live messages; a refresh may enrich an existing ID.
  (let ((seen (make-hash-table)) (anonymous '()))
    (for-each (lambda (rec)
                (let ((id (record-id rec)))
                  (if id
                      (let ((old (hash-ref seen id '())))
                        (hash-set! seen id (append rec (filter
                          (lambda (entry) (not (assoc (car entry) rec))) old))))
                      (set! anonymous (cons rec anonymous)))))
              (append current incoming))
    (take-last (sort (hash-fold (lambda (id rec out) (cons rec out)) anonymous seen)
                     record-before?) *chat-cap*)))

(define (store-record! chat rec inbound?)
  (with-mutex *smutex*
    (let* ((key (normalize-jid chat))
           (cur (hash-ref *chats* key '()))
           (id (record-id rec))
           (duplicate? (and id (any (lambda (r) (equal? id (record-id r))) cur))))
      (trim-chats! key)
      (hash-set! *rawjid* key chat)
      (hash-set! *chats* key
        (if (and (not duplicate?)
                 (or (null? cur) (not (record-before? rec (last cur)))))
            (take-last (append cur (list rec)) *chat-cap*)
            (merge-records cur (list rec))))
      (when (and inbound? (not duplicate?) (not (jget rec "me")))
        (hash-set! *unread* key (min *chat-cap* (1+ (hash-ref *unread* key 0)))))
      (let ((nm (jget rec "name")))
        (when (and (nonempty-string? nm) (not (jget rec "me")))
          (hash-set! *names* key nm)))
      (invalidate-read-state! key)
      (not duplicate?))))

(define (store-inbound! rec)
  (store-record! (or (jget rec "chat" "from") "unknown") rec #t))

(define (store-outbound! chat rec) (store-record! chat rec #f))

;; Detect a media sub-message. Returns (values kind-string media-alist caption).
(define (detect-media msg)
  (let loop ((specs '(("imageMessage" . "image")    ("ImageMessage" . "image")
                      ("videoMessage" . "video")    ("VideoMessage" . "video")
                      ("audioMessage" . "audio")    ("AudioMessage" . "audio")
                      ("documentMessage" . "document") ("DocumentMessage" . "document")
                      ("stickerMessage" . "sticker") ("StickerMessage" . "sticker"))))
    (if (null? specs)
        (values #f #f #f)
        (let ((mm (jget msg (caar specs))))
          (if (and (json-object? mm) (pair? mm))
              (values (cdar specs) mm
                      (or (assoc-ref mm "caption") (assoc-ref mm "Caption")))
              (loop (cdr specs)))))))

;; Extract wuzapi download fields from a media sub-message (defensive casing).
(define (media-dl-fields mm)
  (filter
   (lambda (entry)
     (let ((value (cdr entry)))
       (if (string=? (car entry) "FileLength")
           (let ((n (if (string? value) (string->number value) value)))
             (and (integer? n) (exact? n) (<= 0 n 201326592)))
           (and (string? value)
                (<= (string-length value)
                    (if (member (car entry) '("Url" "DirectPath")) 8192 256))))))
   (list (cons "Url"           (jget mm "url" "URL" "Url"))
         (cons "DirectPath"    (jget mm "directPath" "DirectPath" "direct_path"))
         (cons "MediaKey"      (jget mm "mediaKey" "MediaKey"))
         (cons "Mimetype"      (jget mm "mimetype" "Mimetype" "mimeType"))
         (cons "FileSHA256"    (jget mm "fileSha256" "FileSHA256" "fileSHA256"))
         (cons "FileLength"    (jget mm "fileLength" "FileLength"))
         (cons "FileEncSHA256" (jget mm "fileEncSha256" "FileEncSHA256" "fileEncSHA256")))))

;; Quoted text of a reply, from a message's contextInfo.quotedMessage.
(define (msg-quoted-text msg)
  (let* ((etm (and (pair? msg) (or (assoc-ref msg "extendedTextMessage")
                                   (assoc-ref msg "ExtendedTextMessage"))))
         (ci  (or (and (pair? etm) (jget etm "contextInfo" "ContextInfo"))
                  (and (pair? msg) (jget msg "contextInfo" "ContextInfo"))))
         (qm  (and (pair? ci) (jget ci "quotedMessage" "QuotedMessage"))))
    (and (pair? qm)
         (or (jget qm "conversation" "Conversation")
             (let ((q2 (jget qm "extendedTextMessage" "ExtendedTextMessage")))
               (and (pair? q2) (jget q2 "text" "Text")))
             (cond ((assoc-ref qm "imageMessage")   "[image]")
                   ((assoc-ref qm "videoMessage")   "[video]")
                   ((assoc-ref qm "stickerMessage") "[sticker]")
                   ((assoc-ref qm "audioMessage")   "[audio]")
                   (else #f))))))

(load (string-append (dirname (current-filename)) "/whatsappel-transport.scm"))

;; Parse a webhook payload (JSON, JSON jsonData or form jsonData) into a record.
;; Keep parsed fields only; duplicating raw/base64 webhook data wastes memory.
(define (extract-message raw)
  (let ((o (parse-webhook raw)))
    (if (not (pair? o))
        #f
        (let* ((ev     (assoc-ref o "event"))
               (info   (and (json-object? ev) (jget ev "Info" "info")))
               (msg    (unwrap-message (and (json-object? ev) (jget ev "Message" "message"))))
               (sender (and (pair? info) (or (assoc-ref info "Sender")
                                             (assoc-ref info "Chat"))))
               (chat   (and (pair? info) (or (assoc-ref info "Chat")
                                             (assoc-ref info "Sender"))))
               (name   (and (pair? info) (assoc-ref info "PushName")))
               (id     (and (pair? info) (assoc-ref info "ID")))
               (ts     (and (pair? info) (assoc-ref info "Timestamp")))
               (text   (and (pair? msg)
                            (or (assoc-ref msg "conversation")
                                (let ((etm (assoc-ref msg "extendedTextMessage")))
                                  (and (pair? etm) (assoc-ref etm "text")))))))
          (call-with-values (lambda () (detect-media (or msg '())))
            (lambda (kind mm cap)
              (filter-false
               (list (cons "type" (assoc-ref o "type"))
                     (cons "from" sender)
                     (cons "me" (eq? #t (jget info "IsFromMe")))
                     (cons "chat" chat)
                     (cons "name" name)
                     (cons "id"   id)
                     (cons "ts"   (or ts (current-ts)))
                     (cons "text" text)
                     (cons "kind" (or kind (and (pq-text? text) "pq")))
                     (cons "caption" cap)
                     (cons "reply" (msg-quoted-text msg))
                     (cons "media" (and mm (media-dl-fields mm)))))))))))

;;; ---------------------------------------------------------------------------
;;; History import from wuzapi (existing chats on first link / restart)
;;;
;;; wuzapi persists the WhatsApp history-sync into its own DB and exposes it at
;;; GET /chat/history (requires the user's history retention > 0):
;;;   ?chat_jid=index      -> { userid: [ {chat_jid,last_updated}, ... ] }
;;;   ?chat_jid=<jid>      -> [ {chat_jid,sender_jid,message_id,message_type,
;;;                              text_content,timestamp,data_json}, ... ]
;;; We pull that once at startup (and on demand via POST /sync) so the chat list
;;; and per-chat history appear without waiting for a new live message. Names are
;;; resolved from /user/contacts and /group/list.
;;; ---------------------------------------------------------------------------

(define *history-limit* (env-integer "WHATSAPPEL_HISTORY" "200" 1 10000))
(define *syncing?* #f)

;; Optional: wuzapi's whatsmeow store (main.db). When set, we read its
;; `whatsmeow_lid_map' (lid -> phone) read-only to put a name (or at least a real
;; phone number) on chats addressed by WhatsApp's anonymous @lid id. Empty = off.
(define *lidmap-db* (env "WHATSAPPEL_LIDMAP_DB" ""))
(define *lidmap*    (make-hash-table))   ; lid-number -> phone-number
(define *rawjid*    (make-hash-table))   ; normalized chat key -> raw wuzapi jid

(define (->list v)
  (cond ((vector? v) (vector->list v)) ((list? v) v) (else '())))

;; Read lid->phone from wuzapi's whatsmeow_lid_map via the sqlite3 CLI (read-only).
(define (load-lid-map!)
  (let ((h (make-hash-table)))
    (when (and (string? *lidmap-db*) (> (string-length *lidmap-db*) 0)
               (file-exists? *lidmap-db*))
      (catch #t
        (lambda ()
          (let* ((q "SELECT lid, pn FROM whatsmeow_lid_map;")
                 ;; No shell: database paths may contain quotes and metacharacters.
                 (port (open-pipe* OPEN_READ "sqlite3" "-readonly" "-noheader"
                                   "-separator" "|" *lidmap-db* q)))
            (let loop ()
              (let ((line (read-line port)))
                (unless (eof-object? line)
                  (let ((bar (string-index line #\|)))
                    (when (and bar (> bar 0))
                      (hash-set! h (substring line 0 bar) (substring line (1+ bar)))))
                  (loop))))
            (close-pipe port)))
        (lambda (k . a)
          (format #t "whatsappel: lid-map load failed: ~a~%" k))))
    (format #t "whatsappel: lid-map entries: ~a~%" (hash-count (const #t) h))
    h))

;; Percent-encode a chat jid for use in a query string ("@" -> "%40", etc.).
(define (uri-encode s) ((@ (web uri) uri-encode) s))

;; Resolve display names from contacts (1:1) and group subjects.
(define (load-names!)
  (call-with-values (lambda () (wuzapi-request 'GET "/user/contacts" #f))
    (lambda (st parsed raw)
      (let ((data (and (pair? parsed) (assoc-ref parsed "data"))))
        (when (pair? data)
          (for-each
           (lambda (pair)
             (let* ((jid  (car pair)) (info (cdr pair))
                    (nm   (and (pair? info)
                               (or (let ((x (assoc-ref info "FullName")))    (and (string? x) (> (string-length x) 0) x))
                                   (let ((x (assoc-ref info "PushName")))    (and (string? x) (> (string-length x) 0) x))
                                   (let ((x (assoc-ref info "FirstName")))   (and (string? x) (> (string-length x) 0) x))
                                   (let ((x (assoc-ref info "BusinessName"))) (and (string? x) (> (string-length x) 0) x))))))
               (when (and (string? jid) nm)
                 (set-contact-name! jid nm))))
           data)))))
  (call-with-values (lambda () (wuzapi-request 'GET "/group/list" #f))
    (lambda (st parsed raw)
      (let* ((data   (and (pair? parsed) (assoc-ref parsed "data")))
             (groups (and (pair? data) (assoc-ref data "Groups"))))
        (for-each
         (lambda (g)
           (let ((jid (and (pair? g) (assoc-ref g "JID")))
                 (nm  (and (pair? g) (assoc-ref g "Name"))))
             (when (and (string? jid) (string? nm) (> (string-length nm) 0))
               (set-contact-name! jid nm))))
         (->list groups))))))

;; Build a store record from one history row. Parses the embedded whatsmeow
;; event (data_json) once to recover both Info and the media sub-message, so the
;; client gets the same download fields (Url/DirectPath/MediaKey/...) a live
;; webhook would carry. Old media may still 403 at download time (WhatsApp CDN
;; expiry); recent/in-window media downloads and renders normally.
(define (history-row->rec row)
  (let* ((dj     (assoc-ref row "data_json"))
         (parsed (and (string? dj) (safe-json-parse dj)))
         (info   (and (pair? parsed) (assoc-ref parsed "Info")))
         (msg    (unwrap-message (and (pair? parsed) (assoc-ref parsed "Message"))))
         (fromme (if (and (pair? info) (assoc "IsFromMe" info))
                     (eq? #t (assoc-ref info "IsFromMe"))
                     (equal? (assoc-ref row "sender_jid") "me")))
         (name   (and (pair? info) (assoc-ref info "PushName")))
         (mtype  (assoc-ref row "message_type"))
         (text   (assoc-ref row "text_content"))
         (ts     (or (and (pair? info) (assoc-ref info "Timestamp"))
                     (assoc-ref row "timestamp"))))
    (call-with-values (lambda () (detect-media (or msg '())))
      (lambda (mkind mm mcap)
        (filter-false
         (list (cons "from" (if fromme "me" (assoc-ref row "sender_jid")))
               (cons "me"   (and fromme #t))
               (cons "chat" (assoc-ref row "chat_jid"))
               (cons "name" (and (string? name) (> (string-length name) 0) name))
               (cons "id"   (assoc-ref row "message_id"))
               (cons "ts"   ts)
               ;; Show real text only for non-media (avoid wuzapi's ":image:" stub).
               (cons "text" (and (or (not mkind) (pq-text? text)) text))
               (cons "kind" (cond ((pq-text? text) "pq")
                                  (mkind mkind)
                                  ((and (string? mtype) (not (string=? mtype "text"))) mtype)
                                  (else #f)))
               (cons "caption" (or mcap
                                   (and (string? mtype) (not (string=? mtype "text"))
                                        (not (string-prefix? ":" (or text ""))) text)))
               (cons "reply" (msg-quoted-text msg))
               (cons "media" (and mm (media-dl-fields mm)))))))))

(define (import-chat! jid)
  (call-with-values
      (lambda ()
        (wuzapi-request 'GET (string-append "/chat/history?chat_jid=" (uri-encode jid)
                                            "&limit=" (number->string *history-limit*)) #f))
    (lambda (st parsed raw)
      (unless (upstream-ok? st parsed) (throw 'upstream-failure))
      (let* ((rows (->list (and (pair? parsed) (assoc-ref parsed "data"))))
             (recs (map history-row->rec (filter json-object? rows)))
             (good (filter (lambda (r) (and (parse-timestamp (jget r "ts"))
                                          (valid-target? (jget r "id"))
                                          (optional-string? (jget r "text") *max-text-length*))) recs))
             (sorted (sort good record-before?)))
        (when (pair? sorted)
          (with-mutex *smutex*
            (let ((key (normalize-jid jid)))
              (trim-chats! key)
              (hash-set! *rawjid* key jid)
              (hash-set! *chats* key (merge-records (hash-ref *chats* key '()) sorted))
              (invalidate-read-state! key)
              (unless (hash-ref *unread* key #f) (hash-set! *unread* key 0))
              ;; If contacts/groups didn't name this chat, fall back to the
              ;; PushName carried by its most recent inbound (non-me) message.
              (unless (hash-ref *names* key #f)
                (let loop ((ms (reverse sorted)))
                  (when (pair? ms)
                    (let ((nm (assoc-ref (car ms) "name")))
                      (if (and (not (assoc-ref (car ms) "me")) (string? nm) (> (string-length nm) 0))
                          (hash-set! *names* key nm)
                          (loop (cdr ms)))))))
              ;; Still unnamed and this is an @lid chat? Map lid -> phone, then
              ;; phone -> contact name; failing that, show the real phone number,
              ;; which is far more useful than the opaque lid.
              (when (and (not (hash-ref *names* key #f))
                         (string-contains jid "@lid"))
                (let ((phone (hash-ref *lidmap* (car (string-split key #\@)) #f)))
                  (when (string? phone)
                    (hash-set! *names* key
                               (or (hash-ref *names* phone #f)
                                   (string-append "+" phone)))))))))))))

;; Pull every chat's history from wuzapi into the store. Safe to call repeatedly.
(define (sync-history!)
  (if (not (with-mutex *smutex*
             (and (not *syncing?*) (begin (set! *syncing?* #t) #t))))
      0
      (begin
        (let ((n 0))
          (catch #t
            (lambda ()
              (load-names!)
              (set! *lidmap* (load-lid-map!))
              (call-with-values
                  (lambda () (wuzapi-request 'GET "/chat/history?chat_jid=index" #f))
                (lambda (st parsed raw)
                  (unless (upstream-ok? st parsed) (throw 'upstream-failure))
                  (let ((data (and (pair? parsed) (assoc-ref parsed "data"))))
                    (when (pair? data)
                      (for-each
                       (lambda (uentry)
                         (for-each
                          (lambda (centry)
                            (let ((jid (and (pair? centry) (assoc-ref centry "chat_jid"))))
                              (when (string? jid) (import-chat! jid) (set! n (1+ n)))))
                          (->list (cdr uentry))))
                       data))))))
            (lambda (key . args)
              (set! n #f)
              (format #t "whatsappel: history sync error: ~a~%" key)))
          (with-mutex *smutex* (set! *syncing?* #f))
          (format #t "whatsappel: history sync imported ~a chat(s)~%" n)
          n))))

;;; ---------------------------------------------------------------------------
;;; Route handlers
;;; ---------------------------------------------------------------------------

(define (handle-connect)
  ;; Explicit legacy command. Inspect configuration first; unavailable schema
  ;; must never erase subscriptions. Opening the UI does not call this command.
  (parameterize ((wuzapi-response-limit 65536))
    (call-with-values (lambda () (wuzapi-request 'GET "/webhook" #f))
      (lambda (ws wp wr)
        (let ((config (and (upstream-ok? ws wp) (webhook-config wp))))
          (if (not config)
              (json-response 502 '(("error" . "Cannot preserve upstream subscriptions; connect was not attempted")))
              (let* ((configured (filter (lambda (s) (> (string-length s) 0))
                                  (map string-trim-both (string-split *subscribe* #\,))))
                     (events (delete-duplicates (append (cadr config) configured '("Message" "ReadReceipt")))))
                (call-with-values
                    (lambda () (wuzapi-request 'POST "/session/connect"
                                (list (cons "Subscribe" (list->vector events)) (cons "Immediate" #t))))
                  (lambda (status parsed raw)
                    (if (not (upstream-ok? status parsed))
                        (json-response 502 '(("error" . "Connect not confirmed; no automatic retry")))
                        (let ((repair (transport-repair #f)))
                          (json-response 200
                            (append (list (cons "connect_status" status)
                                          (cons "webhook_registered"
                                            (equal? (assoc-ref repair "repair") "registered-not-reachability-tested"))) repair)))))))))))))

(define* (respond-send status parsed text #:optional expected-chat)
  ;; An ID is upstream acceptance, NOT a delivered/read receipt.  Do not reflect
  ;; provider error text or store a successful-looking message on ambiguity.
  (let ((id (upstream-send-id status parsed)))
    (json-response (if id 200 502)
      (if id
          (append
           (list (cons "wuzapi_status" status) (cons "message_id" id)
                 (cons "delivery" "accepted")
                 (cons "data" (list (cons "success" #t)
                                   (cons "data" (list (cons "Id" id))))))
           (if expected-chat
               (list (cons "accepted_chat" expected-chat) (cons "recipient_contract" 1))
               '()))
          (list (cons "wuzapi_status" status) (cons "uncertain" #t)
                (cons "error" "Send not confirmed; check the recipient before retrying"))))))

(define* (handle-send body-str #:optional verified?)
  (let* ((o    (safe-json-parse body-str))
         (to   (and (pair? o) (assoc-ref o "to")))
         (text (and (pair? o) (assoc-ref o "body")))
         ;; Native quoted reply: when reply_id + reply_participant are present,
         ;; build wuzapi's ContextInfo so WhatsApp threads the reply.
         (rid   (and (pair? o) (assoc-ref o "reply_id")))
         (rpart (and (pair? o) (assoc-ref o "reply_participant")))
         (rtext (and (pair? o) (assoc-ref o "reply_text")))
         (ctx   (and (string? rid) (string? rpart)
                     (> (string-length rid) 0) (> (string-length rpart) 0)
                     (list (cons "StanzaID" rid) (cons "Participant" rpart)))))
    (if (or (not (valid-target? to))
            (and verified? (not (message-recipient? to)))
            (not (nonempty-string? text))
            (and (string? text) (> (string-length text) *max-text-length*))
            (not (optional-string? rid 256)) (not (optional-string? rpart 256))
            (not (optional-string? rtext *max-text-length*)))
        (json-response 400 '(("error" . "missing 'to' or 'body'")))
        (call-with-values
            (lambda () (wuzapi-request 'POST "/chat/send/text"
                                       (append (list (cons "Phone" to) (cons "Body" text))
                                               (if ctx
                                                   (list (cons "ContextInfo" ctx)
                                                         (cons "QuotedText" (or rtext "")))
                                                   '()))))
          (lambda (status parsed raw)
            (when (upstream-send-id status parsed)
              (store-outbound! to (filter-false
                                   (list (cons "from" "me") (cons "me" #t)
                                         (cons "text" text)
                                         (cons "id" (upstream-send-id status parsed))
                                         (cons "delivery" "accepted")
                                         (cons "kind" (and (pq-text? text) "pq"))
                                         (cons "reply" (and ctx (or rtext "")))
                                         (cons "ts" (current-ts))))))
            (respond-send status parsed raw (and verified? (normalize-jid to))))))))

;; /send/gif remains an MP4 video alias. Stock wuzapi has no GIF-loop flag.
(define *media-specs*
  '(("image" "/chat/send/image" "Image" "/chat/downloadimage" "image/")
    ("video" "/chat/send/video" "Video" "/chat/downloadvideo" "video/")
    ("gif" "/chat/send/video" "Video" "/chat/downloadvideo" "video/mp4")
    ("audio" "/chat/send/audio" "Audio" "/chat/downloadaudio" "audio/")
    ("document" "/chat/send/document" "Document" "/chat/downloaddocument" "")
    ("sticker" "/chat/send/sticker" "Sticker" "/chat/downloadsticker" "image/webp")))

(define (base64-index c)
  (string-index "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" c))

(define (data-uri-info data)
  ;; Validate in one pass without allocating a decoded copy of large media.
  ;; Return (mime decoded-size), or #f for URLs, malformed/empty base64, etc.
  (and (string? data) (string-prefix? "data:" data)
       (let ((comma (string-index data #\,)))
         (and comma (< comma 160)
              (let ((header (substring data 5 comma))
                    (size (- (string-length data) comma 1)))
                (and (string-suffix? ";base64" header)
                     (> size 0) (zero? (modulo size 4))
                     (let* ((mime (substring header 0 (- (string-length header) 7)))
                            (end (string-length data))
                            (padding (cond ((and (> size 1)
                                                 (string-suffix? "==" data)) 2)
                                           ((string-suffix? "=" data) 1) (else 0)))
                            (decoded (- (* 3 (quotient size 4)) padding)))
                       (and (string-match "^[a-zA-Z0-9!#$&^_.+-]+/[a-zA-Z0-9!#$&^_.+-]+$" mime)
                            (<= decoded *max-media-bytes*)
                            (let loop ((i (1+ comma)))
                              (cond ((>= i (- end padding)) #t)
                                    ((base64-index (string-ref data i)) (loop (1+ i)))
                                    (else #f)))
                            ;; Reject noncanonical padding bits, too.
                            (or (zero? padding)
                                (zero? (modulo (base64-index
                                   (string-ref data (- end padding 1)))
                                   (if (= padding 2) 16 4))))
                            (list (string-downcase mime) decoded)))))))))

(define (valid-filename? filename)
  (and (nonempty-string? filename) (<= (string-length filename) 255)
       (not (member filename '("." "..")))
       (not (string-any (lambda (c) (or (memv c '(#\/ #\\))
                                        (char-iso-control? c))) filename))))

(define (handle-send-media kind body-str)
  (let* ((o (safe-json-parse body-str))
         (spec (assoc kind *media-specs*))
         (to (jget o "to")) (data (jget o "data"))
         (caption (jget o "caption")) (filename (jget o "filename"))
         (info (data-uri-info data)))
    (cond
     ((or (not spec) (not (valid-target? to))
          (not (optional-string? caption *max-text-length*))
          (and filename (not (valid-filename? filename)))
          (and (equal? kind "document") (not (valid-filename? filename))))
      (json-response 400 '(("error" . "invalid recipient, caption or filename"))))
     ((not info)
      (json-response 400 '(("error" . "media must be a nonempty base64 data URI within the media size limit"))))
     ((not (string-prefix? (list-ref spec 4) (car info)))
      (json-response 400 '(("error" . "media MIME does not match kind; send original files as documents (GIF mode requires MP4)"))))
     (else
      (call-with-values
          (lambda () (wuzapi-request 'POST (list-ref spec 1)
             (filter-false (list (cons "Phone" to) (cons (list-ref spec 2) data)
                                 (cons "Caption" caption) (cons "FileName" filename)
                                 (cons "MimeType" (car info))))))
        (lambda (status parsed raw)
          (when (upstream-send-id status parsed)
            (store-outbound! to (filter-false
              (list (cons "from" "me") (cons "me" #t) (cons "kind" kind)
                    (cons "id" (upstream-send-id status parsed))
                                         (cons "delivery" "accepted")
                    (cons "caption" caption) (cons "text" caption)
                    (cons "filename" filename) (cons "mimetype" (car info))
                    (cons "ts" (current-ts))))))
          (respond-send status parsed raw)))))))

(define (valid-download-url? value)
  ;; The bridge only forwards WhatsApp's media metadata, never arbitrary URLs.
  (and (nonempty-string? value) (<= (string-length value) 8192)
       (catch #t
         (lambda ()
           (let* ((uri (string->uri value))
                  (host (and uri (uri-host uri))))
             (and uri (eq? (uri-scheme uri) 'https) (not (uri-userinfo uri))
                  (or (not (uri-port uri)) (= (uri-port uri) 443))
                  (string? host)
                  (let ((host (string-downcase host)))
                    (or (string=? host "mmg.whatsapp.net")
                        (string-suffix? ".whatsapp.net" host))))))
         (lambda _ #f))))

(define (valid-direct-path? value)
  (and (nonempty-string? value) (<= (string-length value) 8192)
       (string-prefix? "/" value) (not (string-prefix? "//" value))
       (not (string-any (lambda (c) (or (char-iso-control? c)
                                        (char=? c #\\))) value))))

(define (handle-download body-str)
  (let* ((o (safe-json-parse body-str)) (kind (jget o "kind"))
         (spec (assoc kind *media-specs*))
         (url (jget o "Url")) (path (jget o "DirectPath"))
         (key (jget o "MediaKey")) (size (jget o "FileLength"))
         (numeric-size (cond ((number? size) size)
                             ((string? size) (string->number size)) (else #f))))
    (if (or (not spec) (not (nonempty-string? key))
            (not (optional-string? key 256))
            (not (optional-string? (jget o "Mimetype") 160))
            (not (optional-string? (jget o "FileSHA256") 256))
            (not (optional-string? (jget o "FileEncSHA256") 256))
            (and (nonempty-string? url) (not (valid-download-url? url)))
            (and (nonempty-string? path) (not (valid-direct-path? path)))
            (not (or (valid-download-url? url) (valid-direct-path? path)))
            (and size (not (and (integer? numeric-size) (exact? numeric-size)
                               (<= 0 numeric-size *max-media-bytes*)))))
        (json-response 400 '(("error" . "invalid media kind, download metadata or size")))
        (relay 'POST (list-ref spec 3)
          (filter-false (list (cons "Url" (and (nonempty-string? url) url))
                             (cons "DirectPath" (and (nonempty-string? path) path))
                             (cons "MediaKey" key) (cons "Mimetype" (jget o "Mimetype"))
                             (cons "FileSHA256" (jget o "FileSHA256"))
                             (cons "FileLength" numeric-size)
                             (cons "FileEncSHA256" (jget o "FileEncSHA256"))))))))

;; --- telega-style actions: react / unreact / delete / mark read --------------
(define (handle-react body-str)
  (let* ((o     (safe-json-parse body-str))
         (to    (and (pair? o) (assoc-ref o "to")))
         (id    (and (pair? o) (assoc-ref o "id")))
         (emoji (or (and (pair? o) (assoc-ref o "emoji")) ""))
         (mine  (and (pair? o) (eq? #t (assoc-ref o "me"))))
         (mid   (if (and mine (string? id)) (string-append "me:" id) id)))
    (if (or (not (valid-target? to)) (not (valid-target? id))
            (not (optional-string? emoji 64)))
        (json-response 400 '(("error" . "missing 'to' or 'id', or invalid emoji")))
        (relay 'POST "/chat/react"
               (list (cons "Phone" to) (cons "Id" mid) (cons "Body" emoji))))))

(define (handle-delete body-str)
  (let* ((o    (safe-json-parse body-str))
         (to   (and (pair? o) (assoc-ref o "to")))
         (id   (and (pair? o) (assoc-ref o "id")))
         (mine (and (pair? o) (eq? #t (assoc-ref o "me"))))
         (mid  (if (and mine (string? id)) (string-append "me:" id) id)))
    (if (or (not (valid-target? to)) (not (valid-target? id)))
        (json-response 400 '(("error" . "missing 'to' or 'id'")))
        (relay 'POST "/chat/delete" (list (cons "Phone" to) (cons "Id" mid))))))

(define (handle-markread body-str)
  (let* ((o  (safe-json-parse body-str))
         (to (and (pair? o) (assoc-ref o "to")))
         (id (and (pair? o) (assoc-ref o "id"))))
    (if (not (valid-target? to))
        (json-response 400 '(("error" . "missing 'to'")))
        (relay 'POST "/chat/markread"
               (list (cons "Id" (if (string? id) (vector id) #()))
                     (cons "ChatPhone" to))))))

;; Ask the sender to re-upload expired media (best-effort, async). wuzapi's
;; whatsappel patch decrypts the response and refreshes the stored directPath;
;; a later /sync picks it up so the download then succeeds.
(define (handle-mediaretry body-str)
  (let* ((o  (safe-json-parse body-str))
         (id (and (pair? o) (assoc-ref o "id"))))
    (if (not (valid-target? id))
        (json-response 400 '(("error" . "missing 'id'")))
        (relay 'POST "/chat/mediaretry" (list (cons "Id" id))))))

(define (handle-message-webhook body-str)
  (let ((rec (extract-message body-str)))
    (cond
     ((not rec) (json-response 400 '(("error" . "invalid webhook JSON"))))
     ;; Subscription/status events must never manufacture an unknown chat.
     ((not (or (equal? (jget rec "type") "Message")
               (and (not (jget rec "type")) (jget rec "id"))))
      (json-response 200 '(("success" . #t) ("ignored" . #t))))
     ((or (not (valid-target? (jget rec "chat" "from")))
          (not (valid-target? (jget rec "id")))
          (not (optional-string? (jget rec "name") 512))
          (not (optional-string? (jget rec "text") *max-text-length*))
          (not (optional-string? (jget rec "caption") *max-text-length*))
          (not (optional-string? (jget rec "reply") *max-text-length*))
          (not (optional-string? (jget rec "from") 256))
          (not (parse-timestamp (jget rec "ts"))))
      (json-response 400 '(("error" . "invalid message fields"))))
     (else
      (let ((stored? (store-inbound! rec)))
        (transport-note-message!)
        (json-response 200 (list (cons "success" #t) (cons "duplicate" (not stored?)))))))))

(define (chat-summaries/locked)
  ;; Rebuild only after mutation, not on each idle poll. Legacy callers retain
  ;; their original array shape; previews are bounded for both read versions.
  (or *read-summary-cache*
      (let ((out '()))
        (hash-for-each
         (lambda (jid msgs)
           (let* ((lastm (and (pair? msgs) (last msgs)))
                  (kind (and lastm (jget lastm "kind")))
                  (text (and lastm (jget lastm "text")))
                  (preview (cond ((equal? kind "pq") "[encrypted]")
                                 ((string? text) text)
                                 ((string? kind) (string-append "[" kind "]"))
                                 (else ""))))
             (set! out (cons (list (cons "jid" jid)
                                   (cons "name" (hash-ref *names* jid jid))
                                   (cons "unread" (hash-ref *unread* jid 0))
                                   (cons "last" (substring preview 0 (min 240 (string-length preview))))
                                   (cons "ts" (or (and lastm (jget lastm "ts")) ""))) out))))
         *chats*)
        (set! *read-summary-cache*
              (list->vector
               (sort out (lambda (a b)
                           (let ((ta (timestamp-value a)) (tb (timestamp-value b)))
                             (if (= ta tb) (string<? (jget a "jid") (jget b "jid")) (> ta tb)))))))
        *read-summary-cache*)))

(define* (handle-chats #:optional query)
  (let ((snapshot
         (with-mutex *smutex*
           (if (not (equal? "2" (form-param query "v")))
               (chat-summaries/locked)
               (let* ((revision (read-revision *read-generation* "chats"))
                      (same? (equal? revision (form-param query "since"))))
                 (append (list (cons "version" 2) (cons "revision" revision)
                               (cons "async_media" #t) (cons "unchanged" same?))
                         (if same? '() (list (cons "chats" (chat-summaries/locked))))))))))
    (json-response 200 snapshot)))

(define (read-window-limit query)
  (let ((raw (form-param query "limit")))
    (if (not raw) 60
        (and (string-match "^[0-9]{1,5}$" raw)
             (let ((n (string->number raw))) (and (<= 1 n 10000) n))))))

(define (handle-chat-messages query)
  (let* ((jid (form-param query "jid"))
         (v2? (equal? "2" (form-param query "v")))
         (limit (if v2? (read-window-limit query) *chat-cap*)))
    (cond
     ((not (valid-target? jid)) (json-response 400 '(("error" . "missing jid"))))
     ((not limit) (json-response 400 '(("error" . "limit must be 1..10000"))))
     (else
      (let ((snapshot
             (with-mutex *smutex*
               (let* ((key (normalize-jid jid)) (msgs (hash-ref *chats* key '()))
                      (total (length msgs)))
                 ;; v2 diagnostics/prefetch is side-effect free unless read=1.
                 ;; Preserve legacy /chat's existing mark-read behavior.
                 (when (and (or (not v2?) (equal? "1" (form-param query "read")))
                            (> (hash-ref *unread* key 0) 0))
                   (hash-set! *unread* key 0)
                   (invalidate-read-state! #f))
                 (if (not v2?) (list->vector msgs)
                     (let* ((rev (read-revision (hash-ref *read-chat-revisions* key 0)
                                               (number->string limit)))
                            (same? (equal? rev (form-param query "since"))))
                       (append
                        (list (cons "version" 2) (cons "revision" rev)
                              (cons "async_media" #t) (cons "unchanged" same?)
                              (cons "total" total) (cons "limit" limit)
                              (cons "has_more" (> total limit)))
                        (if same? '() (list (cons "messages" (list->vector (take-last msgs limit))))))))))))
        (json-response 200 snapshot))))))

;;; Keep slow upstream downloads off the serial HTTP accept loop. At most two
;;; workers/results exist. Send endpoints are never routed through this queue.
;;; A hung upstream occupies one worker, not the main chat-read listener.
(define *media-job-mutex* (make-mutex))
(define *media-jobs* (make-hash-table))
(define *media-job-counter* 0)

(define (prune-media-jobs!)
  (let ((now (car (gettimeofday))) (expired '()))
    (hash-for-each
     (lambda (key job)
       (when (and (vector-ref job 0) (> (- now (vector-ref job 1)) 60))
         (set! expired (cons key expired)))) *media-jobs*)
    (for-each (lambda (key) (hash-remove! *media-jobs* key)) expired)))

(define (start-media-job body)
  (let ((id (with-mutex *media-job-mutex*
              (prune-media-jobs!)
              (and (< (hash-count (const #t) *media-jobs*) 2)
                   (begin
                     (set! *media-job-counter* (1+ *media-job-counter*))
                     (let ((id (read-revision *media-job-counter* "media")))
                       (hash-set! *media-jobs* id (vector #f 0 #f #f)) id))))))
    (if (not id) (json-response 429 '(("error" . "media workers busy; retry explicitly")))
        (begin
          (catch #t
            (lambda ()
              (call-with-new-thread
               (lambda ()
                 (call-with-values
                     (lambda ()
                       (catch #t (lambda () (handle-download body))
                              (lambda _ (json-response 502 '(("error" . "media upstream unavailable"))))))
                   (lambda (response bytes)
                     (with-mutex *media-job-mutex*
                       (hash-set! *media-jobs* id
                                  (vector #t (car (gettimeofday)) response bytes))))))))
            (lambda _
              (with-mutex *media-job-mutex* (hash-remove! *media-jobs* id))
              (throw 'upstream-failure)))
          (json-response 202 (list (cons "job" id)))))))

(define (poll-media-job query)
  (let* ((id (form-param query "id"))
         (job (with-mutex *media-job-mutex*
                (prune-media-jobs!)
                (let ((job (and (string? id) (<= (string-length id) 160)
                                (hash-ref *media-jobs* id #f))))
                  ;; A completed read result is single-consumer. No message is
                  ;; sent or retried; another explicit download remains safe.
                  (when (and job (vector-ref job 0)) (hash-remove! *media-jobs* id))
                  job))))
    (cond ((not job) (json-response 404 '(("error" . "media job expired or unknown"))))
          ((not (vector-ref job 0)) (json-response 202 '(("pending" . #t))))
          (else (values (vector-ref job 2) (vector-ref job 3))))))

(load (string-append (dirname (current-filename)) "/whatsappel-profiles.scm"))

(define (handle-webhook body-str)
  (let* ((o (parse-webhook body-str))
         (kind (jget o "type")))
    (transport-note-event! kind)
    (cond
     ((not o) (json-response 400 '(("error" . "Invalid webhook envelope"))))
     ((equal? kind "ReadReceipt") (handle-receipt o))
     ((member kind '("Presence" "ChatPresence" "Picture" "Connected" "Disconnected"
                      "LoggedOut" "StreamReplaced" "PrivacySettings"))
        (if (> (string-length body-str) 65536)
            (json-response 413 '(("error" . "profile event too large")))
            (let ((result (profile-event! o)))
              (json-response (if (eq? result 'invalid) 400 200)
                             (list (cons "success" (not (eq? result 'invalid)))
                                   (cons "ignored" (eq? result 'ignored)))))))
     (else (handle-message-webhook (scm->json-string o))))))

(define (authed? headers)
  (ct-string=? (assoc-ref headers 'x-whatsappel-token) *bridge-token*))

;;; ---------------------------------------------------------------------------
;;; Dispatch
;;; ---------------------------------------------------------------------------

(define (dispatch request body)
  (let ((method  (request-method request))
        (path    (uri-path (request-uri request)))
        (query   (uri-query (request-uri request)))
        (headers (request-headers request))
        (body*   (if (and (eq? (request-method request) 'POST)
                               (ct-string=? (uri-path (request-uri request)) *hook-path*))
                          "" (body->string body))))
    (cond
     ((and (eq? method 'GET) (string=? path "/health"))
      (json-response 200 '(("status" . "ok") ("service" . "whatsappel") ("read_api" . 2) ("async_media" . #t)
                            ("version" . "3.2.0-rc17") ("transport_api" . 1) ("verified_send" . 1))))
     ((and (eq? method 'POST) (ct-string=? path *hook-path*))
      (handle-webhook (webhook-body-string headers body)))
     ((not (authed? headers))
      (json-response 401 '(("error" . "unauthorized"))))
     ((and (eq? method 'GET) (string=? path "/transport/status")) (handle-transport-status))
     ((and (eq? method 'POST) (string=? path "/transport/repair")) (handle-transport-repair body*))
     ((and (eq? method 'GET) (string=? path "/profile/capabilities")) (profile-capabilities))
     ((and (eq? method 'GET) (string=? path "/profiles")) (handle-profiles query))
     ((and (eq? method 'POST) (string=? path "/profile/request")) (start-profile-job body*))
     ((and (eq? method 'GET) (string=? path "/profile/job")) (poll-profile-job query))
     ((and (eq? method 'POST) (string=? path "/connect"))  (handle-connect))
     ((and (eq? method 'GET)  (string=? path "/status"))   (relay 'GET "/session/status" #f))
     ((and (eq? method 'GET)  (string=? path "/qr"))       (relay 'GET "/session/qr" #f))
     ((and (eq? method 'POST) (string=? path "/logout"))   (relay 'POST "/session/logout" '()))
     ((and (eq? method 'POST) (string=? path "/send/verified")) (handle-send body* #t))
     ((and (eq? method 'POST) (string=? path "/send"))     (handle-send body*))
     ((and (eq? method 'POST) (string=? path "/send/image"))    (handle-send-media "image" body*))
     ((and (eq? method 'POST) (string=? path "/send/video"))    (handle-send-media "video" body*))
     ((and (eq? method 'POST) (string=? path "/send/gif"))      (handle-send-media "gif" body*))
     ((and (eq? method 'POST) (string=? path "/send/audio"))    (handle-send-media "audio" body*))
     ((and (eq? method 'POST) (string=? path "/send/document")) (handle-send-media "document" body*))
     ((and (eq? method 'POST) (string=? path "/send/sticker"))  (handle-send-media "sticker" body*))
     ((and (eq? method 'POST) (string=? path "/download"))
      (if (equal? "1" (form-param query "async")) (start-media-job body*) (handle-download body*)))
     ((and (eq? method 'GET) (string=? path "/media-job")) (poll-media-job query))
     ((and (eq? method 'GET)  (string=? path "/chats"))         (handle-chats query))
     ((and (eq? method 'GET)  (string=? path "/chat"))          (handle-chat-messages query))
     ((and (eq? method 'POST) (string=? path "/react"))    (handle-react body*))
     ((and (eq? method 'POST) (string=? path "/delete"))   (handle-delete body*))
     ((and (eq? method 'POST) (string=? path "/markread")) (handle-markread body*))
     ((and (eq? method 'POST) (string=? path "/mediaretry")) (handle-mediaretry body*))
     ((and (eq? method 'POST) (string=? path "/sync"))
      (let* ((o   (and (> (string-length body*) 0) (safe-json-parse body*)))
             (jid (and (pair? o) (assoc-ref o "jid"))))
        (cond
         ((or (and (> (string-length body*) 0) (not o))
              (and jid (not (valid-target? jid))))
          (json-response 400 '(("error" . "invalid sync request"))))
         ((string? jid)
          (import-chat! (with-mutex *smutex* (hash-ref *rawjid* (normalize-jid jid) jid)))
          (json-response 200 '(("imported" . 1))))
         (else
          (let ((imported (sync-history!)))
            (if imported (json-response 200 (list (cons "imported" imported)))
                (json-response 502 '(("error" . "history upstream unavailable")))))))))
     (else (json-response 404 '(("error" . "not found")))))))

(define (handler request body)
  (catch #t
    (lambda ()
      (let ((size (cond ((bytevector? body) (bytevector-length body))
                        ((string? body) (bytevector-length (string->utf8 body)))
                        (else 0))))
        ;; Guile's HTTP server has already buffered the body at this stage.
        ;; Enforce an ingress body/timeout limit in front of public deployments.
        (if (> size *max-body-bytes*)
            (json-response 413 '(("error" . "request exceeds body limit")))
            (dispatch request body))))
    ;; Malformed JSON/UTF-8/metadata should never crash a running listener.
    (lambda (key . args)
      (if (eq? key 'upstream-failure)
          (json-response 502 '(("error" . "history upstream unavailable")))
          (json-response 400 '(("error" . "invalid request")))))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(define (main)
  (format #t "whatsappel: bridge on http://~a:~a -> wuzapi ~a~%"
          *host* *port* *wuzapi-base*)
  (format #t "whatsappel: webhook configured (credential redacted)~%")
  ;; Import existing chats/history from wuzapi in the background (non-fatal),
  ;; so the chat list is populated on startup without waiting for live traffic.
  (call-with-new-thread
   (lambda ()
     (sleep 3)
     (catch #t (lambda () (sync-history!))
       (lambda (k . a) (format #t "whatsappel: initial sync failed: ~a~%" k)))))
  (run-server handler 'http (list #:host *host* #:port *port*)))

;; Load definitions for tests/static checks without starting a listener.
(unless (member "--check-load" (command-line)) (main))
