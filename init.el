;;; -*- lexical-binding: t -*-

;; Font size
(set-face-attribute 'default nil :height 140)

;; Use ibuffer instead of default buffer list
(global-set-key (kbd "C-x C-b") 'ibuffer)
(setq ibuffer-saved-filter-groups
      '(("default"
         ("Dired/Dirvish" (mode . dired-mode))
         ("Magit" (name . "^magit"))
         ("Org" (mode . org-mode))
         ("F#" (mode . fsharp-mode))
         ("Markdown" (mode . markdown-mode))
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

;; Package archives
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

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

;; Theme packages
(use-package doom-themes :ensure t)
(use-package ef-themes :ensure t)

;; Load theme early (before dashboard and other UI packages)
(load-theme 'manoj-dark t)

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
  :ensure t)

;; Install magit
(use-package magit
  :ensure t)

;; Install fsharp-mode with LSP support via eglot
(use-package fsharp-mode
  :defer t
  :ensure t
  :hook (fsharp-mode . eglot-ensure)
  :config
  (require 'eglot-fsharp)
  (setq eglot-fsharp-server-install-dir nil))

;; Fix fsautocomplete path for TRAMP/Podman containers
;; eglot-fsharp expands ~ to the local home, but in the container
;; fsautocomplete lives under /home/developer/.dotnet/tools/
;; NOTE: tramp-direct-async-process must be nil (default) — setting it
;; to t breaks stdin forwarding for Podman, causing eglot LSP timeouts.
(connection-local-set-profile-variables
 'podman-fsharp-profile
 '((eglot-fsharp-server-path . "/home/developer/.dotnet/tools/")))

(connection-local-set-profiles
 '(:application tramp :protocol "podman")
 'podman-fsharp-profile)

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
  (add-hook 'vterm-mode-hook #'vterm-setup-dnd))

;; Docker/Podman management
(use-package docker
  :ensure t
  :bind ("C-c d" . docker)
  :config
  (setq docker-command "podman"))

;; Dockerfile/Containerfile editing
(use-package dockerfile-mode
  :ensure t)

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

;; Startup buffers
(add-hook 'emacs-startup-hook
          (lambda ()
            ;; Claude Code in SystemAdmin → *sysadmin*
            (let ((default-directory "~/Documents/Projects/SystemAdmin/"))
              (claude-code)
              (when-let ((buf (car (claude-code--find-claude-buffers-for-directory default-directory))))
                (with-current-buffer buf
                  (rename-buffer "*sysadmin*"))))
            ;; vterm in emacs-dev container → *projects*
            ;; Start container if not running
            (unless (string-match-p "emacs-dev"
                      (shell-command-to-string "podman ps --format '{{.Names}}'"))
              (shell-command "podman start emacs-dev"))
            (vterm "*projects*")
            (vterm-send-string "podman exec -it emacs-dev bash -c 'cd /home/developer/Projects && exec bash'\n")
            ;; cterm - general terminal in emacs-dev container
            (vterm "*cterm*")
            (vterm-send-string "podman exec -it emacs-dev bash\n")))

;; Open files in running Podman containers via TRAMP
(defun podman-find-file ()
  "Find file in a running Podman container."
  (interactive)
  (let* ((containers (split-string
                      (shell-command-to-string
                       "podman ps --format '{{.Names}}'") "\n" t))
         (container (completing-read "Container: " containers)))
    (find-file (format "/podman:%s:/" container))))

(global-set-key (kbd "C-c p") #'podman-find-file)

;; Open vterm session in a running Podman container
(defun podman-vterm ()
  "Open vterm in a running Podman container."
  (interactive)
  (let* ((containers (split-string
                      (shell-command-to-string
                       "podman ps --format '{{.Names}}'") "\n" t))
         (container (completing-read "Container: " containers)))
    (vterm (format "*podman:%s*" container))
    (vterm-send-string (format "podman exec -it %s /bin/bash\n" container))))

(global-set-key (kbd "C-c v") #'podman-vterm)

;; cterm - dedicated vterm terminal in the emacs-dev container
(defun cterm ()
  "Open a vterm terminal named *cterm* in the emacs-dev container."
  (interactive)
  (unless (string-match-p "emacs-dev"
            (shell-command-to-string "podman ps --format '{{.Names}}'"))
    (shell-command "podman start emacs-dev"))
  (vterm "*cterm*")
  (vterm-send-string "podman exec -it emacs-dev bash\n"))

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

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(custom-enabled-themes '(doom-dracula))
 '(custom-safe-themes
   '("8c7e832be864674c220f9a9361c851917a93f921fedb7717b1b5ece47690c098"
     default))
 '(package-selected-packages nil))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
