;;; emacs-hypervisor-extensions.el --- Extension options -*- lexical-binding: t; -*-

(defgroup emacs-hypervisor-extensions nil
  "Emacs Hypervisor configuration."
  :group 'emacs-hypervisor)

(defvar emacs-hypervisor-extension-setting-functions nil
  "Functions that return extension settings plists.")

(defun emacs-hypervisor-register-extension-settings (function)
  "Register FUNCTION as an extension settings provider."
  (add-hook 'emacs-hypervisor-extension-setting-functions function))

(defun emacs-hypervisor--extension-feature-settings ()
  "Return all registered extension feature settings."
  (apply #'append
         (mapcar #'funcall emacs-hypervisor-extension-setting-functions)))

(defun emacs-hypervisor-export-extension-settings ()
  "Return extension settings for Elle startup."
  (emacs-hypervisor--extension-feature-settings))

(provide 'emacs-hypervisor-extensions)
