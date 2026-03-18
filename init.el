;;; -*- lexical-binding: t -*-

;; Font size
(set-face-attribute 'default nil :height 140)

;; Use ibuffer instead of default buffer list
(global-set-key (kbd "C-x C-b") 'ibuffer)

;; Auto-revert buffers (including dired) when files change on disk
(setq global-auto-revert-non-file-buffers t)
(global-auto-revert-mode 1)

;; Package archives
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

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
(connection-local-set-profile-variables
 'podman-fsharp-profile
 '((eglot-fsharp-server-path . "/home/developer/.dotnet/tools/")))

(connection-local-set-profiles
 '(:application tramp :protocol "podman")
 'podman-fsharp-profile)

;; Install vterm (terminal backend for claude-code-ide)
(use-package vterm
  :ensure t)

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
 '(custom-enabled-themes '(deeper-blue))
 '(package-selected-packages
   '(claude-code claude-code-ide docker dockerfile-mode fsharp-mode magit
		 markdown-mode vterm)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
