;;; emacs-hypervisor-config-paths.el --- Config path resolution -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolve the paths Hypervisor uses at startup and reload: the user-owned
;; Hypervisor config directory, the active `config.el' / `config.org' /
;; tangled-shadow files, and the env snapshot file.  User-facing variables
;; `emacs-hypervisor-config-file', `emacs-hypervisor-config-org-file', and
;; `emacs-hypervisor-env-file' (declared in `home-startup.el') override the
;; defaults when bound.
;;
;; `emacs-hypervisor-config-org-file' holds either one path or an ordered
;; list of paths.  A list lets a large literate config live in several files
;; without an org `#+INCLUDE' step; the files are tangled in list order and
;; their blocks are concatenated into one shadow file.  Hypervisor has no
;; opinion on how the list is split or what the files are called.

(require 'seq)

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

(defun emacs-hypervisor--config-org-files ()
  "Return the configured literate config sources as an ordered list.

`emacs-hypervisor-config-org-file' may hold one path or a list of paths.
List order is tangle order, and therefore config load order, so it is the
user's explicit declaration rather than a directory scan."
  (let ((configured
         (if (boundp 'emacs-hypervisor-config-org-file)
             emacs-hypervisor-config-org-file
           (expand-file-name "config.org"
                             (emacs-hypervisor--config-directory)))))
    (cond
     ((null configured) nil)
     ((stringp configured) (list configured))
     ((consp configured)
      (unless (seq-every-p #'stringp configured)
        (error "`emacs-hypervisor-config-org-file' list must hold paths: %S"
               configured))
      (copy-sequence configured))
     (t
      (error "`emacs-hypervisor-config-org-file' must be a path or list: %S"
             configured)))))

(defun emacs-hypervisor--existing-config-org-files ()
  "Return the configured literate config sources that exist on disk."
  (seq-filter #'file-exists-p (emacs-hypervisor--config-org-files)))

(defun emacs-hypervisor--config-org-file ()
  "Return one representative literate config source, or nil.

This is the first configured source.  It names the config in boot context
and load-failure messages; anything that tangles must use
`emacs-hypervisor--config-org-files' so a multi-file config is not
silently truncated to its first file."
  (car (emacs-hypervisor--config-org-files)))

(defun emacs-hypervisor--config-tangled-file ()
  "Return the shadow file path for tangled literate config output.

Anchored on the Hypervisor config directory, not on a source file's
directory.  The shadow is the tangled whole config, so its directory is
what the config sees as `load-file-name' and `default-directory' while it
loads.  That has to be the config root: a config that keeps its sources in
a subdirectory still resolves its own relative paths, such as a `lisp/'
directory, against the root."
  (expand-file-name ".config.tangled.el"
                    (emacs-hypervisor--config-directory)))

(defun emacs-hypervisor--env-file ()
  (if (boundp 'emacs-hypervisor-env-file)
      emacs-hypervisor-env-file
    (emacs-hypervisor--repo-file "env")))

(provide 'emacs-hypervisor-config-paths)
