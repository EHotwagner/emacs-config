;;; -*- lexical-binding: t -*-

;; Prevent package.el from initializing before init.el
(setq package-enable-at-startup nil)

;; Suppress startup screen (dashboard replaces it)
(setq inhibit-startup-screen t)

;; Remove UI elements before frame renders (no flash)
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)

;; Raise GC threshold during init (reset after startup in init.el)
(setq gc-cons-threshold most-positive-fixnum)
