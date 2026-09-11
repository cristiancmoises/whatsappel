;;; responsiveness-tests.el --- RC3 native regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'cl-lib)
(require 'whatsapp)
(require 'performance-tests)

(ert-deftest wa-rc3-json-objects-retain-string-keys ()
  (let* ((value (whatsapp--json-read "{\"a\":[{\"name\":\"João\",\"false\":false,\"null\":null}],\"empty\":[]}"))
         (child (car (cdr (assoc "a" value)))))
    (should (equal (cdr (assoc "name" child)) "João"))
    (should (assoc "false" child)) (should-not (cdr (assoc "false" child)))
    (should (assoc "null" child)) (should-not (cdr (assoc "empty" value)))))

(ert-deftest wa-rc3-json-fallback-keeps-the-same-contract ()
  (cl-letf (((symbol-function 'json-available-p) (lambda () nil)))
    (should (equal (whatsapp--json-read "{\"name\":\"Ana\",\"ok\":false}")
                   '(("name" . "Ana") ("ok"))))))

(ert-deftest wa-rc3-get-uses-worker-post-retains-url-transport ()
  "Keep the historical ID, but assert the current RC11 explicit-send contract.
Read snapshots and /send use an owned worker. Other legacy POSTs retain URL I/O."
  (let ((whatsapp-use-read-worker t) worker-calls url-calls)
    (cl-letf (((symbol-function 'whatsapp--read-worker)
               (lambda (path _callback &optional payload) (push (list path payload) worker-calls)))
              ((symbol-function 'whatsapp--url-request-async)
               (lambda (method path payload _callback) (push (list method path payload) url-calls))))
      (whatsapp--request-async "GET" "/chats?v=2" nil #'ignore)
      (whatsapp--request-async "GET" "/chat?jid=a&v=2&read=0&limit=60" nil #'ignore)
      (whatsapp--request-async "POST" "/send" '(("to" . "123@lid") ("body" . "fixture")) #'ignore)
      (whatsapp--request-async "POST" "/markread" '(("to" . "123@lid")) #'ignore))
    (should (equal (nreverse worker-calls)
                   '(("/chats?v=2" nil) ("/chat?jid=a&v=2&read=0&limit=60" nil)
                     ("/send" (("to" . "123@lid") ("body" . "fixture"))))))
    (should (equal url-calls '(("POST" "/markread" (("to" . "123@lid"))))))))

(ert-deftest wa-rc3-background-chat-does-not-mark-read ()
  (wa-rc2-chat
   (let (path)
     (cl-letf (((symbol-function 'whatsapp-chat--focused-p) (lambda () nil))
               ((symbol-function 'whatsapp--request-async) (lambda (_m p _d cb) (setq path p) (funcall cb (wa-rc2-snapshot nil)))))
       (whatsapp-chat-refresh))
     (should (string-match-p "&read=0&" path)))))

(ert-deftest wa-rc3-focused-chat-can-mark-read ()
  (wa-rc2-chat
   (let (path)
     (cl-letf (((symbol-function 'whatsapp-chat--focused-p) (lambda () t))
               ((symbol-function 'whatsapp--request-async) (lambda (_m p _d cb) (setq path p) (funcall cb (wa-rc2-snapshot nil)))))
       (whatsapp-chat-refresh))
     (should (string-match-p "&read=1&" path)))))

(ert-deftest wa-rc3-unknown-focus-is-not-assumed-active ()
  (save-window-excursion
    (wa-rc2-chat
     (switch-to-buffer (current-buffer))
     (cl-letf (((symbol-function 'frame-visible-p) (lambda (&rest _) t))
               ((symbol-function 'frame-focus-state) (lambda (&rest _) 'unknown)))
       (should-not (whatsapp-chat--focused-p))))))

(ert-deftest wa-rc3-empty-success-is-distinct-from-loading ()
  (wa-rc2-chat
   (whatsapp-chat--render nil)
   (should (string-match-p "Loading retained history" (buffer-string)))
   (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m _p _d cb) (funcall cb (wa-rc2-snapshot nil)))))
     (whatsapp-chat-refresh))
   (should whatsapp--has-snapshot)
   (should (string-match-p "No retained messages" (buffer-string)))
   (should-not (string-match-p "Loading retained history" (buffer-string)))))

(ert-deftest wa-rc3-failed-read-is-not-an-empty-conversation ()
  (wa-rc2-chat
   (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m _p _d cb) (funcall cb '(503)))))
     (whatsapp-chat-refresh))
   (should-not whatsapp--has-snapshot) (should whatsapp--last-error)
   (should-not (string-match-p "No retained messages" (buffer-string)))))

(ert-deftest wa-rc3-polling-start-is-idempotent-and-pause-persists ()
  (let ((whatsapp-auto-poll t) (whatsapp--polling-paused nil) (whatsapp--poll-timer nil) (calls 0))
    (cl-letf (((symbol-function 'run-with-timer) (lambda (&rest _) (cl-incf calls) 'fixture-timer))
              ((symbol-function 'cancel-timer) #'ignore))
      (whatsapp--ensure-polling) (whatsapp--ensure-polling)
      (should (= calls 1))
      (whatsapp-toggle-polling) (whatsapp--ensure-polling)
      (should whatsapp--polling-paused) (should (= calls 1))
      (whatsapp-toggle-polling) (should-not whatsapp--polling-paused) (should (= calls 2)))))

(ert-deftest wa-rc3-root-replaces-only-one-changed-row ()
  (with-temp-buffer
    (whatsapp-root-mode)
    (let* ((one '(("jid" . "1") ("name" . "Ana") ("last" . "before")))
           (two '(("jid" . "2") ("name" . "Beto") ("last" . "same")))
           (changed '(("jid" . "1") ("name" . "Ana") ("last" . "after")))
           (original (symbol-function 'whatsapp-root--insert-row)) (count 0))
      (whatsapp-root--render (list one two))
      (goto-char (whatsapp-root--chat-position "2"))
      (cl-letf (((symbol-function 'erase-buffer) (lambda () (ert-fail "Full root redraw")))
                ((symbol-function 'whatsapp-root--insert-row) (lambda (c w) (cl-incf count) (funcall original c w))))
        (whatsapp-root--update (list changed two)))
      (should (= count 1)) (should (equal "2" (get-text-property (point) 'whatsapp-jid)))
      (should (string-match-p "after" (buffer-string))) (should-not (string-match-p "before" (buffer-string))))))

(ert-deftest wa-rc3-unchanged-root-inserts-zero-rows ()
  (with-temp-buffer
    (whatsapp-root-mode)
    (let ((rows '((("jid" . "1") ("name" . "Ana")))))
      (whatsapp-root--render rows)
      (cl-letf (((symbol-function 'whatsapp-root--insert-row) (lambda (&rest _) (ert-fail "Unchanged row rebuilt"))))
        (whatsapp-root--update (copy-tree rows))))))

(ert-deftest wa-rc3-root-reordering-falls-back-to-bounded-render ()
  (with-temp-buffer
    (whatsapp-root-mode)
    (let ((rows '((("jid" . "1")) (("jid" . "2")))))
      (whatsapp-root--render rows) (whatsapp-root--update (reverse rows))
      (should (< (whatsapp-root--chat-position "2") (whatsapp-root--chat-position "1"))))))

(ert-deftest wa-rc3-selection-change-does-not-rebuild-every-row ()
  (with-temp-buffer
    (whatsapp-root-mode)
    (let* ((rows '((("jid" . "1") ("name" . "Ana")) (("jid" . "2") ("name" . "Beto"))))
           (whatsapp--selected-chat "1") (count 0) (original (symbol-function 'whatsapp-root--insert-row)))
      (whatsapp-root--render rows) (setq whatsapp--selected-chat "2")
      (cl-letf (((symbol-function 'whatsapp-root--insert-row) (lambda (c w) (cl-incf count) (funcall original c w)))
                ((symbol-function 'erase-buffer) (lambda () (ert-fail "Selection erased root"))))
        (whatsapp-root--update rows))
      (should (= count 2)))))

(ert-deftest wa-rc3-prefetch-ignores-hidden-chats ()
  (wa-rc2-chat
   (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
             ((symbol-function 'get-buffer-window-list) (lambda (&rest _) nil))
             ((symbol-function 'whatsapp--queue-image) (lambda (&rest _) (ert-fail "Hidden image download"))))
     (let ((whatsapp-auto-load-images t)) (whatsapp-chat--prefetch-visible)))))

(ert-deftest wa-rc3-prefetch-selects-only-viewport-records ()
  (wa-rc2-chat
   (let ((whatsapp-auto-load-images t) calls)
     (insert (propertize "outside\n" 'whatsapp-msg '(("id" . "off") ("kind" . "image") ("media" . (("Url" . "fixture"))))))
     (let ((start (point)))
       (insert (propertize "inside\n" 'whatsapp-msg '(("id" . "on") ("kind" . "image") ("media" . (("Url" . "fixture"))))))
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                 ((symbol-function 'get-buffer-window-list) (lambda (&rest _) '(fixture-window)))
                 ((symbol-function 'window-start) (lambda (_) start))
                 ((symbol-function 'window-end) (lambda (&rest _) (point-max)))
                 ((symbol-function 'whatsapp--queue-image) (lambda (id &rest _) (push id calls))))
         (whatsapp-chat--prefetch-visible)))
     (should (equal calls '("on"))))))

(ert-deftest wa-rc3-queued-click-registers-intent-without-second-download ()
  (wa-rc2-chat
   (let ((whatsapp--media-cache (make-hash-table :test 'equal))
         (whatsapp--media-pending (make-hash-table :test 'equal))
         (whatsapp--media-open-waiters (make-hash-table :test 'equal))
         (whatsapp--media-queue nil)
         (record '(("id" . "fixture") ("kind" . "image") ("media" . (("Url" . "fixture"))))))
     (let ((key (whatsapp--media-key "fixture" "image")))
       (puthash key 'active whatsapp--media-pending)
       (cl-letf (((symbol-function 'whatsapp--message-at-point) (lambda () record))
                 ((symbol-function 'whatsapp--download-async) (lambda (&rest _) (ert-fail "Duplicate download"))))
         (whatsapp-chat-open-media-at-point))
       (should (eq (car (gethash key whatsapp--media-open-waiters)) (current-buffer)))))))

(ert-deftest wa-rc3-old-open-intent-cannot-steal-focus ()
  (wa-rc2-chat
   (let ((whatsapp--media-open-waiters (make-hash-table :test 'equal))
         (key (whatsapp--media-key "fixture" "image")))
     (setq whatsapp--media-open-generation 2)
     (puthash key (list (current-buffer) 1) whatsapp--media-open-waiters)
     (cl-letf (((symbol-function 'whatsapp--open-uri) (lambda (&rest _) (ert-fail "Stale media opened"))))
       (whatsapp--finish-media-open key '(200)))
     (should-not (gethash key whatsapp--media-open-waiters)))))

(ert-deftest wa-rc3-media-poll-uses-chat-not-url-callback-buffer ()
  (wa-rc2-chat
   (let ((whatsapp--async-media t) (owner (current-buffer)) observed)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (method _path _data cb)
                  (if (equal method "POST")
                      (with-temp-buffer (funcall cb '(202 ("job" . "fixture"))))
                    (setq observed (current-buffer)) (funcall cb '(200 ("data")))))))
       (whatsapp--download-async nil #'ignore))
     (should (eq observed owner)))))

(ert-deftest wa-rc3-evicted-preview-is-eligible-to-fetch-again ()
  (let ((whatsapp--media-cache (make-hash-table :test 'equal))
        (whatsapp--media-pending (make-hash-table :test 'equal))
        (whatsapp--media-order nil) (whatsapp-media-cache-max-bytes 4))
    (puthash 'old 'done whatsapp--media-pending)
    (whatsapp--cache-put 'old "aaaa") (whatsapp--cache-put 'new "bbbb")
    (should-not (gethash 'old whatsapp--media-pending))))

(ert-deftest wa-rc3-late-send-after-account-change-retains-draft ()
  (wa-rc2-chat
   (whatsapp-chat--render nil) (insert "keep this draft")
   (let (callback)
     (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m _p _d cb) (setq callback cb))))
       (whatsapp-chat-send-input))
     (let ((whatsapp-bridge-token "other-account"))
       (funcall callback '(200 ("wuzapi_status" . 200))))
     (should (equal "keep this draft" (whatsapp-chat--current-input)))
     (should whatsapp--last-error))))

(ert-deftest wa-rc3-write-shortcut-never-sends-or-clears-input ()
  (wa-rc2-chat
   (whatsapp-chat--render (list (wa-rc2-message 1))) (insert "draft") (goto-char (point-min))
   (whatsapp-chat-focus-input)
   (should (= (point) (point-max))) (should (equal "draft" (whatsapp-chat--current-input)))
   (should (eq (lookup-key whatsapp-chat-mode-map (kbd "C-c C-b")) #'whatsapp-chat-focus-input))))

(ert-deftest wa-rc3-real-python-read-child-roundtrip ()
  "Run the real child against an Emacs-owned loopback HTTP fixture."
  (unless (executable-find whatsapp-python-program) (ert-skip "Python runtime absent"))
  (let ((server nil) (clients nil) (done nil) (calls 0) result request-text)
    (unwind-protect
        (progn
          (setq server
                (make-network-process
                 :name "wa-test-http" :server t :family 'ipv4 :host "127.0.0.1" :service t
                 :noquery t :coding 'binary
                 :filter (lambda (process text)
                           (cl-pushnew process clients)
                           (process-put process 'input (concat (process-get process 'input) text))
                           (when (and (not (process-get process 'sent))
                                      (string-match-p "\r\n\r\n" (process-get process 'input)))
                             (setq request-text (process-get process 'input)) (process-put process 'sent t)
                             (process-send-string process "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
                             (process-send-eof process)))))
          (wa-rc2-chat
           (let ((whatsapp-bridge-url (format "http://127.0.0.1:%d" (process-contact server :service)))
                 (whatsapp-request-timeout 3))
             (whatsapp--read-worker "/chats?v=2" (lambda (value) (setq result value done t) (cl-incf calls)))
             (let ((deadline (+ (float-time) 6)))
               (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.02)))
             (should done) (should (= calls 1)) (should (equal result '(200)))
             (should-not whatsapp--read-processes)))
          (should (string-prefix-p "GET /chats?v=2 HTTP/1.1" request-text)))
      (dolist (process (cons server clients))
        (when (and (processp process) (process-live-p process)) (delete-process process))))))

(ert-deftest wa-rc3-malformed-record-does-not-replace-cache ()
  (wa-rc2-chat
   (let ((good (list (wa-rc2-message 1))))
     (setq whatsapp--has-snapshot t)
     (whatsapp-chat--render good)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _d cb) (funcall cb '(200 (("id" . "bad") ("text" . 42)))))))
       (whatsapp-chat-refresh))
     (should (equal whatsapp-chat--messages good)) (should whatsapp--last-error))))

(ert-deftest wa-rc3-duplicate-identities-rejected-before-cache-update ()
  (wa-rc2-chat
   (should-not (whatsapp--records-p (list (wa-rc2-message 1) (wa-rc2-message 1))))
   (should (whatsapp--records-p (list (wa-rc2-message 1) (wa-rc2-message 2))))))

(ert-deftest wa-rc3-scroll-prefetch-belongs-to-the-scrolled-window ()
  (let ((other (generate-new-buffer " *wa-scroll-fixture*")) observed)
    (unwind-protect
        (progn
          (with-current-buffer other (whatsapp-chat-mode))
          (cl-letf (((symbol-function 'window-live-p) (lambda (_) t))
                    ((symbol-function 'window-buffer) (lambda (_) other))
                    ((symbol-function 'whatsapp-chat--schedule-prefetch)
                     (lambda () (setq observed (current-buffer)))))
            (whatsapp-chat--scrolled 'fixture-window 1))
          (should (eq observed other)))
      (kill-buffer other))))

(provide 'responsiveness-tests)
;;; responsiveness-tests.el ends here
