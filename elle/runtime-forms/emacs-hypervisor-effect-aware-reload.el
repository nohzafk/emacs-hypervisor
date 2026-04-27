;;; emacs-hypervisor-effect-aware-reload.el --- Reload effect cleanup -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-effect-registry)

(defun emacs-hypervisor-effect-aware-reload--registry-hook-form-p (form)
  (and (consp form)
       (eq (car form) 'add-hook)
       (memq (length form) '(3 4 5))
       (or (< (length form) 5)
           (null (nth 4 form)))))

(defun emacs-hypervisor-effect-aware-reload--registry-advice-form-p (form)
  (and (consp form)
       (eq (car form) 'advice-add)
       (= (length form) 4)))

(defun emacs-hypervisor-effect-aware-reload--source-plist (form)
  (list :form form))

(defun emacs-hypervisor-effect-aware-reload--registry-hook-form
    (unit-name form)
  (if (emacs-hypervisor-effect-aware-reload--registry-hook-form-p form)
      (list
       'emacs-hypervisor-register-hook-effect
       :unit unit-name
       :target (nth 1 form)
       :function (nth 2 form)
       :depth (if (> (length form) 3) (nth 3 form) nil)
       :local (if (> (length form) 4) (nth 4 form) nil)
       :source (list 'quote
                     (emacs-hypervisor-effect-aware-reload--source-plist
                      form)))
    form))

(defun emacs-hypervisor-effect-aware-reload--registry-advice-form
    (unit-name form)
  (if (emacs-hypervisor-effect-aware-reload--registry-advice-form-p form)
      (list
       'emacs-hypervisor-register-advice-effect
       :unit unit-name
       :target (nth 1 form)
       :where (nth 2 form)
       :function (nth 3 form)
       :source (list 'quote
                     (emacs-hypervisor-effect-aware-reload--source-plist
                      form)))
    form))

(defconst emacs-hypervisor-effect-aware-reload--registry-effect-specs
  (list
   (list :kind :hook
         :operator 'add-hook
         :predicate
         #'emacs-hypervisor-effect-aware-reload--registry-hook-form-p
         :rewrite
         #'emacs-hypervisor-effect-aware-reload--registry-hook-form)
   (list :kind :advice
         :operator 'advice-add
         :predicate
         #'emacs-hypervisor-effect-aware-reload--registry-advice-form-p
         :rewrite
         #'emacs-hypervisor-effect-aware-reload--registry-advice-form)))

(defun emacs-hypervisor-effect-aware-reload--registry-effect-spec
    (operator)
  (cl-find operator
           emacs-hypervisor-effect-aware-reload--registry-effect-specs
           :key (lambda (spec) (plist-get spec :operator))))

(defun emacs-hypervisor-effect-aware-reload--registry-effect-form-p
    (form)
  (and (consp form)
       (let ((spec
              (emacs-hypervisor-effect-aware-reload--registry-effect-spec
               (car form))))
         (and spec
              (funcall (plist-get spec :predicate) form)))))

(defun emacs-hypervisor-effect-aware-reload--registry-effect-form
    (unit-name form)
  (let ((spec
         (and (consp form)
              (emacs-hypervisor-effect-aware-reload--registry-effect-spec
               (car form)))))
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
   ((memq (car form) '(let let*))
    (append
     (list (car form) (cadr form))
     (emacs-hypervisor-effect-aware-reload--rewrite-body-forms
      unit-name
      (cddr form))))
   ((memq (car form) '(when unless))
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
   ((memq (car form) '(dolist dotimes))
    (append
     (list (car form) (cadr form))
     (emacs-hypervisor-effect-aware-reload--rewrite-body-forms
      unit-name
      (cddr form))))
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
