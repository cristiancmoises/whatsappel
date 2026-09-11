;;; benchmark-profiles.el --- native cached-selection samples -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
;; Target: cached-selection p95 <100ms on the declared machine, NOT provider latency.
;; Report budget attainment; never hide an outlier. No synthetic result is prefilled.
(require 'whatsapp)
(require 'json)
(require 'cl-lib)
(defun wa-profile-bench-percentile (values q)
  (nth (min (1- (length values)) (max 0 (1- (ceiling (* q (length values))))))
       (sort (copy-sequence values) #'<)))
(let ((whatsapp-auto-poll nil) (whatsapp-auto-load-images nil)
      (whatsapp-workspace-sidebar nil) results)
  (dolist (size '(1000 10000))
    (let* ((whatsapp--chats
            (cl-loop for i from 1 to size collect
                     (list (cons "jid" (number-to-string (+ 15550000000 i)))
                           (cons "name" (format "Synthetic contact %d" i))
                           (cons "last" "Synthetic cached preview") (cons "unread" 0))))
           (jid "15550000001") (buf (generate-new-buffer " *profile-benchmark*"))
           samples first root-time)
      (unwind-protect
          (save-window-excursion
            (with-temp-buffer
              (whatsapp-root-mode)
              (let ((start (float-time)))
                (whatsapp-root--render whatsapp--chats)
                (setq root-time (* 1000 (- (float-time) start)))))
            (with-current-buffer buf
              (whatsapp-chat-mode)
              (setq whatsapp-chat--jid jid whatsapp-chat--target jid))
            (cl-letf (((symbol-function 'whatsapp--chat-buffer) (lambda (_) buf))
                      ((symbol-function 'whatsapp--ensure-polling) (lambda () nil)))
              (dotimes (i 21)
                (let ((start (float-time)))
                  (whatsapp-open-chat jid)
                  (let ((ms (* 1000 (- (float-time) start))))
                    (if (= i 0) (setq first ms) (push ms samples))))
                (with-current-buffer buf
                  (when (timerp whatsapp--open-timer) (cancel-timer whatsapp--open-timer))
                  (setq whatsapp--open-timer nil)
                  (when (= i 0) (insert "unchanged synthetic draft"))
                  (unless (equal (whatsapp-chat--current-input) "unchanged synthetic draft")
                    (error "Benchmark changed draft")))))
            (push `((cached_conversations . ,size) (initial_visible_rows . 80)
                    (first_composer_selection_ms . ,first) (root_layout_ms . ,root-time)
                    (warm_raw_ms . ,(vconcat (nreverse samples)))
                    (warm_median_ms . ,(wa-profile-bench-percentile samples .5))
                    (warm_p95_ms . ,(wa-profile-bench-percentile samples .95))
                    (warm_worst_ms . ,(apply #'max samples))
                    (target_p95_ms . 100)
                    (target_met . ,(if (< (wa-profile-bench-percentile samples .95) 100) t :json-false))) results))
        (when (buffer-live-p buf) (kill-buffer buf)))))
  (princ (json-encode `((scope . "Native batch cached selection only; no HTTP, decoder or recipient")
                        (emacs_version . ,emacs-version) (system . ,system-configuration)
                        (measurements . ,(vconcat (nreverse results))))))
  (terpri))
