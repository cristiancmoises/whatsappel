;;; performance-tests.el --- RC2 read/render regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'cl-lib)
(require 'whatsapp)

(defun wa-rc2-message (n &optional text)
  (list (cons "id" (format "m%d" n)) (cons "text" (or text (format "record-%d" n)))
        (cons "ts" (+ 1700000000 n)) (cons "kind" "text")))
(defmacro wa-rc2-chat (&rest body)
  `(with-temp-buffer
     (whatsapp-chat-mode)
     (setq whatsapp-chat--jid "fixture" whatsapp-chat--target "fixture")
     (let ((whatsapp-auto-load-images nil) (whatsapp-bridge-token "fixture-token")) ,@body)))
(defun wa-rc2-snapshot (records &optional rev same total limit more)
  (cons 200 (list (cons "version" 2) (cons "revision" (or rev "epoch:1:60"))
                  (cons "unchanged" same) (cons "messages" records) (cons "async_media" t)
                  (cons "total" (or total (length records))) (cons "limit" (or limit 60))
                  (cons "has_more" more))))

(ert-deftest wa-rc2-small-first-window ()
  (wa-rc2-chat
   (let (path)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m p _d callback) (setq path p)
                  (funcall callback (wa-rc2-snapshot (list (wa-rc2-message 1)))))))
       (whatsapp-chat-refresh))
     (should (string-match-p "&v=2&read=0&limit=60" path))
     (should whatsapp--read-v2) (should whatsapp--async-media)
     (should (= 1 (length whatsapp-chat--messages))))))

(ert-deftest wa-rc2-unchanged-read-does-not-erase-or-reinsert ()
  (wa-rc2-chat
   (whatsapp-chat--render (list (wa-rc2-message 1))) (insert "draft")
   (setq whatsapp--read-v2 t whatsapp--read-revision "epoch:1:60" whatsapp--read-origin (whatsapp--origin-key))
   (let ((before (buffer-chars-modified-tick)) path)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m p _d callback) (setq path p)
                  (funcall callback (wa-rc2-snapshot nil "epoch:1:60" t 1)))))
       (whatsapp-chat-refresh))
     (should (string-match-p "&since=" path))
     (should (= before (buffer-chars-modified-tick)))
     (should (equal "draft" (whatsapp-chat--current-input))))))

(ert-deftest wa-rc2-invalid-envelope-preserves-draft-and-history ()
  (wa-rc2-chat
   (whatsapp-chat--render (list (wa-rc2-message 1))) (insert "unsent")
   (dolist (response (list '(200 ("version" . 2) ("revision" . "x") ("unchanged" . nil))
                           (wa-rc2-snapshot nil "wrong" t 1)
                           (wa-rc2-snapshot (list (wa-rc2-message 2)) "x" nil -1)))
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _d callback) (funcall callback response))))
       (whatsapp-chat-refresh))
     (should whatsapp--last-error)
     (should (equal "unsent" (whatsapp-chat--current-input)))
     (should (equal "m1" (cdr (assoc "id" (car whatsapp-chat--messages))))))))

(ert-deftest wa-rc2-account-change-discards-late-response ()
  (wa-rc2-chat
   (whatsapp-chat--render (list (wa-rc2-message 1)))
   (let (callback)
     (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m _p _d cb) (setq callback cb))))
       (whatsapp-chat-refresh))
     (let ((whatsapp-bridge-token "different-account"))
       (funcall callback (wa-rc2-snapshot (list (wa-rc2-message 2)))))
     (should whatsapp--last-error)
     (should (equal "m1" (cdr (assoc "id" (car whatsapp-chat--messages))))))))

(ert-deftest wa-rc2-new-account-never-sends-old-revision ()
  (wa-rc2-chat
   (setq whatsapp--read-revision "old" whatsapp--read-origin (whatsapp--origin-key))
   (let ((whatsapp-bridge-token "different"))
     (should (equal "/chats?v=2" (whatsapp--conditional-path "/chats?v=2"))))))

(ert-deftest wa-rc2-legacy-array-still-works ()
  (wa-rc2-chat
   (cl-letf (((symbol-function 'whatsapp--request-async)
              (lambda (_m _p _d cb) (funcall cb (cons 200 (list (wa-rc2-message 3)))))))
     (whatsapp-chat-refresh))
   (should-not whatsapp--read-v2)
   (should (= 1 (length whatsapp-chat--messages)))))

(ert-deftest wa-rc2-load-older-requests-larger-window ()
  (wa-rc2-chat
   (setq whatsapp--read-v2 t whatsapp--read-revision "old")
   (let (path)
     (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m p _d _cb) (setq path p))))
       (whatsapp-chat-show-older))
     (should (string-match-p "limit=120" path))
     (should-not (string-match-p "since=" path)))))

(ert-deftest wa-rc2-append-preserves-draft-marker-and-undo-list ()
  (wa-rc2-chat
   (let ((first (list (wa-rc2-message 1) (wa-rc2-message 2))))
     (whatsapp-chat--render first) (insert "keep draft")
     (let ((marker whatsapp-chat--input-marker) (undo buffer-undo-list))
       (cl-letf (((symbol-function 'erase-buffer) (lambda () (ert-fail "Unexpected full erase"))))
         (whatsapp-chat--update-messages (append first (list (wa-rc2-message 3)))))
       (should (eq marker whatsapp-chat--input-marker))
       (should (eq undo buffer-undo-list))
       (should (equal "keep draft" (whatsapp-chat--current-input)))
       (should (= 3 (length (whatsapp-chat--ranges))))))))

(ert-deftest wa-rc2-sliding-window-retains-overlap ()
  (wa-rc2-chat
   (let* ((whatsapp-history-page-size 3)
          (all (mapcar #'wa-rc2-message '(1 2 3 4))))
     (whatsapp-chat--render (cl-subseq all 0 3)) (insert "never delete")
     (let ((count 0) (original (symbol-function 'whatsapp--insert-message)))
       (cl-letf (((symbol-function 'whatsapp--insert-message)
                  (lambda (record) (cl-incf count) (funcall original record)))
                 ((symbol-function 'erase-buffer) (lambda () (ert-fail "Unexpected full erase"))))
         (whatsapp-chat--update-messages (cdr all)))
       (should (= count 1)))
     (should-not (string-match-p "record-1" (buffer-string)))
     (should (string-match-p "record-4" (buffer-string)))
     (should (equal "never delete" (whatsapp-chat--current-input))))))

(ert-deftest wa-rc2-edits-and-deletions-replace-only-transcript ()
  (wa-rc2-chat
   (whatsapp-chat--render (mapcar #'wa-rc2-message '(1 2 3))) (insert "draft")
   (whatsapp-chat--update-messages (list (wa-rc2-message 1) (wa-rc2-message 2 "edited")))
   (should (string-match-p "edited" (buffer-string)))
   (should-not (string-match-p "record-3" (buffer-string)))
   (should (equal "draft" (whatsapp-chat--current-input)))
   (goto-char whatsapp-chat--history-start)
   (should-error (insert "not allowed") :type 'text-read-only)))

(ert-deftest wa-rc2-root-initial-render-is-bounded ()
  (with-temp-buffer
    (whatsapp-root-mode)
    (let ((whatsapp--chats (cl-loop for i from 1 to 500 collect
                                   (list (cons "jid" (number-to-string i)) (cons "name" (format "contact-%d" i))))))
      (whatsapp-root--render whatsapp--chats)
      (should (whatsapp-root--chat-position "80"))
      (should-not (whatsapp-root--chat-position "81"))
      (should (string-match-p "More chats" (buffer-string)))
      (whatsapp-root-show-more)
      (should (whatsapp-root--chat-position "160"))
      (should-not (whatsapp-root--chat-position "161")))))

(ert-deftest wa-rc2-search-is-not-limited-to-first-page ()
  (with-temp-buffer
    (whatsapp-root-mode)
    (let ((whatsapp--chats (cl-loop for i from 1 to 500 collect
                                   (list (cons "jid" (number-to-string i)) (cons "name" (format "contact-%d" i))))))
      (whatsapp-root-search "contact-499")
      (should (whatsapp-root--chat-position "499")))))

(ert-deftest wa-rc2-row-controls-and-layout-overrides-are-flattened ()
  (should (equal "Ana Work X" (whatsapp--row-text "Ana\nWork\u202eX"))))

(ert-deftest wa-rc2-unread-navigation-uses-cache-only ()
  (let ((whatsapp--chats '((("jid" . "1") ("unread" . 0)) (("jid" . "2") ("unread" . 1)))) opened)
    (cl-letf (((symbol-function 'whatsapp-open-chat) (lambda (jid) (setq opened jid)))
              ((symbol-function 'whatsapp--request) (lambda (&rest _) (ert-fail "Synchronous lookup"))))
      (whatsapp-next-unread))
    (should (equal opened "2"))))

(ert-deftest wa-rc2-name-index-rebuilds-only-for-a-new-snapshot ()
  (let ((whatsapp--indexed-chats nil) (whatsapp--name-table (make-hash-table :test 'equal))
        (whatsapp--chats '((("jid" . "1") ("name" . "First")))))
    (should (equal "First" (whatsapp--chat-name "1")))
    (let ((table whatsapp--name-table))
      (should (equal "First" (whatsapp--chat-name "1"))) (should (eq table whatsapp--name-table)))
    (setq whatsapp--chats '((("jid" . "1") ("name" . "Renamed"))))
    (should (equal "Renamed" (whatsapp--chat-name "1")))))

(ert-deftest wa-rc2-preview-display-patch-never-changes-characters ()
  (wa-rc2-chat
   (let ((whatsapp--media-cache (make-hash-table :test 'equal))
         (whatsapp-auto-load-images t))
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
       (whatsapp-chat--render '((("id" . "image") ("kind" . "image") ("media" . (("Url" . "fixture")))))))
     (insert "keep input")
     (puthash (whatsapp--media-key "image" "image") "data:image/png;base64,AA==" whatsapp--media-cache)
     (let ((before (buffer-chars-modified-tick)) (point-before (point)))
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                 ((symbol-function 'image-type-available-p) (lambda (_) t))
                 ((symbol-function 'whatsapp--preview-image) (lambda (&rest _) '(image :type png :data "fixture")))
                 ((symbol-function 'whatsapp--visible-spans) (lambda () (list (cons (point-min) (point-max)))))
                 ((symbol-function 'whatsapp-chat--render) (lambda (&rest _) (ert-fail "Full preview redraw"))))
         (whatsapp--refresh-image-displays))
       (should (= before (buffer-chars-modified-tick)))
       (should (= point-before (point)))
       (should (equal "keep input" (whatsapp-chat--current-input)))))))

(ert-deftest wa-rc2-media-jobs-submit-once-and-poll-with-get ()
  (wa-rc2-chat
   (let ((whatsapp--async-media t) methods paths delivered)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (method path _payload callback)
                  (push method methods) (push path paths)
                  (funcall callback (if (equal method "POST") '(202 ("job" . "epoch:media")) '(200 ("data" . nil)))))))
       (whatsapp--download-async '(("kind" . "image")) (lambda (r) (setq delivered r))))
     (should (equal (reverse methods) '("POST" "GET")))
     (should (equal (car (last paths)) "/download?async=1"))
     (should (= 200 (car delivered))))))

(ert-deftest wa-rc2-busy-media-worker-is-not-automatically-retried ()
  (wa-rc2-chat
   (let ((whatsapp--async-media t) (calls 0) delivered)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _d cb) (cl-incf calls) (funcall cb '(429 ("error" . "busy"))))))
       (whatsapp--download-async nil (lambda (r) (setq delivered r))))
     (should (= calls 1)) (should (= (car delivered) 429)))))

(ert-deftest wa-rc2-failed-poll-backs-off-without-hiding-cached-history ()
  (wa-rc2-chat
   (whatsapp-chat--render (list (wa-rc2-message 1)))
   (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m _p _d cb) (funcall cb '(503)))))
     (whatsapp-chat-refresh))
   (should (> whatsapp--next-refresh (float-time)))
   (should (< (- whatsapp--next-refresh (float-time)) 61))
   (should (= (length whatsapp-chat--messages) 1))))

(ert-deftest wa-rc2-preserves-established-forward-key ()
  (should (eq (lookup-key whatsapp-chat-mode-map (kbd "C-c C-f")) #'whatsapp-chat-forward))
  (should (eq (lookup-key whatsapp-chat-mode-map (kbd "C-c /")) #'whatsapp-chat-search)))

(provide 'performance-tests)
;;; performance-tests.el ends here
