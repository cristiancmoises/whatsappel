;;; whatsapp-org-tests.el --- Org capture/export safety checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'ert)
(require 'whatsapp-org)

(defvar whatsapp-org-test-executed nil)

(ert-deftest whatsapp-org-capture-placeholders-remain-literal ()
  (dolist (payload '("%(progn (setq whatsapp-org-test-executed t) \"executed\")"
                     "\\%(progn (setq whatsapp-org-test-executed t) \"executed\")"
                     "%[definitely-no-such-local-file]" "%t %:annotation"))
    (let* ((whatsapp-org-test-executed nil)
           (org-capture-plist nil)
           (org-store-link-plist nil)
           (expanded (org-capture-fill-template (whatsapp-org--esc payload))))
      (should-not whatsapp-org-test-executed)
      (should (string-match-p (regexp-quote payload) expanded)))))

(ert-deftest whatsapp-org-capture-cannot-escape-example-block ()
  (let* ((template (whatsapp-org--capture-template
                    "123@s.whatsapp.net" "Name\n* injected" "Sender\n:END:"
                    0 "hello\n#+end_example\n#+begin_src emacs-lisp\n(danger)\n#+end_src\n* evil"))
         (body (nth 4 template)))
    (with-temp-buffer
      (insert body) (org-mode)
      (let ((tree (org-element-parse-buffer)))
        (should (= 1 (length (org-element-map tree 'headline #'identity))))
        (should (= 1 (length (org-element-map tree 'example-block #'identity))))
        (should-not (org-element-map tree 'src-block #'identity))))))

(ert-deftest whatsapp-org-export-does-not-run-code ()
  (let ((whatsapp-org-test-executed nil)
        (org-confirm-babel-evaluate nil))
    (whatsapp-org--export
     "#+begin_src emacs-lisp :exports results\n(setq whatsapp-org-test-executed t)\n#+end_src")
    (should-not whatsapp-org-test-executed)
    (whatsapp-org--export
     "#+MACRO: evil (eval (progn (setq whatsapp-org-test-executed t) \"ran\"))\n{{{evil}}}")
    (should-not whatsapp-org-test-executed)))

(ert-deftest whatsapp-org-export-does-not-include-local-files ()
  (let ((f (make-temp-file "whatsapp-org-include-" nil ".txt" "PRIVATE-FILE-CONTENT")))
    (unwind-protect
        (should-not (string-match-p
                     "PRIVATE-FILE-CONTENT"
                     (whatsapp-org--export (format "#+INCLUDE: %S\n" f))))
      (delete-file f))))

(ert-deftest whatsapp-org-pq-capture-only-uses-displayed-plaintext ()
  (let ((whatsapp-chat--jid "123@s.whatsapp.net")
        (whatsapp-pq--plain-cache (make-hash-table :test 'equal))
        (msg '(("id" . "message-id") ("text" . "WAPQ1:blob"))))
    (should (string-prefix-p "[encrypted" (whatsapp-org--message-text msg)))
    (puthash (list whatsapp-chat--jid "message-id" "WAPQ1:blob") :fail whatsapp-pq--plain-cache)
    (should (string-prefix-p "[encrypted" (whatsapp-org--message-text msg)))
    (puthash (list whatsapp-chat--jid "message-id" "WAPQ1:blob") "already displayed" whatsapp-pq--plain-cache)
    (should (equal "already displayed" (whatsapp-org--message-text msg)))))
