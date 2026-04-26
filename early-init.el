;;; -*- lexical-binding: t; -*-

;; Temporarily increase GC threshold during startup
(setq gc-cons-threshold most-positive-fixnum)

;; Restore to normal value after startup (100MB)
(add-hook 'emacs-startup-hook
          (lambda () (setq gc-cons-threshold (* 100 1024 1024))))

;;
;; GUI settings before rendering
;;

(setq inhibit-startup-screen t)

(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(horizontal-scroll-bar-mode -1)

;;
;; Frame settings
;;
(setq frame-resize-pixelwise t)

(add-to-list 'default-frame-alist '(undecorated-round . t))

(add-to-list 'initial-frame-alist '(width . 128))
(add-to-list 'initial-frame-alist '(height . 50))

(modify-all-frames-parameters
 '((right-divider-width . 10)
   (internal-border-width . 10)))
