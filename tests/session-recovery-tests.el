;;; session-recovery-tests.el --- connection regression tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'cl-lib)
(require 'whatsapp)

(defmacro wa19-session-fixture (&rest body)
  `(let ((whatsapp-bridge-url "http://127.0.0.1:7337")
         (whatsapp-bridge-token "fixture-session-token")
         (whatsapp--session-snapshot nil))
     (with-temp-buffer
       (special-mode)
       (setq-local whatsapp--transport-origin (whatsapp--origin-key))
       (setq-local whatsapp--transport-generation 0)
       (setq-local whatsapp--closing nil)
       ,@body)))

(ert-deftest wa19-cached-history-never-implies-connected ()
  (wa19-session-fixture
   (setq-local whatsapp--has-snapshot t whatsapp--last-refresh-time (float-time))
   (whatsapp-session-observe '(("session_state" . "disconnected") ("checked" . t) ("checked_age" . 0)) (whatsapp--origin-key))
   (should (string-match-p "Backend disconnected" (whatsapp--status-label)))
   (should (string-match-p "Cached snapshot" (whatsapp--status-label)))))

(ert-deftest wa19-stale-state-does-not-show-connected ()
  (wa19-session-fixture
   (dolist (data '((("session_state" . "ready") ("checked" . t) ("checked_age" . 100))
                  (("session_state" . "ready") ("checked" . nil) ("checked_age" . 0))
                  (("session_state" . "ready") ("checked" . t) ("checked_age" . "0"))
                  :invalid-json))
     (whatsapp-session-observe data (whatsapp--origin-key))
     (should (string-match-p "unverified" (whatsapp-session-label))))))

(ert-deftest wa19-status-does-not-leak-to-another-account ()
  (wa19-session-fixture
   (whatsapp-session-observe '(("session_state" . "ready") ("checked" . t) ("checked_age" . 0)) (whatsapp--origin-key))
   (setq whatsapp-bridge-token "another-fixture-account")
   (should (string-match-p "unverified" (whatsapp-session-label)))))

(ert-deftest wa19-connect-cancel-has-no-write ()
  (wa19-session-fixture
   (let (called)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
               ((symbol-function 'whatsapp--request-async) (lambda (&rest _) (setq called t))))
       (whatsapp-connection-connect)
       (should-not called)))))

(ert-deftest wa19-connect-needs-matching-panel-account ()
  (wa19-session-fixture
   (setq whatsapp--transport-origin '("other" "account"))
   (should-error (whatsapp-connection-connect) :type 'user-error)))

(ert-deftest wa19-connect-exact-route-payload-one-write ()
  (wa19-session-fixture
   (let (calls)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
               ((symbol-function 'whatsapp--request-async)
                (lambda (method path payload _callback) (push (list method path payload) calls))))
       (whatsapp-connection-connect)
       (should (equal calls '(("POST" "/transport/connect" ((confirm . t))))))
       (should-error (whatsapp-connection-connect) :type 'user-error)
       (should (= (length calls) 1))))))

(ert-deftest wa19-start-error-releases-panel-pending ()
  (wa19-session-fixture
   (cl-letf (((symbol-function 'whatsapp--request-async) (lambda (&rest _) (error "fixture"))))
     (whatsapp--transport-action "/transport/connect" '((confirm . t)))
     (should-not whatsapp--transport-pending))))

(ert-deftest wa19-late-operation-cannot-touch-new-account ()
  (wa19-session-fixture
   (let (callback fetched)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (_method _path _payload cb) (setq callback cb)))
               ((symbol-function 'whatsapp--transport-fetch) (lambda (&optional _) (setq fetched t))))
       (whatsapp--transport-action "/transport/connect" '((confirm . t)))
       (setq whatsapp-bridge-token "new-fixture-account")
       (cl-incf whatsapp--transport-generation)
       (funcall callback '(202 ("accepted" . t)))
       (should whatsapp--transport-pending)
       (should-not fetched)))))

(ert-deftest wa19-malformed-operation-result-does-not-start-watch ()
  (wa19-session-fixture
   (cl-letf (((symbol-function 'whatsapp--request-async)
              (lambda (_m _p _o cb) (funcall cb '(202 . :invalid-json)))))
     (whatsapp--transport-action "/transport/connect" '((confirm . t)))
     (should-not whatsapp--transport-pending)
     (should (= whatsapp--transport-watch-until 0)))))

(ert-deftest wa19-session-refresh-is-bounded-and-read-only ()
  (wa19-session-fixture
   (let (calls)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (m p payload cb)
                  (push (list m p payload) calls)
                  (funcall cb '(200 ("session_state" . "ready") ("checked" . t) ("checked_age" . 0))))))
       (dotimes (_ 100) (whatsapp-session-refresh))
       (should (equal calls '(("GET" "/transport/status" nil))))
       (should (string-match-p "Backend connected" (whatsapp-session-label)))))))

(ert-deftest wa19-fresh-check-does-not-request-connect ()
  (wa19-session-fixture
   (let (calls)
     (cl-letf (((symbol-function 'whatsapp--request-async)
                (lambda (m p payload _cb) (push (list m p payload) calls))))
       (whatsapp-connection-refresh)
       (should (equal calls '(("GET" "/transport/status?refresh=1" nil))))))))

(ert-deftest wa19-recovered-profile-backoff-preserves-consent-and-images ()
  (wa19-session-fixture
   (let ((whatsapp-profiles--scope (whatsapp--origin-key))
         (whatsapp-profiles--consent-origin (whatsapp--origin-key))
         (whatsapp-profiles--meta (make-hash-table :test 'equal))
         (whatsapp-profiles--photos (make-hash-table :test 'equal)))
     (puthash "fixture" '(:photo-next 999999 :subscribe-next 999999) whatsapp-profiles--meta)
     (puthash 'fixture-image 'keep whatsapp-profiles--photos)
     (whatsapp-profiles-session-recovered)
     (should (equal whatsapp-profiles--consent-origin (whatsapp--origin-key)))
     (should (eq (gethash 'fixture-image whatsapp-profiles--photos) 'keep))
     (should (= (plist-get (gethash "fixture" whatsapp-profiles--meta) :photo-next) 0)))))

(ert-deftest wa19-qr-failure-does-not-log-raw-provider-body ()
  (wa19-session-fixture
   (let (messages)
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
               ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
               ((symbol-function 'whatsapp--request-async)
                (lambda (_m _p _o cb) (funcall cb '(502 ("data" . "PRIVATE_PROVIDER_TEXT"))))))
       (whatsapp-qr)
       (should-not (string-match-p "PRIVATE_PROVIDER_TEXT" (mapconcat #'identity messages " ")))))))
