;;; manifest.scm --- development environment for whatsappel
;;; SPDX-License-Identifier: AGPL-3.0-only
;;; Copyright (c) 2026 Cristian Cezar Moisés — AGPL-3.0-only
;;;
;;; Usage:  guix shell -m manifest.scm
;;;
;;; Provides the Guile runtime and JSON library for the bridge. wuzapi (the Go
;;; WhatsApp engine) and Emacs are expected from the host; wuzapi is not packaged
;;; here because it links whatsmeow and tracks WhatsApp protocol changes upstream.

(specifications->manifest
 (list "guile"
       "guile-json"
       ;; Only needed if WUZAPI_BASE_URL is https (default is loopback http).
       "guile-gnutls"))
