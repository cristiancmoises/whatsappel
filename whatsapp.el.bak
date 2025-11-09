;;; whatsapp.el --- WhatsApp integration for Emacs -*- lexical-binding: t; -*-

(require 'json)
(require 'url)
(require 'url-http)

(defgroup whatsapp nil
  "Send and read WhatsApp messages via local Node.js API."
  :group 'external)

(defcustom whatsapp-api-base "http://localhost:3000"
  "Base URL of your local WhatsApp Node.js API."
  :type 'string
  :group 'whatsapp)

(defun whatsapp--get (endpoint)
  "Perform GET request to ENDPOINT."
  (with-current-buffer (url-retrieve-synchronously
                        (concat whatsapp-api-base endpoint))
    (goto-char (point-min))
    (re-search-forward "\n\n" nil t)
    (let ((json-object-type 'alist))
      (prog1 (json-read)
        (kill-buffer (current-buffer))))))

(defun whatsapp--post-json (endpoint data)
  "POST DATA (alist) as JSON to ENDPOINT."
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (encode-coding-string (json-encode data) 'utf-8)))
    (with-current-buffer (url-retrieve-synchronously
                          (concat whatsapp-api-base endpoint))
      (goto-char (point-min))
      (re-search-forward "\n\n" nil t)
      (let ((resp (buffer-substring (point) (point-max))))
        (kill-buffer (current-buffer))
        resp))))

;;;###autoload
(defun whatsapp-send-text (number text)
  (interactive "sNumber (e.g. +5599999999999): \nsMessage: ")
  (message "%s"
           (whatsapp--post-json "/send"
                                `(("to" . ,number) ("text" . ,text)))))

;;;###autoload
(defun whatsapp-send-image (number path caption)
  (interactive "sNumber: \nfImage path: \nsCaption: ")
  (whatsapp--post-json "/send"
                       `(("to" . ,number)
                         ("image" . ,path)
                         ("text" . ,caption))))

;;;###autoload
(defun whatsapp-send-file (number path caption)
  (interactive "sNumber: \nfFile path: \nsCaption: ")
  (whatsapp--post-json "/send"
                       `(("to" . ,number)
                         ("file" . ,path)
                         ("text" . ,caption))))

;;;###autoload
(defun whatsapp-send-gif (number path caption)
  (interactive "sNumber: \nfGIF path: \nsCaption: ")
  (whatsapp--post-json "/send"
                       `(("to" . ,number)
                         ("gif" . ,path)
                         ("text" . ,caption))))

;;;###autoload
(defun whatsapp-read-messages ()
  "Fetch and display last messages."
  (interactive)
  (let* ((msgs (whatsapp--get "/messages"))
         (buf (get-buffer-create "*WhatsApp Messages*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert (format "📱 Last %d messages:\n\n" (length msgs)))
      (dolist (msg msgs)
        (let ((from (alist-get 'from msg))
              (text (alist-get 'text msg))
              (time (alist-get 'timestamp msg)))
          (insert (format "[%s] %s:\n%s\n\n" time from text))))
      (goto-char (point-min)))
    (display-buffer buf)))

(provide 'whatsapp)
;;; whatsapp.el ends here
