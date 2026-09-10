;;; whatsapp.el --- telega-style Emacs WhatsApp client  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-only
;; Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
;;
;; Author: Cristian Cezar Moisés
;; URL: https://codeberg.org/berkeley/whatsappel
;; Version: 3.2.0pre1
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
(require 'url-http)
(require 'subr-x)
(require 'cl-lib)
(require 'button)
(require 'easymenu)

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

(defcustom whatsapp-media-player "mpv"
  "mpv executable used to open audio, video and GIF media.
Arguments disable user scripts and referenced resources; use an mpv-compatible program."
  :type 'string)

(defcustom whatsapp-auto-load-images t
  "When non-nil, lazily load recent inline images in graphical Emacs.
Original bytes are retained; only the displayed preview is scaled."
  :type 'boolean)

(defcustom whatsapp-request-timeout 30
  "Maximum seconds for a bridge request."
  :type 'number)

(defcustom whatsapp-max-file-bytes (* 16 1024 1024)
  "Maximum attachment size before base64 encoding, in bytes.
Keep this below the bridge request limit after base64 overhead."
  :type 'integer)

(defcustom whatsapp-media-cache-max-bytes (* 32 1024 1024)
  "Maximum combined data URI bytes retained in the in-memory media cache."
  :type 'integer)

(defcustom whatsapp-image-prefetch-count 12
  "Maximum recent messages considered for lazy inline image downloads."
  :type 'integer)

(defface whatsapp-title '((t (:inherit bold :height 1.5)))
  "Dashboard and conversation title." :group 'whatsapp)
(defface whatsapp-accent '((t (:inherit success :weight bold)))
  "Active filters, own messages, and unread counts." :group 'whatsapp)
(defface whatsapp-contact '((t (:inherit font-lock-function-name-face :weight bold)))
  "Contact names." :group 'whatsapp)

(defcustom whatsapp-chat-prompt "❯ "
  "Prompt shown at the bottom of a chat buffer."
  :type 'string)

(defvar whatsapp--chats nil "Last fetched chat list (root buffer).")
(defvar whatsapp--media-cache (make-hash-table :test 'equal)
  "Cache of downloaded media: message id -> data URI string.")
(defvar whatsapp--poll-timer nil "Active poll timer, or nil.")
(defvar whatsapp--media-order nil "Least recently used media cache keys first.")
(defvar whatsapp--media-queue nil "Pending lazy media requests.")
(defvar whatsapp--media-pending (make-hash-table :test 'equal))
(defvar whatsapp--media-active 0)
(defvar whatsapp--media-pump-timer nil)
(defvar-local whatsapp--refresh-pending nil)
(defvar-local whatsapp--refresh-again nil)
(defvar-local whatsapp--last-error nil)
(defvar-local whatsapp-chat--messages nil)
(defvar-local whatsapp-root--filter 'all)
(defvar-local whatsapp-root--query "")

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
  "Decrypted envelopes: (JID ID blob) -> plaintext, :stale, or :fail.")
(defvar whatsapp-pq--sent-cache (make-hash-table :test 'equal)
  "Cache of plaintext for envelopes this client sent: blob -> plaintext.")

(defvar-local whatsapp-chat--jid nil "JID/number of the chat in this buffer.")
(defvar-local whatsapp-chat--target nil "wuzapi Phone target for this chat.")
(defvar-local whatsapp-chat--input-marker nil "Marker at the start of the input area.")
(defvar-local whatsapp-chat--reply nil
  "Pending reply target: plist (:id :participant :text :who), or nil.")

(defconst whatsapp-version "3.2.0-rc1" "Workspace release candidate version.")

(defconst whatsapp--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))
(defcustom whatsapp-python-program "python3"
  "Python 3 used for isolated attachment uploads and explicit GIF conversion."
  :type 'string :group 'whatsapp)
(defcustom whatsapp-history-page-size 100
  "Messages initially rendered per conversation; Show older expands the view."
  :type 'integer :group 'whatsapp)
(defcustom whatsapp-image-pixel-limit 16000000
  "Largest canvas decoded by the image preview, in pixels."
  :type 'integer :group 'whatsapp)
(defcustom whatsapp-preview-pixel-budget 16000000
  "Total declared source pixels retained by the eight-entry preview cache."
  :type 'integer :group 'whatsapp)
(defcustom whatsapp-voice-seconds 180
  "Maximum duration of an explicitly started voice recording, in seconds."
  :type 'integer :group 'whatsapp)
(defcustom whatsapp-voice-device "default"
  "PulseAudio input device; PipeWire's PulseAudio server also accepts default."
  :type 'string :group 'whatsapp)
(defcustom whatsapp-workspace-sidebar t
  "Keep a chat-list side window when opening the mouse-first workspace."
  :type 'boolean :group 'whatsapp)
(defvar whatsapp--workspace-active nil)
(defvar whatsapp--preview-cache (make-hash-table :test 'equal))
(defvar whatsapp--preview-order nil)
(defvar whatsapp--media-jobs nil "Owned mpv processes; no private data is logged.")
(defvar-local whatsapp-chat--history-limit nil)
(defvar-local whatsapp-chat--send-pending nil)
(defvar-local whatsapp-chat--redraw-timer nil)
(defvar-local whatsapp--stage-target nil)
(defvar-local whatsapp--stage-origin nil)
(defvar-local whatsapp--stage-file nil)
(defvar-local whatsapp--stage-kind nil)
(defvar-local whatsapp--stage-caption "")
(defvar-local whatsapp--stage-operation nil)
(defvar-local whatsapp--stage-process nil)
(defvar-local whatsapp--stage-owned nil)
(defvar-local whatsapp--stage-error nil)
(defvar-local whatsapp--stage-url nil)
(defvar-local whatsapp--stage-token-id nil)
(defvar-local whatsapp--view-bytes nil)
(defvar-local whatsapp--view-type nil)
(defvar-local whatsapp--view-mime nil)
(defvar-local whatsapp--view-zoom nil)


;;; ---------------------------------------------------------------------------
;;; HTTP + small helpers
;;; ---------------------------------------------------------------------------

(defun whatsapp--validate-bridge ()
  "Validate the destination before transmitting the shared bridge token."
  (unless (and (stringp whatsapp-bridge-token)
               (not (string-empty-p whatsapp-bridge-token))
               (not (string-match-p "[\r\n]" whatsapp-bridge-token)))
    (user-error "Set a nonempty `whatsapp-bridge-token' without line breaks"))
  (let* ((url (url-generic-parse-url whatsapp-bridge-url))
         (scheme (url-type url))
         (host (url-host url)))
    (unless (and (member scheme '("http" "https")) host
                 (not (url-user url)) (not (url-password url))
                 (not (url-target url))
                 (member (url-filename url) '("" "/"))
                 (or (equal scheme "https")
                     (member host '("127.0.0.1" "localhost" "::1" "[::1]"))))
      (user-error "Bridge URL must use loopback HTTP or HTTPS without credentials, path, or query"))))

(defun whatsapp--response ()
  "Parse the current HTTP response, preserving JSON false as nil."
  (goto-char (point-min))
  (let ((status (and (boundp 'url-http-response-status) url-http-response-status)))
    (cons status
          (when (re-search-forward "\r?\n\r?\n" nil t)
            (let ((json-object-type 'alist) (json-array-type 'list)
                  (json-key-type 'string) (json-false nil) (json-null nil))
              (condition-case nil
                  (json-read-from-string
                   (decode-coding-string
                    (buffer-substring-no-properties (point) (point-max)) 'utf-8))
                (error :invalid-json)))))))

(defun whatsapp--request (method path &optional payload)
  "Call METHOD PATH with PAYLOAD; return (STATUS . parsed JSON).
Explicit user actions use this bounded synchronous API for Org compatibility.
Background refresh and inline previews use `whatsapp--request-async'."
  (whatsapp--validate-bridge)
  (let* ((url-request-method method)
         (url-max-redirections 0)
         (url-request-extra-headers
          (append (list (cons "X-Whatsappel-Token" whatsapp-bridge-token))
                  (when payload '(("Content-Type" . "application/json")))))
         (url-request-data
          (when payload (encode-coding-string (json-encode payload) 'utf-8)))
         (buf (url-retrieve-synchronously
               (concat (string-remove-suffix "/" whatsapp-bridge-url) path)
               t t whatsapp-request-timeout)))
    (unless buf (user-error "No response from WhatsApp bridge"))
    (unwind-protect (with-current-buffer buf (whatsapp--response))
      (kill-buffer buf))))

(defun whatsapp--request-async (method path payload callback)
  "Call METHOD PATH with PAYLOAD without blocking Emacs; deliver to CALLBACK.
CALLBACK receives (STATUS . DATA) exactly once, including timeouts/errors.
No redirect may forward the bridge token to a different origin."
  (whatsapp--validate-bridge)
  (let ((url-request-method method)
        (url-max-redirections 0)
        (url-request-extra-headers
         (append (list (cons "X-Whatsappel-Token" whatsapp-bridge-token))
                 (when payload '(("Content-Type" . "application/json")))))
        (url-request-data
         (when payload (encode-coding-string (json-encode payload) 'utf-8)))
        done timer request-buffer)
    (cl-labels ((finish (result)
                 (unless done
                   (setq done t)
                   (when timer (cancel-timer timer))
                   (unwind-protect (funcall callback result)
                     (when (buffer-live-p request-buffer)
                       (kill-buffer request-buffer))))))
      (condition-case err
          (setq request-buffer
                (url-retrieve
                 (concat (string-remove-suffix "/" whatsapp-bridge-url) path)
                 (lambda (_status)
                   (setq request-buffer (current-buffer))
                   (finish (whatsapp--response))) nil t t))
        (error (finish (cons nil (list (cons "error" (error-message-string err)))))))
      (unless done
        (setq timer
              (run-at-time whatsapp-request-timeout nil
                           (lambda ()
                             (finish '(nil ("error" . "Request timed out"))))))))))

(defun whatsapp--ok-p (status)
  "Non-nil if STATUS is a 2xx HTTP code."
  (and (integerp status) (<= 200 status 299)))

(defun whatsapp--fmt-ts (ts)
  "Format ISO, numeric seconds, or numeric milliseconds TS as HH:MM."
  (cond ((numberp ts)
         (format-time-string "%H:%M" (seconds-to-time
                                      (if (> ts 100000000000) (/ ts 1000.0) ts))))
        ((not (stringp ts)) "")
        ((string-match "T\\([0-9][0-9]:[0-9][0-9]\\)" ts) (match-string 1 ts))
        ((string-match-p "\\`[0-9]+\\'" ts) (whatsapp--fmt-ts (string-to-number ts)))
        (t "")))

(defconst whatsapp--mime-types
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("webp" . "image/webp") ("gif" . "image/gif") ("avif" . "image/avif")
    ("heic" . "image/heic") ("heif" . "image/heif") ("svg" . "image/svg+xml")
    ("tif" . "image/tiff") ("tiff" . "image/tiff") ("bmp" . "image/bmp")
    ("mp4" . "video/mp4") ("mov" . "video/quicktime") ("webm" . "video/webm")
    ("mkv" . "video/x-matroska") ("avi" . "video/x-msvideo")
    ("ogg" . "audio/ogg") ("opus" . "audio/ogg") ("mp3" . "audio/mpeg")
    ("m4a" . "audio/mp4") ("aac" . "audio/aac") ("wav" . "audio/wav")
    ("flac" . "audio/flac") ("pdf" . "application/pdf") ("txt" . "text/plain")
    ("md" . "text/markdown") ("csv" . "text/csv") ("json" . "application/json")
    ("xml" . "application/xml") ("zip" . "application/zip") ("gz" . "application/gzip")
    ("tar" . "application/x-tar") ("xz" . "application/x-xz")
    ("7z" . "application/x-7z-compressed") ("epub" . "application/epub+zip")
    ("doc" . "application/msword") ("xls" . "application/vnd.ms-excel")
    ("ppt" . "application/vnd.ms-powerpoint")
    ("docx" . "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    ("xlsx" . "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    ("pptx" . "application/vnd.openxmlformats-officedocument.presentationml.presentation")
    ("odt" . "application/vnd.oasis.opendocument.text")
    ("ods" . "application/vnd.oasis.opendocument.spreadsheet")
    ("odp" . "application/vnd.oasis.opendocument.presentation")
    ("vcf" . "text/vcard") ("ics" . "text/calendar")))

(defun whatsapp--guess-mime (file _kind)
  "Guess FILE's MIME type; unknown formats remain binary documents."
  (or (cdr (assoc (downcase (or (file-name-extension file) "")) whatsapp--mime-types))
      "application/octet-stream"))

(defun whatsapp--safe-media-kind (kind mime)
  "Return a conservative transport for KIND and MIME without conversion.
Unsupported preview formats travel as original documents. GIF video needs MP4;
a GIF file is never mislabeled as an MP4. Looping and codecs depend on upstream."
  (if (pcase kind
        ('image (member mime '("image/jpeg" "image/png")))
        ('sticker (equal mime "image/webp"))
        ((or 'video 'gif) (equal mime "video/mp4"))
        ('audio (member mime '("audio/ogg" "audio/mpeg" "audio/mp4" "audio/aac")))
        ('document t))
      kind 'document))

(defun whatsapp--validate-file (file)
  "Reject unreadable, remote, nonregular, or oversized FILE before encoding."
  (unless (and (not (file-remote-p file)) (file-regular-p file) (file-readable-p file))
    (user-error "Choose a readable local regular file"))
  (when (> (file-attribute-size (file-attributes file)) whatsapp-max-file-bytes)
    (user-error "Attachment exceeds the configured %s MiB limit"
                (/ whatsapp-max-file-bytes 1048576.0))))

(defun whatsapp--file->data-uri (file mime)
  "Read FILE and return a data: URI string with MIME and base64 payload."
  (whatsapp--validate-file file)
  (concat "data:" mime ";base64,"
          (base64-encode-string
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file nil 0 (1+ whatsapp-max-file-bytes))
             (when (> (buffer-size) whatsapp-max-file-bytes)
               (user-error "Attachment grew beyond the configured limit"))
             (buffer-string))
           t)))

(defun whatsapp--data-uri-mime (uri)
  "Return the MIME type from a data URI string URI."
  (if (string-match "\\`data:\\([^;,]+\\)" uri) (match-string 1 uri)
    "application/octet-stream"))

(defun whatsapp--data-uri-bytes (uri)
  "Decode a bounded strict base64 data URI, rejecting oversized media first."
  (unless (and (stringp uri)
               (<= (string-bytes uri) (+ 256 (* 4 (/ (+ whatsapp-max-file-bytes 2) 3))))
               (string-match "\\`data:[A-Za-z0-9.+/-]+;base64,\\([A-Za-z0-9+/]*=*\\)\\'" uri))
    (user-error "Invalid or oversized media data URI"))
  (let ((bytes (base64-decode-string (match-string 1 uri))))
    (when (> (string-bytes bytes) whatsapp-max-file-bytes)
      (user-error "Media exceeds the configured size limit"))
    bytes))

(defun whatsapp--image-type-from-mime (mime)
  "Map MIME to an Emacs image type symbol."
  (pcase mime
    ("image/png" 'png) ("image/jpeg" 'jpeg) ("image/gif" 'gif)
    ("image/webp" 'webp) (_ nil)))

;;; ---------------------------------------------------------------------------
;;; Chat: media, rendering, buffer, input
;;; ---------------------------------------------------------------------------

(defun whatsapp--media-key (id kind)
  "Namespace ID by account, origin, chat and media KIND."
  (list whatsapp-bridge-url (secure-hash 'sha256 (or whatsapp-bridge-token ""))
        whatsapp-chat--jid id kind))

(defun whatsapp--cache-get (key)
  "Read KEY and update media recency."
  (when-let ((value (gethash key whatsapp--media-cache)))
    (setq whatsapp--media-order (append (delete key whatsapp--media-order) (list key)))
    value))

(defun whatsapp--cache-put (key value)
  "Cache VALUE under KEY, evicting oldest entries to honor the byte budget."
  (when (and (stringp value) (<= (string-bytes value) whatsapp-media-cache-max-bytes))
    (puthash key value whatsapp--media-cache)
    (setq whatsapp--media-order (append (delete key whatsapp--media-order) (list key)))
    (let ((bytes 0))
      (maphash (lambda (_k v) (cl-incf bytes (string-bytes v))) whatsapp--media-cache)
      (while (and (> bytes whatsapp-media-cache-max-bytes) whatsapp--media-order)
        (let* ((old (pop whatsapp--media-order)) (v (gethash old whatsapp--media-cache)))
          (when v (cl-decf bytes (string-bytes v)))
          (remhash old whatsapp--media-cache)
          (remhash old whatsapp--preview-cache)
          (setq whatsapp--preview-order (delete old whatsapp--preview-order)))))))

(defun whatsapp-clear-caches ()
  "Discard downloaded media and cached decrypted/sent plaintext from memory."
  (interactive)
  (clrhash whatsapp--media-cache)
  (clrhash whatsapp--preview-cache)
  (setq whatsapp--preview-order nil)
  (let (finished)
    (maphash (lambda (k v) (when (eq v 'done) (push k finished))) whatsapp--media-pending)
    (dolist (k finished) (remhash k whatsapp--media-pending)))
  (clrhash whatsapp-pq--plain-cache)
  (clrhash whatsapp-pq--sent-cache)
  (setq whatsapp--media-order nil)
  (message "WhatsApp caches cleared"))

(defun whatsapp--download-uri (result)
  "Extract a data URI from a successful bridge RESULT."
  (when (whatsapp--ok-p (car result))
    (let* ((top (cdr result)) (wj (and (listp top) (cdr (assoc "data" top))))
           (wd (and (listp wj) (cdr (assoc "data" wj))))
           (uri (and (listp wd) (or (cdr (assoc "Data" wd)) (cdr (assoc "data" wd))))))
      (and (stringp uri) (string-prefix-p "data:" uri) uri))))

(defun whatsapp--media-data (id kind media)
  "Download MEDIA of KIND on explicit request; cache with chat-scoped ID."
  (let ((key (whatsapp--media-key id kind)))
    (or (and id (whatsapp--cache-get key))
        (let ((uri (whatsapp--download-uri
                    (whatsapp--request "POST" "/download"
                                       (append (list (cons "kind" kind)) media)))))
          (when (and id uri) (whatsapp--cache-put key uri))
          uri))))

(defun whatsapp--queue-image (id kind media)
  "Queue one lazy preview identified by ID, KIND, and MEDIA."
  (let ((key (whatsapp--media-key id kind)))
    (when (and id (not (gethash key whatsapp--media-cache))
               (not (gethash key whatsapp--media-pending)))
      (when (> (hash-table-count whatsapp--media-pending) 256)
        (let (finished)
          (maphash (lambda (k v) (when (eq v 'done) (push k finished))) whatsapp--media-pending)
          (dolist (k finished) (remhash k whatsapp--media-pending))))
      (puthash key 'queued whatsapp--media-pending)
      (setq whatsapp--media-queue
            (append whatsapp--media-queue (list (list key kind media (current-buffer)))))
      (unless whatsapp--media-pump-timer
        (setq whatsapp--media-pump-timer (run-at-time 0 nil #'whatsapp--media-pump))))))

(defun whatsapp--media-pump ()
  "Download at most two previews at once, redrawing only live chat buffers."
  (setq whatsapp--media-pump-timer nil)
  (while (and whatsapp--media-queue (< whatsapp--media-active 2))
    (pcase-let ((`(,key ,kind ,media ,buffer) (pop whatsapp--media-queue)))
      (if (not (buffer-live-p buffer))
          (remhash key whatsapp--media-pending)
        (puthash key 'active whatsapp--media-pending)
        (cl-incf whatsapp--media-active)
        (condition-case nil
            (whatsapp--request-async
             "POST" "/download" (append (list (cons "kind" kind)) media)
             (lambda (result)
               (cl-decf whatsapp--media-active)
               (puthash key 'done whatsapp--media-pending)
               ;; Keep failure/over-budget markers until explicit retry: polling
               ;; must not repeatedly fetch expired or enormous media.
               (when-let ((uri (whatsapp--download-uri result)))
                 (whatsapp--cache-put key uri)
                 (when (and (buffer-live-p buffer) (gethash key whatsapp--media-cache))
                   (with-current-buffer buffer
                     (whatsapp--schedule-media-redraw))))
               (whatsapp--media-pump)))
          (error (puthash key 'done whatsapp--media-pending)
                 (cl-decf whatsapp--media-active)))))))

(defun whatsapp--media-suffix (mime)
  "Return a safe local suffix for MIME, never a path from remote input."
  (concat "." (or (car (rassoc mime whatsapp--mime-types)) "bin")))

(defun whatsapp-chat-open-media-at-point (&optional event)
  "Open the selected original media asynchronously; EVENT selects the clicked message."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (when event (mouse-set-point event))
  (let* ((m (whatsapp--message-at-point)) (media (whatsapp--msg-field m "media"))
         (kind (whatsapp--msg-field m "kind")) (id (whatsapp--msg-field m "id"))
         (key (whatsapp--media-key id kind)) (cached (whatsapp--cache-get key))
         (buffer (current-buffer)))
    (unless media (user-error "No downloadable media on this message"))
    (if cached (whatsapp--open-uri cached kind)
      (when (memq (gethash key whatsapp--media-pending) '(opening active queued))
        (user-error "This media download is in progress; click again when its preview appears"))
      (puthash key 'opening whatsapp--media-pending)
      (condition-case err
          (whatsapp--request-async
           "POST" "/download" (append (list (cons "kind" kind)) media)
           (lambda (result)
             (remhash key whatsapp--media-pending)
             (let ((uri (whatsapp--download-uri result)))
               (if (not uri) (message "WhatsApp: media unavailable; use Retry or check the connection")
                 (whatsapp--cache-put key uri)
                 (when (buffer-live-p buffer)
                   (condition-case nil
                       (whatsapp--open-uri uri kind)
                     (error (message "WhatsApp: no safe preview; use Save original on the message"))))))))
        (error (remhash key whatsapp--media-pending) (signal (car err) (cdr err)))))))

(defvar whatsapp-media-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'whatsapp-chat-open-media-at-point)
    (define-key m (kbd "o")   #'whatsapp-chat-open-media-at-point)
    (define-key m [mouse-1]   #'whatsapp-chat-open-media-at-point)
    (define-key m (kbd "s")   #'whatsapp-chat-save-media)
    (define-key m (kbd "R")   #'whatsapp-chat-retry-media)
    (define-key m (kbd "m")   #'whatsapp-chat-message-menu)
    m)
  "Keymap on media regions: RET/o/click open, s save, R retry expired, m menu.")

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
  "Insert cached original media as a scaled preview, otherwise a lazy label."
  (let* ((beg (point)) (uri (whatsapp--cache-get (whatsapp--media-key id kind)))
         (type (and uri (whatsapp--image-type-from-mime (whatsapp--data-uri-mime uri)))))
    (if (and uri type (display-graphic-p) (image-type-available-p type))
        (condition-case nil
            (insert-image (whatsapp--preview-image (whatsapp--media-key id kind) uri type kind))
          (error (insert (format "[%s · open or save original]" kind))))
      (insert (format "[%s · RET to open · C-c C-s to save]" kind)))
    (when media (whatsapp--tag-media beg (point) media kind id))
    (when (and (stringp cap) (not (string-empty-p cap))) (insert " " cap))))

(defun whatsapp--insert-message (m)
  "Insert one message alist M into the current chat buffer.
The inserted region carries a `whatsapp-msg' text property holding M, so
companion tools (e.g. `whatsapp-org') can recover the structured message
at point rather than re-parsing the rendered line."
  (let* ((msg-beg (point))
         (me    (eq t (cdr (assoc "me" m))))
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
         (reply (cdr (assoc "reply" m)))
         (tss   (whatsapp--fmt-ts ts))
         (hdr (propertize (concat name "  ")
                          'face (if me 'whatsapp-accent 'whatsapp-contact))))
    (insert hdr (propertize tss 'face 'shadow) "  ")
    (insert-text-button "Actions…" 'follow-link t 'help-echo "React, reply, forward, save, or delete"
                        'action (lambda (button)
                                  (goto-char (button-start button))
                                  (whatsapp-chat-message-menu)))
    (insert "\n")
    (when (and (stringp reply) (> (length reply) 0))
      (insert (propertize
               (format "↳ %s\n%s"
                       (truncate-string-to-width
                        (replace-regexp-in-string "\n" " " reply) 70)
                       (make-string (length (if (> (length tss) 0)
                                                (format "[%s] " tss) "")) ?\s))
               'face 'font-lock-comment-face)))
    (cond
     ((and (stringp text) (whatsapp--pq-text-p text))
      (whatsapp--insert-pq me text id))
     ((and (stringp text) (> (length text) 0)
           (not (member kind '("image" "sticker" "audio" "video" "document" "gif"))))
      (insert text))
     ((and (member kind '("image" "sticker")) media whatsapp-auto-load-images)
      (whatsapp--insert-image id kind media cap))
     ((member kind '("image" "sticker" "video" "audio" "document" "gif"))
      (let ((beg (point)))
        (insert (whatsapp--media-label kind cap))
        (when media (whatsapp--tag-media beg (point) media kind id))))
     ((stringp text) (insert text))
     (t (insert "[message]")))
    (insert "\n\n")
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
         (me (eq t (whatsapp--msg-field m "me")))
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
         (me (eq t (whatsapp--msg-field m "me"))))
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
    (unless (whatsapp--ok-p
             (car (whatsapp--request "POST" "/markread"
                                     (append (list (cons "to" whatsapp-chat--target))
                                             (when (stringp id) (list (cons "id" id)))))))
      (user-error "Mark read failed"))
    (message "whatsapp: marked read")))

(defun whatsapp-sync (&optional jid)
  "Re-import chats/history from wuzapi.  With JID, only re-import that chat."
  (interactive)
  (unless (whatsapp--ok-p (car (whatsapp--request "POST" "/sync" (when jid (list (cons "jid" jid))))))
    (user-error "History synchronization failed"))
  (when (derived-mode-p 'whatsapp-chat-mode) (whatsapp-chat-refresh))
  (message "whatsapp: synced%s" (if jid (format " (%s)" jid) "")))

(defun whatsapp-chat-retry-media ()
  "Ask the sender to re-upload the (expired) media of the message at point.
Best-effort: the sender must be online and still have the media.  A few seconds
later this chat is re-synced so you can open the media again (RET)."
  (interactive)
  (let* ((m   (whatsapp--message-at-point))
         (id  (whatsapp--msg-field m "id"))
         (jid whatsapp-chat--jid)
         (buf (current-buffer)))
    (unless (and (stringp id) (whatsapp--msg-field m "media"))
      (user-error "No media to retry on this message"))
    (let ((res (whatsapp--request "POST" "/mediaretry" (list (cons "id" id)))))
      (unless (whatsapp--ok-p (car res))
        (user-error "whatsapp: media retry request failed: %S" (cdr res)))
      (when id
        (let ((key (whatsapp--media-key id (whatsapp--msg-field m "kind"))))
          (remhash key whatsapp--media-cache)
          (remhash key whatsapp--media-pending)))
      (message "whatsapp: re-upload requested — re-syncing this chat in ~8s…")
      (run-at-time
       8 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (ignore-errors (whatsapp-sync jid))
             (message "whatsapp: re-synced — open the media again with RET"))))))))

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
             (ext   (whatsapp--media-suffix mime))
             (dest  (read-file-name "Save media to: " nil nil nil
                                    (concat "whatsapp-" (or kind "media") ext))))
        (when (and (file-exists-p dest)
                   (not (yes-or-no-p (format "Overwrite %s? " dest))))
          (user-error "Save cancelled"))
        (let ((coding-system-for-write 'binary))
          (with-temp-file dest (set-buffer-multibyte nil)
                          (insert (whatsapp--data-uri-bytes uri))))
        (message "whatsapp: saved to %s" dest)))))

(defun whatsapp--send-media-to (target kind file &optional caption)
  "Send FILE to TARGET using KIND, with optional CAPTION.
Unsupported inline formats fall back to original documents. No resizing,
transcoding, compression, or MIME relabeling is performed by this client."
  (let* ((mime (whatsapp--guess-mime file kind))
         (transport (whatsapp--safe-media-kind kind mime))
         (data (whatsapp--file->data-uri file mime))
         (payload (append (list (cons "to" target) (cons "data" data)
                                (cons "mimetype" mime))
                          (when (and caption (> (length caption) 0))
                            (list (cons "caption" caption)))
                          (when (eq transport 'document)
                            (list (cons "filename" (file-name-nondirectory file))))))
         (route (concat "/send/" (symbol-name transport))))
    (when (not (eq kind transport))
      (message "Sending %s as an original document; inline transport does not support %s"
               (file-name-nondirectory file) mime))
    (whatsapp--ok-p (car (whatsapp--request "POST" route payload)))))

(defun whatsapp--forward-targets ()
  "Unambiguous (DISPLAY . JID) choices from the latest chat list."
  (mapcar (lambda (c)
            (let ((jid (cdr (assoc "jid" c))))
              (cons (format "%s  <%s>" (or (cdr (assoc "name" c)) jid) jid) jid)))
          whatsapp--chats))

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
               (ext  (whatsapp--media-suffix mime))
               (tmp  (make-temp-file "whatsapp-fwd" nil ext)))
          (unwind-protect
              (progn
                (let ((coding-system-for-write 'binary))
                  (with-temp-file tmp (set-buffer-multibyte nil)
                                  (insert (whatsapp--data-uri-bytes uri))))
                (if (whatsapp--send-media-to target (intern (or kind "document")) tmp text)
                    (message "whatsapp: forwarded to %s" choice)
                  (user-error "whatsapp: forward failed")))
            (ignore-errors (delete-file tmp))))))
     ((and (stringp text) (> (length text) 0))
      (if (whatsapp--ok-p (car (whatsapp--request
                                "POST" "/send"
                                (list (cons "to" target) (cons "body" text)))))
          (message "whatsapp: forwarded to %s" choice)
        (user-error "whatsapp: forward failed")))
     (t (user-error "Nothing to forward")))))

(defun whatsapp-chat-reply ()
  "Set the message at point as the reply target for the next send.
Sends a native WhatsApp quoted reply when the author's JID is known (an inbound
message); otherwise the quote is shown locally but not threaded server-side."
  (interactive)
  (let* ((m    (whatsapp--message-at-point))
         (id   (whatsapp--msg-field m "id"))
         (me   (eq t (whatsapp--msg-field m "me")))
         (from (whatsapp--msg-field m "from"))
         (who  (or (whatsapp--msg-field m "name") from "?"))
         (txt  (or (whatsapp--msg-field m "text") (whatsapp--msg-field m "caption")
                   (format "[%s]" (or (whatsapp--msg-field m "kind") "msg"))))
         (part (and (not me) (stringp from) (string-match-p "@" from) from)))
    (unless (stringp id) (user-error "This message has no id to reply to"))
    (setq whatsapp-chat--reply
          (list :id id :participant part
                :text (replace-regexp-in-string "\n" " " txt) :who who))
    (whatsapp-chat--render whatsapp-chat--messages)
    (goto-char (point-max))
    (message "whatsapp: replying to %s%s — type, then RET (C-c C-k cancels)"
             who (if part "" "  [local quote — author JID unknown]"))))

(defun whatsapp-chat-cancel-reply ()
  "Clear the pending reply target."
  (interactive)
  (setq whatsapp-chat--reply nil)
  (whatsapp-chat--render whatsapp-chat--messages)
  (goto-char (point-max))
  (message "whatsapp: reply cancelled"))

(defun whatsapp-chat-message-menu ()
  "Telega-style action menu for the message at point."
  (interactive)
  (whatsapp--message-at-point)            ; validate point is on a message
  (pcase (car (read-multiple-choice
               "Message action"
               '((?r "react") (?y "reply") (?f "forward") (?c "copy")
                 (?s "save") (?o "open media") (?t "retry media")
                 (?d "delete") (?m "mark read"))))
    (?r (whatsapp-chat-react))
    (?y (whatsapp-chat-reply))
    (?f (whatsapp-chat-forward))
    (?c (whatsapp-chat-copy-text))
    (?s (whatsapp-chat-save-media))
    (?o (whatsapp-chat-open-media-at-point))
    (?t (whatsapp-chat-retry-media))
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

(defun whatsapp--button (label command &optional help)
  "Insert a keyboard-accessible LABEL that calls COMMAND, with HELP text."
  (insert-text-button label 'follow-link t 'help-echo (or help label)
                      'action (lambda (_button) (call-interactively command)))
  (insert "   "))

(defun whatsapp--chat-name (jid)
  "Resolve JID to its latest display name."
  (or (cdr (assoc "name" (cl-find jid whatsapp--chats
                                 :key (lambda (c) (cdr (assoc "jid" c))) :test #'equal)))
      jid "WhatsApp"))

(defun whatsapp-chat--position (pos)
  "Capture POS relative to the draft or the containing message."
  (let ((input (and whatsapp-chat--input-marker
                    (marker-position whatsapp-chat--input-marker))))
    (if (and input (>= pos input)) (list 'input (- pos input))
      (let ((m (get-text-property pos 'whatsapp-msg)))
        (if (and m (cdr (assoc "id" m)))
            (list 'message (cdr (assoc "id" m))
                  (- pos (or (previous-single-property-change (1+ pos) 'whatsapp-msg)
                             (point-min))))
          (list 'absolute pos))))))

(defun whatsapp-chat--restore-position (saved)
  "Resolve SAVED to a valid position after a render."
  (min (point-max)
       (max (point-min)
            (pcase saved
              (`(input ,offset) (+ (marker-position whatsapp-chat--input-marker) offset))
              (`(message ,id ,offset)
               (let ((p (point-min)) found)
                 (while (and (< p (point-max)) (not found))
                   (when (equal id (cdr (assoc "id" (get-text-property p 'whatsapp-msg))))
                     (setq found p))
                   (setq p (next-single-property-change p 'whatsapp-msg nil (point-max))))
                 (if found (+ found offset) (point-min))))
              (`(absolute ,position) position)
              (_ (point-max))))))

(defun whatsapp-chat--render (messages)
  "Render MESSAGES without losing draft, message position, or window scroll."
  (let* ((input (whatsapp-chat--current-input))
         (limit (max 1 (or whatsapp-chat--history-limit whatsapp-history-page-size)))
         (visible (last messages limit))
         (initial (not whatsapp-chat--input-marker))
         (saved-point (whatsapp-chat--position (point)))
         (windows (mapcar (lambda (w)
                            (list w (whatsapp-chat--position (window-start w))
                                  (whatsapp-chat--position (window-point w))))
                          (get-buffer-window-list (current-buffer) nil t)))
         (inhibit-read-only t))
    (setq whatsapp-chat--messages messages)
    (erase-buffer)
    (insert (propertize (concat (whatsapp--chat-name whatsapp-chat--jid) "\n")
                        'face 'whatsapp-title))
    (insert (propertize (format "%s  ·  %d messages\n\n" whatsapp-chat--jid (length messages))
                        'face 'shadow))
    (whatsapp--button "Chats" #'whatsapp)
    (whatsapp--button "Attach…" #'whatsapp-chat-attach)
    (whatsapp--button "Original file…" #'whatsapp-chat-attach-original
                      "Send original bytes as a document, without photo recompression")
    (whatsapp--button "Refresh" #'whatsapp-chat-refresh)
    (whatsapp--button "Commands…" #'whatsapp-command-menu)
    (insert "\n\n")
    (unless messages
      (insert (propertize "Your conversation starts here. Type below, then press Enter.\n\n"
                          'face 'shadow)))
    (when (> (length messages) limit)
      (insert (propertize (format "Showing the latest %d of %d retained messages.  "
                                  limit (length messages)) 'face 'shadow))
      (whatsapp--button "Show older" #'whatsapp-chat-show-older)
      (insert "\n\n"))
    (dolist (m visible) (whatsapp--insert-message m))
    (insert (propertize "\nCompose  ·  Enter sends  ·  C-j adds a line\n" 'face 'shadow))
    (whatsapp--button (if whatsapp-chat--send-pending "Sending…" "Send") #'whatsapp-chat-send-input)
    (whatsapp--button "Image…" #'whatsapp-chat-attach-image)
    (whatsapp--button "Video…" #'whatsapp-chat-attach-video)
    (whatsapp--button "GIF…" #'whatsapp-chat-attach-gif)
    (whatsapp--button "Record voice" #'whatsapp-chat-record-voice)
    (whatsapp--button "File…" #'whatsapp-chat-attach-original)
    (whatsapp--button "Encrypted send" #'whatsapp-chat-send-encrypted)
    (insert "\n")
    (when whatsapp-chat--reply
      (insert (propertize
               (format "↳ %s: %s  ·  C-c C-k cancels\n"
                       (plist-get whatsapp-chat--reply :who)
                       (truncate-string-to-width (or (plist-get whatsapp-chat--reply :text) "") 70))
               'face 'shadow)))
    (insert (propertize whatsapp-chat-prompt 'face 'minibuffer-prompt))
    (add-text-properties (point-min) (point) '(read-only t front-sticky (read-only)))
    (add-text-properties (1- (point)) (point) '(rear-nonsticky t))
    (setq whatsapp-chat--input-marker (copy-marker (point) nil))
    (insert input)
    (goto-char (if initial (point-max) (whatsapp-chat--restore-position saved-point)))
    (dolist (saved windows)
      (when (window-live-p (car saved))
        (set-window-start (car saved) (whatsapp-chat--restore-position (nth 1 saved)) t)
        (set-window-point (car saved) (whatsapp-chat--restore-position (nth 2 saved)))))
    (set-buffer-modified-p nil)
    (when (and whatsapp-auto-load-images (display-graphic-p))
      (dolist (m (last messages (max 0 whatsapp-image-prefetch-count)))
        (let ((kind (cdr (assoc "kind" m))) (media (cdr (assoc "media" m))))
          (when (and media (member kind '("image" "sticker")))
            (whatsapp--queue-image (cdr (assoc "id" m)) kind media)))))))

(defun whatsapp--refresh (path render current)
  "Asynchronously refresh PATH using RENDER, comparing against CURRENT data.
Only one request per buffer may run; explicit refresh queues one follow-up."
  (if whatsapp--refresh-pending
      (when (called-interactively-p 'any) (setq whatsapp--refresh-again t))
    (setq whatsapp--refresh-pending t)
    (let ((buffer (current-buffer)))
      (condition-case err
          (whatsapp--request-async
           "GET" path nil
           (lambda (result)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq whatsapp--refresh-pending nil)
                 (if (and (whatsapp--ok-p (car result))
                          (listp (cdr result))
                          (cl-every #'listp (cdr result)))
                     (progn
                       (setq whatsapp--last-error nil)
                       (unless (equal (cdr result) (funcall current))
                         (funcall render (cdr result))))
                   (setq whatsapp--last-error
                         (format "Refresh failed (HTTP %s); existing history retained"
                                 (or (car result) "unavailable")))
                   (message "WhatsApp: %s" whatsapp--last-error))
                 (force-mode-line-update)
                 (when whatsapp--refresh-again
                   (setq whatsapp--refresh-again nil)
                   (whatsapp--refresh path render current))))))
        (error (setq whatsapp--refresh-pending nil)
               (setq whatsapp--last-error (error-message-string err))
               (message "WhatsApp: %s" whatsapp--last-error))))))

(defun whatsapp-chat-refresh (&optional after-send)
  "Refresh this chat asynchronously, preserving draft and scroll.
AFTER-SEND requests a follow-up if an older request is still running."
  (interactive)
  (unless whatsapp-chat--jid (user-error "Open a WhatsApp chat first"))
  (when (and whatsapp--refresh-pending (or after-send (called-interactively-p 'any)))
    (setq whatsapp--refresh-again t))
  (unless whatsapp-chat--input-marker (whatsapp-chat--render nil))
  (whatsapp--refresh
   (concat "/chat?jid=" (url-hexify-string whatsapp-chat--jid))
   #'whatsapp-chat--render (lambda () whatsapp-chat--messages)))

(defun whatsapp-chat-return ()
  "Activate the current button/message, or send text when inside the draft."
  (interactive)
  (cond ((button-at (point)) (push-button))
        ((and whatsapp-chat--input-marker (>= (point) whatsapp-chat--input-marker))
         (whatsapp-chat-send-input))
        ((get-text-property (point) 'whatsapp-media) (whatsapp-chat-open-media-at-point))
        ((get-text-property (point) 'whatsapp-msg) (whatsapp-chat-message-menu))
        (t (goto-char (point-max)))))

(defun whatsapp-chat-newline ()
  "Insert a newline in the input area."
  (interactive)
  (insert "\n"))

(defun whatsapp--send-accepted-p (result)
  "Require the bridge to confirm a successful upstream send, not just HTTP 200."
  (and (whatsapp--ok-p (car result)) (listp (cdr result))
       (let ((upstream (cdr (assoc "wuzapi_status" (cdr result)))))
         (and (integerp upstream) (<= 200 upstream) (< upstream 300)))))

(defun whatsapp-chat-send-input ()
  "Send the draft asynchronously once; preserve edits made during the request."
  (interactive)
  (when whatsapp-chat--send-pending (user-error "A send is already in progress"))
  (unless whatsapp-chat--target (user-error "Open a WhatsApp conversation first"))
  (let* ((original (whatsapp-chat--current-input)) (input (string-trim original))
         (reply whatsapp-chat--reply) (buffer (current-buffer))
         (payload (append (list (cons "to" whatsapp-chat--target) (cons "body" input))
                          (when (and reply (plist-get reply :participant))
                            (list (cons "reply_id" (plist-get reply :id))
                                  (cons "reply_participant" (plist-get reply :participant))
                                  (cons "reply_text" (or (plist-get reply :text) "")))))))
    (unless (string-empty-p input)
      (when (> (length input) 65536) (user-error "Message exceeds the 65536-character limit"))
      (setq whatsapp-chat--send-pending t)
      (force-mode-line-update)
      (condition-case err
          (whatsapp--request-async
           "POST" "/send" payload
           (lambda (result)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq whatsapp-chat--send-pending nil)
                 (if (whatsapp--send-accepted-p result)
                     (progn
                       (when (equal reply whatsapp-chat--reply) (setq whatsapp-chat--reply nil))
                       ;; Never delete newer text typed while this send was in flight.
                       (when (equal original (whatsapp-chat--current-input))
                         (let ((inhibit-read-only t))
                           (delete-region whatsapp-chat--input-marker (point-max))))
                       (whatsapp-chat-refresh t)
                       (message "WhatsApp: message accepted by the bridge"))
                   (setq whatsapp--last-error "Delivery unconfirmed. Draft retained; check chat before retrying.")
                   (message "WhatsApp: %s" whatsapp--last-error))
                 (force-mode-line-update)))))
        (error (setq whatsapp-chat--send-pending nil)
               (force-mode-line-update) (signal (car err) (cdr err)))))))

(defun whatsapp--send-media (kind file &optional caption)
  "Stage FILE of KIND with CAPTION; uploading requires the visible Send button."
  (unless whatsapp-chat--target (user-error "Open a WhatsApp conversation first"))
  (whatsapp--validate-file file)
  (when (file-symlink-p file) (user-error "Choose a regular file, not a symbolic link"))
  (whatsapp--stage-create kind (expand-file-name file) caption))

(defun whatsapp-chat-attach-original (file)
  "Stage FILE as an original document, including full-resolution photos.
The document transport avoids WhatsApp's photo recompression."
  (interactive "fOriginal file: ")
  (whatsapp--send-media 'document file))

(defun whatsapp-chat-attach (file &optional original)
  "Choose FILE and a compatible attachment format; ORIGINAL forces document."
  (interactive (list (read-file-name "Attach file: " nil nil t) current-prefix-arg))
  (whatsapp--validate-file file)
  (let* ((mime (whatsapp--guess-mime file 'document))
         (suggested (cond ((string-prefix-p "image/" mime) 'image)
                          ((string-prefix-p "audio/" mime) 'audio)
                          ((string-prefix-p "video/" mime) 'video)
                          (t 'document)))
         (kind (whatsapp--safe-media-kind suggested mime))
         (choice (if (or original (eq kind 'document)) "Original file"
                   (completing-read "Send as: "
                                    (list "Original file" (format "%s preview" (capitalize (symbol-name kind))))
                                    nil t nil nil "Original file"))))
    (whatsapp--send-media (if (equal choice "Original file") 'document kind) file)))

(defun whatsapp-command-menu ()
  "Offer discoverable commands appropriate for the dashboard or current chat."
  (interactive)
  (let* ((commands
          (append
           (when (derived-mode-p 'whatsapp-chat-mode)
             '(("Attach any file…" . whatsapp-chat-attach)
               ("Send original / full-resolution image…" . whatsapp-chat-attach-original)
               ("Send draft" . whatsapp-chat-send-input)
               ("Message actions…" . whatsapp-chat-message-menu)
               ("Refresh conversation" . whatsapp-chat-refresh)))
           '(("Open conversation…" . whatsapp-open-chat)
             ("All conversations" . whatsapp) ("Connect account" . whatsapp-connect)
             ("Show linking QR" . whatsapp-qr) ("Connection status" . whatsapp-status)
             ("Toggle automatic refresh" . whatsapp-toggle-polling)
             ("Import chats/history" . whatsapp-sync) ("Clear media and plaintext caches" . whatsapp-clear-caches)
             ("Customize WhatsAppel" . whatsapp-customize))))
         (choice (completing-read "WhatsApp command: " commands nil t)))
    (call-interactively (cdr (assoc choice commands)))))

(defun whatsapp-customize ()
  "Open the native customization interface for WhatsAppel."
  (interactive)
  (customize-group 'whatsapp))

(defun whatsapp-chat-attach-image (file)
  "Choose image FILE for the Preview/Send attachment stage."
  (interactive "fImage: ")
  (whatsapp--send-media 'image file))

(defun whatsapp-chat-attach-video (file)
  "Choose video FILE for the Preview/Send attachment stage."
  (interactive "fVideo: ")
  (whatsapp--send-media 'video file))

(defun whatsapp-chat-attach-audio (file)
  "Choose audio FILE for the Preview/Send attachment stage."
  (interactive "fAudio: ")
  (whatsapp--send-media 'audio file))

(defun whatsapp-chat-attach-file (file)
  "Choose document FILE for the explicit Send attachment stage."
  (interactive "fFile: ")
  (whatsapp--send-media 'document file))

(defun whatsapp-chat-attach-sticker (file)
  "Choose WebP sticker FILE for the Preview/Send attachment stage."
  (interactive "fSticker (webp): ")
  (whatsapp--send-media 'sticker file))

(defun whatsapp-chat-attach-gif (file)
  "Send MP4 FILE as video, or a raw GIF as an original document.
Looping playback depends on upstream support."
  (interactive "fGIF/MP4: ")
  (whatsapp--send-media 'gif file))

(defvar whatsapp-chat-attach-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'whatsapp-chat-attach-image)
    (define-key map (kbd "?") #'whatsapp-chat-attach)
    (define-key map (kbd "o") #'whatsapp-chat-attach-original)
    (define-key map (kbd "v") #'whatsapp-chat-attach-video)
    (define-key map (kbd "a") #'whatsapp-chat-attach-audio)
    (define-key map (kbd "f") #'whatsapp-chat-attach-file)
    (define-key map (kbd "s") #'whatsapp-chat-attach-sticker)
    (define-key map (kbd "g") #'whatsapp-chat-attach-gif)
    (define-key map (kbd "r") #'whatsapp-chat-record-voice)
    map)
  "Attach submenu, bound to C-c C-a in a chat buffer.")

(defvar whatsapp-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'whatsapp-chat-return)
    (define-key map (kbd "C-j")     #'whatsapp-chat-newline)
    (define-key map (kbd "C-c ?") #'whatsapp-command-menu)
    (define-key map (kbd "C-c a") #'whatsapp-chat-attach)
    (define-key map (kbd "C-c C-a") whatsapp-chat-attach-map)
    (define-key map (kbd "C-c C-l") #'whatsapp-chat-refresh)
    (define-key map (kbd "C-c C-e") #'whatsapp-chat-send-encrypted)
    ;; Telega-style message actions on the message at point.
    (define-key map (kbd "C-c C-m") #'whatsapp-chat-message-menu)
    (define-key map (kbd "C-c r")   #'whatsapp-chat-react)
    (define-key map (kbd "C-c C-r") #'whatsapp-chat-reply)
    (define-key map (kbd "C-c C-k") #'whatsapp-chat-cancel-reply)
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
  (setq-local truncate-lines nil)
  (setq-local line-spacing 0.18)
  (setq-local mode-line-process
              '(:eval (cond (whatsapp-chat--send-pending " · sending")
                            (whatsapp--refresh-pending " · refreshing")
                            (whatsapp--last-error " · offline"))))
  (setq-local header-line-format " WhatsAppel  ·  C-c ? commands  ·  C-c C-a attach  ·  C-c C-l refresh"))

;;; ---------------------------------------------------------------------------
;;; Open a chat
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun whatsapp-open-chat (jid)
  "Open the chat buffer for JID (a number, or a full @g.us group jid)."
  (interactive
   (let* ((targets (whatsapp--forward-targets))
          (choice (completing-read "Open chat (name or number): " targets nil nil)))
     (list (or (cdr (assoc choice targets)) choice))))
  (when (string-empty-p (string-trim jid)) (user-error "Enter a chat number or JID"))
  (let ((buf (whatsapp--chat-buffer jid)))
    (with-current-buffer buf (whatsapp-chat-refresh))
    (if (and whatsapp--workspace-active whatsapp-workspace-sidebar (> (frame-width) 90))
        (progn
          (display-buffer-in-side-window (whatsapp--root-buffer)
                                         '((side . left) (slot . 0) (window-width . 34)))
          (when-let ((main (cl-find-if (lambda (window)
                                        (not (window-parameter window 'window-side)))
                                      (window-list))))
            (select-window main))
          (switch-to-buffer buf))
      (pop-to-buffer buf))))

;;; ---------------------------------------------------------------------------
;;; Root (chat list)
;;; ---------------------------------------------------------------------------

(defun whatsapp-root-set-filter (filter)
  "Show chats matching FILTER, one of all, unread, or groups."
  (setq whatsapp-root--filter filter)
  (whatsapp-root--render whatsapp--chats))

(defun whatsapp-root-search (query)
  "Filter known chat names, JIDs, and message previews by literal QUERY."
  (interactive (list (read-string "Find chat: " whatsapp-root--query)))
  (setq whatsapp-root--query query)
  (whatsapp-root--render whatsapp--chats))

(defun whatsapp-root--visible-p (chat)
  "Whether CHAT matches the active dashboard filters."
  (and (pcase whatsapp-root--filter
         ('unread (> (or (cdr (assoc "unread" chat)) 0) 0))
         ('groups (string-suffix-p "@g.us" (or (cdr (assoc "jid" chat)) "")))
         (_ t))
       (or (string-empty-p whatsapp-root--query)
           (let ((case-fold-search t))
             (string-match-p (regexp-quote whatsapp-root--query)
                             (format "%s %s %s" (cdr (assoc "name" chat))
                                     (cdr (assoc "jid" chat)) (cdr (assoc "last" chat))))))))

(defvar whatsapp-root-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'whatsapp-root-click)
    (define-key map (kbd "RET") #'whatsapp-root-open-chat)
    map))

(defun whatsapp-root--render (chats)
  "Render CHATS as native buttons with unread, group, and search filters."
  (let ((inhibit-read-only t)
        (jid-at-point (get-text-property (point) 'whatsapp-jid))
        (old-point (point))
        (visible (cl-remove-if-not #'whatsapp-root--visible-p chats)))
    (erase-buffer)
    (insert (propertize (format "WhatsAppel %s\n" whatsapp-version) 'face 'whatsapp-title))
    (insert (propertize (format "%d conversations  ·  %d unread\n\n"
                                (length chats)
                                (cl-count-if (lambda (c) (> (or (cdr (assoc "unread" c)) 0) 0)) chats))
                        'face 'shadow))
    (whatsapp--button "New chat…" #'whatsapp-open-chat)
    (whatsapp--button "Search…" #'whatsapp-root-search)
    (whatsapp--button "Refresh" #'whatsapp-root-refresh)
    (whatsapp--button "Commands…" #'whatsapp-command-menu)
    (insert "\n\n")
    (dolist (item '((all . "All") (unread . "Unread") (groups . "Groups")))
      (let ((filter (car item)))
        (insert-text-button (format " %s " (cdr item)) 'follow-link t
                            'face (if (eq filter whatsapp-root--filter) 'whatsapp-accent 'button)
                            'action (lambda (_b) (whatsapp-root-set-filter filter)))
        (insert "  ")))
    (unless (string-empty-p whatsapp-root--query)
      (insert (format "  Search: %s  " whatsapp-root--query))
      (insert-text-button "Clear" 'follow-link t
                          'action (lambda (_b) (whatsapp-root-search ""))))
    (insert "\n\n")
    (if (null visible)
        (progn
          (insert (if chats "No conversations match this filter.\n\n"
                    "Connect your account to start chatting.\n\n"))
          (whatsapp--button "Connect" #'whatsapp-connect)
          (whatsapp--button "Show QR" #'whatsapp-qr)
          (whatsapp--button "Connection status" #'whatsapp-status)
          (insert "\n"))
      (dolist (c visible)
        (let* ((beg (point)) (jid (cdr (assoc "jid" c)))
               (name (or (cdr (assoc "name" c)) jid "Unknown"))
               (unread (or (cdr (assoc "unread" c)) 0))
               (preview (replace-regexp-in-string "[\r\n]+" " " (or (cdr (assoc "last" c)) ""))))
          (insert (propertize (format " %s  " (upcase (substring name 0 (min 2 (length name)))))
                              'face 'whatsapp-accent))
          (insert-text-button name 'follow-link t 'face 'whatsapp-contact
                              'action (lambda (_b) (whatsapp-open-chat jid)))
          (when (> unread 0) (insert (propertize (format "  [%d]" unread) 'face 'whatsapp-accent)))
          (insert (propertize (format "   %s\n" (whatsapp--fmt-ts (cdr (assoc "ts" c)))) 'face 'shadow))
          (insert "     " (truncate-string-to-width preview 90 nil nil "…") "\n\n")
          (add-text-properties beg (point) (list 'whatsapp-jid jid 'mouse-face 'highlight
                                                'keymap whatsapp-root-row-map)))))
    (insert (propertize "Enter opens  ·  / searches  ·  ? commands  ·  Tab visits buttons\n" 'face 'shadow))
    (goto-char (or (and jid-at-point (whatsapp-root--chat-position jid-at-point))
                   (min old-point (point-max)))))
  (set-buffer-modified-p nil))

(defun whatsapp--root-buffer ()
  "Get or create the root chat-list buffer."
  (let ((buf (get-buffer-create "*WhatsApp*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'whatsapp-root-mode) (whatsapp-root-mode)))
    buf))

(defun whatsapp-root-refresh ()
  "Refresh the dashboard asynchronously; keep existing chats on failure."
  (interactive)
  (with-current-buffer (whatsapp--root-buffer)
    (when (= (buffer-size) 0) (whatsapp-root--render whatsapp--chats))
    (whatsapp--refresh "/chats"
                       (lambda (chats) (setq whatsapp--chats chats)
                         (whatsapp-root--render chats))
                       (lambda () whatsapp--chats))))

(defun whatsapp-root-open-chat ()
  "Open the chat on the current root line."
  (interactive)
  (let ((jid (get-text-property (point) 'whatsapp-jid)))
    (if jid (whatsapp-open-chat jid)
      (user-error "No chat on this line"))))

(defun whatsapp-root--chat-position (jid)
  "Find the row for JID using string equality across separate refreshes."
  (let ((p (point-min)) found)
    (while (and (< p (point-max)) (not found))
      (when (equal jid (get-text-property p 'whatsapp-jid)) (setq found p))
      (setq p (next-single-property-change p 'whatsapp-jid nil (point-max))))
    found))

(defun whatsapp-root-next ()
  "Move to the next conversation card."
  (interactive)
  (let ((p (point)) (jid (get-text-property (point) 'whatsapp-jid)) found)
    (while (and (< p (point-max)) (not found))
      (setq p (next-single-property-change p 'whatsapp-jid nil (point-max)))
      (let ((next (get-text-property p 'whatsapp-jid)))
        (when (and next (not (equal jid next))) (setq found p))))
    (when found (goto-char found))))

(defun whatsapp-root-prev ()
  "Move to the previous conversation card."
  (interactive)
  (let ((p (point)) (jid (get-text-property (point) 'whatsapp-jid)) found)
    (while (and (> p (point-min)) (not found))
      (setq p (1- p))
      (let ((previous (get-text-property p 'whatsapp-jid)))
        (when (and previous (not (equal jid previous))) (setq found previous)))
      (unless found
        (setq p (or (previous-single-property-change (1+ p) 'whatsapp-jid) (point-min)))))
    (when found (goto-char (whatsapp-root--chat-position found)))))

(defvar whatsapp-root-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'whatsapp-root-open-chat)
    (define-key map (kbd "n")   #'whatsapp-root-next)
    (define-key map (kbd "p")   #'whatsapp-root-prev)
    (define-key map (kbd "g")   #'whatsapp-root-refresh)
    (define-key map (kbd "/") #'whatsapp-root-search)
    (define-key map (kbd "?") #'whatsapp-command-menu)
    (define-key map (kbd "j")   #'whatsapp-open-chat)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `whatsapp-root-mode'.")

(define-derived-mode whatsapp-root-mode special-mode "WA-Root"
  "Major mode for the WhatsApp chat list (telega-style root buffer)."
  (setq-local line-spacing 0.18)
  (setq-local mode-line-process
              '(:eval (cond (whatsapp--refresh-pending " · refreshing")
                            (whatsapp--last-error " · offline")))))

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
    (unless (whatsapp--ok-p (car res)) (user-error "Connection request failed"))
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
    (unless (whatsapp--ok-p (car (whatsapp--request "POST" "/logout")))
      (user-error "Logout failed"))
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
    (define-key map (kbd "S") #'whatsapp-sync)
    (define-key map (kbd "Q") #'whatsapp-qr)
    (define-key map (kbd "k") #'whatsapp-pq-keygen)
    (define-key map (kbd "i") #'whatsapp-pq-import-contact)
    (define-key map (kbd "f") #'whatsapp-pq-show-fingerprint)
    map)
  "Prefix map; bind e.g. (global-set-key (kbd \"C-c w\") whatsapp-prefix-map).")

(defun whatsapp--poll ()
  "Refresh visible buffers only; pending requests never overlap."
  (dolist (buf (buffer-list))
    (when (get-buffer-window buf t)
      (with-current-buffer buf
        (cond ((derived-mode-p 'whatsapp-chat-mode) (whatsapp-chat-refresh))
              ((derived-mode-p 'whatsapp-root-mode) (whatsapp-root-refresh)))))))

;;;###autoload
(defun whatsapp-toggle-polling ()
  "Toggle periodic polling every `whatsapp-poll-interval' seconds."
  (interactive)
  (unless (and (numberp whatsapp-poll-interval) (>= whatsapp-poll-interval 1))
    (user-error "Polling interval must be at least one second"))
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
  (make-directory (expand-file-name "contacts" whatsapp-pq-dir) t)
  (set-file-modes whatsapp-pq-dir #o700)
  (set-file-modes (expand-file-name "contacts" whatsapp-pq-dir) #o700))

(defun whatsapp-pq--identity-prefix ()
  (expand-file-name "identity" whatsapp-pq-dir))
(defun whatsapp-pq--identity-secret ()
  (concat (whatsapp-pq--identity-prefix) ".secret"))
(defun whatsapp-pq--identity-public ()
  (concat (whatsapp-pq--identity-prefix) ".public"))
(defun whatsapp-pq--validate-jid (jid)
  "Reject unsafe contact filenames in JID before accessing key files."
  (unless (and (stringp jid)
               (string-match-p "\\`[A-Za-z0-9_.+@-]+\\'" jid))
    (user-error "Invalid contact JID for a PQ key filename")))

(defun whatsapp-pq--contact-file (jid)
  (whatsapp-pq--validate-jid jid)
  (expand-file-name (format "contacts/%s.public" jid) whatsapp-pq-dir))
(defun whatsapp-pq--contact-fpr (jid)
  "Path to the stored trusted fingerprint for JID (TOFU pin)."
  (whatsapp-pq--validate-jid jid)
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

(defun whatsapp-pq--cache-put (key value table)
  "Store KEY and VALUE in TABLE, keeping at most 256 plaintext entries."
  (unless (gethash key table)
    (when (>= (hash-table-count table) 256)
      (let (oldest)
        (maphash (lambda (k _v) (unless oldest (setq oldest k))) table)
        (remhash oldest table))))
  (puthash key value table))

(defun whatsapp--insert-pq (me blob id)
  "Render a WAPQ1 BLOB at point. ME non-nil for outbound messages.
Uses the current chat buffer's `whatsapp-chat--jid' as the peer."
  (let* ((jid whatsapp-chat--jid)
         (cache-key (list jid id blob)))
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
      (let ((cached (and id (gethash cache-key whatsapp-pq--plain-cache))))
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
              (when id (whatsapp-pq--cache-put cache-key pt whatsapp-pq--plain-cache))
              (insert (propertize "[PQ] " 'face 'success)) (insert pt))
             ((eq pt 'stale)
              (when id (whatsapp-pq--cache-put cache-key :stale whatsapp-pq--plain-cache))
              (insert (propertize "[encrypted — stale/replayed: outside freshness window]"
                                  'face 'warning)))
             (t
              (when id (whatsapp-pq--cache-put cache-key :fail whatsapp-pq--plain-cache))
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
              (whatsapp-pq--cache-put blob input whatsapp-pq--sent-cache)
              (let ((inhibit-read-only t))
                (when (marker-position whatsapp-chat--input-marker)
                  (delete-region whatsapp-chat--input-marker (point-max))))
              (whatsapp-chat-refresh t))
          (user-error "whatsapp: send failed: %S" (cdr res)))))))

(easy-menu-define whatsapp-chat-menu whatsapp-chat-mode-map
  "WhatsApp conversation menu."
  '("WhatsApp"
    ["Commands…" whatsapp-command-menu t]
    ["Attach any file…" whatsapp-chat-attach t]
    ["Send original / high-quality image…" whatsapp-chat-attach-original t]
    ["Send draft" whatsapp-chat-send-input t]
    "--"
    ["Message actions…" whatsapp-chat-message-menu t]
    ["Refresh" whatsapp-chat-refresh t]
    ["All conversations" whatsapp t]
    ["Settings…" whatsapp-customize t]))

(easy-menu-define whatsapp-root-menu whatsapp-root-mode-map
  "WhatsApp dashboard menu."
  '("WhatsApp"
    ["New conversation…" whatsapp-open-chat t]
    ["Search…" whatsapp-root-search t]
    ["Commands…" whatsapp-command-menu t]
    ["Connect" whatsapp-connect t]
    ["Show QR" whatsapp-qr t]
    ["Refresh" whatsapp-root-refresh t]
    ["Automatic refresh" whatsapp-toggle-polling :style toggle :selected whatsapp--poll-timer]
    ["Settings…" whatsapp-customize t]))

;;; ---------------------------------------------------------------------------
;;; 3.2 workspace: bounded rendering, owned media jobs, and explicit send preview
;;; ---------------------------------------------------------------------------

(defun whatsapp-chat-show-older ()
  "Expand the visible history without discarding the current draft."
  (interactive)
  (setq whatsapp-chat--history-limit
        (+ (or whatsapp-chat--history-limit (max 1 whatsapp-history-page-size))
           (max 1 whatsapp-history-page-size)))
  (whatsapp-chat--render whatsapp-chat--messages))

(defun whatsapp--schedule-media-redraw ()
  "Coalesce preview completions into one delayed repaint per live buffer."
  (unless whatsapp-chat--redraw-timer
    (let ((buffer (current-buffer)))
      (setq whatsapp-chat--redraw-timer
            (run-at-time
             0.12 nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq whatsapp-chat--redraw-timer nil)
                   (whatsapp-chat--render whatsapp-chat--messages)))))))))

(defun whatsapp--uint (bytes offset count &optional little)
  "Read COUNT bytes of unsigned integer at OFFSET in BYTES."
  (when (> (+ offset count) (length bytes)) (error "Truncated image header"))
  (let ((n 0))
    (dotimes (i count n)
      (setq n (+ (ash n 8) (aref bytes (+ offset (if little (- count 1 i) i))))))))

(defun whatsapp--image-dimensions (bytes type)
  "Read PNG, JPEG or static WebP canvas dimensions without native decoding.
Return (WIDTH . HEIGHT), or nil for unsupported, animated or malformed data."
  (condition-case nil
      (pcase type
        ('png (when (and (>= (length bytes) 24)
                         (equal (substring bytes 0 8) (unibyte-string 137 80 78 71 13 10 26 10))
                         (equal (substring bytes 12 16) "IHDR"))
                (cons (whatsapp--uint bytes 16 4) (whatsapp--uint bytes 20 4))))
        ('jpeg
         (when (and (>= (length bytes) 4)
                    (= (aref bytes 0) 255) (= (aref bytes 1) 216))
           (let ((i 2) found stop)
             (while (and (not found) (not stop) (< (+ i 3) (length bytes)))
               (if (/= (aref bytes i) 255) (setq stop t)
                 (while (and (< i (length bytes)) (= (aref bytes i) 255)) (cl-incf i))
                 (let ((marker (aref bytes i)))
                   (cl-incf i)
                   (cond
                    ((memq marker '(217 218)) (setq stop t))
                    ((or (= marker 1) (<= 208 marker 216)))
                    (t
                     (let ((size (whatsapp--uint bytes i 2)))
                       (when (or (< size 2) (> (+ i size) (length bytes)))
                         (error "Invalid JPEG segment"))
                       (when (memq marker '(192 193 194 195 197 198 199 201 202 203 205 206 207))
                         (when (< size 8) (error "Invalid JPEG frame"))
                         (setq found (cons (whatsapp--uint bytes (+ i 5) 2)
                                           (whatsapp--uint bytes (+ i 3) 2))))
                       (cl-incf i size)))))))
             found)))
        ('webp
         (when (and (>= (length bytes) 30) (equal (substring bytes 0 4) "RIFF")
                    (equal (substring bytes 8 12) "WEBP"))
           (pcase (substring bytes 12 16)
             ("VP8X" (when (= 0 (logand (aref bytes 20) 2))
                       (cons (1+ (whatsapp--uint bytes 24 3 t))
                             (1+ (whatsapp--uint bytes 27 3 t)))))
             ("VP8L" (when (= (aref bytes 20) 47)
                       (let ((bits (whatsapp--uint bytes 21 4 t)))
                         (cons (1+ (logand bits #x3fff))
                               (1+ (logand (ash bits -14) #x3fff))))))
             ("VP8 " (when (equal (substring bytes 23 26) (unibyte-string 157 1 42))
                       (cons (logand (whatsapp--uint bytes 26 2 t) #x3fff)
                             (logand (whatsapp--uint bytes 28 2 t) #x3fff))))))))
    (error nil)))

(defun whatsapp--checked-image-pixels (bytes type)
  "Reject unknown or oversized canvases before invoking an image decoder."
  (let ((dimensions (whatsapp--image-dimensions bytes type)))
    (unless (and dimensions (> (car dimensions) 0) (> (cdr dimensions) 0)
                 (<= (car dimensions) 16384) (<= (cdr dimensions) 16384)
                 (<= (* (car dimensions) (cdr dimensions)) whatsapp-image-pixel-limit))
      (user-error "Preview unavailable or canvas too large; save the original instead"))
    (* (car dimensions) (cdr dimensions))))

(defun whatsapp--preview-image (key uri type kind)
  "Reuse a decoded preview for KEY, preserving original URI bytes."
  (let ((entry (gethash key whatsapp--preview-cache)))
    (unless (and entry (equal uri (nth 0 entry)))
      (remhash key whatsapp--preview-cache)
      (setq whatsapp--preview-order (delete key whatsapp--preview-order))
      (let* ((bytes (whatsapp--data-uri-bytes uri))
             (pixels (whatsapp--checked-image-pixels bytes type))
             (image (whatsapp--create-image bytes type kind)))
        (setq entry (list uri image pixels))
        (when (<= pixels whatsapp-preview-pixel-budget)
          (puthash key entry whatsapp--preview-cache))))
    (when (gethash key whatsapp--preview-cache)
      (setq whatsapp--preview-order (append (delete key whatsapp--preview-order) (list key))))
    (let ((pixels 0))
      (maphash (lambda (_k v) (cl-incf pixels (nth 2 v))) whatsapp--preview-cache)
      (while (and whatsapp--preview-order
                  (or (> pixels whatsapp-preview-pixel-budget)
                      (> (hash-table-count whatsapp--preview-cache) 8)))
        (let* ((old (pop whatsapp--preview-order)) (value (gethash old whatsapp--preview-cache)))
          (when value (cl-decf pixels (nth 2 value)))
          (remhash old whatsapp--preview-cache))))
    (nth 1 entry)))

(defun whatsapp--media-environment ()
  "Do not pass bridge tokens or TLS debug logging to media subprocesses."
  (cl-remove-if (lambda (entry)
                  (string-match-p "\\`\\(?:WHATSAPPEL_TOKEN\\|WUZAPI_TOKEN\\|SSLKEYLOGFILE\\|FFREPORT\\)=" entry))
                process-environment))

(defun whatsapp--private-directory ()
  "Create an owned media job directory."
  (let ((dir (make-temp-file "whatsappel-job-" t)))
    (set-file-modes dir #o700)
    dir))

(defun whatsapp--private-write (directory bytes suffix)
  "Write BYTES inside our DIRECTORY with a trusted SUFFIX and mode 0600."
  (let ((file (expand-file-name (concat "media" suffix) directory))
        (coding-system-for-write 'no-conversion))
    (with-temp-file file (set-buffer-multibyte nil) (insert bytes))
    (set-file-modes file #o600)
    file))

(defun whatsapp--mpv-command (file &optional loop)
  "Build an mpv argument vector for owned local FILE, never a shell command."
  (append (list whatsapp-media-player "--no-config" "--load-scripts=no" "--ytdl=no"
                "--access-references=no" "--sub-auto=no" "--audio-file-auto=no"
                "--demuxer-lavf-o=protocol_whitelist=file" "--keep-open=no"
                "--force-window=yes" "--osc=yes")
          (when loop '("--loop-file=inf")) (list "--" file)))

(defun whatsapp--play-bytes (bytes mime &optional loop)
  "Play an owned snapshot of BYTES in mpv; remove it when that player exits."
  (unless (executable-find whatsapp-media-player)
    (user-error "Install mpv and set whatsapp-media-player to its executable"))
  (let* ((process-environment (whatsapp--media-environment))
         (dir (whatsapp--private-directory))
         (file (whatsapp--private-write dir bytes (whatsapp--media-suffix mime))) proc)
    (condition-case err
        (progn
          (setq proc
                (make-process
                 :name "whatsappel-mpv" :buffer nil :noquery t :connection-type 'pipe
                 :command (whatsapp--mpv-command file loop)
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (setq whatsapp--media-jobs (delq process whatsapp--media-jobs))
                     (ignore-errors (delete-directory dir t))
                     (when (/= (process-exit-status process) 0)
                       (message "WhatsApp: mpv failed; verify the installed mpv version and file format"))))))
          (push proc whatsapp--media-jobs)
          proc)
      (error (ignore-errors (delete-directory dir t)) (signal (car err) (cdr err))))))

(defun whatsapp--stop-media-jobs ()
  "Stop only mpv processes started by this Emacs instance."
  (dolist (process (copy-sequence whatsapp--media-jobs))
    (when (process-live-p process) (delete-process process))))
(add-hook 'kill-emacs-hook #'whatsapp--stop-media-jobs)

(defun whatsapp--view-render ()
  "Render the current image with mouse-accessible zoom and save controls."
  (let ((inhibit-read-only t) (bytes whatsapp--view-bytes) (type whatsapp--view-type))
    (whatsapp--checked-image-pixels bytes type)
    (erase-buffer)
    (whatsapp--button "Fit" #'whatsapp-image-fit)
    (whatsapp--button "−" #'whatsapp-image-smaller)
    (whatsapp--button "+" #'whatsapp-image-larger)
    (whatsapp--button "Save original…" #'whatsapp-image-save)
    (whatsapp--button "Close" #'quit-window)
    (insert "\n\n")
    (let* ((dimensions (whatsapp--image-dimensions bytes type))
           (width (if whatsapp--view-zoom
                      (max 1 (round (* (car dimensions) whatsapp--view-zoom)))
                    (max 1 (min (car dimensions) (- (window-pixel-width) 40)
                                (floor (* (car dimensions)
                                          (/ (float (max 1 (- (window-pixel-height) 120)))
                                             (cdr dimensions)))))))))
      (setq width (max 1 (min width 4096
                             (floor (sqrt (* (min whatsapp-image-pixel-limit 16000000)
                                             (/ (float (car dimensions)) (cdr dimensions))))))))
      (insert-image (create-image bytes type t :width width :max-height 4096 :ascent 'center)))
    (insert "\n") (goto-char (point-min)) (set-buffer-modified-p nil)))
(defun whatsapp-image-fit () "Fit image to the selected window." (interactive)
  (setq whatsapp--view-zoom nil) (whatsapp--view-render))
(defun whatsapp-image-larger () "Increase image zoom, bounded at 400 percent." (interactive)
  (setq whatsapp--view-zoom (min 4.0 (* 1.25 (or whatsapp--view-zoom 1.0))))
  (whatsapp--view-render))
(defun whatsapp-image-smaller () "Decrease image zoom, bounded at ten percent." (interactive)
  (setq whatsapp--view-zoom (max 0.1 (/ (or whatsapp--view-zoom 1.0) 1.25)))
  (whatsapp--view-render))
(defun whatsapp-image-save (file)
  "Save original image bytes to FILE without recompression."
  (interactive (list (read-file-name "Save original: " nil nil nil
                                      (concat "whatsapp" (whatsapp--media-suffix whatsapp--view-mime)))))
  (when (file-remote-p file) (user-error "Choose a local destination"))
  (when (or (not (file-exists-p file)) (yes-or-no-p "Replace the existing file? "))
    (let ((coding-system-for-write 'no-conversion))
      (write-region whatsapp--view-bytes nil file nil 'silent))
    (message "WhatsApp: original saved")))

(defun whatsapp--open-uri (uri &optional kind)
  "Preview image URI or open audio/video with mpv; never execute a document."
  (whatsapp--open-bytes (whatsapp--data-uri-bytes uri) (whatsapp--data-uri-mime uri) kind))

(defun whatsapp--open-bytes (bytes mime &optional kind)
  "Preview bounded local BYTES of MIME; never invoke a shell or document handler."
  (when (> (string-bytes bytes) whatsapp-max-file-bytes) (user-error "Preview exceeds the byte limit"))
  (let ((type (whatsapp--image-type-from-mime mime)))
    (cond
     ((and type (not (eq type 'gif)) (display-graphic-p) (image-type-available-p type))
      (whatsapp--checked-image-pixels bytes type)
      (let ((buffer (get-buffer-create "*WhatsApp image*")))
        (with-current-buffer buffer
          (special-mode)
          (setq whatsapp--view-bytes bytes whatsapp--view-type type
                whatsapp--view-mime mime whatsapp--view-zoom nil))
        (pop-to-buffer buffer) (whatsapp--view-render)))
     ((or (string-prefix-p "video/" mime) (string-prefix-p "audio/" mime)
          (equal mime "image/gif"))
      (whatsapp--play-bytes bytes mime (or (equal kind "gif") (equal mime "image/gif"))))
     (t (user-error "No safe inline viewer; use Save original on the message")))))

(defun whatsapp--worker (operation payload callback)
  "Run OPERATION asynchronously with PAYLOAD on stdin, then invoke CALLBACK.
Tokens never appear in process arguments or temporary files."
  (let ((process-environment (whatsapp--media-environment))
        (script (expand-file-name "scripts/media-worker.py" whatsapp--source-directory))
        (python (executable-find whatsapp-python-program))
        (output "") done timer proc)
    (unless (and python (file-regular-p script))
      (user-error "Install Python 3 and the complete WhatsAppel source directory"))
    (cl-labels
        ((finish (result)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (funcall callback result))))
      (setq proc
            (make-process
             :name "whatsappel-media-worker" :buffer nil :noquery t
             :connection-type 'pipe :coding 'utf-8-unix
             :command (list python "-I" script operation)
             :filter (lambda (process text)
                       (setq output (concat output text))
                       (when (> (length output) 65536)
                         (finish '(("ok") ("uncertain" . t) ("error" . "Worker output limit; check delivery before retrying")))
                         (delete-process process)))
             :sentinel
             (lambda (process _event)
               (when (memq (process-status process) '(exit signal))
                 (finish
                  (condition-case nil
                      (let ((json-object-type 'alist) (json-array-type 'list)
                            (json-key-type 'string) (json-false nil) (json-null nil))
                        (let ((result (json-read-from-string output)))
                          (unless (listp result) (error "Invalid worker response"))
                          result))
                    (error '(("ok") ("uncertain" . t)
                             ("error" . "Worker stopped; check delivery before retrying")))))))))
      (setq timer (run-at-time 130 nil
                              (lambda ()
                                (finish '(("ok") ("uncertain" . t)
                                          ("error" . "Operation timed out; check delivery before retrying")))
                                (when (process-live-p proc) (delete-process proc)))))
      (condition-case err
          (progn (process-send-string proc (concat (json-encode payload) "\n"))
                 (process-send-eof proc))
        (error (when (process-live-p proc) (delete-process proc))
               (finish '(("ok") ("error" . "Could not start media operation")))
               (message "WhatsApp: worker setup failed")))
      proc)))

(defun whatsapp--stage-render ()
  "Render the explicit preview/send workflow for the pinned recipient."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Prepare attachment\n" 'face 'whatsapp-title))
    (let ((transport (if whatsapp--stage-file
                         (whatsapp--safe-media-kind (intern whatsapp--stage-kind)
                                                    (whatsapp--guess-mime whatsapp--stage-file 'document))
                       whatsapp--stage-kind)))
      (insert (format "To: %s\nFile: %s\nSend as: %s\n\n"
                      whatsapp--stage-target (or whatsapp--stage-file "Recording…") transport)))
    (insert (format "Caption: %s\n\n" whatsapp--stage-caption))
    (cond
     ((and (not whatsapp--stage-operation) (not whatsapp--stage-file))
      (whatsapp--button "Cancel" #'whatsapp-stage-cancel))
     ((eq whatsapp--stage-operation 'recording)
      (insert "Microphone active · recording stops automatically at the configured limit.\n\n")
      (whatsapp--button "Stop recording" #'whatsapp-voice-stop)
      (whatsapp--button "Discard" #'whatsapp-stage-cancel))
     (whatsapp--stage-operation
      (insert (format "%s in progress. Do not retry a send until its result is known.\n"
                      whatsapp--stage-operation)))
     (t
      (whatsapp--button "Preview" #'whatsapp-stage-preview)
      (whatsapp--button "Caption…" #'whatsapp-stage-caption)
      (whatsapp--button "Send" #'whatsapp-stage-send)
      (whatsapp--button "Cancel" #'whatsapp-stage-cancel)
      (when (equal (downcase (or (and whatsapp--stage-file (file-name-extension whatsapp--stage-file)) "")) "gif")
        (insert "\n\nRaw GIFs are sent unchanged as documents. Optional MP4 copy: up to 30 seconds.\n")
        (whatsapp--button "Prepare MP4 copy" #'whatsapp-stage-convert-gif))))
    (when whatsapp--stage-error
      (insert (propertize (concat "\n\n" whatsapp--stage-error "\n") 'face 'warning)))
    (insert "\n\nNo automatic send. Media uses the standard bridge transport, not a pqenv envelope.\n")
    (goto-char (point-min)) (set-buffer-modified-p nil)))

(defun whatsapp--stage-cleanup ()
  "Remove only this stage's private generated files."
  (dolist (directory whatsapp--stage-owned)
    (ignore-errors (delete-directory directory t)))
  (setq whatsapp--stage-owned nil))

(defun whatsapp--stage-close-p ()
  "Protect an in-flight operation against accidental buffer closure."
  (if whatsapp--stage-operation
      (progn (message "WhatsApp: use Stop/Discard for recording; an upload cannot be recalled by closing") nil)
    t))

(defun whatsapp--stage-create (kind file &optional caption)
  "Create a mouse-first stage for KIND and FILE, pinning this chat and account."
  (unless whatsapp-chat--target (user-error "Open a WhatsApp conversation first"))
  (let ((target whatsapp-chat--target) (origin (current-buffer))
        (buffer (generate-new-buffer "*WhatsApp attachment*")))
    (with-current-buffer buffer
      (special-mode)
      (setq whatsapp--stage-target target whatsapp--stage-origin origin
            whatsapp--stage-file file whatsapp--stage-kind (if (symbolp kind) (symbol-name kind) kind)
            whatsapp--stage-caption (or caption "") whatsapp--stage-url whatsapp-bridge-url
            whatsapp--stage-token-id (secure-hash 'sha256 (or whatsapp-bridge-token "")))
      (add-hook 'kill-buffer-hook #'whatsapp--stage-cleanup nil t)
      (add-hook 'kill-buffer-query-functions #'whatsapp--stage-close-p nil t)
      (whatsapp--stage-render))
    (pop-to-buffer buffer) buffer))

(defun whatsapp-stage-caption (caption)
  "Set attachment CAPTION before sending."
  (interactive (list (read-string "Caption: " whatsapp--stage-caption)))
  (when whatsapp--stage-operation (user-error "An operation is already in progress"))
  (setq whatsapp--stage-caption caption) (whatsapp--stage-render))

(defun whatsapp-stage-preview ()
  "Preview the local file; do not upload anything."
  (interactive)
  (when whatsapp--stage-operation (user-error "An operation is already in progress"))
  (unless whatsapp--stage-file (user-error "There is no recorded/selected file"))
  (let* ((file whatsapp--stage-file) (mime (whatsapp--guess-mime file 'document)))
    (whatsapp--validate-file file)
    (let ((kind whatsapp--stage-kind)
          (bytes (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally file nil 0 (1+ whatsapp-max-file-bytes))
                   (buffer-string))))
      (whatsapp--open-bytes bytes mime kind))))

(defun whatsapp-stage-send ()
  "Send the staged attachment once to its pinned recipient, asynchronously."
  (interactive)
  (when whatsapp--stage-operation (user-error "An operation is already in progress"))
  (unless (and (equal whatsapp--stage-url whatsapp-bridge-url)
               (equal whatsapp--stage-token-id (secure-hash 'sha256 (or whatsapp-bridge-token ""))))
    (user-error "Account changed; cancel and prepare the attachment again"))
  (whatsapp--validate-bridge)
  (whatsapp--validate-file whatsapp--stage-file)
  (let ((buffer (current-buffer)) (origin whatsapp--stage-origin))
    (setq whatsapp--stage-operation 'upload whatsapp--stage-error nil)
    (whatsapp--stage-render)
    (condition-case err
        (setq whatsapp--stage-process
              (whatsapp--worker
               "send" `(("url" . ,whatsapp-bridge-url) ("token" . ,whatsapp-bridge-token)
                        ("target" . ,whatsapp--stage-target) ("kind" . ,whatsapp--stage-kind)
                        ("file" . ,whatsapp--stage-file) ("caption" . ,whatsapp--stage-caption)
                        ("max_bytes" . ,(min (* 16 1024 1024) whatsapp-max-file-bytes))
                        ("timeout" . ,(max 1 (min 120 whatsapp-request-timeout))))
               (lambda (result)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq whatsapp--stage-operation nil whatsapp--stage-process nil)
                     (if (eq t (cdr (assoc "ok" result)))
                         (progn
                           (when (buffer-live-p origin)
                             (with-current-buffer origin (whatsapp-chat-refresh t)))
                           (kill-buffer buffer)
                           (message "WhatsApp: attachment accepted by the bridge"))
                       (setq whatsapp--stage-error (or (cdr (assoc "error" result))
                                                       "Delivery unconfirmed; check the chat before retrying"))
                       (whatsapp--stage-render)))))))
      (error (setq whatsapp--stage-operation nil whatsapp--stage-error (error-message-string err))
             (whatsapp--stage-render)))))

(defun whatsapp-stage-convert-gif ()
  "Prepare an explicit bounded MP4 copy of the staged GIF; never auto-send."
  (interactive)
  (when whatsapp--stage-operation (user-error "An operation is already in progress"))
  (let* ((buffer (current-buffer)) (dir (whatsapp--private-directory))
         (output (expand-file-name "animation.mp4" dir)))
    (push dir whatsapp--stage-owned)
    (setq whatsapp--stage-operation 'conversion whatsapp--stage-error nil)
    (whatsapp--stage-render)
    (condition-case err
        (setq whatsapp--stage-process
              (whatsapp--worker
               "gif" `(("file" . ,whatsapp--stage-file) ("output" . ,output))
               (lambda (result)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq whatsapp--stage-operation nil whatsapp--stage-process nil)
                     (if (eq t (cdr (assoc "ok" result)))
                         (setq whatsapp--stage-file output whatsapp--stage-kind "gif"
                               whatsapp--stage-error "MP4 copy prepared. Preview, then Send. Native GIF looping depends on your wuzapi build.")
                       (setq whatsapp--stage-error (or (cdr (assoc "error" result)) "Conversion failed")))
                     (whatsapp--stage-render))))))
      (error (setq whatsapp--stage-operation nil whatsapp--stage-error (error-message-string err))
             (whatsapp--stage-render)))))

(defun whatsapp-stage-cancel ()
  "Discard a recording or a prepared file; never recall an in-flight upload."
  (interactive)
  (when (and whatsapp--stage-operation (not (eq whatsapp--stage-operation 'recording)))
    (user-error "An upload/conversion is in progress; closing cannot undo delivery"))
  (when (and whatsapp--stage-process (process-live-p whatsapp--stage-process))
    (set-process-sentinel whatsapp--stage-process #'ignore)
    (delete-process whatsapp--stage-process))
  (setq whatsapp--stage-operation nil)
  (kill-buffer (current-buffer)))

(defun whatsapp-voice-command (file)
  "Return a shell-free FFmpeg command for a bounded, mono Opus recording."
  (list "ffmpeg" "-hide_banner" "-loglevel" "error" "-n"
        "-f" "pulse" "-i" whatsapp-voice-device "-ac" "1" "-ar" "48000"
        "-c:a" "libopus" "-b:a" "32k" "-t" (number-to-string (max 1 (min 600 whatsapp-voice-seconds)))
        "-fs" (number-to-string (min (* 16 1024 1024) whatsapp-max-file-bytes)) file))

(defun whatsapp-chat-record-voice ()
  "Start recording only after this explicit command; Stop, Preview, then Send."
  (interactive)
  (unless (executable-find "ffmpeg") (user-error "Install FFmpeg with PulseAudio input support"))
  (unless whatsapp-chat--target (user-error "Open a WhatsApp conversation first"))
  (let* ((process-environment (whatsapp--media-environment))
         (dir (whatsapp--private-directory)) (file (expand-file-name "voice.ogg" dir))
         (buffer (whatsapp--stage-create 'audio file)) timer)
    (with-current-buffer buffer
      (push dir whatsapp--stage-owned)
      (setq whatsapp--stage-operation 'recording)
      (condition-case err
          (progn
            (setq whatsapp--stage-process
                  (make-process
                   :name "whatsappel-recording" :buffer nil :noquery t :connection-type 'pipe
                   :command (whatsapp-voice-command file)
                   :sentinel
                   (lambda (process _event)
                     (when (memq (process-status process) '(exit signal))
                       (when timer (cancel-timer timer))
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (setq whatsapp--stage-operation nil whatsapp--stage-process nil)
                           (if (and (= (process-exit-status process) 0) (file-regular-p file)
                                    (> (file-attribute-size (file-attributes file)) 0))
                               (progn (set-file-modes file #o600)
                                      (setq whatsapp--stage-error "Recording ready. Preview before Send. This is Opus audio; a native voice-note badge is not guaranteed."))
                             (setq whatsapp--stage-file nil
                                   whatsapp--stage-error "Recording failed. Check microphone permission and the PulseAudio/PipeWire input; Cancel to retry."))
                           (whatsapp--stage-render)))))))
            (let ((process whatsapp--stage-process))
              (setq timer (run-at-time (+ 10 (max 1 (min 600 whatsapp-voice-seconds))) nil
                                       (lambda () (when (process-live-p process) (delete-process process)))))))
        (error (setq whatsapp--stage-operation nil whatsapp--stage-file nil
                     whatsapp--stage-error (error-message-string err))))
      (whatsapp--stage-render))))

(defun whatsapp-voice-stop ()
  "Ask FFmpeg to finish the recording and flush its Ogg container."
  (interactive)
  (unless (and (eq whatsapp--stage-operation 'recording)
               (process-live-p whatsapp--stage-process))
    (user-error "No active recording"))
  (setq whatsapp--stage-operation 'finishing-recording)
  (process-send-string whatsapp--stage-process "q\n")
  (whatsapp--stage-render))

(defun whatsapp-root-click (event)
  "Open the exact conversation clicked by mouse EVENT."
  (interactive "e")
  (mouse-set-point event) (whatsapp-root-open-chat))

;;;###autoload
(defun whatsapp-launch ()
  "Open the mouse-first workspace using existing account settings.
No account linking or microphone recording occurs automatically."
  (interactive)
  (setq whatsapp--workspace-active t)
  (when (equal whatsapp-media-player "xdg-open") (setq whatsapp-media-player "mpv"))
  (when-let ((origin (getenv "WHATSAPPEL_BRIDGE_URL"))) (setq whatsapp-bridge-url origin))
  (unless whatsapp-bridge-token
    (setq whatsapp-bridge-token (getenv "WHATSAPPEL_TOKEN")))
  (whatsapp)
  (unless whatsapp--poll-timer (whatsapp-toggle-polling))
  (message "WhatsAppel: select a conversation; Connect / Show QR are available on the dashboard"))

(provide 'whatsapp)
;;; whatsapp.el ends here
