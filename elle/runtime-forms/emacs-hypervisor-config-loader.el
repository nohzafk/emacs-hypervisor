;;; emacs-hypervisor-config-loader.el --- Config loading helpers -*- lexical-binding: t; -*-

(require 'emacs-hypervisor-config-paths)
(require 'emacs-hypervisor-declarations)

(defconst emacs-hypervisor--config-org-elisp-lang-regexp
  (rx string-start (or "elisp" "emacs-lisp") string-end)
  "Org Babel language tags accepted for Emacs Lisp config blocks.")

(defun emacs-hypervisor--tangle-config-org-file (config-org-file)
  "Tangle CONFIG-ORG-FILE and return the generated load target."
  (let ((tangled-file
         (expand-file-name
          ".config.tangled.el"
          (file-name-directory config-org-file))))
    (require 'ob-tangle)
    (org-babel-tangle-file
     config-org-file tangled-file
     emacs-hypervisor--config-org-elisp-lang-regexp)
    tangled-file))

(defun emacs-hypervisor-config-loader-prepare-load-target
    (&optional config-file config-org-file)
  "Return the config file to load, tangling CONFIG-ORG-FILE when present."
  (let ((config-file (or config-file (emacs-hypervisor--config-file)))
        (config-org-file
         (or config-org-file
             (let ((path (emacs-hypervisor--config-org-file)))
               (and (file-exists-p path) path)))))
    (if config-org-file
        (emacs-hypervisor--tangle-config-org-file config-org-file)
      config-file)))

(defun emacs-hypervisor-tangle-config ()
  "Tangle repo-root config.org into the shadow tangled file."
  (interactive)
  (let ((config-org-file (emacs-hypervisor--config-org-file)))
    (unless (and config-org-file (file-exists-p config-org-file))
      (user-error "No config.org at %s" config-org-file))
    (emacs-hypervisor--tangle-config-org-file config-org-file)))

(defun emacs-hypervisor-load-startup-config (&optional config-file config-org-file)
  "Reset declarations and load CONFIG-FILE or tangled CONFIG-ORG-FILE.

When called without arguments, use the configured Hypervisor paths inside
Emacs. This keeps boot-context paths out of the host-to-Emacs eval payload."
  (let ((load-target
         (emacs-hypervisor-config-loader-prepare-load-target
          config-file
          config-org-file)))
    (emacs-hypervisor-reset-declarations)
    (load-file load-target)
    :ok))

(provide 'emacs-hypervisor-config-loader)
