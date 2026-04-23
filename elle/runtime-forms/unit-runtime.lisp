## Emitted unit execution forms.

(defn emacs-hypervisor-runtime-forms-unit-module []
  (defn runtime-forms []
    '((defun emacs-hypervisor-runtime--unit-entry (name)
         (cl-find name emacs-hypervisor-config-units
                  :key (lambda (entry) (plist-get entry :name))
                  :test (function equal)))
      (defun emacs-hypervisor-runtime-note-unit-event (kind name &optional error)
        (when (fboundp 'emacs-hypervisor-report-note-unit-event)
          (emacs-hypervisor-report-note-unit-event kind name error)))
      (defun emacs-hypervisor-runtime--normalize-unit-requires (name requires)
        (cond
         ((and (listp requires) (cl-every (function stringp) requires))
          requires)
         ((and (consp requires)
               (memq (car requires) '(quote unquote))
               (listp (cadr requires))
               (cl-every (function stringp) (cadr requires)))
          (cadr requires))
         (t
          (plist-get (emacs-hypervisor-runtime--unit-entry name) :requires))))
      (defun emacs-hypervisor-runtime--require-unit-features (name requires)
        (let ((missing
               (cl-loop for feature in (emacs-hypervisor-runtime--normalize-unit-requires
                                        name requires)
                        unless (require (intern feature) nil t)
                        collect feature)))
          (when missing
            (error "Unit %s missing required features: %S" name missing))))
      (defun emacs-hypervisor-runtime-run-unit (name body &optional requires)
        (push (list :phase :units :event :attempt :name name)
              emacs-hypervisor-execution-events)
        (emacs-hypervisor-runtime-note-unit-event :attempt name)
        (condition-case err
            (progn
              (emacs-hypervisor-runtime--require-unit-features name requires)
              (let ((result (eval (read body))))
                (push (list :phase :units :event :success :name name)
                      emacs-hypervisor-execution-events)
                (emacs-hypervisor-runtime-note-unit-event :success name)
                result))
          (error
           (emacs-hypervisor-runtime-note-unit-event
            :failed
            name
            (format "%S" err))
           (signal (car err) (cdr err)))))))

  {:runtime-forms runtime-forms})
