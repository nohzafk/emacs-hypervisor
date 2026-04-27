;;; emacs-hypervisor-compose.el --- Config reload command wiring -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-hypervisor-bootstrap)
(require 'emacs-hypervisor-declarations)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-selective-reload)

(defvar emacs-hypervisor-last-soft-reload-report nil
  "Report plist from the last config reload.")

(defconst emacs-hypervisor--config-org-elisp-lang-regexp
  (rx string-start (or "elisp" "emacs-lisp") string-end)
  "Org Babel language tags accepted for Emacs Lisp config blocks.")

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

(defun emacs-hypervisor--make-reload-report
    (name status reason &optional details action cleanup)
  (list :name name
        :status status
        :reason reason
        :action action
        :cleanup cleanup
        :details details))

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
    (cond
     (pending-package-deps
      (emacs-hypervisor--make-reload-report
       name :skipped :pending-package-sync pending-package-deps action nil))
     (missing-env
      (emacs-hypervisor--make-reload-report
       name :skipped :preflight
       (list :env missing-env :executable nil) action nil))
     (missing-executables
      (emacs-hypervisor--make-reload-report
       name :skipped :preflight
       (list :env nil :executable missing-executables) action nil))
     (missing-features
      (emacs-hypervisor--make-reload-report
       name :skipped :missing-required-features
       missing-features action nil))
     (t
      (let ((cleanup (and previous-entry
                          (emacs-hypervisor-effect-aware-reload-cleanup-unit
                           name
                           previous-entry))))
        (if (plist-get cleanup :failed)
            (emacs-hypervisor--make-reload-report
             name :failed :cleanup
             (plist-get cleanup :failed)
             action
             cleanup)
          (condition-case err
              (progn
                (eval (emacs-hypervisor--unit-body entry) t)
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
              cleanup)))))))))

(defun emacs-hypervisor--removed-unit-report (diff)
  (let* ((name (plist-get diff :name))
         (previous (plist-get diff :previous))
         (cleanup (emacs-hypervisor-effect-aware-reload-cleanup-unit name previous)))
    (if (plist-get cleanup :failed)
        (emacs-hypervisor--make-reload-report
         name :failed :cleanup
         (plist-get cleanup :failed)
         :removed
         cleanup)
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

(defun emacs-hypervisor--reload-summary (reports)
  (list
   :applied
   (cl-count-if
    (lambda (entry)
      (and (eq (plist-get entry :status) :ok)
           (memq (plist-get entry :action) '(:new :changed))))
    reports)
   :removed
   (cl-count-if
    (lambda (entry)
      (and (eq (plist-get entry :status) :ok)
           (eq (plist-get entry :action) :removed)))
    reports)
   :skipped-unchanged
   (cl-count-if
    (lambda (entry)
      (and (eq (plist-get entry :status) :skipped)
           (eq (plist-get entry :action) :unchanged)))
    reports)
   :cleaned
   (cl-loop for entry in reports
            sum (emacs-hypervisor-effect-aware-reload-cleanup-count
                 (plist-get entry :cleanup)))
   :failed
   (cl-count :failed reports :key (lambda (entry) (plist-get entry :status)))))

(defun emacs-hypervisor--reload-warning (new-packages reports)
  (let ((skipped-units
         (cl-loop for entry in reports
                  when (eq (plist-get entry :reason) :pending-package-sync)
                  collect (plist-get entry :name))))
    (string-join
     (delq
      nil
      (list
       (format "Reload: new packages %s"
               (string-join new-packages ", "))
       (when skipped-units
         (format "Skipped: %s"
                 (string-join skipped-units ", ")))
       "Apply on next Emacs start."))
     "\n")))

(defun emacs-hypervisor-tangle-config ()
  "Tangle repo-root config.org into the shadow tangled file."
  (interactive)
  (let ((config-org-file (emacs-hypervisor--config-org-file))
        (tangled-file (emacs-hypervisor--config-tangled-file)))
    (unless (and config-org-file (file-exists-p config-org-file))
      (user-error "No config.org at %s" config-org-file))
    (require 'ob-tangle)
    (org-babel-tangle-file
     config-org-file tangled-file
     emacs-hypervisor--config-org-elisp-lang-regexp)))

(defun emacs-hypervisor-reload-config ()
  "Reload changed config units into the current Emacs state.

If `config.org' exists, it is tangled to a shadow file before loading.
This command reloads declarations, warns about new package declarations,
skips unchanged config units, and cleans up recognized effects from
previous changed or removed units before applying new bodies."
  (interactive)
  (when (emacs-hypervisor-session-active-p)
    (user-error "Hypervisor session is still active"))
  (let* ((config-file (emacs-hypervisor--config-file))
         (config-org-file (emacs-hypervisor--config-org-file))
         (use-org (and config-org-file (file-exists-p config-org-file)))
         (previous-packages (emacs-hypervisor--declared-package-names))
         (previous-units (emacs-hypervisor-export-config-units)))
    (when use-org
      (require 'ob-tangle)
      (let ((tangled-file (emacs-hypervisor--config-tangled-file)))
        (org-babel-tangle-file
         config-org-file tangled-file
         emacs-hypervisor--config-org-elisp-lang-regexp)
        (setq config-file tangled-file)))
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
             :note "Selective reload applies only new and changed config units. Effect-aware reload cleans recognized previous hook and advice effects before replacement; opaque effects are reported but not reset."))
      (message
       "[Hypervisor] Reload: %d changed applied, %d unchanged skipped, %d old effects cleaned."
       (plist-get summary :applied)
       (plist-get summary :skipped-unchanged)
       (plist-get summary :cleaned))
      (when new-packages
        (display-warning
         'emacs-hypervisor
         (emacs-hypervisor--reload-warning new-packages reports)
         :warning))
      emacs-hypervisor-last-soft-reload-report)))

(provide 'emacs-hypervisor-compose)
