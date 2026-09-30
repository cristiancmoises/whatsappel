;;; media-profile-repair-tests.el --- Native RC18 regressions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'cl-lib)
(require 'whatsapp)
(require 'profiles-tests)

(ert-deftest wa-rc18-download-dispatches-to-bounded-worker ()
  (dolist (path '("/download" "/download?async=1"))
    (let (called)
      (cl-letf (((symbol-function 'whatsapp--read-worker)
                 (lambda (p _callback payload) (setq called (list p payload))))
                ((symbol-function 'whatsapp--url-request-async)
                 (lambda (&rest _) (ert-fail "Media must not use legacy URL transport"))))
        (whatsapp--request-async "POST" path '((kind . "image")) #'ignore))
      (should (equal called (list path '((kind . "image"))))))))

(ert-deftest wa-rc18-read-and-send-routes-stay-distinct ()
  (dolist (path '("/send/verified" "/media-job?id=123:1:media"))
    (let (called)
      (cl-letf (((symbol-function 'whatsapp--read-worker)
                 (lambda (p _callback &optional payload) (setq called p))))
        (whatsapp--request-async (if (string-prefix-p "/send" path) "POST" "GET") path nil #'ignore))
      (should (equal called path)))))

(ert-deftest wa-rc18-media-failure-label-is-redacted ()
  (should (string-match-p "authentication" (whatsapp--media-failure-label '(401 ("error" . "PRIVATE")))))
  (should-not (string-match-p "PRIVATE" (whatsapp--media-failure-label '(502 ("error" . "PRIVATE")))))
  (should (stringp (whatsapp--media-failure-label '(nil . :invalid-json)))))

(ert-deftest wa-rc18-media-provider-reason-is-actionable ()
  (should (string-match-p "user token" (whatsapp--media-failure-label '(502 ("reason" . "provider-auth")))))
  (should (string-match-p "busy" (whatsapp--media-failure-label '(429))))
  (should (string-match-p "expired" (whatsapp--media-failure-label '(410)))))

(ert-deftest wa-rc18-profile-malformed-body-never-throws ()
  (dolist (text '("8" "{\"body\":8}" "{\"body\":\"PRIVATE\"}" "null"))
    (let ((out (whatsapp-profiles--worker-result 'exit 1 text)))
      (should (equal (cdr (assoc "state" (cdr (assoc "body" out)))) "unavailable")))))

(ert-deftest wa-rc18-busy-photo-is-not-cached-for-two-minutes ()
  (wa-profile-fixture
   (let ((now (float-time)))
     (whatsapp-profiles--accept '(avatar "123456789")
       '(("status" . 429) ("body" ("state" . "unavailable") ("reason" . "bridge-busy"))))
     (let ((rec (gethash "123456789" whatsapp-profiles--meta)))
       (should (equal (plist-get rec :photo-reason) "bridge-busy"))
       (should (< (plist-get rec :photo-next) (+ now 10)))))))

(ert-deftest wa-rc18-lastseen-observation-is-not-presence ()
  (wa-profile-fixture
   (puthash "123456789" '(:availability "unknown" :last-seen-observed 1700000000) whatsapp-profiles--meta)
   (should (equal (whatsapp-profiles--presence-label "123456789") "Status unavailable"))
   (should (string-match-p "Previous last-seen" (whatsapp-profiles--presence-context "123456789")))))

(ert-deftest wa-rc18-groups-have-no-invented-online-state ()
  (wa-profile-fixture
   (should (string-match-p "Groups" (whatsapp-profiles--presence-context "123456789@g.us")))))

(ert-deftest wa-rc18-profile-events-cancel-does-not-post ()
  (let* ((whatsapp--transport-origin (whatsapp--origin-key)) (whatsapp--transport-pending nil))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'whatsapp--request-async) (lambda (&rest _) (ert-fail "Cancelled repair sent a request"))))
      (whatsapp-repair-profile-events))))

(ert-deftest wa-rc18-profile-events-post-separate-flag-without-reconnect ()
  (let* ((whatsapp--transport-origin (whatsapp--origin-key)) (whatsapp--transport-pending nil) sent)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'whatsapp--request-async)
               (lambda (method path payload _cb) (setq sent (list method path payload)))))
      (whatsapp-repair-profile-events))
    (should (equal (car sent) "POST"))
    (should (equal (cadr sent) "/transport/repair"))
    (should (eq (alist-get 'profiles (caddr sent)) t))
    (should (eq (alist-get 'replace (caddr sent)) :json-false))))

(ert-deftest wa-rc18-profile-success-exit-requires-an-object-body ()
  (dolist (text '("8" "{\"status\":200,\"body\":8}" "null"))
    (let ((out (whatsapp-profiles--worker-result 'exit 0 text)))
      (should (equal (cdr (assoc "state" (cdr (assoc "body" out)))) "unavailable")))))

(provide 'media-profile-repair-tests)
