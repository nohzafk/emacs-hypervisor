;;; emacs-hypervisor-extensions.el --- Extension options -*- lexical-binding: t; -*-

(defgroup emacs-hypervisor-extensions nil
  "Emacs Hypervisor configuration."
  :group 'emacs-hypervisor)

(defcustom emacs-hypervisor-extensions nil
  "Comma-separated Hypervisor extension feature names, or nil to disable extensions."
  :type '(choice (const :tag "Disabled" nil)
                 (string :tag "Extensions"))
  :group 'emacs-hypervisor-extensions)

(defvar emacs-hypervisor-extension-setting-functions nil
  "Functions that return extension settings plists.")

(defun emacs-hypervisor-register-extension-settings (function)
  "Register FUNCTION as an extension settings provider."
  (add-hook 'emacs-hypervisor-extension-setting-functions function))

(defun emacs-hypervisor--extension-feature-settings ()
  "Return all registered extension feature settings."
  (apply #'append
         (mapcar #'funcall emacs-hypervisor-extension-setting-functions)))

(defun emacs-hypervisor-extension-enabled-p (name)
  "Return non-nil when extension feature NAME is requested."
  (and (stringp emacs-hypervisor-extensions)
       (member name
               (mapcar #'string-trim
                       (split-string emacs-hypervisor-extensions "," t)))))

(defun emacs-hypervisor-export-extension-settings ()
  "Return extension settings for Elle startup."
  (let ((feature-settings (emacs-hypervisor--extension-feature-settings)))
    (append
     (list :extensions-enabled
           (and (stringp emacs-hypervisor-extensions)
                (not (string-empty-p emacs-hypervisor-extensions)))
           :extensions emacs-hypervisor-extensions)
     feature-settings)))

(provide 'emacs-hypervisor-extensions)
