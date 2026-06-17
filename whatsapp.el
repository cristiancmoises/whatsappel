;;; whatsapp.el --- telega-style Emacs WhatsApp client  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-only
;; Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
;;
;; Author: Cristian Cezar Moisés
;; URL: https://codeberg.org/berkeley/whatsappel
;; Version: 3.0.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm, whatsapp

;;; Commentary:

;; Talks to the Guile `whatsappel.scm' bridge over a token-guarded loopback
;; HTTP API.  The bridge proxies to wuzapi (whatsmeow); no Baileys, no Node.
;;
;; UI/UX follows telega.el: a root buffer listing chats, per-chat buffers with a
;; bottom input prompt, telega-style keybindings, an attach submenu on C-c C-a,
;; images/stickers rendered inline, audio/video/GIF opened in an external player
;; (the same media model telega uses).
;;
;; Setup:
;;   (require 'whatsapp)
;;   (setq whatsapp-bridge-url   "http://127.0.0.1:7337"
;;         whatsapp-bridge-token "the-same-token-as-WHATSAPPEL_TOKEN")
;;   (global-set-key (kbd "C-c w") whatsapp-prefix-map)
;;
;; M-x whatsapp-connect ; M-x whatsapp-qr (scan) ; M-x whatsapp (chat list).

;;; Code:

(require 'json)
(require 'url)
(require 'url-util)
(require 'subr-x)

(defgroup whatsapp nil
  "telega-style Emacs client for the whatsappel bridge."
  :group 'comm
  :prefix "whatsapp-")

(defcustom whatsapp-bridge-url "http://127.0.0.1:7337"
  "Base URL of the local whatsappel Guile bridge."
  :type 'string)

(defcustom whatsapp-bridge-token nil
  "Shared token; must equal the bridge's WHATSAPPEL_TOKEN.
Sent in the X-Whatsappel-Token header on every request."
  :type '(choice (const :tag "Unset" nil) string))

(defcustom whatsapp-poll-interval 5
  "Seconds between polls when polling is enabled."
  :type 'integer)

(defcustom whatsapp-media-player "xdg-open"
  "External program used to open audio, video and GIF media."
  :type 'string)

(defcustom whatsapp-auto-load-images t
  "When non-nil, download and render inbound images/stickers inline."
  :type 'boolean)

(defcustom whatsapp-chat-prompt "❯ "
  "Prompt shown at the bottom of a chat buffer."
  :type 'string)

(defvar whatsapp--chats nil "Last fetched chat list (root buffer).")
(defvar whatsapp--media-cache (make-hash-table :test 'equal)
  "Cache of downloaded media: message id -> data URI string.")
(defvar whatsapp--poll-timer nil "Active poll timer, or nil.")

(defcustom whatsapp-pq-program "pqenv"
  "Path to the pqenv binary used for post-quantum envelopes."
  :type 'string)

(defcustom whatsapp-pq-dir (expand-file-name "~/.config/whatsappel/pq")
  "Directory holding the PQ identity and imported contact public keys."
  :type 'directory)

(defcustom whatsapp-pq-max-age 604800
  "Reject inbound PQ messages whose timestamp is older/newer than this many
seconds (default 7 days; 0 disables the freshness check). Catches replays of
old captured envelopes; tolerates clock skew and delayed delivery."
  :type 'integer)

(defvar whatsapp-pq--plain-cache (make-hash-table :test 'equal)
  "Cache of decrypted inbound envelopes: message id -> plaintext or :fail.")
(defvar whatsapp-pq--sent-cache (make-hash-table :test 'equal)
  "Cache of plaintext for envelopes this client sent: blob -> plaintext.")

(defvar-local whatsapp-chat--jid nil "JID/number of the chat in this buffer.")
(defvar-local whatsapp-chat--target nil "wuzapi Phone target for this chat.")
(defvar-local whatsapp-chat--input-marker nil "Marker at the start of the input area.")

;;; ---------------------------------------------------------------------------
;;; HTTP + small helpers
;;; ---------------------------------------------------------------------------

(defun whatsapp--request (method path &optional payload)
  "Call the bridge: METHOD (string) PATH, optional PAYLOAD alist.
Return (STATUS . DATA): STATUS the HTTP code or nil, DATA parsed JSON or nil."
  (unless whatsapp-bridge-token
    (user-error "Set `whatsapp-bridge-token' to the bridge's WHATSAPPEL_TOKEN"))
  (let* ((url-request-method method)
         (url-request-extra-headers
          (append (list (cons "X-Whatsappel-Token" whatsapp-bridge-token))
                  (when payload '(("Content-Type" . "application/json")))))
         (url-request-data
          (when payload (encode-coding-string (json-encode payload) 'utf-8)))
         (buf (url-retrieve-synchronously
               (concat whatsapp-bridge-url path) t t 60)))
    (unless buf (user-error "whatsapp: no response from bridge at %s"
                            whatsapp-bridge-url))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (let ((status (and (boundp 'url-http-response-status)
                             url-http-response-status)))
            (if (re-search-forward "\n\r?\n" nil t)
                (let* ((json-object-type 'alist)
                       (json-array-type 'list)
                       (json-key-type 'string)
                       (raw (buffer-substring-no-properties (point) (point-max)))
                       (data (ignore-errors
                               (json-read-from-string
                                (decode-coding-string raw 'utf-8)))))
                  (cons status data))
              (cons status nil))))
      (kill-buffer buf))))

(defun whatsapp--ok-p (status)
  "Non-nil if STATUS is a 2xx HTTP code."
  (and (integerp status) (<= 200 status 299)))

(defun whatsapp--fmt-ts (ts)
  "Format a heterogeneous timestamp TS to HH:MM, best-effort."
  (cond ((not (stringp ts)) "")
        ((string-match "T\\([0-9][0-9]:[0-9][0-9]\\)" ts) (match-string 1 ts))
        ((string-match "\\`[0-9]+\\'" ts)
         (format-time-string "%H:%M" (seconds-to-time (string-to-number ts))))
        (t "")))

(defun whatsapp--guess-mime (file kind)
  "Guess a MIME type for FILE, falling back by KIND."
  (let ((ext (downcase (or (file-name-extension file) ""))))
    (or (cdr (assoc ext '(("png" . "image/png") ("jpg" . "image/jpeg")
                          ("jpeg" . "image/jpeg") ("webp" . "image/webp")
                          ("gif" . "image/gif") ("mp4" . "video/mp4")
                          ("mov" . "video/quicktime") ("ogg" . "audio/ogg")
                          ("opus" . "audio/ogg") ("mp3" . "audio/mpeg")
                          ("m4a" . "audio/mp4") ("wav" . "audio/wav")
                          ("pdf" . "application/pdf"))))
        (pcase kind
          ('image "image/jpeg") ('sticker "image/webp") ('video "video/mp4")
          ('gif "video/mp4") ('audio "audio/ogg") (_ "application/octet-stream")))))

(defun whatsapp--file->data-uri (file mime)
  "Read FILE and return a data: URI string with MIME and base64 payload."
  (concat "data:" mime ";base64,"
          (base64-encode-string
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file)
             (buffer-string))
           t)))

(defun whatsapp--data-uri-mime (uri)
  "Return the MIME type from a data URI string URI."
  (if (string-match "\\`data:\\([^;,]+\\)" uri) (match-string 1 uri)
    "application/octet-stream"))

(defun whatsapp--data-uri-bytes (uri)
  "Return the decoded (unibyte) bytes from a data URI string URI."
  (let ((b64 (if (string-match ",\\(.*\\)\\'" uri) (match-string 1 uri) uri)))
    (base64-decode-string b64)))

(defun whatsapp--image-type-from-mime (mime)
  "Map MIME to an Emacs image type symbol."
  (pcase mime
    ("image/png" 'png) ("image/jpeg" 'jpeg) ("image/gif" 'gif)
    ("image/webp" 'webp) (_ 'png)))

;;; ---------------------------------------------------------------------------
;;; Chat: media, rendering, buffer, input
;;; ---------------------------------------------------------------------------

(defun whatsapp--media-data (id kind media)
  "Download MEDIA (alist of wuzapi fields) of KIND, cache by ID, return data URI."
  (or (and id (gethash id whatsapp--media-cache))
      (let* ((res (whatsapp--request
                   "POST" "/download" (append (list (cons "kind" kind)) media)))
             (top (cdr res))
             (wj  (and (listp top) (cdr (assoc "data" top))))
             (wd  (and (listp wj) (cdr (assoc "data" wj))))
             (uri (and (listp wd) (or (cdr (assoc "Data" wd))
                                      (cdr (assoc "data" wd))))))
        (when (and id (stringp uri)) (puthash id uri whatsapp--media-cache))
        uri)))

(defun whatsapp-chat-open-media-at-point ()
  "Download the media tagged at point and open it with `whatsapp-media-player'."
  (interactive)
  (let ((media (get-text-property (point) 'whatsapp-media))
        (kind  (get-text-property (point) 'whatsapp-kind))
        (id    (get-text-property (point) 'whatsapp-id)))
    (unless media (user-error "No downloadable media on this line"))
    (let ((uri (whatsapp--media-data id kind media)))
      (unless (stringp uri) (user-error "whatsapp: download failed"))
      (let* ((bytes (whatsapp--data-uri-bytes uri))
             (mime  (whatsapp--data-uri-mime uri))
             (ext   (concat "." (or (cadr (split-string mime "/")) "bin")))
             (f     (make-temp-file "whatsapp-media" nil ext)))
        (let ((coding-system-for-write 'binary))
          (with-temp-file f (set-buffer-multibyte nil) (insert bytes)))
        (start-process "whatsapp-media" nil whatsapp-media-player f)
        (message "whatsapp: opened %s in %s" kind whatsapp-media-player)))))

(defvar whatsapp-media-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'whatsapp-chat-open-media-at-point)
    (define-key m (kbd "o")   #'whatsapp-chat-open-media-at-point)
    (define-key m [mouse-1]   #'whatsapp-chat-open-media-at-point)
    (define-key m (kbd "s")   #'whatsapp-chat-save-media)
    (define-key m (kbd "m")   #'whatsapp-chat-message-menu)
    m)
  "Keymap placed on media regions: RET/o/click open, s save, m action menu.")

(defun whatsapp--tag-media (beg end media kind id)
  "Tag region BEG..END with MEDIA, KIND, ID and the media keymap."
  (add-text-properties beg end
                       (list 'whatsapp-media media 'whatsapp-kind kind
                             'whatsapp-id id 'mouse-face 'highlight
                             'keymap whatsapp-media-keymap)))

(defun whatsapp--media-label (kind cap)
  "A textual label for media of KIND with optional caption CAP."
  (concat "[" (or kind "media") "]"
          (if (and cap (> (length cap) 0)) (concat " " cap) "")
          (if (member kind '("video" "audio" "document" "gif"))
              "  (RET/o to open)" "")))

(defcustom whatsapp-image-max-width 400
  "Maximum width (px) for inline images/stickers; nil keeps natural size."
  :type '(choice (const :tag "Natural size" nil) integer) :group 'whatsapp)

(defcustom whatsapp-sticker-max-width 160
  "Maximum width (px) for inline stickers."
  :type '(choice (const :tag "Natural size" nil) integer) :group 'whatsapp)

(defun whatsapp--create-image (bytes type &optional kind)
  "Create an image from BYTES of TYPE, scaled down per KIND, robust to old Emacs."
  (let ((maxw (if (equal kind "sticker") whatsapp-sticker-max-width
                whatsapp-image-max-width)))
    (or (and maxw (ignore-errors
                    (create-image bytes type t :max-width maxw :ascent 'center)))
        (ignore-errors (create-image bytes type t :ascent 'center))
        (create-image bytes type t))))

(defun whatsapp--insert-image (id kind media cap)
  "Insert inbound image/sticker inline; on failure, a retryable label.
The whole region is tagged with MEDIA so RET retries and actions apply."
  (let* ((beg  (point))
         (uri  (whatsapp--media-data id kind media))
         (mime (and uri (whatsapp--data-uri-mime uri)))
         (type (and mime (whatsapp--image-type-from-mime mime))))
    (if (and uri type (image-type-available-p type))
        (insert-image (whatsapp--create-image (whatsapp--data-uri-bytes uri) type kind))
      (insert (if uri
                  (whatsapp--media-label kind cap)
                (format "[%s · indisponível — mídia expirada no WhatsApp · RET p/ tentar]"
                        (or kind "media")))))
    (when media (whatsapp--tag-media beg (point) media kind id))
    (when (and cap (> (length cap) 0)) (insert " " cap))))

(defun whatsapp--insert-message (m)
  "Insert one message alist M into the current chat buffer.
The inserted region carries a `whatsapp-msg' text property holding M, so
companion tools (e.g. `whatsapp-org') can recover the structured message
at point rather than re-parsing the rendered line."
  (let* ((msg-beg (point))
         (me    (cdr (assoc "me" m)))
         (name  (cond (me "me")
                      ((cdr (assoc "name" m)))
                      ((cdr (assoc "from" m)))
                      (t "?")))
         (ts    (cdr (assoc "ts" m)))
         (text  (cdr (assoc "text" m)))
         (kind  (cdr (assoc "kind" m)))
         (cap   (cdr (assoc "caption" m)))
         (id    (cdr (assoc "id" m)))
         (media (cdr (assoc "media" m)))
         (tss   (whatsapp--fmt-ts ts))
         (hdr   (concat (if (> (length tss) 0) (format "[%s] " tss) "")
                        (propertize (concat name ": ")
                                    'face (if me 'font-lock-keyword-face 'bold)))))
    (insert hdr)
    (cond
     ((and (stringp text) (whatsapp--pq-text-p text))
      (whatsapp--insert-pq me text id))
     ((and (stringp text) (> (length text) 0)
           (not (member kind '("image" "sticker"))))
      (insert text))
     ((and (member kind '("image" "sticker")) media whatsapp-auto-load-images)
      (whatsapp--insert-image id kind media cap))
     ((member kind '("image" "sticker" "video" "audio" "document" "gif"))
      (let ((beg (point)))
        (insert (whatsapp--media-label kind cap))
        (when media (whatsapp--tag-media beg (point) media kind id))))
     ((stringp text) (insert text))
     (t (insert "[message]")))
    (insert "\n")
    (add-text-properties msg-beg (point) (list 'whatsapp-msg m))))

;;; ---------------------------------------------------------------------------
;;; Telega-style message actions (react, reply, forward, copy, save, delete)
;;; ---------------------------------------------------------------------------

(defcustom whatsapp-reactions '("👍" "❤️" "😂" "😮" "😢" "🙏" "🔥" "👏")
  "Quick-reaction emojis offered by `whatsapp-chat-react'."
  :type '(repeat string) :group 'whatsapp)

(defun whatsapp--message-at-point ()
  "Return the message alist at point, scanning the line, or signal an error."
  (or (get-text-property (point) 'whatsapp-msg)
      (and (not (bobp)) (get-text-property (1- (point)) 'whatsapp-msg))
      (save-excursion (beginning-of-line) (get-text-property (point) 'whatsapp-msg))
      (user-error "Point is not on a message")))

(defun whatsapp--msg-field (m k) "Field K of message alist M." (cdr (assoc k m)))

(defun whatsapp-chat-react (&optional emoji)
  "React to the message at point with EMOJI (prompted; empty removes it)."
  (interactive)
  (let* ((m  (whatsapp--message-at-point))
         (id (whatsapp--msg-field m "id"))
         (me (whatsapp--msg-field m "me"))
         (emoji (or emoji (completing-read "React (empty = remove): "
                                           whatsapp-reactions nil nil))))
    (unless (stringp id) (user-error "This message has no id to react to"))
    (let ((res (whatsapp--request
                "POST" "/react"
                (append (list (cons "to" whatsapp-chat--target)
                              (cons "id" id) (cons "emoji" emoji))
                        (when me '(("me" . t)))))))
      (if (whatsapp--ok-p (car res))
          (message "whatsapp: %s" (if (string= "" emoji) "reaction removed"
                                    (concat "reacted " emoji)))
        (user-error "whatsapp: react failed: %S" (cdr res))))))

(defun whatsapp-chat-delete-message ()
  "Delete the message at point (for everyone when it is yours)."
  (interactive)
  (let* ((m  (whatsapp--message-at-point))
         (id (whatsapp--msg-field m "id"))
         (me (whatsapp--msg-field m "me")))
    (unless (stringp id) (user-error "This message has no id"))
    (when (yes-or-no-p "Delete this message? ")
      (let ((res (whatsapp--request
                  "POST" "/delete"
                  (append (list (cons "to" whatsapp-chat--target) (cons "id" id))
                          (when me '(("me" . t)))))))
        (if (whatsapp--ok-p (car res))
            (progn (message "whatsapp: deleted") (whatsapp-chat-refresh))
          (user-error "whatsapp: delete failed: %S" (cdr res)))))))

(defun whatsapp-chat-copy-text ()
  "Copy the text/caption of the message at point to the kill ring."
  (interactive)
  (let* ((m (whatsapp--message-at-point))
         (s (or (whatsapp--msg-field m "text") (whatsapp--msg-field m "caption"))))
    (unless (and (stringp s) (> (length s) 0)) (user-error "No text to copy"))
    (kill-new s) (message "whatsapp: copied")))

(defun whatsapp-chat-mark-read ()
  "Mark the message at point (and this chat) as read."
  (interactive)
  (let* ((m (whatsapp--message-at-point)) (id (whatsapp--msg-field m "id")))
    (whatsapp--request "POST" "/markread"
                       (append (list (cons "to" whatsapp-chat--target))
                               (when (stringp id) (list (cons "id" id)))))
    (message "whatsapp: marked read")))

(defun whatsapp-chat-save-media ()
  "Download the media of the message at point and save it to a file."
  (interactive)
  (let* ((m     (whatsapp--message-at-point))
         (media (whatsapp--msg-field m "media"))
         (kind  (whatsapp--msg-field m "kind"))
         (id    (whatsapp--msg-field m "id")))
    (unless media (user-error "No media on this message"))
    (let ((uri (whatsapp--media-data id kind media)))
      (unless (stringp uri)
        (user-error "whatsapp: download failed (media may have expired on WhatsApp)"))
      (let* ((mime  (whatsapp--data-uri-mime uri))
             (ext   (concat "." (or (cadr (split-string mime "/")) "bin")))
             (dest  (read-file-name "Save media to: " nil nil nil
                                    (concat "whatsapp-" (or kind "media") ext))))
        (let ((coding-system-for-write 'binary))
          (with-temp-file dest (set-buffer-multibyte nil)
                          (insert (whatsapp--data-uri-bytes uri))))
        (message "whatsapp: saved to %s" dest)))))

(defun whatsapp--send-media-to (target kind file &optional caption)
  "Send FILE as media of KIND (symbol) to TARGET, optional CAPTION.
Return non-nil on success."
  (let* ((mime (whatsapp--guess-mime file kind))
         (data (whatsapp--file->data-uri file mime))
         (payload (append (list (cons "to" target) (cons "data" data))
                          (when (and caption (> (length caption) 0))
                            (list (cons "caption" caption)))
                          (when (eq kind 'document)
                            (list (cons "filename" (file-name-nondirectory file))))))
         (route (pcase kind
                  ('image "/send/image") ('video "/send/video") ('gif "/send/gif")
                  ('audio "/send/audio") ('document "/send/document")
                  ('sticker "/send/sticker") (_ (user-error "Bad media kind")))))
    (whatsapp--ok-p (car (whatsapp--request "POST" route payload)))))

(defun whatsapp--forward-targets ()
  "Alist of (DISPLAY . JID) from the last fetched chat list."
  (mapcar (lambda (c) (cons (or (cdr (assoc "name" c)) (cdr (assoc "jid" c)))
                            (cdr (assoc "jid" c))))
          (or whatsapp--chats '())))

(defun whatsapp-chat-forward ()
  "Forward the message at point (text or media) to another chat."
  (interactive)
  (let* ((m       (whatsapp--message-at-point))
         (text    (or (whatsapp--msg-field m "text") (whatsapp--msg-field m "caption")))
         (media   (whatsapp--msg-field m "media"))
         (kind    (whatsapp--msg-field m "kind"))
         (id      (whatsapp--msg-field m "id"))
         (targets (whatsapp--forward-targets))
         (choice  (completing-read "Forward to: " (mapcar #'car targets)))
         (jid     (or (cdr (assoc choice targets)) choice))
         (target  (whatsapp--target-of-jid jid)))
    (cond
     (media
      (let ((uri (whatsapp--media-data id kind media)))
        (unless (stringp uri) (user-error "whatsapp: media download failed (expired?)"))
        (let* ((mime (whatsapp--data-uri-mime uri))
               (ext  (concat "." (or (cadr (split-string mime "/")) "bin")))
               (tmp  (make-temp-file "whatsapp-fwd" nil ext)))
          (let ((coding-system-for-write 'binary))
            (with-temp-file tmp (set-buffer-multibyte nil)
                            (insert (whatsapp--data-uri-bytes uri))))
          (if (whatsapp--send-media-to target (intern (or kind "image")) tmp text)
              (message "whatsapp: forwarded to %s" choice)
            (user-error "whatsapp: forward failed")))))
     ((and (stringp text) (> (length text) 0))
      (if (whatsapp--ok-p (car (whatsapp--request
                                "POST" "/send"
                                (list (cons "to" target) (cons "body" text)))))
          (message "whatsapp: forwarded to %s" choice)
        (user-error "whatsapp: forward failed")))
     (t (user-error "Nothing to forward")))))

(defun whatsapp-chat-reply ()
  "Insert a quoted reference to the message at point into the input area.
This is a textual quote (WhatsApp's native quoted-reply context is not wired);
type your reply after it and press RET."
  (interactive)
  (let* ((m   (whatsapp--message-at-point))
         (who (or (whatsapp--msg-field m "name") (whatsapp--msg-field m "from") "?"))
         (txt (or (whatsapp--msg-field m "text") (whatsapp--msg-field m "caption")
                  (format "[%s]" (or (whatsapp--msg-field m "kind") "msg")))))
    (when (and whatsapp-chat--input-marker
               (marker-position whatsapp-chat--input-marker))
      (goto-char (point-max))
      (insert (format "> %s: %s\n" who
                      (truncate-string-to-width (replace-regexp-in-string "\n" " " txt) 80)))
      (message "whatsapp: quote inserted — type your reply, then RET"))))

(defun whatsapp-chat-message-menu ()
  "Telega-style action menu for the message at point."
  (interactive)
  (whatsapp--message-at-point)            ; validate point is on a message
  (pcase (car (read-multiple-choice
               "Message action"
               '((?r "react") (?R "reply") (?f "forward") (?c "copy")
                 (?s "save") (?o "open media") (?d "delete") (?m "mark read"))))
    (?r (whatsapp-chat-react))
    (?R (whatsapp-chat-reply))
    (?f (whatsapp-chat-forward))
    (?c (whatsapp-chat-copy-text))
    (?s (whatsapp-chat-save-media))
    (?o (whatsapp-chat-open-media-at-point))
    (?d (whatsapp-chat-delete-message))
    (?m (whatsapp-chat-mark-read))))

(defun whatsapp--target-of-jid (jid)
  "Return the wuzapi Phone target for chat JID."
  (cond ((string-suffix-p "@g.us" jid) jid)
        ((string-match "\\`\\([^@]+\\)" jid) (match-string 1 jid))
        (t jid)))

(defun whatsapp--chat-buffer (jid)
  "Get or create the chat buffer for JID, set buffer-locals."
  (let ((buf (get-buffer-create (format "*WhatsApp: %s*" jid))))
    (with-current-buffer buf
      (unless (derived-mode-p 'whatsapp-chat-mode) (whatsapp-chat-mode))
      (setq whatsapp-chat--jid jid
            whatsapp-chat--target (whatsapp--target-of-jid jid)))
    buf))

(defun whatsapp-chat--current-input ()
  "Return the text currently typed in the input area."
  (if (and whatsapp-chat--input-marker
           (marker-position whatsapp-chat--input-marker))
      (buffer-substring-no-properties whatsapp-chat--input-marker (point-max))
    ""))

(defun whatsapp-chat--render (messages)
  "Render MESSAGES as read-only history above an editable input prompt."
  (let ((input (whatsapp-chat--current-input))
        (inhibit-read-only t))
    (erase-buffer)
    (let ((hbeg (point)))
      (dolist (m messages) (whatsapp--insert-message m))
      (add-text-properties hbeg (point) '(read-only t front-sticky t)))
    (insert (propertize whatsapp-chat-prompt
                        'read-only t 'rear-nonsticky t 'face 'minibuffer-prompt))
    (setq whatsapp-chat--input-marker (point-marker))
    (set-marker-insertion-type whatsapp-chat--input-marker nil)
    (when (> (length input) 0) (insert input))
    (goto-char (point-max))))

(defun whatsapp-chat-refresh ()
  "Reload this chat's messages from the bridge and re-render."
  (interactive)
  (let* ((res  (whatsapp--request
                "GET" (concat "/chat?jid=" (url-hexify-string whatsapp-chat--jid))))
         (msgs (cdr res)))
    (whatsapp-chat--render (if (listp msgs) msgs '()))))

(defun whatsapp-chat-newline ()
  "Insert a newline in the input area."
  (interactive)
  (insert "\n"))

(defun whatsapp-chat-send-input ()
  "Send the text in the input area to this chat."
  (interactive)
  (let ((input (string-trim (whatsapp-chat--current-input))))
    (if (= (length input) 0)
        (message "whatsapp: nothing to send")
      (let ((res (whatsapp--request
                  "POST" "/send"
                  (list (cons "to" whatsapp-chat--target) (cons "body" input)))))
        (if (whatsapp--ok-p (car res))
            (progn
              (let ((inhibit-read-only t))
                (when (marker-position whatsapp-chat--input-marker)
                  (delete-region whatsapp-chat--input-marker (point-max))))
              (whatsapp-chat-refresh))
          (user-error "whatsapp: send failed: %S" (cdr res)))))))

(defun whatsapp--send-media (kind file &optional caption)
  "Send FILE as media of KIND (a symbol) to the current chat, optional CAPTION."
  (unless whatsapp-chat--target (user-error "Not in a WhatsApp chat buffer"))
  (let* ((mime (whatsapp--guess-mime file kind))
         (data (whatsapp--file->data-uri file mime))
         (payload (append (list (cons "to" whatsapp-chat--target)
                                (cons "data" data))
                          (when (and caption (> (length caption) 0))
                            (list (cons "caption" caption)))
                          (when (eq kind 'document)
                            (list (cons "filename" (file-name-nondirectory file))))))
         (route (pcase kind
                  ('image "/send/image") ('video "/send/video") ('gif "/send/gif")
                  ('audio "/send/audio") ('document "/send/document")
                  ('sticker "/send/sticker") (_ (user-error "Bad media kind")))))
    (let ((res (whatsapp--request "POST" route payload)))
      (if (whatsapp--ok-p (car res))
          (progn (message "whatsapp: %s sent" kind) (whatsapp-chat-refresh))
        (user-error "whatsapp: %s send failed: %S" kind (cdr res))))))

(defun whatsapp-chat-attach-image (file)
  "Attach and send image FILE."
  (interactive "fImage: ")
  (whatsapp--send-media 'image file (read-string "Caption: ")))

(defun whatsapp-chat-attach-video (file)
  "Attach and send video FILE."
  (interactive "fVideo: ")
  (whatsapp--send-media 'video file (read-string "Caption: ")))

(defun whatsapp-chat-attach-audio (file)
  "Attach and send audio FILE."
  (interactive "fAudio: ")
  (whatsapp--send-media 'audio file))

(defun whatsapp-chat-attach-file (file)
  "Attach and send document FILE."
  (interactive "fFile: ")
  (whatsapp--send-media 'document file))

(defun whatsapp-chat-attach-sticker (file)
  "Attach and send a webp sticker FILE."
  (interactive "fSticker (webp): ")
  (whatsapp--send-media 'sticker file))

(defun whatsapp-chat-attach-gif (file)
  "Attach and send a GIF/MP4 FILE (sent as a looping video)."
  (interactive "fGIF/MP4: ")
  (whatsapp--send-media 'gif file))

(defvar whatsapp-chat-attach-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'whatsapp-chat-attach-image)
    (define-key map (kbd "v") #'whatsapp-chat-attach-video)
    (define-key map (kbd "a") #'whatsapp-chat-attach-audio)
    (define-key map (kbd "f") #'whatsapp-chat-attach-file)
    (define-key map (kbd "s") #'whatsapp-chat-attach-sticker)
    (define-key map (kbd "g") #'whatsapp-chat-attach-gif)
    map)
  "Attach submenu, bound to C-c C-a in a chat buffer.")

(defvar whatsapp-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'whatsapp-chat-send-input)
    (define-key map (kbd "C-j")     #'whatsapp-chat-newline)
    (define-key map (kbd "C-c C-a") whatsapp-chat-attach-map)
    (define-key map (kbd "C-c C-l") #'whatsapp-chat-refresh)
    (define-key map (kbd "C-c C-e") #'whatsapp-chat-send-encrypted)
    ;; Telega-style message actions on the message at point.
    (define-key map (kbd "C-c C-m") #'whatsapp-chat-message-menu)
    (define-key map (kbd "C-c r")   #'whatsapp-chat-react)
    (define-key map (kbd "C-c C-r") #'whatsapp-chat-reply)
    (define-key map (kbd "C-c C-f") #'whatsapp-chat-forward)
    (define-key map (kbd "C-c C-w") #'whatsapp-chat-copy-text)
    (define-key map (kbd "C-c C-s") #'whatsapp-chat-save-media)
    (define-key map (kbd "C-c C-d") #'whatsapp-chat-delete-message)
    (define-key map (kbd "C-c C-q") #'quit-window)
    map)
  "Keymap for `whatsapp-chat-mode'.
Plain letter keys are intentionally unbound so they self-insert in the
input area; media commands live on the per-line `whatsapp-media-keymap'.")

(define-derived-mode whatsapp-chat-mode fundamental-mode "WA-Chat"
  "Major mode for a WhatsApp conversation (telega-style)."
  (setq-local truncate-lines nil))

;;; ---------------------------------------------------------------------------
;;; Open a chat
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun whatsapp-open-chat (jid)
  "Open the chat buffer for JID (a number, or a full @g.us group jid)."
  (interactive "sChat (number or jid): ")
  (let ((buf (whatsapp--chat-buffer jid)))
    (with-current-buffer buf (whatsapp-chat-refresh))
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Root (chat list)
;;; ---------------------------------------------------------------------------

(defun whatsapp-root--render (chats)
  "Render CHATS into the current root buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "WhatsApp — chats\n\n" 'face 'bold))
    (if (null chats)
        (insert "No chats yet. M-x whatsapp-connect, scan the QR, then send or receive.\n")
      (dolist (c chats)
        (let* ((jid    (cdr (assoc "jid" c)))
               (name   (or (cdr (assoc "name" c)) jid))
               (unread (or (cdr (assoc "unread" c)) 0))
               (last   (or (cdr (assoc "last" c)) ""))
               (line   (format "%4s  %-24s  %s\n"
                               (if (and (numberp unread) (> unread 0))
                                   (format "(%d)" unread) "")
                               name last)))
          (insert (propertize line 'whatsapp-jid jid 'mouse-face 'highlight)))))
    (goto-char (point-min))))

(defun whatsapp--root-buffer ()
  "Get or create the root chat-list buffer."
  (let ((buf (get-buffer-create "*WhatsApp*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'whatsapp-root-mode) (whatsapp-root-mode)))
    buf))

(defun whatsapp-root-refresh ()
  "Fetch the chat list from the bridge and render it."
  (interactive)
  (let* ((res   (whatsapp--request "GET" "/chats"))
         (chats (cdr res)))
    (setq whatsapp--chats (if (listp chats) chats '()))
    (with-current-buffer (whatsapp--root-buffer)
      (whatsapp-root--render whatsapp--chats))))

(defun whatsapp-root-open-chat ()
  "Open the chat on the current root line."
  (interactive)
  (let ((jid (get-text-property (point) 'whatsapp-jid)))
    (if jid (whatsapp-open-chat jid)
      (user-error "No chat on this line"))))

(defun whatsapp-root-next ()
  "Move to the next chat line."
  (interactive)
  (forward-line 1))

(defun whatsapp-root-prev ()
  "Move to the previous chat line."
  (interactive)
  (forward-line -1))

(defvar whatsapp-root-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'whatsapp-root-open-chat)
    (define-key map (kbd "n")   #'whatsapp-root-next)
    (define-key map (kbd "p")   #'whatsapp-root-prev)
    (define-key map (kbd "g")   #'whatsapp-root-refresh)
    (define-key map (kbd "j")   #'whatsapp-open-chat)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `whatsapp-root-mode'.")

(define-derived-mode whatsapp-root-mode special-mode "WA-Root"
  "Major mode for the WhatsApp chat list (telega-style root buffer).")

;;; ---------------------------------------------------------------------------
;;; Entry, session, polling
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun whatsapp ()
  "Open the WhatsApp chat list."
  (interactive)
  (whatsapp-root-refresh)
  (pop-to-buffer (whatsapp--root-buffer)))

;;;###autoload
(defun whatsapp-connect ()
  "Connect the wuzapi session and register the inbound webhook."
  (interactive)
  (let* ((res (whatsapp--request "POST" "/connect"))
         (data (cdr res))
         (reg (and (listp data) (cdr (assoc "webhook_registered" data)))))
    (message "whatsapp: connect requested%s. If not logged in, run M-x whatsapp-qr"
             (if (eq reg t) " (webhook registered)" ""))))

;;;###autoload
(defun whatsapp-status ()
  "Show connection/login status from the bridge."
  (interactive)
  (message "whatsapp status: %S" (cdr (whatsapp--request "GET" "/status"))))

;;;###autoload
(defun whatsapp-logout ()
  "Log out the WhatsApp session (a new QR scan will be required)."
  (interactive)
  (when (yes-or-no-p "Log out the WhatsApp session? ")
    (whatsapp--request "POST" "/logout")
    (message "whatsapp: logged out")))

;;;###autoload
(defun whatsapp-qr ()
  "Fetch and display the linking QR code from wuzapi."
  (interactive)
  (let* ((res   (whatsapp--request "GET" "/qr"))
         (data  (cdr res))
         (wj    (and (listp data) (cdr (assoc "data" data))))
         (wd    (and (listp wj) (cdr (assoc "data" wj))))
         (qr    (and (listp wd) (cdr (assoc "QRCode" wd)))))
    (unless (stringp qr)
      (user-error "No QR returned (already logged in? run M-x whatsapp-status): %S"
                  data))
    (let* ((b64 (if (string-match ",\\(.*\\)\\'" qr) (match-string 1 qr) qr))
           (png (base64-decode-string b64)))
      (with-current-buffer (get-buffer-create "*whatsapp-qr*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (if (image-type-available-p 'png)
              (insert-image (create-image png 'png t))
            (let ((f (make-temp-file "whatsapp-qr" nil ".png")))
              (let ((coding-system-for-write 'binary))
                (with-temp-file f (set-buffer-multibyte nil) (insert png)))
              (insert (format "QR (no inline image) saved to:\n%s\nOpen and scan." f)))))
        (special-mode)
        (display-buffer (current-buffer))))))

(defvar whatsapp-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "w") #'whatsapp)
    (define-key map (kbd "j") #'whatsapp-open-chat)
    (define-key map (kbd "c") #'whatsapp-connect)
    (define-key map (kbd "s") #'whatsapp-status)
    (define-key map (kbd "Q") #'whatsapp-qr)
    (define-key map (kbd "k") #'whatsapp-pq-keygen)
    (define-key map (kbd "i") #'whatsapp-pq-import-contact)
    (define-key map (kbd "f") #'whatsapp-pq-show-fingerprint)
    map)
  "Prefix map; bind e.g. (global-set-key (kbd \"C-c w\") whatsapp-prefix-map).")

(defun whatsapp--poll ()
  "Refresh the root buffer and any visible chat buffers."
  (when (get-buffer "*WhatsApp*") (ignore-errors (whatsapp-root-refresh)))
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'whatsapp-chat-mode)
                 (get-buffer-window buf)
                 whatsapp-chat--input-marker
                 (>= (point) (marker-position whatsapp-chat--input-marker)))
        (ignore-errors (whatsapp-chat-refresh))))))

;;;###autoload
(defun whatsapp-toggle-polling ()
  "Toggle periodic polling every `whatsapp-poll-interval' seconds."
  (interactive)
  (if whatsapp--poll-timer
      (progn (cancel-timer whatsapp--poll-timer)
             (setq whatsapp--poll-timer nil)
             (message "whatsapp: polling off"))
    (setq whatsapp--poll-timer
          (run-with-timer 0 whatsapp-poll-interval #'whatsapp--poll))
    (message "whatsapp: polling every %ss" whatsapp-poll-interval)))

;;; ---------------------------------------------------------------------------
;;; Post-quantum envelope (pqenv) integration — 1:1 chats
;;; ---------------------------------------------------------------------------

(defun whatsapp--pq-text-p (s)
  "Non-nil if S is a WAPQ1 transport blob."
  (and (stringp s) (string-prefix-p "WAPQ1:" s)))

(defun whatsapp-pq--ensure-dir ()
  "Create the PQ key directory tree."
  (make-directory (expand-file-name "contacts" whatsapp-pq-dir) t))

(defun whatsapp-pq--identity-prefix ()
  (expand-file-name "identity" whatsapp-pq-dir))
(defun whatsapp-pq--identity-secret ()
  (concat (whatsapp-pq--identity-prefix) ".secret"))
(defun whatsapp-pq--identity-public ()
  (concat (whatsapp-pq--identity-prefix) ".public"))
(defun whatsapp-pq--contact-file (jid)
  (expand-file-name (format "contacts/%s.public" jid) whatsapp-pq-dir))
(defun whatsapp-pq--contact-fpr (jid)
  "Path to the stored trusted fingerprint for JID (TOFU pin)."
  (expand-file-name (format "contacts/%s.fpr" jid) whatsapp-pq-dir))
(defun whatsapp-pq-ready-p ()
  "Non-nil if a local PQ identity exists."
  (file-exists-p (whatsapp-pq--identity-secret)))
(defun whatsapp-pq-have-contact-p (jid)
  "Non-nil if a public key for JID has been imported."
  (file-exists-p (whatsapp-pq--contact-file jid)))

(defun whatsapp-pq--run (args &optional infile outfile)
  "Run pqenv with ARGS plus optional --in INFILE / --out OUTFILE. Return exit code."
  (apply #'call-process whatsapp-pq-program nil
         (get-buffer-create "*whatsapp-pq*") nil
         (append args
                 (when infile (list "--in" infile))
                 (when outfile (list "--out" outfile)))))

(defun whatsapp-pq-fingerprint-of (pubfile)
  "Return the pqenv fingerprint string of PUBFILE, or nil."
  (with-temp-buffer
    (when (eq 0 (call-process whatsapp-pq-program nil t nil "fingerprint"
                              (expand-file-name pubfile)))
      (string-trim (buffer-string)))))

;;;###autoload
(defun whatsapp-pq-keygen (&optional force)
  "Generate this device's PQ identity. With prefix arg FORCE, overwrite."
  (interactive "P")
  (whatsapp-pq--ensure-dir)
  (when (and (whatsapp-pq-ready-p) (not force))
    (user-error "PQ identity already exists; C-u to overwrite: %s"
                (whatsapp-pq--identity-secret)))
  (let ((rc (call-process whatsapp-pq-program nil
                          (get-buffer-create "*whatsapp-pq*") nil
                          "keygen" "--out" (whatsapp-pq--identity-prefix))))
    (if (eq rc 0)
        (message "PQ identity ready. Share %s. Fingerprint: %s"
                 (whatsapp-pq--identity-public)
                 (or (whatsapp-pq-fingerprint-of (whatsapp-pq--identity-public)) "?"))
      (user-error "pqenv keygen failed (exit %s); see *whatsapp-pq*" rc))))

;;;###autoload
(defun whatsapp-pq-import-contact (jid file &optional force)
  "Import a contact's public key FILE and associate it with chat JID.
Pins the key's fingerprint on first import (TOFU). A later import of a
*different* key for the same JID is refused unless FORCE (\\[universal-argument]),
since a silent change can mean key substitution. Re-importing the same key,
or rotating with FORCE, updates the pin."
  (interactive
   (list (read-string "Chat (number or jid): "
                      (and (derived-mode-p 'whatsapp-chat-mode) whatsapp-chat--jid))
         (read-file-name "Contact public key (.public): ")
         current-prefix-arg))
  (whatsapp-pq--ensure-dir)
  (let* ((dest (whatsapp-pq--contact-file jid))
         (fpr-file (whatsapp-pq--contact-fpr jid))
         (newfp (whatsapp-pq-fingerprint-of (expand-file-name file))))
    (unless newfp
      (user-error "pqenv could not read a public key from %s" file))
    (when (file-exists-p fpr-file)
      (let ((oldfp (with-temp-buffer
                     (insert-file-contents fpr-file) (string-trim (buffer-string)))))
        (when (and (not (equal oldfp newfp)) (not force))
          (user-error
           "KEY CHANGE for %s — refusing. Pinned %s, new %s. If you re-verified out of band, C-u to override"
           jid (car (split-string oldfp)) (car (split-string newfp))))))
    (make-directory (file-name-directory dest) t)
    (copy-file (expand-file-name file) dest t)
    (with-temp-file fpr-file (insert newfp "\n"))
    (message "Imported key for %s. Verify out-of-band — fingerprint: %s" jid newfp)))

;;;###autoload
(defun whatsapp-pq-show-fingerprint (&optional jid)
  "Show this identity's fingerprint, or that of contact JID with prefix arg."
  (interactive
   (list (when current-prefix-arg
           (read-string "Contact (number or jid): "
                        (and (derived-mode-p 'whatsapp-chat-mode) whatsapp-chat--jid)))))
  (let ((file (if jid (whatsapp-pq--contact-file jid) (whatsapp-pq--identity-public))))
    (unless (file-exists-p file)
      (user-error "No such key: %s" file))
    (message "%s fingerprint: %s" (if jid jid "my identity")
             (or (whatsapp-pq-fingerprint-of file) "?"))))

(defun whatsapp-pq-seal (jid plaintext)
  "Seal PLAINTEXT to contact JID, signed by this identity. Return a WAPQ1 blob."
  (unless (whatsapp-pq-ready-p)
    (user-error "No PQ identity; run M-x whatsapp-pq-keygen"))
  (unless (whatsapp-pq-have-contact-p jid)
    (user-error "No PQ key for %s; run M-x whatsapp-pq-import-contact" jid))
  (let ((inf (make-temp-file "wapq-in")) (outf (make-temp-file "wapq-out")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8))
            (with-temp-file inf (insert plaintext)))
          (let ((rc (whatsapp-pq--run
                     (list "seal" "--recipient" (whatsapp-pq--contact-file jid)
                           "--identity" (whatsapp-pq--identity-secret))
                     inf outf)))
            (unless (eq rc 0) (user-error "pqenv seal failed (exit %s)" rc))
            (with-temp-buffer
              (let ((coding-system-for-read 'utf-8)) (insert-file-contents outf))
              (string-trim (buffer-string)))))
      (ignore-errors (delete-file inf))
      (ignore-errors (delete-file outf)))))

(defun whatsapp-pq-open (jid blob)
  "Verify+decrypt BLOB from contact JID, enforcing the freshness window.
Return the plaintext string, the symbol `stale' if rejected as out-of-window
\(pqenv exit 3), or nil on any other failure."
  (when (and (whatsapp-pq-ready-p) (whatsapp-pq-have-contact-p jid))
    (let ((inf (make-temp-file "wapq-in")) (outf (make-temp-file "wapq-out")))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8))
              (with-temp-file inf (insert blob)))
            (let ((rc (whatsapp-pq--run
                       (append
                        (list "open" "--identity" (whatsapp-pq--identity-secret)
                              "--sender" (whatsapp-pq--contact-file jid))
                        (when (> whatsapp-pq-max-age 0)
                          (list "--max-age" (number-to-string whatsapp-pq-max-age))))
                       inf outf)))
              (cond
               ((eq rc 0)
                (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8)) (insert-file-contents outf))
                  (buffer-string)))
               ((eq rc 3) 'stale)
               (t nil))))
        (ignore-errors (delete-file inf))
        (ignore-errors (delete-file outf))))))

(defun whatsapp--insert-pq (me blob id)
  "Render a WAPQ1 BLOB at point. ME non-nil for outbound messages.
Uses the current chat buffer's `whatsapp-chat--jid' as the peer."
  (let ((jid whatsapp-chat--jid))
    (cond
     (me
      (let ((pt (gethash blob whatsapp-pq--sent-cache)))
        (insert (propertize "[PQ] " 'face 'success))
        (insert (or pt (propertize "[encrypted, sent]" 'face 'shadow)))))
     ((not (whatsapp-pq-ready-p))
      (insert (propertize "[encrypted — M-x whatsapp-pq-keygen]" 'face 'warning)))
     ((not (whatsapp-pq-have-contact-p jid))
      (insert (propertize "[encrypted — M-x whatsapp-pq-import-contact]" 'face 'warning)))
     (t
      (let ((cached (and id (gethash id whatsapp-pq--plain-cache))))
        (cond
         ((eq cached :fail)
          (insert (propertize "[encrypted — decrypt/verify FAILED]" 'face 'error)))
         ((eq cached :stale)
          (insert (propertize "[encrypted — stale/replayed: outside freshness window]"
                              'face 'warning)))
         ((stringp cached)
          (insert (propertize "[PQ] " 'face 'success)) (insert cached))
         (t
          (let ((pt (whatsapp-pq-open jid blob)))
            (cond
             ((stringp pt)
              (when id (puthash id pt whatsapp-pq--plain-cache))
              (insert (propertize "[PQ] " 'face 'success)) (insert pt))
             ((eq pt 'stale)
              (when id (puthash id :stale whatsapp-pq--plain-cache))
              (insert (propertize "[encrypted — stale/replayed: outside freshness window]"
                                  'face 'warning)))
             (t
              (when id (puthash id :fail whatsapp-pq--plain-cache))
              (insert (propertize "[encrypted — decrypt/verify FAILED]"
                                  'face 'error))))))))))))

(defun whatsapp-chat-send-encrypted ()
  "Seal the input to this chat's contact and send it as a WAPQ1 message."
  (interactive)
  (let ((jid whatsapp-chat--jid)
        (input (string-trim (whatsapp-chat--current-input))))
    (when (= (length input) 0) (user-error "Nothing to send"))
    (let ((blob (whatsapp-pq-seal jid input)))
      (let ((res (whatsapp--request
                  "POST" "/send"
                  (list (cons "to" whatsapp-chat--target) (cons "body" blob)))))
        (if (whatsapp--ok-p (car res))
            (progn
              (puthash blob input whatsapp-pq--sent-cache)
              (let ((inhibit-read-only t))
                (when (marker-position whatsapp-chat--input-marker)
                  (delete-region whatsapp-chat--input-marker (point-max))))
              (whatsapp-chat-refresh))
          (user-error "whatsapp: send failed: %S" (cdr res)))))))

(provide 'whatsapp)
;;; whatsapp.el ends here
