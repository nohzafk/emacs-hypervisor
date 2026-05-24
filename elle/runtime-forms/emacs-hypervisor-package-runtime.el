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

(defun emacs-hypervisor-runtime--package-entries (entries-or-names)
  (mapcar #'emacs-hypervisor-runtime--package-entry entries-or-names))

(defun emacs-hypervisor-runtime--package-name (entry)
  (plist-get entry :name))

(defun emacs-hypervisor-runtime--package-entry-in (name entries)
  (cl-find name entries
           :key #'emacs-hypervisor-runtime--package-name
           :test #'equal))

(defun emacs-hypervisor-runtime--package-result (entry status &optional error)
  (append
   (list :name (emacs-hypervisor-runtime--package-name entry)
         :status status)
   (when (plist-get entry :deps)
     (list :deps (copy-sequence (plist-get entry :deps))))
   (when error
     (list :error error))))

(defun emacs-hypervisor-runtime--known-package-names ()
  (mapcar #'emacs-hypervisor-runtime--package-name emacs-hypervisor-packages))

(defun emacs-hypervisor-runtime--package-installed-entry-p (entry)
  (and (fboundp 'emacs-hypervisor--package-installed-p)
       (emacs-hypervisor--package-installed-p entry)))

(defun emacs-hypervisor-runtime--missing-package-deps-p (entry known-names)
  (cl-some (lambda (dep) (not (member dep known-names)))
           (plist-get entry :deps)))

(defun emacs-hypervisor-runtime--declared-package-plan ()
  "Return declared package entries in dependency order for installation.

This mirrors the host-side package plan closely enough for the Emacs runtime
entry point that does not receive a serialized package-name list."
  (let* ((entries (copy-sequence emacs-hypervisor-packages))
         (known-names (emacs-hypervisor-runtime--known-package-names))
         (ready-names nil)
         (remaining nil)
         (ordered nil))
    (dolist (entry entries)
      (if (emacs-hypervisor-runtime--package-installed-entry-p entry)
          (push (emacs-hypervisor-runtime--package-name entry) ready-names)
        (unless (emacs-hypervisor-runtime--missing-package-deps-p entry known-names)
          (push entry remaining))))
    (setq remaining (nreverse remaining))
    (while remaining
      (let ((next
             (cl-find-if
              (lambda (entry)
                (cl-every (lambda (dep) (member dep ready-names))
                          (plist-get entry :deps)))
              remaining)))
        (if (not next)
            (setq remaining nil)
          (push next ordered)
          (push (emacs-hypervisor-runtime--package-name next) ready-names)
          (setq remaining (delq next remaining)))))
    (nreverse ordered)))

(defun emacs-hypervisor-runtime-install-declared-package-batch ()
  "Install declared packages using the Emacs-side declaration registry."
  (emacs-hypervisor-runtime-install-package-batch
   (emacs-hypervisor-runtime--declared-package-plan)))

(defun emacs-hypervisor-runtime-notify-packages-finished (&optional reason)
  (when emacs-hypervisor-runtime-packages-installation-active
    (unless emacs-hypervisor-runtime-packages-finished-sent
      (setq emacs-hypervisor-runtime-packages-finished-sent t)
      (setq emacs-hypervisor-runtime-packages-installation-active nil)
      (emacs-hypervisor-runtime-packages-finished reason))))

(defun emacs-hypervisor-runtime-install-package-batch (entries-or-names)
  "Install ENTRIES-OR-NAMES synchronously via the package bridge.
Emits per-package :installed/:failed events and a terminal :finished event.
Returns a list of (:name NAME :status STATUS [:error REASON]) plists."
  (emacs-hypervisor-runtime-begin-package-installation)
  (let ((results nil)
        (entries (emacs-hypervisor-runtime--package-entries entries-or-names))
        failure-reason)
    (condition-case err
        (progn
          (emacs-hypervisor-bridge-install-batch
           entries
           (lambda (name)
             (push
              (emacs-hypervisor-runtime--package-result
               (emacs-hypervisor-runtime--package-entry-in name entries)
               :installed)
              results)
             (emacs-hypervisor-runtime-package-installed name))
           (lambda (name reason)
             (unless failure-reason
               (setq failure-reason reason))
             (push
              (emacs-hypervisor-runtime--package-result
               (emacs-hypervisor-runtime--package-entry-in name entries)
               :failed
               reason)
              results)
             (emacs-hypervisor-runtime-package-failed name reason)))
          (emacs-hypervisor-runtime-notify-packages-finished "completed"))
      (error
       (let ((reason (format "%S" err)))
         (setq failure-reason reason)
         (dolist (entry entries)
           (push
            (emacs-hypervisor-runtime--package-result entry :failed reason)
            results))
         (emacs-hypervisor-runtime-notify-packages-finished reason))))
    (if failure-reason
        (error "%s" failure-reason)
      (nreverse results))))

(setq emacs-hypervisor-runtime-packages-installation-active nil)
(setq emacs-hypervisor-runtime-packages-finished-sent nil)

(provide 'emacs-hypervisor-package-runtime)
