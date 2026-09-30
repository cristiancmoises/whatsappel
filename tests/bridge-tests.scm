;;; Bridge regression tests: guile --no-auto-compile tests/bridge-tests.scm
;;; SPDX-License-Identifier: AGPL-3.0-only
(use-modules (srfi srfi-64))
(setenv "WHATSAPPEL_TOKEN" "unit-test-bridge-token-000000")
(setenv "WUZAPI_TOKEN" "unit-test-upstream-token")
(set-program-arguments (append (command-line) '("--check-load")))
(load "../whatsappel.scm")

(test-begin "bridge")
(define (response-status thunk)
  (call-with-values thunk (lambda (response body) (response-code response))))
(define (reset-store!)
  (for-each hash-clear! (list *chats* *unread* *names* *rawjid*)))
(define (rec id chat ts . extra)
  (append (list (cons "id" id) (cons "chat" chat) (cons "ts" ts)) extra))

(test-assert "equal tokens authenticate" (ct-string=? "abc123" "abc123"))
(test-assert "first differing byte rejected" (not (ct-string=? "abc123" "zbc123")))
(test-assert "last differing byte rejected" (not (ct-string=? "abc123" "abc124")))
(test-assert "non-string credentials rejected" (not (ct-string=? #f "token")))
(test-assert "Unicode length compares bytes" (not (ct-string=? "é" "e")))
(test-assert "array not a request object" (not (safe-json-parse "[1,2]")))
(test-assert "scalar not a request object" (not (safe-json-parse "42")))
(test-assert "invalid JSON rejected" (not (safe-json-parse "{broken")))
(test-assert "empty object valid" (json-object? (safe-json-parse "{}")))
(test-equal "form decoding preserves UTF-8" "ação + café" (url-decode "a%C3%A7%C3%A3o+%2B+caf%C3%A9"))
(test-equal "JID query encoding roundtrips" "ação@g.us" (url-decode (uri-encode "ação@g.us")))
(test-equal "phone JID normalization" "5511999" (normalize-jid "5511999@s.whatsapp.net"))
(test-equal "LID namespace kept distinct" "5511999@lid" (normalize-jid "5511999@lid"))
(test-equal "group JID kept intact" "123-456@g.us" (normalize-jid "123-456@g.us"))
(for-each (lambda (v) (test-assert (format #f "invalid timestamp ~s rejected" v)
                                  (not (parse-timestamp v))))
          (list "1+i" "+nan.0" "+inf.0" -1 "-1" '(1 2) "bad"))
(test-equal "numeric timestamps order numerically" '("a" "b")
  (map record-id (sort (list (rec "b" "1" "10") (rec "a" "1" "9")) record-before?)))
(test-equal "RFC3339 offsets normalize" (parse-timestamp "2026-09-09T15:00:00Z")
  (parse-timestamp "2026-09-09T12:00:00.123-03:00"))
(test-equal "base64 decoded size and MIME" '("image/png" 1) (data-uri-info "data:image/png;base64,AA=="))
(for-each (lambda (v) (test-assert (format #f "malformed media ~s" v) (not (data-uri-info v))))
          '("http://localhost/private" "data:image/png;base64," "data:image/png;base64,A==="
            "data:image/png;base64,AB==" "data:image/png;base64,AAA" "data:image/png;base64,AA?="
            "data:invalid;base64,AAAA"))
(let ((old *max-media-bytes*))
  (set! *max-media-bytes* 1)
  (test-assert "decoded media limit enforced before decode" (not (data-uri-info "data:image/png;base64,AAAA")))
  (set! *max-media-bytes* old))
(test-assert "WhatsApp CDN accepted" (valid-download-url? "https://mmg.whatsapp.net/file"))
(test-assert "CDN variant accepted" (valid-download-url? "https://mmg-fna.whatsapp.net/file"))
(for-each (lambda (v) (test-assert (format #f "unsafe download URL ~s" v) (not (valid-download-url? v))))
          '("http://mmg.whatsapp.net/file" "https://mmg.whatsapp.net.evil.example/file"
            "https://localhost/private" "https://user:password@mmg.whatsapp.net/file"
            "https://mmg.whatsapp.net:444/file" "file:///etc/passwd"))
(test-assert "relative CDN path accepted" (valid-direct-path? "/v/t62.7118-24/file?x=y"))
(test-assert "network path rejected" (not (valid-direct-path? "//localhost/file")))
(for-each (lambda (v) (test-assert (format #f "unsafe filename ~s" v) (not (valid-filename? v))))
          '("../photo.png" ".." "a/b.pdf" "C:\\secret" ""))
(test-assert "Unicode document filename" (valid-filename? "relatório.pdf"))
(test-equal "unknown download kind rejected" 400
  (response-status (lambda () (handle-download "{\"kind\":\"bogus\"}"))))
(test-equal "image MIME mismatch rejected" 400
  (response-status (lambda () (handle-send-media "image" "{\"to\":\"123\",\"data\":\"data:audio/ogg;base64,AA==\"}"))))
(test-equal "raw GIF rejected for MP4 playback route" 400
  (response-status (lambda () (handle-send-media "gif" "{\"to\":\"123\",\"data\":\"data:image/gif;base64,AA==\"}"))))
(test-equal "document requires filename" 400
  (response-status (lambda () (handle-send-media "document" "{\"to\":\"123\",\"data\":\"data:application/pdf;base64,AA==\"}"))))
(test-equal "react numeric ID cannot throw" 400
  (response-status (lambda () (handle-react "{\"to\":\"123\",\"id\":42,\"me\":true}"))))
(test-equal "delete numeric ID cannot throw" 400
  (response-status (lambda () (handle-delete "{\"to\":\"123\",\"id\":42,\"me\":true}"))))
(test-assert "upstream application failure propagates" (not (upstream-ok? 200 '(("success" . #f)))))
(test-assert "upstream HTTP failure propagates" (not (upstream-ok? 500 '(("success" . #t)))))

(reset-store!)
(store-inbound! (rec "a" "123@s.whatsapp.net" 9 '("text" . "hello")))
(store-inbound! (rec "a" "123@s.whatsapp.net" 9 '("text" . "hello")))
(test-equal "duplicate webhook adds no record" 1 (length (hash-ref *chats* "123")))
(test-equal "duplicate webhook adds no unread" 1 (hash-ref *unread* "123"))
(store-inbound! (rec "own" "123@s.whatsapp.net" 10 '("me" . #t)))
(test-equal "own echo adds no unread" 1 (hash-ref *unread* "123"))
(store-outbound! "123" (rec "echo" "123" 11 '("me" . #t) '("text" . "sent")))
(store-inbound! (rec "echo" "123" 11 '("me" . #t)))
(test-equal "outbound echo deduplicated by ID" 3 (length (hash-ref *chats* "123")))
(test-equal "duplicate enrichment retains old text" "sent" (jget (last (hash-ref *chats* "123")) "text"))
(test-equal "history merge retains live and adds older record" '("historic" "a" "own" "echo")
  (map record-id (merge-records (hash-ref *chats* "123") (list (rec "historic" "123" 1)))))
(test-equal "history merge deduplicates ID" 3
  (length (merge-records (hash-ref *chats* "123") (list (rec "a" "123" 9)))))
(test-equal "full phone JID reads normalized chat" 200
  (response-status (lambda () (handle-chat-messages "jid=123%40s.whatsapp.net"))))
(test-equal "read resets existing chat unread" 0 (hash-ref *unread* "123"))
(let ((old *chat-cap*))
  (set! *chat-cap* 2)
  (store-inbound! (rec "latest" "123" 20))
  (test-equal "per-chat cap retains newest records" '("echo" "latest") (map record-id (hash-ref *chats* "123")))
  (set! *chat-cap* old))
(let ((old *max-chats*))
  (set! *max-chats* 2)
  (store-inbound! (rec "x" "456" 21))
  (store-inbound! (rec "y" "789" 22))
  (test-equal "total chat count bounded" 2 (hash-count (const #t) *chats*))
  (test-assert "least active chat and unread metadata evicted" (and (not (hash-ref *chats* "123")) (not (hash-ref *unread* "123"))))
  (set! *max-chats* old))
(reset-store!)
(test-equal "status webhook ignored" 200
  (response-status (lambda () (handle-webhook "{\"type\":\"Connected\",\"event\":{}}"))))
(test-equal "status webhook creates no unknown chat" 0 (hash-count (const #t) *chats*))
(test-equal "invalid webhook rejected" 400 (response-status (lambda () (handle-webhook "bad"))))
(let* ((event '(("type" . "Message") ("event" . (("Info" . (("ID" . "m") ("Chat" . "123") ("Timestamp" . "+nan.0"))) ("Message" . (("conversation" . "hi")))))))
       (json (scm->json-string event)))
  (test-equal "poison timestamp rejected before store" 400 (response-status (lambda () (handle-webhook json))))
  (test-equal "poison event left store empty" 0 (hash-count (const #t) *chats*)))
(test-equal "reading absent chat does not retain unread metadata" 200
  (response-status (lambda () (handle-chat-messages "jid=nonexistent"))))
(test-equal "absent chat read creates no auxiliary entry" 0 (hash-count (const #t) *unread*))
(test-assert "non-JSON upstream success is rejected" (not (upstream-ok? 200 #f)))
(test-assert "bodyless upstream 204 remains successful" (upstream-ok? 204 #f))
;; SRFI-64's named test-error form has THREE arguments.  With two, the
;; descriptive string was interpreted as an exception matcher, not a name.
;; Keep the actual production guard; test both rejection and valid boundaries.
(let ((previous (getenv "WHATSAPPEL_TEST_INTEGER")))
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (setenv "WHATSAPPEL_TEST_INTEGER" "0")
      (test-error "zero configured cap fails startup validation" #t
        (env-integer "WHATSAPPEL_TEST_INTEGER" "500" 1 10000))
      (for-each
        (lambda (value)
          (setenv "WHATSAPPEL_TEST_INTEGER" value)
          (test-error (format #f "invalid configured cap ~s rejected" value) #t
            (env-integer "WHATSAPPEL_TEST_INTEGER" "500" 1 10000)))
        '("-1" "10001" "1.0" "1/2" "1+i" "+nan.0" "+inf.0" "bad"))
      ;; An unrelated exception must not stand in for configuration validation.
      (test-assert "configuration rejection is the expected Guile error"
        (catch 'misc-error
          (lambda () (env-integer "WHATSAPPEL_TEST_INTEGER" "500" 1 10000) #f)
          (lambda args #t)))
      (for-each
        (lambda (value)
          (setenv "WHATSAPPEL_TEST_INTEGER" (number->string value))
          (test-equal (format #f "valid configured cap ~a accepted" value) value
            (env-integer "WHATSAPPEL_TEST_INTEGER" "500" 1 10000)))
        '(1 500 10000))
      (unsetenv "WHATSAPPEL_TEST_INTEGER")
      (test-equal "unset configured cap uses validated default" 500
        (env-integer "WHATSAPPEL_TEST_INTEGER" "500" 1 10000)))
    (lambda ()
      (if previous (setenv "WHATSAPPEL_TEST_INTEGER" previous)
          (unsetenv "WHATSAPPEL_TEST_INTEGER")))))
;; RC16: explicit own-history rows do not depend on optional data_json payloads.
(let* ((row '(("message_id" . "own-history-fixture") ("sender_jid" . "me")
              ("chat_jid" . "123456789@lid") ("timestamp" . "1750000000")
              ("data_json" . "") ("message_type" . "text") ("text_content" . "fixture")))
       (record (history-row->rec row)))
  (test-equal "own history row remains own without embedded metadata" #t (jget record "me"))
  (test-equal "own history row preserves recipient namespace" "123456789@lid" (jget record "chat"))
  (set-cdr! (assoc "data_json" row) "{\"Info\":{\"IsFromMe\":false}}")
  (test-assert "explicit inbound metadata overrides sender fallback" (not (jget (history-row->rec row) "me")))
  (set-cdr! (assoc "sender_jid" row) "123456789")
  (set-cdr! (assoc "data_json" row) "")
  (test-assert "other sender without metadata is not inferred own" (not (jget (history-row->rec row) "me"))))


;; RC18: metadata aliases are authoritative and never change send identities.
(let ((saved-map *lidmap*) (saved-profiles *profile-store*)
      (saved-request wuzapi-request) (calls '()) (events '("Message" "CustomEvent")))
  (dynamic-wind
    (lambda () (set! *lidmap* (make-hash-table)) (set! *profile-store* (make-hash-table)))
    (lambda ()
      (test-equal "unmapped LID is preserved, not guessed" "123456789@lid"
        (profile-provider-jid "123456789@lid"))
      (hash-set! *lidmap* "123456789" "987654321@s.whatsapp.net")
      (test-equal "authoritative map is used for metadata" "987654321"
        (profile-provider-jid "123456789@lid"))
      (test-equal "group identity remains a group" "123456-789@g.us"
        (profile-provider-jid "123456-789@g.us"))
      (hash-set! *lidmap* "777777777" "hostile@other")
      (test-equal "invalid authoritative entry cannot redirect metadata" "777777777@lid"
        (profile-provider-jid "777777777@lid"))
      (profile-record! "123456789@lid")
      (profile-record! "222222222@lid")
      (profile-event! '(("type" . "Presence") ("event" ("From" . "987654321@s.whatsapp.net") ("Unavailable" . #f))))
      (test-equal "phone event reaches requested matching LID" "online"
        (assoc-ref (hash-ref *profile-store* "123456789@lid") "availability"))
      (test-equal "phone event never reaches unrelated LID" "unknown"
        (assoc-ref (hash-ref *profile-store* "222222222@lid") "availability"))
      (profile-event! '(("type" . "Picture") ("event" ("JID" . "987654321@s.whatsapp.net"))))
      (test-equal "picture revision reaches authoritative alias" 1
        (assoc-ref (hash-ref *profile-store* "123456789@lid") "photo_revision"))
      (let* ((rec (hash-ref *profile-store* "123456789@lid")) (seen (- (current-time) 120)))
        (profile-set! rec "availability" "offline")
        (profile-set! rec "availability_at" -1000000)
        (profile-set! rec "last_seen" seen)
        (let ((snapshot (profile-snapshot "123456789@lid" rec)))
          (test-equal "expired offline becomes unknown" "unknown" (assoc-ref snapshot "availability"))
          (test-assert "no fresh last_seen claim after expiry" (not (assoc "last_seen" snapshot)))
          (test-equal "separate historical observation survives" seen (assoc-ref snapshot "last_seen_observed"))))
      (set! wuzapi-request
        (lambda (method path payload)
          (set! calls (cons (list method path payload) calls))
          (cond
           ((equal? path "/user/avatar")
            (values 200 '(("success" . #t) ("data" ("URL" . "https://pps.whatsapp.net/synthetic"))) "{}"))
           ((and (eq? method 'POST) (equal? path "/webhook"))
            (set! events (vector->list (assoc-ref payload "events")))
            (values 200 '(("success" . #t)) "{}"))
           ((equal? path "/webhook")
            (values 200 (list (cons "success" #t)
                         (cons "data" (list (cons "webhook" *hook-url*) (cons "subscribe" (list->vector events))))) "{}"))
           (else (error "Unexpected provider call in regression")))))
      (profile-upstream "avatar" "123456789@lid")
      (test-equal "avatar request uses provider phone from mapping" "987654321"
        (assoc-ref (caddar calls) "Phone"))
      (set! calls '())
      (transport-repair #f)
      (test-assert "ordinary callback repair does not opt into presence" (not (member "Presence" events)))
      (transport-repair #f #t)
      (test-assert "explicit profile repair retains existing subscription" (member "CustomEvent" events))
      (test-assert "explicit profile repair adds all three profile events"
        (every (lambda (name) (member name events)) '("Presence" "ChatPresence" "Picture")))
      (test-assert "repair never announces self presence or reconnects"
        (every (lambda (call) (equal? (cadr call) "/webhook")) calls))
      (test-equal "unknown profile subscription stays unknown" "unknown" (transport-subscribed #f "Presence"))
      (test-equal "all-events wildcard reports profile subscription" "yes"
        (transport-subscribed (list "fixture" '("All")) "Picture")))
    (lambda () (set! *lidmap* saved-map) (set! *profile-store* saved-profiles)
      (set! wuzapi-request saved-request))))

;; RC20: existing receipts remain authoritative during an own-history refresh.
(let* ((chat "123456789@lid")
       (own (lambda (state) (rec "fixture-rc20" chat "123" (cons "me" #t)
                                (cons "text" "synthetic") (cons "delivery" state))))
       (merge-state (lambda (a b)
                      (jget (car (merge-records (list (own a)) (list (own b)))) "delivery"))))
  (test-equal "history acceptance cannot downgrade delivered" "delivered" (merge-state "delivered" "accepted"))
  (test-equal "history acceptance cannot downgrade read" "read" (merge-state "read" "accepted"))
  (test-equal "late delivered cannot downgrade read" "read" (merge-state "read" "delivered"))
  (test-equal "a new read receipt can advance accepted" "read" (merge-state "accepted" "read"))
  (let* ((enriched (rec "fixture-rc20" chat "124" (cons "me" #t) (cons "delivery" "accepted")
                        (cons "caption" "synthetic caption")))
         (merged (car (merge-records (list (own "read")) (list enriched)))))
    (test-equal "refresh still enriches caption" "synthetic caption" (jget merged "caption"))
    (test-equal "refresh keeps one canonical delivery field" 1
      (length (filter (lambda (p) (equal? (car p) "delivery")) merged)))
    (test-equal "refresh keeps the existing read receipt" "read" (jget merged "delivery")))
  (let ((incoming (rec "fixture-rc20" chat "124" (cons "me" #f) (cons "delivery" "accepted"))))
    (test-equal "ownership conflict does not inherit own receipt" "accepted"
      (jget (car (merge-records (list (own "read")) (list incoming))) "delivery")))
  (test-equal "different IDs stay distinct" 2
    (length (merge-records (list (own "read"))
      (list (rec "fixture-other" chat "125" (cons "me" #t) (cons "delivery" "accepted")))))))

(let ((failures (test-runner-fail-count (test-runner-current))))
  (test-end "bridge")
  (exit (if (zero? failures) 0 1)))
