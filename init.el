;;; -*- lexical-binding: t -*-

;; ── Post-init GC ───────────────────────────────────────────────────────────────
;; early-init.el sets gc-cons-threshold to most-positive-fixnum; settle to 50MB
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 50 1024 1024))
            (run-with-idle-timer 5 t #'garbage-collect)))

;; ── General settings ───────────────────────────────────────────────────────────

;; Disable audible bell (causes HDMI signal drops)
(setq ring-bell-function 'ignore)

;; Font size
(set-face-attribute 'default nil :height 140)

;; Column number in modeline
(column-number-mode 1)

;; Remember minibuffer history and cursor positions across sessions
(savehist-mode 1)
(save-place-mode 1)

;; Centralize backup, auto-save, and lock files
(setq backup-directory-alist `(("." . ,(expand-file-name "backups/" user-emacs-directory))))
(setq auto-save-file-name-transforms
      `((".*" ,(expand-file-name "auto-saves/" user-emacs-directory) t)))
(setq create-lockfiles nil)

;; Separate file for Custom so it doesn't pollute init.el
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(when (file-exists-p custom-file) (load custom-file))

;; Use ibuffer instead of default buffer list
(global-set-key (kbd "C-x C-b") 'ibuffer)
(setq ibuffer-saved-filter-groups
      '(("default"
         ("Dired/Dirvish" (mode . dired-mode))
         ("Magit" (name . "^magit"))
         ("Org" (mode . org-mode))
         ("F#" (mode . fsharp-mode))
         ("Nushell" (mode . nushell-mode))
         ("Markdown" (mode . markdown-mode))
         ("Books" (mode . nov-mode))
         ("Terminal" (mode . vterm-mode))
         ("Emacs" (or (name . "^\\*") (name . "^\\s-"))))))
(add-hook 'ibuffer-mode-hook
          (lambda () (ibuffer-switch-to-saved-filter-groups "default")))

;; Kill buffers and processes without confirmation
(setq kill-buffer-query-functions nil)
(setq confirm-kill-processes nil)

;; Auto-revert buffers (including dired) when files change on disk
(setq global-auto-revert-non-file-buffers t)
(global-auto-revert-mode 1)

;; TRAMP buffers: file-notify doesn't work over Podman, fall back to polling
;; Keep inotify enabled for local files — only disable for remote
(setq auto-revert-remote-files t)
(setq auto-revert-use-notify t)
(add-hook 'find-file-hook
          (lambda ()
            (when (file-remote-p default-directory)
              (setq-local auto-revert-use-notify nil))))

;; Package archives (early-init.el defers package init, so initialize here)
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)

;; Vertico - vertical completion UI
(use-package vertico
  :ensure t
  :init
  (vertico-mode))

;; Orderless - flexible completion matching (fuzzy, regex, etc.)
(use-package orderless
  :ensure t
  :config
  (setq completion-styles '(orderless basic)))

;; Consult - enhanced search and navigation commands
(use-package consult
  :ensure t
  :bind (("C-x b" . consult-buffer)
         ("C-s" . consult-line)
         ("M-g g" . consult-goto-line)))

;; Marginalia - annotations for completion candidates
(use-package marginalia
  :ensure t
  :init
  (marginalia-mode))

;; Which-key - show available keybindings after prefix
(use-package which-key
  :ensure t
  :init
  (which-key-mode))

;; Corfu - in-buffer completion popup (uses eglot's completion-at-point)
(use-package corfu
  :ensure t
  :init
  (global-corfu-mode)
  :config
  (setq corfu-auto t))

;; Theme packages
(use-package doom-themes
  :ensure t
  :config
  (load-theme 'doom-nord t))

;; Window dividers — clear borders between buffers
(setq window-divider-default-right-width 6
      window-divider-default-bottom-width 6
      window-divider-default-places t)
(window-divider-mode 1)
(set-face-foreground 'window-divider "#6272a4")

;; Dashboard - startup screen with recent files and projects
(use-package dashboard
  :ensure t
  :config
  (setq dashboard-items '((recents . 10)
                          (bookmarks . 5)
                          (projects . 5)))
  (setq dashboard-center-content t)
  (dashboard-setup-startup-hook))

;; Install org-mode
(use-package org
  :ensure t
  :defer t)

;; Install magit
(use-package magit
  :ensure t
  :defer t)

;; Install fsharp-mode with LSP support via eglot
(use-package fsharp-mode
  :defer t
  :ensure t
  :hook (fsharp-mode . eglot-ensure)
  :config
  ;; Register fsautocomplete as the eglot server for fsharp-mode
  ;; TRAMP strips \r\n from LSP headers; fsautocomplete-lsp wrapper re-adds them
  (with-eval-after-load 'eglot
    (add-to-list 'eglot-server-programs
                 `(fsharp-mode . ,(lambda (interactive project)
                                    (if (file-remote-p (project-root project))
                                        '("fsautocomplete-lsp")
                                      '("fsautocomplete" "--adaptive-lsp-server-enabled")))))))

;; FSI via MCP server — shares the FSI session with Claude Code
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))
(require 'fsi-mcp)
(setq fsi-mcp-host "127.0.0.1")
(add-hook 'fsharp-mode-hook #'fsi-mcp-mode)

;; Podman container: add dotnet tools to TRAMP remote path
;; NOTE: tramp-direct-async-process must be nil (default) — setting it
;; to t breaks stdin forwarding for Podman, causing eglot LSP timeouts.
(with-eval-after-load 'tramp
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path))

;; Install vterm (terminal backend for claude-code-ide)
(use-package vterm
  :ensure t
  :config
  ;; Enable drag-and-drop file paths into vterm (for Claude Code image input, etc.)
  (defun vterm-dnd-send-file-path (uri action)
    "Handle drag-and-drop in vterm by sending the file path as text."
    (let ((file (dnd-get-local-file-name uri t)))
      (when (and file (eq major-mode 'vterm-mode))
        (vterm-send-string file)
        action)))
  (defun vterm-setup-dnd ()
    "Set up drag-and-drop handler for vterm buffers."
    (setq-local dnd-protocol-alist
                (cons '("^file:" . vterm-dnd-send-file-path)
                      dnd-protocol-alist)))
  (add-hook 'vterm-mode-hook #'vterm-setup-dnd)
  (setq vterm-shell "/usr/bin/nu")
  (setq vterm-tramp-shells '(("ssh" login-shell) ("scp" login-shell)
                              ("docker" "/usr/bin/nu") ("podman" "/usr/bin/nu"))))

;; EAF - Emacs Application Framework (deferred until first use)
(let ((eaf-dir (expand-file-name "site-lisp/emacs-application-framework" user-emacs-directory)))
  (when (file-directory-p eaf-dir)
    (add-to-list 'load-path eaf-dir)
    (let ((app-dir (expand-file-name "app" eaf-dir)))
      (when (file-directory-p app-dir)
        (dolist (app (directory-files app-dir t "^[^.]"))
          (when (file-directory-p app)
            (add-to-list 'load-path app)))))))
(setq eaf-python-command (expand-file-name "site-lisp/emacs-application-framework/.venv/bin/python" user-emacs-directory)
      eaf-find-file-advisor-enable nil
      eaf-dired-advisor-enable nil)
(autoload 'eaf-open "eaf" nil t)
(autoload 'eaf-open-browser "eaf" nil t)
(autoload 'eaf-open-url "eaf" nil t)
(with-eval-after-load 'eaf
  (require 'eaf-browser)
  (require 'eaf-pdf-viewer)
  (require 'eaf-music-player)
  (require 'eaf-video-player)
  (require 'eaf-js-video-player)
  (require 'eaf-image-viewer)
  (require 'eaf-rss-reader)
  (require 'eaf-pyqterminal)
  (require 'eaf-markdown-previewer)
  (require 'eaf-org-previewer)
  (require 'eaf-camera)
  (require 'eaf-git)
  (require 'eaf-mindmap)
  (require 'eaf-mind-elixir)
  (require 'eaf-system-monitor)
  (require 'eaf-file-browser)
  (require 'eaf-file-sender)
  (require 'eaf-airshare)
  (require 'eaf-jupyter)
  (require 'eaf-markmap)
  (require 'eaf-map)
  (require 'eaf-video-editor)
  (require 'eaf-2048))
(global-set-key (kbd "C-c w") #'eaf-open-browser)

;; Docker/Podman management
(use-package docker
  :ensure t
  :bind ("C-c d" . docker)
  :config
  (setq docker-command "podman"))

;; Dockerfile/Containerfile editing
(use-package dockerfile-mode
  :ensure t
  :defer t)

;; Nushell script editing
(use-package nushell-mode
  :vc (:url "https://github.com/mrkkrp/nushell-mode" :rev :newest)
  :mode ("\\.nu\\'" . nushell-mode))

;; Install claude-code-ide
(use-package claude-code-ide
  :vc (:url "https://github.com/manzaltu/claude-code-ide.el" :rev :newest)
  :bind ("C-c C-'" . claude-code-ide-menu)
  :config
  (claude-code-ide-emacs-tools-setup))

;; Install inheritenv (required by claude-code)
(use-package inheritenv
  :vc (:url "https://github.com/purcell/inheritenv" :rev :newest))

;; Install claude-code.el (stevemolitor)
(use-package claude-code
  :vc (:url "https://github.com/stevemolitor/claude-code.el" :rev :newest)
  :config
  (setq claude-code-terminal-backend 'vterm)
  (claude-code-mode)
  :bind-keymap ("C-c c" . claude-code-command-map))

;; MCP Server — expose Emacs to Claude Code via Unix socket
(use-package mcp-server
  :vc (:url "https://github.com/rhblind/emacs-mcp-server" :rev :newest)
  :config
  (setq mcp-server-socket-directory "~/.config/emacs/")
  (add-hook 'emacs-startup-hook #'mcp-server-start-unix))

;; Startup buffers
(add-hook 'emacs-startup-hook
          (lambda ()
            ;; Claude Code in SystemAdmin → *sysadmin*
            (let ((default-directory "~/Documents/Projects/SystemAdmin/"))
              (claude-code)
              (when-let ((buf (car (claude-code--find-claude-buffers-for-directory default-directory))))
                (with-current-buffer buf
                  (rename-buffer "*sysadmin*"))))
            ;; Start emacs-dev container asynchronously, then open vterms once ready
            (set-process-sentinel
             (start-process "podman-ensure" nil "bash" "-c"
                            "podman ps --format '{{.Names}}' | grep -q emacs-dev || podman start emacs-dev")
             (lambda (_proc event)
               (if (string-match-p "finished" event)
                   (run-at-time 0 nil
                     (lambda ()
                       ;; vterm in emacs-dev container → *projects*
                       (vterm "*projects*")
                       (vterm-send-string "podman exec -it emacs-dev nu -c 'cd /home/developer/Projects; nu'\n")
                       ;; cterm - general terminal in emacs-dev container
                       (vterm "*cterm*")
                       (vterm-send-string "podman exec -it emacs-dev /usr/bin/nu\n")))
                 (message "podman-ensure failed: %s" (string-trim event)))))))

;; Open files in running Podman containers via TRAMP
(defun podman-find-file ()
  "Find file in a running Podman container.
If already in a TRAMP podman buffer, open dired at that container's root."
  (interactive)
  (let* ((tramp-info (and (tramp-tramp-file-p default-directory)
                          (tramp-dissect-file-name default-directory)))
         (container (if (and tramp-info
                             (string= (tramp-file-name-method tramp-info) "podman"))
                        (tramp-file-name-host tramp-info)
                      (completing-read "Container: "
                        (split-string
                         (shell-command-to-string
                          "podman ps --format '{{.Names}}'") "\n" t)))))
    (find-file (format "/podman:%s:/" container))))

(global-set-key (kbd "C-c p") #'podman-find-file)

;; Open vterm session in a running Podman container
(defun podman-vterm ()
  "Open vterm in a running Podman container.
If already in a TRAMP podman buffer, use that container."
  (interactive)
  (let* ((tramp-info (and (tramp-tramp-file-p default-directory)
                          (tramp-dissect-file-name default-directory)))
         (container (if (and tramp-info
                             (string= (tramp-file-name-method tramp-info) "podman"))
                        (tramp-file-name-host tramp-info)
                      (completing-read "Container: "
                        (split-string
                         (shell-command-to-string
                          "podman ps --format '{{.Names}}'") "\n" t)))))
    (let ((default-directory "~/"))
      (vterm (generate-new-buffer-name (format "*podman:%s*" container))))
    (vterm-send-string (format "podman exec -it %s /usr/bin/nu\n" container))))

(global-set-key (kbd "C-c v") #'podman-vterm)

;; cterm - dedicated vterm terminal in the emacs-dev container
(defun cterm ()
  "Open a vterm terminal named *cterm* in the emacs-dev container."
  (interactive)
  (unless (string-match-p "emacs-dev"
            (shell-command-to-string "podman ps --format '{{.Names}}'"))
    (shell-command "podman start emacs-dev"))
  (vterm "*cterm*")
  (vterm-send-string "podman exec -it emacs-dev /usr/bin/nu\n"))

(global-set-key (kbd "C-c t") #'cterm)

;; Dirvish - enhanced dired
(setq dired-dwim-target t)
(use-package dirvish
  :ensure t
  :init
  (dirvish-override-dired-mode)
  :bind (:map dirvish-mode-map
         ("TAB" . dirvish-layout-toggle)))

;; Markdown editing and live preview
(use-package markdown-mode
  :ensure t
  :mode (("\\.md\\'" . markdown-mode)
         ("\\.markdown\\'" . markdown-mode))
  :bind (:map markdown-mode-map
         ("C-c m p" . markdown-live-preview-mode)
         ("C-c m e" . markdown-export)
         ("C-c m o" . markdown-open)))

;; Epub reader
(use-package nov
  :ensure t
  :mode ("\\.epub\\'" . nov-mode)
  :hook (nov-mode . (lambda ()
                      (visual-line-mode 1)
                      (variable-pitch-mode 1)
                      (face-remap-add-relative 'variable-pitch :height 1.1)
                      (setq-local cursor-type 'bar)))
  :custom
  (nov-text-width 80))
