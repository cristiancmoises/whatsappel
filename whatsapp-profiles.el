;;; whatsapp-profiles.el --- bounded native profile workspace -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
;; Loaded by whatsapp.el after the core definitions. No standalone account setup.
;;; Code:
(require 'cl-lib)
(require 'face-remap)
(require 'button)
(require 'subr-x)

(defgroup whatsapp-profiles nil "Native profiles and observed presence." :group 'whatsapp)
(defcustom whatsapp-profile-photos t
  "Load a bounded visible set of authenticated profile photographs."
  :type 'boolean :group 'whatsapp-profiles)
(defcustom whatsapp-profile-palette 'cyan
  "Buffer-local palette.  `current' keeps the existing Emacs theme."
  :type '(choice (const cyan) (const current)) :group 'whatsapp-profiles)
(defcustom whatsapp-profile-presence-enabled nil
  "Enable selected-contact presence only after explicit account-scoped consent.
Use `whatsapp-profile-toggle-presence'; setting this alone does not subscribe."
  :type 'boolean :group 'whatsapp-profiles)
(defface whatsapp-profile-muted '((t (:inherit shadow))) "Secondary information." :group 'whatsapp-profiles)
(defface whatsapp-profile-online '((t (:inherit success :weight bold))) "Observed online." :group 'whatsapp-profiles)
(defface whatsapp-profile-unknown '((t (:inherit shadow))) "Unavailable presence." :group 'whatsapp-profiles)
(defface whatsapp-profile-avatar '((t (:inherit font-lock-type-face :weight bold))) "Photo fallback." :group 'whatsapp-profiles)
(defface whatsapp-profile-selection '((t (:background "#17313d" :foreground "#ffffff" :weight bold :underline nil :overline nil :strike-through nil :box nil))) "Selected chat." :group 'whatsapp-profiles)

(defface whatsapp-profile-hover
  '((t (:background "#15252e" :foreground "#e2eaef" :underline nil
        :overline nil :strike-through nil :box nil)))
  "Chat-row hover without the global theme's decorative lines."
  :group 'whatsapp-profiles)
(defcustom whatsapp-profile-clean-lines t
  "Suppress inherited underlines/overlines and editor guide lines in app buffers.
The background still identifies the selected row. Other Emacs buffers are unchanged."
  :type 'boolean :group 'whatsapp-profiles)


(defun whatsapp-profiles--row-face (selected)
  "An explicit flat face; do not inherit theme underlines or boxes on a row."
  (if whatsapp-profile-clean-lines
      (list :inherit (if selected 'whatsapp-profile-selection 'whatsapp-contact)
            :underline nil :overline nil :strike-through nil :box nil :extend nil)
    (if selected 'whatsapp-profile-selection 'whatsapp-contact)))

(defun whatsapp-profiles--hover-face ()
  "Use a background-only hover even when the global button face is underlined."
  (if whatsapp-profile-clean-lines
      '(:inherit whatsapp-profile-hover :underline nil :overline nil
        :strike-through nil :box nil :extend nil)
    'whatsapp-profile-hover))

(defvar whatsapp-profiles--scope nil)
(defvar whatsapp-profiles--epoch nil)
(defvar whatsapp-profiles--capability nil)
(defvar whatsapp-profiles--generation 0)
(defvar whatsapp-profiles--timer nil)
(defvar whatsapp-profiles--queue nil)
(defvar whatsapp-profiles--processes nil)
(defvar whatsapp-profiles--pending (make-hash-table :test 'equal))
(defvar whatsapp-profiles--meta (make-hash-table :test 'equal))
(defvar whatsapp-profiles--photos (make-hash-table :test 'equal))
(defvar whatsapp-profiles--photo-order nil)
(defvar whatsapp-profiles--consent-origin nil)
(defvar whatsapp-profiles--next-snapshot 0)
(defvar whatsapp-profiles--next-capability 0)
(defvar whatsapp-profiles--buffers nil)
(defvar-local whatsapp-profiles--face-cookies nil)
(defvar-local whatsapp-profiles--detail-jid nil)
(defvar-local whatsapp-profiles--detail-origin nil)
(defvar-local whatsapp-profiles--details-back nil)
(defvar-local whatsapp-profiles--header "")
(defvar-local whatsapp-profiles--large-photo nil)

(defun whatsapp-profiles--safe (value &optional maximum)
  "Flatten remote text without importing text properties or layout controls."
  (let ((text (if (stringp value) (substring-no-properties value) "")))
    (setq text (substring text 0 (min (or maximum 160) (length text))))
    (replace-regexp-in-string "[\000-\037\177-\237\u202a-\u202e\u2066-\u2069]" " " text)))

(defun whatsapp-profiles--jid-p (jid)
  "Match the bridge profile API identity grammar; do not merge LIDs and phones."
  (and (stringp jid) (<= (length jid) 80)
       (string-match-p "\\`\\(?:[0-9]\\{3,30\\}\\(?:@\\(?:s\\.whatsapp\\.net\\|lid\\)\\)?\\|[0-9]\\{3,30\\}\\(?:-[0-9]\\{1,20\\}\\)?@g\\.us\\)\\'" jid)))

(defun whatsapp-profiles--key (jid)
  (if (string-suffix-p "@s.whatsapp.net" jid) (substring jid 0 -15) jid))

(defun whatsapp-profiles--initials (jid)
  (if (string-suffix-p "@g.us" jid) "GR"
    (let* ((name (whatsapp-profiles--safe (whatsapp--chat-name jid) 80))
           (words (split-string name "[[:space:]]+" t)))
      (upcase (concat (if words (substring (car words) 0 1) "?")
                      (if (cdr words) (substring (car (last words)) 0 1) " "))))))

(defun whatsapp-profiles--current-p ()
  "Refuse enrichment across a credential switch, including already open buffers."
  (and (equal whatsapp-profiles--scope (whatsapp--origin-key))
       (or (null whatsapp-profiles--detail-origin)
           (equal whatsapp-profiles--detail-origin (whatsapp--origin-key)))
       (or (not (derived-mode-p 'whatsapp-chat-mode))
           (null whatsapp--read-origin)
           (equal whatsapp--read-origin (whatsapp--origin-key)))))

(defun whatsapp-profiles--presence-label (jid)
  "Return a label from a fresh received event, never from message activity."
  (let* ((rec (gethash (whatsapp-profiles--key jid) whatsapp-profiles--meta))
         (now (float-time))
         (activity (plist-get rec :activity))
         (state (plist-get rec :availability)))
    (cond ((not (whatsapp-profiles--current-p)) "Status unavailable")
          ((string-suffix-p "@g.us" jid) "Group conversation")
          ((and (< now (or (plist-get rec :activity-until) 0)) (equal activity "typing")) "Typing…")
          ((and (< now (or (plist-get rec :activity-until) 0)) (equal activity "recording")) "Recording audio…")
          ((and (< now (or (plist-get rec :available-until) 0)) (equal state "online")) "Online")
          ((and (< now (or (plist-get rec :available-until) 0)) (equal state "offline"))
           (if-let ((seen (plist-get rec :last-seen)))
               (format "Offline · last seen %s" (format-time-string "%d %b %H:%M" (seconds-to-time seen)))
             "Offline · last seen unavailable"))
          (t "Status unavailable"))))

(defun whatsapp-profiles--photo (jid &optional large)
  "Return an already prepared image; never decode on a rendering path."
  (let* ((key (cons (whatsapp-profiles--key jid) (if large 'photo 'avatar)))
         (entry (gethash key whatsapp-profiles--photos)))
    (and (whatsapp-profiles--current-p) whatsapp-profile-photos entry (> (plist-get entry :expires) (float-time))
         (plist-get entry :image))))

;; Replacing text with an image spec retains the underlying text for terminal use.
(defun whatsapp-profiles--display (jid &optional large)
  (or (and (display-graphic-p)
           (let ((image (whatsapp-profiles--photo jid (and large (not (eq large 'header))))))
             (if (and image (eq large 'header))
                 (let ((copy (copy-tree image)))
                   (setcdr copy (plist-put (cdr copy) :max-width 60))
                   (setcdr copy (plist-put (cdr copy) :max-height 60)) copy)
               image)))
      (propertize (format "[%s]" (whatsapp-profiles--initials jid)) 'face 'whatsapp-profile-avatar)))

(defvar whatsapp-profile-avatar-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'whatsapp-profile-click)
    (define-key map (kbd "RET") #'whatsapp-profile-at-point)
    map))

(defun whatsapp-profiles--insert-avatar (jid)
  "Insert a fixed-width fallback, with no work beyond the in-memory cache."
  (let ((beg (point)))
    (insert (format "[%s]" (whatsapp-profiles--initials jid)))
    (add-text-properties beg (point)
                         (list 'whatsapp-profile-jid jid 'display (whatsapp-profiles--display jid)
                               'rear-nonsticky t 'face 'whatsapp-profile-avatar))
    (insert (propertize " " 'display '(space :align-to 6) 'rear-nonsticky t))))

(defun whatsapp-profiles--decorate-row (beg end jid)
  "Give only the avatar its own action after the row keymap has been applied."
  (let ((finish (next-single-property-change beg 'whatsapp-profile-jid nil end)))
    (when (get-text-property beg 'whatsapp-profile-jid)
      (add-text-properties beg finish
                           (list 'keymap whatsapp-profile-avatar-map 'mouse-face (whatsapp-profiles--hover-face)
                                 'help-echo "View contact info (does not send a message)"))))
  (when (equal jid whatsapp--selected-chat)
    (put-text-property beg (save-excursion (goto-char beg) (line-end-position))
                       'face (whatsapp-profiles--row-face t))))

(defun whatsapp-profiles--paint-avatars (jid)
  "Patch display properties only, preserving drafts, undo and row positions."
  (dolist (buffer (copy-sequence whatsapp-profiles--buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (or (not whatsapp-profiles--detail-origin)
                  (equal whatsapp-profiles--detail-origin (whatsapp--origin-key)))
          (let ((p (point-min)) (inhibit-read-only t) (buffer-undo-list t)
                (modified (buffer-modified-p)))
            (with-silent-modifications
              (while (< p (point-max))
                (let* ((end (next-single-property-change p 'whatsapp-profile-jid nil (point-max)))
                       (at (get-text-property p 'whatsapp-profile-jid)))
                  (when (and at (or (null jid) (equal (whatsapp-profiles--key at) jid)))
                    (put-text-property p end 'display
                                       (whatsapp-profiles--display at (get-text-property p 'whatsapp-profile-large))))
                  (setq p end))))
            (set-buffer-modified-p modified))
          (whatsapp-profiles--update-header))))))

(defun whatsapp-profiles--drop-photo (jid)
  (dolist (kind '(avatar photo))
    (let ((key (cons jid kind)))
      (remhash key whatsapp-profiles--photos)
      (setq whatsapp-profiles--photo-order (delete key whatsapp-profiles--photo-order))))
  (whatsapp-profiles--paint-avatars jid))

(defun whatsapp-profiles--cache-photo (jid action body)
  "Admit only the worker's bounded PNG output, in a separate completion callback."
  (when (and whatsapp-profile-photos (image-type-available-p 'png))
    (let* ((encoded (cdr (assoc "png" body)))
           (revision (cdr (assoc "photo_revision" body)))
           (metadata (gethash jid whatsapp-profiles--meta))
           (edge (if (eq action 'photo) 256 96)))
      (when (and (stringp encoded) (< (length encoded) 400000) (integerp revision)
                 (equal (cdr (assoc "epoch" body)) whatsapp-profiles--epoch)
                 (not (member (plist-get metadata :photo-state) '("removed" "unavailable")))
                 (equal revision (or (plist-get metadata :photo-revision) 0)))
        (let* ((bytes (base64-decode-string encoded))
               (dims (whatsapp--image-dimensions bytes 'png))
               (key (cons jid action)))
          (when (and (< (length bytes) 300000) (equal dims (cons edge edge)))
            (puthash key (list :image (create-image bytes 'png t :max-width (if (eq action 'photo) 256 38)
                                                  :max-height (if (eq action 'photo) 256 38) :ascent 'center)
                               :bytes (length bytes) :pixels (* edge edge) :expires (+ (float-time) 120))
                     whatsapp-profiles--photos)
            (setq whatsapp-profiles--photo-order (append (delete key whatsapp-profiles--photo-order) (list key)))
            (let ((total 0) (pixels 0))
              (maphash (lambda (_ v) (cl-incf total (plist-get v :bytes)) (cl-incf pixels (plist-get v :pixels)))
                       whatsapp-profiles--photos)
              (while (and whatsapp-profiles--photo-order
                          (or (> (hash-table-count whatsapp-profiles--photos) 32) (> total (* 4 1024 1024)) (> pixels 1000000)))
                (let* ((old (pop whatsapp-profiles--photo-order)) (value (gethash old whatsapp-profiles--photos)))
                  (cl-decf total (plist-get value :bytes)) (cl-decf pixels (plist-get value :pixels))
                  (remhash old whatsapp-profiles--photos)
                  (whatsapp-profiles--paint-avatars (car old)))))
            (whatsapp-profiles--paint-avatars jid)))))))

(defun whatsapp-profiles--reset ()
  (cl-incf whatsapp-profiles--generation)
  (setq whatsapp-profiles--queue nil whatsapp-profiles--capability nil whatsapp-profiles--epoch nil
        whatsapp-profiles--next-capability 0 whatsapp-profiles--next-snapshot 0
        whatsapp-profiles--consent-origin nil)
  (dolist (proc (copy-sequence whatsapp-profiles--processes))
    (when (process-live-p proc) (delete-process proc)))
  (setq whatsapp-profiles--processes nil whatsapp-profiles--photo-order nil)
  (clrhash whatsapp-profiles--pending)
  (clrhash whatsapp-profiles--meta)
  (clrhash whatsapp-profiles--photos)
  (whatsapp-profiles--paint-avatars nil))

(defun whatsapp-clear-profile-cache ()
  "Clear in-memory profile data and invalidate pending results.  No secure-erasure claim."
  (interactive)
  (whatsapp-profiles--reset)
  (message "Profile cache cleared; live capabilities will be checked again"))

(defun whatsapp-profiles--visible ()
  "Return at most twelve visible identities, selected chat first."
  (let (keys)
    (dolist (frame (frame-list))
      (when (eq (frame-visible-p frame) t)
        (dolist (window (window-list frame 'no-minibuffer))
          (with-current-buffer (window-buffer window)
            (cond
             ((and (whatsapp-profiles--current-p) (derived-mode-p 'whatsapp-chat-mode) (whatsapp-profiles--jid-p whatsapp-chat--jid))
              (cl-pushnew (whatsapp-profiles--key whatsapp-chat--jid) keys :test #'equal))
             ((and (whatsapp-profiles--current-p) (derived-mode-p 'whatsapp-profile-mode) (whatsapp-profiles--jid-p whatsapp-profiles--detail-jid))
              (cl-pushnew (whatsapp-profiles--key whatsapp-profiles--detail-jid) keys :test #'equal))
             ((derived-mode-p 'whatsapp-root-mode)
              (let ((p (window-start window)) (end (window-end window nil)))
                (while (and (integerp end) (< p end) (< (length keys) 12))
                  (let ((jid (get-text-property p 'whatsapp-jid)))
                    (when (whatsapp-profiles--jid-p jid)
                      (cl-pushnew (whatsapp-profiles--key jid) keys :test #'equal)))
                  (setq p (next-single-property-change p 'whatsapp-jid nil end))))))))))
    (when (and (whatsapp-profiles--jid-p whatsapp--selected-chat)
               (member (whatsapp-profiles--key whatsapp--selected-chat) keys))
      (setq keys (cons (whatsapp-profiles--key whatsapp--selected-chat)
                       (delete (whatsapp-profiles--key whatsapp--selected-chat) keys))))
    (cl-subseq keys 0 (min 12 (length keys)))))

(defun whatsapp-profiles--user-work-p ()
  (cl-some (lambda (buf)
             (and (buffer-live-p buf)
                  (with-current-buffer buf (or whatsapp-chat--send-pending whatsapp--refresh-pending))))
           (whatsapp--visible-buffers)))

(defun whatsapp-profiles--enqueue (action value)
  (let ((task (list action value)))
    (when (and (< (length whatsapp-profiles--queue) 16)
               (not (gethash task whatsapp-profiles--pending))
               (not (member task whatsapp-profiles--queue)))
      (setq whatsapp-profiles--queue (append whatsapp-profiles--queue (list task))))))

(defun whatsapp-profiles--worker-result (state exit-code text)
  "Retain a safe failure category even when the worker exits nonzero.
A nonzero exit can never publish a ready photo or upstream private values."
  (let* ((fallback '(("status") ("body" ("state" . "unavailable")
                                             ("reason" . "worker-failed"))))
         (result (and (eq state 'exit)
                      (condition-case nil (whatsapp--json-read text) (error nil)))))
    (if (and (eq state 'exit) (equal exit-code 0))
        (or result fallback)
      (let* ((body (cdr (assoc "body" result))) (reason (cdr (assoc "reason" body))))
        (if (and (equal (cdr (assoc "state" body)) "unavailable")
                 (member reason '("cdn-policy" "cdn-network" "image-rejected"
                                  "decoder-unavailable" "decoder-failed" "worker-failed")))
            (list '("status") (cons "body" (list '("state" . "unavailable")
                                                   (cons "reason" reason))))
          fallback)))))

(defun whatsapp-profiles--start-child (task)
  "One isolated profile worker. The process filter only stores bounded chunks."
  (let* ((python (executable-find whatsapp-python-program))
         (script (expand-file-name "scripts/profile-worker.py" whatsapp--source-directory))
         (scope (whatsapp--origin-key)) (generation whatsapp-profiles--generation)
         (process-environment (whatsapp--media-environment))
         (action (car task)) (value (cadr task))
         (control `((url . ,whatsapp-bridge-url) (token . ,whatsapp-bridge-token)
                    (action . ,(symbol-name action)) (timeout . 20)))
         chunks (size 0) proc timer done)
    (unless (and python (file-regular-p script)) (user-error "Complete profile worker and Python 3 required"))
    (cond ((eq action 'snapshot) (push (cons 'jids (vconcat value)) control))
          ((not (eq action 'capabilities)) (push (cons 'jid value) control)))
    (when (eq action 'subscribe) (push '(consent . t) control))
    (puthash task t whatsapp-profiles--pending)
    (cl-labels
        ((finish (result)
           (unless done
             (setq done t chunks nil)
             (when timer (cancel-timer timer))
             (setq whatsapp-profiles--processes (delq proc whatsapp-profiles--processes))
             (when (and (= generation whatsapp-profiles--generation) (equal scope (whatsapp--origin-key)))
               (remhash task whatsapp-profiles--pending)
               (condition-case nil
                   (progn (whatsapp-profiles--accept task result) (whatsapp-profiles--trim-meta))
                 (error (setq whatsapp-profiles--next-snapshot (+ (float-time) 10))))))))
      (condition-case nil
          (progn
            (setq proc
                  (make-process
                   :name "whatsappel-profile" :buffer nil :noquery t :connection-type 'pipe :coding 'utf-8-unix
                   :command (list python "-I" script)
                   :filter (lambda (p text)
                             (unless done
                               (cl-incf size (string-bytes text))
                               (if (> size 600000)
                                   (progn (finish nil) (when (process-live-p p) (delete-process p)))
                                 (push text chunks))))
                   :sentinel (lambda (p _event)
                               (when (memq (process-status p) '(exit signal))
                                 (finish (whatsapp-profiles--worker-result
                                          (process-status p) (process-exit-status p)
                                          (apply #'concat (nreverse chunks))))))))
            (push proc whatsapp-profiles--processes)
            (setq timer (run-at-time 21 nil (lambda () (finish nil) (when (process-live-p proc) (delete-process proc)))))
            (process-send-string proc (json-encode control))
            (process-send-eof proc))
        (error (finish (whatsapp-profiles--worker-result 'failed 1 ""))
               (when (and proc (process-live-p proc)) (delete-process proc)))))))

(defun whatsapp-profiles--trim-meta ()
  (while (> (hash-table-count whatsapp-profiles--meta) 128)
    (let (old (stamp most-positive-fixnum))
      (maphash (lambda (jid rec)
                 (when (< (or (plist-get rec :touched) 0) stamp)
                   (setq old jid stamp (or (plist-get rec :touched) 0))))
               whatsapp-profiles--meta)
      (remhash old whatsapp-profiles--meta)
      (whatsapp-profiles--drop-photo old))))

(defun whatsapp-profiles--accept (task result)
  "Apply one bounded, already validated worker response to memory-only state."
  (let* ((action (car task)) (key (cadr task)) (now (float-time))
         (status (cdr (assoc "status" result))) (body (cdr (assoc "body" result))))
    (cond
     ((eq action 'capabilities)
      (setq whatsapp-profiles--capability
            (if (and (equal status 200) (equal (cdr (assoc "version" body)) 1)) 'ready 'unavailable)
            whatsapp-profiles--next-capability (+ now 60)))
     ((eq action 'snapshot)
      (when (and (equal status 200) (equal (cdr (assoc "version" body)) 1))
        (let ((epoch (cdr (assoc "epoch" body))))
          (when (and whatsapp-profiles--epoch (not (equal epoch whatsapp-profiles--epoch)))
            (clrhash whatsapp-profiles--photos)
            (setq whatsapp-profiles--photo-order nil)
            (clrhash whatsapp-profiles--meta)
            (whatsapp-profiles--paint-avatars nil))
          (setq whatsapp-profiles--epoch epoch))
        (dolist (item (cdr (assoc "profiles" body)))
          (let* ((jid (cdr (assoc "jid" item))) (rec (gethash jid whatsapp-profiles--meta))
                 (photo-rev (cdr (assoc "photo_revision" item)))
                 (photo-state (cdr (assoc "photo_state" item)))
                 (age (cdr (assoc "availability_age" item)))
                 (activity-age (cdr (assoc "activity_age" item))))
            (when (and (member jid key) (integerp photo-rev))
              (when (or (not (equal photo-rev (plist-get rec :photo-revision)))
                        (member photo-state '("removed" "unavailable")))
                (whatsapp-profiles--drop-photo jid)
                (setq rec (plist-put rec :photo-next 0)))
              (setq rec (plist-put rec :photo-revision photo-rev)
                    rec (plist-put rec :photo-state photo-state)
                    rec (plist-put rec :availability (cdr (assoc "availability" item)))
                    rec (plist-put rec :activity (cdr (assoc "activity" item)))
                    rec (plist-put rec :last-seen (cdr (assoc "last_seen" item)))
                    rec (plist-put rec :available-until (+ now (max 0 (- 60 (or age 60)))))
                    rec (plist-put rec :activity-until (+ now (max 0 (- 8 (or activity-age 8)))))
                    rec (plist-put rec :touched now))
              (puthash jid rec whatsapp-profiles--meta))))
        (while (> (hash-table-count whatsapp-profiles--meta) 128)
          (let (old (stamp most-positive-fixnum))
            (maphash (lambda (jid rec)
                       (when (< (or (plist-get rec :touched) 0) stamp)
                         (setq old jid stamp (or (plist-get rec :touched) 0))))
                     whatsapp-profiles--meta)
            (remhash old whatsapp-profiles--meta)
            (whatsapp-profiles--drop-photo old)))
        (whatsapp-profiles--paint-status)))
     ((memq action '(avatar photo))
      (let ((rec (gethash key whatsapp-profiles--meta)))
        (unless result
          (setq body '(("state" . "unavailable") ("reason" . "worker-failed"))))
        (setq rec (plist-put rec :photo-next (+ now 120))
              rec (plist-put rec :photo-result (cdr (assoc "state" body)))
              rec (plist-put rec :photo-reason
                             (let ((reason (cdr (assoc "reason" body))))
                               (and (member reason '("provider-route" "provider-rejected" "cdn-policy"
                                                      "cdn-network" "image-rejected" "decoder-unavailable"
                                                      "decoder-failed" "worker-failed")) reason))))
        (puthash key rec whatsapp-profiles--meta))
      (cond
       ((and (equal status 200) (equal (cdr (assoc "state" body)) "ready"))
        (run-at-time
         0.02 nil
         (let ((scope whatsapp-profiles--scope) (generation whatsapp-profiles--generation))
           (lambda ()
             (when (and (equal scope (whatsapp--origin-key)) (= generation whatsapp-profiles--generation))
               (condition-case nil
                   (whatsapp-profiles--cache-photo key action body)
                 (error (let ((rec (gethash key whatsapp-profiles--meta)))
                          (puthash key (plist-put rec :decode-failed t) whatsapp-profiles--meta)))))))))
       ((member (cdr (assoc "state" body)) '("unavailable" "unsupported" "stale"))
        (whatsapp-profiles--drop-photo key)))
      (whatsapp-profiles--paint-status))
     ((eq action 'about)
      (let* ((rec (gethash key whatsapp-profiles--meta))
             (about (if (and (equal status 200) (equal (cdr (assoc "state" body)) "ready")
                             (equal (cdr (assoc "epoch" body)) whatsapp-profiles--epoch))
                        (whatsapp-profiles--safe (cdr (assoc "about" body)) 1024) "About unavailable")))
        (puthash key (plist-put rec :about about) whatsapp-profiles--meta))
      (whatsapp-profiles--paint-status))
     ((eq action 'subscribe)
      (let* ((rec (gethash key whatsapp-profiles--meta))
             (label (if (and (equal status 200) (equal (cdr (assoc "state" body)) "subscribed"))
                        "Subscription requested" "Subscription unavailable")))
        (puthash key (plist-put rec :subscription label) whatsapp-profiles--meta))))))

(defun whatsapp-profiles--tick ()
  "Coalesced visible-only enrichment, lower priority than chat reads and sends."
  (condition-case nil
      (progn
        (unless (equal whatsapp-profiles--scope (whatsapp--origin-key))
          (whatsapp-profiles--reset) (setq whatsapp-profiles--scope (whatsapp--origin-key)))
        (let ((visible (whatsapp-profiles--visible)) (now (float-time)))
          ;; A removal, account reset, or expiry must remove already displayed pixels.
          (let (expired)
            (maphash (lambda (key entry) (when (<= (plist-get entry :expires) now) (push (car key) expired)))
                     whatsapp-profiles--photos)
            (dolist (key (delete-dups expired)) (whatsapp-profiles--drop-photo key)))
          (whatsapp-profiles--paint-status)
          (when (and visible (stringp whatsapp-bridge-token) (not (whatsapp-profiles--user-work-p)))
            (cond
             ((not (eq whatsapp-profiles--capability 'ready))
              (when (>= now whatsapp-profiles--next-capability)
                (setq whatsapp-profiles--next-capability (+ now 60))
                (whatsapp-profiles--enqueue 'capabilities nil)))
             (t
              (when (>= now whatsapp-profiles--next-snapshot)
                (setq whatsapp-profiles--next-snapshot (+ now 5))
                (whatsapp-profiles--enqueue 'snapshot visible))
              (when (and whatsapp-profile-presence-enabled (equal whatsapp-profiles--consent-origin whatsapp-profiles--scope)
                         (whatsapp-profiles--jid-p whatsapp--selected-chat)
                         (member (whatsapp-profiles--key whatsapp--selected-chat) visible)
                         (not (string-suffix-p "@g.us" whatsapp--selected-chat)))
                (let* ((jid (whatsapp-profiles--key whatsapp--selected-chat)) (rec (gethash jid whatsapp-profiles--meta)))
                  (when (> now (or (plist-get rec :subscribe-next) 0))
                    (puthash jid (plist-put rec :subscribe-next (+ now 300)) whatsapp-profiles--meta)
                    (whatsapp-profiles--enqueue 'subscribe jid))))
              (when (and whatsapp-profile-photos (display-graphic-p))
                (dolist (jid visible)
                  (let ((rec (gethash jid whatsapp-profiles--meta)))
                    (when (and rec (not (member (plist-get rec :photo-state) '("removed" "unavailable")))
                               (not (whatsapp-profiles--photo jid)) (>= now (or (plist-get rec :photo-next) 0)))
                      (whatsapp-profiles--enqueue 'avatar jid)))))))
            ;; Drop no-longer-visible queued work; at most two workers in flight.
            (setq whatsapp-profiles--queue
                  (cl-remove-if (lambda (task) (and (not (memq (car task) '(snapshot capabilities)))
                                                    (not (member (cadr task) visible)))) whatsapp-profiles--queue))
            (if (eq whatsapp-profiles--capability 'ready)
                (while (and whatsapp-profiles--queue (< (length whatsapp-profiles--processes) 2))
                  (whatsapp-profiles--start-child (pop whatsapp-profiles--queue)))
              (when (and (member '(capabilities nil) whatsapp-profiles--queue)
                         (< (length whatsapp-profiles--processes) 2))
                (setq whatsapp-profiles--queue (delete '(capabilities nil) whatsapp-profiles--queue))
                (whatsapp-profiles--start-child '(capabilities nil)))))))
    (error (setq whatsapp-profiles--next-snapshot (+ (float-time) 10)))))

(defun whatsapp-profiles-start ()
  "Start profile enrichment after a normal account snapshot or explicit UI action."
  (unless (equal whatsapp-profiles--scope (whatsapp--origin-key))
    (whatsapp-profiles--reset)
    (setq whatsapp-profiles--scope (whatsapp--origin-key)))
  (unless (timerp whatsapp-profiles--timer)
    (setq whatsapp-profiles--timer (run-at-time 0.3 1 #'whatsapp-profiles--tick))))

(defun whatsapp-profiles--update-header ()
  (let ((jid (or whatsapp-chat--jid whatsapp-profiles--detail-jid)))
    (when jid
      (setq whatsapp-profiles--header
            (concat " " (propertize (format "[%s]" (whatsapp-profiles--initials jid))
                                    'display (whatsapp-profiles--display jid 'header)
                                    'mouse-face (whatsapp-profiles--hover-face) 'keymap whatsapp-profile-avatar-map
                                    'help-echo "View contact info" 'whatsapp-profile-jid jid)
                    " " (whatsapp-profiles--safe (whatsapp--chat-name jid) 60) "   ·   "
                    (whatsapp-profiles--presence-label jid))))))

(defun whatsapp-profiles--paint-status ()
  (setq whatsapp-profiles--buffers (cl-remove-if-not #'buffer-live-p whatsapp-profiles--buffers))
  (dolist (buffer whatsapp-profiles--buffers)
    (with-current-buffer buffer
      (when (get-buffer-window buffer t)
        (whatsapp-profiles--update-header)
        (when (and whatsapp-profiles--detail-jid (equal whatsapp-profiles--detail-origin (whatsapp--origin-key)))
          (let ((inhibit-read-only t) (buffer-undo-list t))
            (with-silent-modifications
              (dolist (field '(whatsapp-profile-status whatsapp-profile-about whatsapp-profile-photo-status))
                (when-let ((p (text-property-any (point-min) (point-max) field t)))
                  (put-text-property p (next-single-property-change p field nil (point-max)) 'display
                                     (cond ((eq field 'whatsapp-profile-status)
                                            (whatsapp-profiles--presence-label whatsapp-profiles--detail-jid))
                                           ((eq field 'whatsapp-profile-photo-status)
                                            (whatsapp-profiles--photo-label whatsapp-profiles--detail-jid))
                                           (t (or (plist-get (gethash (whatsapp-profiles--key whatsapp-profiles--detail-jid)
                                                              whatsapp-profiles--meta) :about) "About unavailable")))))))))))))

(defun whatsapp-profiles--setup-buffer ()
  "Apply local layout defaults, without changing global themes or other buffers."
  (cl-pushnew (current-buffer) whatsapp-profiles--buffers)
  (setq-local display-line-numbers nil)
  (when (fboundp 'display-line-numbers-mode) (display-line-numbers-mode -1))
  (when (fboundp 'display-fill-column-indicator-mode) (display-fill-column-indicator-mode -1))
  (setq-local line-spacing 0.15)
  (when whatsapp-profile-clean-lines
    (setq-local show-trailing-whitespace nil)
    (setq-local global-hl-line-mode nil)
    (when (fboundp 'hl-line-mode) (hl-line-mode -1))
    ;; Turning off local hl-line does not remove an existing global overlay.
    (when (and (fboundp 'global-hl-line-unhighlight)
               (boundp 'global-hl-line-overlay) (overlayp global-hl-line-overlay)
               (eq (overlay-buffer global-hl-line-overlay) (current-buffer)))
      (global-hl-line-unhighlight))
    (setq-local cursor-type 'bar))
  (dolist (cookie whatsapp-profiles--face-cookies) (face-remap-remove-relative cookie))
  (setq whatsapp-profiles--face-cookies nil)
  (when (eq whatsapp-profile-palette 'cyan)
    (dolist (pair '((default :background "#090f14" :foreground "#e2eaef")
                    (whatsapp-title :foreground "#64dfed" :weight bold :height 1.35)
                    (whatsapp-accent :foreground "#64dfed" :weight bold)
                    (whatsapp-contact :foreground "#e2eaef" :weight bold)
                    (whatsapp-profile-avatar :foreground "#64dfed" :background "#15252e")
                    (whatsapp-profile-selection :background "#17313d" :foreground "#ffffff")
                    (button :foreground "#64dfed" :underline nil)
                    (header-line :background "#15252e" :foreground "#e2eaef" :box nil)))
      (push (apply #'face-remap-add-relative (car pair) (cdr pair)) whatsapp-profiles--face-cookies)))
  (when whatsapp-profile-clean-lines
    (dolist (face '(default button link link-visited highlight hl-line region
                    whatsapp-title whatsapp-contact whatsapp-accent shadow
                    whatsapp-profile-avatar whatsapp-profile-selection whatsapp-profile-hover))
      (when (facep face)
        (push (face-remap-add-relative face :underline nil :overline nil
                                       :strike-through nil :box nil)
              whatsapp-profiles--face-cookies))))
  (when (derived-mode-p 'whatsapp-chat-mode 'whatsapp-profile-mode)
    (setq-local header-line-format '(:eval whatsapp-profiles--header)))
  (add-hook 'kill-buffer-hook #'whatsapp-profiles--buffer-killed nil t)
  (whatsapp-profiles--update-header))

(defun whatsapp-profiles--buffer-killed ()
  (setq whatsapp-profiles--buffers (delq (current-buffer) whatsapp-profiles--buffers))
  (unless (cl-some #'buffer-live-p whatsapp-profiles--buffers)
    (when (timerp whatsapp-profiles--timer) (cancel-timer whatsapp-profiles--timer))
    (setq whatsapp-profiles--timer nil)
    (whatsapp-profiles--reset)))

(defun whatsapp-profile-toggle-photos ()
  (interactive)
  (setq whatsapp-profile-photos (not whatsapp-profile-photos))
  (whatsapp-clear-profile-cache)
  (whatsapp-profiles-start)
  (message "Profile photos %s" (if whatsapp-profile-photos "enabled" "disabled")))

(defun whatsapp-profile-toggle-presence ()
  "Explicit, session/account-scoped consent; no outgoing online announcement."
  (interactive)
  (whatsapp-profiles-start)
  (if (equal whatsapp-profiles--consent-origin (whatsapp--origin-key))
      (setq whatsapp-profiles--consent-origin nil whatsapp-profile-presence-enabled nil)
    (when (yes-or-no-p "Subscribe only to selected contacts? WhatsApp may require your account to be online; wuzapi may already announce availability on connect. This action will NOT set you online or change privacy settings. Continue? ")
      (setq whatsapp-profile-presence-enabled t whatsapp-profiles--consent-origin (whatsapp--origin-key))))
  (whatsapp-profiles-start)
  (message "Presence subscription %s; remote Idle is not inferred"
           (if whatsapp-profiles--consent-origin "enabled for this account" "disabled (upstream has no unsubscribe route)")))

(defun whatsapp-profile-toggle-palette ()
  (interactive)
  (setq whatsapp-profile-palette (if (eq whatsapp-profile-palette 'cyan) 'current 'cyan))
  (dolist (buffer whatsapp-profiles--buffers)
    (when (buffer-live-p buffer) (with-current-buffer buffer (whatsapp-profiles--setup-buffer)))))

(defun whatsapp-profile-font-larger ()
  (interactive)
  (dolist (buf whatsapp-profiles--buffers)
    (when (buffer-live-p buf) (with-current-buffer buf (text-scale-increase 1)))))
(defun whatsapp-profile-font-smaller ()
  (interactive)
  (dolist (buf whatsapp-profiles--buffers)
    (when (buffer-live-p buf) (with-current-buffer buf (text-scale-decrease 1)))))

(defun whatsapp-profile-diagnostics ()
  "Show bounded, identifier-free local state. Does not call the bridge."
  (interactive)
  (let ((body (format "WhatsAppel %s profile diagnostics\n\nCapability: %s\nPhotos enabled: %s\nPresence opt-in for current account: %s\nActive workers: %d / 2\nWaiting tasks: %d / 16\nCached metadata: %d / 128\nCached images: %d / 32\n\nStatus unavailable is not Offline. Remote Idle is unsupported.\nPresence requires forwarded authorized events; it never sets your account online.\nNo network request was made by this diagnostic.\n"
                      whatsapp-version (or whatsapp-profiles--capability 'not-checked)
                      (if whatsapp-profile-photos "yes" "no")
                      (if (equal whatsapp-profiles--consent-origin (whatsapp--origin-key)) "yes" "no")
                      (length whatsapp-profiles--processes) (length whatsapp-profiles--queue)
                      (hash-table-count whatsapp-profiles--meta) (hash-table-count whatsapp-profiles--photos))))
    (with-current-buffer (get-buffer-create "*WhatsApp profile diagnostics*")
      (special-mode)
      (let ((inhibit-read-only t)) (erase-buffer) (insert body))
      (pop-to-buffer (current-buffer)))))

(defun whatsapp-profile-settings ()
  (interactive)
  (let ((buffer (get-buffer-create "*WhatsApp settings*")))
    (with-current-buffer buffer
      (whatsapp-profile-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Workspace settings\n\n" 'face 'whatsapp-title))
        (insert "All changes are scoped to WhatsAppel. Profiles remain in memory only.\n\n")
        (whatsapp--button "Toggle photos" #'whatsapp-profile-toggle-photos)
        (whatsapp--button "Clear profile cache" #'whatsapp-clear-profile-cache)
        (insert "\n\n")
        (whatsapp--button "Presence consent" #'whatsapp-profile-toggle-presence)
        (whatsapp--button "Theme: cyan / current" #'whatsapp-profile-toggle-palette)
        (insert "\n\n")
        (whatsapp--button "Larger text" #'whatsapp-profile-font-larger)
        (whatsapp--button "Smaller text" #'whatsapp-profile-font-smaller)
        (whatsapp--button "Video: Pale / mpv" #'whatsapp-video-select-backend)
        (whatsapp--button "Connection / delivery" #'whatsapp-connection-panel)
        (whatsapp--button "All settings" #'whatsapp-customize)
        (whatsapp--button "Diagnostics" #'whatsapp-profile-diagnostics)
        (insert "\n\nPresence requires supported, authorized webhook events.\nUnknown is not Offline. Remote Idle and Status stories are unsupported.\n")
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defvar whatsapp-profile-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'whatsapp-profile-close)
    (define-key map (kbd "g") #'whatsapp-profile-refresh)
    map))
(define-derived-mode whatsapp-profile-mode special-mode "WA-Profile"
  "Native account-scoped contact details; q goes back."
  (whatsapp-profiles--setup-buffer))

(defun whatsapp-profile-at-point ()
  (interactive)
  (when (and (derived-mode-p 'whatsapp-chat-mode) whatsapp--read-origin
             (not (equal whatsapp--read-origin (whatsapp--origin-key))))
    (user-error "Restore the original account before viewing these details"))
  (whatsapp-contact-info (or (get-text-property (point) 'whatsapp-profile-jid)
                             whatsapp-chat--jid (get-text-property (point) 'whatsapp-jid))))
(defun whatsapp-profile-click (event)
  (interactive "e")
  (let ((where (posn-point (event-start event))))
    (if (or (eq where 'header-line) (consp where))
        (with-selected-window (posn-window (event-start event)) (whatsapp-contact-info (or whatsapp-chat--jid whatsapp-profiles--detail-jid)))
      (mouse-set-point event) (whatsapp-profile-at-point))))

(defun whatsapp-contact-info (&optional jid)
  "Show cached details immediately; enrich without selecting or sending to a recipient."
  (interactive)
  (when (and (derived-mode-p 'whatsapp-chat-mode) whatsapp--read-origin
             (not (equal whatsapp--read-origin (whatsapp--origin-key))))
    (user-error "Restore this conversation's account before viewing details"))
  (setq jid (or jid whatsapp-chat--jid (get-text-property (point) 'whatsapp-jid)))
  (unless (whatsapp-profiles--jid-p jid) (user-error "Choose a supported contact first"))
  (let* ((origin (whatsapp--origin-key)) (back (current-buffer))
         (buffer (get-buffer-create (format "*WA Profile %s*" (substring (secure-hash 'sha256 (format "%S %s" origin jid)) 0 12)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'whatsapp-profile-mode) (whatsapp-profile-mode))
      (setq whatsapp-profiles--detail-jid jid whatsapp-profiles--detail-origin origin whatsapp-profiles--details-back back)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Contact info\n\n" 'face 'whatsapp-title))
        (let ((beg (point)))
          (whatsapp-profiles--insert-avatar jid)
          (whatsapp-profiles--decorate-row beg (point) jid))
        (insert (propertize (whatsapp-profiles--safe (whatsapp--chat-name jid)) 'face 'whatsapp-title) "\n\n")
        (insert (propertize "Status unavailable" 'whatsapp-profile-status t 'rear-nonsticky t) "\n\n")
        (insert "Photo: " (propertize "Not checked" 'whatsapp-profile-photo-status t 'rear-nonsticky t) "\n\n")
        (insert "About\n" (propertize "About unavailable" 'whatsapp-profile-about t 'rear-nonsticky t) "\n\n")
        (insert (propertize "Identity\n" 'face 'bold) (whatsapp-profiles--safe jid) "\n\n")
        (whatsapp--button "Open conversation"
                          (lambda () (interactive)
                            (unless (equal whatsapp-profiles--detail-origin (whatsapp--origin-key))
                              (user-error "Restore the original account before opening this conversation"))
                            (whatsapp-open-chat jid)))
        (whatsapp--button "Refresh details" #'whatsapp-profile-refresh)
        (whatsapp--button "Retry photo" #'whatsapp-profile-retry-photo)
        (whatsapp--button "Larger photo" #'whatsapp-profile-large-photo)
        (insert "\n\n")
        (whatsapp--button "Privacy / presence" #'whatsapp-profile-toggle-presence)
        (whatsapp--button "Back" #'whatsapp-profile-close)
        (insert "\n\n" (propertize "No inferred Idle, blocking status, or hidden last-seen information.\n" 'face 'shadow))
        (goto-char (point-min)))
      (whatsapp-profiles--update-header))
    (pop-to-buffer buffer)
    (whatsapp-profiles-start)
    (whatsapp-profile-refresh)))

(defun whatsapp-profile-refresh ()
  (interactive)
  (when whatsapp-profiles--detail-jid
    (unless (equal whatsapp-profiles--detail-origin (whatsapp--origin-key))
      (user-error "Restore the original account before refreshing this panel"))
    (let ((jid (whatsapp-profiles--key whatsapp-profiles--detail-jid)))
      (whatsapp-profiles--enqueue 'snapshot (list jid))
      (whatsapp-profiles--enqueue 'about jid)
      (when whatsapp-profile-photos (whatsapp-profiles--enqueue 'avatar jid))
      (whatsapp-profiles-start))))

(defun whatsapp-profiles--photo-label (jid)
  "Explain a bounded cached photo result without exposing URLs or provider text."
  (let* ((key (whatsapp-profiles--key jid)) (rec (gethash key whatsapp-profiles--meta))
         (reason (plist-get rec :photo-reason)))
    (cond ((not whatsapp-profile-photos) "Disabled in Settings")
          ((not (display-graphic-p)) "Images need a graphical frame")
          ((whatsapp-profiles--photo key) "Loaded")
          ((eq (plist-get rec :decode-failed) t) "Native PNG display failed")
          ((equal reason "provider-route") "Installed provider lacks this route")
          ((equal reason "provider-rejected") "Provider denied/failed lookup; privacy or session may limit it")
          ((equal reason "cdn-policy") "Photo host is outside the verified CDN policy")
          ((equal reason "cdn-network") "Photo download or validation failed")
          ((equal reason "decoder-unavailable") "FFmpeg missing from Emacs PATH")
          ((equal reason "decoder-failed") "Thumbnail conversion failed")
          ((equal reason "worker-failed") "Worker failed; check runtime and configuration")
          ((equal (plist-get rec :photo-result) "stale") "Photo changed during loading; use Retry photo")
          (t "Unavailable or still loading; this does not mean blocked"))))

(defun whatsapp-profile-retry-photo ()
  "Retry only this profile; preserve consent, other photos and message state."
  (interactive)
  (unless (and whatsapp-profile-photos whatsapp-profiles--detail-jid
               (equal whatsapp-profiles--detail-origin (whatsapp--origin-key)))
    (user-error "Open current-account contact details with photos enabled"))
  (let* ((key (whatsapp-profiles--key whatsapp-profiles--detail-jid))
         (rec (gethash key whatsapp-profiles--meta)))
    (setq rec (plist-put rec :photo-next 0) rec (plist-put rec :photo-reason nil)
          rec (plist-put rec :decode-failed nil))
    (puthash key rec whatsapp-profiles--meta)
    (whatsapp-profiles--drop-photo key)
    (whatsapp-profiles--enqueue 'snapshot (list key))
    (whatsapp-profiles--enqueue 'avatar key)
    (whatsapp-profiles-start)))

(defun whatsapp-profile-large-photo ()
  (interactive)
  (unless (and whatsapp-profile-photos whatsapp-profiles--detail-jid
               (equal whatsapp-profiles--detail-origin (whatsapp--origin-key)))
    (user-error "Open current-account details with photos enabled"))
  (let ((inhibit-read-only t))
    (when-let ((p (text-property-any (point-min) (point-max) 'whatsapp-profile-jid whatsapp-profiles--detail-jid)))
      (put-text-property p (next-single-property-change p 'whatsapp-profile-jid nil (point-max)) 'whatsapp-profile-large t)))
  (whatsapp-profiles--enqueue 'photo (whatsapp-profiles--key whatsapp-profiles--detail-jid))
  (whatsapp-profiles-start))

(defun whatsapp-profile-close ()
  (interactive)
  (let ((back whatsapp-profiles--details-back))
    (quit-window)
    (when (buffer-live-p back) (pop-to-buffer back))))

(defun whatsapp-insert-emoji ()
  "Insert a chosen Unicode emoji into the draft, never send it."
  (interactive)
  (unless whatsapp-chat--input-marker (user-error "Open a conversation first"))
  (let ((emoji (completing-read "Insert emoji: " '("👍" "❤️" "😊" "😂" "🙏" "🎉" "✅" "👋") nil t)))
    (when (< (point) whatsapp-chat--input-marker) (goto-char (point-max)))
    (insert emoji)))

(add-hook 'whatsapp-root-mode-hook #'whatsapp-profiles--setup-buffer)
(add-hook 'whatsapp-chat-mode-hook #'whatsapp-profiles--setup-buffer)
(define-key whatsapp-chat-mode-map (kbd "C-c i") #'whatsapp-contact-info)
(define-key whatsapp-root-mode-map (kbd "i") #'whatsapp-profile-at-point)
(define-key whatsapp-chat-mode-map (kbd "C-c e") #'whatsapp-insert-emoji)
(define-key whatsapp-root-mode-map (kbd "S") #'whatsapp-profile-settings)
(provide 'whatsapp-profiles)
;;; whatsapp-profiles.el ends here
