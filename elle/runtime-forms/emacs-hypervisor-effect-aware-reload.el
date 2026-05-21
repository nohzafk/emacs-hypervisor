;;; emacs-hypervisor-effect-aware-reload.el --- Reload effect cleanup -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-effect-registry)

(defvar emacs-hypervisor-effect-aware-reload-effect-specs nil
  "Registered effect rewrite specs in dispatch order.")

(defun emacs-hypervisor-effect-aware-reload-source-plist (form)
  (list :form form))

(defun emacs-hypervisor-effect-aware-reload-register-effect-spec (spec)
  "Register effect rewrite SPEC.

SPEC is a plist with :kind, :operator, :predicate, and :rewrite.
The predicate receives a form and the rewrite function receives UNIT-NAME and
the same form."
  (let ((kind (plist-get spec :kind))
        (operator (plist-get spec :operator))
        (predicate (plist-get spec :predicate))
        (rewrite (plist-get spec :rewrite))
        replaced
        updated)
    (unless (and kind operator (functionp predicate) (functionp rewrite))
      (error "Invalid effect spec: %S" spec))
    (dolist (entry emacs-hypervisor-effect-aware-reload-effect-specs)
      (if (and (eq (plist-get entry :kind) kind)
               (eq (plist-get entry :operator) operator))
          (progn
            (push spec updated)
            (setq replaced t))
        (push entry updated)))
    (setq emacs-hypervisor-effect-aware-reload-effect-specs
          (if replaced
              (nreverse updated)
            (append emacs-hypervisor-effect-aware-reload-effect-specs
                    (list spec))))
    spec))

(defun emacs-hypervisor-effect-aware-reload--registry-effect-spec
    (operator)
  (cl-find operator
           emacs-hypervisor-effect-aware-reload-effect-specs
           :key (lambda (spec) (plist-get spec :operator))))

(defun emacs-hypervisor-effect-aware-reload--registry-effect-spec-for-form
    (form)
  (and (consp form)
       (cl-find-if
        (lambda (spec)
          (and (eq (plist-get spec :operator) (car form))
               (funcall (plist-get spec :predicate) form)))
        emacs-hypervisor-effect-aware-reload-effect-specs)))

(defun emacs-hypervisor-effect-aware-reload--registry-effect-form-p
    (form)
  (and (emacs-hypervisor-effect-aware-reload--registry-effect-spec-for-form
        form)
       t))

(defun emacs-hypervisor-effect-aware-reload--registry-effect-form
    (unit-name form)
  (let ((spec
         (emacs-hypervisor-effect-aware-reload--registry-effect-spec-for-form
          form)))
    (if spec
        (funcall (plist-get spec :rewrite) unit-name form)
      form)))

(defun emacs-hypervisor-effect-aware-reload--rewrite-body-forms
    (unit-name forms)
  (mapcar
   (lambda (form)
     (emacs-hypervisor-effect-aware-reload--rewrite-form unit-name form))
   forms))

(defun emacs-hypervisor-effect-aware-reload--rewrite-cond-clause
    (unit-name clause)
  (if (consp clause)
      (cons (car clause)
            (emacs-hypervisor-effect-aware-reload--rewrite-body-forms
             unit-name
             (cdr clause)))
    clause))

(defun emacs-hypervisor-effect-aware-reload--rewrite-form (unit-name form)
  (cond
   ((not (consp form))
    form)
   ((memq (car form) '(quote function lambda defun defmacro))
    form)
   ((emacs-hypervisor-effect-aware-reload--registry-effect-spec (car form))
    (emacs-hypervisor-effect-aware-reload--registry-effect-form
     unit-name
     form))
   ((eq (car form) 'progn)
    (cons 'progn
          (emacs-hypervisor-effect-aware-reload--rewrite-body-forms
           unit-name
           (cdr form))))
   ((memq (car form) '(let let* when unless dolist dotimes))
    (append
     (list (car form) (cadr form))
     (emacs-hypervisor-effect-aware-reload--rewrite-body-forms
      unit-name
      (cddr form))))
   ((eq (car form) 'if)
    (append
     (list (car form)
           (cadr form)
           (emacs-hypervisor-effect-aware-reload--rewrite-form
            unit-name
            (caddr form)))
     (emacs-hypervisor-effect-aware-reload--rewrite-body-forms
      unit-name
      (cdddr form))))
   ((eq (car form) 'cond)
    (cons
     'cond
     (mapcar
      (lambda (clause)
        (emacs-hypervisor-effect-aware-reload--rewrite-cond-clause
         unit-name
         clause))
      (cdr form))))
   (t form)))

(defun emacs-hypervisor-effect-aware-reload-normalize-body (unit-name body)
  "Return BODY with supported effects rewritten to registry helpers."
  (emacs-hypervisor-effect-aware-reload--rewrite-form unit-name body))

(defun emacs-hypervisor-effect-aware-reload-normalize-entry (entry)
  "Return ENTRY with its body normalized for supported reload effects."
  (let ((copy (copy-sequence entry))
        (name (plist-get entry :name)))
    (plist-put
     copy
     :body
     (emacs-hypervisor-effect-aware-reload-normalize-body
      name
      (plist-get entry :body)))))

(defun emacs-hypervisor-effect-aware-reload-cleanup-unit (name _entry)
  (emacs-hypervisor-effect-registry-retract-unit name))

(defun emacs-hypervisor-effect-aware-reload-cleanup-count (cleanup)
  (length (plist-get cleanup :cleaned)))

(provide 'emacs-hypervisor-effect-aware-reload)
