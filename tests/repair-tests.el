;;; repair-tests.el --- RC16 send/photo/row regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'cl-lib)
(require 'hl-line)
(require 'whatsapp)
(require 'profiles-tests)
(require 'performance-tests)
(require 'delivery-tests)

(ert-deftest wa-rc16-send-uses-verified-route-and-keeps-lid ()
  (wa-rc2-chat
   (setq whatsapp-chat--jid "123456789@lid" whatsapp-chat--target "123456789")
   (whatsapp-chat--render nil) (insert "test draft")
   (let (path sent callback)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_method endpoint payload cb) (setq path endpoint sent payload callback cb))))
       (whatsapp-chat-send-input))
     (should (equal path "/send/verified"))
     (should (equal (cdr (assoc "to" sent)) "123456789@lid"))
     (funcall callback '(404 ("error" . "Verified send route unavailable. Install and activate the matching bridge before sending.")))
     (should (equal (whatsapp-chat--current-input) "test draft"))
     (should (string-match-p "activate" whatsapp--last-error))
     (should (eq (plist-get (car whatsapp-chat--outgoing) :state) 'unconfirmed)))))

(ert-deftest wa-rc16-send-provider-rejection-keeps-newer-draft ()
  (wa-rc2-chat
   (whatsapp-chat--render nil) (insert "initial")
   (let (callback)
     (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m _p _d cb) (setq callback cb))))
       (whatsapp-chat-send-input))
     (insert " newer")
     (funcall callback '(502 ("error" . "Provider rejected the recipient or request. Draft retained; verify the contact identity.")))
     (should (equal (whatsapp-chat--current-input) "initial newer"))
     (should (string-match-p "verify the contact identity" whatsapp--last-error)))))

(ert-deftest wa-rc16-send-does-not-display-untrusted-provider-message ()
  (wa-rc2-chat
   (whatsapp-chat--render nil) (insert "private draft")
   (let (callback)
     (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (_m _p _d cb) (setq callback cb))))
       (whatsapp-chat-send-input))
     (funcall callback '(502 ("error" . "UNTRUSTED_CONTACT_TOKEN")))
     (should-not (string-match-p "UNTRUSTED" whatsapp--last-error))
     (should (equal (whatsapp-chat--current-input) "private draft")))))

(ert-deftest wa-rc16-profile-nonzero-retains-only-safe-failure-stage ()
  (let* ((raw "{\"status\":null,\"body\":{\"state\":\"unavailable\",\"reason\":\"cdn-policy\",\"url\":\"PRIVATE\",\"error\":\"PRIVATE\"}}")
         (out (whatsapp-profiles--worker-result 'exit 1 raw)))
    (should (equal (cdr (assoc "reason" (cdr (assoc "body" out)))) "cdn-policy"))
    (should-not (string-match-p "PRIVATE" (prin1-to-string out)))
    (should-not (cdr (assoc "status" out)))))

(ert-deftest wa-rc16-profile-nonzero-cannot-publish-ready-image ()
  (let ((out (whatsapp-profiles--worker-result 'exit 1
              "{\"status\":200,\"body\":{\"state\":\"ready\",\"png\":\"PRIVATE\"}}")))
    (should-not (cdr (assoc "status" out)))
    (should (equal (cdr (assoc "state" (cdr (assoc "body" out)))) "unavailable"))
    (should-not (assoc "png" (cdr (assoc "body" out))))))

(ert-deftest wa-rc16-profile-signal-or-malformed-output-becomes-safe-failure ()
  (dolist (state '(exit signal failed))
    (let ((out (whatsapp-profiles--worker-result state 1 "UNTRUSTED")))
      (should (equal (cdr (assoc "reason" (cdr (assoc "body" out)))) "worker-failed"))
      (should-not (string-match-p "UNTRUSTED" (prin1-to-string out))))))

(ert-deftest wa-rc16-profile-success-body-is-retained ()
  (should (equal (whatsapp-profiles--worker-result 'exit 0
                   "{\"status\":200,\"body\":{\"version\":1}}")
                 '(("status" . 200) ("body" ("version" . 1))))))

(ert-deftest wa-rc16-photo-failure-updates-contact-specific-metadata ()
  (wa-profile-fixture
   (puthash "987654321" '(:about "other contact") whatsapp-profiles--meta)
   (whatsapp-profiles--accept '(avatar "123456789")
      '(("status") ("body" ("state" . "unavailable") ("reason" . "cdn-policy"))))
   (should (equal (plist-get (gethash "123456789" whatsapp-profiles--meta) :photo-reason) "cdn-policy"))
   (should (equal (plist-get (gethash "987654321" whatsapp-profiles--meta) :about) "other contact"))
   (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
     (should (string-match-p "CDN policy" (whatsapp-profiles--photo-label "123456789"))))))

(ert-deftest wa-rc16-photo-retry-does-not-clear-consent-or-other-contacts ()
  (wa-profile-fixture
   (with-temp-buffer
     (setq-local whatsapp-profiles--detail-jid "123456789")
     (setq-local whatsapp-profiles--detail-origin (whatsapp--origin-key))
     (setq whatsapp-profiles--consent-origin (whatsapp--origin-key))
     (puthash "987654321" '(:about "keep") whatsapp-profiles--meta)
     (cl-letf (((symbol-function 'whatsapp-profiles-start) #'ignore))
       (whatsapp-profile-retry-photo))
     (should (equal whatsapp-profiles--consent-origin (whatsapp--origin-key)))
     (should (equal (gethash "987654321" whatsapp-profiles--meta) '(:about "keep")))
     (should (member '(avatar "123456789") whatsapp-profiles--queue))
     (should-not (member '(avatar "987654321") whatsapp-profiles--queue)))))

(ert-deftest wa-rc16-photo-retry-refuses-previous-account ()
  (wa-profile-fixture
   (with-temp-buffer
     (setq-local whatsapp-profiles--detail-jid "123456789")
     (setq-local whatsapp-profiles--detail-origin "another-account")
     (should-error (whatsapp-profile-retry-photo) :type 'user-error)
     (should-not whatsapp-profiles--queue))))

(ert-deftest wa-rc16-explicit-row-and-hover-faces-remove-all-lines ()
  (let ((whatsapp-profile-clean-lines t))
    (dolist (face (list (whatsapp-profiles--row-face nil)
                        (whatsapp-profiles--row-face t)
                        (whatsapp-profiles--hover-face)))
      (dolist (attr '(:underline :overline :strike-through :box :extend))
        (should (plist-member face attr))
        (should-not (plist-get face attr))))))

(ert-deftest wa-rc16-local-setup-removes-only-the-global-hl-line-overlay ()
  (let ((global-hl-line-overlay nil) (global-hl-line-mode t)
        (whatsapp-profile-clean-lines t) (whatsapp-profiles--buffers nil))
    (with-temp-buffer
      (insert "keep all text\n")
      (let ((unrelated (make-overlay 1 2)) (before (buffer-string)))
        (setq global-hl-line-overlay (make-overlay 1 4))
        (whatsapp-profiles--setup-buffer)
        (should (or (null global-hl-line-overlay)
                    (null (overlay-buffer global-hl-line-overlay))))
        (should (eq (overlay-buffer unrelated) (current-buffer)))
        (should (equal (buffer-string) before))
        (should (eq cursor-type 'bar))
        (delete-overlay unrelated)))))

(ert-deftest wa-rc16-selection-repeatedly-keeps-text-point-and-other-overlays ()
  (wa-profile-fixture
   (with-temp-buffer
     (let ((inhibit-read-only t))
       (insert (propertize "Alpha\npreview\n" 'whatsapp-jid "123456789")
               (propertize "Beta\npreview\n" 'whatsapp-jid "987654321")))
     (cl-letf (((symbol-function 'whatsapp-profiles-start) #'ignore))
       (whatsapp-root-mode))
     (let ((before (buffer-string)) (pos (point)) (own (make-overlay 1 2)))
       (dotimes (n 300)
         (whatsapp-root--select-only (if (zerop (% n 2)) "123456789" "987654321")))
       (should (equal (substring-no-properties (buffer-string)) (substring-no-properties before)))
       (should (= pos (point)))
       (should (eq (overlay-buffer own) (current-buffer)))
       (delete-overlay own)))))


(ert-deftest wa-rc16-local-setup-leaves-another-buffers-highlight-alone ()
  (let ((other (generate-new-buffer " *wa-other-editor*")) highlight
        (global-hl-line-mode t) (whatsapp-profile-clean-lines t)
        (whatsapp-profiles--buffers nil))
    (unwind-protect
        (progn
          (with-current-buffer other
            (insert "unrelated editor text")
            (setq global-hl-line-overlay (make-overlay 1 4))
            (setq highlight global-hl-line-overlay))
          (with-temp-buffer
            (whatsapp-profiles--setup-buffer)
            (should (eq (overlay-buffer highlight) other))))
      (when (overlayp highlight) (delete-overlay highlight))
      (kill-buffer other))))


;;; RC17: failure rendering must not treat an invalid-JSON sentinel as an alist.
(defmacro wa-rc17-failure-chat (&rest body)
  "Use a private synthetic chat; never call a live bridge."
  `(wa-profile-fixture
    (wa-rc2-chat
     (setq whatsapp-chat--jid "123456789@lid")
     (whatsapp-chat--render nil)
     (buffer-enable-undo)
     (setq buffer-undo-list nil)
     (insert "retained draft")
     (setq whatsapp-chat--reply '(:id "reply-id" :participant "987654321@lid" :text "quoted"))
     ,@body)))

(defun wa-rc17-check-failed-result (result &optional expected)
  "Exercise a deferred RESULT and check draft/reply/undo and no retry."
  (wa-rc17-failure-chat
   (let ((calls 0) (refreshes 0) callback)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (method path payload cb)
                  (cl-incf calls)
                  (should (equal method "POST"))
                  (should (equal path "/send/verified"))
                  (should (equal (cdr (assoc "to" payload)) "123456789@lid"))
                  (setq callback cb)))
               ((symbol-function 'whatsapp-chat-refresh)
                (lambda (&rest _) (cl-incf refreshes))))
       (whatsapp-chat-send-input)
       (should whatsapp-chat--send-pending)
       (insert " newer edit")
       (let ((text (buffer-string)) (position (point))
             (marker whatsapp-chat--input-marker)
             (marker-pos (marker-position whatsapp-chat--input-marker))
             (reply whatsapp-chat--reply) (undo buffer-undo-list)
             (tick (buffer-chars-modified-tick)))
         (funcall callback result)
         (should-not whatsapp-chat--send-pending)
         (should (equal (buffer-string) text))
         (should (= (point) position))
         (should (eq whatsapp-chat--input-marker marker))
         (should (= (marker-position marker) marker-pos))
         (should (eq whatsapp-chat--reply reply))
         (should (eq buffer-undo-list undo))
         (should (= (buffer-chars-modified-tick) tick))
         (should (equal (whatsapp-chat--current-input) "retained draft newer edit"))
         (should (equal whatsapp--last-error
                        (or expected "Unconfirmed send. Draft retained; check recipient before retrying.")))
         (should (eq (plist-get (car whatsapp-chat--outgoing) :state) 'unconfirmed))
         (should-not (plist-get (car whatsapp-chat--outgoing) :message-id))
         (should (= calls 1))
         (should (= refreshes 0))
         ;; A late, contradictory duplicate must not upgrade the attempt.
         (funcall callback '(200 ("wuzapi_status" . 200)
                                ("data" ("success" . t) ("data" ("Id" . "duplicate-id")))))
         (should (eq (plist-get (car whatsapp-chat--outgoing) :state) 'unconfirmed))
         (should (eq whatsapp-chat--reply reply))
         (should (equal (buffer-string) text))
         (should (= calls 1))
         (should (= refreshes 0)))))))

(ert-deftest wa-rc17-invalid-json-deferred-preserves-newer-draft-and-reply ()
  (wa-rc17-check-failed-result '(200 . :invalid-json)))

(ert-deftest wa-rc17-scalar-error-body-does-not-escape-callback ()
  (dolist (body '(:invalid-json "PRIVATE_RAW_ERROR" 42 t ["PRIVATE_RAW_ERROR"]))
    (wa-rc17-check-failed-result (cons 200 body))))

(ert-deftest wa-rc17-empty-and-transport-failures-stay-unconfirmed ()
  (dolist (result '(nil (200) (503) (nil . :invalid-json)
                      (nil ("error" . "Request timed out"))))
    (wa-rc17-check-failed-result result)))

(ert-deftest wa-rc17-allowlisted-failure-messages-are-preserved ()
  (dolist (reason '("Verified send route unavailable. Install and activate the matching bridge before sending."
                    "Recipient acknowledgement mismatch. Draft retained; do not resend."
                    "Provider authentication failed. Draft retained; check the existing session configuration."
                    "Provider denied the request. Draft retained; check account permissions."
                    "Provider rejected the recipient or request. Draft retained; verify the contact identity."))
    (wa-rc17-check-failed-result (list 502 (cons "error" reason)) reason)))

(ert-deftest wa-rc17-untrusted-error-values-are-not-displayed ()
  (dolist (reason '("PRIVATE_TOKEN_CONTACT" ("PRIVATE_TOKEN_CONTACT") ["PRIVATE_TOKEN_CONTACT"] 9 t nil))
    (wa-rc17-check-failed-result (list 502 (cons "error" reason)))))

(ert-deftest wa-rc17-invalid-json-synchronous-never-resends ()
  (wa-rc17-failure-chat
   (let ((calls 0) (reply whatsapp-chat--reply))
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_method _path _payload callback)
                  (cl-incf calls)
                  (funcall callback '(200 . :invalid-json))))
               ((symbol-function 'whatsapp-chat-refresh)
                (lambda (&rest _) (ert-fail "Failure must not start history refresh"))))
       (whatsapp-chat-send-input)
       (should-not whatsapp-chat--send-pending)
       (should (eq whatsapp-chat--reply reply))
       (should (equal (whatsapp-chat--current-input) "retained draft"))
       (should whatsapp--last-error)
       (should-error (whatsapp-chat-send-input) :type 'user-error)
       (should (= calls 1))))))

(ert-deftest wa-rc17-failed-callback-belongs-to-original-buffer ()
  (wa-rc17-failure-chat
   (let (callback)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _d cb) (setq callback cb))))
       (whatsapp-chat-send-input))
     (with-temp-buffer
       (insert "unrelated editor buffer")
       (setq-local whatsapp--last-error "other error")
       (funcall callback '(200 . :invalid-json))
       (should (equal (buffer-string) "unrelated editor buffer"))
       (should (equal whatsapp--last-error "other error")))
     (should-not whatsapp-chat--send-pending)
     (should (equal (whatsapp-chat--current-input) "retained draft"))
     (should whatsapp-chat--reply))))

(ert-deftest wa-rc17-closed-owner-does-not-consume-failed-response ()
  (let ((owner (generate-new-buffer " *wa-rc17-closed-owner*")) callback)
    (unwind-protect
        (progn
          (with-current-buffer owner
            (whatsapp-chat-mode)
            (setq whatsapp-chat--jid "123456789@lid")
            (let ((whatsapp-auto-load-images nil)) (whatsapp-chat--render nil))
            (insert "draft")
            (cl-letf (((symbol-function 'whatsapp--request-async)
                       (lambda (_m _p _d cb) (setq callback cb))))
              (whatsapp-chat-send-input)))
          (kill-buffer owner)
          (with-temp-buffer
            (insert "unrelated")
            (funcall callback '(200 . :invalid-json))
            (should (equal (buffer-string) "unrelated"))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest wa-rc17-failed-response-after-account-change-keeps-warning ()
  (wa-rc17-failure-chat
   (let (callback)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _d cb) (setq callback cb))))
       (whatsapp-chat-send-input))
     (let ((whatsapp-bridge-token "different-test-account"))
       (funcall callback '(200 . :invalid-json)))
     (should (equal (whatsapp-chat--current-input) "retained draft"))
     (should whatsapp-chat--reply)
     (should (equal whatsapp--last-error
                    "Account or conversation changed while sending. Draft retained; delivery unconfirmed."))
     (should (eq (plist-get (car whatsapp-chat--outgoing) :state) 'unconfirmed)))))

(ert-deftest wa-rc17-valid-acceptance-still-clears-only-unchanged-draft ()
  (wa-rc17-failure-chat
   (let ((calls 0) (refreshes 0) callback)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _d cb) (cl-incf calls) (setq callback cb)))
               ((symbol-function 'whatsapp-chat-refresh)
                (lambda (&rest _) (cl-incf refreshes))))
       (whatsapp-chat-send-input)
       (funcall callback '(200 ("wuzapi_status" . 200)
                              ("recipient_contract" . 1) ("accepted_chat" . "123456789@lid")
                              ("data" ("success" . t) ("data" ("Id" . "accepted-test-id")))))
       (should (= calls 1)) (should (= refreshes 1))
       (should-not whatsapp-chat--send-pending)
       (should-not whatsapp-chat--reply)
       (should-not whatsapp--last-error)
       (should (equal (whatsapp-chat--current-input) ""))
       (should (eq (plist-get (car whatsapp-chat--outgoing) :state) 'accepted))
       (should (equal (plist-get (car whatsapp-chat--outgoing) :message-id) "accepted-test-id"))))))

(provide 'repair-tests)
