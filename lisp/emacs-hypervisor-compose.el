;;; emacs-hypervisor-compose.el --- Soft reload helpers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-bootstrap)
(require 'emacs-hypervisor-declarations)

(defvar emacs-hypervisor-last-soft-reload-report nil
  "Report plist from the last soft reload.")

(defun emacs-hypervisor--repo-file (name)
  (expand-file-name name user-emacs-directory))

(defun emacs-hypervisor--config-file ()
  (if (boundp 'emacs-hypervisor-config-file)
      emacs-hypervisor-config-file
    (emacs-hypervisor--repo-file "config.el")))

(defun emacs-hypervisor--config-org-file ()
  (if (boundp 'emacs-hypervisor-config-org-file)
      emacs-hypervisor-config-org-file
    (emacs-hypervisor--repo-file "config.org")))

(defun emacs-hypervisor--env-file ()
  (if (boundp 'emacs-hypervisor-env-file)
      emacs-hypervisor-env-file
    (emacs-hypervisor--repo-file "env")))

(defun emacs-hypervisor--declared-package-names ()
  (mapcar (lambda (entry) (plist-get entry :name))
          (emacs-hypervisor-export-packages)))

(defun emacs-hypervisor--unit-name (entry)
  (plist-get entry :name))

(defun emacs-hypervisor--unit-entry (name units)
  (cl-find name units
           :key #'emacs-hypervisor--unit-name
           :test #'equal))

(defun emacs-hypervisor--unit-requires (entry)
  (copy-sequence (plist-get entry :requires)))

(defun emacs-hypervisor--unit-after (entry)
  (copy-sequence (plist-get entry :after)))

(defun emacs-hypervisor--unit-env (entry)
  (copy-sequence (plist-get entry :env)))

(defun emacs-hypervisor--unit-executable (entry)
  (copy-sequence (plist-get entry :executable)))

(defun emacs-hypervisor--unit-body (entry)
  (plist-get entry :body))

(defun emacs-hypervisor--missing-env (entry)
  (cl-loop for name in (emacs-hypervisor--unit-env entry)
           unless (getenv name)
           collect name))

(defun emacs-hypervisor--missing-executables (entry)
  (cl-loop for name in (emacs-hypervisor--unit-executable entry)
           unless (executable-find name)
           collect name))

(defun emacs-hypervisor--missing-features (entry)
  (cl-loop for feature-name in (emacs-hypervisor--unit-requires entry)
           unless (require (intern feature-name) nil t)
           collect feature-name))

(defun emacs-hypervisor--make-soft-reload-report (name status reason &optional details)
  (list :name name
        :status status
        :reason reason
        :details details))

(defun emacs-hypervisor--soft-reload-status (reports name)
  (plist-get (gethash name reports) :status))

(defun emacs-hypervisor--soft-reload-run-unit (entry pending-packages)
  (let* ((name (emacs-hypervisor--unit-name entry))
         (pending-package-deps
          (cl-intersection
           (emacs-hypervisor--unit-requires entry)
           pending-packages
           :test #'equal))
         (missing-env (emacs-hypervisor--missing-env entry))
         (missing-executables (emacs-hypervisor--missing-executables entry))
         (missing-features (emacs-hypervisor--missing-features entry)))
    (cond
     (pending-package-deps
      (emacs-hypervisor--make-soft-reload-report
       name :skipped :pending-package-sync pending-package-deps))
     (missing-env
      (emacs-hypervisor--make-soft-reload-report
       name :skipped :preflight
       (list :env missing-env :executable nil)))
     (missing-executables
      (emacs-hypervisor--make-soft-reload-report
       name :skipped :preflight
       (list :env nil :executable missing-executables)))
     (missing-features
      (emacs-hypervisor--make-soft-reload-report
       name :skipped :missing-required-features
       missing-features))
     (t
      (condition-case err
          (progn
            (eval (read (emacs-hypervisor--unit-body entry)))
            (emacs-hypervisor--make-soft-reload-report
             name :ok :reloaded
             (list :requires (emacs-hypervisor--unit-requires entry)
                   :after (emacs-hypervisor--unit-after entry))))
        (error
         (emacs-hypervisor--make-soft-reload-report
          name :failed :execution (format "%S" err))))))))

(defun emacs-hypervisor--soft-reload-unit-reports (units pending-packages)
  (let* ((known-unit-names (mapcar #'emacs-hypervisor--unit-name units))
         (reports (make-hash-table :test #'equal))
         pending
         progress)
    (dolist (entry units)
      (let* ((name (emacs-hypervisor--unit-name entry))
             (missing-after
              (cl-set-difference
               (emacs-hypervisor--unit-after entry)
               known-unit-names
               :test #'equal)))
        (if missing-after
            (puthash
             name
             (emacs-hypervisor--make-soft-reload-report
              name :skipped :missing-after-units missing-after)
             reports)
          (push entry pending))))
    (setq pending (nreverse pending))
    (while pending
      (setq progress nil)
      (let (next-pending)
        (dolist (entry pending)
          (let* ((name (emacs-hypervisor--unit-name entry))
                 (after (emacs-hypervisor--unit-after entry))
                 (unresolved
                  (cl-remove-if
                   (lambda (dep) (gethash dep reports))
                   after))
                 (blocked
                  (cl-loop for dep in after
                           unless (eq (emacs-hypervisor--soft-reload-status reports dep) :ok)
                           when (gethash dep reports)
                           collect dep)))
            (cond
             (unresolved
              (push entry next-pending))
             (blocked
              (setq progress t)
              (puthash
               name
               (emacs-hypervisor--make-soft-reload-report
                name :skipped :blocked-by-unit blocked)
               reports))
             (t
             (setq progress t)
              (puthash name
                       (emacs-hypervisor--soft-reload-run-unit
                        entry
                        pending-packages)
                       reports)))))
        (setq pending (nreverse next-pending)))
      (unless progress
        (dolist (entry pending)
          (let ((name (emacs-hypervisor--unit-name entry)))
            (puthash
             name
             (emacs-hypervisor--make-soft-reload-report
              name :skipped :cycle (emacs-hypervisor--unit-after entry))
             reports)))
        (setq pending nil)))
    (mapcar (lambda (entry)
              (gethash (emacs-hypervisor--unit-name entry) reports))
            units)))

(defun emacs-hypervisor--soft-reload-summary (reports)
  (list
   :ok (cl-count :ok reports :key (lambda (entry) (plist-get entry :status)))
   :skipped (cl-count :skipped reports :key (lambda (entry) (plist-get entry :status)))
   :failed (cl-count :failed reports :key (lambda (entry) (plist-get entry :status)))))

(defun emacs-hypervisor--soft-reload-warning (new-packages reports)
  (let ((skipped-units
         (cl-loop for entry in reports
                  when (eq (plist-get entry :reason) :pending-package-sync)
                  collect (plist-get entry :name))))
    (string-join
     (delq
      nil
      (list
       (format "Soft reload: new packages %s"
               (string-join new-packages ", "))
       (when skipped-units
         (format "Skipped: %s"
                 (string-join skipped-units ", ")))
       "Apply on next Emacs start."))
     "\n")))

(defun emacs-hypervisor-tangle-config ()
  "Tangle repo-root config.org into config.el."
  (interactive)
  (let ((config-org-file (emacs-hypervisor--config-org-file)))
    (unless (file-exists-p config-org-file)
      (user-error "No config.org at %s" config-org-file))
    (require 'ob-tangle)
    (org-babel-tangle-file config-org-file)))

(defun emacs-hypervisor-reload-config ()
  "Soft reload config units on top of the current Emacs state.

This command reloads declarations from `config.el', warns about new package
declarations, and reruns config units only. It does not unload old config,
hooks, advice, themes, or package state."
  (interactive)
  (when (emacs-hypervisor-live-p)
    (user-error "Hypervisor session is still running"))
  (let* ((config-file (emacs-hypervisor--config-file))
         (previous-packages (emacs-hypervisor--declared-package-names)))
    (unless (file-exists-p config-file)
      (error "No config.el at %s" config-file))
    (emacs-hypervisor-load-envvars-file (emacs-hypervisor--env-file) t)
    (emacs-hypervisor-reset-declarations)
    (load-file config-file)
    (let* ((new-packages
            (cl-set-difference
             (emacs-hypervisor--declared-package-names)
             previous-packages
             :test #'equal))
           (reports
            (emacs-hypervisor--soft-reload-unit-reports
             (emacs-hypervisor-export-config-units)
             new-packages))
           (summary (emacs-hypervisor--soft-reload-summary reports)))
      (setq emacs-hypervisor-last-soft-reload-report
            (list
             :kind :soft-reload
             :new-packages new-packages
             :reports reports
             :summary summary
             :note "Soft reload reruns config on top of current Emacs state; old config is not unloaded."))
      (message
       "[Hypervisor] Soft reload: %d ok, %d skipped, %d failed. Existing Emacs state was not unloaded."
       (plist-get summary :ok)
       (plist-get summary :skipped)
       (plist-get summary :failed))
      (when new-packages
        (display-warning
         'emacs-hypervisor
         (emacs-hypervisor--soft-reload-warning new-packages reports)
         :warning))
      emacs-hypervisor-last-soft-reload-report)))

(provide 'emacs-hypervisor-compose)
