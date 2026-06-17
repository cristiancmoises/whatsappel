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
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(define (env name default) (or (getenv name) default))

(define (require-env name)
  (or (getenv name)
      (begin
        (format (current-error-port)
                "whatsappel: missing required environment variable ~a~%" name)
        (exit 2))))

(define *host*          (env "WHATSAPPEL_HOST" "127.0.0.1"))
(define *port*          (string->number (env "WHATSAPPEL_PORT" "7337")))
(define *bridge-token*  (require-env "WHATSAPPEL_TOKEN"))
(define *wuzapi-base*   (env "WUZAPI_BASE_URL" "http://127.0.0.1:8080"))
(define *wuzapi-token*  (require-env "WUZAPI_TOKEN"))
(define *wuzapi-hdr*    (string->symbol (string-downcase (env "WUZAPI_TOKEN_HEADER" "Token"))))
(define *subscribe*     (env "WHATSAPPEL_SUBSCRIBE" "Message"))
(define *chat-cap*      (string->number (env "WHATSAPPEL_CHAT_CAP" "500")))
(define *public-url*    (env "WHATSAPPEL_PUBLIC_URL"
                             (format #f "http://~a:~a" *host* *port*)))
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

(define (safe-json-parse s)
  (catch #t (lambda () (json-string->scm s)) (lambda _ #f)))

;; First present key from an alist (string keys); tries each variant.
(define (jget obj . keys)
  (and (pair? obj)
       (let loop ((ks keys))
         (and (pair? ks)
              (or (assoc-ref obj (car ks)) (loop (cdr ks)))))))

;; Minimal x-www-form-urlencoded decoding (fallback webhook payloads + queries).
(define (hexval c)
  (cond ((char<=? #\0 c #\9) (- (char->integer c) 48))
        ((char<=? #\a c #\f) (+ 10 (- (char->integer c) 97)))
        ((char<=? #\A c #\F) (+ 10 (- (char->integer c) 65)))
        (else 0)))

(define (url-decode s)
  (let ((out (open-output-string)) (n (string-length s)))
    (let loop ((i 0))
      (if (>= i n)
          (get-output-string out)
          (let ((c (string-ref s i)))
            (cond ((char=? c #\+) (write-char #\space out) (loop (1+ i)))
                  ((and (char=? c #\%) (< (+ i 2) n))
                   (write-char (integer->char (+ (* 16 (hexval (string-ref s (1+ i))))
                                                 (hexval (string-ref s (+ i 2)))))
                               out)
                   (loop (+ i 3)))
                  (else (write-char c out) (loop (1+ i)))))))))

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
        ((string-contains s "@g.us") s)
        ((string-index s #\@) => (lambda (i) (substring s 0 i)))
        (else s)))

(define (current-ts) (number->string (current-time)))

;; Recognise the post-quantum envelope transport tag.
(define (pq-text? s) (and (string? s) (string-prefix? "WAPQ1:" s)))

;;; ---------------------------------------------------------------------------
;;; wuzapi REST client
;;; ---------------------------------------------------------------------------

;; Returns (values status parsed-or-#f raw-string).
(define (wuzapi-request method path body-obj)
  (let* ((uri  (string-append *wuzapi-base* path))
         (body (and body-obj (string->utf8 (scm->json-string body-obj))))
         (hdrs (append
                (list (cons *wuzapi-hdr* *wuzapi-token*))
                (if body
                    (list (cons 'content-type '(application/json (charset . "utf-8"))))
                    '()))))
    (call-with-values
        (lambda ()
          (http-request uri
                        #:method method
                        #:headers hdrs
                        #:body body
                        #:decode-body? #f
                        #:streaming? #f))
      (lambda (resp rbody)
        (let* ((status (response-code resp))
               (text   (body->string rbody))
               (parsed (and (> (string-length text) 0) (safe-json-parse text))))
          (values status parsed text))))))

(define (relay method path body-obj)
  (call-with-values (lambda () (wuzapi-request method path body-obj))
    (lambda (status parsed text)
      (json-response (if (and (>= status 200) (< status 300)) 200 502)
                     (list (cons "wuzapi_status" status)
                           (cons "data" (or parsed text)))))))

;;; ---------------------------------------------------------------------------
;;; Per-chat message store
;;; ---------------------------------------------------------------------------

(define *chats*  (make-hash-table))   ; jid -> list of message-alists (oldest first)
(define *unread* (make-hash-table))   ; jid -> integer
(define *names*  (make-hash-table))   ; jid -> push name
(define *smutex* (make-mutex))

(define (store-inbound! rec)
  (with-mutex *smutex*
    (let* ((chat (normalize-jid (or (assoc-ref rec "chat")
                                    (assoc-ref rec "from") "unknown")))
           (cur  (hash-ref *chats* chat '())))
      (hash-set! *chats* chat (take-last (append cur (list rec)) *chat-cap*))
      (hash-set! *unread* chat (1+ (hash-ref *unread* chat 0)))
      (let ((nm (assoc-ref rec "name"))) (when nm (hash-set! *names* chat nm))))))

(define (store-outbound! chat rec)
  (with-mutex *smutex*
    (let* ((key (normalize-jid chat))
           (cur (hash-ref *chats* key '())))
      (hash-set! *chats* key (take-last (append cur (list rec)) *chat-cap*)))))

;; Detect a media sub-message. Returns (values kind-string media-alist caption).
(define (detect-media msg)
  (let loop ((specs '(("imageMessage" . "image")    ("ImageMessage" . "image")
                      ("videoMessage" . "video")    ("VideoMessage" . "video")
                      ("audioMessage" . "audio")    ("AudioMessage" . "audio")
                      ("documentMessage" . "document") ("DocumentMessage" . "document")
                      ("stickerMessage" . "sticker") ("StickerMessage" . "sticker"))))
    (if (null? specs)
        (values #f #f #f)
        (let ((mm (assoc-ref msg (caar specs))))
          (if (pair? mm)
              (values (cdar specs) mm
                      (or (assoc-ref mm "caption") (assoc-ref mm "Caption")))
              (loop (cdr specs)))))))

;; Extract wuzapi download fields from a media sub-message (defensive casing).
(define (media-dl-fields mm)
  (filter-false
   (list (cons "Url"           (jget mm "url" "URL" "Url"))
         (cons "MediaKey"      (jget mm "mediaKey" "MediaKey"))
         (cons "Mimetype"      (jget mm "mimetype" "Mimetype" "mimeType"))
         (cons "FileSHA256"    (jget mm "fileSha256" "FileSHA256" "fileSHA256"))
         (cons "FileLength"    (jget mm "fileLength" "FileLength"))
         (cons "FileEncSHA256" (jget mm "fileEncSha256" "FileEncSHA256" "fileEncSHA256")))))

;; Parse a webhook payload (JSON or form jsonData) into a message record.
;; Always preserves the raw body.
(define (extract-message raw)
  (let ((o (or (safe-json-parse raw)
               (let ((jd (form-param raw "jsonData")))
                 (and jd (safe-json-parse jd))))))
    (if (not (pair? o))
        (list (cons "raw" raw))
        (let* ((ev     (assoc-ref o "event"))
               (info   (and (pair? ev) (assoc-ref ev "Info")))
               (msg    (and (pair? ev) (assoc-ref ev "Message")))
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
                     (cons "chat" chat)
                     (cons "name" name)
                     (cons "id"   id)
                     (cons "ts"   ts)
                     (cons "text" text)
                     (cons "kind" (or kind (and (pq-text? text) "pq")))
                     (cons "caption" cap)
                     (cons "media" (and mm (media-dl-fields mm)))
                     (cons "raw"  raw)))))))))

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

(define *history-limit* (string->number (env "WHATSAPPEL_HISTORY" "200")))
(define *syncing?* #f)

;; Optional: wuzapi's whatsmeow store (main.db). When set, we read its
;; `whatsmeow_lid_map' (lid -> phone) read-only to put a name (or at least a real
;; phone number) on chats addressed by WhatsApp's anonymous @lid id. Empty = off.
(define *lidmap-db* (env "WHATSAPPEL_LIDMAP_DB" ""))
(define *lidmap*    (make-hash-table))   ; lid-number -> phone-number

(define (->list v)
  (cond ((vector? v) (vector->list v)) ((list? v) v) (else '())))

;; Read lid->phone from wuzapi's whatsmeow_lid_map via the sqlite3 CLI (read-only).
(define (load-lid-map!)
  (let ((h (make-hash-table)))
    (when (and (string? *lidmap-db*) (> (string-length *lidmap-db*) 0)
               (file-exists? *lidmap-db*))
      (catch #t
        (lambda ()
          (let* ((q   "SELECT lid, pn FROM whatsmeow_lid_map;")
                 (cmd (string-append "sqlite3 -readonly -noheader -separator '|' '"
                                     *lidmap-db* "' \"" q "\" 2>/dev/null"))
                 (port (open-input-pipe cmd)))
            (let loop ()
              (let ((line (read-line port)))
                (unless (eof-object? line)
                  (let ((bar (string-index line #\|)))
                    (when (and bar (> bar 0))
                      (hash-set! h (substring line 0 bar) (substring line (1+ bar)))))
                  (loop))))
            (close-pipe port)))
        (lambda (k . a)
          (format #t "whatsappel: lid-map load failed: ~a ~a~%" k a))))
    (format #t "whatsappel: lid-map entries: ~a~%" (hash-count (const #t) h))
    h))

;; Percent-encode a chat jid for use in a query string ("@" -> "%40", etc.).
(define (uri-encode s)
  (string-concatenate
   (map (lambda (c)
          (if (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_ #\.)))
              (string c)
              (format #f "%~2,'0X" (char->integer c))))
        (string->list s))))

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
                 (hash-set! *names* (normalize-jid jid) nm))))
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
               (hash-set! *names* (normalize-jid jid) nm))))
         (->list groups))))))

;; Build a store record from one history row.
(define (history-row->rec row)
  (let* ((dj     (assoc-ref row "data_json"))
         (info   (and (string? dj)
                      (let ((p (safe-json-parse dj))) (and (pair? p) (assoc-ref p "Info")))))
         (fromme (and (pair? info) (eq? #t (assoc-ref info "IsFromMe"))))
         (name   (and (pair? info) (assoc-ref info "PushName")))
         (mtype  (assoc-ref row "message_type"))
         (text   (assoc-ref row "text_content"))
         (ts     (or (and (pair? info) (assoc-ref info "Timestamp"))
                     (assoc-ref row "timestamp"))))
    (filter-false
     (list (cons "from" (if fromme "me" (assoc-ref row "sender_jid")))
           (cons "me"   (and fromme #t))
           (cons "chat" (assoc-ref row "chat_jid"))
           (cons "name" (and (string? name) (> (string-length name) 0) name))
           (cons "id"   (assoc-ref row "message_id"))
           (cons "ts"   ts)
           (cons "text" text)
           (cons "kind" (cond ((pq-text? text) "pq")
                              ((and (string? mtype) (not (string=? mtype "text"))) mtype)
                              (else #f)))
           (cons "caption" (and (string? mtype) (not (string=? mtype "text")) text))))))

(define (import-chat! jid)
  (call-with-values
      (lambda ()
        (wuzapi-request 'GET (string-append "/chat/history?chat_jid=" (uri-encode jid)
                                            "&limit=" (number->string *history-limit*)) #f))
    (lambda (st parsed raw)
      (let* ((rows (->list (and (pair? parsed) (assoc-ref parsed "data"))))
             (recs (map history-row->rec rows))
             (good (filter (lambda (r) (assoc-ref r "ts")) recs))
             (sorted (sort good (lambda (a b)
                                  (string<? (or (assoc-ref a "ts") "")
                                            (or (assoc-ref b "ts") ""))))))
        (when (pair? sorted)
          (with-mutex *smutex*
            (let ((key (normalize-jid jid)))
              (hash-set! *chats* key (take-last sorted *chat-cap*))
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
                (let ((phone (hash-ref *lidmap* key #f)))
                  (when (string? phone)
                    (hash-set! *names* key
                               (or (hash-ref *names* phone #f)
                                   (string-append "+" phone)))))))))))))

;; Pull every chat's history from wuzapi into the store. Safe to call repeatedly.
(define (sync-history!)
  (if *syncing?*
      0
      (begin
        (set! *syncing?* #t)
        (let ((n 0))
          (catch #t
            (lambda ()
              (load-names!)
              (set! *lidmap* (load-lid-map!))
              (call-with-values
                  (lambda () (wuzapi-request 'GET "/chat/history?chat_jid=index" #f))
                (lambda (st parsed raw)
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
              (format #t "whatsappel: history sync error: ~a ~a~%" key args)))
          (set! *syncing?* #f)
          (format #t "whatsappel: history sync imported ~a chat(s)~%" n)
          n))))

;;; ---------------------------------------------------------------------------
;;; Route handlers
;;; ---------------------------------------------------------------------------

(define (handle-connect)
  (let ((events (filter (lambda (s) (> (string-length s) 0))
                        (map string-trim-both (string-split *subscribe* #\,)))))
    (call-with-values
        (lambda () (wuzapi-request 'POST "/session/connect"
                                   (list (cons "Subscribe" (list->vector events))
                                         (cons "Immediate" #t))))
      (lambda (cstatus cparsed ctext)
        (call-with-values
            (lambda () (wuzapi-request 'POST "/webhook"
                                       (list (cons "webhookURL" *hook-url*))))
          (lambda (wstatus wparsed wtext)
            (json-response 200
                           (list (cons "connect_status" cstatus)
                                 (cons "connect" (or cparsed ctext))
                                 (cons "webhook_registered"
                                       (and (>= wstatus 200) (< wstatus 300)))
                                 (cons "hook_url" *hook-url*)))))))))

(define (respond-send status parsed text)
  (json-response (if (and (>= status 200) (< status 300)) 200 502)
                 (list (cons "wuzapi_status" status) (cons "data" (or parsed text)))))

(define (handle-send body-str)
  (let* ((o    (safe-json-parse body-str))
         (to   (and (pair? o) (assoc-ref o "to")))
         (text (and (pair? o) (assoc-ref o "body"))))
    (if (or (not (string? to)) (not (string? text))
            (= 0 (string-length to)) (= 0 (string-length text)))
        (json-response 400 '(("error" . "missing 'to' or 'body'")))
        (call-with-values
            (lambda () (wuzapi-request 'POST "/chat/send/text"
                                       (list (cons "Phone" to) (cons "Body" text))))
          (lambda (status parsed raw)
            (when (and (>= status 200) (< status 300))
              (store-outbound! to (filter-false
                                   (list (cons "from" "me") (cons "me" #t)
                                         (cons "text" text)
                                         (cons "kind" (and (pq-text? text) "pq"))
                                         (cons "ts" (current-ts))))))
            (respond-send status parsed raw))))))

;; kind: image | video | gif | audio | document | sticker
(define (handle-send-media kind body-str)
  (let* ((o        (safe-json-parse body-str))
         (to       (and (pair? o) (assoc-ref o "to")))
         (data     (and (pair? o) (assoc-ref o "data")))
         (caption  (and (pair? o) (assoc-ref o "caption")))
         (filename (and (pair? o) (assoc-ref o "filename"))))
    (if (or (not (string? to)) (not (string? data)))
        (json-response 400 '(("error" . "missing 'to' or 'data'")))
        (let ((wpath (cond ((string=? kind "image")    "/chat/send/image")
                           ((string=? kind "video")    "/chat/send/video")
                           ((string=? kind "gif")      "/chat/send/video")
                           ((string=? kind "audio")    "/chat/send/audio")
                           ((string=? kind "document") "/chat/send/document")
                           ((string=? kind "sticker")  "/chat/send/sticker")
                           (else #f)))
              (field (cond ((string=? kind "image")    "Image")
                           ((string=? kind "video")    "Video")
                           ((string=? kind "gif")      "Video")
                           ((string=? kind "audio")    "Audio")
                           ((string=? kind "document") "Document")
                           ((string=? kind "sticker")  "Sticker")
                           (else #f))))
          (if (not wpath)
              (json-response 400 '(("error" . "unknown media kind")))
              (call-with-values
                  (lambda () (wuzapi-request 'POST wpath
                                             (filter-false
                                              (list (cons "Phone" to)
                                                    (cons field data)
                                                    (cons "Caption" caption)
                                                    (cons "FileName" filename)))))
                (lambda (status parsed raw)
                  (when (and (>= status 200) (< status 300))
                    (store-outbound! to (filter-false
                                         (list (cons "from" "me") (cons "me" #t)
                                               (cons "kind" kind)
                                               (cons "caption" caption)
                                               (cons "text" (and caption caption))
                                               (cons "ts" (current-ts))))))
                  (respond-send status parsed raw))))))))

(define (handle-download body-str)
  (let* ((o    (safe-json-parse body-str))
         (kind (and (pair? o) (assoc-ref o "kind"))))
    (if (not (pair? o))
        (json-response 400 '(("error" . "bad body")))
        (let ((wpath (cond ((equal? kind "video")    "/chat/downloadvideo")
                           ((equal? kind "audio")    "/chat/downloadaudio")
                           ((equal? kind "document") "/chat/downloaddocument")
                           (else "/chat/downloadimage"))))
          (relay 'POST wpath
                 (filter-false
                  (list (cons "Url"           (assoc-ref o "Url"))
                        (cons "MediaKey"      (assoc-ref o "MediaKey"))
                        (cons "Mimetype"      (assoc-ref o "Mimetype"))
                        (cons "FileSHA256"    (assoc-ref o "FileSHA256"))
                        (cons "FileLength"    (assoc-ref o "FileLength"))
                        (cons "FileEncSHA256" (assoc-ref o "FileEncSHA256")))))))))

(define (handle-webhook body-str)
  (store-inbound! (extract-message body-str))
  (json-response 200 '(("success" . #t))))

(define (handle-chats)
  (with-mutex *smutex*
    (let ((out '()))
      (hash-for-each
       (lambda (jid msgs)
         (let* ((lastm (if (null? msgs) #f (last msgs)))
                (lt    (and lastm
                            (let ((k (assoc-ref lastm "kind")))
                              (cond ((equal? k "pq") "[encrypted]")
                                    ((assoc-ref lastm "text"))
                                    (k (string-append "[" k "]"))
                                    (else #f)))))
                (lts   (and lastm (assoc-ref lastm "ts"))))
           (set! out (cons (list (cons "jid" jid)
                                 (cons "name" (hash-ref *names* jid jid))
                                 (cons "unread" (hash-ref *unread* jid 0))
                                 (cons "last" (or lt ""))
                                 (cons "ts" (or lts "")))
                           out))))
       *chats*)
      (json-response 200 (list->vector out)))))

(define (handle-chat-messages query)
  (let ((jid (form-param query "jid")))
    (if (not jid)
        (json-response 400 '(("error" . "missing jid")))
        (with-mutex *smutex*
          (let ((msgs (hash-ref *chats* jid '())))
            (hash-set! *unread* jid 0)
            (json-response 200 (list->vector msgs)))))))

(define (authed? headers)
  (ct-string=? (assoc-ref headers 'x-whatsappel-token) *bridge-token*))

;;; ---------------------------------------------------------------------------
;;; Dispatch
;;; ---------------------------------------------------------------------------

(define (handler request body)
  (let ((method  (request-method request))
        (path    (uri-path (request-uri request)))
        (query   (uri-query (request-uri request)))
        (headers (request-headers request))
        (body*   (body->string body)))
    (cond
     ((and (eq? method 'GET) (string=? path "/health"))
      (json-response 200 '(("status" . "ok") ("service" . "whatsappel"))))
     ((and (eq? method 'POST) (ct-string=? path *hook-path*))
      (handle-webhook body*))
     ((not (authed? headers))
      (json-response 401 '(("error" . "unauthorized"))))
     ((and (eq? method 'POST) (string=? path "/connect"))  (handle-connect))
     ((and (eq? method 'GET)  (string=? path "/status"))   (relay 'GET "/session/status" #f))
     ((and (eq? method 'GET)  (string=? path "/qr"))       (relay 'GET "/session/qr" #f))
     ((and (eq? method 'POST) (string=? path "/logout"))   (relay 'POST "/session/logout" '()))
     ((and (eq? method 'POST) (string=? path "/send"))     (handle-send body*))
     ((and (eq? method 'POST) (string=? path "/send/image"))    (handle-send-media "image" body*))
     ((and (eq? method 'POST) (string=? path "/send/video"))    (handle-send-media "video" body*))
     ((and (eq? method 'POST) (string=? path "/send/gif"))      (handle-send-media "gif" body*))
     ((and (eq? method 'POST) (string=? path "/send/audio"))    (handle-send-media "audio" body*))
     ((and (eq? method 'POST) (string=? path "/send/document")) (handle-send-media "document" body*))
     ((and (eq? method 'POST) (string=? path "/send/sticker"))  (handle-send-media "sticker" body*))
     ((and (eq? method 'POST) (string=? path "/download"))      (handle-download body*))
     ((and (eq? method 'GET)  (string=? path "/chats"))         (handle-chats))
     ((and (eq? method 'GET)  (string=? path "/chat"))          (handle-chat-messages query))
     ((and (eq? method 'POST) (string=? path "/sync"))
      (json-response 200 (list (cons "imported" (sync-history!)))))
     (else (json-response 404 '(("error" . "not found")))))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(define (main)
  (format #t "whatsappel: bridge on http://~a:~a -> wuzapi ~a~%"
          *host* *port* *wuzapi-base*)
  (format #t "whatsappel: inbound webhook ~a~%" *hook-url*)
  ;; Import existing chats/history from wuzapi in the background (non-fatal),
  ;; so the chat list is populated on startup without waiting for live traffic.
  (call-with-new-thread
   (lambda ()
     (sleep 3)
     (catch #t (lambda () (sync-history!))
       (lambda (k . a) (format #t "whatsappel: initial sync failed: ~a~%" k)))))
  (run-server handler 'http (list #:host *host* #:port *port*)))

(main)
