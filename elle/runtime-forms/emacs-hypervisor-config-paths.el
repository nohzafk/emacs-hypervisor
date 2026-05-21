;;; emacs-hypervisor-config-paths.el --- Config path resolution -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolve the paths Hypervisor uses at startup and reload: the user-owned
;; Hypervisor config directory, the active `config.el' / `config.org' /
;; tangled-shadow files, and the env snapshot file.  User-facing variables
;; `emacs-hypervisor-config-file', `emacs-hypervisor-config-org-file', and
;; `emacs-hypervisor-env-file' (declared in `home-startup.el') override the
;; defaults when bound.

(defun emacs-hypervisor--repo-file (name)
  (expand-file-name name user-emacs-directory))

(defun emacs-hypervisor--xdg-config-home ()
  "Return the XDG config home directory with HOME/.config fallback."
  (let ((xdg-config-home (getenv "XDG_CONFIG_HOME")))
    (if (and xdg-config-home (not (equal xdg-config-home "")))
        xdg-config-home
      "~/.config")))

(defun emacs-hypervisor--config-directory ()
  "Return the fixed user-owned Hypervisor config directory."
  (file-name-as-directory
   (expand-file-name
    "emacs-hypervisor"
    (emacs-hypervisor--xdg-config-home))))

(defun emacs-hypervisor--config-file ()
  (if (boundp 'emacs-hypervisor-config-file)
      emacs-hypervisor-config-file
    (expand-file-name "config.el" (emacs-hypervisor--config-directory))))

(defun emacs-hypervisor--config-org-file ()
  (if (boundp 'emacs-hypervisor-config-org-file)
      emacs-hypervisor-config-org-file
    (expand-file-name "config.org" (emacs-hypervisor--config-directory))))

(defun emacs-hypervisor--config-tangled-file ()
  "Return the shadow file path for tangled config.org output."
  (let ((org-file (emacs-hypervisor--config-org-file)))
    (when org-file
      (expand-file-name ".config.tangled.el"
                        (file-name-directory org-file)))))

(defun emacs-hypervisor--env-file ()
  (if (boundp 'emacs-hypervisor-env-file)
      emacs-hypervisor-env-file
    (emacs-hypervisor--repo-file "env")))

(provide 'emacs-hypervisor-config-paths)
