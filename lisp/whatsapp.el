;;; whatsapp.el --- WhatsApp client for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 berkeley, Cristian Cezar Moisés
;; Author: berkeley, Cristian Cezar Moisés
;; URL: https://codeberg.org/berkeley/whatsappel
;; Version: 2.7.2
;; Package-Requires: ((emacs "28.1") (websocket "1.14"))
;; Keywords: comm, chat, whatsapp

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Full WhatsApp client for Emacs.
;; Sprint 7: profile pics, audio playback, chat export, drafts,
;; link previews, compose typing indicators.

;;; Code:

(require 'json) (require 'url) (require 'url-http) (require 'ewoc)
(require 'cl-lib) (require 'websocket) (require 'subr-x) (require 'bookmark)

;; =========================================================================
;;  Customization
;; =========================================================================

(defgroup whatsapp nil "WhatsApp client for Emacs." :group 'comm :prefix "whatsapp-")
(defcustom whatsapp-server-host "localhost" "Bridge hostname." :type 'string)
(defcustom whatsapp-server-port 3000 "HTTP port." :type 'integer)
(defcustom whatsapp-ws-port 3001 "WebSocket port." :type 'integer)
(defcustom whatsapp-api-token ""
  "Bearer token for API authentication.
Set to match WAEL_API_TOKEN on the server. Empty = no auth." :type 'string)
(defcustom whatsapp-history-fetch-count 50 "Messages to load." :type 'integer)
(defcustom whatsapp-auto-read t "Auto-mark read." :type 'boolean)
(defcustom whatsapp-typing-indicator t "Send typing." :type 'boolean)
(defcustom whatsapp-typing-debounce 2.0 "Typing debounce secs." :type 'number)
(defcustom whatsapp-typing-timeout 5.0 "Typing expire secs." :type 'number)
(defcustom whatsapp-time-format "%H:%M" "Timestamp format." :type 'string)
(defcustom whatsapp-date-format "%Y-%m-%d %a" "Date format." :type 'string)
(defcustom whatsapp-media-directory (expand-file-name "whatsapp-media" user-emacs-directory) "Media storage." :type 'directory)
(defcustom whatsapp-notification-function #'whatsapp--notify-default "Notification handler." :type 'function)
(defcustom whatsapp-convert-org-markup t "Org → WA formatting." :type 'boolean)
(defcustom whatsapp-voice-record-command "sox" "Voice recorder." :type 'string)
(defcustom whatsapp-voice-format "ogg" "Voice format." :type 'string)
(defcustom whatsapp-inline-images t "Inline images." :type 'boolean)
(defcustom whatsapp-inline-image-max-width 300 "Max image width px." :type 'integer)
(defcustom whatsapp-render-formatting t "Render *bold* _italic_." :type 'boolean)
(defcustom whatsapp-clickable-urls t "Clickable URLs." :type 'boolean)
(defcustom whatsapp-relative-timestamps nil "Relative timestamps." :type 'boolean)
(defcustom whatsapp-show-archive nil "Show archived chats." :type 'boolean)
(defcustom whatsapp-sender-colors '("#e06c75" "#98c379" "#61afef" "#c678dd" "#e5c07b" "#56b6c2" "#be5046" "#d19a66") "Sender colors." :type '(repeat string))
(defcustom whatsapp-show-link-previews t "Show link preview metadata below messages." :type 'boolean)
(defcustom whatsapp-show-profile-pics t "Show contact/chat profile pictures (avatars) in the chat list." :type 'boolean)
(defcustom whatsapp-audio-player "mpv" "Program to play audio. Set to \"emms\" to use EMMS." :type 'string)
(defcustom whatsapp-video-player "mpv" "Program to play videos." :type 'string)
(defcustom whatsapp-animate-gifs t "Animate GIFs/animated stickers inline in the chat buffer." :type 'boolean)
(defcustom whatsapp-export-directory (expand-file-name "whatsapp-exports" user-emacs-directory) "Chat export directory." :type 'directory)

(defcustom whatsapp-quick-replies
  '(("ok" . "👍 OK!")
    ("omw" . "On my way!")
    ("brb" . "Be right back")
    ("ty" . "Thank you! 🙏")
    ("busy" . "I'm busy right now, I'll get back to you later.")
    ("call" . "Can't talk now, can I call you later?"))
  "Alist of (SHORTCUT . TEXT) for quick replies.
Use `whatsapp-chat-quick-reply' to pick one." :type '(alist :key-type string :value-type string))

(defcustom whatsapp-notification-sound nil
  "Path to audio file played on new message. Nil to disable.
Uses `play-sound-file' in GUI Emacs, or `aplay'/`afplay' as fallback."
  :type '(choice (const nil) file))

(defcustom whatsapp-auto-away nil
  "Auto-away message sent when Emacs is idle for `whatsapp-auto-away-idle' seconds.
Nil to disable." :type '(choice (const nil) string))

(defcustom whatsapp-auto-away-idle 300
  "Seconds of Emacs idle time before sending auto-away." :type 'integer)

;; =========================================================================
;;  Faces
;; =========================================================================

(defgroup whatsapp-faces nil "Faces for WhatsApp." :group 'whatsapp)
(defface whatsapp-chat-name '((t :inherit font-lock-function-name-face :weight bold)) "Chat names.")
(defface whatsapp-chat-preview '((t :inherit shadow)) "Message preview.")
(defface whatsapp-chat-timestamp '((t :inherit font-lock-comment-face)) "Chat timestamps.")
(defface whatsapp-chat-unread '((t :inherit bold)) "Unread chats.")
(defface whatsapp-chat-unread-badge '((t :inherit warning :weight bold)) "Unread badge.")
(defface whatsapp-chat-muted '((t :inherit shadow :slant italic)) "Muted chats.")
(defface whatsapp-chat-pinned '((t :inherit success)) "Pin indicator.")
(defface whatsapp-chat-group-indicator '((t :inherit font-lock-type-face)) "Group indicator.")
(defface whatsapp-chat-presence-online '((t :inherit success)) "Online.")
(defface whatsapp-chat-presence-offline '((t :inherit shadow)) "Offline.")
(defface whatsapp-msg-self '((t :inherit font-lock-string-face)) "Own messages.")
(defface whatsapp-msg-other '((t :inherit default)) "Others' messages.")
(defface whatsapp-msg-sender '((t :inherit font-lock-keyword-face :weight bold)) "Sender names.")
(defface whatsapp-msg-timestamp '((t :inherit font-lock-comment-face)) "Timestamps.")
(defface whatsapp-msg-quote '((t :inherit font-lock-doc-face :slant italic)) "Quoted text.")
(defface whatsapp-msg-system '((t :inherit font-lock-comment-face :slant italic)) "System msgs.")
(defface whatsapp-msg-status-sent '((t :inherit shadow)) "Sent.")
(defface whatsapp-msg-status-read '((t :inherit success)) "Read.")
(defface whatsapp-msg-media-link '((t :inherit link)) "Media links.")
(defface whatsapp-msg-deleted '((t :inherit shadow :strike-through t)) "Deleted.")
(defface whatsapp-msg-date-header '((t :inherit font-lock-preprocessor-face :weight bold)) "Date headers.")
(defface whatsapp-msg-reaction '((t :inherit highlight :height 0.9)) "Reactions.")
(defface whatsapp-msg-starred '((t :inherit warning)) "Starred.")
(defface whatsapp-msg-bold '((t :weight bold)) "WA bold.")
(defface whatsapp-msg-italic '((t :slant italic)) "WA italic.")
(defface whatsapp-msg-strike '((t :strike-through t)) "WA strike.")
(defface whatsapp-msg-code '((t :inherit fixed-pitch :inherit font-lock-constant-face)) "WA code.")
(defface whatsapp-msg-url '((t :inherit link)) "URLs.")
(defface whatsapp-msg-link-preview '((t :inherit font-lock-doc-face :slant italic)) "Link previews.")
(defface whatsapp-compose-prompt '((t :inherit minibuffer-prompt)) "Compose prompt.")
(defface whatsapp-compose-separator '((t :inherit font-lock-comment-face :extend t)) "Compose sep.")
(defface whatsapp-unread-separator '((t :inherit warning :weight bold :extend t)) "Unread sep.")
(defface whatsapp-typing-indicator '((t :inherit font-lock-comment-face :slant italic)) "Typing.")
(defface whatsapp-contact-phone '((t :inherit font-lock-constant-face)) "Phone numbers.")
(defface whatsapp-chat-initials '((t :inherit font-lock-type-face :weight bold)) "Initials.")
(defface whatsapp-new-msg-indicator '((t :inherit warning :weight bold)) "New msgs counter.")
(defface whatsapp-msg-gutter-self '((t :inherit success :weight bold)) "Left gutter bar for own messages.")
(defface whatsapp-msg-self-name '((t :inherit success :weight bold)) "\"You\" label on own messages.")
(defface whatsapp-msg-meta '((t :inherit shadow :height 0.9)) "Trailing timestamp/status metadata.")

;; =========================================================================
;;  State
;; =========================================================================

(defvar whatsapp--ws nil) (defvar whatsapp--connection-state 'disconnected)
(defvar whatsapp--reconnect-timer nil) (defvar whatsapp--reconnect-attempt 0)
(defvar whatsapp--chats nil) (defvar whatsapp--contacts nil) (defvar whatsapp--presence nil)
(defvar whatsapp--unread-total 0) (defvar whatsapp--my-jid nil)
(defvar whatsapp--last-qr nil "Most recent QR data URL pushed by the bridge server.")
(defvar whatsapp--event-queue nil) (defvar whatsapp--event-timer nil)
(defvar whatsapp--voice-process nil) (defvar whatsapp--voice-file nil)
(defvar whatsapp--drafts (make-hash-table :test #'equal) "JID → draft text.")
(defvar whatsapp--pic-cache (make-hash-table :test #'equal) "JID → image/nil.")
(defvar whatsapp--image-cache (make-hash-table :test #'equal) "msgId → image | \\='loading | \\='none.")

(defvar-local whatsapp--chat-jid nil) (defvar-local whatsapp--chat-ewoc nil)
(defvar-local whatsapp--oldest-msg-id nil) (defvar-local whatsapp--history-requested nil)
(defvar-local whatsapp--chat-messages nil) (defvar-local whatsapp--chat-typing nil)
(defvar-local whatsapp--typing-timer nil) (defvar-local whatsapp--last-typing-sent 0)
(defvar-local whatsapp--compose-marker nil) (defvar-local whatsapp--reply-to-id nil)
(defvar-local whatsapp--new-msg-count 0) (defvar-local whatsapp--at-bottom t)
(defvar-local whatsapp--compose-target-jid nil) (defvar-local whatsapp--compose-quote-id nil)

;; =========================================================================
;;  Data
;; =========================================================================

(cl-defstruct (whatsapp-message (:constructor whatsapp-message-create))
  id jid from-me sender sender-name text type timestamp status
  quoted-id quoted-text quoted-sender deleted edited reactions
  has-media mimetype file-name file-length seconds ptt starred
  link-preview)

(defvar whatsapp--emoji-list
  '("👍" "❤️" "😂" "😮" "😢" "🙏" "🔥" "🎉" "💯" "👏" "😍" "🤔" "👀" "💪" "🤣" "😊" "🥰" "😭" "😤" "🤝"
    "✅" "❌" "⭐" "💡" "📌" "🚀" "💀" "🤷" "🙄" "😅" "🫡" "🫶" "🤞" "🤙" "👋" "🎯" "💜" "💙" "💚" "🧡"))

(defun whatsapp--read-emoji ()
  (completing-read "Emoji: " (mapcar (lambda (e) (cons e e)) whatsapp--emoji-list) nil nil))

;; =========================================================================
;;  HTTP
;; =========================================================================

(defun whatsapp--api-url (p) (format "http://%s:%d/api/v1%s" whatsapp-server-host whatsapp-server-port p))

(defun whatsapp--http-get (path cb)
  (let ((url-request-extra-headers (when (not (string-empty-p whatsapp-api-token))
                                     `(("Authorization" . ,(concat "Bearer " whatsapp-api-token))))))
    (url-retrieve (whatsapp--api-url path)
      (lambda (st) (unwind-protect (unless (plist-get st :error) (goto-char url-http-end-of-headers)
          (let* ((json-object-type 'plist) (json-array-type 'list) (json-key-type 'keyword) (r (ignore-errors (json-read))))
            (when (and r (plist-get r :ok)) (funcall cb (plist-get r :data))))) (kill-buffer))) nil t t)))

(defun whatsapp--auth-headers ()
  "Return auth headers if token is configured."
  (when (not (string-empty-p whatsapp-api-token))
    `(("Authorization" . ,(concat "Bearer " whatsapp-api-token)))))

(defun whatsapp--curl-auth ()
  "Return curl auth flag string, or empty."
  (if (string-empty-p whatsapp-api-token) ""
    (format "-H 'Authorization: Bearer %s'" whatsapp-api-token)))

(defun whatsapp--http-post (path body cb)
  (let ((url-request-method "POST")
        (url-request-extra-headers `(("Content-Type" . "application/json") ,@(whatsapp--auth-headers)))
        (url-request-data (encode-coding-string (json-serialize (or body '(:_x t))) 'utf-8)))
    (url-retrieve (whatsapp--api-url path)
      (lambda (st) (unwind-protect (unless (plist-get st :error) (goto-char url-http-end-of-headers)
        (let* ((json-object-type 'plist) (json-array-type 'list) (json-key-type 'keyword) (r (ignore-errors (json-read))))
          (when cb (funcall cb r)))) (kill-buffer))) nil t t)))

(defun whatsapp--http-delete (path cb)
  (let ((url-request-method "DELETE") (url-request-extra-headers (whatsapp--auth-headers)))
    (url-retrieve (whatsapp--api-url path)
      (lambda (st) (unwind-protect (unless (plist-get st :error) (goto-char url-http-end-of-headers)
        (let* ((json-object-type 'plist) (json-array-type 'list) (json-key-type 'keyword) (r (ignore-errors (json-read))))
          (when cb (funcall cb r)))) (kill-buffer))) nil t t)))

(defun whatsapp--ack (&optional ok-msg)
  "Response callback that reports OK-MSG (default ✓) or the server error text."
  (lambda (r) (if (and r (plist-get r :ok)) (message "%s" (or ok-msg "✓"))
                (message "✗ %s" (or (and r (plist-get r :error)) "request failed")))))

(defun whatsapp--http-get-binary (path out-file cb)
  "GET PATH, write the binary body to OUT-FILE, call CB with non-nil on success.
Refuses to save a JSON error body as media (so a failed download never produces
a corrupt file reported as success)."
  (let ((url-request-extra-headers (whatsapp--auth-headers)))
    (url-retrieve (whatsapp--api-url path)
      (lambda (status)
        (condition-case nil
            (if (plist-get status :error) (funcall cb nil)
              (goto-char (point-min))
              (let* ((hdr-end (and (re-search-forward "\r?\n\r?\n" nil t) (point)))
                     (ct (and hdr-end (save-excursion (goto-char (point-min))
                            (and (re-search-forward "^Content-Type:[ \t]*\\([^\r\n]*\\)" hdr-end t) (match-string 1))))))
                (cond ((null hdr-end) (kill-buffer) (funcall cb nil))
                      ((and ct (string-match-p "application/json" ct)) (kill-buffer) (funcall cb nil))
                      (t (let ((coding-system-for-write 'binary)) (write-region hdr-end (point-max) out-file nil 'silent))
                         (kill-buffer) (funcall cb t)))))
          (error (funcall cb nil))))
      nil t t)))

;; =========================================================================
;;  WebSocket
;; =========================================================================

(defun whatsapp--ws-url ()
  "Build WebSocket URL, including token if configured."
  (let ((base (format "ws://%s:%d" whatsapp-server-host whatsapp-ws-port)))
    (if (string-empty-p whatsapp-api-token) base
      (format "%s?token=%s" base whatsapp-api-token))))

(defun whatsapp--ws-connect ()
  (when whatsapp--ws (ignore-errors (websocket-close whatsapp--ws)))
  (setq whatsapp--connection-state 'connecting)
  (condition-case err
      (setq whatsapp--ws (websocket-open (whatsapp--ws-url)
        :on-open (lambda (_) (setq whatsapp--connection-state 'open whatsapp--reconnect-attempt 0)
                   (when whatsapp--reconnect-timer (cancel-timer whatsapp--reconnect-timer) (setq whatsapp--reconnect-timer nil))
                   (message "WhatsApp: connected") (whatsapp--update-mode-line)
                   (run-hook-with-args 'whatsapp-connection-hook 'open))
        :on-message (lambda (_ f) (let* ((json-object-type 'plist) (json-array-type 'list) (json-key-type 'keyword)
                                          (p (ignore-errors (json-read-from-string (websocket-frame-text f)))))
                       (when p (push p whatsapp--event-queue)
                             (unless whatsapp--event-timer (setq whatsapp--event-timer (run-with-idle-timer 0.05 nil #'whatsapp--flush-events))))))
        :on-close (lambda (_) (setq whatsapp--connection-state 'disconnected) (message "WhatsApp: disconnected")
                    (whatsapp--update-mode-line) (whatsapp--schedule-reconnect))
        :on-error (lambda (_ _t e) (message "WhatsApp ws error: %s" e))))
    (error (message "WhatsApp: failed — %s" (error-message-string err)) (whatsapp--schedule-reconnect))))

(defun whatsapp--schedule-reconnect ()
  (when whatsapp--reconnect-timer (cancel-timer whatsapp--reconnect-timer))
  (cl-incf whatsapp--reconnect-attempt)
  (setq whatsapp--reconnect-timer (run-with-timer (+ (min (expt 2 (1- whatsapp--reconnect-attempt)) 30) (/ (random 500) 1000.0)) nil #'whatsapp--ws-connect)))

;; =========================================================================
;;  Events
;; =========================================================================

(defun whatsapp--flush-events ()
  (setq whatsapp--event-timer nil)
  ;; Capture and clear the queue atomically so a burst arriving mid-flush isn't lost.
  (let ((evs (nreverse whatsapp--event-queue)))
    (setq whatsapp--event-queue nil)
    (dolist (ev evs)
      (condition-case e (whatsapp--handle-event ev) (error (message "WA event err: %s" e))))))

(defun whatsapp--handle-event (p)
  (pcase (plist-get p :event)
    ("connection.update" (pcase (plist-get (plist-get p :data) :state)
      ("open" (setq whatsapp--connection-state 'open) (whatsapp--http-get "/session/me" (lambda (d) (setq whatsapp--my-jid (plist-get d :jid))))
              (whatsapp--http-get "/contacts" (lambda (cs) (dolist (c cs) (setf (alist-get (plist-get c :jid) whatsapp--contacts nil nil #'equal) c)) (whatsapp--refresh-chat-list-buffer)))
              ;; Reload chat list and re-subscribe presence for open chats after a (re)connect.
              (whatsapp--http-get "/chats" (lambda (cs) (when cs (setq whatsapp--chats nil) (dolist (c cs) (push (cons (plist-get c :jid) c) whatsapp--chats)) (whatsapp--recompute-unread) (whatsapp--refresh-chat-list-buffer))))
              (dolist (b (buffer-list)) (with-current-buffer b (when (and (derived-mode-p 'whatsapp-chat-mode) whatsapp--chat-jid (not (whatsapp--is-group-jid whatsapp--chat-jid))) (whatsapp--http-post "/presence/subscribe" `(:jid ,whatsapp--chat-jid) nil))))
              (message "WhatsApp: connected"))
      ("qr" (setq whatsapp--connection-state 'qr)
            (let ((qr (plist-get (plist-get p :data) :qr)))
              (if (and qr (stringp qr))
                  (progn (setq whatsapp--last-qr qr) (whatsapp--display-qr qr))
                (message "WhatsApp: QR ready — M-x whatsapp-show-qr to scan"))))
      ("disconnected" (setq whatsapp--connection-state 'disconnected))) (whatsapp--update-mode-line))
    ((or "chats.upsert" "chats.update") (let ((raw (plist-get (plist-get p :data) :chats)))
      (when raw (setq whatsapp--chats nil) (dolist (c raw) (push (cons (plist-get c :jid) c) whatsapp--chats))
            (whatsapp--recompute-unread) (whatsapp--refresh-chat-list-buffer))))
    ("chats.delete" (dolist (j (plist-get (plist-get p :data) :jids)) (setq whatsapp--chats (assoc-delete-all j whatsapp--chats)))
      (whatsapp--recompute-unread) (whatsapp--refresh-chat-list-buffer))
    ("messages.upsert" (let* ((d (plist-get p :data)) (jid (plist-get d :jid)) (msg (whatsapp--plist-to-message (plist-get d :message))))
      (whatsapp--chat-buffer-add-message jid msg)
      (unless (whatsapp-message-from-me msg)
        (setq whatsapp--last-received (whatsapp-message-text msg))
        (unless (whatsapp--chat-buffer-visible-p jid)
          (unless (whatsapp--chat-muted-p jid)
            (funcall whatsapp-notification-function (whatsapp-message-sender-name msg) (whatsapp-message-text msg) jid)
            (whatsapp--play-notification-sound)
            (whatsapp--maybe-auto-reply jid))))
      (when (and whatsapp-auto-read (whatsapp--chat-buffer-visible-p jid)) (whatsapp--mark-read jid (list (whatsapp-message-id msg))))))
    ("messages.update" (let ((d (plist-get p :data))) (whatsapp--chat-buffer-update-status (plist-get d :jid) (plist-get d :msgId) (plist-get d :status))))
    ("messages.delete" (let ((d (plist-get p :data))) (whatsapp--chat-buffer-mark-deleted (plist-get d :jid) (plist-get d :msgId))))
    ("messages.edit" (let* ((d (plist-get p :data)) (m (whatsapp--plist-to-message (plist-get d :message)))) (setf (whatsapp-message-edited m) t) (whatsapp--chat-buffer-update-message (plist-get d :jid) m)))
    ("messages.reaction" (let ((d (plist-get p :data))) (whatsapp--chat-buffer-update-reactions (plist-get d :jid) (plist-get d :msgId) (whatsapp--parse-reactions (plist-get d :reactions)))))
    ("messages.star" (let ((d (plist-get p :data))) (dolist (b (buffer-list)) (with-current-buffer b
      (when (and (derived-mode-p 'whatsapp-chat-mode) whatsapp--chat-messages)
        (let ((n (gethash (plist-get d :msgId) whatsapp--chat-messages)))
          (when n (setf (whatsapp-message-starred (ewoc-data n)) (eq (plist-get d :starred) t))
                (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc n)))))))))
    ("message-receipt.update" (let ((d (plist-get p :data))) (whatsapp--chat-buffer-update-status (plist-get d :jid) (plist-get d :msgId) (or (plist-get d :status) 3))))
    ("presence.update" (let* ((d (plist-get p :data)) (jid (plist-get d :jid)))
      (dolist (pair (whatsapp--plist-pairs (plist-get d :presences)))
        (setf (alist-get (car pair) whatsapp--presence nil nil #'equal)
              `(:lastKnown ,(plist-get (cdr pair) :lastKnownPresence) :lastSeen ,(float-time)))
        (pcase (plist-get (cdr pair) :lastKnownPresence)
          ((or "composing" "recording") (whatsapp--set-typing jid (car pair) t))
          (_ (whatsapp--set-typing jid (car pair) nil))))
      (whatsapp--refresh-chat-list-buffer)))
    ((or "contacts.upsert" "contacts.update") (dolist (c (plist-get (plist-get p :data) :contacts))
      (setf (alist-get (plist-get c :jid) whatsapp--contacts nil nil #'equal) c))
      (whatsapp--refresh-chat-list-buffer))
    ((or "groups.upsert" "groups.update") (whatsapp--refresh-chat-list-buffer))
    ("history.set" (dolist (j (plist-get (plist-get p :data) :jids))
      (when (whatsapp--get-chat-buffer j) (whatsapp--reload-chat-history j))))))

(defun whatsapp--plist-pairs (pl) (let (r) (while pl (push (cons (let ((k (pop pl))) (if (keywordp k) (substring (symbol-name k) 1) (format "%s" k))) (pop pl)) r)) (nreverse r)))

;; =========================================================================
;;  Typing
;; =========================================================================

(defun whatsapp--set-typing (chat-jid typer typing-p)
  (let ((buf (whatsapp--get-chat-buffer chat-jid)))
    (when (and buf (buffer-live-p buf)) (with-current-buffer buf
      (if typing-p (progn (cl-pushnew typer whatsapp--chat-typing :test #'equal)
                     (when whatsapp--typing-timer (cancel-timer whatsapp--typing-timer))
                     (setq whatsapp--typing-timer (run-with-timer whatsapp-typing-timeout nil
                       (lambda () (when (buffer-live-p buf) (with-current-buffer buf (setq whatsapp--chat-typing nil) (whatsapp--update-chat-header)))))))
        (setq whatsapp--chat-typing (delete typer whatsapp--chat-typing)))
      (whatsapp--update-chat-header)))))

(defun whatsapp--update-chat-header ()
  (when (derived-mode-p 'whatsapp-chat-mode)
    (let* ((name (whatsapp--chat-display-name whatsapp--chat-jid))
           (tp (mapcar (lambda (j) (or (whatsapp--contact-name j) (replace-regexp-in-string "@.*" "" j))) whatsapp--chat-typing))
           (pr (alist-get whatsapp--chat-jid whatsapp--presence nil nil #'equal))
           (ps (when (and pr (not (whatsapp--is-group-jid whatsapp--chat-jid)))
                 (if (equal (plist-get pr :lastKnown) "available") (propertize " ●" 'face 'whatsapp-chat-presence-online)
                   (propertize " ○" 'face 'whatsapp-chat-presence-offline))))
           (ts (when tp (propertize (format " — %s typing…" (string-join tp ", ")) 'face 'whatsapp-typing-indicator)))
           (ns (when (and (> whatsapp--new-msg-count 0) (not whatsapp--at-bottom))
                 (propertize (format " ↓ %d new" whatsapp--new-msg-count) 'face 'whatsapp-new-msg-indicator)))
           (rs (when whatsapp--reply-to-id (propertize " [replying]" 'face 'whatsapp-msg-quote))))
      (setq header-line-format (concat " 💬 " (propertize name 'face 'whatsapp-chat-name) (or ps "") (or ts "") (or ns "") (or rs "")))
      (force-mode-line-update))))

(defun whatsapp--send-typing-composing ()
  (when (and whatsapp-typing-indicator whatsapp--chat-jid)
    (let ((now (float-time))) (when (> (- now whatsapp--last-typing-sent) whatsapp-typing-debounce)
      (setq whatsapp--last-typing-sent now) (whatsapp--http-post "/presence/update" `(:jid ,whatsapp--chat-jid :type "composing") nil)))))

(defun whatsapp--send-typing-paused ()
  (when (and whatsapp-typing-indicator whatsapp--chat-jid)
    (whatsapp--http-post "/presence/update" `(:jid ,whatsapp--chat-jid :type "paused") nil)))

;; =========================================================================
;;  Data conversion
;; =========================================================================

(defun whatsapp--plist-to-message (pl)
  (let ((lp (plist-get pl :linkPreview)))
    (whatsapp-message-create
     :id (plist-get pl :id) :jid (plist-get pl :jid) :from-me (eq (plist-get pl :fromMe) t)
     :sender (plist-get pl :sender) :sender-name (or (plist-get pl :senderName) "")
     :text (or (plist-get pl :text) "") :type (or (plist-get pl :type) "text")
     :timestamp (or (plist-get pl :timestamp) 0) :status (or (plist-get pl :status) 0)
     :quoted-id (plist-get pl :quotedId) :quoted-text (plist-get pl :quotedText)
     :quoted-sender (plist-get pl :quotedSender) :deleted (eq (plist-get pl :deleted) t)
     :edited (eq (plist-get pl :edited) t) :reactions (whatsapp--parse-reactions (plist-get pl :reactions))
     :has-media (eq (plist-get pl :hasMedia) t) :mimetype (plist-get pl :mimetype)
     :file-name (plist-get pl :fileName) :file-length (plist-get pl :fileLength)
     :seconds (plist-get pl :seconds) :ptt (eq (plist-get pl :ptt) t) :starred (eq (plist-get pl :starred) t)
     :link-preview (when lp `(:url ,(plist-get lp :url) :title ,(plist-get lp :title) :description ,(plist-get lp :description))))))

(defun whatsapp--parse-reactions (raw) (when raw (mapcar (lambda (r) (cons (plist-get r :emoji) (or (plist-get r :count) 1))) raw)))
(defun whatsapp--format-timestamp (ms) (if (or (null ms) (<= ms 0)) "" (if whatsapp-relative-timestamps (whatsapp--relative-time ms) (format-time-string whatsapp-time-format (seconds-to-time (/ ms 1000.0))))))
(defun whatsapp--format-timestamp-full (ms) (if (or (null ms) (<= ms 0)) "" (format-time-string "%Y-%m-%d %H:%M:%S" (seconds-to-time (/ ms 1000.0)))))
(defun whatsapp--relative-time (ms) (let ((d (/ (- (* (float-time) 1000.0) ms) 1000.0)))
  (cond ((< d 60) "now") ((< d 3600) (format "%dm" (floor (/ d 60)))) ((< d 86400) (format "%dh" (floor (/ d 3600)))) ((< d 604800) (format "%dd" (floor (/ d 86400)))) (t (format-time-string "%m/%d" (seconds-to-time (/ ms 1000.0)))))))
(defun whatsapp--format-date (ms)
  "Format MS as smart date: Today, Yesterday, weekday, or full date."
  (if (or (null ms) (<= ms 0)) ""
    (let* ((now (current-time))
           (time (seconds-to-time (/ ms 1000.0)))
           (today (format-time-string "%Y-%m-%d" now))
           (yesterday (format-time-string "%Y-%m-%d" (time-subtract now 86400)))
           (msg-date (format-time-string "%Y-%m-%d" time))
           (days-ago (/ (float-time (time-subtract now time)) 86400.0)))
      (cond
       ((string= msg-date today) "Today")
       ((string= msg-date yesterday) "Yesterday")
       ((< days-ago 7) (format-time-string "%A" time))
       (t (format-time-string whatsapp-date-format time))))))
(defun whatsapp--status-indicator (st fm)
  "Delivery indicator for own messages: ⏳ pending, ✓ sent, ✓✓ delivered, ✓✓(read)."
  (if (not fm) ""
    (pcase st
      ((or 0 1) (propertize "⏳" 'face 'whatsapp-msg-status-sent))
      (2 (propertize "✓" 'face 'whatsapp-msg-status-sent))
      (3 (propertize "✓✓" 'face 'whatsapp-msg-status-sent))
      ((or 4 5) (propertize "✓✓" 'face 'whatsapp-msg-status-read))
      (_ (propertize "✓" 'face 'whatsapp-msg-status-sent)))))
(defun whatsapp--format-phone (digits)
  "Pretty-print DIGITS as a phone number, e.g. \"+55 54 99324-2221\"."
  (if (or (null digits) (string-empty-p digits)) ""
    (let ((d (replace-regexp-in-string "[^0-9]" "" digits)))
      (cond ((string-empty-p d) "")
            ((< (length d) 7) (concat "+" d))
            (t (let* ((cc (if (> (length d) 11) (substring d 0 (- (length d) 10)) (substring d 0 2)))
                      (rest (substring d (length cc)))
                      (area (substring rest 0 (min 2 (length rest))))
                      (tail (substring rest (length area)))
                      (tail (if (> (length tail) 4) (concat (substring tail 0 (- (length tail) 4)) "-" (substring tail (- (length tail) 4))) tail)))
                 (string-trim (format "+%s %s %s" cc area tail))))))))
(defun whatsapp--contact-name (jid) (let ((c (alist-get jid whatsapp--contacts nil nil #'equal))) (when c (let ((n (plist-get c :name)) (p (plist-get c :pushName))) (cond ((and n (not (string-empty-p n))) n) ((and p (not (string-empty-p p))) p))))))
(defun whatsapp--chat-display-name (jid)
  "Best display name for JID. The bridge resolves most names + a :phone; this
formats a number fallback so the UI never shows a bare LID handle when avoidable."
  (let* ((c (alist-get jid whatsapp--chats nil nil #'equal))
         (cn (and c (plist-get c :name)))
         (ph (and c (plist-get c :phone))))
    (or (and cn (not (string-empty-p cn)) cn)
        (whatsapp--contact-name jid)
        (and ph (not (string-empty-p ph)) (whatsapp--format-phone ph))
        (if (string-match-p "@s\\.whatsapp\\.net$" (or jid ""))
            (whatsapp--format-phone (replace-regexp-in-string "@.*" "" (or jid "")))
          (replace-regexp-in-string "@.*" "" (or jid ""))))))
(defun whatsapp--is-group-jid (jid) (and jid (string-match-p "@g\\.us$" jid)))
(defun whatsapp--format-file-size (b) (cond ((or (null b) (<= b 0)) "") ((< b 1024) (format "%dB" b)) ((< b 1048576) (format "%.0fKB" (/ b 1024.0))) (t (format "%.1fMB" (/ b 1048576.0)))))
(defun whatsapp--format-duration (s) (if (or (null s) (<= s 0)) "" (format "%d:%02d" (/ s 60) (mod s 60))))
(defun whatsapp--mime-from-ext (p) (pcase (downcase (or (file-name-extension p) "")) ((or "jpg" "jpeg") "image/jpeg") ("png" "image/png") ("gif" "image/gif") ("webp" "image/webp") ("mp4" "video/mp4") ("mp3" "audio/mpeg") ((or "ogg" "opus") "audio/ogg") ("wav" "audio/wav") ("pdf" "application/pdf") (_ "application/octet-stream")))
(defun whatsapp--initials (name) (if (or (null name) (string-empty-p name)) "??" (let ((w (split-string (string-trim name) "[[:space:]]+" t))) (upcase (if (>= (length w) 2) (concat (substring (car w) 0 1) (substring (cadr w) 0 1)) (substring (car w) 0 (min 2 (length (car w)))))))))

;; --- Profile pictures ---

(defun whatsapp--avatar-finalize (jid path callback)
  "Create a cached image for JID from PATH (aspect ratio preserved), call CALLBACK."
  (condition-case nil
      (let ((img (create-image path nil nil :height (max 16 (frame-char-height)) :ascent 'center)))
        (puthash jid img whatsapp--pic-cache) (funcall callback img))
    (error (puthash jid 'none whatsapp--pic-cache) (funcall callback nil))))

(defun whatsapp--get-avatar (jid callback)
  "Get avatar for JID. Call CALLBACK with image object or nil.
Fully asynchronous — never blocks Emacs on the network download."
  (let ((cached (gethash jid whatsapp--pic-cache)))
    (cond
     ((eq cached 'none) (funcall callback nil))
     (cached (funcall callback cached))
     (t
      (let ((img-path (expand-file-name (format "avatar-%s.jpg" (md5 jid)) whatsapp-media-directory)))
        (if (file-exists-p img-path)
            (whatsapp--avatar-finalize jid img-path callback)
          (whatsapp--http-get (format "/contacts/%s/avatar" (url-hexify-string jid))
            (lambda (data)
              (let ((url (plist-get data :url)))
                (if (or (null url) (not (stringp url)))
                    (progn (puthash jid 'none whatsapp--pic-cache) (funcall callback nil))
                  (ignore-errors (make-directory whatsapp-media-directory t))
                  (url-retrieve url
                    (lambda (status)
                      (condition-case nil
                          (if (plist-get status :error)
                              (progn (puthash jid 'none whatsapp--pic-cache) (funcall callback nil))
                            (goto-char (point-min))
                            (if (re-search-forward "\r?\n\r?\n" nil t)
                                (progn
                                  (let ((coding-system-for-write 'binary))
                                    (write-region (point) (point-max) img-path nil 'silent))
                                  (kill-buffer)
                                  (whatsapp--avatar-finalize jid img-path callback))
                              (kill-buffer) (puthash jid 'none whatsapp--pic-cache) (funcall callback nil)))
                        (error (puthash jid 'none whatsapp--pic-cache) (funcall callback nil))))
                    nil t t)))))))))))

(defun whatsapp--avatar-string (jid name)
  "Return display string for JID: profile pic if available, else initials."
  (let ((cached (gethash jid whatsapp--pic-cache)))
    (cond
     ((and cached (not (eq cached 'none)) (display-graphic-p))
      (propertize "  " 'display cached))
     (t (propertize (whatsapp--initials name) 'face 'whatsapp-chat-initials)))))(defun whatsapp--convert-org-markup (t2) (if (not whatsapp-convert-org-markup) t2 (string-trim (replace-regexp-in-string "=\\([^=\n]+\\)=" "```\\1```" (replace-regexp-in-string "\\(?:^\\|[[:space:]]\\)/\\([^/\n]+\\)/\\(?:[[:space:]]\\|$\\)" " _\\1_ " t2)))))

;; --- Text rendering ---
(defun whatsapp--render-wa-text (text face)
  (if (not whatsapp-render-formatting) (propertize text 'face face)
    (let ((r text))
      (setq r (whatsapp--apply-fmt r "```" "```" 'whatsapp-msg-code))
      (setq r (whatsapp--apply-fmt r "*" "*" 'whatsapp-msg-bold))
      (setq r (whatsapp--apply-fmt r "_" "_" 'whatsapp-msg-italic))
      (setq r (whatsapp--apply-fmt r "~" "~" 'whatsapp-msg-strike))
      (dotimes (i (length r)) (unless (get-text-property i 'face r) (put-text-property i (1+ i) 'face face r)))
      (when whatsapp-clickable-urls (setq r (whatsapp--buttonize-urls r))) r)))

(defun whatsapp--apply-fmt (text open close face)
  (let ((r text) (re (concat (regexp-quote open) "\\([^" (substring close 0 1) "\n]+\\)" (regexp-quote close))))
    (while (string-match re r) (setq r (replace-match (propertize (match-string 1 r) 'face face) t t r))) r))

(defun whatsapp--buttonize-urls (text)
  (let ((pos 0)) (while (string-match "https?://[^[:space:]<>\"']*[^[:space:]<>\"'.,;:!?)\\]]" text pos)
    (let ((s (match-beginning 0)) (e (match-end 0)) (url (match-string 0 text)))
      (put-text-property s e 'face 'whatsapp-msg-url text) (put-text-property s e 'mouse-face 'highlight text)
      (put-text-property s e 'help-echo (concat "Open: " url) text)
      (put-text-property s e 'keymap (let ((m (make-sparse-keymap))) (define-key m [mouse-1] `(lambda () (interactive) (browse-url ,url))) (define-key m (kbd "RET") `(lambda () (interactive) (browse-url ,url))) m) text)
      (setq pos e))) text))

(defun whatsapp--sender-face (jid) (if (or (null whatsapp-sender-colors) (null jid)) 'whatsapp-msg-sender
  (let ((c (nth (mod (abs (sxhash jid)) (length whatsapp-sender-colors)) whatsapp-sender-colors))) `(:foreground ,c :weight bold))))

;; =========================================================================
;;  Mode-line + notifications
;; =========================================================================

(defun whatsapp--recompute-unread ()
  (setq whatsapp--unread-total (cl-reduce #'+ (mapcar (lambda (p) (or (plist-get (cdr p) :unreadCount) 0)) whatsapp--chats) :initial-value 0))
  (whatsapp--update-mode-line))
(defvar whatsapp--mode-line-string "")
(defun whatsapp--update-mode-line ()
  (setq whatsapp--mode-line-string (pcase whatsapp--connection-state
    ('open (if (> whatsapp--unread-total 0) (propertize (format " WA[%d]" whatsapp--unread-total) 'face 'whatsapp-chat-unread-badge) " WA"))
    ('qr " WA[QR]") ('connecting (propertize " WA[…]" 'face 'whatsapp-msg-timestamp)) (_ "")))
  (force-mode-line-update t))
(unless (memq 'whatsapp--mode-line-string global-mode-string) (push 'whatsapp--mode-line-string global-mode-string))

(defun whatsapp--notify-default (sender text _jid)
  (let ((ti (format "WhatsApp: %s" sender)) (bo (truncate-string-to-width (or text "") 80 nil nil "…")))
    (cond ((fboundp 'alert) (alert bo :title ti :category 'whatsapp))
          ((and (fboundp 'notifications-notify) (eq system-type 'gnu/linux)) (notifications-notify :title ti :body bo :urgency 'normal))
          ((eq system-type 'darwin) (ignore-errors (start-process "n" nil "osascript" "-e" (format "display notification \"%s\" with title \"%s\"" bo ti))))
          (t (message "%s: %s" ti bo)))))

(defun whatsapp--mark-read (jid ids) (whatsapp--http-post "/messages/read" `(:jid ,jid :msgIds ,(or ids [])) nil))

;; =========================================================================
;;  Contacts
;; =========================================================================

(defun whatsapp--contact-candidates ()
  "Every addressable chat + contact as (LABEL . JID).
Never filtered by name — so the recipient picker is always populated even when
names are still resolving. LABEL shows the phone number when it adds info."
  (let ((seen (make-hash-table :test #'equal)) c)
    (dolist (p whatsapp--chats)
      (let* ((j (car p)) (nm (whatsapp--chat-display-name j))
             (ph (plist-get (cdr p) :phone))
             ;; Append the number only when the name isn't itself a phone number.
             (label (if (and ph (not (string-empty-p ph)) (not (string-prefix-p "+" nm)))
                        (format "%s — %s" nm (whatsapp--format-phone ph)) nm)))
        (unless (gethash j seen) (puthash j t seen) (push (cons label j) c))))
    (dolist (p whatsapp--contacts)
      (let ((j (car p)))
        (unless (gethash j seen) (puthash j t seen) (push (cons (whatsapp--chat-display-name j) j) c))))
    (nreverse c)))

(defun whatsapp--read-jid (prompt)
  "Pick a chat/contact by name, or type a raw phone number."
  (let* ((cands (whatsapp--contact-candidates))
         (ch (completing-read prompt cands nil nil)))
    (or (cdr (assoc ch cands))
        (if (string-match-p "@" ch) ch
          (concat (replace-regexp-in-string "[^0-9]" "" ch) "@s.whatsapp.net")))))

;; =========================================================================
;;  Chat List
;; =========================================================================

(defvar whatsapp-chat-list-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'whatsapp-chat-list-open) (define-key m (kbd "o") #'whatsapp-chat-list-open)
    (define-key m [mouse-1] #'whatsapp-chat-list-mouse-open) (define-key m [double-mouse-1] #'whatsapp-chat-list-mouse-open)
    (define-key m (kbd "c") #'whatsapp-send-new) (define-key m (kbd "C") #'whatsapp-contacts-list) (define-key m (kbd "g") #'whatsapp-refresh)
    (define-key m (kbd "s") #'whatsapp-search-chats) (define-key m (kbd "S") #'whatsapp-search-messages) (define-key m (kbd "G") #'whatsapp-group-create)
    (define-key m (kbd "A") #'whatsapp-chat-archive-toggle) (define-key m (kbd "P") #'whatsapp-chat-pin-toggle)
    (define-key m (kbd "M") #'whatsapp-chat-mute-toggle) (define-key m (kbd "D") #'whatsapp-chat-delete-at-point)
    (define-key m (kbd "R") #'whatsapp-mark-all-read) (define-key m (kbd "TAB") #'whatsapp-toggle-archive)
    (define-key m (kbd "*") #'whatsapp-starred-messages) (define-key m (kbd "h") #'whatsapp-chat-actions) (define-key m (kbd "W") #'whatsapp-status-updates)
    (define-key m (kbd "1") #'whatsapp-filter-unread) (define-key m (kbd "2") #'whatsapp-filter-groups)
    (define-key m (kbd "3") #'whatsapp-filter-contacts) (define-key m (kbd "0") #'whatsapp-filter-clear)
    (define-key m (kbd "n") #'next-line) (define-key m (kbd "p") #'previous-line) (define-key m (kbd "q") #'bury-buffer) (define-key m (kbd "Q") #'whatsapp-disconnect)
    (define-key m (kbd "?") #'whatsapp-help) m))

(defun whatsapp--conn-indicator ()
  "A short, coloured connection-state pill for header-lines."
  (pcase whatsapp--connection-state
    ('open        (propertize "● online"     'face 'whatsapp-chat-presence-online))
    ('connecting  (propertize "… connecting" 'face 'whatsapp-msg-timestamp))
    ('qr          (propertize "▢ scan QR"    'face 'whatsapp-chat-unread-badge))
    (_            (propertize "○ offline"    'face 'whatsapp-chat-presence-offline))))

(defun whatsapp--chat-list-header ()
  "Telega-style status header for the chat list: state, account, unread, hints."
  (let* ((acct (or (whatsapp--contact-name whatsapp--my-jid)
                   (and whatsapp--my-jid (replace-regexp-in-string "@.*" "" whatsapp--my-jid))))
         (unread (if (> whatsapp--unread-total 0)
                     (concat "  " (propertize (format "%d unread" whatsapp--unread-total)
                                              'face 'whatsapp-chat-unread-badge))
                   ""))
         (left (concat " " (propertize "WhatsApp" 'face 'whatsapp-chat-name)
                       "  " (whatsapp--conn-indicator)
                       (if acct (concat "  " (propertize (concat "@" acct) 'face 'whatsapp-contact-phone)) "")
                       unread))
         (right (propertize "c new · s search · g refresh · ? help " 'face 'whatsapp-chat-preview))
         (pad (max 1 (- (window-width)
                        (string-width (substring-no-properties left))
                        (string-width (substring-no-properties right))))))
    (concat left (make-string pad ?\s) right)))

(define-derived-mode whatsapp-chat-list-mode tabulated-list-mode "WA-Chats"
  (setq tabulated-list-format [("" 4 nil) ("" 4 nil) ("" 5 t) ("Name" 22 t) ("Last Message" 38 nil) ("Time" 10 t)] tabulated-list-padding 1)
  (tabulated-list-init-header) (setq header-line-format '(:eval (whatsapp--chat-list-header)))
  (setq-local revert-buffer-function (lambda (&rest _) (whatsapp-refresh))))

(defun whatsapp--chat-list-buffer () (let ((b (get-buffer-create "*WhatsApp*"))) (with-current-buffer b (unless (derived-mode-p 'whatsapp-chat-list-mode) (whatsapp-chat-list-mode))) b))

(defvar whatsapp--chat-filter nil
  "When non-nil, a predicate (PAIR -> bool) limiting which chats are listed.
Persisted across live updates so a filter survives incoming WebSocket events.")

(defun whatsapp--conversational-jid-p (jid)
  "Non-nil if JID is a real chat (not status/broadcast/newsletter pseudo-chats)."
  (and jid (not (string-match-p "\\(status@broadcast\\|@newsletter\\|@broadcast\\)" jid))))

(defun whatsapp--visible-chats ()
  "Chats to show: conversational, archive honoured, filter applied."
  (let ((cs (cl-remove-if-not (lambda (p) (whatsapp--conversational-jid-p (car p))) whatsapp--chats)))
    (unless whatsapp-show-archive
      (setq cs (cl-remove-if (lambda (p) (eq (plist-get (cdr p) :archived) t)) cs)))
    (when whatsapp--chat-filter (setq cs (cl-remove-if-not whatsapp--chat-filter cs)))
    cs))

(defun whatsapp--refresh-chat-list-buffer ()
  (let ((buf (get-buffer "*WhatsApp*"))) (when (and buf (buffer-live-p buf)) (with-current-buffer buf
    (let ((inhibit-read-only t) (pos (point))
          (chats (whatsapp--visible-chats)))
      (setq tabulated-list-entries (mapcar #'whatsapp--chat-to-entry
        (sort (copy-sequence chats)
              (lambda (a b) (let ((ap (eq (plist-get (cdr a) :pinned) t)) (bp (eq (plist-get (cdr b) :pinned) t)))
                (cond ((and ap (not bp)) t) ((and bp (not ap)) nil) (t (> (or (plist-get (cdr a) :timestamp) 0) (or (plist-get (cdr b) :timestamp) 0)))))))))
      (tabulated-list-print t) (goto-char (min pos (point-max)))
      ;; Empty-state guidance so a fresh/syncing account never looks broken.
      (when (null tabulated-list-entries)
        (goto-char (point-max))
        (insert (propertize
                 (pcase whatsapp--connection-state
                   ('open "\n  No chats yet — syncing with WhatsApp…\n  Press c to start a new chat, g to refresh.\n")
                   ('connecting "\n  Connecting to the bridge…\n")
                   ('qr "\n  Scan the QR code: M-x whatsapp-show-qr\n")
                   (_ "\n  Not connected. M-x whatsapp-connect to begin.\n"))
                 'face 'whatsapp-chat-preview)))
      (when (and whatsapp-show-profile-pics (display-graphic-p))
        (whatsapp--preload-avatars (mapcar #'car (seq-take chats 25)))))))))

(defvar whatsapp--list-refresh-timer nil)
(defun whatsapp--refresh-list-debounced ()
  "Coalesce many list refreshes (e.g. one per avatar download) into one repaint."
  (when (timerp whatsapp--list-refresh-timer) (cancel-timer whatsapp--list-refresh-timer))
  (setq whatsapp--list-refresh-timer
        (run-with-idle-timer 0.4 nil (lambda () (setq whatsapp--list-refresh-timer nil) (whatsapp--refresh-chat-list-buffer)))))

(defun whatsapp--preload-avatars (jids)
  "Start async avatar downloads for JIDS that aren't cached."
  (dolist (jid jids)
    (unless (gethash jid whatsapp--pic-cache)
      (whatsapp--get-avatar jid (lambda (_img) (whatsapp--refresh-list-debounced))))))
(defun whatsapp--chat-to-entry (pair)
  (let* ((jid (car pair)) (ch (cdr pair))
         (name (whatsapp--chat-display-name jid))
         (ur (or (plist-get ch :unreadCount) 0)) (ig (or (eq (plist-get ch :isGroup) t) (whatsapp--is-group-jid jid)))
         (pn (eq (plist-get ch :pinned) t)) (mt (eq (plist-get ch :muted) t)) (ar (eq (plist-get ch :archived) t))
         (lm (plist-get ch :lastMessage))
         (lmtext (replace-regexp-in-string "[\n\r]+" " " (or (and lm (plist-get lm :text)) "")))
         ;; Prefix outgoing previews with a check so you can see what you last sent.
         (pv (cond ((null lm) "")
                   ((eq (plist-get lm :fromMe) t) (concat (propertize "✓ " 'face 'whatsapp-msg-status-sent) lmtext))
                   (t lmtext)))
         (pv (truncate-string-to-width pv 38 nil nil "…"))
         (ts (if lm (whatsapp--format-timestamp (plist-get lm :timestamp)) ""))
         (pr (alist-get jid whatsapp--presence nil nil #'equal))
         (ps (if (and pr (not ig)) (if (member (plist-get pr :lastKnown) '("available" "composing")) (propertize "●" 'face 'whatsapp-chat-presence-online) (propertize "○" 'face 'whatsapp-chat-presence-offline)) " "))
         (ini (whatsapp--avatar-string jid name))
         (ind (concat (cond (pn (propertize "📌" 'face 'whatsapp-chat-pinned)) (ar "📦") (t " "))
                      (if ig (propertize "👥" 'face 'whatsapp-chat-group-indicator) " ")
                      (if mt "🔕" " ")))
         (ub (if (> ur 0) (propertize (format "%d" ur) 'face 'whatsapp-chat-unread-badge) ""))
         (nf (cond (mt 'whatsapp-chat-muted) ((> ur 0) 'whatsapp-chat-unread) (t 'whatsapp-chat-name))))
    (list jid (vector (concat ps " " ini) ind ub
                      (propertize (truncate-string-to-width name 22 nil nil "…") 'face nf 'mouse-face 'highlight 'help-echo "mouse-1: open chat")
                      (propertize pv 'face (if (> ur 0) 'whatsapp-chat-unread 'whatsapp-chat-preview))
                      (propertize ts 'face 'whatsapp-chat-timestamp)))))

;; =========================================================================
;;  Contacts list
;; =========================================================================

(defvar whatsapp-contacts-mode-map (let ((m (make-sparse-keymap))) (define-key m (kbd "RET") #'whatsapp-contacts-open-chat)
  (define-key m (kbd "s") #'whatsapp-contacts-search) (define-key m (kbd "g") #'whatsapp-contacts-list) (define-key m (kbd "q") #'kill-this-buffer) m))

(define-derived-mode whatsapp-contacts-mode tabulated-list-mode "WA-Contacts"
  (setq tabulated-list-format [("Name" 30 t) ("Phone" 20 t) ("Push Name" 20 t)] tabulated-list-padding 1)
  (tabulated-list-init-header) (setq header-line-format (propertize " 👥 Contacts" 'face 'whatsapp-chat-name)))

(defun whatsapp-contacts-list () (interactive) (whatsapp--http-get "/contacts" (lambda (cs)
  (dolist (c cs) (setf (alist-get (plist-get c :jid) whatsapp--contacts nil nil #'equal) c))
  (let ((buf (get-buffer-create "*WhatsApp: Contacts*")))
    (with-current-buffer buf (whatsapp-contacts-mode) (whatsapp--contacts-render cs) (goto-char (point-min))) (pop-to-buffer-same-window buf)))))

(defun whatsapp--contacts-render (cs) (let ((inhibit-read-only t))
  (setq tabulated-list-entries
        (cl-remove-if #'null (mapcar (lambda (c)
          (let* ((j (plist-get c :jid))
                 (n (whatsapp--chat-display-name j))
                 (ph (or (plist-get c :phone) ""))
                 (pn (or (plist-get c :pushName) "")))
            ;; Skip self and non-conversational JIDs, but keep @lid contacts.
            (unless (or (null j) (equal j whatsapp--my-jid) (string-match-p "@\\(g\\.us\\|broadcast\\|newsletter\\)" j))
              (list j (vector (propertize n 'face 'whatsapp-chat-name)
                              (propertize (if (string-empty-p ph) "" (whatsapp--format-phone ph)) 'face 'whatsapp-contact-phone)
                              (propertize pn 'face 'whatsapp-chat-preview))))))
          cs)))
  (tabulated-list-print t)))

(defun whatsapp-contacts-open-chat () (interactive) (let ((j (tabulated-list-get-id))) (when j (whatsapp--open-chat j))))
(defun whatsapp-contacts-search () (interactive) (let ((p (downcase (read-string "Search: ")))) (if (string-empty-p p) (whatsapp-contacts-list)
  (whatsapp--contacts-render (mapcar #'cdr (cl-remove-if-not (lambda (x) (string-match-p p (downcase (or (plist-get (cdr x) :name) "")))) whatsapp--contacts))))))

;; =========================================================================
;;  Chat buffer with inline compose
;; =========================================================================

(defvar whatsapp-chat-mode-map
  (let ((m (make-sparse-keymap)))
    ;; --- Composing: the buffer behaves like a chat input. Type anywhere to
    ;; compose; RET sends; C-j / S-RET insert a newline. ---
    (define-key m [remap self-insert-command] #'whatsapp-chat-self-insert)
    (define-key m (kbd "RET") #'whatsapp-chat-send-or-newline)
    (define-key m (kbd "<return>") #'whatsapp-chat-send-or-newline)
    (define-key m (kbd "C-j") #'whatsapp-chat-newline)
    (define-key m (kbd "S-<return>") #'whatsapp-chat-newline)
    (define-key m (kbd "C-<return>") #'whatsapp-chat-newline)
    ;; --- Message actions live under C-c so letters stay typeable. ---
    (define-key m (kbd "C-c r") #'whatsapp-chat-reply)     (define-key m (kbd "C-c e") #'whatsapp-chat-react)
    (define-key m (kbd "C-c E") #'whatsapp-chat-edit)      (define-key m (kbd "C-c d") #'whatsapp-chat-delete)
    (define-key m (kbd "C-c f") #'whatsapp-chat-forward)   (define-key m (kbd "C-c w") #'whatsapp-chat-copy-text)
    (define-key m (kbd "C-c *") #'whatsapp-chat-star-toggle) (define-key m (kbd "C-c i") #'whatsapp-chat-info)
    ;; --- Attachments / media ---
    (define-key m (kbd "C-c a") #'whatsapp-chat-attach)    (define-key m (kbd "C-c v") #'whatsapp-chat-voice)
    (define-key m (kbd "C-c m") #'whatsapp-chat-play-media) (define-key m (kbd "C-c M") #'whatsapp-chat-download-media)
    (define-key m (kbd "C-c l") #'whatsapp-chat-send-location) (define-key m (kbd "C-c C-p") #'whatsapp-chat-send-poll)
    (define-key m (kbd "C-c C-v") #'whatsapp-chat-send-contact)
    ;; --- Navigation / history ---
    (define-key m (kbd "M-p") #'whatsapp-chat-prev-message) (define-key m (kbd "M-n") #'whatsapp-chat-next-message)
    (define-key m (kbd "C-c C-n") #'whatsapp-chat-next-unread) (define-key m (kbd "C-c g") #'whatsapp-chat-scroll-bottom)
    (define-key m (kbd "C-c <") #'whatsapp-chat-load-older) (define-key m (kbd "C-c C-h") #'whatsapp-chat-load-older)
    ;; --- Misc ---
    (define-key m (kbd "C-c s") #'whatsapp-chat-search-in-chat) (define-key m (kbd "C-c I") #'whatsapp-chat-stats)
    (define-key m (kbd "C-c x") #'whatsapp-chat-export) (define-key m (kbd "C-c h") #'whatsapp-chat-actions)
    (define-key m (kbd "C-c C-e") #'whatsapp-chat-compose-multiline) (define-key m (kbd "C-c C-k") #'whatsapp-chat-cancel-reply)
    (define-key m (kbd "C-c C-r") #'whatsapp-chat-quick-reply) (define-key m (kbd "C-c C-y") #'whatsapp-yank-last-message)
    (define-key m (kbd "<tab>") #'whatsapp-chat-focus-compose) (define-key m (kbd "C-c q") #'whatsapp-chat-quit)
    m))

(defun whatsapp-chat-newline ()
  "Insert a newline in the compose area (jumping there first if needed)."
  (interactive)
  (when (and whatsapp--compose-marker (not (whatsapp--in-compose-p))) (goto-char (point-max)))
  (insert "\n"))

(defun whatsapp-chat-self-insert (n &optional c)
  "Insert into the compose area, jumping there first if point is elsewhere."
  (interactive "p")
  (when (and whatsapp--compose-marker (not (whatsapp--in-compose-p)))
    (goto-char (point-max)))
  (self-insert-command n c))

(define-derived-mode whatsapp-chat-mode nil "WA-Chat"
  (setq-local whatsapp--chat-messages (make-hash-table :test #'equal))
  (setq-local whatsapp--chat-typing nil whatsapp--last-typing-sent 0 whatsapp--new-msg-count 0 whatsapp--at-bottom t whatsapp--reply-to-id nil)
  (setq-local word-wrap t truncate-lines nil)
  (setq-local imenu-create-index-function #'whatsapp--imenu-index)
  (setq-local bookmark-make-record-function #'whatsapp--bookmark-make)
  (add-hook 'post-command-hook #'whatsapp--track-scroll nil t)
  (add-hook 'post-self-insert-hook #'whatsapp--compose-typing-hook nil t)
  (whatsapp--setup-context-menu)
  (visual-line-mode 1))

(defun whatsapp--compose-typing-hook ()
  "Send typing indicator when typing in compose area."
  (when (and whatsapp--compose-marker (>= (point) (marker-position whatsapp--compose-marker)))
    (whatsapp--send-typing-composing)))

(defun whatsapp--track-scroll ()
  (when (and whatsapp--compose-marker (derived-mode-p 'whatsapp-chat-mode))
    (let ((was whatsapp--at-bottom))
      (setq whatsapp--at-bottom (>= (window-end nil t) (marker-position whatsapp--compose-marker)))
      (when (and whatsapp--at-bottom (not was) (> whatsapp--new-msg-count 0))
        (setq whatsapp--new-msg-count 0) (whatsapp--update-chat-header)))))

(defun whatsapp--chat-buffer-name (jid) (format "*WhatsApp: %s*" (whatsapp--chat-display-name jid)))
(defun whatsapp--get-chat-buffer (jid) (cl-find-if (lambda (b) (with-current-buffer b (and (derived-mode-p 'whatsapp-chat-mode) (equal whatsapp--chat-jid jid)))) (buffer-list)))
(defun whatsapp--chat-buffer-visible-p (jid) (let ((b (whatsapp--get-chat-buffer jid))) (and b (get-buffer-window b t))))

;; --- Compose area ---

(defun whatsapp--setup-compose ()
  (goto-char (point-max))
  (let ((inhibit-read-only t))
    (insert (propertize "\n" 'whatsapp-sep t))
    (insert (propertize "─── type a message · RET send · C-j newline · C-c h actions ───\n" 'face 'whatsapp-compose-separator 'read-only t 'front-sticky t 'rear-nonsticky t))
    (setq whatsapp--compose-marker (point-marker)) (set-marker-insertion-type whatsapp--compose-marker nil)
    (insert (propertize "→ " 'face 'whatsapp-compose-prompt 'read-only t 'rear-nonsticky t))
    ;; Restore draft
    (let ((draft (gethash whatsapp--chat-jid whatsapp--drafts)))
      (when (and draft (not (string-empty-p draft))) (insert draft)))
    (put-text-property (point-min) whatsapp--compose-marker 'read-only t)))

(defun whatsapp--compose-text ()
  (when whatsapp--compose-marker
    (string-trim (buffer-substring-no-properties (save-excursion (goto-char whatsapp--compose-marker) (forward-char 2) (point)) (point-max)))))

(defun whatsapp--clear-compose ()
  (when whatsapp--compose-marker
    (let ((inhibit-read-only t)) (save-excursion (goto-char whatsapp--compose-marker) (forward-char 2) (delete-region (point) (point-max))))))

(defun whatsapp--save-draft ()
  "Save compose text as draft for current chat."
  (when (and whatsapp--chat-jid whatsapp--compose-marker)
    (let ((text (whatsapp--compose-text)))
      (if (string-empty-p text) (remhash whatsapp--chat-jid whatsapp--drafts)
        (puthash whatsapp--chat-jid text whatsapp--drafts)))))

;; --- Ewoc printer ---

(defun whatsapp--inline-image-finalize (jid mid path)
  "Cache a scaled image for MID from PATH and repaint its node in JID's buffer.
Animated images (GIF, animated WebP stickers) are looped when supported."
  (condition-case nil
      (let ((img (create-image path nil nil :max-width whatsapp-inline-image-max-width :ascent 'center)))
        (puthash mid img whatsapp--image-cache)
        (let ((buf (whatsapp--get-chat-buffer jid)))
          (when (and buf (buffer-live-p buf))
            (with-current-buffer buf
              (let ((node (and whatsapp--chat-messages (gethash mid whatsapp--chat-messages))))
                (when node (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc node)))))))
        ;; Loop animated images/stickers if the build + file support it.
        (when (and whatsapp-animate-gifs (fboundp 'image-multi-frame-p) (image-multi-frame-p img))
          (image-animate img 0 t)))
    (error (puthash mid 'none whatsapp--image-cache))))

(defun whatsapp--load-inline-image (jid msg)
  "Asynchronously fetch MSG's image and display it inline in JID's chat buffer."
  (let ((mid (whatsapp-message-id msg)))
    (when (null (gethash mid whatsapp--image-cache))   ; trigger once
      (puthash mid 'loading whatsapp--image-cache)
      (let ((out (expand-file-name (format "img-%s" (md5 mid)) whatsapp-media-directory)))
        (if (file-exists-p out)
            (whatsapp--inline-image-finalize jid mid out)
          (ignore-errors (make-directory whatsapp-media-directory t))
          (whatsapp--http-get-binary (format "/messages/media/%s" (url-hexify-string mid)) out
            (lambda (ok) (if ok (whatsapp--inline-image-finalize jid mid out)
                           (puthash mid 'none whatsapp--image-cache)))))))))

(defvar whatsapp-media-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'whatsapp-chat-play-media-at-mouse)
    (define-key m (kbd "RET") #'whatsapp-chat-play-media)
    m)
  "Keymap on media links in the chat buffer: click or RET to play/open.")

(defun whatsapp-chat-play-media-at-mouse (event)
  "Play the media on the clicked line."
  (interactive "e") (mouse-set-point event) (whatsapp-chat-play-media))

(defun whatsapp--media-label (s)
  "Return S as a clickable media link (mouse-1 / RET plays or opens it)."
  (propertize s 'face 'whatsapp-msg-media-link 'mouse-face 'highlight
              'keymap whatsapp-media-keymap 'help-echo "mouse-1 / RET: play / open"))

(defun whatsapp--printer-image (msg label)
  "Insert an inline image for MSG, or LABEL + size when it can't be shown yet."
  (let* ((mid (whatsapp-message-id msg)) (cached (gethash mid whatsapp--image-cache))
         (inline (and whatsapp-inline-images (display-graphic-p))))
    (cond
     ((and inline cached (not (memq cached '(loading none))))
      (insert (propertize "🖼" 'display cached 'mouse-face 'highlight 'keymap whatsapp-media-keymap 'help-echo "mouse-1 / RET: open") "\n"))
     (t
      (insert (whatsapp--media-label (string-trim (format "%s %s" label (whatsapp--format-file-size (whatsapp-message-file-length msg)))))
              (if (and inline (eq cached 'loading)) (propertize " …" 'face 'whatsapp-msg-meta) "")
              "\n")
      (when (and inline (null cached)) (whatsapp--load-inline-image (whatsapp-message-jid msg) msg))))))

(defun whatsapp--center-rule (label face)
  "A full-width horizontal rule with centered LABEL, multibyte-width aware."
  (let* ((w (max 24 (- (window-width) 2)))
         (lw (string-width label))
         (lpad (max 0 (/ (- w lw) 2)))
         (rpad (max 0 (- w lpad lw))))
    (propertize (concat (make-string lpad ?─) label (make-string rpad ?─)) 'face face)))

(defun whatsapp--msg-printer (msg)
  (let ((mt (whatsapp-message-type msg)))
    (cond
     ((eq mt 'date-header)
      (insert (whatsapp--center-rule (concat "  " (whatsapp-message-text msg) "  ") 'whatsapp-msg-date-header)))
     ((eq mt 'unread-separator)
      (insert (whatsapp--center-rule "  ▼ unread messages ▼  " 'whatsapp-unread-separator)))
     ((eq mt 'notice)
      (insert (propertize (whatsapp-message-text msg) 'face 'whatsapp-chat-preview)))
     (t
      (let* ((fm (whatsapp-message-from-me msg)) (del (whatsapp-message-deleted msg)) (ed (whatsapp-message-edited msg))
             (st (whatsapp-message-starred msg)) (ts (whatsapp--format-timestamp (whatsapp-message-timestamp msg)))
             (tf (whatsapp--format-timestamp-full (whatsapp-message-timestamp msg)))
             (si (whatsapp--status-indicator (whatsapp-message-status msg) fm))
             (ig (whatsapp--is-group-jid (whatsapp-message-jid msg))) (sn (whatsapp-message-sender-name msg))
             (rx (whatsapp-message-reactions msg)) (lp (whatsapp-message-link-preview msg))
             (gface (if fm 'whatsapp-msg-gutter-self (whatsapp--sender-face (whatsapp-message-sender msg))))
             (start (point)))
        ;; Header: "You" / sender name, plus a star marker if starred.
        (let ((who (cond (fm (propertize "You" 'face 'whatsapp-msg-self-name))
                         ((and ig (not (string-empty-p sn))) (propertize sn 'face (whatsapp--sender-face (whatsapp-message-sender msg))))
                         (t nil))))
          (when (or who st)
            (insert (or who "") (if st (propertize "  ⭐" 'face 'whatsapp-msg-starred) "") "\n")))
        ;; Quoted reply
        (when (whatsapp-message-quoted-text msg)
          (let ((qs (or (whatsapp--contact-name (or (whatsapp-message-quoted-sender msg) "")) "")))
            (insert (propertize (concat "│ " (if (string-empty-p qs) "" (concat qs ": "))
                                        (truncate-string-to-width (or (whatsapp-message-quoted-text msg) "") 55 nil nil "…"))
                                'face 'whatsapp-msg-quote)
                    "\n")))
        ;; Body
        (cond (del (insert (propertize "🚫 This message was deleted" 'face 'whatsapp-msg-deleted)))
              (t (let ((text (whatsapp-message-text msg)) (face (if fm 'whatsapp-msg-self 'whatsapp-msg-other)))
                   (pcase mt
                     ("image" (whatsapp--printer-image msg "📷 Image"))
                     ("gif" (insert (whatsapp--media-label (format "🎞️ GIF %s ▶" (whatsapp--format-file-size (whatsapp-message-file-length msg)))) "\n"))
                     ("video" (insert (whatsapp--media-label (format "🎬 Video %s %s ▶" (whatsapp--format-duration (whatsapp-message-seconds msg)) (whatsapp--format-file-size (whatsapp-message-file-length msg)))) "\n"))
                     ("audio" (insert (whatsapp--media-label (format "%s Voice %s ▶" (if (whatsapp-message-ptt msg) "🎤" "🎵") (whatsapp--format-duration (whatsapp-message-seconds msg)))) "\n"))
                     ("document" (insert (propertize (format "📄 %s %s" (or (whatsapp-message-file-name msg) "Document") (whatsapp--format-file-size (whatsapp-message-file-length msg))) 'face 'whatsapp-msg-media-link) "\n"))
                     ("sticker" (whatsapp--printer-image msg "🏷️ Sticker"))
                     ("location" (insert (propertize "📍 " 'face 'whatsapp-msg-media-link)))
                     ("contact" (insert (propertize "👤 " 'face 'whatsapp-msg-media-link)))
                     ("poll" (insert (propertize "📊 " 'face 'whatsapp-msg-media-link))) (_ nil))
                   (unless (string-empty-p (or text "")) (insert (whatsapp--render-wa-text text face))))))
        ;; Link preview
        (when (and whatsapp-show-link-previews lp)
          (let ((title (plist-get lp :title)) (desc (plist-get lp :description)))
            (when (and title (not (string-empty-p title)))
              (insert "\n" (propertize (concat "🔗 " title) 'face 'whatsapp-msg-link-preview))
              (when (and desc (not (string-empty-p desc)))
                (insert "\n" (propertize (truncate-string-to-width desc 60 nil nil "…") 'face 'whatsapp-msg-link-preview))))))
        ;; Edited + timestamp + delivery status (subtle trailing metadata)
        (insert (propertize (concat "  " (if ed "·edited " "") ts (if (string-empty-p si) "" (concat " " si)))
                            'face 'whatsapp-msg-meta 'help-echo tf))
        ;; Reactions on their own line
        (when rx
          (insert "\n")
          (dolist (r rx) (insert (propertize (format " %s %d " (car r) (cdr r)) 'face 'whatsapp-msg-reaction) " ")))
        ;; Colored gutter bar down the left of the whole message (groups + distinguishes own/other).
        (add-text-properties start (point)
                             (list 'line-prefix (propertize "▎ " 'face gface)
                                   'wrap-prefix (propertize "▎   " 'face gface))))))))

;; --- Buffer ops ---

(defun whatsapp--open-chat (jid)
  (let* ((ex (whatsapp--get-chat-buffer jid)) (buf (or ex (generate-new-buffer (whatsapp--chat-buffer-name jid)))))
    (unless ex (with-current-buffer buf
      (whatsapp-chat-mode) (setq whatsapp--chat-jid jid)
      (let ((inhibit-read-only t)) (erase-buffer) (setq whatsapp--chat-ewoc (ewoc-create #'whatsapp--msg-printer nil nil t)))
      (whatsapp--update-chat-header)
      (unless (whatsapp--is-group-jid jid) (whatsapp--http-post "/presence/subscribe" `(:jid ,jid) nil))
      (whatsapp--load-chat-history jid)))
    (pop-to-buffer-same-window buf)
    ;; Land the cursor in the compose field so the user can type right away.
    (when (buffer-local-value 'whatsapp--compose-marker buf) (goto-char (point-max)))
    (when whatsapp-auto-read (whatsapp--mark-read jid nil)) buf))

(defun whatsapp--load-chat-history (jid)
  "Fetch and render JID's message history, then set up the compose area."
  (whatsapp--http-get (format "/messages/history/%s?limit=%d" (url-hexify-string jid) whatsapp-history-fetch-count) (lambda (msgs)
    (let ((buf (whatsapp--get-chat-buffer jid))) (when (and buf (buffer-live-p buf)) (with-current-buffer buf
      (let ((inhibit-read-only t) (ld nil) (cd (alist-get jid whatsapp--chats nil nil #'equal)) (uc 0) (us nil) (mc (length msgs)))
        (when cd (setq uc (or (plist-get (cdr cd) :unreadCount) 0)))
        (when msgs (setq whatsapp--oldest-msg-id (whatsapp-message-id (whatsapp--plist-to-message (car msgs)))))
        (dolist (pl msgs) (let* ((m (whatsapp--plist-to-message pl)) (d (whatsapp--format-date (whatsapp-message-timestamp m))))
          (unless (equal ld d) (setq ld d) (ewoc-enter-last whatsapp--chat-ewoc (whatsapp-message-create :id (format "d-%s" d) :text d :type 'date-header :timestamp 0)))
          (when (and (> uc 0) (not us) (>= (cl-decf mc) 0) (= mc (1- uc))) (setq us t)
            (ewoc-enter-last whatsapp--chat-ewoc (whatsapp-message-create :id "usep" :text "" :type 'unread-separator :timestamp 0)))
          (puthash (whatsapp-message-id m) (ewoc-enter-last whatsapp--chat-ewoc m) whatsapp--chat-messages)))
        ;; Friendly placeholder when there's no synced history yet.
        (when (null msgs)
          (ewoc-enter-last whatsapp--chat-ewoc
            (whatsapp-message-create :id "notice" :type 'notice :timestamp 0
              :text "No earlier messages synced yet.\nNew messages appear here as you chat. Press C-c C-h to try fetching older history from WhatsApp.\nType below and press RET to send.")))
        ;; Setup compose area after history is rendered
        (unless whatsapp--compose-marker (whatsapp--setup-compose))
        (when whatsapp--compose-marker (let ((w (get-buffer-window buf))) (when w (with-selected-window w (goto-char (point-max)) (recenter -1)))))
        ;; If we have little/no history, ask the bridge to pull it from WhatsApp.
        ;; Result arrives via the "history.set" event, which reloads this buffer.
        (when (and (< (length msgs) 8) (not whatsapp--history-requested))
          (setq whatsapp--history-requested t)
          (whatsapp--http-post (format "/messages/history/%s/fetch" (url-hexify-string jid)) '(:count 50) nil)))))))))

(defun whatsapp--reload-chat-history (jid)
  "Regenerate JID's chat buffer from scratch (preserving any compose draft)."
  (let ((buf (whatsapp--get-chat-buffer jid)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (whatsapp--save-draft)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (setq whatsapp--chat-ewoc (ewoc-create #'whatsapp--msg-printer nil nil t)
                whatsapp--compose-marker nil)
          (clrhash whatsapp--chat-messages))
        (whatsapp--load-chat-history jid)))))

(defun whatsapp--fetch-older-from-whatsapp (jid)
  "Ask the bridge to pull older messages from WhatsApp for JID."
  (whatsapp--http-post (format "/messages/history/%s/fetch" (url-hexify-string jid)) '(:count 50)
    (lambda (r) (if (and r (plist-get r :ok))
                    (if (plist-get (plist-get r :data) :requested) (message "Fetching older messages from WhatsApp…") (message "No earlier messages"))
                  (message "✗ %s" (or (and r (plist-get r :error)) "could not load older"))))))

(defun whatsapp--chat-buffer-add-message (jid msg)
  (let ((buf (whatsapp--get-chat-buffer jid))) (when (and buf (buffer-live-p buf)) (with-current-buffer buf
    (let ((inhibit-read-only t))
      ;; Drop the "no history yet" placeholder once a real message lands.
      (let ((first (ewoc-nth whatsapp--chat-ewoc 0)))
        (when (and first (eq (whatsapp-message-type (ewoc-data first)) 'notice))
          (ewoc-delete whatsapp--chat-ewoc first)))
      (let* ((ln (ewoc-nth whatsapp--chat-ewoc -1)) (lm (and ln (ewoc-data ln)))
             (d (whatsapp--format-date (whatsapp-message-timestamp msg)))
             (ld (and lm (not (memq (whatsapp-message-type lm) '(date-header unread-separator notice))) (whatsapp--format-date (whatsapp-message-timestamp lm)))))
        (when (and d (not (equal ld d))) (ewoc-enter-last whatsapp--chat-ewoc (whatsapp-message-create :id (format "d-%s" d) :text d :type 'date-header :timestamp 0))))
      (unless (gethash (whatsapp-message-id msg) whatsapp--chat-messages)
        (puthash (whatsapp-message-id msg) (ewoc-enter-last whatsapp--chat-ewoc msg) whatsapp--chat-messages))
      (if whatsapp--at-bottom (let ((w (get-buffer-window buf))) (when w (with-selected-window w (goto-char (point-max)) (recenter -1))))
        (cl-incf whatsapp--new-msg-count) (whatsapp--update-chat-header)))))))

(defun whatsapp--chat-buffer-update-status (jid mid st) (let ((buf (whatsapp--get-chat-buffer jid))) (when buf (with-current-buffer buf
  (let ((n (gethash mid whatsapp--chat-messages))) (when n (setf (whatsapp-message-status (ewoc-data n)) st) (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc n))))))))
(defun whatsapp--chat-buffer-mark-deleted (jid mid) (let ((buf (whatsapp--get-chat-buffer jid))) (when buf (with-current-buffer buf
  (let ((n (gethash mid whatsapp--chat-messages))) (when n (let ((m (ewoc-data n))) (setf (whatsapp-message-deleted m) t (whatsapp-message-text m) "") (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc n)))))))))
(defun whatsapp--chat-buffer-update-message (jid msg) (let ((buf (whatsapp--get-chat-buffer jid))) (when buf (with-current-buffer buf
  (let ((n (gethash (whatsapp-message-id msg) whatsapp--chat-messages))) (when n (ewoc-set-data n msg) (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc n))))))))
(defun whatsapp--chat-buffer-update-reactions (jid mid rx) (let ((buf (whatsapp--get-chat-buffer jid))) (when buf (with-current-buffer buf
  (let ((n (gethash mid whatsapp--chat-messages))) (when n (setf (whatsapp-message-reactions (ewoc-data n)) rx) (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc n))))))))

(defun whatsapp--message-at-point ()
  (when (and whatsapp--chat-ewoc whatsapp--compose-marker (< (point) (marker-position whatsapp--compose-marker)))
    (let ((n (ewoc-locate whatsapp--chat-ewoc (point)))) (when n (let ((m (ewoc-data n))) (unless (memq (whatsapp-message-type m) '(date-header unread-separator)) m))))))

;; --- imenu + bookmark ---
(defun whatsapp--imenu-index () (when whatsapp--chat-ewoc (let (idx (n (ewoc-nth whatsapp--chat-ewoc 0)))
  (while n (when (eq (whatsapp-message-type (ewoc-data n)) 'date-header) (push (cons (whatsapp-message-text (ewoc-data n)) (ewoc-location n)) idx)) (setq n (ewoc-next whatsapp--chat-ewoc n))) (nreverse idx))))
(defun whatsapp--bookmark-make () `(,(format "WA: %s" (whatsapp--chat-display-name whatsapp--chat-jid)) (handler . whatsapp--bookmark-handler) (jid . ,whatsapp--chat-jid)))
(defun whatsapp--bookmark-handler (bm) (whatsapp--open-chat (cdr (assq 'jid bm))))

;; --- Actions menu ---
(defun whatsapp-chat-actions () (interactive)
  (if (derived-mode-p 'whatsapp-chat-mode)
    (pcase (read-char-choice "[r]eply [e]moji [E]dit [d]el [f]wd [a]ttach [v]oice [m]edia [L]oc [P]oll [V]card [w]copy [*]star [i]nfo [/]search [I]stats [x]export [G]o-end: "
             '(?r ?e ?E ?d ?f ?a ?v ?m ?L ?P ?V ?w ?* ?i ?/ ?I ?x ?G))
      (?r (call-interactively #'whatsapp-chat-reply)) (?e (call-interactively #'whatsapp-chat-react)) (?E (call-interactively #'whatsapp-chat-edit))
      (?d (call-interactively #'whatsapp-chat-delete)) (?f (call-interactively #'whatsapp-chat-forward)) (?a (call-interactively #'whatsapp-chat-attach))
      (?v (call-interactively #'whatsapp-chat-voice)) (?m (call-interactively #'whatsapp-chat-play-media)) (?L (call-interactively #'whatsapp-chat-send-location))
      (?P (call-interactively #'whatsapp-chat-send-poll)) (?V (call-interactively #'whatsapp-chat-send-contact)) (?w (call-interactively #'whatsapp-chat-copy-text))
      (?* (call-interactively #'whatsapp-chat-star-toggle)) (?i (call-interactively #'whatsapp-chat-info)) (?/ (call-interactively #'whatsapp-chat-search-in-chat))
      (?I (call-interactively #'whatsapp-chat-stats)) (?x (call-interactively #'whatsapp-chat-export))
      (?G (call-interactively #'whatsapp-chat-scroll-bottom)))
    (pcase (read-char-choice "[o]pen [c]new [C]ontacts [G]roup [A]rchive [P]in [M]ute [D]el [R]ead-all [S]earch [*]starred [W]status [1]unread [2]groups [3]contacts [0]clear: "
             '(?o ?c ?C ?G ?A ?P ?M ?D ?R ?S ?* ?W ?1 ?2 ?3 ?0))
      (?o (call-interactively #'whatsapp-chat-list-open)) (?c (call-interactively #'whatsapp-send-new)) (?C (call-interactively #'whatsapp-contacts-list))
      (?G (call-interactively #'whatsapp-group-create)) (?A (call-interactively #'whatsapp-chat-archive-toggle)) (?P (call-interactively #'whatsapp-chat-pin-toggle))
      (?M (call-interactively #'whatsapp-chat-mute-toggle)) (?D (call-interactively #'whatsapp-chat-delete-at-point)) (?R (call-interactively #'whatsapp-mark-all-read))
      (?S (call-interactively #'whatsapp-search-messages)) (?* (call-interactively #'whatsapp-starred-messages)) (?W (call-interactively #'whatsapp-status-updates))
      (?1 (call-interactively #'whatsapp-filter-unread)) (?2 (call-interactively #'whatsapp-filter-groups))
      (?3 (call-interactively #'whatsapp-filter-contacts)) (?0 (call-interactively #'whatsapp-filter-clear)))))

;; =========================================================================
;;  Commands — chat list
;; =========================================================================

(defun whatsapp-chat-list-open () (interactive) (let ((j (tabulated-list-get-id))) (when j (whatsapp--open-chat j))))
(defun whatsapp-chat-list-mouse-open (event)
  "Open the chat on the clicked line (telega-style click-to-open)."
  (interactive "e")
  (mouse-set-point event)
  (let ((j (tabulated-list-get-id))) (when j (whatsapp--open-chat j))))
(defun whatsapp-send-new () (interactive) (whatsapp--open-chat (whatsapp--read-jid "Send to: ")))
(defun whatsapp-refresh () (interactive) (whatsapp--http-get "/chats" (lambda (cs) (setq whatsapp--chats nil) (dolist (c cs) (push (cons (plist-get c :jid) c) whatsapp--chats)
  (let ((pr (plist-get c :presence))) (when pr (setf (alist-get (plist-get c :jid) whatsapp--presence nil nil #'equal) pr)))) (whatsapp--recompute-unread) (whatsapp--refresh-chat-list-buffer) (message "WhatsApp: refreshed"))))
(defun whatsapp-search-chats () (interactive) (let ((p (downcase (read-string "Filter: ")))) (if (string-empty-p p) (whatsapp--refresh-chat-list-buffer)
  (let ((buf (get-buffer "*WhatsApp*"))) (when buf (with-current-buffer buf (let ((inhibit-read-only t))
    (setq tabulated-list-entries (mapcar #'whatsapp--chat-to-entry (cl-remove-if-not (lambda (x) (string-match-p p (downcase (or (plist-get (cdr x) :name) "")))) whatsapp--chats)))
    (tabulated-list-print t))))))))
(defun whatsapp-search-messages () (interactive) (let ((q (read-string "Search: "))) (when (string-empty-p q) (user-error "Empty"))
  (whatsapp--http-get (format "/messages/search?q=%s&limit=30" (url-hexify-string q)) (lambda (rs) (if (null rs) (message "No results")
    (let ((buf (get-buffer-create "*WhatsApp: Search*"))) (with-current-buffer buf (let ((inhibit-read-only t)) (erase-buffer)
      (insert (propertize (format "Results for \"%s\" (%d)  — RET to open chat\n\n" q (length rs)) 'face 'whatsapp-msg-date-header))
      (dolist (pl rs) (let* ((m (whatsapp--plist-to-message pl)) (jid (whatsapp-message-jid m))
                             (name (whatsapp--chat-display-name jid)))
        (let ((start (point)))
          (insert (propertize name 'face 'whatsapp-msg-sender) "  "
                  (propertize (whatsapp--format-timestamp (whatsapp-message-timestamp m)) 'face 'whatsapp-msg-timestamp) "\n"
                  (whatsapp--render-wa-text (whatsapp-message-text m) 'whatsapp-msg-other) "\n\n")
          (put-text-property start (point) 'whatsapp-search-jid jid)))) (goto-char (point-min)))
      (special-mode)
      (local-set-key (kbd "q") #'kill-this-buffer)
      (local-set-key (kbd "RET") (lambda () (interactive)
        (let ((jid (get-text-property (point) 'whatsapp-search-jid))) (when jid (whatsapp--open-chat jid))))))
    (pop-to-buffer buf)))))))
(defun whatsapp-toggle-archive () (interactive) (setq whatsapp-show-archive (not whatsapp-show-archive)) (whatsapp--refresh-chat-list-buffer) (message "Archive %s" (if whatsapp-show-archive "shown" "hidden")))
(defun whatsapp-mark-all-read () (interactive) (when (y-or-n-p "Mark all read? ") (whatsapp--http-post "/chats/read-all" nil (lambda (r) (when (plist-get r :ok) (message "✓") (whatsapp-refresh))))))
(defun whatsapp-starred-messages () (interactive) (whatsapp--http-get "/messages/starred" (lambda (rs) (if (null rs) (message "No starred")
  (let ((buf (get-buffer-create "*WhatsApp: Starred*"))) (with-current-buffer buf (let ((inhibit-read-only t)) (erase-buffer)
    (insert (propertize (format "⭐ Starred (%d)\n\n" (length rs)) 'face 'whatsapp-msg-date-header))
    (dolist (pl rs) (let ((m (whatsapp--plist-to-message pl))) (insert (propertize (whatsapp--chat-display-name (whatsapp-message-jid m)) 'face 'whatsapp-msg-sender) "  "
      (propertize (whatsapp--format-timestamp (whatsapp-message-timestamp m)) 'face 'whatsapp-msg-timestamp) "\n"
      (whatsapp--render-wa-text (whatsapp-message-text m) 'whatsapp-msg-other) "\n\n"))) (goto-char (point-min)))
    (special-mode) (local-set-key (kbd "q") #'kill-this-buffer)) (pop-to-buffer buf))))))

;; Chat management
(defun whatsapp-chat-archive-toggle () (interactive) (let* ((j (tabulated-list-get-id)) (c (alist-get j whatsapp--chats nil nil #'equal)) (a (and c (eq (plist-get (cdr c) :archived) t))))
  (when j (whatsapp--http-post "/chats/archive" `(:jid ,j :archive ,(if a :json-false t)) (lambda (r) (when (plist-get r :ok) (message (if a "Unarchived" "Archived")) (whatsapp-refresh)))))))
(defun whatsapp-chat-pin-toggle () (interactive) (let* ((j (tabulated-list-get-id)) (c (alist-get j whatsapp--chats nil nil #'equal)) (p (and c (eq (plist-get (cdr c) :pinned) t))))
  (when j (whatsapp--http-post "/chats/pin" `(:jid ,j :pin ,(if p :json-false t)) (lambda (r) (when (plist-get r :ok) (message (if p "Unpinned" "Pinned")) (whatsapp-refresh)))))))
(defun whatsapp-chat-mute-toggle () (interactive) (let* ((j (tabulated-list-get-id)) (c (alist-get j whatsapp--chats nil nil #'equal)) (m (and c (eq (plist-get (cdr c) :muted) t))))
  (when j (whatsapp--http-post "/chats/mute" `(:jid ,j :mute ,(if m :json-false t)) (lambda (r) (when (plist-get r :ok) (message (if m "Unmuted" "Muted")) (whatsapp-refresh)))))))
(defun whatsapp-chat-delete-at-point () (interactive) (let ((j (tabulated-list-get-id)))
  (when (and j (y-or-n-p (format "Delete %s? " (whatsapp--chat-display-name j)))) (whatsapp--http-delete (format "/chats/%s" (url-hexify-string j)) (lambda (r) (when (plist-get r :ok) (message "Deleted") (whatsapp-refresh)))))))

;; =========================================================================
;;  Commands — chat buffer
;; =========================================================================

(defun whatsapp--in-compose-p () (and whatsapp--compose-marker (>= (point) (marker-position whatsapp--compose-marker))))
(defun whatsapp-chat-send-or-newline () (interactive) (if (whatsapp--in-compose-p) (whatsapp--do-send) (whatsapp-chat-focus-compose)))
(defun whatsapp-chat-focus-compose () (interactive) (when whatsapp--compose-marker (goto-char (point-max))))
(defun whatsapp-chat-scroll-bottom () (interactive) (goto-char (point-max)) (recenter -1) (setq whatsapp--new-msg-count 0 whatsapp--at-bottom t) (whatsapp--update-chat-header))

(defun whatsapp--do-send ()
  (let ((raw (whatsapp--compose-text))) (when (string-empty-p raw) (user-error "Empty"))
    (let ((text (whatsapp--convert-org-markup raw)) (rid whatsapp--reply-to-id))
      (whatsapp--send-typing-paused)
      (whatsapp--http-post (if rid "/messages/reply" "/messages/send/text")
        (if rid `(:jid ,whatsapp--chat-jid :text ,text :quotedMsgId ,rid) `(:jid ,whatsapp--chat-jid :text ,text))
        (lambda (r) (if (plist-get r :ok) (progn (whatsapp--chat-buffer-add-message whatsapp--chat-jid (whatsapp--plist-to-message (plist-get r :data))) (message "✓"))
                      (message "✗ %s" (plist-get r :error)))))
      (whatsapp--clear-compose) (setq whatsapp--reply-to-id nil) (remhash whatsapp--chat-jid whatsapp--drafts) (whatsapp--update-chat-header))))

(defun whatsapp-chat-cancel-reply () (interactive) (setq whatsapp--reply-to-id nil) (whatsapp--update-chat-header) (message "Reply cancelled"))

(defun whatsapp-chat-compose-multiline () (interactive) (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let ((jid whatsapp--chat-jid) (name (whatsapp--chat-display-name whatsapp--chat-jid)) (rid whatsapp--reply-to-id)
        (draft (whatsapp--compose-text)))
    (let ((buf (get-buffer-create (format "*WhatsApp: Compose → %s*" name)))) (pop-to-buffer buf)
      (with-current-buffer buf (text-mode) (erase-buffer) (setq-local whatsapp--compose-target-jid jid whatsapp--compose-quote-id rid)
        (setq header-line-format (concat (propertize " ✏️ → " 'face 'whatsapp-compose-prompt) (propertize name 'face 'whatsapp-chat-name) "  C-c C-c send · C-c C-k cancel"))
        (when (and draft (not (string-empty-p draft))) (insert draft))
        (local-set-key (kbd "C-c C-c") #'whatsapp--ext-send) (local-set-key (kbd "C-c C-k") (lambda () (interactive) (kill-buffer) (message "Cancelled")))))))

(defun whatsapp--ext-send () (interactive) (let ((text (whatsapp--convert-org-markup (string-trim (buffer-string)))) (jid whatsapp--compose-target-jid) (qid whatsapp--compose-quote-id))
  (when (string-empty-p text) (user-error "Empty"))
  (whatsapp--http-post (if qid "/messages/reply" "/messages/send/text") (if qid `(:jid ,jid :text ,text :quotedMsgId ,qid) `(:jid ,jid :text ,text))
    (lambda (r) (when (plist-get r :ok) (whatsapp--chat-buffer-add-message jid (whatsapp--plist-to-message (plist-get r :data))) (message "✓")))) (kill-buffer)))

;; Message commands
(defun whatsapp-chat-reply () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message"))
  (setq whatsapp--reply-to-id (whatsapp-message-id msg)) (whatsapp--update-chat-header) (goto-char (point-max))
  (message "Replying to: %s" (truncate-string-to-width (whatsapp-message-text msg) 40 nil nil "…"))))
(defun whatsapp-chat-react () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message"))
  (whatsapp--http-post "/messages/react" `(:jid ,whatsapp--chat-jid :msgId ,(whatsapp-message-id msg) :emoji ,(whatsapp--read-emoji)) (whatsapp--ack))))
(defun whatsapp-chat-edit () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message")) (unless (whatsapp-message-from-me msg) (user-error "Own only"))
  (let ((new (whatsapp--convert-org-markup (read-string "New: " (whatsapp-message-text msg))))) (when (string-empty-p new) (user-error "Empty"))
    (whatsapp--http-post "/messages/edit" `(:jid ,whatsapp--chat-jid :msgId ,(whatsapp-message-id msg) :newText ,new)
      (lambda (r) (when (plist-get r :ok) (setf (whatsapp-message-text msg) new (whatsapp-message-edited msg) t)
        (let ((n (gethash (whatsapp-message-id msg) whatsapp--chat-messages))) (when n (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc n)))) (message "✓")))))))
(defun whatsapp-chat-delete () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message"))
  (let ((ev (and (whatsapp-message-from-me msg) (y-or-n-p "For everyone? ")))) (when (y-or-n-p "Delete? ")
    (whatsapp--http-post "/messages/delete" `(:jid ,whatsapp--chat-jid :msgId ,(whatsapp-message-id msg) :forEveryone ,(if ev t :json-false))
      (lambda (r) (when (plist-get r :ok) (whatsapp--chat-buffer-mark-deleted whatsapp--chat-jid (whatsapp-message-id msg)) (message "✓"))))))))
(defun whatsapp-chat-forward () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message"))
  (whatsapp--http-post "/messages/forward" `(:fromJid ,whatsapp--chat-jid :toJid ,(whatsapp--read-jid "Forward to: ") :msgId ,(whatsapp-message-id msg))
    (whatsapp--ack))))
(defun whatsapp-chat-copy-text () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message")) (kill-new (whatsapp-message-text msg)) (message "Copied")))
(defun whatsapp-chat-star-toggle () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message"))
  (let ((ns (not (whatsapp-message-starred msg)))) (whatsapp--http-post "/messages/star" `(:msgId ,(whatsapp-message-id msg) :star ,(if ns t :json-false))
    (lambda (r) (when (plist-get r :ok) (setf (whatsapp-message-starred msg) ns) (let ((n (gethash (whatsapp-message-id msg) whatsapp--chat-messages)))
      (when n (let ((inhibit-read-only t)) (ewoc-invalidate whatsapp--chat-ewoc n)))) (message (if ns "⭐" "Unstarred"))))))))

;; Media
(defun whatsapp-chat-attach () (interactive) (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let* ((f (expand-file-name (read-file-name "Attach: " nil nil t))) (cap (read-string "Caption: ")) (mime (whatsapp--mime-from-ext f)))
    (unless (file-exists-p f) (user-error "Not found")) (message "Uploading…")
    (let* ((cmd (format "curl -s -X POST %s -F %s -F %s %s %s" (whatsapp--curl-auth)
                  (shell-quote-argument (format "file=@%s;type=%s" f mime))
                  (shell-quote-argument (format "jid=%s" whatsapp--chat-jid))
                  (if (string-empty-p cap) "" (format "-F %s" (shell-quote-argument (format "caption=%s" cap))))
                  (whatsapp--api-url "/messages/send/media")))
           (out (shell-command-to-string cmd)) (json-object-type 'plist) (json-key-type 'keyword) (resp (ignore-errors (json-read-from-string out))))
      (if (and resp (plist-get resp :ok)) (progn (whatsapp--chat-buffer-add-message whatsapp--chat-jid (whatsapp--plist-to-message (plist-get resp :data))) (message "✓"))
        (message "✗ %s" (or (plist-get resp :error) out))))))

(defun whatsapp--voice-binary ()
  "Executable used to record, per `whatsapp-voice-record-command'."
  (pcase whatsapp-voice-record-command ("sox" "rec") (cmd cmd)))

(defun whatsapp-chat-voice (&optional cancel)
  "Toggle voice recording: start, then C-c v again to stop and send.
With prefix arg CANCEL, stop and discard instead of sending."
  (interactive "P")
  (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (if whatsapp--voice-process
      ;; --- stop ---
      (progn
        (when (process-live-p whatsapp--voice-process) (interrupt-process whatsapp--voice-process) (sit-for 0.4))
        (setq whatsapp--voice-process nil)
        (cond
         (cancel (when (and whatsapp--voice-file (file-exists-p whatsapp--voice-file)) (ignore-errors (delete-file whatsapp--voice-file)))
                 (setq whatsapp--voice-file nil) (message "Voice recording discarded"))
         ((and whatsapp--voice-file (file-exists-p whatsapp--voice-file) (> (file-attribute-size (file-attributes whatsapp--voice-file)) 0))
          (message "Sending voice…")
          (let* ((cmd (format "curl -s -X POST %s -F %s -F %s -F 'mimetype=audio/ogg' -F 'ptt=true' %s"
                              (whatsapp--curl-auth)
                              (shell-quote-argument (format "file=@%s;type=audio/ogg" whatsapp--voice-file))
                              (shell-quote-argument (format "jid=%s" whatsapp--chat-jid))
                              (whatsapp--api-url "/messages/send/media")))
                 (out (shell-command-to-string cmd)) (json-object-type 'plist) (json-key-type 'keyword) (resp (ignore-errors (json-read-from-string out))))
            (if (and resp (plist-get resp :ok))
                (progn (whatsapp--chat-buffer-add-message whatsapp--chat-jid (whatsapp--plist-to-message (plist-get resp :data))) (message "🎤 Voice sent"))
              (message "✗ %s" (or (plist-get resp :error) out))))
          (ignore-errors (delete-file whatsapp--voice-file)) (setq whatsapp--voice-file nil))
         (t (setq whatsapp--voice-file nil) (message "✗ Recording failed (no audio captured)"))))
    ;; --- start ---
    (unless (executable-find (whatsapp--voice-binary))
      (user-error "Recorder '%s' not found — set `whatsapp-voice-record-command' (sox/ffmpeg/arecord)" (whatsapp--voice-binary)))
    (make-directory whatsapp-media-directory t)
    (setq whatsapp--voice-file (expand-file-name (format "v-%s.%s" (format-time-string "%Y%m%d%H%M%S") whatsapp-voice-format) whatsapp-media-directory))
    (condition-case err
        (progn
          (setq whatsapp--voice-process
                (apply #'start-process "wa-rec" nil
                       (pcase whatsapp-voice-record-command
                         ("sox" (list "rec" "-q" "-c" "1" "-r" "48000" whatsapp--voice-file))
                         ("ffmpeg" (list "ffmpeg" "-y" "-f" "pulse" "-i" "default" "-c:a" "libopus" "-b:a" "48k" whatsapp--voice-file))
                         ("arecord" (list "arecord" "-q" "-f" "cd" "-c" "1" whatsapp--voice-file))
                         (_ (list whatsapp-voice-record-command whatsapp--voice-file)))))
          (message "🔴 Recording… C-c v to stop & send · C-u C-c v to cancel"))
      (error (setq whatsapp--voice-process nil whatsapp--voice-file nil) (message "✗ Recording failed: %s" (error-message-string err))))))

(defun whatsapp-chat-download-media () (interactive) (let ((msg (whatsapp--message-at-point))) (unless msg (user-error "No message"))
  (unless (whatsapp-message-has-media msg) (user-error "No media")) (make-directory whatsapp-media-directory t)
  (let* ((mid (whatsapp-message-id msg)) (jid (whatsapp-message-jid msg))
         (ext (pcase (whatsapp-message-type msg) ("image" (pcase (whatsapp-message-mimetype msg) ("image/png" "png") ("image/webp" "webp") (_ "jpg")))
           ("video" "mp4") ("audio" (if (whatsapp-message-ptt msg) "ogg" "mp3")) ("document" (or (file-name-extension (or (whatsapp-message-file-name msg) "")) "bin")) (_ "bin")))
         (out (expand-file-name (or (whatsapp-message-file-name msg) (format "m-%s.%s" mid ext)) whatsapp-media-directory))
         (open (string= (whatsapp-message-type msg) "image")))
    (message "Downloading…")
    ;; Async + content-type checked, so Emacs never blocks and a JSON error is
    ;; never saved as a media file.
    (whatsapp--http-get-binary (format "/messages/media/%s" (url-hexify-string mid)) out
      (lambda (ok)
        (if (not ok) (message "✗ Download failed (media may have expired)")
          (message "Saved: %s" out)
          ;; Refresh the inline image via the cache rather than splicing into the ewoc.
          (when (and whatsapp-inline-images (display-graphic-p) (member (whatsapp-message-type msg) '("image" "sticker")))
            (whatsapp--inline-image-finalize jid mid out))
          (when (y-or-n-p "Open? ") (pcase system-type ('gnu/linux (start-process "o" nil "xdg-open" out)) ('darwin (start-process "o" nil "open" out)) (_ (find-file out))))))))))

(defun whatsapp-chat-play-audio ()
  "Download and play audio/voice message at point."
  (interactive)
  (let ((msg (whatsapp--message-at-point)))
    (unless msg (user-error "No message"))
    (unless (and (whatsapp-message-has-media msg) (member (whatsapp-message-type msg) '("audio")))
      (user-error "Not an audio message"))
    (make-directory whatsapp-media-directory t)
    (let* ((mid (whatsapp-message-id msg)) (ext (if (whatsapp-message-ptt msg) "ogg" "mp3"))
           (out (expand-file-name (format "audio-%s.%s" mid ext) whatsapp-media-directory))
           (play (lambda ()
                   (if (string= whatsapp-audio-player "emms")
                       (if (fboundp 'emms-play-file) (emms-play-file out) (message "EMMS not loaded"))
                     (start-process "wa-play" nil whatsapp-audio-player out)
                     (message "Playing %s…" (file-name-nondirectory out))))))
      (if (file-exists-p out) (funcall play)
        (message "Downloading…")
        (whatsapp--http-get-binary (format "/messages/media/%s" (url-hexify-string mid)) out
          (lambda (ok) (if ok (funcall play) (message "✗ Could not fetch audio"))))))))

(defun whatsapp--media-ext (msg)
  "Best file extension for MSG's media type."
  (pcase (whatsapp-message-type msg)
    ("image" (pcase (whatsapp-message-mimetype msg) ("image/png" "png") ("image/webp" "webp") ("image/gif" "gif") (_ "jpg")))
    ((or "video" "gif") "mp4")
    ("audio" (if (whatsapp-message-ptt msg) "ogg" "mp3"))
    ("sticker" "webp")
    ("document" (or (file-name-extension (or (whatsapp-message-file-name msg) "")) "bin"))
    (_ "bin")))

(defun whatsapp--with-media-file (msg cb)
  "Ensure MSG's media is on disk, then call CB with its path (async, cached)."
  (make-directory whatsapp-media-directory t)
  (let* ((mid (whatsapp-message-id msg))
         (out (expand-file-name (format "m-%s.%s" (md5 mid) (whatsapp--media-ext msg)) whatsapp-media-directory)))
    (if (file-exists-p out) (funcall cb out)
      (message "Downloading…")
      (whatsapp--http-get-binary (format "/messages/media/%s" (url-hexify-string mid)) out
        (lambda (ok) (if ok (funcall cb out) (message "✗ Could not fetch media (may have expired)")))))))

(defun whatsapp-chat-play-media ()
  "Play the media at point: audio in the audio player, video/GIF in the video
player (GIFs loop). Downloads on demand and caches."
  (interactive)
  (let* ((msg (whatsapp--message-at-point)))
    (unless msg (user-error "No message"))
    (unless (whatsapp-message-has-media msg) (user-error "No media at point"))
    (pcase (whatsapp-message-type msg)
      ("audio" (whatsapp-chat-play-audio))
      ((or "video" "gif")
       (whatsapp--with-media-file msg
         (lambda (path)
           (let ((loop (string= (whatsapp-message-type msg) "gif")))
             (apply #'start-process "wa-video" nil whatsapp-video-player
                    (append (when loop '("--loop")) (list path)))
             (message "Playing %s…" (if loop "GIF" "video"))))))
      ("image" (whatsapp--with-media-file msg (lambda (path) (whatsapp--inline-image-finalize (whatsapp-message-jid msg) (whatsapp-message-id msg) path) (message "Loaded image"))))
      (_ (whatsapp-chat-download-media)))))

;; Rich messages
(defun whatsapp-chat-send-location () (interactive) (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (whatsapp--http-post "/messages/send/location" `(:jid ,whatsapp--chat-jid :lat ,(read-number "Lat: ") :lon ,(read-number "Lon: ")
    ,@(let ((n (read-string "Name: "))) (unless (string-empty-p n) (list :name n))) ,@(let ((a (read-string "Addr: "))) (unless (string-empty-p a) (list :address a))))
    (lambda (r) (when (plist-get r :ok) (whatsapp--chat-buffer-add-message whatsapp--chat-jid (whatsapp--plist-to-message (plist-get r :data))) (message "✓")))))
(defun whatsapp-chat-send-poll () (interactive) (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let* ((nm (read-string "Question: ")) (opts (mapcar #'string-trim (split-string (read-string "Options (comma): ") ","))) (mu (y-or-n-p "Multi? ")))
    (when (< (length opts) 2) (user-error "≥2 options"))
    (whatsapp--http-post "/messages/send/poll" `(:jid ,whatsapp--chat-jid :name ,nm :values ,opts :selectableCount ,(if mu (length opts) 1)) (whatsapp--ack))))
(defun whatsapp-chat-send-contact () (interactive) (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let* ((dn (read-string "Name: ")) (ph (replace-regexp-in-string "[^0-9]" "" (read-string "Phone: "))))
    (whatsapp--http-post "/messages/send/contact" `(:jid ,whatsapp--chat-jid :displayName ,dn :vcard ,(format "BEGIN:VCARD\nVERSION:3.0\nFN:%s\nTEL;type=CELL;waid=%s:+%s\nEND:VCARD" dn ph ph))
      (whatsapp--ack))))

;; Chat export
(defun whatsapp-chat-export ()
  "Export the current chat. Choose text or Org format."
  (interactive)
  (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let* ((fmt (completing-read "Format: " '("text" "org") nil t nil nil "text"))
         (name (whatsapp--chat-display-name whatsapp--chat-jid))
         (ext (if (string= fmt "org") "org" "txt"))
         (filename (format "whatsapp-%s-%s.%s" (replace-regexp-in-string "[^a-zA-Z0-9]" "_" name) (format-time-string "%Y%m%d") ext)))
    (make-directory whatsapp-export-directory t)
    (let ((out-path (expand-file-name filename whatsapp-export-directory)))
      (if (string= fmt "org")
          ;; Org export: build locally from loaded messages
          (whatsapp--export-org out-path name)
        ;; Text export: fetch from server
        (message "Exporting…")
        (url-copy-file (whatsapp--api-url (format "/chats/%s/export?format=text&limit=500" (url-hexify-string whatsapp--chat-jid))) out-path t)
        (message "Exported to %s" out-path))
      (when (y-or-n-p "Open? ") (find-file out-path)))))

(defun whatsapp--export-org (path name)
  "Export current chat buffer messages to Org format at PATH."
  (let ((msgs nil))
    ;; Collect messages from ewoc
    (when whatsapp--chat-ewoc
      (let ((node (ewoc-nth whatsapp--chat-ewoc 0)))
        (while node
          (let ((m (ewoc-data node)))
            (unless (memq (whatsapp-message-type m) '(date-header unread-separator))
              (push m msgs)))
          (setq node (ewoc-next whatsapp--chat-ewoc node)))))
    (setq msgs (nreverse msgs))
    (with-temp-file path
      (insert (format "#+TITLE: WhatsApp: %s\n" name))
      (insert (format "#+DATE: %s\n" (format-time-string "%Y-%m-%d")))
      (insert "#+EXPORT_FROM: whatsapp.el v2.7.0\n\n")
      (let ((last-date nil))
        (dolist (m msgs)
          (let ((date (whatsapp--format-date (whatsapp-message-timestamp m)))
                (time (whatsapp--format-timestamp (whatsapp-message-timestamp m)))
                (sender (if (whatsapp-message-from-me m) "You" (whatsapp-message-sender-name m)))
                (text (whatsapp-message-text m))
                (mtype (whatsapp-message-type m)))
            (unless (equal last-date date)
              (setq last-date date)
              (insert "* " date "\n"))
            (unless (whatsapp-message-deleted m)
              (insert "** " time " " sender "\n")
              (when (whatsapp-message-quoted-text m)
                (insert "#+begin_quote\n" (whatsapp-message-quoted-text m) "\n#+end_quote\n"))
              (unless (string= mtype "text")
                (insert "/" (upcase mtype) "/")
                (let ((fn (whatsapp-message-file-name m)))
                  (when fn (insert " =" fn "=")))
                (insert "\n"))
              (unless (string-empty-p text)
                (insert text "\n"))
              (when (whatsapp-message-reactions m)
                (insert "Reactions: " (mapconcat (lambda (r) (format "%s×%d" (car r) (cdr r))) (whatsapp-message-reactions m) " ") "\n"))
              (insert "\n"))))))
    (message "Org export: %s" path)))

;; Groups
(defun whatsapp-group-create () (interactive) (let ((nm (read-string "Group: ")) (mb (mapcar #'string-trim (split-string (read-string "Members (comma): ") ","))))
  (when (string-empty-p nm) (user-error "Empty")) (whatsapp--http-post "/groups/create" `(:name ,nm :participants ,mb)
    (lambda (r) (if (plist-get r :ok) (progn (message "✓") (whatsapp-refresh)) (message "✗ %s" (plist-get r :error)))))))

(defun whatsapp-chat-info () (interactive)
  (if (whatsapp--is-group-jid whatsapp--chat-jid)
    (whatsapp--http-get (format "/groups/%s/metadata" (url-hexify-string whatsapp--chat-jid)) (lambda (data)
      (let ((buf (get-buffer-create (format "*WhatsApp: %s Info*" (whatsapp--chat-display-name whatsapp--chat-jid)))))
        (with-current-buffer buf (let ((inhibit-read-only t) (jid whatsapp--chat-jid)) (erase-buffer)
          (insert (propertize (or (plist-get data :subject) "Group") 'face 'whatsapp-chat-name) "\n\n")
          (let ((desc (plist-get data :desc))) (when (and desc (not (string-empty-p desc))) (insert desc "\n\n")))
          (insert (propertize (format "Participants (%d):\n" (length (plist-get data :participants))) 'face 'whatsapp-msg-sender))
          (dolist (p (plist-get data :participants)) (insert "  " (whatsapp--chat-display-name (plist-get p :id))
            (let ((a (plist-get p :admin))) (if a (propertize (format " [%s]" a) 'face 'whatsapp-chat-pinned) "")) "\n"))
          (insert "\n" (propertize "a Add · r Remove · l Leave · i Invite" 'face 'whatsapp-msg-timestamp) "\n") (goto-char (point-min))
          (special-mode) (local-set-key (kbd "q") #'kill-this-buffer)
          (local-set-key (kbd "a") `(lambda () (interactive) (whatsapp--http-post ,(format "/groups/%s/participants" (url-hexify-string jid)) (list :action "add" :participants (list (read-string "Phone: "))) (whatsapp--ack))))
          (local-set-key (kbd "r") `(lambda () (interactive) (whatsapp--http-post ,(format "/groups/%s/participants" (url-hexify-string jid)) (list :action "remove" :participants (list (read-string "Phone: "))) (whatsapp--ack))))
          (local-set-key (kbd "l") `(lambda () (interactive) (when (y-or-n-p "Leave? ") (whatsapp--http-post ,(format "/groups/%s/leave" (url-hexify-string jid)) '(:_x t) (lambda (r) (when (plist-get r :ok) (message "Left") (whatsapp-refresh)))))))
          (local-set-key (kbd "i") `(lambda () (interactive) (whatsapp--http-get ,(format "/groups/%s/invite-code" (url-hexify-string jid)) (lambda (d) (kill-new (plist-get d :link)) (message "Copied: %s" (plist-get d :link))))))))
        (pop-to-buffer buf))))
    (whatsapp--http-get (format "/contacts/%s" (url-hexify-string whatsapp--chat-jid)) (lambda (d)
      (let* ((jid whatsapp--chat-jid) (name (or (plist-get d :name) (plist-get d :pushName) "?"))
             (phone (replace-regexp-in-string "@.*" "" jid)) (status (plist-get d :status))
             (push-name (or (plist-get d :pushName) "")) (img-url (plist-get d :imgUrl))
             (buf (get-buffer-create (format "*WhatsApp: %s Info*" name))))
        (with-current-buffer buf
          (let ((inhibit-read-only t)) (erase-buffer)
            (insert (propertize (whatsapp--initials name) 'face '(:height 2.0 :inherit whatsapp-chat-initials)) "  "
                    (propertize name 'face '(:height 1.5 :inherit whatsapp-chat-name)) "\n\n")
            (insert (propertize "Phone: " 'face 'whatsapp-msg-sender) (propertize (concat "+" phone) 'face 'whatsapp-contact-phone) "\n")
            (when (and push-name (not (string-empty-p push-name)) (not (equal push-name name)))
              (insert (propertize "Push Name: " 'face 'whatsapp-msg-sender) push-name "\n"))
            (when (and status (not (string-empty-p status)))
              (insert (propertize "About: " 'face 'whatsapp-msg-sender) (propertize status 'face 'whatsapp-msg-quote) "\n"))
            (let ((pr (alist-get jid whatsapp--presence nil nil #'equal)))
              (when pr (insert (propertize "Status: " 'face 'whatsapp-msg-sender)
                               (pcase (plist-get pr :lastKnown)
                                 ("available" (propertize "Online" 'face 'whatsapp-chat-presence-online))
                                 (_ (propertize "Offline" 'face 'whatsapp-chat-presence-offline))) "\n")))
            (insert "\n" (propertize "─── Actions ───" 'face 'whatsapp-msg-date-header) "\n")
            (insert " o Open chat  · w Copy phone  · q Close\n")
            (goto-char (point-min)))
          (special-mode)
          (local-set-key (kbd "q") #'kill-this-buffer)
          (local-set-key (kbd "o") `(lambda () (interactive) (kill-this-buffer) (whatsapp--open-chat ,jid)))
          (local-set-key (kbd "w") `(lambda () (interactive) (kill-new ,(concat "+" phone)) (message "Copied: +%s" ,phone))))
        (pop-to-buffer buf))))))

;; Navigation
(defun whatsapp-chat-next-message () (interactive) (when whatsapp--chat-ewoc (let* ((n (ewoc-locate whatsapp--chat-ewoc (point))) (nx (and n (ewoc-next whatsapp--chat-ewoc n)))) (when nx (goto-char (ewoc-location nx))))))
(defun whatsapp-chat-prev-message () (interactive) (when whatsapp--chat-ewoc (let* ((n (ewoc-locate whatsapp--chat-ewoc (point))) (pv (and n (ewoc-prev whatsapp--chat-ewoc n)))) (when pv (goto-char (ewoc-location pv))))))
(defun whatsapp-chat-next-unread () (interactive) (when whatsapp--chat-ewoc (let ((n (ewoc-nth whatsapp--chat-ewoc 0)) f)
  (while (and n (not f)) (when (eq (whatsapp-message-type (ewoc-data n)) 'unread-separator) (setq f n)) (setq n (ewoc-next whatsapp--chat-ewoc n)))
  (if f (goto-char (ewoc-location f)) (message "No unread")))))
(defun whatsapp-chat-load-older () (interactive) (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let ((nd (ewoc-nth whatsapp--chat-ewoc 0)) fid) (while (and nd (not fid))
    (unless (memq (whatsapp-message-type (ewoc-data nd)) '(date-header unread-separator)) (setq fid (whatsapp-message-id (ewoc-data nd)))) (setq nd (ewoc-next whatsapp--chat-ewoc nd)))
  (whatsapp--http-get (format "/messages/history/%s?limit=%d%s" (url-hexify-string whatsapp--chat-jid) whatsapp-history-fetch-count (if fid (format "&before=%s" (url-hexify-string fid)) ""))
    (lambda (msgs) (let ((buf (whatsapp--get-chat-buffer whatsapp--chat-jid))) (when (and buf (buffer-live-p buf)) (with-current-buffer buf (let ((inhibit-read-only t) (ct 0) ld)
      (dolist (pl (reverse msgs)) (let* ((m (whatsapp--plist-to-message pl)) (d (whatsapp--format-date (whatsapp-message-timestamp m))))
        (unless (gethash (whatsapp-message-id m) whatsapp--chat-messages)
          (unless (equal ld d) (setq ld d) (ewoc-enter-first whatsapp--chat-ewoc (whatsapp-message-create :id (format "d-%s" d) :text d :type 'date-header :timestamp 0)))
          (puthash (whatsapp-message-id m) (ewoc-enter-first whatsapp--chat-ewoc m) whatsapp--chat-messages) (cl-incf ct))))
      ;; Local store exhausted — pull older history from WhatsApp itself.
      (if (= ct 0) (whatsapp--fetch-older-from-whatsapp whatsapp--chat-jid) (message "%d older messages loaded" ct))))))))))

(defun whatsapp-chat-quit () (interactive)
  (whatsapp--save-draft) (when whatsapp--chat-jid (whatsapp--send-typing-paused))
  (bury-buffer) (let ((lb (get-buffer "*WhatsApp*"))) (when lb (pop-to-buffer-same-window lb))))

;; =========================================================================
;;  New features: in-chat search, status viewer, chat stats, helpers
;; =========================================================================

(defun whatsapp--chat-muted-p (jid)
  "Return non-nil if chat JID is muted."
  (let ((c (alist-get jid whatsapp--chats nil nil #'equal)))
    (and c (eq (plist-get (cdr c) :muted) t))))

(defun whatsapp-chat-search-in-chat ()
  "Search messages within the current chat."
  (interactive)
  (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let ((q (read-string (format "Search in %s: " (whatsapp--chat-display-name whatsapp--chat-jid)))))
    (when (string-empty-p q) (user-error "Empty"))
    (whatsapp--http-get (format "/messages/search/chat/%s?q=%s&limit=20" (url-hexify-string whatsapp--chat-jid) (url-hexify-string q))
      (lambda (results)
        (if (null results) (message "No matches for \"%s\"" q)
          (let ((buf (get-buffer-create (format "*WhatsApp: Search in %s*" (whatsapp--chat-display-name whatsapp--chat-jid)))))
            (with-current-buffer buf
              (let ((inhibit-read-only t)) (erase-buffer)
                (insert (propertize (format "Search \"%s\" in %s (%d results)\n\n" q (whatsapp--chat-display-name whatsapp--chat-jid) (length results))
                                     'face 'whatsapp-msg-date-header))
                (dolist (pl results)
                  (let ((m (whatsapp--plist-to-message pl)))
                    (insert (propertize (whatsapp--format-timestamp-full (whatsapp-message-timestamp m)) 'face 'whatsapp-msg-timestamp) " "
                            (propertize (if (whatsapp-message-from-me m) "You" (whatsapp-message-sender-name m)) 'face 'whatsapp-msg-sender) "\n"
                            (whatsapp--render-wa-text (whatsapp-message-text m) 'whatsapp-msg-other) "\n\n")))
                (goto-char (point-min)))
              (special-mode) (local-set-key (kbd "q") #'kill-this-buffer))
            (pop-to-buffer buf)))))))

(defun whatsapp-status-updates ()
  "View recent WhatsApp status/story updates."
  (interactive)
  (whatsapp--http-get "/status"
    (lambda (updates)
      (if (null updates) (message "No status updates")
        (let ((buf (get-buffer-create "*WhatsApp: Status Updates*")))
          (with-current-buffer buf
            (let ((inhibit-read-only t)) (erase-buffer)
              (insert (propertize (format "📱 Status Updates (%d)\n\n" (length updates)) 'face 'whatsapp-msg-date-header))
              (dolist (u updates)
                (let ((name (or (plist-get u :senderName) "?"))
                      (text (or (plist-get u :text) ""))
                      (ts (plist-get u :timestamp))
                      (mtype (or (plist-get u :type) "text")))
                  (insert (propertize name 'face 'whatsapp-msg-sender) "  "
                          (propertize (whatsapp--format-timestamp ts) 'face 'whatsapp-msg-timestamp)
                          (unless (string= mtype "text") (propertize (format " [%s]" mtype) 'face 'whatsapp-msg-media-link))
                          "\n")
                  (unless (string-empty-p text) (insert (propertize text 'face 'whatsapp-msg-other) "\n"))
                  (insert "\n")))
              (goto-char (point-min)))
            (special-mode) (local-set-key (kbd "q") #'kill-this-buffer)
            (local-set-key (kbd "g") (lambda () (interactive) (kill-this-buffer) (whatsapp-status-updates))))
          (pop-to-buffer buf))))))

(defun whatsapp-chat-stats ()
  "Show statistics for the current chat."
  (interactive)
  (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (whatsapp--http-get (format "/chats/%s/stats" (url-hexify-string whatsapp--chat-jid))
    (lambda (data)
      (let ((buf (get-buffer-create (format "*WhatsApp: %s Stats*" (whatsapp--chat-display-name whatsapp--chat-jid)))))
        (with-current-buffer buf
          (let ((inhibit-read-only t)) (erase-buffer)
            (insert (propertize (format "📊 Chat Stats: %s\n\n" (or (plist-get data :name) "?")) 'face 'whatsapp-msg-date-header))
            (insert (propertize "Total messages: " 'face 'whatsapp-msg-sender) (format "%d\n" (or (plist-get data :totalMessages) 0)))
            (insert (propertize "Media shared: " 'face 'whatsapp-msg-sender) (format "%d\n" (or (plist-get data :mediaCount) 0)))
            (let ((first (plist-get data :firstMessage)) (last-ts (plist-get data :lastMessage)))
              (when first (insert (propertize "First message: " 'face 'whatsapp-msg-sender) (whatsapp--format-timestamp-full first) "\n"))
              (when last-ts (insert (propertize "Last message: " 'face 'whatsapp-msg-sender) (whatsapp--format-timestamp-full last-ts) "\n")))
            (let ((counts (plist-get data :senderCounts)))
              (when counts
                (insert "\n" (propertize "Messages per sender:\n" 'face 'whatsapp-msg-sender))
                (dolist (pair (whatsapp--plist-pairs counts))
                  (insert (format "  %-20s %s\n" (car pair) (cdr pair))))))
            (goto-char (point-min)))
          (special-mode) (local-set-key (kbd "q") #'kill-this-buffer))
        (pop-to-buffer buf)))))

;; --- Context menu (graphical Emacs) ---

(defun whatsapp--setup-context-menu ()
  "Setup right-click context menu for chat buffers."
  (when (and (display-graphic-p) (boundp 'context-menu-functions))
    (add-hook 'context-menu-functions #'whatsapp--context-menu nil t)))

(defun whatsapp--context-menu (menu _click)
  "Populate MENU with WhatsApp actions for the message at point."
  (let ((msg (whatsapp--message-at-point)))
    (when msg
      (define-key-after menu [wa-sep] menu-bar-separator)
      (define-key-after menu [wa-reply] '(menu-item "Reply" whatsapp-chat-reply))
      (define-key-after menu [wa-react] '(menu-item "React" whatsapp-chat-react))
      (define-key-after menu [wa-copy] '(menu-item "Copy Text" whatsapp-chat-copy-text))
      (define-key-after menu [wa-forward] '(menu-item "Forward" whatsapp-chat-forward))
      (define-key-after menu [wa-star] '(menu-item "Star/Unstar" whatsapp-chat-star-toggle))
      (when (whatsapp-message-from-me msg)
        (define-key-after menu [wa-edit] '(menu-item "Edit" whatsapp-chat-edit))
        (define-key-after menu [wa-delete] '(menu-item "Delete" whatsapp-chat-delete)))
      (when (whatsapp-message-has-media msg)
        (define-key-after menu [wa-download] '(menu-item "Download Media" whatsapp-chat-download-media)))))
  menu)

;; =========================================================================
;;  Quick replies
;; =========================================================================

(defun whatsapp-chat-quick-reply ()
  "Send a quick reply from `whatsapp-quick-replies'."
  (interactive)
  (unless whatsapp--chat-jid (user-error "Not in a chat"))
  (let* ((choices (mapcar (lambda (pair) (cons (format "[%s] %s" (car pair) (cdr pair)) (cdr pair))) whatsapp-quick-replies))
         (choice (completing-read "Quick reply: " choices nil t))
         (text (cdr (assoc choice choices))))
    (when text
      (whatsapp--http-post "/messages/send/text" `(:jid ,whatsapp--chat-jid :text ,text)
        (lambda (r) (if (plist-get r :ok)
                        (progn (whatsapp--chat-buffer-add-message whatsapp--chat-jid (whatsapp--plist-to-message (plist-get r :data))) (message "✓ Quick: %s" text))
                      (message "✗")))))))

;; =========================================================================
;;  Notification sound
;; =========================================================================

(defun whatsapp--play-notification-sound ()
  "Play the notification sound if configured."
  (when whatsapp-notification-sound
    (condition-case nil
        (cond
         ;; GUI Emacs with sound support
         ((and (fboundp 'play-sound-file) (display-graphic-p))
          (play-sound-file whatsapp-notification-sound))
         ;; Linux
         ((eq system-type 'gnu/linux)
          (start-process "wa-snd" nil "aplay" "-q" whatsapp-notification-sound))
         ;; macOS
         ((eq system-type 'darwin)
          (start-process "wa-snd" nil "afplay" whatsapp-notification-sound)))
      (error nil))))

;; =========================================================================
;;  Auto-away
;; =========================================================================

(defvar whatsapp--away-timer nil "Idle timer for auto-away.")
(defvar whatsapp--away-active nil "Whether auto-away reply has been sent for current idle period.")
(defvar whatsapp--away-jids nil "JIDs that received auto-away this idle period.")

(defun whatsapp--start-auto-away ()
  "Start the auto-away idle timer."
  (whatsapp--stop-auto-away)
  (when whatsapp-auto-away
    (setq whatsapp--away-timer
          (run-with-idle-timer whatsapp-auto-away-idle t #'whatsapp--auto-away-activate))))

(defun whatsapp--stop-auto-away ()
  (when whatsapp--away-timer (cancel-timer whatsapp--away-timer) (setq whatsapp--away-timer nil))
  (setq whatsapp--away-active nil whatsapp--away-jids nil))

(defun whatsapp--auto-away-activate ()
  "Mark as away. Actual replies sent per-message in the notification handler."
  (setq whatsapp--away-active t whatsapp--away-jids nil))

(defun whatsapp--maybe-auto-reply (jid)
  "Send auto-away reply to JID if away and not already replied."
  (when (and whatsapp--away-active whatsapp-auto-away
             (not (member jid whatsapp--away-jids)))
    (push jid whatsapp--away-jids)
    (whatsapp--http-post "/messages/send/text" `(:jid ,jid :text ,whatsapp-auto-away) nil)))

;; =========================================================================
;;  Chat filter presets
;; =========================================================================

(defun whatsapp--apply-filter (pred label)
  (setq whatsapp--chat-filter pred)
  (whatsapp--refresh-chat-list-buffer)
  (message "%s — %d chats" label (length tabulated-list-entries)))

(defun whatsapp-filter-unread ()
  "Show only chats with unread messages."
  (interactive)
  (whatsapp--apply-filter (lambda (p) (> (or (plist-get (cdr p) :unreadCount) 0) 0)) "Unread"))

(defun whatsapp-filter-groups ()
  "Show only group chats."
  (interactive)
  (whatsapp--apply-filter (lambda (p) (or (eq (plist-get (cdr p) :isGroup) t) (whatsapp--is-group-jid (car p)))) "Groups"))

(defun whatsapp-filter-contacts ()
  "Show only 1:1 chats (no groups)."
  (interactive)
  (whatsapp--apply-filter (lambda (p) (not (or (eq (plist-get (cdr p) :isGroup) t) (whatsapp--is-group-jid (car p))))) "Direct chats"))

(defun whatsapp-filter-clear ()
  "Clear all filters, show all chats."
  (interactive)
  (setq whatsapp--chat-filter nil)
  (whatsapp--refresh-chat-list-buffer)
  (message "Filter cleared"))

;; =========================================================================
;;  Message yank (paste last received text)
;; =========================================================================

(defvar whatsapp--last-received nil "Last received message text for yanking.")

(defun whatsapp-yank-last-message ()
  "Insert the last received message text into the current buffer."
  (interactive)
  (if whatsapp--last-received
      (insert whatsapp--last-received)
    (message "No recent message to yank")))

;; Embark
(defvar whatsapp-message-map (let ((m (make-sparse-keymap))) (define-key m "r" #'whatsapp-chat-reply) (define-key m "e" #'whatsapp-chat-react) (define-key m "E" #'whatsapp-chat-edit)
  (define-key m "d" #'whatsapp-chat-delete) (define-key m "f" #'whatsapp-chat-forward) (define-key m "w" #'whatsapp-chat-copy-text)
  (define-key m "*" #'whatsapp-chat-star-toggle) (define-key m "m" #'whatsapp-chat-download-media) m))
(with-eval-after-load 'embark (add-to-list 'embark-keymap-alist '(whatsapp-message . whatsapp-message-map)))

;; =========================================================================
;;  QR + Help + Top-level
;; =========================================================================

(defun whatsapp--display-qr (qr)
  "Render QR (a \"data:image/png;base64,...\" URL) in the *WhatsApp QR* buffer.
Shows the PNG inline when the frame supports images; otherwise saves it to a
file and tries to open it externally so it can still be scanned."
  (if (not (and (stringp qr) (string-prefix-p "data:image/png;base64," qr)))
      (message "WhatsApp: no QR available yet (state: %s). Try M-x whatsapp-reconnect."
               whatsapp--connection-state)
    (let ((png (ignore-errors
                 (base64-decode-string (substring qr (length "data:image/png;base64,")))))
          (buf (get-buffer-create "*WhatsApp QR*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "\n  " (propertize "Link WhatsApp" 'face '(:height 1.5 :weight bold)) "\n\n")
          (insert "  On your phone open "
                  (propertize "WhatsApp → Settings → Linked Devices → Link a device"
                              'face 'whatsapp-chat-preview)
                  "\n  then point the camera at this code:\n\n")
          (if (and png (display-graphic-p) (image-type-available-p 'png))
              (insert "  " (propertize " " 'display (create-image png 'png t :ascent 'center)))
            (let ((f (expand-file-name "whatsapp-qr.png" temporary-file-directory)))
              (when png (let ((coding-system-for-write 'binary)) (with-temp-file f (insert png))))
              (insert (propertize
                       (format "  (this frame can't display inline images)\n  QR saved to %s\n  Open that file and scan it." f)
                       'face 'warning))
              (when png (ignore-errors (start-process "wa-qr-open" nil "xdg-open" f)))))
          (insert "\n\n  " (propertize "g" 'face 'help-key-binding) " refresh    "
                  (propertize "q" 'face 'help-key-binding) " close\n"))
        (unless (derived-mode-p 'special-mode) (special-mode))
        (setq-local revert-buffer-function (lambda (&rest _) (whatsapp-show-qr)))
        (goto-char (point-min)))
      (unless (get-buffer-window buf 'visible) (pop-to-buffer buf)))))

(defun whatsapp-show-qr ()
  "Fetch and display the WhatsApp linking QR code.
Shows the last QR the server pushed (instantly) and refreshes from the bridge."
  (interactive)
  (if (eq whatsapp--connection-state 'open)
      (message "WhatsApp is already linked and connected.")
    (when whatsapp--last-qr (whatsapp--display-qr whatsapp--last-qr))
    (whatsapp--http-get "/session/qr"
      (lambda (d) (let ((qr (plist-get d :qr)))
                    (if qr (whatsapp--display-qr qr)
                      (unless whatsapp--last-qr
                        (message "WhatsApp: no QR yet — is the bridge running? Try M-x whatsapp-reconnect."))))))))

(defun whatsapp-help () (interactive)
  (with-help-window "*WhatsApp Help*"
    (princ "WhatsApp.el v2.7.2\n\n")
    (princ "CHAT LIST                              CHAT BUFFER  (just type to compose!)\n")
    (princ "  RET / mouse-1  Open chat               RET        Send message\n")
    (princ "  c    New message                       C-j / S-RET Newline\n")
    (princ "  C    Contacts browser                  C-c C-e    Multi-line compose buffer\n")
    (princ "  g    Refresh                           C-c h      Actions menu (everything)\n")
    (princ "  s    Filter chats                      mouse-1    Click media/image to play/open\n")
    (princ "  S    Search messages                 \n")
    (princ "  G    Create group                      MESSAGE ACTIONS (C-c prefix)\n")
    (princ "  A/P/M  Archive / Pin / Mute            C-c r reply   C-c e react   C-c E edit\n")
    (princ "  D    Delete chat                       C-c d delete  C-c f forward C-c w copy\n")
    (princ "  R    Mark all read                     C-c * star    C-c i info\n")
    (princ "  TAB  Toggle archive view             \n")
    (princ "  *    Starred messages                  ATTACH / MEDIA\n")
    (princ "  h    Actions menu                      C-c a attach  C-c v voice (toggle)\n")
    (princ "  q    Bury / Q Disconnect               C-c m play media  C-c M download\n")
    (princ "                                         C-c l location  C-c C-p poll  C-c C-v card\n")
    (princ "  CONTACTS: RET/click chat, s search   \n")
    (princ "                                         NAVIGATION / HISTORY\n")
    (princ "  1/2/3/0  filter unread/groups/         M-p / M-n  prev / next message\n")
    (princ "           contacts / clear              C-c g  scroll to bottom\n")
    (princ "                                         C-c <  load older (C-c C-h)\n")
    (princ "                                         C-c s search · C-c I stats · C-c x export\n")
    (princ "\n  Voice: C-c v starts recording, C-c v again stops & sends (C-u C-c v cancels).\n")
    (princ "  GIFs & animated stickers play inline; videos/voice open on click.\n")
    (princ "  Right-click any message for a context menu. C-c C-r quick reply · C-c C-y yank last.\n")))

(defvar whatsapp--health-timer nil "Periodic health check timer.")

(defcustom whatsapp-health-interval 60
  "Seconds between server health checks. 0 to disable." :type 'integer :group 'whatsapp)

(defcustom whatsapp-connection-hook nil
  "Hook run when connection state changes.
Each function receives one argument: the new state symbol
\(one of `open', `disconnected', `connecting', `qr')." :type 'hook :group 'whatsapp)

(defun whatsapp--start-health-monitor ()
  "Start periodic health check. Detects server restarts."
  (whatsapp--stop-health-monitor)
  (when (> whatsapp-health-interval 0)
    (setq whatsapp--health-timer
          (run-with-timer whatsapp-health-interval whatsapp-health-interval
                          #'whatsapp--health-check))))

(defun whatsapp--stop-health-monitor ()
  (when whatsapp--health-timer (cancel-timer whatsapp--health-timer) (setq whatsapp--health-timer nil)))

(defun whatsapp--health-check ()
  "Check server health. Reconnect if WS is dead but server is alive."
  (condition-case nil
      (let ((url-request-method "GET")
            (url-request-extra-headers (whatsapp--auth-headers)))
        (url-retrieve (whatsapp--api-url "/health")
          (lambda (status)
            (unwind-protect
                (if (plist-get status :error)
                    ;; Server unreachable
                    (when (eq whatsapp--connection-state 'open)
                      (setq whatsapp--connection-state 'disconnected)
                      (whatsapp--update-mode-line)
                      (run-hook-with-args 'whatsapp-connection-hook 'disconnected))
                  ;; Server alive — check if WS needs reconnection
                  (when (and (not whatsapp--ws)
                             (memq whatsapp--connection-state '(disconnected)))
                    (message "WhatsApp: server detected, reconnecting…")
                    (whatsapp--ws-connect)))
              (kill-buffer)))
          nil t t))
    (error nil)))

;;;###autoload
(defun whatsapp-connect () (interactive) (make-directory whatsapp-media-directory t) (whatsapp--ws-connect)
  (whatsapp--start-health-monitor) (whatsapp--start-auto-away)
  (pop-to-buffer-same-window (whatsapp--chat-list-buffer)) (run-with-timer 1 nil #'whatsapp-refresh))

(defun whatsapp-disconnect () (interactive)
  (whatsapp--stop-health-monitor) (whatsapp--stop-auto-away)
  (when whatsapp--reconnect-timer (cancel-timer whatsapp--reconnect-timer) (setq whatsapp--reconnect-timer nil))
  (when whatsapp--event-timer (cancel-timer whatsapp--event-timer) (setq whatsapp--event-timer nil))
  (when whatsapp--voice-process (ignore-errors (kill-process whatsapp--voice-process)) (setq whatsapp--voice-process nil))
  (when whatsapp--ws (ignore-errors (websocket-close whatsapp--ws)) (setq whatsapp--ws nil))
  (dolist (b (buffer-list)) (when (string-prefix-p "*WhatsApp" (buffer-name b)) (kill-buffer b)))
  (setq whatsapp--connection-state 'disconnected whatsapp--chats nil whatsapp--contacts nil whatsapp--presence nil
        whatsapp--unread-total 0 whatsapp--reconnect-attempt 0 whatsapp--my-jid nil)
  (whatsapp--update-mode-line) (run-hook-with-args 'whatsapp-connection-hook 'disconnected) (message "WhatsApp: disconnected"))
(defun whatsapp-reconnect () (interactive) (whatsapp-disconnect) (run-with-timer 0.5 nil #'whatsapp-connect))
(defun whatsapp-status () (interactive) (message "WA: %s | chats:%d | contacts:%d | unread:%d | %s"
  whatsapp--connection-state (length whatsapp--chats) (length whatsapp--contacts) whatsapp--unread-total (or whatsapp--my-jid "?")))
(defun whatsapp-start-server () (interactive) (let ((default-directory (read-directory-name "Dir: ")))
  (start-process "wa-srv" (get-buffer-create "*WhatsApp Server*") "node" "server.js") (message "Started") (run-with-timer 3 nil #'whatsapp-connect)))

(provide 'whatsapp)
;;; whatsapp.el ends here
