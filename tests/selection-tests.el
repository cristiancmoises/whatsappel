;;; selection-tests.el --- Contact-selection responsiveness -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'cl-lib)
(require 'whatsapp)
(require 'performance-tests)

(ert-deftest wa-rc8-message-preview-retains-original-record ()
  (wa-rc2-chat
   (let* ((text (make-string 200000 ?a)) (record (wa-rc2-message 1 text))
          (whatsapp-message-preview-characters 2048))
     (whatsapp-chat--render (list record))
     (should (< (buffer-size) 5000))
     (goto-char whatsapp-chat--history-start)
     (should (eq text (cdr (assoc "text" (get-text-property (point) 'whatsapp-msg)))))
     (should (string-match-p "Read full text" (buffer-string))))))

(ert-deftest wa-rc8-caption-and-sender-are-bounded ()
  (wa-rc2-chat
   (let ((record `(("id" . "media") ("name" . ,(make-string 100000 ?x))
                   ("kind" . "video") ("caption" . ,(make-string 100000 ?c)))))
     (whatsapp-chat--render (list record)) (should (< (buffer-size) 4000)))))

(ert-deftest wa-rc8-preview-setting-cannot-remove-hard-ceiling ()
  (with-temp-buffer
    (let ((whatsapp-message-preview-characters 100000000))
      (whatsapp--insert-bounded-text (make-string 90000 ?x))
      (should (< (buffer-size) 8400)))))

(ert-deftest wa-rc8-text-reader-is-paged-not-a-whole-body-insertion ()
  (with-temp-buffer
    (special-mode)
    (setq whatsapp--text-content (make-string 100000 ?a))
    (whatsapp--text-page)
    (should (< (buffer-size) 8400))
    (let ((button (next-button (point-min) t)))
      (should (equal "Next page" (button-label button)))
      (button-activate button)
      (should (= whatsapp--text-offset 8192))
      (should (= (length whatsapp--text-content) 100000)))))

(ert-deftest wa-rc8-cached-image-render-never-starts-a-decoder ()
  (wa-rc2-chat
   (let ((whatsapp--media-cache (make-hash-table :test 'equal))
         (whatsapp--preview-cache (make-hash-table :test 'equal)))
     (puthash (whatsapp--media-key "i" "image") "data:image/png;base64,AA==" whatsapp--media-cache)
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'whatsapp--preview-image) (lambda (&rest _) (ert-fail "Inline decoder"))))
       (whatsapp--insert-image "i" "image" '(("Url" . "fixture")) nil)))))

(ert-deftest wa-rc8-cached-image-spec-can-be-reused-without-decoding ()
  (wa-rc2-chat
   (let* ((whatsapp--preview-cache (make-hash-table :test 'equal))
          (image '(image :type png :data "fixture")))
     (puthash (whatsapp--media-key "i" "image") (list "uri" image 1) whatsapp--preview-cache)
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
       (whatsapp--insert-image "i" "image" '(("Url" . "fixture")) nil))
     (should (equal (get-text-property (point-min) 'display) image)))))

(ert-deftest wa-rc8-prefetch-uses-relative-wall-timer-once ()
  (wa-rc2-chat
   (let ((whatsapp-auto-load-images t) calls)
     (cl-letf (((symbol-function 'run-at-time) (lambda (delay repeat fn &rest _) (push (list delay repeat fn) calls) 'owned))
               ((symbol-function 'run-with-idle-timer) (lambda (&rest _) (ert-fail "Expired idle timer"))))
       (whatsapp-chat--schedule-prefetch) (whatsapp-chat--schedule-prefetch))
     (should (= 1 (length calls))) (should (= 0.15 (caar calls)))
     (setq whatsapp--prefetch-timer nil))))

(ert-deftest wa-rc8-window-end-never-forces-layout ()
  (wa-rc2-chat
   (insert (make-string 10000 ?x))
   (cl-letf (((symbol-function 'get-buffer-window-list) (lambda (&rest _) '(fixture)))
             ((symbol-function 'window-start) (lambda (_) 1))
             ((symbol-function 'window-end) (lambda (_window &optional update) (should-not update) nil)))
     (should (equal (whatsapp--visible-spans) '((1 . 8193)))))))

(ert-deftest wa-rc8-ready-previews-decode-one-per-tick ()
  (wa-rc2-chat
   (let ((whatsapp-auto-load-images t)
         (whatsapp--media-cache (make-hash-table :test 'equal)) (calls 0) scheduled)
     (dotimes (i 3)
       (let ((id (number-to-string i)))
         (insert (propertize "image\n" 'whatsapp-id id 'whatsapp-kind "image"))
         (puthash (whatsapp--media-key id "image") "data:image/png;base64,AA==" whatsapp--media-cache)))
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'image-type-available-p) (lambda (_) t))
               ((symbol-function 'whatsapp--visible-spans) (lambda () (list (cons (point-min) (point-max)))))
               ((symbol-function 'whatsapp--preview-image) (lambda (&rest _) (cl-incf calls) '(image :type png :data "fixture")))
               ((symbol-function 'whatsapp--schedule-media-redraw) (lambda () (setq scheduled t))))
       (let ((before (buffer-substring-no-properties (point-min) (point-max))))
         (whatsapp--refresh-image-displays)
         (should (equal before (buffer-substring-no-properties (point-min) (point-max))))))
     (should (= calls 1)) (should scheduled))))

(ert-deftest wa-rc8-hidden-previews-never-decode ()
  (wa-rc2-chat
   (let ((whatsapp-auto-load-images t))
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'whatsapp--visible-spans) (lambda () nil))
               ((symbol-function 'whatsapp--preview-image) (lambda (&rest _) (ert-fail "Hidden decode"))))
       (whatsapp--refresh-image-displays)))))

(ert-deftest wa-rc8-selection-highlight-does-not-mutate-characters ()
  (with-temp-buffer
    (whatsapp-root-mode)
    (let ((chats '(( ("jid" . "a") ("name" . "Ana")) (("jid" . "b") ("name" . "Beto")))))
      (whatsapp-root--render chats)
      (goto-char (whatsapp-root--chat-position "a"))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))) (pos (point)))
        (cl-letf (((symbol-function 'whatsapp-root--render) (lambda (&rest _) (ert-fail "Root rebuild")))
                  ((symbol-function 'whatsapp-root--insert-row) (lambda (&rest _) (ert-fail "Row rebuild"))))
          (whatsapp-root--select-only "b"))
        (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
        (should (= pos (point))) (should (equal whatsapp-root--shown-selection "b"))))))

(ert-deftest wa-rc8-open-displays-composer-before-refresh ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *wa-rc8-open*")) (whatsapp-auto-load-images nil)
          (whatsapp-workspace-sidebar nil) (whatsapp-auto-poll nil) timer-args)
      (unwind-protect
          (cl-letf (((symbol-function 'whatsapp--chat-buffer) (lambda (_jid)
                                                              (with-current-buffer buffer
                                                                (whatsapp-chat-mode)
                                                                (setq whatsapp-chat--jid "fixture")) buffer))
                    ((symbol-function 'run-at-time) (lambda (&rest args) (setq timer-args args) 'fixture-timer))
                    ((symbol-function 'whatsapp-chat-refresh) (lambda (&rest _) (ert-fail "Refresh ran inside selection"))))
            (whatsapp-open-chat "fixture")
            (should (eq buffer (window-buffer (selected-window))))
            (with-current-buffer buffer
              (should (markerp whatsapp-chat--input-marker))
              (insert "editable immediately")
              (should (equal "editable immediately" (whatsapp-chat--current-input))))
            (should (eq (nth 2 timer-args) #'whatsapp--open-deferred)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest wa-rc8-selection-defers-already-cached-unrendered-history ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *wa-rc8-cached*")) (whatsapp-auto-load-images nil)
          (whatsapp-workspace-sidebar nil) (whatsapp-auto-poll nil))
      (unwind-protect
          (progn
            (with-current-buffer buffer (whatsapp-chat-mode)
              (setq whatsapp-chat--jid "fixture" whatsapp-chat--messages (list (wa-rc2-message 1))))
            (cl-letf (((symbol-function 'whatsapp--chat-buffer) (lambda (_) buffer))
                      ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                      ((symbol-function 'whatsapp--insert-message) (lambda (&rest _) (ert-fail "Rendered cached history inside click"))))
              (whatsapp-open-chat "fixture"))
            (with-current-buffer buffer (should (= 1 (length whatsapp-chat--messages)))))
        (kill-buffer buffer)))))

(ert-deftest wa-rc8-deferred-work-ignores-stale-generation ()
  (wa-rc2-chat
   (setq whatsapp--open-generation 2)
   (cl-letf (((symbol-function 'whatsapp-chat-refresh) (lambda (&rest _) (ert-fail "Stale refresh"))))
     (whatsapp--open-deferred (current-buffer) 1 (whatsapp--origin-key)))))

(ert-deftest wa-rc8-deferred-work-ignores-changed-account ()
  (wa-rc2-chat
   (setq whatsapp--open-generation 1)
   (cl-letf (((symbol-function 'whatsapp-chat-refresh) (lambda (&rest _) (ert-fail "Wrong account"))))
     (whatsapp--open-deferred (current-buffer) 1 '("other" "scope")))))

(ert-deftest wa-rc8-deferred-work-ignores-hidden-conversation ()
  (wa-rc2-chat
   (setq whatsapp--open-generation 1)
   (cl-letf (((symbol-function 'whatsapp-chat-refresh) (lambda (&rest _) (ert-fail "Hidden refresh"))))
     (whatsapp--open-deferred (current-buffer) 1 (whatsapp--origin-key)))))

(ert-deftest wa-rc8-deferred-work-refreshes-selected-conversation ()
  (save-window-excursion
    (wa-rc2-chat
     (switch-to-buffer (current-buffer)) (setq whatsapp--open-generation 1)
     (let ((calls 0))
       (cl-letf (((symbol-function 'whatsapp-chat-refresh) (lambda (&rest _) (cl-incf calls))))
         (whatsapp--open-deferred (current-buffer) 1 (whatsapp--origin-key)))
       (should (= calls 1))))))

(ert-deftest wa-rc8-closed-buffer-deferred-work-is-a-noop ()
  (let ((buffer (generate-new-buffer " *closed*")))
    (kill-buffer buffer) (should-not (whatsapp--open-deferred buffer 0 nil))))

(ert-deftest wa-rc8-invalid-contact-is-rejected-before-window-changes ()
  (dolist (jid '(nil "" "bad\ncontact" "bad contact"))
    (should-error (whatsapp-open-chat jid) :type 'user-error)))

(ert-deftest wa-rc8-pq-render-never-starts-crypto-or-reads-key-files ()
  (wa-rc2-chat
   (let ((whatsapp-pq--plain-cache (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'whatsapp-pq-open) (lambda (&rest _) (ert-fail "Synchronous decryption")))
               ((symbol-function 'whatsapp-pq-ready-p) (lambda () (ert-fail "Filesystem check in renderer")))
               ((symbol-function 'whatsapp-pq-have-contact-p) (lambda (_) (ert-fail "Key read in renderer"))))
       (whatsapp--insert-pq nil "WAPQ1:fixture" "m"))
     (should (string-match-p "Decrypt" (buffer-string))))))

(ert-deftest wa-rc8-pq-cache-does-not-cross-accounts ()
  (let ((whatsapp-bridge-token "first"))
    (let ((key (whatsapp--pq-cache-key "jid" "id" "blob")))
      (let ((whatsapp-bridge-token "second"))
        (should-not (equal key (whatsapp--pq-cache-key "jid" "id" "blob")))))))

(ert-deftest wa-rc8-pq-ready-display-preserves-draft-and-character-positions ()
  (wa-rc2-chat
   (whatsapp-chat--render (list (wa-rc2-message 1 "WAPQ1:fixture")))
   (insert "draft stays")
   (let ((key (whatsapp--pq-cache-key "fixture" "m1" "WAPQ1:fixture"))
         (text (buffer-substring-no-properties (point-min) (point-max)))
         (marker (marker-position whatsapp-chat--input-marker)))
     (whatsapp--pq-show-ready key "verified text")
     (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
     (should (= marker (marker-position whatsapp-chat--input-marker)))
     (should (equal "draft stays" (whatsapp-chat--current-input))))))

(ert-deftest wa-rc8-pq-large-blob-rejected-before-files-or-child ()
  (wa-rc2-chat
   (cl-letf (((symbol-function 'whatsapp-pq-ready-p) (lambda () (ert-fail "Key inspection before size check"))))
     (should-error (whatsapp-chat-decrypt "m" (make-string (+ (* 1024 1024) 1) ?x)) :type 'user-error))))

(ert-deftest wa-rc8-debug-report-does-not-contain-account-or-contact ()
  (wa-rc2-chat
   (let ((whatsapp-bridge-url "https://private-origin.invalid") (whatsapp-bridge-token "PRIVATE_TOKEN")
         (whatsapp-chat--jid "PRIVATE_CONTACT"))
     (whatsapp-selection-diagnostics)
     (with-current-buffer "*WhatsApp selection diagnostics*"
       (should-not (string-match-p "PRIVATE_TOKEN\\|PRIVATE_CONTACT\\|private-origin" (buffer-string)))))))

(provide 'selection-tests)

(ert-deftest wa-rc8-real-delayed-http-keeps-event-loop-and-draft-live ()
  "Actual Emacs sockets + actual Python worker; no real WhatsApp account."
  (unless (executable-find whatsapp-python-program) (ert-skip "Python is absent"))
  (save-window-excursion
    (let ((server nil) clients response-timers heartbeat buffer
          (ticks 0) (requests 0) request-text
          (whatsapp-auto-load-images nil) (whatsapp-auto-poll nil)
          (whatsapp-workspace-sidebar nil) (whatsapp-mark-focused-chat-read nil)
          (whatsapp-use-read-worker t) (whatsapp-request-timeout 5)
          (whatsapp-bridge-token "synthetic-token"))
      (unwind-protect
          (progn
            (setq server
                  (make-network-process
                   :name "wa-rc8-delayed-http" :server t :family 'ipv4 :host "127.0.0.1" :service t
                   :noquery t :coding 'binary
                   :filter
                   (lambda (process text)
                     (cl-pushnew process clients)
                     (process-put process 'input (concat (process-get process 'input) text))
                     (when (and (not (process-get process 'sent))
                                (string-match-p "\r\n\r\n" (process-get process 'input)))
                       (process-put process 'sent t) (cl-incf requests)
                       (setq request-text (process-get process 'input))
                       (push (run-at-time
                              0.4 nil
                              (lambda ()
                                (when (process-live-p process)
                                  (let ((body (encode-coding-string
                                               (json-encode `((version . 2) (revision . "test:1")
                                                              (unchanged . :json-false) (total . 1) (limit . 60)
                                                              (has_more . :json-false)
                                                              (messages . [((id . "m1") (kind . "text")
                                                                             (text . ,(make-string 200000 ?x)))])))
                                               'utf-8)))
                                    (process-send-string process (format "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" (string-bytes body)))
                                    (process-send-string process body) (process-send-eof process)))))
                             response-timers)))))
            (let ((whatsapp-bridge-url (format "http://127.0.0.1:%d" (process-contact server :service))))
              (setq buffer (generate-new-buffer " *wa-rc8-delayed-chat*"))
              (with-current-buffer buffer (whatsapp-chat-mode)
                (setq whatsapp-chat--jid "fixture" whatsapp-chat--target "fixture"))
              (setq heartbeat (run-at-time 0.01 0.01 (lambda () (cl-incf ticks))))
              (cl-letf (((symbol-function 'whatsapp--chat-buffer) (lambda (_) buffer)))
                (whatsapp-open-chat "fixture"))
              (with-current-buffer buffer
                (should (= requests 0))
                (insert "draft while server waits")
                (let ((deadline (+ (float-time) 7)))
                  (while (and (not whatsapp--has-snapshot) (< (float-time) deadline))
                    (accept-process-output nil 0.02)))
                (should whatsapp--has-snapshot)
                (should (> ticks 5))
                (should (= requests 1))
                (should (equal "draft while server waits" (whatsapp-chat--current-input)))
                (should (< (buffer-size) 5000))
                (should (= 200000 (length (cdr (assoc "text" (car whatsapp-chat--messages)))))))
            (should (string-prefix-p "GET /chat?" request-text))
            (should (string-match-p "&read=0&" request-text))))
        (dolist (timer (cons heartbeat response-timers)) (when (timerp timer) (cancel-timer timer)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (dolist (process (cons server clients))
          (when (and (processp process) (process-live-p process)) (delete-process process)))))))

(ert-deftest wa-rc8-pq-fake-child-completion-never-moves-draft ()
  "Actual subprocess plumbing with a fake verifier, NOT cryptographic validation."
  (unless (executable-find whatsapp-python-program) (ert-skip "Python is absent"))
  (let* ((directory (make-temp-file "wa-rc8-fake-pq-" t))
         (program (expand-file-name "fake-pq" directory)) (ticks 0) timer input-path)
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/usr/bin/env python3\nimport time,sys\ntime.sleep(.15)\nsys.stdout.write('verified fixture')\n"))
          (set-file-modes program #o700)
          (wa-rc2-chat
           (let ((whatsapp-pq-program program) (whatsapp-pq-dir directory)
                 (whatsapp-pq--plain-cache (make-hash-table :test 'equal)))
             (whatsapp-chat--render (list (wa-rc2-message 1 "WAPQ1:fixture")))
             (insert "keep draft")
             (setq timer (run-at-time 0.01 0.01 (lambda () (cl-incf ticks))))
             (cl-letf (((symbol-function 'whatsapp-pq-ready-p) (lambda () t))
                       ((symbol-function 'whatsapp-pq-have-contact-p) (lambda (_) t)))
               (whatsapp-chat-decrypt "m1" "WAPQ1:fixture"))
             (should (processp whatsapp--pq-process))
             ;; Locate --in rather than relying on optional --max-age placement.
             (setq input-path (cadr (member "--in" (process-command whatsapp--pq-process))))
             (let ((deadline (+ (float-time) 5)))
               (while (and whatsapp--pq-process (< (float-time) deadline)) (accept-process-output nil 0.02)))
             (should-not whatsapp--pq-process)
             (should (> ticks 2))
             (should-not (file-exists-p input-path))
             (should (equal "verified fixture" (gethash (whatsapp--pq-cache-key "fixture" "m1" "WAPQ1:fixture") whatsapp-pq--plain-cache)))
             (should (equal "keep draft" (whatsapp-chat--current-input))))))
      (when (timerp timer) (cancel-timer timer)) (delete-directory directory t))))
