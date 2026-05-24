;;; emacs-hypervisor-reload-report.el --- Reload report helpers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-hypervisor-effect-aware-reload)

(defvar emacs-hypervisor-reload-log-enabled t
  "When non-nil, `emacs-hypervisor-reload-config' logs reload progress.")

(defvar emacs-hypervisor--reload-logging-active nil)

(defun emacs-hypervisor--make-reload-report
    (name status reason &optional details action cleanup)
  (list :name name
        :status status
        :reason reason
        :action action
        :cleanup cleanup
        :details details))

(defun emacs-hypervisor--reload-log (format-string &rest args)
  (when (and emacs-hypervisor-reload-log-enabled
             emacs-hypervisor--reload-logging-active)
    (apply #'message (concat "[Hypervisor] " format-string) args)))

(defun emacs-hypervisor--reload-format-value (value)
  (cond
   ((and (consp value) (eq (car value) 'quote))
    (emacs-hypervisor--reload-format-value (cadr value)))
   ((and (consp value) (eq (car value) 'function))
    (format "#'%s"
            (emacs-hypervisor--reload-format-value (cadr value))))
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   ((null value) "nil")
   (t (format "%S" value))))

(defun emacs-hypervisor--reload-effect-source-form (effect)
  (plist-get effect :source-form))

(defun emacs-hypervisor--reload-effect-target (effect)
  (or (plist-get effect :target)
      (nth 1 (emacs-hypervisor--reload-effect-source-form effect))))

(defun emacs-hypervisor--reload-effect-function (effect)
  (or (plist-get effect :function)
      (let ((form (emacs-hypervisor--reload-effect-source-form effect)))
        (pcase (plist-get effect :kind)
          (:advice (nth 3 form))
          (_ (nth 2 form))))))

(defun emacs-hypervisor--reload-effect-where (effect)
  (or (plist-get (plist-get effect :metadata) :where)
      (nth 2 (emacs-hypervisor--reload-effect-source-form effect))))

(defun emacs-hypervisor--reload-format-effect (effect)
  (cl-flet ((fmt (value) (emacs-hypervisor--reload-format-value value)))
    (let ((metadata (plist-get effect :metadata)))
      (pcase (plist-get effect :kind)
        (:hook
         (format "hook %s -> %s"
                 (fmt (emacs-hypervisor--reload-effect-target effect))
                 (fmt (emacs-hypervisor--reload-effect-function effect))))
        (:advice
         (format "advice %s %s -> %s"
                 (fmt (emacs-hypervisor--reload-effect-target effect))
                 (fmt (emacs-hypervisor--reload-effect-where effect))
                 (fmt (emacs-hypervisor--reload-effect-function effect))))
        (:keybinding
         (format "keybinding %s %s -> %s"
                 (fmt (plist-get metadata :map))
                 (fmt (plist-get metadata :key))
                 (fmt (emacs-hypervisor--reload-effect-function effect))))
        (:generated-function
         (format "generated function %s"
                 (fmt (emacs-hypervisor--reload-effect-function effect))))
        (kind
         (format "%s effect" (fmt kind)))))))

(defun emacs-hypervisor--reload-log-cleanup (name cleanup)
  (when cleanup
    (dolist (effect (plist-get cleanup :cleaned))
      (emacs-hypervisor--reload-log
       "Reload cleaned %s for %s"
       (emacs-hypervisor--reload-format-effect effect)
       name))
    (dolist (effect (plist-get cleanup :failed))
      (emacs-hypervisor--reload-log
       "Reload cleanup failed for %s: %s (%s)"
       name
       (emacs-hypervisor--reload-format-effect effect)
       (plist-get effect :error)))))

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

(provide 'emacs-hypervisor-reload-report)
