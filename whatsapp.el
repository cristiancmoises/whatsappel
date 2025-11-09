;;; whatsapp.el --- Simple WhatsApp interface for Emacs -*- lexical-binding: t; -*-

(defgroup whatsapp nil
  "Send WhatsApp messages via local Baileys API."
  :group 'external)

(defcustom whatsapp-api-url "http://localhost:3000/send"
  "URL of your local WhatsApp Node.js API."
  :type 'string
  :group 'whatsapp)

(defun whatsapp-send (number message)
  "Send MESSAGE to WhatsApp NUMBER using local Node.js API."
  (interactive "sNumber (e.g., 5599999999999): \nsMessage: ")
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data
          (encode-coding-string
           (json-encode `(("to" . ,number) ("text" . ,message)))
           'utf-8))
         (response-buffer (url-retrieve-synchronously whatsapp-api-url t t 5)))
    (if response-buffer
        (progn
          (with-current-buffer response-buffer
            (goto-char (point-min))
            (if (search-forward "200 OK" nil t)
                (message "✅ Message sent to %s" number)
              (message "❌ Failed to send message: %s" number)))
          (kill-buffer response-buffer))
      (message "⚠️ No response from WhatsApp API — is server.js running?"))))

(provide 'whatsapp)
;;; whatsapp.el ends here
