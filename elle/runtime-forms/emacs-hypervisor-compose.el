;;; emacs-hypervisor-compose.el --- Config reload command wiring -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-bootstrap)
(require 'emacs-hypervisor-config-loader)
(require 'emacs-hypervisor-declarations)
(require 'emacs-hypervisor-reload-policy)
(require 'emacs-hypervisor-reload-report)
(require 'emacs-hypervisor-selective-reload)

(defvar emacs-hypervisor-last-soft-reload-report nil
  "Report plist from the last config reload.")

(defun emacs-hypervisor-reload-config ()
  "Reload changed config units into the current Emacs state.

If `config.org' exists, it is tangled to a shadow file before loading.
This command reloads declarations, warns about new package declarations,
skips unchanged config units, and cleans up recognized effects from
previous changed or removed units before applying new bodies."
  (interactive)
  (when (emacs-hypervisor-session-active-p)
    (user-error "Hypervisor session is still active"))
  (let ((emacs-hypervisor--reload-logging-active t))
    (emacs-hypervisor--reload-log "Reload started")
    (let* ((config-file (emacs-hypervisor--config-file))
           (config-org-file (emacs-hypervisor--config-org-file))
           (use-org (and config-org-file (file-exists-p config-org-file)))
           (previous-packages (emacs-hypervisor--declared-package-names))
           (previous-units (emacs-hypervisor-export-config-units)))
      (when use-org
        (setq config-file
              (emacs-hypervisor-config-loader-prepare-load-target
               config-file
               config-org-file)))
      (unless (file-exists-p config-file)
        (error "No config file found at %s"
               (if use-org config-org-file config-file)))
      (emacs-hypervisor-load-envvars-file (emacs-hypervisor--env-file) t)
      (emacs-hypervisor-reset-declarations)
      (load-file config-file)
      (let* ((new-packages
              (cl-set-difference
               (emacs-hypervisor--declared-package-names)
               previous-packages
               :test #'equal))
             (current-units (emacs-hypervisor-export-config-units))
             (diffs
              (emacs-hypervisor-selective-reload-diff-units
               previous-units
               current-units))
             (reports
              (emacs-hypervisor--reload-unit-reports
               diffs
               new-packages))
             (summary (emacs-hypervisor--reload-summary reports)))
        (setq emacs-hypervisor-last-soft-reload-report
              (list
               :kind :config-reload
               :new-packages new-packages
               :reports reports
               :summary summary
               :note "Selective reload applies only new and changed config units. Effect-aware reload cleans recognized previous effects before replacement; opaque effects are reported but not reset."))
        (emacs-hypervisor--reload-log
         "Reload: %d changed applied, %d unchanged skipped, %d old effects cleaned."
         (plist-get summary :applied)
         (plist-get summary :skipped-unchanged)
         (plist-get summary :cleaned))
        (when new-packages
          (display-warning
           'emacs-hypervisor
           (emacs-hypervisor--reload-warning new-packages reports)
           :warning))
        emacs-hypervisor-last-soft-reload-report))))

(provide 'emacs-hypervisor-compose)
