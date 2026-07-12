;;; emacs-hypervisor-selective-reload.el --- Config unit selection -*- lexical-binding: t; -*-

(require 'cl-lib)

(defun emacs-hypervisor-selective-reload-unit-name (entry)
  (plist-get entry :name))

(defun emacs-hypervisor-selective-reload-unit-after (entry)
  (copy-sequence (plist-get entry :after)))

(defun emacs-hypervisor-selective-reload--strip-effect-source (form)
  "Return FORM with constructed `:source' keyword arguments replaced by nil.
Effect rewrites bake the unit's own source line into rewritten register
calls inside `:body' (see `emacs-hypervisor-effect-aware-reload'), so line
drift above a unit would otherwise change its identity.  The provenance
value appears as `(quote PLIST)' in freshly rewritten forms and as a
canonicalized `(list ...)' constructor in exported entries; both are
stripped.  The original FORM is never mutated; improper tails and non-cons
values pass through as-is."
  (cl-labels
      ((strip (node)
         (cond
          ((not (consp node)) node)
          ((and (eq (car node) :source)
                (consp (cdr node))
                (consp (cadr node))
                (memq (car (cadr node)) '(quote list)))
           (cons :source (cons nil (strip (cddr node)))))
          (t
           (cons (strip (car node)) (strip (cdr node)))))))
    (strip form)))

(defun emacs-hypervisor-selective-reload--identity-entry (entry)
  "Return ENTRY without the keys that never participate in unit identity.
`:source' is provenance: editing text above a unit shifts its line numbers
without changing the unit.  `:index' is declaration order bookkeeping.
Embedded effect `:source' provenance inside `:body' is stripped for the
same reason."
  (let (identity)
    (cl-loop for (key value) on entry by #'cddr
             unless (memq key '(:source :index))
             do (setq identity
                      (append identity
                              (list key
                                    (if (eq key :body)
                                        (emacs-hypervisor-selective-reload--strip-effect-source
                                         value)
                                      value)))))
    identity))

(defun emacs-hypervisor-selective-reload-unit-equal-p (previous current)
  (equal (emacs-hypervisor-selective-reload--identity-entry previous)
         (emacs-hypervisor-selective-reload--identity-entry current)))

(defun emacs-hypervisor-selective-reload--units-by-name (units)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry units table)
      (puthash (emacs-hypervisor-selective-reload-unit-name entry) entry table))))

(defun emacs-hypervisor-selective-reload-diff-units (previous-units current-units)
  (let ((previous-by-name
         (emacs-hypervisor-selective-reload--units-by-name previous-units))
        (current-by-name
         (emacs-hypervisor-selective-reload--units-by-name current-units))
        diffs)
    (dolist (previous previous-units)
      (let* ((name (emacs-hypervisor-selective-reload-unit-name previous))
             (current (gethash name current-by-name)))
        (unless current
          (push (list :name name
                      :action :removed
                      :previous previous
                      :current nil)
                diffs))))
    (dolist (current current-units)
      (let* ((name (emacs-hypervisor-selective-reload-unit-name current))
             (previous (gethash name previous-by-name))
             (action
              (cond
               ((null previous) :new)
               ((emacs-hypervisor-selective-reload-unit-equal-p previous current)
                :unchanged)
               (t :changed))))
        (push (list :name name
                    :action action
                    :previous previous
                    :current current)
              diffs)))
    (nreverse diffs)))

(defun emacs-hypervisor-selective-reload-diff-action (diff)
  (plist-get diff :action))

(defun emacs-hypervisor-selective-reload--report-satisfies-after-p (report)
  (or (eq (plist-get report :status) :ok)
      (eq (plist-get report :action) :unchanged)))

(defun emacs-hypervisor-selective-reload-reports
    (diffs make-report run-current remove-previous)
  (let* ((current-diffs
          (cl-remove-if
           (lambda (diff)
             (eq (emacs-hypervisor-selective-reload-diff-action diff) :removed))
           diffs))
         (current-units
          (mapcar (lambda (diff) (plist-get diff :current)) current-diffs))
         (known-unit-names
          (mapcar #'emacs-hypervisor-selective-reload-unit-name current-units))
         (reports (make-hash-table :test #'equal))
         removed-reports
         pending
         progress)
    (dolist (diff diffs)
      (pcase (emacs-hypervisor-selective-reload-diff-action diff)
        (:removed
         (let ((report (funcall remove-previous diff)))
           (push report removed-reports)
           (puthash (plist-get diff :name) report reports)))
        (:unchanged
         (puthash
          (plist-get diff :name)
          (funcall make-report
                   (plist-get diff :name)
                   :skipped
                   :unchanged
                   nil
                   :unchanged
                   nil)
          reports))))
    (dolist (diff current-diffs)
      (when (memq (emacs-hypervisor-selective-reload-diff-action diff)
                  '(:new :changed))
        (let* ((entry (plist-get diff :current))
               (name (emacs-hypervisor-selective-reload-unit-name entry))
               (missing-after
                (cl-set-difference
                 (emacs-hypervisor-selective-reload-unit-after entry)
                 known-unit-names
                 :test #'equal)))
          (if missing-after
              (puthash
               name
               (funcall make-report
                        name
                        :skipped
                        :missing-after-units
                        missing-after
                        (emacs-hypervisor-selective-reload-diff-action diff)
                        nil)
               reports)
            (push diff pending)))))
    (setq pending (nreverse pending))
    (while pending
      (setq progress nil)
      (let (next-pending)
        (dolist (diff pending)
          (let* ((entry (plist-get diff :current))
                 (name (emacs-hypervisor-selective-reload-unit-name entry))
                 (after (emacs-hypervisor-selective-reload-unit-after entry))
                 (unresolved
                  (cl-remove-if
                   (lambda (dep) (gethash dep reports))
                   after))
                 (blocked
                  (cl-loop for dep in after
                           for report = (gethash dep reports)
                           when (and report
                                     (not
                                      (emacs-hypervisor-selective-reload--report-satisfies-after-p
                                       report)))
                           collect dep)))
            (cond
             (unresolved
              (push diff next-pending))
             (blocked
              (setq progress t)
              (puthash
               name
               (funcall make-report
                        name
                        :skipped
                        :blocked-by-unit
                        blocked
                        (emacs-hypervisor-selective-reload-diff-action diff)
                        nil)
               reports))
             (t
              (setq progress t)
              (puthash name (funcall run-current diff) reports)))))
        (setq pending (nreverse next-pending)))
      (unless progress
        (dolist (diff pending)
          (let* ((entry (plist-get diff :current))
                 (name (emacs-hypervisor-selective-reload-unit-name entry)))
            (puthash
             name
             (funcall make-report
                      name
                      :skipped
                      :cycle
                      (emacs-hypervisor-selective-reload-unit-after entry)
                      (emacs-hypervisor-selective-reload-diff-action diff)
                      nil)
             reports)))
        (setq pending nil)))
    (append
     (nreverse removed-reports)
     (mapcar (lambda (diff)
               (gethash (plist-get diff :name) reports))
             current-diffs))))

(provide 'emacs-hypervisor-selective-reload)
