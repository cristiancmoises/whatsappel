;;; workspace-tests.el --- 3.2 workspace regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'cl-lib)
(require 'whatsapp)

(defmacro whatsapp-workspace-test-chat (&rest body)
  `(with-temp-buffer
     (whatsapp-chat-mode)
     (setq whatsapp-chat--jid "5511@s.whatsapp.net" whatsapp-chat--target "5511")
     (let ((whatsapp-auto-load-images nil))
       (whatsapp-chat--render nil)
       ,@body)))

(defun whatsapp-workspace-test-button (command)
  "Find COMMAND's button without coupling behavior tests to visible wording."
  (let ((button (next-button (point-min) t)))
    (while (and button (not (eq (button-get button 'whatsapp-command) command)))
      (setq button (next-button (button-end button) t)))
    button))

(ert-deftest whatsapp-workspace-async-send-guards-duplicates ()
  (whatsapp-workspace-test-chat
   (insert "hello")
   (let ((calls 0) callback)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _body cb) (cl-incf calls) (setq callback cb)))
               ((symbol-function 'whatsapp-chat-refresh) #'ignore))
       (whatsapp-chat-send-input)
       (should whatsapp-chat--send-pending)
       (should-error (whatsapp-chat-send-input) :type 'user-error)
       (should (= calls 1))
       (funcall callback '(200 ("wuzapi_status" . 200) ("data" ("success" . t) ("data" ("Id" . "fixture-id")))))
       (should-not whatsapp-chat--send-pending)
       (should (equal "" (whatsapp-chat--current-input)))))))

(ert-deftest whatsapp-workspace-send-preserves-newer-draft ()
  (whatsapp-workspace-test-chat
   (insert "hello")
   (let (callback)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _body cb) (setq callback cb)))
               ((symbol-function 'whatsapp-chat-refresh) #'ignore))
       (whatsapp-chat-send-input)
       (insert " newer")
       (funcall callback '(200 ("wuzapi_status" . 200) ("data" ("success" . t) ("data" ("Id" . "fixture-id")))))
       (should (equal "hello newer" (whatsapp-chat--current-input)))))))

(ert-deftest whatsapp-workspace-send-failure-retains-draft-and-reply ()
  (whatsapp-workspace-test-chat
   (insert "do not lose")
   (setq whatsapp-chat--reply '(:id "m1" :participant "5512" :text "quoted"))
   (cl-letf (((symbol-function 'whatsapp--request-async)
              (lambda (_m _p _body cb) (funcall cb '(200 . :invalid-json)))))
     (whatsapp-chat-send-input)
     (should-not whatsapp-chat--send-pending)
     (should whatsapp-chat--reply)
     (should (equal "do not lose" (whatsapp-chat--current-input))))))

(ert-deftest whatsapp-workspace-send-needs-upstream-confirmation ()
  (should (whatsapp--send-accepted-p '(200 ("wuzapi_status" . 201) ("data" ("success" . t) ("data" ("Id" . "fixture-id"))))))
  (dolist (value '((200) (200 . :invalid-json) (200 ("wuzapi_status" . 500)) (503)))
    (should-not (whatsapp--send-accepted-p value))))

(ert-deftest whatsapp-workspace-bounded-history-and-expand ()
  (whatsapp-workspace-test-chat
   (let ((whatsapp-history-page-size 2)
         (messages '((("id" . "old") ("text" . "HIDDEN-OLDEST"))
                     (("id" . "mid") ("text" . "VISIBLE-MIDDLE"))
                     (("id" . "new") ("text" . "VISIBLE-NEWEST")))))
     (insert "retained draft")
     (whatsapp-chat--render messages)
     (should-not (string-match-p "HIDDEN-OLDEST" (buffer-string)))
     ;; Exercise the real UI action, rather than the obsolete RC1 label.
     (let ((button (whatsapp-workspace-test-button #'whatsapp-chat-show-older)))
       (should button)
       (should (button-get button 'follow-link))
       (cl-letf (((symbol-function 'whatsapp--request-async)
                  (lambda (&rest _) (ert-fail "Cached expansion requested network"))))
         (button-activate button)))
     (should (= whatsapp-chat--history-limit 4))
     (should (string-match-p "HIDDEN-OLDEST" (buffer-string)))
     (should-not (whatsapp-workspace-test-button #'whatsapp-chat-show-older))
     (should (equal "retained draft" (whatsapp-chat--current-input))))))

(ert-deftest whatsapp-workspace-account-scoped-cache ()
  (let ((whatsapp-chat--jid "same") (whatsapp-bridge-token "first"))
    (let ((first (whatsapp--media-key "id" "image")))
      (let ((whatsapp-bridge-token "second"))
        (should-not (equal first (whatsapp--media-key "id" "image"))))
      (let ((whatsapp-bridge-url "https://other.example"))
        (should-not (equal first (whatsapp--media-key "id" "image")))))))

(ert-deftest whatsapp-workspace-data-uri-limit-before-decoding ()
  (let ((whatsapp-max-file-bytes 2))
    (should-error (whatsapp--data-uri-bytes "data:image/png;base64,YWJjZA==") :type 'user-error))
  (dolist (uri '("https://evil.example/picture" "data:image/svg+xml,<svg/>" "YWJj"))
    (should-error (whatsapp--data-uri-bytes uri) :type 'user-error)))

(ert-deftest whatsapp-workspace-image-canvas-guards ()
  (let ((png (base64-decode-string "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB")))
    (should (equal (cons 1 1) (whatsapp--image-dimensions png 'png)))
    (should (= 1 (whatsapp--checked-image-pixels png 'png)))
    (let ((whatsapp-image-pixel-limit 0))
      (should-error (whatsapp--checked-image-pixels png 'png) :type 'user-error)))
  (should-not (whatsapp--image-dimensions "truncated" 'jpeg))
  (should-not (whatsapp--image-dimensions "truncated" 'webp))
  (should-error (whatsapp--checked-image-pixels "GIF89a" 'gif) :type 'user-error))

(ert-deftest whatsapp-workspace-preview-reuses-and-bounds-cache ()
  (let ((whatsapp--preview-cache (make-hash-table :test 'equal))
        (whatsapp--preview-order nil) (whatsapp-preview-pixel-budget 2)
        (calls 0) (uri "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"))
    (cl-letf (((symbol-function 'whatsapp--create-image)
               (lambda (&rest _) (cl-incf calls) '(image :type png))))
      (whatsapp--preview-image 'first uri 'png "image")
      (whatsapp--preview-image 'first uri 'png "image")
      (should (= calls 1))
      (whatsapp--preview-image 'second uri 'png "image")
      (whatsapp--preview-image 'third uri 'png "image")
      (should (= 2 (hash-table-count whatsapp--preview-cache)))
      (should-not (gethash 'first whatsapp--preview-cache)))))

(ert-deftest whatsapp-workspace-preview-redraw-is-coalesced ()
  (whatsapp-workspace-test-chat
   (let ((calls 0) callback)
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (_s _r cb) (cl-incf calls) (setq callback cb) 'timer)))
       (whatsapp--schedule-media-redraw) (whatsapp--schedule-media-redraw)
       (should (= calls 1))
       (funcall callback)
       (should-not whatsapp-chat--redraw-timer)))))

(ert-deftest whatsapp-workspace-mpv-argv-local-only ()
  (let ((whatsapp-media-player "mpv") (file "/tmp/a quote'; $(evil).mp4"))
    (let ((args (whatsapp--mpv-command file t)))
      (should (equal (car args) "mpv"))
      (should (member "--no-config" args))
      (should (member "--load-scripts=no" args))
      (should (member "--access-references=no" args))
      (should (member "--demuxer-lavf-o=protocol_whitelist=file" args))
      (should (equal (last args 2) (list "--" file))))))

(ert-deftest whatsapp-workspace-voice-argv-is-bounded ()
  (let ((whatsapp-voice-seconds 9999) (whatsapp-voice-device "default"))
    (let ((args (whatsapp-voice-command "/tmp/private/voice.ogg")))
      (should (equal (cadr (member "-t" args)) "600"))
      (should (member "libopus" args))
      (should (member "pulse" args))
      (should-not (member "-nostdin" args)))))

(ert-deftest whatsapp-workspace-attachment-stage-does-not-send ()
  (whatsapp-workspace-test-chat
   (let ((file (make-temp-file "wa-stage-" nil ".png")) staged)
     (unwind-protect
         (progn
           (with-temp-file file (insert "image"))
           (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer))
                     ((symbol-function 'whatsapp--worker) (lambda (&rest _) (ert-fail "Unexpected automatic upload"))))
             (setq staged (whatsapp--send-media 'image file))
             (setq whatsapp-chat--target "different-chat")
             (with-current-buffer staged
               (should (equal whatsapp--stage-target "5511"))
               (should-not whatsapp--stage-operation)
               (should (string-match-p "Preview" (buffer-string)))
               (should (string-match-p "Send" (buffer-string))))))
       (when (buffer-live-p staged) (kill-buffer staged))
       (delete-file file)))))

(ert-deftest whatsapp-workspace-stage-account-switch-refused ()
  (with-temp-buffer
    (setq whatsapp--stage-url "http://127.0.0.1:7337"
          whatsapp--stage-token-id (secure-hash 'sha256 "first"))
    (let ((whatsapp-bridge-token "second"))
      (should-error (whatsapp-stage-send) :type 'user-error))))

(ert-deftest whatsapp-workspace-media-click-selects-event-point ()
  (let (selected)
    (cl-letf (((symbol-function 'mouse-set-point) (lambda (event) (setq selected event)))
              ((symbol-function 'whatsapp--message-at-point) (lambda () '(("id" . "1") ("kind" . "image") ("media" . (("Url" . "test"))))))
              ((symbol-function 'whatsapp--cache-get) (lambda (_key) "cached"))
              ((symbol-function 'whatsapp--open-uri) #'ignore))
      (whatsapp-chat-open-media-at-point 'event)
      (should (eq selected 'event)))))

(ert-deftest whatsapp-workspace-recording-error-remains-clickable ()
  (with-temp-buffer
    (special-mode)
    (setq whatsapp--stage-target "5511" whatsapp--stage-kind "audio"
          whatsapp--stage-file nil whatsapp--stage-error "Microphone unavailable")
    (whatsapp--stage-render)
    (should (string-match-p "Cancel" (buffer-string)))
    (should (string-match-p "Microphone unavailable" (buffer-string)))))

(ert-deftest whatsapp-workspace-conversion-success-redraws-original-stage ()
  (let ((buffer (generate-new-buffer " *wa-convert-test*")) callback)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (special-mode)
            (setq whatsapp--stage-file "/tmp/original.gif" whatsapp--stage-kind "gif"
                  whatsapp--stage-target "5511")
            (cl-letf (((symbol-function 'whatsapp--worker)
                       (lambda (_operation _payload cb) (setq callback cb) 'mock-process)))
              (whatsapp-stage-convert-gif)))
          ;; Process sentinels may run while a completely different buffer is selected.
          (with-temp-buffer (funcall callback '(("ok" . t))))
          (with-current-buffer buffer
            (should-not whatsapp--stage-operation)
            (should (string-match-p "MP4 copy prepared" (buffer-string)))
            (should (string-match-p "Preview" (buffer-string)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq whatsapp--stage-operation nil)
          (whatsapp--stage-cleanup))
        (kill-buffer buffer)))))

(ert-deftest whatsapp-workspace-media-environment-drops-bridge-secrets ()
  (let ((process-environment '("PATH=/usr/bin" "WHATSAPPEL_TOKEN=secret" "WUZAPI_TOKEN=secret"
                                "SSLKEYLOGFILE=/tmp/debug" "FFREPORT=file=debug.log")))
    (should (equal (whatsapp--media-environment) '("PATH=/usr/bin")))))
