;;; whatsapp-org.el --- Org-mode integration for whatsapp.el  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-only
;; Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
;;
;; Author: Cristian Cezar Moisés
;; URL: https://codeberg.org/berkeley/whatsappel
;; Version: 3.0.3
;; Package-Requires: ((emacs "28.1"))
;; Keywords: comm, whatsapp, org

;;; Commentary:

;; Ties whatsapp.el into Org-mode along three seams:
;;
;; 1. A `whatsapp:' Org link type.  `org-store-link' in a chat (or on a root
;;    line) yields `[[whatsapp:<jid>][WhatsApp: <name>]]'; following it opens
;;    the chat.  `C-c C-l' completion offers your known chats.
;;
;; 2. Capture.  `whatsapp-org-capture' (C-c C-o in a chat, or the `o' key of
;;    `whatsapp-prefix-map') files the message at point as an Org entry, with
;;    the sender, an inactive timestamp, a jump-back link, and the text in a
;;    quote block.  Post-quantum (`WAPQ1:') messages are captured as their
;;    placeholder unless you have already decrypted them on view — capture
;;    never silently reveals plaintext you have not chosen to see.
;;
;; 3. Send from Org.  In a buffer with `whatsapp-org-mode' on, `C-c C-w s'
;;    exports the current subtree to plain text and sends it; `C-c C-w r'
;;    sends the region; `C-c C-w g' jumps from an entry to its chat.  The
;;    target is the entry's `WHATSAPP_JID' property (inherited) or a prompt.
;;
;; Setup:
;;   (with-eval-after-load 'whatsapp (require 'whatsapp-org))
;;   ;; optional, per Org buffer:  M-x whatsapp-org-mode
;;
;; This file only *adds* to whatsapp.el; it never changes its behaviour when
;; unused.  It is an optional companion: the core client does not require Org.

;;; Code:

