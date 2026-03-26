;;; fsi-mcp.el --- Route F# Interactive through fsi-mcp-server -*- lexical-binding: t; -*-

;; Route fsharp-mode FSI eval commands through the fsi-mcp-server HTTP API
;; so Emacs and Claude Code share the same FSI session.
;;
;; Usage:
;;   (require 'fsi-mcp)
;;   (add-hook 'fsharp-mode-hook #'fsi-mcp-mode)
;;
;; Requires fsi-mcp-server running on the container (port 5020).

(require 'json)
(require 'url)

(defgroup fsi-mcp nil
  "FSI MCP server integration."
  :group 'fsharp
  :prefix "fsi-mcp-")

(defcustom fsi-mcp-host "localhost"
  "Host where fsi-mcp-server is running."
  :type 'string)

(defcustom fsi-mcp-port 5020
  "Port where fsi-mcp-server is running."
  :type 'integer)

(defcustom fsi-mcp-poll-delay 0.4
  "Seconds to wait before polling for FSI output after sending code."
  :type 'number)

(defcustom fsi-mcp-poll-retries 5
  "Number of times to retry polling for new output."
  :type 'integer)

(defcustom fsi-mcp-poll-interval 0.3
  "Seconds between poll retries."
  :type 'number)

(defvar fsi-mcp-buffer-name "*fsi-mcp*"
  "Name of the FSI MCP output buffer.")

(defvar fsi-mcp--initialized nil
  "Whether MCP session has been initialized.")

(defvar fsi-mcp--request-id 0
  "Counter for JSON-RPC request IDs.")

(defvar fsi-mcp--last-event-count 0
  "Event count before last send, used to detect new output.")

;; ── MCP protocol ──────────────────────────────────────────────────────────────

(defun fsi-mcp--url ()
  "Return the MCP endpoint URL."
  (format "http://%s:%d/mcp" fsi-mcp-host fsi-mcp-port))

(defun fsi-mcp--next-id ()
  "Return next JSON-RPC request ID."
  (cl-incf fsi-mcp--request-id))

(defun fsi-mcp--parse-response (buffer)
  "Parse JSON-RPC response from BUFFER, handling both plain JSON and SSE."
  (unwind-protect
      (with-current-buffer buffer
        (goto-char (point-min))
        ;; Skip HTTP headers
        (when (re-search-forward "\n\n" nil t)
          (let ((body (buffer-substring-no-properties (point) (point-max))))
            (cond
             ;; SSE format: extract last data: line
             ((string-match-p "^event:" body)
              (let ((result nil))
                (dolist (line (split-string body "\n"))
                  (when (string-prefix-p "data:" line)
                    (let ((data (string-trim (substring line 5))))
                      (unless (string-empty-p data)
                        (condition-case nil
                            (setq result (json-read-from-string data))
                          (error nil))))))
                result))
             ;; Plain JSON
             (t
              (condition-case nil
                  (json-read-from-string (string-trim body))
                (error nil)))))))
    (kill-buffer buffer)))

(defun fsi-mcp--request (method &optional params)
  "Send a JSON-RPC request with METHOD and PARAMS to the MCP server."
  (let* ((id (fsi-mcp--next-id))
         (payload (json-encode
                   `(("jsonrpc" . "2.0")
                     ("id" . ,id)
                     ("method" . ,method)
                     ,@(when params `(("params" . ,params))))))
         (url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/json")
            ("Accept" . "application/json, text/event-stream")))
         (url-request-data payload)
         (url-show-status nil))
    (condition-case err
        (let ((buf (url-retrieve-synchronously (fsi-mcp--url) t nil 10)))
          (if buf
              (fsi-mcp--parse-response buf)
            (message "fsi-mcp: no response from server")
            nil))
      (error
       (message "fsi-mcp: connection failed - %s" (error-message-string err))
       nil))))

(defun fsi-mcp--notify (method &optional params)
  "Send a JSON-RPC notification (no id, no response expected)."
  (let* ((payload (json-encode
                   `(("jsonrpc" . "2.0")
                     ("method" . ,method)
                     ,@(when params `(("params" . ,params))))))
         (url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/json")))
         (url-request-data payload)
         (url-show-status nil))
    (condition-case nil
        (let ((buf (url-retrieve-synchronously (fsi-mcp--url) t nil 5)))
          (when buf (kill-buffer buf)))
      (error nil))))

(defun fsi-mcp--ensure-initialized ()
  "Initialize MCP session if needed."
  (unless fsi-mcp--initialized
    (let ((resp (fsi-mcp--request
                 "initialize"
                 `(("protocolVersion" . "2025-03-26")
                   ("capabilities" . ,(make-hash-table))
                   ("clientInfo" . (("name" . "emacs-fsi-mcp")
                                    ("version" . "1.0")))))))
      (when resp
        (fsi-mcp--notify "notifications/initialized")
        (setq fsi-mcp--initialized t)))))

(defun fsi-mcp--call-tool (name arguments)
  "Call MCP tool NAME with ARGUMENTS and return extracted text."
  (fsi-mcp--ensure-initialized)
  (let ((resp (fsi-mcp--request "tools/call"
                                `(("name" . ,name)
                                  ("arguments" . ,arguments)))))
    (when resp
      (let* ((result (cdr (assoc 'result resp)))
             (content (cdr (assoc 'content result))))
        (when (and content (> (length content) 0))
          (cdr (assoc 'text (aref content 0))))))))

;; ── Output buffer ─────────────────────────────────────────────────────────────

(define-derived-mode fsi-mcp-output-mode special-mode "FSI-MCP"
  "Major mode for FSI MCP output."
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil))

(defun fsi-mcp--output-buffer ()
  "Get or create the FSI MCP output buffer."
  (let ((buf (get-buffer-create fsi-mcp-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'fsi-mcp-output-mode)
        (fsi-mcp-output-mode)))
    buf))

(defun fsi-mcp--append-output (text &optional input-code)
  "Append TEXT to the output buffer. Show INPUT-CODE as the prompt line."
  (let ((buf (fsi-mcp--output-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (when input-code
        (insert (propertize (concat "> " input-code "\n")
                            'face 'font-lock-keyword-face)))
      (when (and text (not (string-empty-p text)))
        (insert text)
        (unless (string-suffix-p "\n" text) (insert "\n")))
      (insert "\n"))
    (display-buffer buf '(nil (inhibit-switch-frame . t)))
    (with-selected-window (get-buffer-window buf t)
      (goto-char (point-max))
      (recenter -3))))

;; ── Polling for output ────────────────────────────────────────────────────────

(defun fsi-mcp--get-event-count ()
  "Get current event count from server status."
  (let ((status (fsi-mcp--call-tool "get_fsi_status" (make-hash-table))))
    (when (and status (string-match "event count: \\([0-9]+\\)" status))
      (string-to-number (match-string 1 status)))))

(defun fsi-mcp--poll-for-output (code prev-count retries)
  "Poll for new output after sending CODE. PREV-COUNT is pre-send event count."
  (let ((events (fsi-mcp--call-tool "get_recent_fsi_events"
                                    `(("count" . 10)))))
    (if (or (and events (not (string-empty-p events)))
            (<= retries 0))
        (fsi-mcp--append-output events code)
      (run-at-time fsi-mcp-poll-interval nil
                   #'fsi-mcp--poll-for-output
                   code prev-count (1- retries)))))

;; ── Interactive commands ──────────────────────────────────────────────────────

(defun fsi-mcp-send (code)
  "Send CODE to FSI via MCP server and display the output."
  (let ((trimmed (string-trim code)))
    (when (string-empty-p trimmed)
      (user-error "Nothing to send"))
    ;; Ensure code ends with ;;
    (unless (string-match-p ";;[ \t]*$" trimmed)
      (setq trimmed (concat trimmed " ;;")))
    (let ((result (fsi-mcp--call-tool "send_fsharp_code"
                                      `(("agentName" . "emacs")
                                        ("code" . ,trimmed)))))
      (if (null result)
          (message "fsi-mcp: failed to send code")
        ;; Poll for output after a delay
        (run-at-time fsi-mcp-poll-delay nil
                     #'fsi-mcp--poll-for-output
                     trimmed 0 fsi-mcp-poll-retries)))))

(defun fsi-mcp-eval-region (start end)
  "Send region to FSI via MCP."
  (interactive "r")
  (fsi-mcp-send (buffer-substring-no-properties start end)))

(defun fsi-mcp-eval-phrase ()
  "Send the current F# block/phrase to FSI via MCP."
  (interactive)
  (save-excursion
    (let ((start (progn (fsharp-beginning-of-block) (point)))
          (end (progn (fsharp-end-of-block) (point))))
      (fsi-mcp-eval-region start end))))

(defun fsi-mcp-eval-buffer ()
  "Send the entire buffer to FSI via MCP."
  (interactive)
  (fsi-mcp-eval-region (point-min) (point-max)))

(defun fsi-mcp-load-file (filename)
  "Load an F# script via MCP."
  (interactive "fF# script: ")
  ;; Resolve TRAMP paths to container-local paths
  (when (tramp-tramp-file-p filename)
    (setq filename (tramp-file-name-localname
                    (tramp-dissect-file-name filename))))
  (let ((result (fsi-mcp--call-tool "LoadFSharpScript"
                                    `(("filePath" . ,filename)))))
    (fsi-mcp--append-output result (format "#load \"%s\"" filename))))

(defun fsi-mcp-show-events (&optional count)
  "Show recent FSI events. With prefix arg, specify COUNT."
  (interactive "P")
  (let ((events (fsi-mcp--call-tool "get_recent_fsi_events"
                                    `(("count" . ,(or count 20))))))
    (fsi-mcp--append-output events "-- recent events --")))

(defun fsi-mcp-status ()
  "Show FSI MCP server status."
  (interactive)
  (let ((status (fsi-mcp--call-tool "get_fsi_status" (make-hash-table))))
    (message "FSI-MCP: %s" (or status "no response"))))

(defun fsi-mcp-reset ()
  "Reset the MCP session (re-initialize on next call)."
  (interactive)
  (setq fsi-mcp--initialized nil
        fsi-mcp--request-id 0)
  (message "fsi-mcp: session reset"))

;; ── Minor mode ────────────────────────────────────────────────────────────────

(defvar fsi-mcp-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'fsi-mcp-eval-region)
    (define-key map (kbd "C-c C-e") #'fsi-mcp-eval-phrase)
    (define-key map (kbd "C-x C-e") #'fsi-mcp-eval-phrase)
    (define-key map (kbd "C-c C-b") #'fsi-mcp-eval-buffer)
    (define-key map (kbd "C-c C-f") #'fsi-mcp-load-file)
    (define-key map (kbd "C-c C-s") #'fsi-mcp-show-events)
    map)
  "Keymap for `fsi-mcp-mode`.
Shadows the default fsharp-mode FSI bindings.")

;;;###autoload
(define-minor-mode fsi-mcp-mode
  "Route F# Interactive eval through fsi-mcp-server.
When enabled, C-c C-r / C-c C-e / etc. send code to the MCP server
instead of spawning a local dotnet fsi process."
  :lighter " FSI-MCP"
  :keymap fsi-mcp-mode-map
  (when fsi-mcp-mode
    (require 'tramp nil t)))

(provide 'fsi-mcp)
;;; fsi-mcp.el ends here
