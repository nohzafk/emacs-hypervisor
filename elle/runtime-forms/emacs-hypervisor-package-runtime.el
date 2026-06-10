;;; emacs-hypervisor-package-runtime.el --- Package runtime helpers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-declarations)

(defvar emacs-hypervisor-runtime-packages-installation-active nil)
(defvar emacs-hypervisor-runtime-packages-finished-sent nil)

(defun emacs-hypervisor-runtime-note-package-event (kind &optional name reason)
  (when (fboundp 'emacs-hypervisor-report-note-package-event)
    (emacs-hypervisor-report-note-package-event kind name reason)))

(defun emacs-hypervisor-runtime--package-install-info (name)
  (and (boundp 'emacs-hypervisor-bridge-last-install-info)
       (cdr (assoc name emacs-hypervisor-bridge-last-install-info))))

(defun emacs-hypervisor-runtime-send-package-installed (name)
  (let ((info (emacs-hypervisor-runtime--package-install-info name)))
    (emacs-hypervisor-send-event
     :package
     (append
      (list :phase :packages :kind :installed :name name)
      (when (plist-get info :rev)
        (list :rev (plist-get info :rev)))
      (when (plist-get info :locked)
        (list :locked (plist-get info :locked)))))))

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

(defun emacs-hypervisor-runtime-note-orphaned-packages ()
  "Surface installed-but-undeclared packages in the startup report.
Never deletes anything; see `emacs-hypervisor-prune-packages'."
  (when (fboundp 'emacs-hypervisor-bridge-orphaned-packages)
    (let ((orphans (emacs-hypervisor-bridge-orphaned-packages
                    (mapcar (lambda (entry) (plist-get entry :name))
                            emacs-hypervisor-packages))))
      (when orphans
        (emacs-hypervisor-runtime-note-package-event
         :orphaned nil (string-join orphans ", "))
        (message
         "[Hypervisor] %d installed package%s not declared: %s (M-x emacs-hypervisor-prune-packages)"
         (length orphans)
         (if (cdr orphans) "s are" " is")
         (string-join orphans ", ")))
      orphans)))

(defun emacs-hypervisor-runtime-notify-packages-finished (&optional reason)
  (when emacs-hypervisor-runtime-packages-installation-active
    (unless emacs-hypervisor-runtime-packages-finished-sent
      (setq emacs-hypervisor-runtime-packages-finished-sent t)
      (setq emacs-hypervisor-runtime-packages-installation-active nil)
      (ignore-errors (emacs-hypervisor-runtime-note-orphaned-packages))
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
Provides interactive completion for all declared packages.
After reinstalling, re-requires the package feature and re-runs
any config unit that depends on it."
  (interactive
   (list (completing-read "Rebuild package: "
                          (mapcar (lambda (e) (plist-get e :name))
                                  emacs-hypervisor-packages))))
  (let ((entry (emacs-hypervisor-runtime--package-entry name)))
    (message "Rebuilding package %s..." name)
    (emacs-hypervisor-bridge-rebuild
     entry
     (lambda (installed-name)
       ;; Re-require the feature so new code takes effect immediately.
       (let ((feat (intern installed-name)))
         (require feat nil t))
       (message "Package %s rebuilt and reloaded." installed-name))
     (lambda (failed-name reason)
       (error "Package %s rebuild failed: %s" failed-name reason)))))

(defvar emacs-hypervisor-last-upgrade-report nil
  "List of (:name NAME :previous-rev R1 :current-rev R2 :status S) plists
from the most recent upgrade operation, most recent first.")

(defun emacs-hypervisor-runtime--upgrade-entry (entry)
  "Upgrade declared ENTRY, ignoring the lockfile.  Return a report plist.
A declared `:ref' or `:tag' pins the package; upgrade is then a no-op."
  (let* ((name (plist-get entry :name))
         (previous (plist-get (emacs-hypervisor-package-lock-entry name) :rev))
         report)
    (if (emacs-hypervisor-bridge--declared-pin entry)
        (progn
          (message "[Hypervisor] %s is pinned by declaration, skipped." name)
          (setq report (list :name name :status :pinned
                             :previous-rev previous :current-rev previous)))
      (unless (emacs-hypervisor-bridge--vc-entry-p entry)
        ;; Archive upgrade needs a fresh index to see newer versions.
        (package-refresh-contents))
      (let ((emacs-hypervisor-bridge-ignore-lock t)
            failure-reason)
        (emacs-hypervisor-bridge-rebuild
         entry
         (lambda (_installed-name))
         (lambda (_failed-name reason)
           (unless failure-reason (setq failure-reason reason))))
        (if failure-reason
            (setq report (list :name name :status :failed
                               :previous-rev previous
                               :reason failure-reason))
          (let ((current (plist-get
                          (emacs-hypervisor-package-lock-entry name) :rev)))
            (message "[Hypervisor] Upgraded %s: %s -> %s"
                     name (or previous "?") (or current "?"))
            (setq report (list :name name :status :ok
                               :previous-rev previous
                               :current-rev current))))))
    (push report emacs-hypervisor-last-upgrade-report)
    report))

(defun emacs-hypervisor-runtime-upgrade-package (name)
  "Upgrade declared package NAME during startup, driven by the host.
Signals on failure so the host derives the report from the eval response."
  (let ((report (emacs-hypervisor-runtime--upgrade-entry
                 (emacs-hypervisor-runtime--package-entry name))))
    (if (eq (plist-get report :status) :failed)
        (error "%s" (plist-get report :reason))
      (emacs-hypervisor-runtime-package-installed name))
    name))

(defun emacs-hypervisor-upgrade-package (name)
  "Upgrade package NAME to its declaration target, ignoring the lockfile.
Provides interactive completion for all declared packages."
  (interactive
   (list (completing-read "Upgrade package: "
                          (mapcar (lambda (e) (plist-get e :name))
                                  emacs-hypervisor-packages))))
  (let ((report (emacs-hypervisor-runtime--upgrade-entry
                 (emacs-hypervisor-runtime--package-entry name))))
    (when (eq (plist-get report :status) :failed)
      (error "Package %s upgrade failed: %s"
             name (plist-get report :reason)))
    report))

(defun emacs-hypervisor-upgrade-all-packages ()
  "Upgrade every declared package to its declaration target."
  (interactive)
  (setq emacs-hypervisor-last-upgrade-report nil)
  (let ((reports
         (mapcar (lambda (entry)
                   (emacs-hypervisor-runtime--upgrade-entry entry))
                 (emacs-hypervisor-export-packages))))
    (message "[Hypervisor] Upgrade finished: %d ok, %d pinned, %d failed."
             (cl-count :ok reports :key (lambda (r) (plist-get r :status)))
             (cl-count :pinned reports :key (lambda (r) (plist-get r :status)))
             (cl-count :failed reports :key (lambda (r) (plist-get r :status))))
    reports))

(defun emacs-hypervisor-prune-packages ()
  "Remove installed packages that are no longer declared.
The keep set includes the transitive Package-Requires closure of declared
packages, so archive dependencies are never pruned.  Asks for confirmation."
  (interactive)
  (let ((orphans (emacs-hypervisor-bridge-orphaned-packages
                  (mapcar (lambda (entry) (plist-get entry :name))
                          emacs-hypervisor-packages))))
    (if (null orphans)
        (message "[Hypervisor] No orphaned packages.")
      (when (yes-or-no-p
             (format "Prune %d orphaned package%s (%s)? "
                     (length orphans)
                     (if (cdr orphans) "s" "")
                     (string-join orphans ", ")))
        (dolist (name orphans)
          (emacs-hypervisor-bridge-remove-package name))
        (message "[Hypervisor] Pruned %d package%s."
                 (length orphans) (if (cdr orphans) "s" ""))))
    orphans))

(setq emacs-hypervisor-runtime-packages-installation-active nil)
(setq emacs-hypervisor-runtime-packages-finished-sent nil)

(provide 'emacs-hypervisor-package-runtime)

