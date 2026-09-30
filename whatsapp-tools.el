;;; whatsapp-tools.el --- Native conversation organization -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defcustom whatsapp-tools-state-directory
  (expand-file-name "whatsappel/chat-state" user-emacs-directory)
  "Private directory for account-scoped archive choices and local pins.
No message bodies, photographs or literal credentials are stored here."
  :type 'directory :group 'whatsapp)
(defvar whatsapp-tools--scope nil)
(defvar whatsapp-tools--preferences (make-hash-table :test 'equal))
(defvar whatsapp-tools--pending (make-hash-table :test 'equal))

(defun whatsapp-tools--state-file ()
  (expand-file-name (concat (secure-hash 'sha256 (prin1-to-string (whatsapp--origin-key))) ".json")
                    whatsapp-tools-state-directory))

(defun whatsapp-tools--safe-path (path)
  "Refuse links anywhere along the preference PATH."
  (let ((current (expand-file-name path)))
    (while current
      (when (file-symlink-p current) (user-error "Chat preferences must not use symbolic links"))
      (let ((parent (file-name-directory (directory-file-name current))))
        (setq current (unless (equal current parent) parent))))))

(defun whatsapp-tools--ensure-state ()
  "Load at most 1000 validated preference entries once per account."
  (unless (equal whatsapp-tools--scope (whatsapp--origin-key))
    (setq whatsapp-tools--scope (whatsapp--origin-key)
          whatsapp-tools--preferences (make-hash-table :test 'equal))
    (condition-case nil
        (let* ((file (whatsapp-tools--state-file)) (attributes (file-attributes file)))
          (whatsapp-tools--safe-path file)
          (when attributes
            (unless (and (null (file-attribute-type attributes))
                         (= (file-attribute-user-id attributes) (user-uid))
                         (zerop (logand #o077 (file-modes file)))
                         (< (file-attribute-size attributes) 262144))
              (error "Unsafe chat preference file"))
            (let ((json-object-type 'alist) (json-array-type 'list)
                  (json-key-type 'string) (json-false nil) (json-null nil))
              (let ((records (json-read-file file)))
                (unless (and (listp records) (<= (length records) 1000))
                  (error "Invalid chat preferences"))
                (dolist (record records)
                  (let ((jid (cdr (assoc "jid" record))))
                    (unless (and (whatsapp-profiles--jid-p jid)
                                 (memq (cdr (assoc "archived" record)) '(nil t))
                                 (memq (cdr (assoc "pinned" record)) '(nil t)))
                      (error "Invalid chat preference entry"))
                    (puthash (whatsapp-profiles--key jid)
                             (list :archived (cdr (assoc "archived" record))
                                   :pinned (cdr (assoc "pinned" record)))
                             whatsapp-tools--preferences)))))))
      (error
       (clrhash whatsapp-tools--preferences)
       (message "Chat preferences could not be loaded; existing file retained")))))

(defun whatsapp-tools--flag (jid flag)
  (whatsapp-tools--ensure-state)
  (plist-get (gethash (whatsapp-profiles--key jid) whatsapp-tools--preferences) flag))

(defun whatsapp-tools--save ()
  "Atomically save bounded JSON, with private file and directory permissions."
  (let ((file (whatsapp-tools--state-file)) records temporary)
    (whatsapp-tools--safe-path file)
    (when (> (hash-table-count whatsapp-tools--preferences) 1000)
      (user-error "Chat preference limit reached (1000 conversations)"))
    (make-directory whatsapp-tools-state-directory t)
    (set-file-modes whatsapp-tools-state-directory #o700)
    (maphash (lambda (jid flags)
               (push (list (cons "jid" jid)
                           (cons "archived" (if (plist-get flags :archived) t :json-false))
                           (cons "pinned" (if (plist-get flags :pinned) t :json-false))) records))
             whatsapp-tools--preferences)
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".preferences-" whatsapp-tools-state-directory)))
          (set-file-modes temporary #o600)
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (json-encode (vconcat records)) nil temporary nil 'silent))
          (whatsapp-tools--safe-path file)
          (rename-file temporary file t))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))))

(defun whatsapp-tools--set-flag (jid flag value)
  (whatsapp-tools--ensure-state)
  (let* ((key (whatsapp-profiles--key jid))
         (old (gethash key whatsapp-tools--preferences))
         (flags (plist-put (copy-sequence old) flag value)))
    (if (or (plist-get flags :archived) (plist-get flags :pinned))
        (puthash key flags whatsapp-tools--preferences)
      (remhash key whatsapp-tools--preferences))
    (condition-case error
        (whatsapp-tools--save)
      (error
       (if old (puthash key old whatsapp-tools--preferences) (remhash key whatsapp-tools--preferences))
       (signal (car error) (cdr error))))))

(defun whatsapp-tools--jid-at-point ()
  (when (or (and (derived-mode-p 'whatsapp-chat-mode 'whatsapp-root-mode) whatsapp--read-origin
                 (not (equal whatsapp--read-origin (whatsapp--origin-key))))
            (and (derived-mode-p 'whatsapp-profile-mode) whatsapp-profiles--detail-origin
                 (not (equal whatsapp-profiles--detail-origin (whatsapp--origin-key)))))
    (user-error "Account changed; reopen this conversation"))
  (let ((jid (if (derived-mode-p 'whatsapp-chat-mode) whatsapp-chat--jid
               (or (get-text-property (point) 'whatsapp-jid)
                   (and (derived-mode-p 'whatsapp-profile-mode) whatsapp-profiles--detail-jid)))))
    (unless (whatsapp-profiles--jid-p jid) (user-error "Choose a conversation first"))
    jid))

(defun whatsapp-tools--refresh ()
  (when-let ((buffer (get-buffer "*WhatsApp*")))
    (with-current-buffer buffer (whatsapp-root--render whatsapp--chats))))

(defun whatsapp-tools--accepted-p (result)
  (let* ((body (cdr-safe result)) (status (and (listp body) (cdr (assoc "wuzapi_status" body))))
         (provider (and (listp body) (cdr (assoc "data" body)))))
    (and (equal (car-safe result) 200) (integerp status) (<= 200 status 299)
         (listp provider) (eq (cdr (assoc "success" provider)) t))))

(defun whatsapp-archive-chat (jid archived)
  "Ask WhatsApp to set JID's ARCHIVED state; record only confirmed success.
With a prefix argument interactively, unarchive. Never automatically retry."
  (interactive (list (whatsapp-tools--jid-at-point) (not current-prefix-arg)))
  (unless (and (whatsapp-profiles--jid-p jid) (memq archived '(nil t)))
    (user-error "Invalid archive request"))
  (let* ((origin (whatsapp--origin-key)) (key (cons origin (whatsapp-profiles--key jid)))
         (ticket (list t)))
    (when (gethash key whatsapp-tools--pending) (user-error "An archive request is already pending"))
    (puthash key ticket whatsapp-tools--pending)
    (condition-case error
        (whatsapp--request-async
         "POST" "/archive" (list (cons "jid" jid) (cons "archive" (if archived t :json-false)))
         (lambda (result)
           (when (eq ticket (gethash key whatsapp-tools--pending))
             (remhash key whatsapp-tools--pending)
             (when (equal origin (whatsapp--origin-key))
               (if (whatsapp-tools--accepted-p result)
                   (condition-case nil
                       (progn (whatsapp-tools--set-flag jid :archived archived)
                              (whatsapp-tools--refresh)
                              (message "WhatsApp confirmed: conversation %s" (if archived "archived" "unarchived")))
                     (error (message "WhatsApp confirmed the change, but local preferences could not be saved")))
                 (message "Archive state unconfirmed; check connection and retry explicitly"))))))
      (error (remhash key whatsapp-tools--pending) (signal (car error) (cdr error))))))

(defun whatsapp-toggle-chat-archive ()
  (interactive)
  (let ((jid (whatsapp-tools--jid-at-point)))
    (whatsapp-archive-chat jid (not (whatsapp-tools--flag jid :archived)))))

(defun whatsapp-pin-chat (jid)
  "Toggle a local, account-scoped pin for JID without sending a message."
  (interactive (list (whatsapp-tools--jid-at-point)))
  (unless (whatsapp-profiles--jid-p jid) (user-error "Choose a supported conversation"))
  (let ((pinned (not (whatsapp-tools--flag jid :pinned))))
    (whatsapp-tools--set-flag jid :pinned pinned)
    (whatsapp-tools--refresh)
    (message "Conversation %s locally" (if pinned "pinned" "unpinned"))))

(defun whatsapp-tools--ordered (chats)
  "Put locally pinned chats first, preserving order inside each group."
  (append (cl-remove-if-not (lambda (chat) (whatsapp-tools--flag (cdr (assoc "jid" chat)) :pinned)) chats)
          (cl-remove-if (lambda (chat) (whatsapp-tools--flag (cdr (assoc "jid" chat)) :pinned)) chats)))

(defun whatsapp-copy-chat-identity ()
  (interactive)
  (kill-new (whatsapp-tools--jid-at-point))
  (message "Conversation identity copied"))

(defun whatsapp-show-archived ()
  "Open the cached Archived view without a network request."
  (interactive)
  (let ((buffer (whatsapp--root-buffer)))
    (with-current-buffer buffer (whatsapp-root-set-filter 'archived))
    (pop-to-buffer buffer)))

(defun whatsapp-chat-tools ()
  "Offer keyboard-accessible actions for the conversation at point."
  (interactive)
  (let* ((jid (whatsapp-tools--jid-at-point))
         (commands `((,(if (whatsapp-tools--flag jid :archived) "Unarchive on WhatsApp" "Archive on WhatsApp") . whatsapp-toggle-chat-archive)
                     (,(if (whatsapp-tools--flag jid :pinned) "Unpin locally" "Pin locally") . whatsapp-pin-chat)
                     ("Contact details / photo" . whatsapp-profile-at-point)
                     ("Copy conversation identity" . whatsapp-copy-chat-identity)))
         (choice (completing-read "Conversation action: " commands nil t)))
    (call-interactively (cdr (assoc choice commands)))))

(defalias 'whatsappel #'whatsapp)
(define-key whatsapp-root-mode-map (kbd "a") #'whatsapp-toggle-chat-archive)
(define-key whatsapp-root-mode-map (kbd "P") #'whatsapp-pin-chat)
(define-key whatsapp-root-mode-map (kbd "m") #'whatsapp-chat-tools)
(define-key whatsapp-root-row-map [mouse-3] #'whatsapp-tools-click)
(define-key whatsapp-profile-avatar-map [mouse-3] #'whatsapp-tools-click)
(defun whatsapp-tools-click (event)
  (interactive "e") (mouse-set-point event) (whatsapp-chat-tools))
(define-key whatsapp-chat-mode-map (kbd "C-c C-t") #'whatsapp-chat-tools)
(provide 'whatsapp-tools)
;;; whatsapp-tools.el ends here
