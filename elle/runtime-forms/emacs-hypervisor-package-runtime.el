;;; emacs-hypervisor-package-runtime.el --- Package runtime helpers -*- lexical-binding: t; -*-

(require 'cl-lib)

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

(defun emacs-hypervisor-runtime-notify-packages-finished (&optional reason)
  (when emacs-hypervisor-runtime-packages-installation-active
    (unless emacs-hypervisor-runtime-packages-finished-sent
      (setq emacs-hypervisor-runtime-packages-finished-sent t)
      (setq emacs-hypervisor-runtime-packages-installation-active nil)
      (emacs-hypervisor-runtime-packages-finished reason))))

(defun emacs-hypervisor-runtime-install-package-batch (entries)
  "Install ENTRIES synchronously via the package bridge.
Emits per-package :installed/:failed events and a terminal :finished event.
Returns a list of (:name NAME :status STATUS [:error REASON]) plists."
  (emacs-hypervisor-runtime-begin-package-installation)
  (let ((results nil))
    (condition-case err
        (progn
          (emacs-hypervisor-bridge-install-batch
           entries
           (lambda (name)
             (push (list :name name :status :installed) results)
             (emacs-hypervisor-runtime-package-installed name))
           (lambda (name reason)
             (push (list :name name :status :failed :error reason) results)
             (emacs-hypervisor-runtime-package-failed name reason)))
          (emacs-hypervisor-runtime-notify-packages-finished "completed"))
      (error
       (emacs-hypervisor-runtime-notify-packages-finished
        (format "%S" err))))
    (nreverse results)))

(setq emacs-hypervisor-runtime-packages-installation-active nil)
(setq emacs-hypervisor-runtime-packages-finished-sent nil)

(provide 'emacs-hypervisor-package-runtime)
