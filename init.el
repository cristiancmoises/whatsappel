;;; init.el --- Example Emacs config for whatsapp.el  -*- lexical-binding: t; -*-

;; Drop-in example showing how to load and configure the WhatsApp client.
;; Copy the bits you want into your own init.el, or load this file directly.
;;
;; Prerequisites:
;;   1. Run the bridge:  cd whatsappel && npm install && node server.js
;;      (or: make install && systemctl --user start whatsappel)
;;   2. Put lisp/whatsapp.el on your load-path (this file does that below).
;;   3. M-x whatsapp-connect, then scan the QR with your phone the first time.

;;; Code:

;; --- Dependencies -----------------------------------------------------------
;; whatsapp.el needs the `websocket' package (and `emacs' >= 28.1).
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(unless package-archive-contents (package-refresh-contents))
(unless (package-installed-p 'websocket) (package-install 'websocket))

;; --- Load whatsapp.el -------------------------------------------------------
;; Adjust this path to wherever you cloned the repo's `lisp/' directory.
(add-to-list 'load-path (expand-file-name "lisp" (file-name-directory (or load-file-name buffer-file-name))))

(condition-case err
    (require 'whatsapp)
  (error (message "whatsapp.el failed to load: %s" (error-message-string err))))

;; --- Configuration ----------------------------------------------------------
;; The bridge host/ports (defaults shown). Set WAEL_API_TOKEN on the server and
;; mirror it here if you enable bearer auth.
(setq whatsapp-server-host "localhost"
      whatsapp-server-port 3000
      whatsapp-ws-port     3001
      ;; whatsapp-api-token "your-shared-secret"   ;; only if the server sets WAEL_API_TOKEN

      ;; UX niceties
      whatsapp-inline-images       t      ;; show photos inline (GUI Emacs)
      whatsapp-animate-gifs        t      ;; loop GIFs / animated stickers
      whatsapp-show-profile-pics   t      ;; avatars in the chat list
      whatsapp-show-link-previews  t
      whatsapp-auto-read           t      ;; mark visible chats read
      whatsapp-typing-indicator    t      ;; send "typing…" to the other side

      ;; External helpers (override if you use different tools)
      whatsapp-audio-player        "mpv"
      whatsapp-video-player        "mpv"
      whatsapp-voice-record-command "sox") ;; or "ffmpeg" / "arecord"

;; --- Keybinding -------------------------------------------------------------
;; Open WhatsApp from anywhere.
(global-set-key (kbd "C-c W") #'whatsapp-connect)

;; --- Optional: auto-connect on startup --------------------------------------
;; (add-hook 'emacs-startup-hook
;;           (lambda ()
;;             (run-with-timer 2 nil
;;               (lambda () (when (fboundp 'whatsapp-connect) (ignore-errors (whatsapp-connect)))))))

;;; init.el ends here