(require 'whatsapp)
(require 'org)
(require 'org-capture)

(declare-function org-export-string-as "ox" (string backend &optional body-only ext-plist))
(declare-function org-link-store-props "ol" (&rest plist))
(declare-function org-link-set-parameters "ol" (type &rest parameters))

;;; ---------------------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------------------

(defgroup whatsapp-org nil
  "Org-mode integration for whatsapp.el."
  :group 'whatsapp
  :prefix "whatsapp-org-")

(defcustom whatsapp-org-capture-file nil
  "Org file `whatsapp-org-capture' files into.
Nil means use `org-default-notes-file'."
  :type '(choice (const :tag "Default notes file" nil) file)
  :group 'whatsapp-org)

(defcustom whatsapp-org-export-backend 'ascii
  "Org export backend used to turn Org into the plain text WhatsApp sends."
  :type 'symbol
  :group 'whatsapp-org)

;;; ---------------------------------------------------------------------------
;;; Small helpers
;;; ---------------------------------------------------------------------------

(defun whatsapp-org--field (m key)
  "Return KEY from message alist M, or nil."
  (and (listp m) (cdr (assoc key m))))

(defun whatsapp-org--esc (s)
  "Escape S for literal use inside an `org-capture' template (double %)."
  (replace-regexp-in-string "%" "%%" (or s "")))

(defun whatsapp-org--inactive-ts (ts)
  "Format unix-seconds TS as an Org inactive timestamp, or nil."
  (when (and (numberp ts) (> ts 0))
    (format-time-string "[%Y-%m-%d %a %H:%M]" (seconds-to-time ts))))

(defun whatsapp-org--chat-name (jid)
  "Best-known display name for JID, falling back to JID itself."
  (let ((name nil))
    (when (boundp 'whatsapp--chats)
      (dolist (c whatsapp--chats)
        (when (and (not name) (equal (whatsapp-org--field c "jid") jid))
          (setq name (whatsapp-org--field c "name")))))
    (or name jid)))

(defun whatsapp-org--chat-alist ()
  "Return a (DISPLAY . JID) alist of known chats for completion."
  (let (out)
    (when (boundp 'whatsapp--chats)
      (dolist (c whatsapp--chats)
        (let ((jid  (whatsapp-org--field c "jid"))
              (name (whatsapp-org--field c "name")))
          (when jid
            (push (cons (format "%s  <%s>" (or name jid) jid) jid) out)))))
    (nreverse out)))

(defun whatsapp-org--read-jid (&optional prompt)
  "Resolve a chat JID: entry property, current chat, else completing-read.
PROMPT is the completion prompt."
  (or (and (derived-mode-p 'org-mode) (org-entry-get nil "WHATSAPP_JID" t))
      (and (derived-mode-p 'whatsapp-chat-mode)
           (bound-and-true-p whatsapp-chat--jid))
      (let* ((cands (whatsapp-org--chat-alist))
             (sel (completing-read (format "%s: " (or prompt "WhatsApp chat"))
                                   cands nil nil)))
        (or (cdr (assoc sel cands)) sel))))

(defun whatsapp-org--message-at-point ()
  "Return the message alist at point, or a synthesized one from the line."
  (or (get-text-property (point) 'whatsapp-msg)
      (let ((line (string-trim (or (thing-at-point 'line t) ""))))
        (and (> (length line) 0) (list (cons "text" line))))))

(defun whatsapp-org--message-text (m)
  "Return display text for message M, honouring the PQ threat model.
A `WAPQ1:' envelope is rendered as a placeholder unless it has already
been decrypted on view (present in the plaintext cache)."
  (let ((text (whatsapp-org--field m "text"))
        (kind (whatsapp-org--field m "kind"))
        (cap  (whatsapp-org--field m "caption")))
    (cond
     ((and (stringp text) (fboundp 'whatsapp--pq-text-p)
           (whatsapp--pq-text-p text))
      (or (and (boundp 'whatsapp-pq--plain-cache)
               (gethash text whatsapp-pq--plain-cache))
          "[encrypted message — view it in the chat to decrypt before capturing]"))
     ((and (stringp text) (> (length text) 0)) text)
     ((and (stringp kind)
           (member kind '("image" "sticker" "video" "audio" "document" "gif")))
      (format "[%s]%s" kind (if (and cap (> (length cap) 0)) (concat " " cap) "")))
     (t ""))))

;;; ---------------------------------------------------------------------------
;;; Org link type:  whatsapp:<jid>
;;; ---------------------------------------------------------------------------

(defun whatsapp-org-open (path &optional _arg)
  "Follow a `whatsapp:' link: open the chat for PATH (a JID)."
  (whatsapp-open-chat path))

(defun whatsapp-org-store-link ()
  "Store a `whatsapp:' link when in a chat buffer or on a root chat line."
  (let ((jid (cond ((derived-mode-p 'whatsapp-chat-mode)
                    (bound-and-true-p whatsapp-chat--jid))
                   ((derived-mode-p 'whatsapp-root-mode)
                    (get-text-property (point) 'whatsapp-jid)))))
    (when jid
      (org-link-store-props
       :type "whatsapp"
       :link (concat "whatsapp:" jid)
       :description (format "WhatsApp: %s" (whatsapp-org--chat-name jid)))
      t)))

(defun whatsapp-org-complete-link (&optional _arg)
  "Completion for `whatsapp:' links: offer a known chat."
  (concat "whatsapp:" (whatsapp-org--read-jid "Link to chat")))

(defun whatsapp-org--register-link ()
  "Register the `whatsapp:' Org link type."
  (when (fboundp 'org-link-set-parameters)
    (org-link-set-parameters
     "whatsapp"
     :follow   #'whatsapp-org-open
     :store    #'whatsapp-org-store-link
     :complete #'whatsapp-org-complete-link)))

(with-eval-after-load 'org (whatsapp-org--register-link))
(when (featurep 'org) (whatsapp-org--register-link))

;;; ---------------------------------------------------------------------------
;;; Capture
;;; ---------------------------------------------------------------------------

(defun whatsapp-org--capture-template (jid name from ts text)
  "Build a one-off `org-capture-templates' entry for a captured message."
  (let* ((file  (or whatsapp-org-capture-file org-default-notes-file))
         (stamp (whatsapp-org--inactive-ts ts))
         (body  (concat
                 "* %?" (and from (format " — from %s" (whatsapp-org--esc from))) "\n"
                 ":PROPERTIES:\n"
                 ":WHATSAPP_JID: " (whatsapp-org--esc jid) "\n"
                 (if from (concat ":WHATSAPP_FROM: " (whatsapp-org--esc from) "\n") "")
                 (if stamp (concat ":WHATSAPP_TS: " stamp "\n") "")
                 ":END:\n"
                 (if stamp (concat stamp "\n") "")
                 "[[whatsapp:" (whatsapp-org--esc jid)
                 "][WhatsApp: " (whatsapp-org--esc name) "]]\n"
                 (if (> (length text) 0)
                     (concat "\n#+begin_quote\n" (whatsapp-org--esc text)
                             "\n#+end_quote\n")
                   ""))))
    (list "w" "WhatsApp message" 'entry (list 'file file) body :empty-lines 1)))

;;;###autoload
(defun whatsapp-org-capture ()
  "Capture the WhatsApp message at point into Org via `org-capture'."
  (interactive)
  (unless (derived-mode-p 'whatsapp-chat-mode)
    (user-error "Not in a WhatsApp chat buffer"))
  (let* ((jid  (bound-and-true-p whatsapp-chat--jid))
         (name (whatsapp-org--chat-name jid))
         (m    (whatsapp-org--message-at-point))
         (from (or (whatsapp-org--field m "name") name))
         (ts   (whatsapp-org--field m "ts"))
         (text (whatsapp-org--message-text m))
         (org-capture-templates
          (list (whatsapp-org--capture-template jid name from ts text))))
    (org-capture nil "w")))

;;; ---------------------------------------------------------------------------
;;; Send from Org
;;; ---------------------------------------------------------------------------

(defun whatsapp-org--export (string)
  "Export Org STRING to plain text using `whatsapp-org-export-backend'."
  (require 'ox-ascii)
  (string-trim
   (org-export-string-as string whatsapp-org-export-backend t '(:with-toc nil))))

(defun whatsapp-org--subtree-body-string ()
  "Return the Org source of the current subtree, excluding its heading line."
  (save-excursion
    (org-back-to-heading t)
    (let ((beg (progn (forward-line 1) (point)))
          (end (org-end-of-subtree t t)))
      (buffer-substring-no-properties beg (min end (point-max))))))

(defun whatsapp-org--send (jid text)
  "Send plain TEXT to chat JID through the bridge."
  (let ((res (whatsapp--request
              "POST" "/send"
              (list (cons "to" (whatsapp--target-of-jid jid))
                    (cons "body" text)))))
    (if (whatsapp--ok-p (car res))
        (message "whatsapp: sent %d chars to %s" (length text) jid)
      (user-error "whatsapp: send failed: %S" (cdr res)))))

(defun whatsapp-org--maybe-send (jid text)
  "Confirm, then send trimmed TEXT to JID.  Refuse empty text."
  (setq text (string-trim text))
  (when (= (length text) 0) (user-error "whatsapp-org: nothing to send"))
  (when (yes-or-no-p
         (format "Send %d chars to WhatsApp chat %s? " (length text) jid))
    (whatsapp-org--send jid text)))

;;;###autoload
(defun whatsapp-org-send-subtree ()
  "Export the current Org subtree to plain text and send it over WhatsApp."
  (interactive)
  (unless (derived-mode-p 'org-mode) (user-error "Not in an Org buffer"))
  (let ((jid (whatsapp-org--read-jid "Send subtree to")))
    (whatsapp-org--maybe-send jid (whatsapp-org--export
                                   (whatsapp-org--subtree-body-string)))))

;;;###autoload
(defun whatsapp-org-send-region (beg end)
  "Export the Org region BEG..END to plain text and send it over WhatsApp."
  (interactive "r")
  (let ((jid (whatsapp-org--read-jid "Send region to")))
    (whatsapp-org--maybe-send
     jid (whatsapp-org--export (buffer-substring-no-properties beg end)))))

;;;###autoload
(defun whatsapp-org-goto ()
  "Open the WhatsApp chat named by the current entry's `WHATSAPP_JID'."
  (interactive)
  (let ((jid (and (derived-mode-p 'org-mode)
                  (org-entry-get nil "WHATSAPP_JID" t))))
    (if jid (whatsapp-open-chat jid)
      (user-error "No WHATSAPP_JID property on this entry"))))

;;; ---------------------------------------------------------------------------
;;; Minor mode + keybindings
;;; ---------------------------------------------------------------------------

(defvar whatsapp-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-w s") #'whatsapp-org-send-subtree)
    (define-key map (kbd "C-c C-w r") #'whatsapp-org-send-region)
    (define-key map (kbd "C-c C-w g") #'whatsapp-org-goto)
    map)
  "Keymap for `whatsapp-org-mode'.")

;;;###autoload
(define-minor-mode whatsapp-org-mode
  "Minor mode adding WhatsApp send/goto commands to an Org buffer.

\\{whatsapp-org-mode-map}"
  :lighter " WA-Org"
  :keymap whatsapp-org-mode-map)

;; Chat-buffer capture key and the prefix-map `o' slot.  whatsapp.el is already
;; loaded (required above), so these maps exist.
(define-key whatsapp-chat-mode-map (kbd "C-c C-o") #'whatsapp-org-capture)
(when (boundp 'whatsapp-prefix-map)
  (define-key whatsapp-prefix-map (kbd "o") #'whatsapp-org-capture))

(provide 'whatsapp-org)
;;; whatsapp-org.el ends here
