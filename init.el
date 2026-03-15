;;; -*- lexical-binding: t -*-

;; Font size
(set-face-attribute 'default nil :height 140)

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

;; Install vterm (terminal backend for claude-code-ide)
(use-package vterm
  :ensure t)

;; Docker/Podman management
(use-package docker
  :ensure t
  :bind ("C-c d" . docker))

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

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(custom-enabled-themes '(deeper-blue)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
