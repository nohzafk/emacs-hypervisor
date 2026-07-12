;;; emacs-hypervisor-unit-runtime.el --- Unit runtime helpers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-declarations)
(require 'emacs-hypervisor-session-base)

(declare-function emacs-hypervisor-report-note-unit-event
                  "emacs-hypervisor-report")

(defun emacs-hypervisor-runtime--unit-entry (name)
  (cl-find name emacs-hypervisor-config-units
           :key (lambda (entry) (plist-get entry :name))
           :test #'equal))

(defun emacs-hypervisor-runtime--unit-entry-at-index (index)
  (nth index (nreverse (copy-sequence emacs-hypervisor-config-units))))

(defun emacs-hypervisor-runtime-note-unit-event (kind name &optional error)
  (when (fboundp 'emacs-hypervisor-report-note-unit-event)
    (emacs-hypervisor-report-note-unit-event kind name error)))

(defun emacs-hypervisor-runtime--normalize-unit-requires (name requires)
  (cond
   ((and (listp requires) (cl-every #'stringp requires))
    requires)
   ((and (consp requires)
         (memq (car requires) '(quote unquote))
         (listp (cadr requires))
         (cl-every #'stringp (cadr requires)))
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

(defun emacs-hypervisor-runtime-run-unit (name &optional body requires)
  (push (list :phase :units :event :attempt :name name)
        emacs-hypervisor-execution-events)
  (emacs-hypervisor-runtime-note-unit-event :attempt name)
  (condition-case err
      (progn
        (let ((entry (emacs-hypervisor-runtime--unit-entry name)))
          (unless (or entry body)
            (error "Unknown config unit: %s" name))
          (emacs-hypervisor-runtime--require-unit-features
           name
           (or requires (and entry (plist-get entry :requires))))
          (let ((result (eval (or body (plist-get entry :body)) t)))
            (push (list :phase :units :event :success :name name)
                  emacs-hypervisor-execution-events)
            (emacs-hypervisor-runtime-note-unit-event :success name)
            result)))
    (error
     (emacs-hypervisor-runtime-note-unit-event
      :failed
      name
      (format "%S" err))
     (signal (car err) (cdr err)))))

(defun emacs-hypervisor-runtime-run-unit-at-index (index)
  (let ((entry (emacs-hypervisor-runtime--unit-entry-at-index index)))
    (unless entry
      (error "Unknown config unit index: %S" index))
    (emacs-hypervisor-runtime-run-unit (plist-get entry :name))))

(provide 'emacs-hypervisor-unit-runtime)
