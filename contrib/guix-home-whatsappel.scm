;;; guix-home-whatsappel.scm --- Guix Home shepherd services for the whatsappel stack
;;; SPDX-License-Identifier: AGPL-3.0-only
;;; Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
;;;
;;; Drop-in services that autostart the whatsappel stack at login on Guix System
;;; (the shepherd equivalent of the bundled systemd `whatsappel.service'):
;;;
;;;   * wuzapi            — the Go/whatsmeow WhatsApp engine, loopback :8080
;;;   * whatsappel-bridge — the Guile bridge (whatsappel.scm), loopback :7337,
;;;                         which `requires' wuzapi so it starts after it.
;;;
;;; Secrets are read at runtime from ~/wuzapi/.env and ~/whatsappel/.env (both
;;; mode 600) — they are never written into the world-readable store.  The wuzapi
;;; session lives under ~/.config/whatsappel/wuzapi-data so the phone link
;;; survives restarts and reboots.
;;;
;;; Usage: splice the (simple-service ...) form below into the `services' list of
;;; your `home-environment', make sure your module imports include
;;;   (gnu packages bash)        ; for `bash'
;;;   (gnu home services shepherd)
;;;   (gnu services)             ; for `simple-service'
;;; then run:  guix home reconfigure ~/.config/guix/home.scm
;;; and:       herd start whatsappel-bridge      ; (pulls in wuzapi)
;;;
;;; Prerequisites (one-time):
;;;   - wuzapi built at ~/wuzapi/wuzapi with ~/wuzapi/.env (WUZAPI_ADMIN_TOKEN, …)
;;;   - a wuzapi user whose token matches WUZAPI_TOKEN in ~/whatsappel/.env
;;;   - mkdir -p ~/.config/whatsappel/logs ~/.config/whatsappel/wuzapi-data

(use-modules (gnu home services shepherd)
             (gnu services)
             (gnu packages bash)
             (guix gexp))

(simple-service 'whatsappel-stack-service
                home-shepherd-service-type
                (list
                 ;; wuzapi — the WhatsApp multi-device engine (whatsmeow).
                 (shepherd-service
                  (provision '(wuzapi))
                  (documentation "wuzapi WhatsApp engine (whatsmeow), loopback :8080.")
                  (respawn? #t)
                  (start
                   #~(make-forkexec-constructor
                      (list (string-append (getenv "HOME") "/wuzapi/wuzapi")
                            "-datadir"
                            (string-append (getenv "HOME")
                                           "/.config/whatsappel/wuzapi-data")
                            "-logtype" "console")
                      #:directory (string-append (getenv "HOME") "/wuzapi")
                      #:log-file (string-append (getenv "HOME")
                                                "/.config/whatsappel/logs/wuzapi.log")
                      #:environment-variables (environ)))
                  (stop #~(make-kill-destructor)))
                 ;; whatsappel bridge — Emacs-facing Guile bridge.
                 (shepherd-service
                  (provision '(whatsappel-bridge))
                  (requirement '(wuzapi))
                  (documentation "whatsappel Guile bridge (Emacs <-> wuzapi), loopback :7337.")
                  (respawn? #t)
                  (start
                   #~(make-forkexec-constructor
                      (list #$(file-append bash "/bin/bash") "-c"
                            (string-append
                             "export PATH=\"$HOME/.local/bin:"
                             "/run/current-system/profile/bin:"
                             "$HOME/.guix-home/profile/bin:$PATH\"; "
                             "set -a; . \"$HOME/whatsappel/.env\"; set +a; "
                             "exec guile \"$HOME/whatsappel/whatsappel.scm\""))
                      #:directory (string-append (getenv "HOME") "/whatsappel")
                      #:log-file (string-append (getenv "HOME")
                                                "/.config/whatsappel/logs/bridge.log")
                      #:environment-variables (environ)))
                  (stop #~(make-kill-destructor)))))
