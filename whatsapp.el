;;; whatsapp.el --- telega-style Emacs WhatsApp client  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-only
;; Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
;;
;; Author: Cristian Cezar Moisés
;; URL: https://codeberg.org/berkeley/whatsappel
;; Version: 3.3.0
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
(require 'pp)

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

(defconst whatsapp-version "3.3.0" "Workspace release version.")

(defconst whatsapp--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))
(defcustom whatsapp-python-program "python3"
  "Python 3 used for isolated attachment uploads and explicit GIF conversion."
  :type 'string :group 'whatsapp)
(defcustom whatsapp-history-page-size 60
  "Recent messages requested initially; Load older expands the retained window."
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


(defcustom whatsapp-root-page-size 80
  "Maximum conversation rows initially rendered; More expands this view."
  :type 'integer :group 'whatsapp)
(defcustom whatsapp-show-message-actions nil
  "Show an Actions button on every message instead of using the context menu."
  :type 'boolean :group 'whatsapp)
(defvar-local whatsapp-root--limit nil)
(defvar-local whatsapp--read-revision nil)
(defvar-local whatsapp--read-v2 nil)
(defvar-local whatsapp--read-origin nil)
(defvar-local whatsapp--async-media nil)
(defvar-local whatsapp--refresh-failures 0)
(defvar-local whatsapp--next-refresh 0)
(defvar-local whatsapp-chat--total nil)
(defvar-local whatsapp-chat--has-more nil)
(defvar-local whatsapp-chat--history-start nil)
(defvar-local whatsapp-chat--history-end nil)
(defvar-local whatsapp-chat--rendered-messages nil)
(defvar-local whatsapp-chat--last-limit nil)
(defvar-local whatsapp-chat--rendered-has-more nil)
(defvar whatsapp--selected-chat nil)
(defvar whatsapp--indexed-chats nil)
(defvar whatsapp--name-table (make-hash-table :test 'equal))

(defun whatsapp--origin-key ()
  "Return an in-memory account scope without retaining the literal token."
  (list whatsapp-bridge-url (secure-hash 'sha256 (or whatsapp-bridge-token ""))))

;;; RC3: bounded reads, focus-aware acknowledgements and lazy media.
(defcustom whatsapp-use-read-worker t
  "Use the bounded Python child for conversation reads and media-job results.
Legacy POST operations still use the existing URL transport."
  :type 'boolean :group 'whatsapp)
(defcustom whatsapp-auto-poll t
  "Start polling when opening WhatsApp, unless polling was explicitly paused."
  :type 'boolean :group 'whatsapp)
(defcustom whatsapp-mark-focused-chat-read t
  "Acknowledge v2 messages only in the selected, focused conversation window.
A terminal whose focus is unknown does not automatically acknowledge messages."
  :type 'boolean :group 'whatsapp)
(defvar whatsapp--polling-paused nil)
(defvar whatsapp--media-open-waiters (make-hash-table :test 'equal))
(defvar-local whatsapp--read-processes nil)
(defvar-local whatsapp--closing nil)
(defvar-local whatsapp--has-snapshot nil)
(defvar-local whatsapp--last-refresh-time nil)
(defvar-local whatsapp--prefetch-timer nil)
(defvar-local whatsapp--media-open-generation 0)
(defvar-local whatsapp-root--render-key nil)
(defvar-local whatsapp-root--shown nil)
(defvar-local whatsapp-root--shown-selection nil)
(defvar-local whatsapp-root--compact nil
  "Non-nil shows one line per conversation; scoped to this root buffer.")

(defun whatsapp--json-read (text)
  "Parse TEXT with string-keyed objects and nil for false/null.
Use native JSON parsing without interning remote keys, when available."
  (if (and (fboundp 'json-parse-string)
           (or (not (fboundp 'json-available-p)) (json-available-p)))
      (cl-labels ((convert (value)
                    (cond ((hash-table-p value)
                           (let (items)
                             (maphash (lambda (key item) (push (cons key (convert item)) items)) value)
                             (nreverse items)))
                          ((consp value) (mapcar #'convert value))
                          (t value))))
        (convert (json-parse-string text :object-type 'hash-table :array-type 'list
                                    :null-object nil :false-object nil)))
    (let ((json-object-type 'alist) (json-array-type 'list)
          (json-key-type 'string) (json-false nil) (json-null nil))
      (json-read-from-string text))))

(defun whatsapp--read-worker (path callback &optional payload)
  "Read PATH in an owned bounded subprocess, delivering CALLBACK once.
The token is sent only on stdin. Killing the originating buffer stops the child."
  (whatsapp--validate-bridge)
  (let* ((buffer (current-buffer)) (origin (whatsapp--origin-key))
         (process-environment (whatsapp--media-environment))
         (python (executable-find whatsapp-python-program))
         (media-submit (member path '("/download" "/download?async=1")))
         (script (expand-file-name (cond (media-submit "scripts/download-worker.py")
                                         (payload "scripts/send-worker.py")
                                         (t "scripts/read-worker.py"))
                                   whatsapp--source-directory))
         (ceiling (if media-submit (* 24 1024 1024)
                    (if payload 65536 (* (if (string-prefix-p "/media-job?" path) 24 4) 1024 1024))))
         (timeout (max 1 (min 120 whatsapp-request-timeout)))
         (size 0) chunks done timer proc)
    (unless (and python (file-regular-p script))
      (user-error "Install Python 3 and the complete WhatsAppel read worker"))
    (cl-labels
        ((finish (result)
           (unless done
             (setq done t chunks nil)
             (when timer (cancel-timer timer))
             (when (and (processp proc) (process-live-p proc)) (delete-process proc))
             (if (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq whatsapp--read-processes (delq proc whatsapp--read-processes))
                   (funcall callback
                            (if (and (not whatsapp--closing) (equal origin (whatsapp--origin-key))) result
                              '(nil ("error" . "Read context changed; result discarded")))))
               (funcall callback '(nil ("error" . "Read buffer closed")))))))
      (condition-case nil
          (progn
            (setq proc
                  (make-process
                   :name "whatsappel-read" :buffer nil :noquery t :connection-type 'pipe
                   :coding 'utf-8-unix :command (list python "-I" script)
                   :filter (lambda (process text)
                             (unless done
                               (cl-incf size (string-bytes text))
                               (if (> size (+ 4096 (* 2 ceiling)))
                                   (progn (finish '(nil ("error" . "Read worker output limit")))
                                          (when (process-live-p process) (delete-process process)))
                                 (push text chunks))))
                   :sentinel
                   (lambda (process _event)
                     (when (and (not done) (memq (process-status process) '(exit signal)))
                       (finish
                        (condition-case nil
                            (let* ((result (whatsapp--json-read (apply #'concat (nreverse chunks))))
                                   (status (cdr (assoc "status" result)))
                                   (body (cdr (assoc "body" result))))
                              (unless (and (listp body) (assoc "body" result)
                                           (or (null status) (and (integerp status) (<= 100 status 599))))
                                (error "Invalid read result"))
                              (cons status body))
                          (error '(nil ("error" . "Read worker stopped; cached history retained")))))))))
            (push proc whatsapp--read-processes)
            (setq timer (run-at-time (+ timeout 1) nil
                                     (lambda () (finish '(nil ("error" . "Read deadline exceeded"))))))
            (process-send-string proc
                                 (json-encode `((url . ,whatsapp-bridge-url) (token . ,whatsapp-bridge-token)
                                                (path . ,path) (timeout . ,timeout) (max_bytes . ,ceiling)
                                                (payload . ,payload))))
            (process-send-eof proc))
        (error (finish '(nil ("error" . "Read worker could not start")))))
      proc)))

(defun whatsapp--request-async (method path payload callback)
  "Use strict owned workers for snapshots and explicit text sends; never resend."
  (cond
   ((and (equal method "POST") (member path '("/send" "/send/verified" "/transport/repair" "/transport/connect" "/download" "/download?async=1")))
    (whatsapp--read-worker path callback payload))
   ((and whatsapp-use-read-worker (equal method "GET")
         (or (member path '("/status" "/qr" "/transport/status" "/transport/status?refresh=1"))
             (string-match-p "\\`/\\(?:chats\\|chat\\|health\\|media-job\\)\\(?:[?]\\|\\'\\)" path)))
    (whatsapp--read-worker path callback))
   (t (whatsapp--url-request-async method path payload callback))))

(defun whatsapp--cancel-buffer-work ()
  "Stop only owned read children/timers when their chat buffer is killed."
  (setq whatsapp--closing t whatsapp--refresh-again nil)
  (when (and (boundp 'whatsapp-chat--outgoing-overlay)
             (overlayp whatsapp-chat--outgoing-overlay))
    (delete-overlay whatsapp-chat--outgoing-overlay))
  (setq whatsapp-chat--outgoing-overlay nil)
  (dolist (process (copy-sequence whatsapp--read-processes))
    (when (process-live-p process) (delete-process process)))
  (setq whatsapp--read-processes nil)
  (dolist (timer (list whatsapp--prefetch-timer whatsapp-chat--redraw-timer whatsapp--open-timer whatsapp--pq-timer))
    (when (timerp timer) (cancel-timer timer)))
  (setq whatsapp--prefetch-timer nil whatsapp-chat--redraw-timer nil whatsapp--open-timer nil whatsapp--pq-timer nil)
  (cl-incf whatsapp--open-generation)
  (when (and whatsapp--pq-process (process-live-p whatsapp--pq-process))
    (delete-process whatsapp--pq-process))
  (setq whatsapp--pq-process nil)
  (cl-incf whatsapp--media-open-generation)
  (let (stale)
    (maphash (lambda (key value) (when (eq (car value) (current-buffer)) (push key stale)))
             whatsapp--media-open-waiters)
    (dolist (key stale) (remhash key whatsapp--media-open-waiters))))

(defun whatsapp--status-label ()
  "Return a non-secret loading/cache status for the visible header."
  (concat (if (fboundp 'whatsapp-session-label) (whatsapp-session-label) "")
   (cond (whatsapp--last-error (concat " " whatsapp--last-error))
        (whatsapp--refresh-pending (if whatsapp--has-snapshot " Refreshing · cached messages remain usable" " Loading from bridge…"))
        (whatsapp--has-snapshot
         (format " Cached snapshot · refreshed %ss ago"
                 (max 0 (floor (- (float-time) (or whatsapp--last-refresh-time (float-time)))))))
        (t " Waiting for the first successful bridge read"))))

(defun whatsapp-chat--focused-p ()
  "Non-nil only for the selected window in a visibly focused frame."
  (and whatsapp-mark-focused-chat-read
       (eq (window-buffer (selected-window)) (current-buffer))
       (eq (frame-visible-p (selected-frame)) t)
       (eq (frame-focus-state (selected-frame)) t)))

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

(defun whatsapp--url-request-async (method path payload callback)
  "Call METHOD PATH with PAYLOAD asynchronously; call CALLBACK exactly once.
A timeout kills the owned URL process and buffer.  Redirects are refused."
  (whatsapp--validate-bridge)
  (let ((url-request-method method)
        (url-max-redirections 0)
        (url-request-extra-headers
         (append (list (cons "X-Whatsappel-Token" whatsapp-bridge-token))
                 (when payload '(("Content-Type" . "application/json")))))
        (url-request-data
         (when payload (encode-coding-string (json-encode payload) 'utf-8)))
        done timer request-buffer)
    (cl-labels
        ((finish (result)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (unwind-protect (funcall callback result)
               (when (buffer-live-p request-buffer)
                 (when-let ((process (get-buffer-process request-buffer)))
                   (set-process-query-on-exit-flag process nil)
                   (delete-process process))
                 (kill-buffer request-buffer))))))
      (condition-case nil
          (let ((buffer
                 (url-retrieve
                  (concat (string-remove-suffix "/" whatsapp-bridge-url) path)
                  (lambda (status)
                    (setq request-buffer (current-buffer))
                    (finish (if (plist-get status :error)
                                '(nil ("error" . "Bridge transport failed"))
                              (condition-case nil (whatsapp--response)
                                (error '(nil ("error" . "Invalid response")))))))
                  nil t t)))
            (unless done (setq request-buffer buffer))
            (when (and done (buffer-live-p buffer)) (kill-buffer buffer)))
        (error (finish '(nil ("error" . "Bridge request could not start")))))
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
          (when (eq (gethash old whatsapp--media-pending) 'done)
            (remhash old whatsapp--media-pending))
          (remhash old whatsapp--preview-cache)
          (setq whatsapp--preview-order (delete old whatsapp--preview-order)))))))

(defun whatsapp-clear-caches ()
  "Discard downloaded media and cached decrypted/sent plaintext from memory."
  (interactive)
  (clrhash whatsapp--media-cache)
  (clrhash whatsapp--preview-cache)
  (setq whatsapp--preview-order nil)
  (let (finished)
    (maphash (lambda (k v) (when (memq v '(done failed)) (push k finished))) whatsapp--media-pending)
    (dolist (k finished) (remhash k whatsapp--media-pending)))
  (clrhash whatsapp-pq--plain-cache)
  (clrhash whatsapp-pq--sent-cache)
  (setq whatsapp--media-order nil)
  (message "WhatsApp caches cleared"))

(defun whatsapp--media-failure-label (result)
  "Return an actionable constant label, never a raw server error or URL."
  (let* ((status (car-safe result))
         (body (cdr-safe result))
         (reason (and (proper-list-p body) (cdr (assoc "reason" body))))
         (provider (and (proper-list-p body) (cdr (assoc "wuzapi_status" body)))))
    (cond
     ((or (member reason '("bridge-auth")) (memq status '(401 403)))
      "Bridge authentication failed; check the selected account/token")
     ((or (equal reason "bridge-route") (memq status '(404 405)))
      "Media route or job unavailable; verify the running bridge version")
     ((or (equal reason "media-metadata") (eq status 400))
      "Download metadata incomplete or rejected; refresh this chat before retrying")
     ((or (equal reason "media-limit") (eq status 413))
      "Media exceeds a configured size limit")
     ((or (member reason '("media-busy" "provider-busy")) (eq status 429))
      "Media workers are busy; wait, then retry explicitly")
     ((or (equal reason "provider-auth") (eq provider 401))
      "wuzapi rejected its user token; check backend account configuration")
     ((or (equal reason "provider-denied") (eq provider 403))
      "Provider denied this media request; check session and media availability")
     ((or (equal reason "media-expired") (eq status 410) (eq provider 410))
      "Provider reports expired media; old content may no longer be downloadable")
     ((equal reason "media-timeout") "Media request timed out; no message was resent")
     ((eq status 502) "Provider could not download this media; inspect Connection / delivery")
     ((whatsapp--ok-p status) "Media reply contains no supported data URI; check provider compatibility")
     (t "Media retrieval failed; check bridge connectivity and the Python worker"))))

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
    (when (and id (< (length whatsapp--media-queue) 64) (not (gethash key whatsapp--media-cache))
               (not (gethash key whatsapp--media-pending)))
      (when (> (hash-table-count whatsapp--media-pending) 256)
        (let (finished)
          (maphash (lambda (k v) (when (memq v '(done failed)) (push k finished))) whatsapp--media-pending)
          (dolist (k finished) (remhash k whatsapp--media-pending))))
      (puthash key 'queued whatsapp--media-pending)
      (setq whatsapp--media-queue
            (append whatsapp--media-queue (list (list key kind media (current-buffer)))))
      (unless whatsapp--media-pump-timer
        (setq whatsapp--media-pump-timer (run-at-time 0 nil #'whatsapp--media-pump))))))

(defun whatsapp--media-pump ()
  "Download at most two queued previews in their original account/buffer context."
  (setq whatsapp--media-pump-timer nil)
  (while (and whatsapp--media-queue (< whatsapp--media-active 2))
    (pcase-let ((`(,key ,kind ,media ,buffer) (pop whatsapp--media-queue)))
      (if (or (not (buffer-live-p buffer))
              (not (get-buffer-window buffer t))
              (not (equal (cl-subseq key 0 2) (whatsapp--origin-key))))
          (remhash key whatsapp--media-pending)
        (puthash key 'active whatsapp--media-pending)
        (cl-incf whatsapp--media-active)
        (condition-case nil
            (with-current-buffer buffer
              (whatsapp--download-async
               (append (list (cons "kind" kind)) media)
               (lambda (result)
                 (cl-decf whatsapp--media-active)
                 (puthash key (if (whatsapp--download-uri result) 'done 'failed) whatsapp--media-pending)
                 (when (and (buffer-live-p buffer)
                            (equal (cl-subseq key 0 2) (whatsapp--origin-key)))
                   (when-let ((uri (whatsapp--download-uri result)))
                     (whatsapp--cache-put key uri)
                     (when (gethash key whatsapp--media-cache)
                       (with-current-buffer buffer (whatsapp--schedule-media-redraw)))))
                 (when (and (eq (gethash key whatsapp--media-pending) 'failed) (buffer-live-p buffer))
                   (with-current-buffer buffer
                     (setq whatsapp--last-error "Image download failed. Check delivery or use Retry images; old media may have expired.")
                     (force-mode-line-update)))
                 (whatsapp--finish-media-open key result)
                 (whatsapp--media-pump))))
          (error (puthash key 'failed whatsapp--media-pending)
                 (cl-decf whatsapp--media-active)))))))

(defun whatsapp--media-suffix (mime)
  "Return a safe local suffix for MIME, never a path from remote input."
  (concat "." (or (car (rassoc mime whatsapp--mime-types)) "bin")))

(defun whatsapp-chat-open-media-at-point (&optional event)
  "Open clicked media once ready, sharing an existing preview download."
  (interactive (list (when (mouse-event-p last-input-event) last-input-event)))
  (when event (mouse-set-point event))
  (let* ((m (whatsapp--message-at-point)) (media (whatsapp--msg-field m "media"))
         (kind (whatsapp--msg-field m "kind")) (id (whatsapp--msg-field m "id"))
         (key (whatsapp--media-key id kind)) (cached (whatsapp--cache-get key))
         (buffer (current-buffer)) (origin (whatsapp--origin-key)))
    (unless media (user-error "No downloadable media on this message"))
    (cl-incf whatsapp--media-open-generation)
    (let ((generation whatsapp--media-open-generation))
      (if cached (whatsapp--open-uri cached kind)
        (puthash key (list buffer generation) whatsapp--media-open-waiters)
        (if (memq (gethash key whatsapp--media-pending) '(opening active queued))
            (progn
              (when-let ((job (cl-find key whatsapp--media-queue :key #'car :test #'equal)))
                (setq whatsapp--media-queue (cons job (delq job whatsapp--media-queue))))
              (message "WhatsApp: opening when ready; no second click needed"))
          (puthash key 'opening whatsapp--media-pending)
          (condition-case err
              (whatsapp--download-async
               (append (list (cons "kind" kind)) media)
               (lambda (result)
                 (remhash key whatsapp--media-pending)
                 (when (and (buffer-live-p buffer) (equal origin (whatsapp--origin-key)))
                   (with-current-buffer buffer
                     (when-let ((uri (whatsapp--download-uri result)))
                       (whatsapp--cache-put key uri))))
                 (whatsapp--finish-media-open key result)))
            (error (remhash key whatsapp--media-pending) (remhash key whatsapp--media-open-waiters)
                   (signal (car err) (cdr err)))))))))

(defun whatsapp--finish-media-open (key result)
  "Consume explicit open intent for KEY; never steal focus from another chat."
  (let ((waiter (gethash key whatsapp--media-open-waiters)))
    (remhash key whatsapp--media-open-waiters)
    (when (and waiter (buffer-live-p (car waiter))
               (equal (cl-subseq key 0 2) (whatsapp--origin-key)))
      (with-current-buffer (car waiter)
        (when (and (= (cadr waiter) whatsapp--media-open-generation)
                   (eq (window-buffer (selected-window)) (current-buffer)))
          (let ((uri (whatsapp--download-uri result)))
            (if (not uri) (message "WhatsApp: %s" (whatsapp--media-failure-label result))
              (condition-case nil
                  (whatsapp--open-uri uri (nth 4 key))
                (error (message "WhatsApp: preview unavailable; check Settings → Video or use Save original"))))))))))

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
  "A bounded media label; full original caption stays on the message record."
  (concat "[" (or kind "media") "]"
          (if (and (stringp cap) (> (length cap) 0))
              (concat " " (substring cap 0 (min 512 (length cap)))
                      (if (> (length cap) 512) "… [full caption: Copy text]" "")) "")
          (if (member kind '("video" "audio" "document" "gif")) "  (RET/o to open)" "")))

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
  "Insert a lazy placeholder. Never decode bytes on a transcript-render path."
  (let* ((beg (point)) (key (whatsapp--media-key id kind))
         (entry (gethash key whatsapp--preview-cache)))
    (insert (format "[%s · click to open]" kind))
    (when media (whatsapp--tag-media beg (point) media kind id))
    (when (and entry (display-graphic-p))
      (put-text-property beg (point) 'display (nth 1 entry)))
    (when (and (stringp cap) (not (string-empty-p cap)))
      (insert " ") (whatsapp--insert-bounded-text cap 512))))

(defcustom whatsapp-message-preview-characters 2048
  "Maximum characters of each message inserted into the conversation.
Original text remains in the record; Read full text opens paged local text."
  :type 'integer :group 'whatsapp)
(defvar-local whatsapp--open-timer nil)
(defvar-local whatsapp--open-generation 0)
(defvar-local whatsapp--selection-phase nil)
(defvar-local whatsapp--selection-seconds nil)
(defvar-local whatsapp--pq-process nil)
(defvar-local whatsapp--pq-timer nil)
(defvar-local whatsapp--pq-generation 0)
(defvar-local whatsapp--text-content nil)
(defvar-local whatsapp--text-offset 0)

(defun whatsapp--insert-bounded-text (text &optional maximum)
  "Insert a bounded prefix of TEXT with an explicit paged-reader control."
  (let* ((limit (max 128 (min 8192 (or maximum whatsapp-message-preview-characters))))
         (size (length text)))
    (insert (substring-no-properties text 0 (min size limit)))
    (when (> size limit)
      (insert "\n")
      (insert-text-button "Read full text…" 'follow-link t
                          'action (lambda (_button) (whatsapp--show-full-text text)))
      (insert (format "  (%d characters; original retained)" size)))))

(defun whatsapp--text-page ()
  "Render only one page of an explicitly opened local text record."
  (let* ((inhibit-read-only t) (size (length whatsapp--text-content))
         (start (min whatsapp--text-offset (max 0 (1- size))))
         (end (min size (+ start 8192))))
    (erase-buffer)
    (insert (format "Original text · characters %d–%d of %d\n\n" (1+ start) end size))
    (when (> start 0)
      (insert-text-button "Previous page" 'follow-link t
                          'action (lambda (_) (setq whatsapp--text-offset (max 0 (- start 8192)))
                                    (whatsapp--text-page))) (insert "   "))
    (when (< end size)
      (insert-text-button "Next page" 'follow-link t
                          'action (lambda (_) (setq whatsapp--text-offset end) (whatsapp--text-page))))
    (insert "\n\n" (substring-no-properties whatsapp--text-content start end))
    (goto-char (point-min))))

(defun whatsapp--show-full-text (text)
  "Open TEXT locally in 8192-character pages; never perform HTTP or decode images."
  (let ((buffer (generate-new-buffer "*WhatsApp text*")))
    (with-current-buffer buffer
      (special-mode)
      (setq whatsapp--text-content text whatsapp--text-offset 0)
      (whatsapp--text-page))
    (pop-to-buffer buffer)))

(defun whatsapp--visible-spans ()
  "Return known visible spans without forcing redisplay from a scroll callback."
  (mapcar (lambda (window)
            (let ((start (window-start window)))
              (cons start (min (point-max) (or (window-end window) (+ start 8192))))))
          (get-buffer-window-list (current-buffer) nil t)))

(defun whatsapp-root--select-only (jid)
  "Update selection faces without deleting rows, filtering or rebuilding history."
  (let ((pos (point-min)) (inhibit-read-only t) (buffer-undo-list t)
        (modified (buffer-modified-p)))
    (save-excursion
      (while (< pos (point-max))
        (let* ((end (next-single-property-change pos 'whatsapp-jid nil (point-max)))
               (row (get-text-property pos 'whatsapp-jid)))
          (when row
            (goto-char pos)
            (put-text-property pos (min end (line-end-position)) 'face
                               (whatsapp-profiles--row-face (equal row jid))))
          (setq pos end))))
    (setq whatsapp-root--shown-selection jid)
    (set-buffer-modified-p modified)))

(defun whatsapp--open-deferred (buffer generation origin)
  "Continue opening only the still-selected BUFFER for GENERATION and ORIGIN."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation whatsapp--open-generation)
        (setq whatsapp--open-timer nil)
        (when (and (not whatsapp--closing) (equal origin (whatsapp--origin-key))
                   (eq buffer (window-buffer (selected-window))))
          (condition-case nil
              (progn
                (setq whatsapp--selection-phase 'refreshing)
                (when (and whatsapp-chat--messages (not whatsapp-chat--rendered-messages))
                  (whatsapp-chat--render whatsapp-chat--messages))
                (whatsapp-chat-refresh)
                (whatsapp-chat--schedule-prefetch))
            (error (setq whatsapp--last-error "Conversation refresh could not start; draft retained"
                         whatsapp--selection-phase 'failed))))))))

(defun whatsapp-selection-diagnostics ()
  "Show content-free runtime facts about this loaded client, without network I/O."
  (interactive)
  (let ((facts (list :version whatsapp-version :emacs emacs-version
                     :loaded-source whatsapp--source-directory
                     :phase whatsapp--selection-phase :select-seconds whatsapp--selection-seconds
                     :cached-messages (length whatsapp-chat--messages)
                     :rendered-messages (length whatsapp-chat--rendered-messages)
                     :read-pending (and whatsapp--refresh-pending t)
                     :read-processes (length whatsapp--read-processes)
                     :automatic-images whatsapp-auto-load-images
                     :debug-on-quit debug-on-quit)))
    (with-help-window "*WhatsApp selection diagnostics*"
      (princ (pp-to-string facts))
      (princ "\nNo message text, contact ID, bridge URL or token is included.\n")
      (princ "To capture a freeze: M-x toggle-debug-on-quit, reproduce, then C-g.\n")
      (princ "Review any resulting backtrace before sharing: it can contain private data.\n"))))

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
         (hdr (propertize (concat (truncate-string-to-width (substring name 0 (min 256 (length name))) 80) "  ")
                          'face (if me 'whatsapp-accent 'whatsapp-contact))))
    (insert hdr (propertize tss 'face 'shadow) "  ")
    (when (and me (member (cdr (assoc "delivery" m)) '("accepted" "delivered" "read")))
      (insert (propertize (format "[%s] " (cdr (assoc "delivery" m))) 'face 'shadow)))
    (when whatsapp-show-message-actions
      (insert-text-button "Actions…" 'follow-link t 'help-echo "React, reply, forward, save, or delete"
                          'action (lambda (button)
                                    (goto-char (button-start button))
                                    (whatsapp-chat-message-menu))))
    (insert "\n")
    (when (and (stringp reply) (> (length reply) 0))
      (insert (propertize
               (format "↳ %s\n%s"
                       (truncate-string-to-width
                        (replace-regexp-in-string "\n" " " (substring reply 0 (min 256 (length reply)))) 70)
                       (make-string (length (if (> (length tss) 0)
                                                (format "[%s] " tss) "")) ?\s))
               'face 'font-lock-comment-face)))
    (cond
     ((and (stringp text) (whatsapp--pq-text-p text))
      (whatsapp--insert-pq me text id))
     ((and (stringp text) (> (length text) 0)
           (not (member kind '("image" "sticker" "audio" "video" "document" "gif"))))
      (whatsapp--insert-bounded-text text))
     ((and (member kind '("image" "sticker")) media whatsapp-auto-load-images)
      (whatsapp--insert-image id kind media cap))
     ((member kind '("image" "sticker" "video" "audio" "document" "gif"))
      (let ((beg (point)))
        (insert (whatsapp--media-label kind cap))
        (when media (whatsapp--tag-media beg (point) media kind id))))
     ((stringp text) (whatsapp--insert-bounded-text text))
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
  "Return the provider target without changing an opaque identifier's namespace.
Only the known telephone namespaces are reduced to a number for compatibility.
In particular, an @lid identifier is NOT a phone number and must keep its suffix.
Unknown qualified identifiers are preserved for the provider to validate, never
silently rewritten as telephone recipients."
  (unless (and (stringp jid) (not (string-empty-p jid)))
    (user-error "A recipient identifier is required"))
  (if (string-match "\\`\\([^@]+\\)@\\(?:s\\.whatsapp\\.net\\|c\\.us\\)\\'" jid)
      (match-string 1 jid)
    jid))

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
  (let* ((window (get-buffer-window (current-buffer) t))
         (width (max 24 (if (window-live-p window) (window-body-width window) 72))))
    (when (and (> (current-column) 0)
               (> (+ (current-column) (string-width label) 3) width))
      (insert "\n")))
  (insert-text-button label 'follow-link t 'help-echo (or help label)
                      'whatsapp-command command
                      'action (lambda (_button) (call-interactively command)))
  (insert "   "))

(defun whatsapp--chat-name (jid)
  "Resolve JID using a snapshot-scoped index, not a full scan per redisplay."
  (unless (eq whatsapp--indexed-chats whatsapp--chats)
    (clrhash whatsapp--name-table)
    (dolist (chat whatsapp--chats)
      (let ((key (cdr (assoc "jid" chat))) (name (cdr (assoc "name" chat))))
        (when (and (stringp key) (stringp name)) (puthash key name whatsapp--name-table))))
    (setq whatsapp--indexed-chats whatsapp--chats))
  (or (gethash jid whatsapp--name-table) jid "WhatsApp"))

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
    (insert (propertize (concat (whatsapp--row-text
                                     (substring-no-properties (truncate-string-to-width
                                                               (whatsapp--chat-name whatsapp-chat--jid) 120 nil nil "…"))) "\n")
                        'face 'whatsapp-title))
    (insert (propertize (concat (whatsapp--row-text whatsapp-chat--jid) "\n\n")
                        'face 'shadow))
    (whatsapp--button "Chats" #'whatsapp)
    (whatsapp--button "Refresh" #'whatsapp-chat-refresh)
    (whatsapp--button "Write" #'whatsapp-chat-focus-input)
    (whatsapp--button "Search messages" #'whatsapp-chat-search)
    (whatsapp--button "Contact info" #'whatsapp-contact-info)
    (whatsapp--button "More…" #'whatsapp-command-menu)
    (insert "\n\n")
    (unless messages
      (insert (propertize (if whatsapp--has-snapshot
                              "No retained messages. Type below, then press Enter.\n\n"
                            "Loading retained history from the bridge… Your draft remains editable.\n\n")
                          'face 'shadow)))
    (when (or whatsapp-chat--has-more (> (length messages) limit))
      (insert (propertize "Recent retained messages.  " 'face 'shadow))
      (whatsapp--button "Load older" #'whatsapp-chat-show-older)
      (insert "\n\n"))
    (setq whatsapp-chat--history-start (copy-marker (point) nil))
    (dolist (m visible) (whatsapp--insert-message m))
    (setq whatsapp-chat--history-end (copy-marker (point) nil)
          whatsapp-chat--rendered-messages visible
          whatsapp-chat--last-limit limit
          whatsapp-chat--rendered-has-more whatsapp-chat--has-more)
    (insert (propertize "\nCompose  ·  Enter sends  ·  C-j adds a line\n" 'face 'shadow))
    (whatsapp--button (if whatsapp-chat--send-pending "Sending…" "Send") #'whatsapp-chat-send-input)
    (whatsapp--button "Image…" #'whatsapp-chat-attach-image)
    (whatsapp--button "Video…" #'whatsapp-chat-attach-video)
    (whatsapp--button "GIF…" #'whatsapp-chat-attach-gif)
    (whatsapp--button "Retry images" #'whatsapp-retry-images)
    (whatsapp--button "Check delivery" #'whatsapp-connection-panel)
    (whatsapp--button "Record voice" #'whatsapp-chat-record-voice)
    (whatsapp--button "File…" #'whatsapp-chat-attach-original)
    (whatsapp--button "Emoji" #'whatsapp-insert-emoji)
    (whatsapp--button "Encrypted send" #'whatsapp-chat-send-encrypted)
    (whatsapp--button "Clear local send notes" #'whatsapp-clear-send-notes)
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
    (whatsapp-chat--schedule-prefetch)
    (whatsapp-chat--paint-outgoing)))

(defun whatsapp--refresh (path render current)
  "Refresh PATH once, recognizing v2 snapshots and legacy arrays.
Do not erase history on invalid data, account changes, or transport failure."
  (if whatsapp--refresh-pending
      (when (called-interactively-p 'any) (setq whatsapp--refresh-again t))
    (setq whatsapp--refresh-pending t)
    (force-mode-line-update)
    (let ((buffer (current-buffer)) (origin (whatsapp--origin-key))
          (had-snapshot whatsapp--has-snapshot))
      (condition-case nil
          (whatsapp--request-async
           "GET" path nil
           (lambda (result)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq whatsapp--refresh-pending nil)
                 (condition-case nil
                     (progn
                       (unless (and (not whatsapp--closing) (equal origin (whatsapp--origin-key))
                                    (whatsapp--ok-p (car result))) (error "Invalid context/HTTP"))
                       (let* ((body (cdr result))
                              (v2 (and (listp body) (equal (cdr (assoc "version" body)) 2)))
                              (same (and v2 (eq (cdr (assoc "unchanged" body)) t)))
                              (revision (and v2 (cdr (assoc "revision" body))))
                              (records (if v2 (cdr (assoc (if whatsapp-chat--jid "messages" "chats") body)) body)))
                         (unless (and (listp body)
                                      (if v2 (and (stringp revision) (< 0 (length revision) 256)
                                                  (assoc "unchanged" body)
                                                  (memq (cdr (assoc "unchanged" body)) '(nil t))
                                                  (or (not same) (equal revision whatsapp--read-revision))
                                                  (or same (assoc (if whatsapp-chat--jid "messages" "chats") body)))
                                        t)
                                      (or same (and (listp records) (whatsapp--records-p records))))
                           (error "Invalid snapshot"))
                         (when (and v2 whatsapp-chat--jid)
                           (let ((total (cdr (assoc "total" body))) (limit (cdr (assoc "limit" body))))
                             (unless (and (integerp total) (>= total 0)
                                          (integerp limit) (<= 1 limit 10000)
                                          (memq (cdr (assoc "has_more" body)) '(nil t))
                                          (or same (and (<= (length records) limit) (<= (length records) total))))
                               (error "Invalid window"))
                             (setq whatsapp-chat--total total
                                   whatsapp-chat--has-more (eq (cdr (assoc "has_more" body)) t))))
                         (setq whatsapp--read-v2 v2 whatsapp--read-revision revision
                               whatsapp--read-origin origin
                               whatsapp--has-snapshot t whatsapp--last-refresh-time (float-time)
                               whatsapp--async-media (and v2 (eq (cdr (assoc "async_media" body)) t))
                               whatsapp--last-error nil whatsapp--refresh-failures 0
                               whatsapp--next-refresh 0)
                         (unless (or same (and had-snapshot (equal records (funcall current))
                                               (or (not whatsapp-chat--jid)
                                                   (eq whatsapp-chat--has-more whatsapp-chat--rendered-has-more))))
                           (funcall render records))
                         (when (and whatsapp-chat--jid (not same))
                           (whatsapp-chat--reconcile-outgoing records))))
                   (error
                    (setq whatsapp--refresh-failures (1+ whatsapp--refresh-failures)
                          whatsapp--next-refresh (+ (float-time) (min 60 (* 2 (expt 2 (min 5 whatsapp--refresh-failures)))))
                          whatsapp--last-error "Refresh failed; cached history and draft retained")))
                 (force-mode-line-update)
                 (when (and whatsapp--refresh-again (not whatsapp--closing))
                   (setq whatsapp--refresh-again nil)
                   ;; Rebuild the requested limit/revision, rather than replaying
                   ;; the stale path captured before Load older or Send.
                   (if whatsapp-chat--jid (whatsapp-chat-refresh)
                     (whatsapp-root-refresh)))))))
        (error (setq whatsapp--refresh-pending nil
                     whatsapp--next-refresh (+ (float-time) 10)
                     whatsapp--last-error "Bridge request could not start"))))))


(defun whatsapp--record-p (record)
  "Validate fields used by rendering before a snapshot can replace the cache."
  (and (listp record)
       (cl-every (lambda (entry) (and (consp entry) (stringp (car entry)))) record)
       (let ((id (cdr (assoc (if whatsapp-chat--jid "id" "jid") record))))
         (and (stringp id) (> (length id) 0) (<= (length id) 256)))
       (cl-every (lambda (key) (let ((value (cdr (assoc key record))))
                                (or (null value) (stringp value))))
                 '("name" "text" "last" "from" "kind" "caption" "reply"))
       (memq (cdr (assoc "me" record)) '(nil t))
       (let ((unread (cdr (assoc "unread" record))))
         (or (null unread) (and (integerp unread) (>= unread 0))))
       (let ((ts (cdr (assoc "ts" record)))) (or (null ts) (stringp ts) (numberp ts)))
       (let ((media (cdr (assoc "media" record))))
         (and (listp media) (cl-every (lambda (entry) (and (consp entry) (stringp (car entry)))) media)))))

(defun whatsapp--records-p (records)
  "Reject malformed or duplicate record identities before mutating UI caches."
  (let ((seen (make-hash-table :test 'equal)))
    (cl-every (lambda (record)
                (when (whatsapp--record-p record)
                  (let ((key (cdr (assoc (if whatsapp-chat--jid "id" "jid") record))))
                    (unless (gethash key seen) (puthash key t seen) t)))) records)))


(defun whatsapp--conditional-path (path)
  "Append a last-known revision only for the same account."
  (if (and whatsapp--read-revision (equal whatsapp--read-origin (whatsapp--origin-key)))
      (concat path "&since=" (url-hexify-string whatsapp--read-revision)) path))

(defun whatsapp--common-prefix-length (left right)
  "Return the equal prefix length in linear time without repeated nth scans."
  (let ((count 0))
    (while (and left right (equal (car left) (car right)))
      (setq count (1+ count) left (cdr left) right (cdr right)))
    count))

(defun whatsapp-chat--ranges ()
  "Return buffer ranges of the currently rendered records."
  (let ((p (marker-position whatsapp-chat--history-start))
        (end (marker-position whatsapp-chat--history-end)) ranges)
    (while (< p end)
      (let ((next (next-single-property-change p 'whatsapp-msg nil end)))
        (when (get-text-property p 'whatsapp-msg) (push (cons p next) ranges))
        (setq p next)))
    (nreverse ranges)))

(defun whatsapp-chat--update-messages (messages)
  "Splice changed transcript tails or a sliding window without touching drafts."
  (let* ((limit (max 1 (or whatsapp-chat--history-limit whatsapp-history-page-size)))
         (new (last messages limit)) (old whatsapp-chat--rendered-messages)
         (ranges (and (markerp whatsapp-chat--history-start)
                      (marker-position whatsapp-chat--history-start)
                      (markerp whatsapp-chat--history-end)
                      (marker-position whatsapp-chat--history-end)
                      (whatsapp-chat--ranges))))
    (if (or (null old) (null new) (not (equal limit whatsapp-chat--last-limit))
            (not (eq whatsapp-chat--has-more whatsapp-chat--rendered-has-more))
            (/= (length ranges) (length old)))
        (whatsapp-chat--render messages)
      (let* ((prefix (whatsapp--common-prefix-length old new))
             (shift (cl-position (car new) old :test #'equal))
             (overlap (and shift (- (length old) shift)))
             (slide (and shift (> shift 0) (<= overlap (length new))
                         (equal (nthcdr shift old) (cl-subseq new 0 overlap))))
             (inhibit-read-only t) (buffer-undo-list t)
             (modified (buffer-modified-p))
             (windows (mapcar (lambda (w) (cons w (copy-marker (window-start w))))
                              (get-buffer-window-list (current-buffer) nil t))))
        (save-excursion
          (if slide
              (progn
                (delete-region whatsapp-chat--history-start (car (nth shift ranges)))
                (goto-char whatsapp-chat--history-end)
                (dolist (m (nthcdr overlap new)) (whatsapp--insert-message m)))
            (goto-char (if (< prefix (length ranges)) (car (nth prefix ranges))
                         whatsapp-chat--history-end))
            (delete-region (point) whatsapp-chat--history-end)
            (dolist (m (nthcdr prefix new)) (whatsapp--insert-message m)))
          (set-marker whatsapp-chat--history-end (point))
          (add-text-properties whatsapp-chat--history-start whatsapp-chat--history-end
                               '(read-only t front-sticky (read-only))))
        (setq whatsapp-chat--messages messages whatsapp-chat--rendered-messages new)
        (dolist (entry windows)
          (when (window-live-p (car entry)) (set-window-start (car entry) (cdr entry) t))
          (set-marker (cdr entry) nil))
        (set-buffer-modified-p modified)
        (whatsapp-chat--schedule-prefetch)
        (whatsapp-chat--paint-outgoing)))))

(defun whatsapp-chat--prefetch-visible ()
  "Queue bounded visible images, without asking Emacs for forced redisplay."
  (when (and whatsapp-auto-load-images (display-graphic-p))
    (let ((budget (max 0 whatsapp-image-prefetch-count)) (seen (make-hash-table :test 'equal)))
      (dolist (span (whatsapp--visible-spans))
        (let ((pos (car span)) (end (cdr span)))
          (while (and (< pos end) (> budget 0))
            (let* ((record (get-text-property pos 'whatsapp-msg))
                   (id (cdr (assoc "id" record))) (kind (cdr (assoc "kind" record)))
                   (media (cdr (assoc "media" record))))
              (when (and id media (member kind '("image" "sticker")) (not (gethash id seen)))
                (puthash id t seen) (cl-decf budget) (whatsapp--queue-image id kind media)))
            (setq pos (next-single-property-change pos 'whatsapp-msg nil end)))))
      (whatsapp--schedule-media-redraw))))

(defun whatsapp-chat--scrolled (window _start)
  "Schedule prefetch for WINDOW's buffer, not an unrelated selected buffer."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'whatsapp-chat-mode)
        (whatsapp-chat--schedule-prefetch)))))

(defun whatsapp-chat--schedule-prefetch (&rest _ignored)
  "Coalesce scrolling using a wall-clock timer, never an already-expired idle time."
  (unless (or whatsapp--closing whatsapp--prefetch-timer (not whatsapp-auto-load-images))
    (let ((buffer (current-buffer)))
      (setq whatsapp--prefetch-timer
            (run-at-time 0.15 nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq whatsapp--prefetch-timer nil)
                               (unless whatsapp--closing (whatsapp-chat--prefetch-visible))))))))))

(defun whatsapp-chat-search ()
  "Search the currently loaded messages, not an invented full account index."
  (interactive)
  (goto-char (or whatsapp-chat--history-start (point-min)))
  (call-interactively #'isearch-forward))

(defun whatsapp-chat-message-context (event)
  "Open message actions at the mouse EVENT, not at an unrelated draft point."
  (interactive "e") (mouse-set-point event) (whatsapp-chat-message-menu))

(defun whatsapp-chat-refresh (&optional after-send)
  "Refresh the visible history window, using conditional v2 reads when supported."
  (interactive)
  (unless whatsapp-chat--jid (user-error "Open a WhatsApp chat first"))
  (when (and whatsapp--refresh-pending (or after-send (called-interactively-p 'any)))
    (setq whatsapp--refresh-again t))
  (unless whatsapp-chat--input-marker (whatsapp-chat--render nil))
  (whatsapp--refresh
   (whatsapp--conditional-path
    (concat "/chat?jid=" (url-hexify-string whatsapp-chat--jid) "&v=2&read="
            (if (whatsapp-chat--focused-p) "1" "0") "&limit="
            (number-to-string (min 10000 (max 1 (or whatsapp-chat--history-limit whatsapp-history-page-size))))))
   #'whatsapp-chat--update-messages (lambda () whatsapp-chat--messages)))

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
  "Require an unambiguous provider message ID; acceptance is not delivery."
  (when (and (whatsapp--ok-p (car result)) (listp (cdr result)))
    (let* ((top (cdr result)) (upstream (cdr (assoc "wuzapi_status" top)))
           (provider (cdr (assoc "data" top)))
           (data (and (listp provider) (cdr (assoc "data" provider))))
           (ids (and (listp data)
                     (mapcar #'cdr (cl-remove-if-not
                                    (lambda (entry) (member (car entry) '("Id" "ID" "id"))) data)))))
      (when (assoc "message_id" top) (push (cdr (assoc "message_id" top)) ids))
      (and (integerp upstream) (<= 200 upstream) (< upstream 300)
           (listp provider) (listp data) ids
           (cl-every (lambda (object)
                       (and (not (assoc "error" object))
                            (or (not (assoc "success" object)) (eq t (cdr (assoc "success" object))))))
                     (list top provider data))
           (cl-some (lambda (key) (assoc key data)) '("Id" "ID" "id"))
           (cl-every (lambda (id) (and (stringp id) (<= 1 (length id) 256)
                                       (not (string-match-p "[[:space:][:cntrl:]]" id))
                                       (equal id (car ids)))) ids)))))

(defun whatsapp-chat-send-input ()
  "Send once to the selected identity; keep a local status until history confirms it.
Provider acceptance is not recipient delivery.  Unconfirmed requests retain the
original draft and are never automatically resent."
  (interactive)
  (when whatsapp-chat--send-pending (user-error "A send is already in progress"))
  (unless whatsapp-chat--jid (user-error "Open a WhatsApp conversation first"))
  (when (and whatsapp--read-origin (not (equal whatsapp--read-origin (whatsapp--origin-key))))
    (user-error "Account changed; reopen this conversation before sending"))
  ;; Recompute from the actual chat, not a possibly stale cached target.
  (setq whatsapp-chat--target (whatsapp--target-of-jid whatsapp-chat--jid))
  (let* ((original (whatsapp-chat--current-input)) (input (string-trim original))
         (reply whatsapp-chat--reply) (buffer (current-buffer)) (origin (whatsapp--origin-key))
         (jid whatsapp-chat--jid) (target whatsapp-chat--target)
         (payload (append (list (cons "to" target) (cons "body" input))
                          (when (and reply (plist-get reply :participant))
                            (list (cons "reply_id" (plist-get reply :id))
                                  (cons "reply_participant" (plist-get reply :participant))
                                  (cons "reply_text" (or (plist-get reply :text) ""))))))
         entry handled)
    (unless (string-empty-p input)
      (when (> (length input) 65536) (user-error "Message exceeds the 65536-character limit"))
      (setq entry (whatsapp-chat--begin-outgoing input origin target)
            whatsapp-chat--send-pending t)
      (force-mode-line-update)
      (condition-case err
          (whatsapp--request-async
           "POST" "/send/verified" payload
           (lambda (result)
             (unless handled
               (setq handled t)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq whatsapp-chat--send-pending nil)
                   (if (and (not whatsapp--closing) (equal jid whatsapp-chat--jid)
                            (equal origin (whatsapp--origin-key)))
                       (progn
                         (whatsapp-chat--finish-outgoing entry result)
                         (if (whatsapp--send-accepted-p result)
                             (progn
                               (when (equal reply whatsapp-chat--reply) (setq whatsapp-chat--reply nil))
                               (when (equal original (whatsapp-chat--current-input))
                                 (let ((inhibit-read-only t))
                                   (delete-region whatsapp-chat--input-marker (point-max))))
                               (setq whatsapp--last-error nil)
                               ;; The visible accepted note survives a delayed/stale snapshot.
                               ;; A history/display failure is not a failed send.
                               ;; Keep the accepted note and do not let an exception
                               ;; escape the process callback or suggest resending.
                               (condition-case nil
                                   (whatsapp-chat-refresh t)
                                 (error
                                  (setq whatsapp--last-error
                                        "Message accepted; history refresh could not start. Do not resend; use Refresh.")))
                               (message "WhatsApp: %s"
                                        (or whatsapp--last-error
                                            "provider accepted an ID; delivery still awaits a receipt")))
                           (setq whatsapp--last-error
                                 (let* ((body (cdr-safe result))
                                        ;; JSON/transport failures can be sentinels, not alists.
                                        (reason (and (proper-list-p body)
                                                     (cdr (assoc "error" body)))))
                                   (if (member reason
                                               '("Verified send route unavailable. Install and activate the matching bridge before sending."
                                                 "Recipient acknowledgement mismatch. Draft retained; do not resend."
                                                 "Provider authentication failed. Draft retained; check the existing session configuration."
                                                 "Provider denied the request. Draft retained; check account permissions."
                                                 "Provider rejected the recipient or request. Draft retained; verify the contact identity."))
                                       reason
                                     "Unconfirmed send. Draft retained; check recipient before retrying.")))
                           (message "WhatsApp: %s" whatsapp--last-error)))
                     (setf (plist-get entry :state) 'unconfirmed)
                     ;; Keep the original draft and expose why this late response
                     ;; cannot be accepted in the current account/conversation.
                     ;; Never include the old token, recipient, or response body.
                     (setq whatsapp--last-error
                           "Account or conversation changed while sending. Draft retained; delivery unconfirmed.")
                     (whatsapp-chat--paint-outgoing))
                   (force-mode-line-update))))))
        (error
         (unless handled
           (setq handled t whatsapp-chat--send-pending nil)
           (setf (plist-get entry :state) 'unconfirmed)
           (whatsapp-chat--paint-outgoing))
         (force-mode-line-update)
         (signal (car err) (cdr err)))))))

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
           '(("Conversation tools…" . whatsapp-chat-tools)
             ("Archived conversations" . whatsapp-show-archived)
             ("Profile diagnostics" . whatsapp-profile-diagnostics)
             ("Open conversation…" . whatsapp-open-chat)
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
  (add-hook 'kill-buffer-hook #'whatsapp--cancel-buffer-work nil t)
  (add-hook 'window-scroll-functions #'whatsapp-chat--scrolled nil t)
  (setq-local truncate-lines nil)
  (setq-local line-spacing 0.1)
  (setq-local mode-line-process
              '(:eval (cond (whatsapp-chat--send-pending " · sending")
                            (whatsapp--refresh-pending " · refreshing")
                            (whatsapp--last-error " · offline"))))
  (setq-local header-line-format
              '(:eval (format " %s · %d loaded ·%s"
                              (whatsapp--chat-name whatsapp-chat--jid)
                              (length whatsapp-chat--rendered-messages)
                              (whatsapp--status-label)))))

;;; ---------------------------------------------------------------------------
;;; Open a chat
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun whatsapp-open-chat (jid)
  "Show the composer for JID first, then schedule bounded history work."
  (interactive
   (let* ((targets (whatsapp--forward-targets))
          (choice (completing-read "Open chat (name or number): " targets nil nil)))
     (list (or (cdr (assoc choice targets)) choice))))
  (unless (and (stringp jid) (<= 1 (length jid) 256)
               (not (string-match-p "[\000-\040\177]" jid)))
    (user-error "Enter a contact number or JID without spaces/control characters"))
  (let* ((started (float-time)) (buf (whatsapp--chat-buffer jid))
         (origin (whatsapp--origin-key)))
    (setq whatsapp--selected-chat jid)
    (with-current-buffer buf
      (when (and whatsapp--read-origin (not (equal whatsapp--read-origin origin)))
        (user-error "This conversation belongs to previous account settings; restore them or close the old buffer first"))
      (unless whatsapp-chat--input-marker
        (let ((cached whatsapp-chat--messages))
          (whatsapp-chat--render nil)
          (setq whatsapp-chat--messages cached))))
    (if (and whatsapp--workspace-active whatsapp-workspace-sidebar (> (frame-width) 90))
        (progn
          (display-buffer-in-side-window (whatsapp--root-buffer)
                                         '((side . left) (slot . 0) (window-width . 38)))
          (when-let ((main (cl-find-if (lambda (window) (not (window-parameter window 'window-side)))
                                      (window-list))))
            (select-window main))
          (switch-to-buffer buf))
      (pop-to-buffer buf))
    (when-let ((root (get-buffer "*WhatsApp*")))
      (with-current-buffer root (whatsapp-root--select-only jid)))
    (with-current-buffer buf
      (goto-char (point-max))
      (when (fboundp 'whatsapp-profiles--update-header) (whatsapp-profiles--update-header))
      (when (timerp whatsapp--open-timer) (cancel-timer whatsapp--open-timer))
      (cl-incf whatsapp--open-generation)
      (setq whatsapp--selection-phase 'composer-ready
            whatsapp--selection-seconds (- (float-time) started)
            whatsapp--open-timer (run-at-time 0.05 nil #'whatsapp--open-deferred
                                              buf whatsapp--open-generation origin)))
    (whatsapp--ensure-polling)))

(defun whatsapp-switch-chat ()
  "Switch to any cached conversation, including rows hidden by the root page.
Uses standard Emacs completion and never sends a message or performs synchronous
network lookup.  C-g cancels without touching the current draft."
  (interactive)
  (unless whatsapp--chats
    (user-error "No cached conversations yet; open WhatsApp and use Refresh"))
  (let* ((choices (mapcar
                   (lambda (chat)
                     (let ((jid (cdr (assoc "jid" chat))))
                       (cons (format "%s  <%s>"
                                     (whatsapp--row-text (or (cdr (assoc "name" chat)) jid))
                                     (whatsapp--row-text jid)) chat)))
                   whatsapp--chats))
         (completion-extra-properties
          (list :category 'whatsappel-chat
                :annotation-function
                (lambda (choice)
                  (let* ((chat (cdr (assoc choice choices)))
                         (unread (or (cdr (assoc "unread" chat)) 0)))
                    (concat (when (> unread 0) (format "  [%d unread]" unread))
                            "  " (truncate-string-to-width
                                   (whatsapp--row-text (or (cdr (assoc "last" chat)) ""))
                                   60 nil nil "…"))))))
         (choice (completing-read "Switch conversation: " choices nil t))
         (chat (cdr (assoc choice choices))))
    (when chat (whatsapp-open-chat (cdr (assoc "jid" chat))))))

(defun whatsapp-root-set-filter (filter)
  "Show chats matching FILTER: all, unread, pinned, groups, direct or archived."
  (setq whatsapp-root--filter filter whatsapp-root--limit nil)
  (whatsapp-root--render whatsapp--chats))

(defun whatsapp-root-search (query)
  "Filter known chat names, JIDs, and message previews by literal QUERY."
  (interactive (list (read-string "Find chat: " whatsapp-root--query)))
  (setq whatsapp-root--query query whatsapp-root--limit nil)
  (whatsapp-root--render whatsapp--chats))

(defun whatsapp-root--visible-p (chat)
  "Whether CHAT matches the active dashboard filters."
  (and (if (eq whatsapp-root--filter 'archived)
           (whatsapp-tools--flag (cdr (assoc "jid" chat)) :archived)
         (not (whatsapp-tools--flag (cdr (assoc "jid" chat)) :archived)))
       (pcase whatsapp-root--filter
         ('pinned (whatsapp-tools--flag (cdr (assoc "jid" chat)) :pinned))
         ('unread (> (or (cdr (assoc "unread" chat)) 0) 0))
         ('groups (string-suffix-p "@g.us" (or (cdr (assoc "jid" chat)) "")))
         ('direct (not (string-suffix-p "@g.us" (or (cdr (assoc "jid" chat)) ""))))
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

(defun whatsapp-root--insert-row (c width)
  "Insert a single clickable conversation row at WIDTH."
  (let* ((beg (point)) (jid (cdr (assoc "jid" c)))
               (name (whatsapp--row-text (or (cdr (assoc "name" c)) jid "Unknown")))
               (unread (or (cdr (assoc "unread" c)) 0))
         (badge (concat (when (whatsapp-tools--flag jid :pinned) " ★")
                        (if (> unread 0) (format " [%s]" (if (> unread 999) "999+" unread)) "")))
               (time (whatsapp--fmt-ts (cdr (assoc "ts" c)))))
          (when (fboundp 'whatsapp-profiles--insert-avatar) (whatsapp-profiles--insert-avatar jid))
          (insert (propertize (truncate-string-to-width name (max 8 (- width 5 (length badge))) nil nil "…")
                              'face (whatsapp-profiles--row-face (equal jid whatsapp--selected-chat))))
          (insert (propertize badge 'face 'whatsapp-accent) "\n")
          (unless whatsapp-root--compact
            (insert (propertize (truncate-string-to-width
                                (concat (unless (string-empty-p time) (concat time "  "))
                                        (whatsapp--row-text (or (cdr (assoc "last" c)) ""))) width nil nil "…") 'face 'shadow) "\n"))
          (add-text-properties beg (point) (list 'whatsapp-jid jid 'mouse-face (whatsapp-profiles--hover-face)
                                                'help-echo "Click or Enter to open; / to search"
                                                'keymap whatsapp-root-row-map 'rear-nonsticky t))
          (when (fboundp 'whatsapp-profiles--decorate-row) (whatsapp-profiles--decorate-row beg (point) jid))))

(defun whatsapp-root--layout-key (chats matching visible limit width)
  "Return the structural key that permits in-place row replacement."
  (list width limit whatsapp-root--query whatsapp-root--filter whatsapp-root--compact
        (length chats) (length matching) whatsapp--has-snapshot
        (mapcar (lambda (c) (cdr (assoc "jid" c))) visible)))

(defun whatsapp-root--summary (chats)
  "Return the count line without treating unread changes as layout changes."
  (format "%d chats · %d unread\n" (length chats)
          (cl-count-if (lambda (c) (> (or (cdr (assoc "unread" c)) 0) 0)) chats)))

(defun whatsapp-root--update-summary (chats)
  "Update only the summary line when its count changes."
  (when-let ((beg (text-property-any (point-min) (point-max) 'whatsapp-root-summary t)))
    (let* ((end (next-single-property-change beg 'whatsapp-root-summary nil (point-max)))
           (label (whatsapp-root--summary chats))
           (inhibit-read-only t) (buffer-undo-list t))
      (unless (equal label (buffer-substring-no-properties beg end))
        (save-excursion
          (goto-char beg)
          (delete-region beg end)
          (insert (propertize label 'face 'shadow 'whatsapp-root-summary t
                              'rear-nonsticky t)))))))

(defun whatsapp-root-toggle-density ()
  "Toggle one/two-line conversation rows without fetching or losing filters."
  (interactive)
  (setq whatsapp-root--compact (not whatsapp-root--compact))
  (whatsapp-root--render whatsapp--chats))

(defun whatsapp-root--update (chats)
  "Replace changed rows only when ordering, filters and layout are unchanged."
  (let* ((matching (whatsapp-tools--ordered (cl-remove-if-not #'whatsapp-root--visible-p chats)))
         (limit (max 1 (or whatsapp-root--limit whatsapp-root-page-size)))
         (visible (cl-subseq matching 0 (min limit (length matching))))
         (window (get-buffer-window (current-buffer) t))
         (width (max 24 (min 95 (- (if (window-live-p window) (window-body-width window) 38) 2))))
         (key (whatsapp-root--layout-key chats matching visible limit width)))
    (if (or (null visible) (not (equal key whatsapp-root--render-key)))
        (whatsapp-root--render chats)
      (whatsapp-root--update-summary chats)
      (let ((pos (point-min)) ranges)
        (while (< pos (point-max))
          (let ((end (next-single-property-change pos 'whatsapp-jid nil (point-max))))
            (when (get-text-property pos 'whatsapp-jid) (push (cons pos end) ranges))
            (setq pos end)))
        (setq ranges (nreverse ranges))
        (if (/= (length ranges) (length visible))
            (whatsapp-root--render chats)
          (let* ((inhibit-read-only t) (buffer-undo-list t)
                 (at (get-text-property (point) 'whatsapp-jid))
                 (offset (and at (- (point) (whatsapp-root--chat-position at))))
                 (windows (mapcar (lambda (w) (cons w (copy-marker (window-start w))))
                                  (get-buffer-window-list (current-buffer) nil t))))
            (save-excursion
              (dolist (triple (reverse (cl-mapcar #'list whatsapp-root--shown visible ranges)))
                (let* ((old (nth 0 triple)) (new (nth 1 triple)) (range (nth 2 triple))
                       (jid (cdr (assoc "jid" new))))
                  (when (or (not (equal old new))
                            (not (eq (equal jid whatsapp-root--shown-selection)
                                     (equal jid whatsapp--selected-chat))))
                    (delete-region (car range) (cdr range))
                    (goto-char (car range))
                    (whatsapp-root--insert-row new width)))))
            (setq whatsapp-root--shown visible whatsapp-root--shown-selection whatsapp--selected-chat)
            (when at
              (when-let ((start (whatsapp-root--chat-position at)))
                (goto-char (min (+ start offset)
                                (1- (next-single-property-change start 'whatsapp-jid nil (point-max)))))))
            (dolist (entry windows)
              (when (window-live-p (car entry)) (set-window-start (car entry) (cdr entry) t))
              (set-marker (cdr entry) nil))
            (set-buffer-modified-p nil)))))))

(defun whatsapp-chat-focus-input ()
  "Move to the current draft without network work or changing its contents."
  (interactive)
  (unless whatsapp-chat--input-marker (user-error "Open a conversation first"))
  (goto-char (point-max))
  (when (eq (current-buffer) (window-buffer (selected-window))) (recenter -2)))

(defun whatsapp-root--render (chats)
  "Render a bounded, width-aware two-line conversation list with native buttons."
  (let* ((inhibit-read-only t)
         (jid-at-point (get-text-property (point) 'whatsapp-jid))
         (old-point (point))
         (matching (whatsapp-tools--ordered (cl-remove-if-not #'whatsapp-root--visible-p chats)))
         (limit (max 1 (or whatsapp-root--limit whatsapp-root-page-size)))
         (visible (cl-subseq matching 0 (min limit (length matching))))
         (window (get-buffer-window (current-buffer) t))
         (width (max 24 (min 95 (- (if (window-live-p window) (window-body-width window) 38) 2)))))
    (setq whatsapp-root--render-key (whatsapp-root--layout-key chats matching visible limit width)
          whatsapp-root--shown visible whatsapp-root--shown-selection whatsapp--selected-chat)
    (erase-buffer)
    (insert (propertize "WhatsAppel\n" 'face 'whatsapp-title))
    (insert (propertize (whatsapp-root--summary chats) 'face 'shadow
                        'whatsapp-root-summary t 'rear-nonsticky t))
    (whatsapp--button "Search" #'whatsapp-root-search)
    (whatsapp--button "Switch" #'whatsapp-switch-chat)
    (whatsapp--button "New" #'whatsapp-open-chat)
    (whatsapp--button "Refresh" #'whatsapp-root-refresh)
    (whatsapp--button "Settings" #'whatsapp-profile-settings)
    (whatsapp--button "Commands" #'whatsapp-command-menu)
    (whatsapp--button "Check delivery" #'whatsapp-connection-panel)
    (insert "\n")
    (whatsapp--button (if whatsapp-root--compact "Detailed rows" "Compact rows")
                      #'whatsapp-root-toggle-density)
    (insert "\n")
    (dolist (item '((all . "Inbox") (unread . "Unread") (pinned . "Pinned")
                    (direct . "Direct") (groups . "Groups") (archived . "Archived")))
      (let ((filter (car item)))
        (insert-text-button (format " %s " (cdr item)) 'follow-link t
                            'face (if (eq filter whatsapp-root--filter) 'whatsapp-accent 'button)
                            'action (lambda (_b) (whatsapp-root-set-filter filter)))))
    (insert "\n")
    (unless (string-empty-p whatsapp-root--query)
      (insert (truncate-string-to-width (concat "Search: " whatsapp-root--query) width nil nil "…") "\n")
      (insert-text-button "Clear search" 'follow-link t 'action (lambda (_b) (whatsapp-root-search "")))
      (insert "\n"))
    (insert "\n")
    (if (null visible)
        (progn
          (insert (if chats "No matching conversations.\n" (if whatsapp--has-snapshot "No retained conversations.\n" "Loading conversations from the bridge…\n")))
          (whatsapp--button "Connect" #'whatsapp-connect)
          (whatsapp--button "Show QR" #'whatsapp-qr)
          (insert "\n")
          (whatsapp--button "Status" #'whatsapp-status)
          (whatsapp--button "Sync history" #'whatsapp-sync)
          (insert "\n"))
      (dolist (c visible) (whatsapp-root--insert-row c width)))
    (when (> (length matching) (length visible))
      (insert "\n")
      (insert-text-button (format "More chats (%d remaining)" (- (length matching) (length visible)))
                          'follow-link t 'action (lambda (_b) (whatsapp-root-show-more)))
      (insert "\n"))
    (insert (propertize "\nn/p navigate · Enter opens\n/ searches · j switches · d density\na archive/restore · P pin · m chat tools\n? commands · i contact photo\n" 'face 'shadow))
    (goto-char (or (and jid-at-point (whatsapp-root--chat-position jid-at-point)) (min old-point (point-max)))))
  (set-buffer-modified-p nil))


(defun whatsapp--row-text (text)
  "Flatten controls and bidirectional layout overrides for conversation rows."
  (replace-regexp-in-string "[\000-\037\177\u202a-\u202e\u2066-\u2069]+" " " text))

(defun whatsapp-root-show-more ()
  "Reveal another bounded page of the already-cached conversation list."
  (interactive)
  (setq whatsapp-root--limit (+ (or whatsapp-root--limit whatsapp-root-page-size)
                               (max 1 whatsapp-root-page-size)))
  (whatsapp-root--render whatsapp--chats))

(defun whatsapp-next-unread ()
  "Open the next unread chat from the cached list, without synchronous lookup."
  (interactive)
  (let* ((unread (cl-remove-if-not
                  (lambda (c) (and (> (or (cdr (assoc "unread" c)) 0) 0)
                                   (not (whatsapp-tools--flag (cdr (assoc "jid" c)) :archived))))
                  whatsapp--chats))
         (at (cl-position whatsapp-chat--jid unread :key (lambda (c) (cdr (assoc "jid" c))) :test #'equal))
         (next (and unread (nth (if at (mod (1+ at) (length unread)) 0) unread))))
    (unless next (user-error "No unread cached conversations"))
    (whatsapp-open-chat (cdr (assoc "jid" next)))))

(defun whatsapp--root-buffer ()
  "Get or create the root chat-list buffer."
  (let ((buf (get-buffer-create "*WhatsApp*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'whatsapp-root-mode) (whatsapp-root-mode)))
    buf))

(defun whatsapp-root-refresh ()
  "Refresh the cached conversation list without re-fetching unchanged snapshots."
  (interactive)
  (with-current-buffer (whatsapp--root-buffer)
    (when (= (buffer-size) 0) (whatsapp-root--render whatsapp--chats))
    (when (fboundp 'whatsapp-session-refresh) (whatsapp-session-refresh))
    (whatsapp--refresh (whatsapp--conditional-path "/chats?v=2")
                       (lambda (chats) (setq whatsapp--chats chats)
                         (whatsapp-root--update chats)
                         (when (fboundp 'whatsapp-profiles-start) (whatsapp-profiles-start)))
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
    (define-key map (kbd "j")   #'whatsapp-switch-chat)
    (define-key map (kbd "d")   #'whatsapp-root-toggle-density)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `whatsapp-root-mode'.")

(define-derived-mode whatsapp-root-mode special-mode "WA-Root"
  "Major mode for the WhatsApp chat list (telega-style root buffer)."
  (add-hook 'kill-buffer-hook #'whatsapp--cancel-buffer-work nil t)
  (setq-local header-line-format '(:eval (whatsapp--status-label)))
  (setq-local line-spacing 0.1)
  (setq-local mode-line-process
              '(:eval (cond (whatsapp--refresh-pending " · refreshing")
                            (whatsapp--last-error " · offline")))))

;;; ---------------------------------------------------------------------------
;;; Entry, session, polling
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun whatsapp ()
  "Show cached chats immediately, then refresh from the bridge."
  (interactive)
  (let ((buffer (whatsapp--root-buffer)))
    (with-current-buffer buffer
      (when (zerop (buffer-size)) (whatsapp-root--render whatsapp--chats)))
    (pop-to-buffer buffer)
    (whatsapp-root-refresh)
    (whatsapp--ensure-polling)))

;;;###autoload
(defun whatsapp-connect ()
  "Open session recovery; connect is a separately confirmed action in the panel."
  (interactive)
  (whatsapp-connection-panel))

;;;###autoload
(defun whatsapp-status ()
  "Show redacted account-scoped connection status, never raw provider credentials."
  (interactive)
  (whatsapp-connection-panel))

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
  "Fetch a linking QR asynchronously for this account; never save it to disk."
  (interactive)
  (unless (and (display-graphic-p) (image-type-available-p 'png))
    (user-error "Use graphical Emacs with PNG support to display a private pairing QR"))
  (let ((origin (whatsapp--origin-key)))
    (whatsapp--request-async
     "GET" "/qr" nil
     (lambda (result)
       (when (equal origin (whatsapp--origin-key))
         (condition-case nil
             (let* ((top (cdr result))
                    (provider (and (proper-list-p top) (cdr (assoc "data" top))))
                    (data (and (proper-list-p provider) (cdr (assoc "data" provider))))
                    (qr (and (proper-list-p data) (cdr (assoc "QRCode" data)))))
               (unless (and (whatsapp--ok-p (car result)) (stringp qr)
                            (<= (length qr) (* 512 1024)))
                 (error "QR unavailable"))
               (let* ((b64 (string-remove-prefix "data:image/png;base64," qr))
                      (png (base64-decode-string b64))
                      (image (and (<= 24 (length png) (* 384 1024))
                                  (string-prefix-p (unibyte-string 137 80 78 71 13 10 26 10) png)
                                  (<= 1 (whatsapp--uint png 16 4 nil) 2048)
                                  (<= 1 (whatsapp--uint png 20 4 nil) 2048)
                                  (create-image png 'png t))))
                 (unless image (error "Invalid QR image"))
                 (with-current-buffer (get-buffer-create "*whatsapp-qr*")
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert "Private linking QR — scan with WhatsApp Linked Devices.\n\n")
                     (insert-image image))
                   (buffer-disable-undo)
                   (setq-local buffer-offer-save nil)
                   (special-mode)
                   (display-buffer (current-buffer)))))
           (error (message "No usable QR returned. Check the session panel; connect first if disconnected. No credentials were printed."))))))))

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

(defun whatsapp--visible-buffers ()
  "Return unique buffers in visible, non-minibuffer windows.
Visit frame/window lists, not every buffer in a long-running Emacs session.
Iconified and invisible frames do not trigger automatic network reads."
  (let (buffers)
    (dolist (frame (frame-list))
      (when (eq (frame-visible-p frame) t)
        (dolist (window (window-list frame 'no-minibuffer))
          (cl-pushnew (window-buffer window) buffers :test #'eq))))
    (nreverse buffers)))

(defun whatsapp--poll ()
  "Refresh each visible conversation/root once, respecting failure backoff."
  (let ((now (float-time)))
    (dolist (buf (whatsapp--visible-buffers))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (and (not whatsapp--closing) (>= now whatsapp--next-refresh))
            (condition-case nil
                (cond ((derived-mode-p 'whatsapp-chat-mode) (whatsapp-chat-refresh))
                      ((derived-mode-p 'whatsapp-root-mode) (whatsapp-root-refresh)))
              (error
               ;; A single broken buffer must not starve other visible chats.
               ;; Do not expose exception arguments or credentials in the header.
               (setq whatsapp--last-error "Automatic refresh failed; use Refresh to retry"
                     whatsapp--next-refresh (+ now (max 1 whatsapp-poll-interval)))
               (force-mode-line-update)))))))))

;;;###autoload
(defun whatsapp--ensure-polling ()
  "Start one poll timer for the UI without overriding an explicit pause."
  (when (and whatsapp-auto-poll (not whatsapp--polling-paused) (not whatsapp--poll-timer))
    (unless (and (numberp whatsapp-poll-interval) (>= whatsapp-poll-interval 1))
      (user-error "Polling interval must be at least one second"))
    (setq whatsapp--poll-timer
          (run-with-timer whatsapp-poll-interval whatsapp-poll-interval #'whatsapp--poll))))

(defun whatsapp-toggle-polling ()
  "Pause or resume polling; reopening a chat respects an explicit pause."
  (interactive)
  (if whatsapp--poll-timer
      (progn (cancel-timer whatsapp--poll-timer)
             (setq whatsapp--poll-timer nil whatsapp--polling-paused t)
             (message "WhatsApp: polling paused"))
    (setq whatsapp--polling-paused nil)
    (let ((whatsapp-auto-poll t)) (whatsapp--ensure-polling))
    (message "WhatsApp: polling resumed")))

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

(defun whatsapp--pq-cache-key (jid id blob)
  "Scope decrypted plaintext to the bridge/account as well as peer/message."
  (list (whatsapp--origin-key) jid id blob))

(defun whatsapp--insert-pq (me blob id)
  "Render cached plaintext or a Decrypt control; never run pqenv or inspect keys."
  (let* ((key (whatsapp--pq-cache-key whatsapp-chat--jid id blob))
         (cached (if me (gethash blob whatsapp-pq--sent-cache)
                   (gethash key whatsapp-pq--plain-cache))))
    (cond ((stringp cached)
           (insert (propertize "[PQ] " 'face 'success))
           (whatsapp--insert-bounded-text cached))
          (me (insert (propertize "[encrypted, sent]" 'face 'shadow)))
          (t
           (let ((beg (point)))
             (insert-text-button
              (pcase cached
                (:stale "[encrypted: rejected as stale/replayed · Decrypt]")
                (:fail "[encrypted: verification did not complete · Decrypt]")
                (_ "[encrypted message · Decrypt]"))
              'follow-link t 'help-echo "Explicit asynchronous verification; never sends a message"
              'action (lambda (_button) (whatsapp-chat-decrypt id blob)))
             (add-text-properties beg (point) (list 'whatsapp-pq-key key)))))))

(defun whatsapp--pq-show-ready (key plaintext)
  "Update only the display of KEY's buttons; preserve draft text and undo offsets."
  (let ((p (point-min)) (inhibit-read-only t) (buffer-undo-list t)
        (modified (buffer-modified-p)))
    (while (< p (point-max))
      (let ((end (next-single-property-change p 'whatsapp-pq-key nil (point-max))))
        (when (equal key (get-text-property p 'whatsapp-pq-key))
          (put-text-property p end 'display
                             (concat "[PQ] " (substring plaintext 0 (min 2048 (length plaintext)))
                                     (if (> (length plaintext) 2048) "… [click for full text]" "")))
          (put-text-property p end 'help-echo "Verified plaintext; click to read the original in pages"))
        (setq p end)))
    (set-buffer-modified-p modified)))

(defun whatsapp-chat-decrypt (id blob)
  "Explicitly verify/decrypt BLOB in an owned bounded child, without shell commands.
Cached plaintext opens locally. Neither starting this operation nor its completion
sends a WhatsApp message. A failure or timeout is never retried automatically."
  (let* ((buffer (current-buffer)) (origin (whatsapp--origin-key))
         (key (whatsapp--pq-cache-key whatsapp-chat--jid id blob))
         (cached (gethash key whatsapp-pq--plain-cache))
         (default-directory (expand-file-name "~/")))
    (if (stringp cached) (whatsapp--show-full-text cached)
      (when (and whatsapp--pq-process (process-live-p whatsapp--pq-process))
        (user-error "One decryption is already running in this conversation"))
      (unless (and (stringp blob) (<= (string-bytes blob) (* 1024 1024)))
        (user-error "Encrypted preview exceeds the 1 MiB limit"))
      (when (file-remote-p whatsapp-pq-dir) (user-error "Use a local PQ key directory"))
      (unless (and (whatsapp-pq-ready-p) (whatsapp-pq-have-contact-p whatsapp-chat--jid))
        (user-error "Set up your PQ identity and import this contact's verified public key first"))
      (let ((program (executable-find whatsapp-pq-program)))
        (unless program (user-error "pqenv is not installed"))
        (let* ((directory (whatsapp--private-directory))
               input
               (generation (cl-incf whatsapp--pq-generation))
               (process-environment (whatsapp--media-environment))
               (size 0) (err-size 0) chunks done proc errpipe)
          (cl-labels
              ((finish (state)
                 (unless done
                   (setq done t)
                   (let ((text (when (eq state 'ok)
                                 (decode-coding-string (apply #'concat (nreverse chunks)) 'utf-8))))
                     (setq chunks nil)
                     (when (and proc (process-live-p proc)) (delete-process proc))
                     (when (and errpipe (process-live-p errpipe)) (delete-process errpipe))
                     (ignore-errors (delete-directory directory t))
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (when (= generation whatsapp--pq-generation)
                           (when (timerp whatsapp--pq-timer) (cancel-timer whatsapp--pq-timer))
                           (setq whatsapp--pq-timer nil whatsapp--pq-process nil)
                           (when (and (not whatsapp--closing) (equal origin (whatsapp--origin-key)))
                             (whatsapp-pq--cache-put key (or text state) whatsapp-pq--plain-cache)
                             (if text (whatsapp--pq-show-ready key text)
                               (message "WhatsApp: decryption/verification did not complete; no automatic retry"))))))))))
            (condition-case nil
                (progn
                  (setq input (whatsapp--private-write directory (encode-coding-string blob 'utf-8) ".pq"))
                  (setq errpipe (make-pipe-process :name "whatsapp-pq-errors" :noquery t
                                                   :buffer nil :filter
                                                   (lambda (_process bytes)
                                                     (cl-incf err-size (string-bytes bytes))
                                                     (when (> err-size 65536) (finish :fail)))))
                  (setq proc
                        (make-process
                         :name "whatsapp-pq-open" :buffer nil :noquery t :connection-type 'pipe
                         :coding 'binary :stderr errpipe
                         :command (append (list program "open" "--identity" (whatsapp-pq--identity-secret)
                                                "--sender" (whatsapp-pq--contact-file whatsapp-chat--jid)
                                                "--in" input)
                                          (when (> whatsapp-pq-max-age 0)
                                            (list "--max-age" (number-to-string whatsapp-pq-max-age))))
                         :filter (lambda (_process bytes)
                                   (cl-incf size (string-bytes bytes))
                                   (if (> size (* 1024 1024)) (finish :fail) (push bytes chunks)))
                         :sentinel (lambda (process _event)
                                     (when (memq (process-status process) '(exit signal failed))
                                       (finish (pcase (process-exit-status process)
                                                 (0 'ok) (3 :stale) (_ :fail)))))))
                  (unless done
                    (setq whatsapp--pq-process proc
                          whatsapp--pq-timer (run-at-time 10 nil (lambda () (finish :fail)))))
                  (process-send-eof proc))
              (error (finish :fail)))))))))

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
  "Expand the requested retained-history window, preserving the current draft."
  (interactive)
  (setq whatsapp-chat--history-limit
        (min 10000 (+ (or whatsapp-chat--history-limit (max 1 whatsapp-history-page-size))
                      (max 1 whatsapp-history-page-size))))
  (if whatsapp--read-v2
      (progn (setq whatsapp--read-revision nil) (whatsapp-chat-refresh t))
    (whatsapp-chat--render whatsapp-chat--messages)))

(defun whatsapp--schedule-media-redraw ()
  "Coalesce image display updates without rebuilding history or the composer."
  (unless whatsapp-chat--redraw-timer
    (let ((buffer (current-buffer)))
      (setq whatsapp-chat--redraw-timer
            (run-at-time
             0.12 nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq whatsapp-chat--redraw-timer nil)
                   (whatsapp--refresh-image-displays)))))))))


(defun whatsapp--refresh-image-displays ()
  "Decode at most one ready visible image per tick; never rebuild the composer."
  (when (and whatsapp-auto-load-images (display-graphic-p) (not whatsapp--closing))
    (let ((budget 1) more (inhibit-read-only t) (buffer-undo-list t)
          (modified (buffer-modified-p)))
      (dolist (span (whatsapp--visible-spans))
        (let ((p (car span)) (last (cdr span)))
          (while (< p last)
            (let* ((end (next-single-property-change p 'whatsapp-id nil last))
                   (id (get-text-property p 'whatsapp-id))
                   (kind (get-text-property p 'whatsapp-kind))
                   (key (and id (whatsapp--media-key id kind)))
                   (uri (and key (gethash key whatsapp--media-cache))))
              (when (and uri (member kind '("image" "sticker"))
                         (not (get-text-property p 'display))
                         (not (get-text-property p 'whatsapp-preview-failed)))
                (if (<= budget 0) (setq more t)
                  (cl-decf budget)
                  (condition-case nil
                      (let* ((type (whatsapp--image-type-from-mime (whatsapp--data-uri-mime uri)))
                             (image (and type (image-type-available-p type)
                                         (whatsapp--preview-image key uri type kind))))
                        (with-silent-modifications
                          (if image (put-text-property p end 'display image)
                            (put-text-property p end 'whatsapp-preview-failed t))))
                    (error (put-text-property p end 'whatsapp-preview-failed t)))))
              (setq p end)))))
      (set-buffer-modified-p modified)
      (when more (whatsapp--schedule-media-redraw)))))

(defun whatsapp--download-async (payload callback)
  "Download PAYLOAD once; all job polls belong to the originating chat buffer."
  (if (not whatsapp--async-media)
      (whatsapp--request-async "POST" "/download" payload callback)
    (let ((origin (whatsapp--origin-key)) (buffer (current-buffer))
          (deadline (+ (float-time) whatsapp-request-timeout)) done timer)
      (cl-labels
          ((finish (result)
             (unless done
               (setq done t)
               (when timer (cancel-timer timer))
               (if (buffer-live-p buffer)
                   (with-current-buffer buffer (funcall callback result))
                 (funcall callback result))))
           (valid () (and (buffer-live-p buffer) (equal origin (whatsapp--origin-key))
                          (not (buffer-local-value 'whatsapp--closing buffer))))
           (poll (id)
             (cond
              ((not (valid)) (finish '(nil ("error" . "Media context closed or changed"))))
              ((>= (float-time) deadline) (finish '(nil ("error" . "Media job timed out"))))
              (t
               (with-current-buffer buffer
                 (condition-case nil
                     (whatsapp--request-async
                      "GET" (concat "/media-job?id=" (url-hexify-string id)) nil
                      (lambda (result)
                        (cond ((not (valid)) (finish '(nil ("error" . "Media context changed"))))
                              ((eq (car result) 202)
                               (setq timer (run-at-time 0.4 nil (lambda () (poll id)))))
                              (t (finish result)))))
                   (error (finish '(nil ("error" . "Media result request failed"))))))))))
        (whatsapp--request-async
         "POST" "/download?async=1" payload
         (lambda (result)
           (let ((id (and (listp (cdr result)) (cdr (assoc "job" (cdr result))))))
             (if (and (eq (car result) 202) (stringp id) (< (length id) 160))
                 (poll id)
               (finish result)))))))))

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
     ((equal mime "image/gif") (whatsapp-gif-open bytes))
     ((string-prefix-p "video/" mime) (whatsapp-video-open bytes mime))
     ((string-prefix-p "audio/" mime) (whatsapp--play-bytes bytes mime nil))
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
                           (message "WhatsApp: attachment accepted by upstream; delivery not yet confirmed"))
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
  ;; External credentials are one account, not per-key overrides of init state.
  ;; Validate the pair before mutating either setting or starting any HTTP work.
  (let ((origin (getenv "WHATSAPPEL_BRIDGE_URL"))
        (token (getenv "WHATSAPPEL_TOKEN")))
    (when (or origin token)
      (unless (and token (not (string-empty-p token))
                   (<= (length token) 4096) (string-match-p "\\`[!-~]+\\'" token))
        (user-error "External bridge URL requires its matching token; remove external settings to use the Emacs-init account"))
      (when (and origin (string-empty-p origin))
        (user-error "External bridge origin is empty"))
      (setq whatsapp-bridge-url (or origin "http://127.0.0.1:7337")
            whatsapp-bridge-token token)))
  (setq whatsapp--workspace-active t)
  (when (equal whatsapp-media-player "xdg-open") (setq whatsapp-media-player "mpv"))
  (whatsapp)
  (whatsapp--ensure-polling)
  (message "WhatsAppel: select a conversation; Connect / Show QR are available on the dashboard"))

(define-key whatsapp-chat-mode-map (kbd "C-c C-j") #'whatsapp-switch-chat)
(define-key whatsapp-root-mode-map (kbd "C-c C-j") #'whatsapp-switch-chat)
(define-key whatsapp-chat-mode-map (kbd "C-c C-b") #'whatsapp-chat-focus-input)
(define-key whatsapp-chat-mode-map [mouse-3] #'whatsapp-chat-message-context)
(define-key whatsapp-chat-mode-map (kbd "C-c .") #'whatsapp-chat-message-menu)
(define-key whatsapp-chat-mode-map (kbd "C-c /") #'whatsapp-chat-search)
(define-key whatsapp-chat-mode-map (kbd "M-g u") #'whatsapp-next-unread)
(define-key whatsapp-root-mode-map (kbd "M-g u") #'whatsapp-next-unread)
(define-key whatsapp-root-mode-map (kbd "TAB") #'forward-button)
(define-key whatsapp-root-mode-map (kbd "<backtab>") #'backward-button)

;; Load the small enrichment module only after all core modes/functions exist.
;; Its hooks register the native UI; loading it never initiates network work.
(load (expand-file-name "whatsapp-profiles.el" whatsapp--source-directory) nil t)
(load (expand-file-name "whatsapp-delivery.el" whatsapp--source-directory) nil t)
(load (expand-file-name "whatsapp-tools.el" whatsapp--source-directory) nil t)

(provide 'whatsapp)
;;; whatsapp.el ends here
