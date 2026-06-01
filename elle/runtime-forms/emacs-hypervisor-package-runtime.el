;;; emacs-hypervisor-package-runtime.el --- Package runtime helpers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-declarations)

(defvar emacs-hypervisor-runtime-packages-installation-active nil)
(defvar emacs-hypervisor-runtime-packages-finished-sent nil)

(defun emacs-hypervisor-runtime-note-package-event (kind &optional name reason)
  (when (fboundp 'emacs-hypervisor-report-note-package-event)
    (emacs-hypervisor-report-note-package-event kind name reason)))

(defun emacs-hypervisor-runtime-send-package-installed (name)
  (emacs-hypervisor-send-event
   :package
   (list :phase :packages :kind :installed :name name)))

(defun emacs-hypervisor-runtime-send-package-failed (name reason)
  (emacs-hypervisor-send-event
   :package
   (list :phase :packages :kind :failed :name name :reason reason)))

(defun emacs-hypervisor-runtime-send-packages-finished (&optional reason)
  (emacs-hypervisor-send-event
   :package
   (append
    '(:phase :packages :kind :finished)
    (when reason (list :reason reason)))))

(defun emacs-hypervisor-runtime-package-installed (name)
  (unless (member name emacs-hypervisor-installed-packages)
    (push name emacs-hypervisor-installed-packages))
  (push (list :phase :packages :event :installed :name name)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-note-package-event :installed name)
  (emacs-hypervisor-runtime-send-package-installed name))

(defun emacs-hypervisor-runtime-package-failed (name reason)
  (push (list :phase :packages :event :failed :name name :reason reason)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-note-package-event :failed name reason)
  (emacs-hypervisor-runtime-send-package-failed name reason))

(defun emacs-hypervisor-runtime-packages-finished (&optional reason)
  (push (list :phase :packages :event :finished :reason reason)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-note-package-event :finished nil reason)
  (emacs-hypervisor-runtime-send-packages-finished reason))

(defun emacs-hypervisor-runtime-begin-package-installation ()
  (setq emacs-hypervisor-runtime-packages-installation-active t)
  (setq emacs-hypervisor-runtime-packages-finished-sent nil)
  (emacs-hypervisor-runtime-note-package-event :begin))

(defun emacs-hypervisor-runtime--package-entry (entry-or-name)
  (cond
   ((and (listp entry-or-name)
         (plist-get entry-or-name :name))
    entry-or-name)
   ((stringp entry-or-name)
    (or (cl-find entry-or-name emacs-hypervisor-packages
                 :key (lambda (entry) (plist-get entry :name))
                 :test #'equal)
        (error "Unknown package declaration: %s" entry-or-name)))
   (t
    (error "Invalid package declaration reference: %S" entry-or-name))))

(defun emacs-hypervisor-runtime-notify-packages-finished (&optional reason)
  (when emacs-hypervisor-runtime-packages-installation-active
    (unless emacs-hypervisor-runtime-packages-finished-sent
      (setq emacs-hypervisor-runtime-packages-finished-sent t)
      (setq emacs-hypervisor-runtime-packages-installation-active nil)
      (emacs-hypervisor-runtime-packages-finished reason))))

(defun emacs-hypervisor-runtime-run-package (name)
  "Install the single declared package NAME via the bridge.
Emits the same per-package :installed/:failed events as the batch path, but
without the phase :begin/:finished bracket -- the host sends those once around
the per-package loop (see `emacs-hypervisor-runtime-begin-package-installation'
and `emacs-hypervisor-runtime-notify-packages-finished').  Signals on failure
so the host derives the report from the eval response.  Returns NAME on
success.  This mirrors `emacs-hypervisor-runtime-run-unit' so that each package
is one eval round-trip, letting Emacs repaint the report between packages."
  (let ((entry (emacs-hypervisor-runtime--package-entry name))
        failure-reason)
    (emacs-hypervisor-bridge-install-batch
     (list entry)
     (lambda (installed-name)
       (emacs-hypervisor-runtime-package-installed installed-name))
     (lambda (failed-name reason)
       (unless failure-reason (setq failure-reason reason))
       (emacs-hypervisor-runtime-package-failed failed-name reason)))
    (when failure-reason
      (error "%s" failure-reason))
    name))

(defun emacs-hypervisor-runtime-rebuild-package (name)
  "Force a clean rebuild of package NAME via the bridge.
Drops cached staging and package directories, purges lisp state, and reinstall.
Signals on failure so the host derives the report from the eval response."
  (let ((entry (emacs-hypervisor-runtime--package-entry name))
        failure-reason)
    (emacs-hypervisor-bridge-rebuild
     entry
     (lambda (installed-name)
       (emacs-hypervisor-runtime-package-installed installed-name))
     (lambda (failed-name reason)
       (unless failure-reason (setq failure-reason reason))
       (emacs-hypervisor-runtime-package-failed failed-name reason)))
    (when failure-reason
      (error "%s" failure-reason))
    name))

(defun emacs-hypervisor-rebuild-package (name)
  "Force a clean rebuild of package NAME.
Provides interactive completion for all declared packages."
  (interactive
   (list (completing-read "Rebuild package: "
                          (mapcar (lambda (e) (plist-get e :name))
                                  emacs-hypervisor-packages))))
  (let ((entry (emacs-hypervisor-runtime--package-entry name)))
    (message "Rebuilding package %s..." name)
    (emacs-hypervisor-bridge-rebuild
     entry
     (lambda (installed-name)
       (message "Package %s rebuilt successfully." installed-name))
     (lambda (failed-name reason)
       (error "Package %s rebuild failed: %s" failed-name reason)))))

(setq emacs-hypervisor-runtime-packages-installation-active nil)
(setq emacs-hypervisor-runtime-packages-finished-sent nil)

(provide 'emacs-hypervisor-package-runtime)

