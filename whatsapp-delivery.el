;;; whatsapp-delivery.el --- Transport visibility and explicit media choices -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-only
;; Loaded by whatsapp.el after its core helpers. No automatic session mutation.
(require 'cl-lib)
(require 'button)
(require 'image)

(defcustom whatsapp-video-backend 'pale
  "Preferred video renderer. Pale is not substituted silently with mpv.
The reviewed native Pale binding is unavailable in this distribution; choosing
Pale explains the missing dependency. Select mpv explicitly for working external
video playback. Static images and bounded GIFs use Emacs's native image support."
  :type '(choice (const :tag "Pale (binding not available yet)" pale)
                 (const :tag "mpv (external window)" mpv)) :group 'whatsapp)

(defun whatsapp-video-select-backend ()
  "Choose the video backend, without starting playback or installing packages."
  (interactive)
  (let ((choice (completing-read "Video renderer: "
                 '("Pale (not available in this build)" "mpv") nil t)))
    (setq whatsapp-video-backend (if (equal choice "mpv") 'mpv 'pale))
    (message "WhatsApp video preference: %s%s" whatsapp-video-backend
             (if (eq whatsapp-video-backend 'pale) " — native binding not installed" ""))))

(defun whatsapp-video-open (bytes mime)
  "Open BYTES only using the explicitly selected, implemented renderer."
  (pcase whatsapp-video-backend
    ('mpv (whatsapp--play-bytes bytes mime))
    ('pale (user-error "Pale API/binding unavailable in this build; Settings → Video → mpv is an explicit alternative. No external player was launched"))
    (_ (user-error "Choose Pale or mpv in Settings → Video"))))

(defun whatsapp-retry-images ()
  "Retry failed downloads/decodes for this conversation only; never resend a message."
  (interactive)
  (unless (derived-mode-p 'whatsapp-chat-mode) (user-error "Open a conversation first"))
  (let ((scope (append (whatsapp--origin-key) (list whatsapp-chat--jid))) keys)
    (maphash (lambda (key state)
               (when (and (eq state 'failed) (equal (cl-subseq key 0 3) scope))
                 (push key keys))) whatsapp--media-pending)
    (dolist (key keys) (remhash key whatsapp--media-pending))
    (let ((inhibit-read-only t) (modified (buffer-modified-p)))
      (with-silent-modifications
        (remove-text-properties (point-min) (point-max) '(whatsapp-preview-failed nil)))
      (set-buffer-modified-p modified))
    (setq whatsapp--last-error nil)
    (whatsapp-chat--schedule-prefetch)
    (message "Retrying visible images; expired media may require explicit re-request from the phone")))

;; Parse the complete GIF block structure before native decoding. Limits concern
;; admitted frames/canvases, not a claim of sandboxing the native image library.
(defun whatsapp--gif-info (bytes)
  "Return (WIDTH HEIGHT FRAMES) for a bounded GIF; reject incomplete or huge input."
  (unless (and (stringp bytes) (<= 14 (length bytes) (* 4 1024 1024))
               (member (substring bytes 0 6) '("GIF87a" "GIF89a")))
    (user-error "Invalid or oversized GIF; Save original remains available"))
  (let* ((n (length bytes)) (w (whatsapp--uint bytes 6 2 t))
         (h (whatsapp--uint bytes 8 2 t)) (flags (aref bytes 10))
         (p (+ 13 (if (> (logand flags 128) 0) (* 3 (ash 1 (1+ (logand flags 7)))) 0)))
         (frames 0) (done nil))
    (unless (and (<= 1 w 2048) (<= 1 h 2048)) (user-error "GIF canvas exceeds preview budget"))
    (cl-labels ((need (count) (unless (<= (+ p count) n) (user-error "Truncated GIF")))
                (blocks ()
                  (need 1)
                  (while (> (aref bytes p) 0)
                    (let ((count (aref bytes p))) (cl-incf p) (need count) (cl-incf p count) (need 1)))
                  (cl-incf p)))
      (while (not done)
        (need 1)
        (pcase (aref bytes p)
          (59 (cl-incf p) (setq done t))
          (33 (need 2) (cl-incf p 2) (blocks))
          (44
           (need 10)
           (let ((x (whatsapp--uint bytes (+ p 1) 2 t))
                 (y (whatsapp--uint bytes (+ p 3) 2 t))
                 (fw (whatsapp--uint bytes (+ p 5) 2 t))
                 (fh (whatsapp--uint bytes (+ p 7) 2 t)) (f (aref bytes (+ p 9))))
             (unless (and (> fw 0) (> fh 0) (<= (+ x fw) w) (<= (+ y fh) h))
               (user-error "Invalid GIF frame"))
             (cl-incf frames)
             (unless (and (<= frames 120) (<= (* w h frames) 8000000))
               (user-error "GIF animation exceeds preview budget; save original instead"))
             (cl-incf p (+ 10 (if (> (logand f 128) 0) (* 3 (ash 1 (1+ (logand f 7)))) 0)))
             (need 1)
             (unless (<= 2 (aref bytes p) 8) (user-error "Invalid GIF compression code"))
             (cl-incf p) (blocks)))
          (_ (user-error "Unknown GIF block"))))
      (unless (and (> frames 0) (= p n)) (user-error "Invalid GIF trailer")))
    (list w h frames)))

(defvar-local whatsapp--gif-image nil)
(defvar-local whatsapp--gif-watch nil)
(defun whatsapp--gif-stop ()
  "Stop this viewer's timers, never another buffer's image animation."
  (interactive)
  (when (and whatsapp--gif-image (fboundp 'image-animate-timer))
    (when-let ((timer (image-animate-timer whatsapp--gif-image))) (cancel-timer timer)))
  (when (timerp whatsapp--gif-watch) (cancel-timer whatsapp--gif-watch))
  (setq whatsapp--gif-watch nil))
(defun whatsapp-gif-play ()
  "Play this bounded native GIF until closed/hidden; Play resumes after returning."
  (interactive)
  (unless whatsapp--gif-image (user-error "No GIF in this buffer"))
  (whatsapp--gif-stop)
  (image-animate whatsapp--gif-image 0 t)
  (let ((buffer (current-buffer)))
    (setq whatsapp--gif-watch
          (run-at-time 0.25 0.25
                       (lambda ()
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (unless (cl-some (lambda (window) (eq t (frame-visible-p (window-frame window))))
                                              (get-buffer-window-list buffer nil t))
                               (whatsapp--gif-stop)))))))))
(defun whatsapp-gif-open (bytes)
  "Show an explicitly opened bounded GIF inside Emacs, not mpv."
  (let ((info (whatsapp--gif-info bytes)))
    (unless (and (display-graphic-p) (image-type-available-p 'gif))
      (user-error "This Emacs frame lacks native GIF support; save original instead"))
    (let ((buffer (generate-new-buffer "*WhatsApp GIF*")))
      (pop-to-buffer buffer)
      (special-mode)
      (setq-local whatsapp--gif-image (create-image bytes 'gif t :max-width 720 :max-height 600))
      (setq-local whatsapp--view-bytes bytes whatsapp--view-mime "image/gif")
      (add-hook 'kill-buffer-hook #'whatsapp--gif-stop nil t)
      (let ((inhibit-read-only t))
        (insert (format "GIF · %d × %d · %d frames\n\n" (nth 0 info) (nth 1 info) (nth 2 info)))
        (whatsapp--button "Play" #'whatsapp-gif-play)
        (whatsapp--button "Pause" #'whatsapp--gif-stop)
        (whatsapp--button "Save original" #'whatsapp-image-save)
        (whatsapp--button "Close" (lambda () (interactive) (whatsapp--gif-stop) (quit-window t)))
        (insert "\n\n") (insert-image whatsapp--gif-image) (goto-char (point-min)))
      (when (> (nth 2 info) 1) (whatsapp-gif-play)))))

;;; Local outgoing notes. These are in-memory UI state, not delivered messages.
(defvar-local whatsapp-chat--outgoing nil)
(defvar-local whatsapp-chat--outgoing-overlay nil)

(defun whatsapp-chat--paint-outgoing ()
  "Render one owned status overlay without inserting into history or the draft.
No wire IDs are invented. Repeated updates reuse the same overlay."
  (let ((entries (cl-remove-if-not
                  (lambda (entry) (equal (plist-get entry :origin) (whatsapp--origin-key)))
                  whatsapp-chat--outgoing)))
    (if (or (null entries) whatsapp--closing)
        (when (overlayp whatsapp-chat--outgoing-overlay)
          (delete-overlay whatsapp-chat--outgoing-overlay)
          (setq whatsapp-chat--outgoing-overlay nil))
      (let ((at (if (and (markerp whatsapp-chat--history-end)
                         (marker-position whatsapp-chat--history-end))
                    (marker-position whatsapp-chat--history-end) (point-min))))
        (unless (overlayp whatsapp-chat--outgoing-overlay)
          (setq whatsapp-chat--outgoing-overlay (make-overlay at at nil nil nil))
          (overlay-put whatsapp-chat--outgoing-overlay 'whatsapp-outgoing-note t))
        (move-overlay whatsapp-chat--outgoing-overlay at at (current-buffer))
        (overlay-put
         whatsapp-chat--outgoing-overlay 'before-string
         (concat
          (propertize "\nLocal send status (not proof of delivery)\n" 'face 'shadow)
          (mapconcat
           (lambda (entry)
             (let ((label (pcase (plist-get entry :state)
                            ('sending "Sending…")
                            ('accepted "Accepted · awaiting history/receipt")
                            (_ "Unconfirmed · check recipient before retrying"))))
               (concat (propertize (concat "[" label "] ")
                                   'face (if (eq (plist-get entry :state) 'unconfirmed) 'warning 'shadow))
                       (truncate-string-to-width
                        (whatsapp--row-text (substring-no-properties (plist-get entry :text)))
                        120 nil nil "…"))))
           entries "\n")
          "\n"))))))

(defun whatsapp-chat--begin-outgoing (text origin target)
  "Create a bounded local note before one explicit text-send attempt."
  (when (cl-some (lambda (entry)
                   (and (equal origin (plist-get entry :origin))
                        (equal target (plist-get entry :target))
                        (equal text (plist-get entry :text))
                        (eq (plist-get entry :state) 'unconfirmed)))
                 whatsapp-chat--outgoing)
    (user-error "This draft has an unconfirmed attempt; check the recipient before clearing its local note to retry"))
  (when (or (>= (length whatsapp-chat--outgoing) 16)
            (> (+ (string-bytes text)
                  (cl-loop for entry in whatsapp-chat--outgoing
                           sum (string-bytes (plist-get entry :text)))) (* 256 1024)))
    (user-error "Local send-note limit reached; refresh or explicitly clear reviewed notes"))
  (let ((entry (list :text (substring-no-properties text) :origin origin :target target
                     :state 'sending :message-id nil)))
    (setq whatsapp-chat--outgoing (append whatsapp-chat--outgoing (list entry)))
    (whatsapp-chat--paint-outgoing)
    entry))

(defun whatsapp-chat--finish-outgoing (entry result)
  "Accept only the existing strict acknowledgement contract for ENTRY."
  (if (whatsapp--send-accepted-p result)
      (let* ((top (cdr result)) (provider (cdr (assoc "data" top)))
             (data (cdr (assoc "data" provider)))
             (id (or (cdr (assoc "message_id" top))
                     (cdr (assoc "Id" data)) (cdr (assoc "ID" data)) (cdr (assoc "id" data)))))
        (setf (plist-get entry :state) 'accepted (plist-get entry :message-id) id))
    (setf (plist-get entry :state) 'unconfirmed))
  (whatsapp-chat--paint-outgoing))

(defun whatsapp-chat--reconcile-outgoing (records)
  "Remove an accepted local note only after its ID appears as an own message.
Never merge a LID with a telephone identifier or infer receipt from matching text."
  (setq whatsapp-chat--outgoing
        (cl-remove-if
         (lambda (entry)
           (and (equal (plist-get entry :origin) (whatsapp--origin-key))
                (eq (plist-get entry :state) 'accepted)
                (stringp (plist-get entry :message-id))
                (cl-some (lambda (record)
                           (and (eq t (cdr (assoc "me" record)))
                                (equal (plist-get entry :message-id) (cdr (assoc "id" record)))))
                         records)))
         whatsapp-chat--outgoing))
  (whatsapp-chat--paint-outgoing))

(defun whatsapp-clear-send-notes ()
  "Explicitly dismiss this buffer's reviewed local notes; never resend/delete remotely.
Unconfirmed notes should be checked against the recipient before retrying a draft."
  (interactive)
  (when (or whatsapp-chat--send-pending
            (cl-some (lambda (entry) (eq (plist-get entry :state) 'sending)) whatsapp-chat--outgoing))
    (user-error "Wait for the current send attempt to finish"))
  (when (and whatsapp-chat--outgoing
             (yes-or-no-p "Dismiss local send notes only? This will NOT resend or delete remote messages: "))
    (setq whatsapp-chat--outgoing nil)
    (whatsapp-chat--paint-outgoing)))

;; Session observations are account-scoped and are never inferred from chat cache.
(defvar whatsapp--session-snapshot nil)
(defvar-local whatsapp--session-pending nil)
(defvar-local whatsapp--session-requested-at 0)
(defvar-local whatsapp--session-request-origin nil)

(defun whatsapp-session-observe (data origin)
  "Store only a fresh, typed backend observation for the currently selected account."
  (when (equal origin (whatsapp--origin-key))
    (let* ((age (and (proper-list-p data) (cdr (assoc "checked_age" data))))
           (state (and (proper-list-p data) (cdr (assoc "session_state" data))))
           (old (and (equal origin (plist-get whatsapp--session-snapshot :origin))
                     (or (plist-get whatsapp--session-snapshot :last-completed-state)
                         (plist-get whatsapp--session-snapshot :state))))
           (fresh (and (integerp age) (<= 0 age 45)
                       (null (cdr (assoc "checking" data)))
                       (eq t (cdr (assoc "checked" data)))
                       (member state '("ready" "disconnected" "pairing-required"
                                       "authentication-required" "provider-unavailable" "unknown")))))
      (setq whatsapp--session-snapshot
            (list :origin origin :state (if fresh state "unknown")
                  ;; A pending check cannot advertise readiness, but must not erase
                  ;; the completed state needed for one later recovery transition.
                  :last-completed-state (if fresh state old)
                  :expires (+ (float-time) (if fresh (max 0 (- 45 age)) 0))))
      (when (and fresh (equal state "ready")
                 (member old '("disconnected" "pairing-required" "provider-unavailable"))
                 (fboundp 'whatsapp-profiles-session-recovered))
        (whatsapp-profiles-session-recovered))
      (force-mode-line-update t))))

(defun whatsapp-session-label ()
  "Return the backend state without exposing credentials or asserting delivery."
  (let ((state (and (equal (plist-get whatsapp--session-snapshot :origin) (whatsapp--origin-key))
                    (> (or (plist-get whatsapp--session-snapshot :expires) 0) (float-time))
                    (plist-get whatsapp--session-snapshot :state))))
    (concat " " (pcase state
                  ("ready" "Backend connected")
                  ("disconnected" "Backend disconnected — Check delivery")
                  ("pairing-required" "Backend awaiting login — Open linking QR")
                  ("authentication-required" "Backend token rejected")
                  ("provider-unavailable" "Backend unavailable")
                  (_ "Backend status unverified")) " |")))

(defun whatsapp-session-refresh ()
  "Read backend state at most once per 15 seconds; cached chats stay responsive."
  (let ((origin (whatsapp--origin-key)) (now (float-time)))
    (unless (equal origin whatsapp--session-request-origin)
      (setq whatsapp--session-request-origin origin
            whatsapp--session-requested-at 0 whatsapp--session-pending nil))
    (when (and (not whatsapp--session-pending)
               (>= (- now whatsapp--session-requested-at) 15))
      (let ((buffer (current-buffer)) (cookie (list origin now)))
        (setq whatsapp--session-pending cookie whatsapp--session-requested-at now)
        (condition-case nil
            (whatsapp--request-async
             "GET" "/transport/status" nil
             (lambda (result)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (eq cookie whatsapp--session-pending)
                     (setq whatsapp--session-pending nil)
                     (whatsapp-session-observe
                      (and (whatsapp--ok-p (car-safe result)) (cdr-safe result)) origin))))))
          (error
           (setq whatsapp--session-pending nil)
           (whatsapp-session-observe nil origin)))))))

(defvar-local whatsapp--transport-origin nil)
(defvar-local whatsapp--transport-timer nil)
(defvar-local whatsapp--transport-pending nil)
(defvar-local whatsapp--transport-data nil)
(defvar-local whatsapp--transport-round 0)
(defvar-local whatsapp--transport-generation 0)
(defvar-local whatsapp--transport-watch-until 0)

(defun whatsapp--transport-stop ()
  (cl-incf whatsapp--transport-generation)
  (when (timerp whatsapp--transport-timer) (cancel-timer whatsapp--transport-timer))
  (setq whatsapp--transport-timer nil whatsapp--transport-pending nil
        whatsapp--transport-watch-until 0)
  (whatsapp--cancel-buffer-work))

(defun whatsapp--transport-current-p (origin generation)
  (and (not whatsapp--closing) (= generation whatsapp--transport-generation)
       (equal origin whatsapp--transport-origin) (equal origin (whatsapp--origin-key))))

(defun whatsapp--transport-render (&optional failure)
  "Render constant guidance and typed fields, not raw provider JSON."
  (let ((inhibit-read-only t) (data whatsapp--transport-data))
    (erase-buffer)
    (insert "WhatsAppel · connection and delivery\n\n")
    (whatsapp--button "Refresh check" #'whatsapp-connection-refresh)
    (whatsapp--button "Connect existing session…" #'whatsapp-connection-connect)
    (whatsapp--button "Open linking QR" #'whatsapp-qr)
    (insert "\n")
    (whatsapp--button "Repair incoming callback…" #'whatsapp-repair-incoming)
    (whatsapp--button "Enable profile events…" #'whatsapp-repair-profile-events)
    (whatsapp--button "Close" #'quit-window)
    (insert "\n\nCached conversations do NOT prove a connected phone session or live incoming delivery.\n")
    (insert "Accepted = upstream accepted an ID. Delivered/Read require a matching receipt.\n\n")
    (when failure (insert "Check unavailable; verify the running bridge and account. No message was sent.\n"))
    (insert (if (eq t (cdr (assoc "checking" data)))
                "Checking backend; any retained fields below are previous observations.\n"
              (pcase (cdr (assoc "session_state" data))
              ("disconnected" "Next: Connect existing session. If WhatsApp requires login, open the linking QR.\n")
              ("pairing-required" "Next: Open linking QR and scan it from WhatsApp → Linked Devices.\n")
              ("authentication-required" "Next: verify this backend account token privately; do not reset the session.\n")
              ("provider-unavailable" "Next: verify the backend process and URL. A running bridge alone is insufficient.\n")
              ("ready" "Backend connected and logged in. Now verify events and test one recent image.\n")
              (_ "Backend status is unverified. Refresh check before changing session settings.\n"))))
    (insert "\n")
    (dolist (item '(("Connection" . "connection_state") ("Login" . "login_state")
                    ("Incoming callback" . "callback_state") ("Message subscription" . "subscription_state")
                    ("Presence events" . "presence_subscription_state")
                    ("Typing/recording events" . "activity_subscription_state")
                    ("Profile picture events" . "picture_subscription_state")))
      (let ((value (cdr (assoc (cdr item) data))))
        (insert (car item) ": " (if (member value '("yes" "no" "unknown")) value "unknown") "\n")))
    (dolist (item '(("Webhook events observed" . "webhooks_seen")
                    ("Message events ingested" . "messages_ingested")
                    ("Seconds since last incoming message event" . "last_message_age")))
      (let ((value (cdr (assoc (cdr item) data))))
        (insert (car item) ": " (if (and (integerp value) (>= value 0)) (number-to-string value) "unknown") "\n")))
    (let ((repair (cdr (assoc "repair" data))) (connect (cdr (assoc "connect_result" data))))
      (when (member repair '("unsupported-webhook-schema" "different-callback-confirmation-required"
                            "unconfirmed-no-automatic-retry" "registered-not-reachability-tested" "verification-failed"))
        (insert "\nCallback result: " repair "\n"))
      (when (member connect '("already-connected" "pairing-required" "status-unverified-no-connect"
                              "subscriptions-unverified-no-connect" "requested-check-status"
                              "already-started-check-status" "unconfirmed-no-automatic-retry"))
        (insert "\nConnect result: " connect "\n")))
    (insert "\nConnect, callback registration and per-contact Presence consent are separate choices.\n")
    (insert "No automatic connect, logout, pairing, message send, or callback replacement.\n")
    (when (eq t (cdr (assoc "checking" data))) (insert "Checking provider asynchronously…\n"))
    (goto-char (point-min))))

(defun whatsapp--transport-fetch (&optional fresh)
  (setq whatsapp--transport-timer nil)
  (when (and (not whatsapp--transport-pending) (not whatsapp--closing)
             (equal whatsapp--transport-origin (whatsapp--origin-key)))
    (let ((buffer (current-buffer)) (origin whatsapp--transport-origin)
          (generation (cl-incf whatsapp--transport-generation)))
      (setq whatsapp--transport-pending t)
      (condition-case nil
          (whatsapp--request-async
           "GET" (if fresh "/transport/status?refresh=1" "/transport/status") nil
           (lambda (result)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (whatsapp--transport-current-p origin generation)
                   (setq whatsapp--transport-pending nil
                         whatsapp--transport-data
                         (and (whatsapp--ok-p (car-safe result))
                              (proper-list-p (cdr-safe result)) (cdr-safe result)))
                   (whatsapp-session-observe whatsapp--transport-data origin)
                   (whatsapp--transport-render (not whatsapp--transport-data))
                   (let* ((checking (eq t (cdr (assoc "checking" whatsapp--transport-data))))
                          (state (cdr (assoc "session_state" whatsapp--transport-data)))
                          (watch (and (> whatsapp--transport-watch-until (float-time))
                                      (not (member state '("ready" "pairing-required" "authentication-required"))))))
                     (when (and whatsapp--transport-data (or checking watch) (< whatsapp--transport-round 40))
                       (cl-incf whatsapp--transport-round)
                       (setq whatsapp--transport-timer
                             (run-at-time
                              (if checking 0.5 2) nil
                              (lambda ()
                                (when (buffer-live-p buffer)
                                  (with-current-buffer buffer
                                    (when (whatsapp--transport-current-p origin generation)
                                      (whatsapp--transport-fetch (not checking)))))))))))))))
        (error
         (setq whatsapp--transport-pending nil)
         (whatsapp--transport-render t))))))

(defun whatsapp-connection-refresh ()
  "Request a fresh check (bridge rate-limits it); never reconnect implicitly."
  (interactive)
  (when (timerp whatsapp--transport-timer) (cancel-timer whatsapp--transport-timer))
  (setq whatsapp--transport-timer nil whatsapp--transport-round 0)
  (whatsapp--transport-fetch t))

(defun whatsapp-connection-panel ()
  "Open diagnosis using the currently loaded Emacs account, without a session write."
  (interactive)
  (let ((buffer (get-buffer-create "*WhatsApp connection*")))
    (pop-to-buffer buffer)
    (unless (eq major-mode 'special-mode) (special-mode))
    (unless (equal whatsapp--transport-origin (whatsapp--origin-key))
      (whatsapp--transport-stop)
      (setq whatsapp--closing nil whatsapp--transport-data nil))
    (setq whatsapp--transport-origin (whatsapp--origin-key))
    (add-hook 'kill-buffer-hook #'whatsapp--transport-stop nil t)
    (whatsapp--transport-render)
    (whatsapp-connection-refresh)))

(defun whatsapp--transport-action (path payload)
  "Submit one explicitly selected operation; stale callbacks cannot mutate a new panel."
  (let ((buffer (current-buffer)) (origin whatsapp--transport-origin)
        (generation (cl-incf whatsapp--transport-generation)))
    (when (timerp whatsapp--transport-timer) (cancel-timer whatsapp--transport-timer))
    (setq whatsapp--transport-timer nil whatsapp--transport-pending t)
    (condition-case nil
        (whatsapp--request-async
         "POST" path payload
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (whatsapp--transport-current-p origin generation)
                 (setq whatsapp--transport-pending nil)
                 (if (and (eq (car-safe result) 202)
                          (proper-list-p (cdr-safe result))
                          (eq (cdr (assoc "accepted" (cdr result))) t))
                     (progn
                       (when (equal path "/transport/connect")
                         (setq whatsapp--transport-watch-until (+ (float-time) 30)))
                       (setq whatsapp--transport-round 0)
                       (whatsapp--transport-fetch))
                   (message "Operation not confirmed. Refresh check; no automatic retry was made.")))))))
      (error
       (setq whatsapp--transport-pending nil)
       (message "Operation could not start. No automatic retry was made.")))))

(defun whatsapp-connection-connect ()
  "Connect after confirmation; preserve session and subscriptions, never log out."
  (interactive)
  (unless (equal whatsapp--transport-origin (whatsapp--origin-key))
    (user-error "Reopen the connection panel for the current account"))
  (when (or whatsapp--transport-pending (> whatsapp--transport-watch-until (float-time)))
    (user-error "Wait for the current session operation; do not submit a second connect"))
  (when (yes-or-no-p "Connect this backend account, retaining its session and subscriptions? A linking QR may be required: ")
    (whatsapp--transport-action "/transport/connect" '((confirm . t)))))

(defun whatsapp-repair-incoming (&optional replace profiles)
  "Explicitly register this callback; preserve all subscriptions. Never connect or log out."
  (interactive "P")
  (unless (equal whatsapp--transport-origin (whatsapp--origin-key))
    (user-error "Reopen the connection panel for the current account"))
  (when whatsapp--transport-pending (user-error "Wait for the current check"))
  (when (and (yes-or-no-p (if profiles
                            "Register Message/ReadReceipt/Presence/ChatPresence/Picture events, preserving existing subscriptions? "
                          "Register this bridge for incoming messages, preserving existing subscriptions? "))
             (or (not replace) (yes-or-no-p "REPLACE a different callback? Its previous consumer can stop receiving events: ")))
    (whatsapp--transport-action
     "/transport/repair"
     (append `((confirm . t) (replace . ,(if replace t :json-false)))
             (when profiles '((profiles . t)))))))

(defun whatsapp-repair-profile-events (&optional replace)
  "Register profile events after consent; no session connect or self-online announcement."
  (interactive "P")
  (whatsapp-repair-incoming replace t))

(provide 'whatsapp-delivery)
;;; whatsapp-delivery.el ends here
