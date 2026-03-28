;;; fsi-mcp.el --- Route F# Interactive through fsi-mcp-server -*- lexical-binding: t; -*-

;; Route fsharp-mode FSI eval commands through the fsi-mcp-server HTTP API
;; so Emacs and Claude Code share the same FSI session.
;;
;; Usage:
;;   (require 'fsi-mcp)
;;   (add-hook 'fsharp-mode-hook #'fsi-mcp-mode)
;;
;; Requires fsi-mcp-server running on the container (port 5020).
;; Uses SSE transport: persistent GET /sse + POST /message?sessionId=...
;; Responses arrive as SSE events on the persistent connection.

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

(defcustom fsi-mcp-request-timeout 10
  "Seconds to wait for a JSON-RPC response on the SSE stream."
  :type 'number)

(defvar fsi-mcp-buffer-name "*fsi-mcp*"
  "Name of the FSI MCP output buffer.")

(defvar fsi-mcp--initialized nil
  "Whether MCP session has been initialized.")

(defvar fsi-mcp--request-id 0
  "Counter for JSON-RPC request IDs.")

(defvar fsi-mcp--last-event-count 0
  "Event count before last send, used to detect new output.")

(defvar fsi-mcp--session-id nil
  "SSE session ID obtained from the /sse endpoint.")

(defvar fsi-mcp--sse-process nil
  "Network process holding the persistent SSE connection.")

(defvar fsi-mcp--responses (make-hash-table :test 'equal)
  "Hash table mapping JSON-RPC request IDs to their responses.")

(defvar fsi-mcp--sse-partial ""
  "Partial SSE data not yet terminated by a newline.")

;; ── SSE session management ──────────────────────────────────────────────────

(defun fsi-mcp--sse-alive-p ()
  "Return non-nil if the SSE connection is alive."
  (and fsi-mcp--sse-process
       (process-live-p fsi-mcp--sse-process)))

(defun fsi-mcp--sse-filter (_proc string)
  "Process filter for SSE stream. Parse JSON-RPC responses from events."
  (let ((input (concat fsi-mcp--sse-partial string)))
    (setq fsi-mcp--sse-partial "")
    (dolist (line (split-string input "\n"))
      (let ((trimmed (string-trim line)))
        (cond
         ((string-prefix-p "data:" trimmed)
          (let ((data (string-trim (substring trimmed 5))))
            (unless (string-empty-p data)
              ;; Endpoint event: extract session ID
              (if (string-match "/message\\?sessionId=\\([^ \t\r\n]+\\)" data)
                  (setq fsi-mcp--session-id (match-string 1 data))
                ;; JSON-RPC response
                (condition-case nil
                    (let* ((json (json-read-from-string data))
                           (id (cdr (assoc 'id json))))
                      (when id
                        (puthash id json fsi-mcp--responses)))
                  (error nil))))))
         ;; Incomplete line (no trailing newline yet) — save for next chunk
         ((and (not (string-empty-p trimmed))
               (not (string-prefix-p "event:" trimmed))
               (not (string-prefix-p "HTTP/" trimmed))
               (not (string-match-p "^[A-Za-z-]+:" trimmed)))
          (setq fsi-mcp--sse-partial trimmed)))))))

(defun fsi-mcp--kill-sse ()
  "Kill the SSE connection."
  (when (fsi-mcp--sse-alive-p)
    (delete-process fsi-mcp--sse-process))
  (setq fsi-mcp--sse-process nil
        fsi-mcp--session-id nil
        fsi-mcp--sse-partial ""
        fsi-mcp--initialized nil)
  (clrhash fsi-mcp--responses))

(defun fsi-mcp--acquire-session ()
  "Open persistent SSE connection and extract session ID.
The connection stays open to keep the server-side session alive.
Responses to JSON-RPC requests arrive as SSE events."
  (unless (and fsi-mcp--session-id (fsi-mcp--sse-alive-p))
    (fsi-mcp--kill-sse)
    (condition-case err
        (let ((proc (open-network-stream
                     "fsi-mcp-sse" nil fsi-mcp-host fsi-mcp-port)))
          (setq fsi-mcp--sse-process proc)
          (set-process-query-on-exit-flag proc nil)
          (set-process-filter proc #'fsi-mcp--sse-filter)
          ;; Send HTTP GET /sse
          (process-send-string
           proc
           (format (concat "GET /sse HTTP/1.1\r\n"
                           "Host: %s:%d\r\n"
                           "Accept: text/event-stream\r\n"
                           "Connection: keep-alive\r\n"
                           "\r\n")
                   fsi-mcp-host fsi-mcp-port))
          ;; Wait for session ID — the filter sets fsi-mcp--session-id
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (not fsi-mcp--session-id)
                        (< (float-time) deadline)
                        (process-live-p proc))
              (accept-process-output proc 0.2)))
          (unless fsi-mcp--session-id
            (fsi-mcp--kill-sse)
            (message "fsi-mcp: timeout waiting for session ID")))
      (error
       (fsi-mcp--kill-sse)
       (message "fsi-mcp: SSE connection failed - %s"
                (error-message-string err)))))
  fsi-mcp--session-id)

;; ── MCP protocol ──────────────────────────────────────────────────────────────

(defun fsi-mcp--message-url ()
  "Return the message endpoint URL with session ID."
  (let ((sid (fsi-mcp--acquire-session)))
    (if sid
        (format "http://%s:%d/message?sessionId=%s"
                fsi-mcp-host fsi-mcp-port sid)
      (error "fsi-mcp: no session — is the server running?"))))

(defun fsi-mcp--next-id ()
  "Return next JSON-RPC request ID."
  (cl-incf fsi-mcp--request-id))

(defun fsi-mcp--post-message (payload)
  "POST PAYLOAD to the message endpoint. Returns non-nil on success."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/json")))
         (url-request-data payload)
         (url-show-status nil))
    (condition-case nil
        (let ((buf (url-retrieve-synchronously (fsi-mcp--message-url) t nil 5)))
          (when buf (kill-buffer buf))
          t)
      (error nil))))

(defun fsi-mcp--request (method &optional params)
  "Send a JSON-RPC request and wait for the response on the SSE stream."
  (let* ((id (fsi-mcp--next-id))
         (payload (json-encode
                   `(("jsonrpc" . "2.0")
                     ("id" . ,id)
                     ("method" . ,method)
                     ,@(when params `(("params" . ,params)))))))
    (if (not (fsi-mcp--post-message payload))
        (progn
          (setq fsi-mcp--session-id nil)
          (message "fsi-mcp: POST failed")
          nil)
      ;; Wait for the matching response on the SSE stream
      (let ((deadline (+ (float-time) fsi-mcp-request-timeout)))
        (while (and (not (gethash id fsi-mcp--responses))
                    (< (float-time) deadline)
                    (fsi-mcp--sse-alive-p))
          (accept-process-output fsi-mcp--sse-process 0.2))
        (let ((resp (gethash id fsi-mcp--responses)))
          (remhash id fsi-mcp--responses)
          (unless resp
            (message "fsi-mcp: timeout waiting for response (id=%d)" id))
          resp)))))

(defun fsi-mcp--notify (method &optional params)
  "Send a JSON-RPC notification (no id, no response expected)."
  (let ((payload (json-encode
                  `(("jsonrpc" . "2.0")
                    ("method" . ,method)
                    ,@(when params `(("params" . ,params)))))))
    (fsi-mcp--post-message payload)))

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
    (when (and status (string-match "Event Statistics: \\([0-9]+\\)" status))
      (string-to-number (match-string 1 status)))))

(defun fsi-mcp--poll-for-output (code prev-count retries)
  "Poll for new FSI output after sending CODE.
Only shows events newer than PREV-COUNT."
  (let* ((cur-count (or (fsi-mcp--get-event-count) 0))
         (new-events (- cur-count prev-count)))
    (if (or (> new-events 0) (<= retries 0))
        (let ((events (fsi-mcp--call-tool "get_recent_fsi_events"
                                          `(("count" . ,(max 1 new-events))))))
          (when (and events (not (string-empty-p events)))
            (fsi-mcp--append-output events code)))
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
    ;; Snapshot event count before sending so we only show new output
    (let ((prev-count (or (fsi-mcp--get-event-count) 0))
          (result (fsi-mcp--call-tool "send_fsharp_code"
                                      `(("agentName" . "emacs")
                                        ("code" . ,trimmed)))))
      (if (null result)
          (message "fsi-mcp: failed to send code")
        ;; Poll for new output only
        (run-at-time fsi-mcp-poll-delay nil
                     #'fsi-mcp--poll-for-output
                     trimmed prev-count fsi-mcp-poll-retries)))))

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
  (fsi-mcp--kill-sse)
  (setq fsi-mcp--request-id 0)
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
