;;; benchmark-client.el --- Synthetic layout cost; NOT network latency -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
(require 'benchmark)
(require 'json)
(load (expand-file-name "whatsapp.el" default-directory) nil t)
(let* ((whatsapp-auto-load-images nil)
       (whatsapp--chats (cl-loop for i from 1 to 1000 collect
                                (list (cons "jid" (number-to-string i)) (cons "name" (format "Fixture %d" i))
                                      (cons "last" "Synthetic preview") (cons "unread" 0))))
       (messages (cl-loop for i from 1 to 501 collect
                          (list (cons "id" (format "fixture-%d" i)) (cons "text" "Synthetic text")
                                (cons "kind" "text") (cons "ts" (+ 1700000000 i)))))
       root-time full-time slide-time)
  (with-temp-buffer
    (whatsapp-root-mode)
    (setq root-time (car (benchmark-run 5 (whatsapp-root--render whatsapp--chats)))))
  (with-temp-buffer
    (whatsapp-chat-mode) (setq whatsapp-chat--jid "fixture")
    (setq full-time (car (benchmark-run 5 (whatsapp-chat--render (cl-subseq messages 0 500)))))
    (insert "draft fixture")
    (setq slide-time (car (benchmark-run 1 (whatsapp-chat--update-messages (cdr messages)))))
    (unless (equal (whatsapp-chat--current-input) "draft fixture") (error "Benchmark lost draft")))
  (princ (json-encode `((scope . "Synthetic batch Emacs layout only; no GUI, images, network or account")
                         (emacs_version . ,emacs-version)
                         (root_1000_chats_80_rows_5_runs_seconds . ,root-time)
                         (history_500_retained_60_rows_5_runs_seconds . ,full-time)
                         (sliding_window_1_run_seconds . ,slide-time))))
  (terpri))
