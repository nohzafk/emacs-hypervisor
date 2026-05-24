;;; emacs-hypervisor-reload-policy.el --- Live reload policy -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-declarations)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-reload-report)
(require 'emacs-hypervisor-selective-reload)

(defun emacs-hypervisor--declared-package-names ()
  (mapcar (lambda (entry) (plist-get entry :name))
          (emacs-hypervisor-export-packages)))

(defun emacs-hypervisor--unit-name (entry)
  (plist-get entry :name))

(defun emacs-hypervisor--unit-requires (entry)
  (copy-sequence (plist-get entry :requires)))

(defun emacs-hypervisor--unit-after (entry)
  (copy-sequence (plist-get entry :after)))

(defun emacs-hypervisor--unit-env (entry)
  (copy-sequence (plist-get entry :env)))

(defun emacs-hypervisor--unit-executable (entry)
  (copy-sequence (plist-get entry :executable)))

(defun emacs-hypervisor--unit-body (entry)
  (plist-get
   (emacs-hypervisor-effect-aware-reload-normalize-entry entry)
   :body))

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

(defun emacs-hypervisor--reload-action-verb (action)
  (pcase action
    (:new "applied new")
    (:changed "re-applied")
    (_ "applied")))

(defun emacs-hypervisor--reload-run-current-unit
    (entry pending-packages &optional action previous-entry)
  (let* ((name (emacs-hypervisor--unit-name entry))
         (pending-package-deps
          (cl-intersection
           (emacs-hypervisor--unit-requires entry)
           pending-packages
           :test #'equal))
         (missing-env (emacs-hypervisor--missing-env entry))
         (missing-executables (emacs-hypervisor--missing-executables entry))
         (missing-features (emacs-hypervisor--missing-features entry)))
    (cl-flet ((skipped (reason details)
                (emacs-hypervisor--make-reload-report
                 name :skipped reason details action nil)))
      (cond
       (pending-package-deps
        (skipped :pending-package-sync pending-package-deps))
       (missing-env
        (skipped :preflight (list :env missing-env :executable nil)))
       (missing-executables
        (skipped :preflight (list :env nil :executable missing-executables)))
       (missing-features
        (skipped :missing-required-features missing-features))
       (t
        (let ((cleanup (and previous-entry
                            (emacs-hypervisor-effect-aware-reload-cleanup-unit
                             name
                             previous-entry))))
          (emacs-hypervisor--reload-log-cleanup name cleanup)
          (if (plist-get cleanup :failed)
              (emacs-hypervisor--make-reload-report
               name :failed :cleanup
               (plist-get cleanup :failed)
               action
               cleanup)
            (condition-case err
                (progn
                  (eval (emacs-hypervisor--unit-body entry) t)
                  (emacs-hypervisor--reload-log
                   "Reload %s unit: %s"
                   (emacs-hypervisor--reload-action-verb action)
                   name)
                  (emacs-hypervisor--make-reload-report
                   name :ok :applied
                   (list :requires (emacs-hypervisor--unit-requires entry)
                         :after (emacs-hypervisor--unit-after entry))
                   action
                   cleanup))
              (error
               (emacs-hypervisor--make-reload-report
                name :failed :execution (format "%S" err)
                action
                cleanup))))))))))

(defun emacs-hypervisor--removed-unit-report (diff)
  (let* ((name (plist-get diff :name))
         (previous (plist-get diff :previous))
         (cleanup (emacs-hypervisor-effect-aware-reload-cleanup-unit name previous)))
    (emacs-hypervisor--reload-log-cleanup name cleanup)
    (if (plist-get cleanup :failed)
        (emacs-hypervisor--make-reload-report
         name :failed :cleanup
         (plist-get cleanup :failed)
         :removed
         cleanup)
      (emacs-hypervisor--reload-log "Reload removed unit: %s" name)
      (emacs-hypervisor--make-reload-report
       name :ok :removed
       nil
       :removed
       cleanup))))

(defun emacs-hypervisor--reload-unit-reports (diffs pending-packages)
  (emacs-hypervisor-selective-reload-reports
   diffs
   #'emacs-hypervisor--make-reload-report
   (lambda (diff)
     (let ((entry (plist-get diff :current)))
       (emacs-hypervisor--reload-run-current-unit
        entry
        pending-packages
        (emacs-hypervisor-selective-reload-diff-action diff)
        (plist-get diff :previous))))
   #'emacs-hypervisor--removed-unit-report))

(provide 'emacs-hypervisor-reload-policy)
