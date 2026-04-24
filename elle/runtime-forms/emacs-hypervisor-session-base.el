;;; emacs-hypervisor-session-base.el --- Session state bootstrap -*- lexical-binding: t; -*-

(require 'cl-lib)

(defvar emacs-hypervisor-execution-events nil)
(defvar emacs-hypervisor-installed-packages nil)
(setq emacs-hypervisor-execution-events nil)
(setq emacs-hypervisor-installed-packages nil)

(provide 'emacs-hypervisor-session-base)
