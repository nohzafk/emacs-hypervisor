;;; emacs-hypervisor-effect-aware-reload.el --- Reload effect cleanup -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-hypervisor-effect-registry)

(defconst emacs-hypervisor-effect-aware-reload--generated-prefix
  "emacs-hypervisor--generated-")

(defun emacs-hypervisor-effect-aware-reload--safe-name-component (value)
  (let* ((raw (cond
               ((symbolp value) (symbol-name value))
               ((stringp value) value)
               (t (format "%S" value))))
         (safe (replace-regexp-in-string "[^[:alnum:]_-]+" "-" raw)))
    (if (string-empty-p safe) "anonymous" safe)))

(defun emacs-hypervisor-effect-aware-reload--hash-form (form)
  (substring
   (secure-hash
    'sha1
    (let ((print-circle t)
          (print-level nil)
          (print-length nil))
      (prin1-to-string form)))
   0
   10))

(defun emacs-hypervisor-effect-aware-reload--lambda-ref-form (form)
  (cond
   ((and (consp form) (eq (car form) 'lambda))
    form)
   ((and (consp form)
         (eq (car form) 'function)
         (consp (cadr form))
         (eq (caadr form) 'lambda)
         (null (cddr form)))
    (cadr form))
   (t nil)))

(defun emacs-hypervisor-effect-aware-reload--literal-symbol-ref-p (form)
  (or (and form (symbolp form))
      (and (consp form)
           (memq (car form) '(quote function))
           (cadr form)
           (symbolp (cadr form))
           (null (cddr form)))))

(defun emacs-hypervisor-effect-aware-reload--quoted-symbol-ref-p (form)
  (and (consp form)
       (eq (car form) 'quote)
       (cadr form)
       (symbolp (cadr form))
       (null (cddr form))))

(defun emacs-hypervisor-effect-aware-reload--quoted-symbol-name (form)
  (symbol-name (cadr form)))

(defun emacs-hypervisor-effect-aware-reload--generated-function-symbol
    (unit-name effect-kind target-name function-form)
  (intern
   (format
    "%s%s-%s-%s-%s"
    emacs-hypervisor-effect-aware-reload--generated-prefix
    (emacs-hypervisor-effect-aware-reload--safe-name-component unit-name)
    (emacs-hypervisor-effect-aware-reload--safe-name-component effect-kind)
    (emacs-hypervisor-effect-aware-reload--safe-name-component target-name)
    (emacs-hypervisor-effect-aware-reload--hash-form
     (list :unit unit-name
           :effect effect-kind
           :target target-name
           :function function-form)))))

(defun emacs-hypervisor-effect-aware-reload--generated-function-symbol-p (symbol)
  (and (symbolp symbol)
       (string-prefix-p
        emacs-hypervisor-effect-aware-reload--generated-prefix
        (symbol-name symbol))))

(defun emacs-hypervisor-effect-aware-reload--generated-defalias-form-p (form)
  (and (consp form)
       (eq (car form) 'defalias)
       (= (length form) 3)
       (emacs-hypervisor-effect-aware-reload--quoted-symbol-ref-p (nth 1 form))
       (emacs-hypervisor-effect-aware-reload--generated-function-symbol-p
        (cadr (nth 1 form)))))

(defun emacs-hypervisor-effect-aware-reload--generated-defalias-cleanup-form
    (form)
  (let ((symbol (cadr (nth 1 form))))
    `(when (fboundp ',symbol)
       (fmakunbound ',symbol))))

(defun emacs-hypervisor-effect-aware-reload--normalize-hook-form
    (unit-name form)
  (let ((lambda-form
         (and (consp form)
              (eq (car form) 'add-hook)
              (memq (length form) '(3 4 5))
              (emacs-hypervisor-effect-aware-reload--quoted-symbol-ref-p
               (nth 1 form))
              (or (< (length form) 5)
                  (null (nth 4 form)))
              (emacs-hypervisor-effect-aware-reload--lambda-ref-form
               (nth 2 form)))))
    (if lambda-form
        (let* ((target
                (emacs-hypervisor-effect-aware-reload--quoted-symbol-name
                 (nth 1 form)))
               (symbol
                (emacs-hypervisor-effect-aware-reload--generated-function-symbol
                 unit-name
                 "add-hook"
                 target
                 lambda-form)))
          (list
           (list 'defalias (list 'quote symbol) (list 'function lambda-form))
           (append
            (cl-subseq form 0 2)
            (list (list 'function symbol))
            (nthcdr 3 form))))
      (list form))))

(defun emacs-hypervisor-effect-aware-reload--normalize-advice-form
    (unit-name form)
  (let ((lambda-form
         (and (consp form)
              (eq (car form) 'advice-add)
              (= (length form) 4)
              (emacs-hypervisor-effect-aware-reload--quoted-symbol-ref-p
               (nth 1 form))
              (emacs-hypervisor-effect-aware-reload--lambda-ref-form
               (nth 3 form)))))
    (if lambda-form
        (let* ((target
                (emacs-hypervisor-effect-aware-reload--quoted-symbol-name
                 (nth 1 form)))
               (symbol
                (emacs-hypervisor-effect-aware-reload--generated-function-symbol
                 unit-name
                 (format "advice-add-%S" (nth 2 form))
                 target
                 lambda-form)))
          (list
           (list 'defalias (list 'quote symbol) (list 'function lambda-form))
           (list (nth 0 form) (nth 1 form) (nth 2 form)
                 (list 'function symbol))))
      (list form))))

(defun emacs-hypervisor-effect-aware-reload--static-normalize-body
    (unit-name body)
  "Return BODY with supported anonymous effects rewritten for static cleanup."
  (if (and (consp body) (eq (car body) 'progn))
      (cons
       'progn
       (apply
        #'append
        (mapcar
         (lambda (form)
           (cond
            ((and (consp form) (eq (car form) 'add-hook))
             (emacs-hypervisor-effect-aware-reload--normalize-hook-form
              unit-name
              form))
            ((and (consp form) (eq (car form) 'advice-add))
             (emacs-hypervisor-effect-aware-reload--normalize-advice-form
              unit-name
              form))
            (t (list form))))
         (cdr body))))
    (cond
     ((and (consp body) (eq (car body) 'add-hook))
      (let ((forms
             (emacs-hypervisor-effect-aware-reload--normalize-hook-form
              unit-name
              body)))
        (if (cdr forms) (cons 'progn forms) (car forms))))
     ((and (consp body) (eq (car body) 'advice-add))
      (let ((forms
             (emacs-hypervisor-effect-aware-reload--normalize-advice-form
              unit-name
              body)))
        (if (cdr forms) (cons 'progn forms) (car forms))))
     (t body))))

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
   ((eq (car form) 'add-hook)
    (emacs-hypervisor-effect-aware-reload--registry-hook-form
     unit-name
     form))
   ((eq (car form) 'advice-add)
    (emacs-hypervisor-effect-aware-reload--registry-advice-form
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

(defun emacs-hypervisor-effect-aware-reload--body-effect-forms (body)
  (if (and (consp body) (eq (car body) 'progn))
      (butlast (cdr body))
    (list body)))

(defun emacs-hypervisor-effect-aware-reload--recognized-hook-effect-p (form)
  (and (consp form)
       (eq (car form) 'add-hook)
       (memq (length form) '(3 4 5))
       (emacs-hypervisor-effect-aware-reload--quoted-symbol-ref-p (nth 1 form))
       (emacs-hypervisor-effect-aware-reload--literal-symbol-ref-p (nth 2 form))
       (or (< (length form) 5)
           (null (nth 4 form)))))

(defun emacs-hypervisor-effect-aware-reload--recognized-advice-effect-p (form)
  (and (consp form)
       (eq (car form) 'advice-add)
       (= (length form) 4)
       (emacs-hypervisor-effect-aware-reload--quoted-symbol-ref-p (nth 1 form))
       (emacs-hypervisor-effect-aware-reload--literal-symbol-ref-p (nth 3 form))))

(defun emacs-hypervisor-effect-aware-reload-cleanup-form (effect)
  (plist-get effect :cleanup-form))

(defun emacs-hypervisor-effect-aware-reload-form-effect (name form)
  (cond
   ((emacs-hypervisor-effect-aware-reload--recognized-hook-effect-p form)
    (list :kind :hook
          :unit name
          :source-form form
          :cleanup-form (list 'remove-hook (nth 1 form) (nth 2 form))
          :supported t
          :reason nil))
   ((emacs-hypervisor-effect-aware-reload--recognized-advice-effect-p form)
    (list :kind :advice
          :unit name
          :source-form form
          :cleanup-form (list 'advice-remove (nth 1 form) (nth 3 form))
          :supported t
          :reason nil))
   ((emacs-hypervisor-effect-aware-reload--generated-defalias-form-p form)
    (list :kind :generated-function
          :unit name
          :source-form form
          :cleanup-form
          (emacs-hypervisor-effect-aware-reload--generated-defalias-cleanup-form
           form)
          :supported t
          :reason nil))
   (t
    (list :kind :opaque
          :unit name
          :source-form form
          :cleanup-form nil
          :supported nil
          :reason :unsupported-form))))

(defun emacs-hypervisor-effect-aware-reload-unit-effects (name entry)
  (let ((normalized-body
         (emacs-hypervisor-effect-aware-reload--static-normalize-body
          name
          (plist-get entry :body))))
    (mapcar (lambda (form)
              (emacs-hypervisor-effect-aware-reload-form-effect name form))
            (emacs-hypervisor-effect-aware-reload--body-effect-forms
             normalized-body))))

(defun emacs-hypervisor-effect-aware-reload-cleanup-unit (name entry)
  (let ((registry-cleanup
         (and (fboundp 'emacs-hypervisor-effect-registry-retract-unit)
              (emacs-hypervisor-effect-registry-retract-unit name))))
    (if (plist-get registry-cleanup :effects)
        registry-cleanup
      (let ((effects (emacs-hypervisor-effect-aware-reload-unit-effects
                      name
                      entry))
            cleaned
            unsupported
            failures)
        (dolist (effect effects)
          (if (plist-get effect :supported)
              (let ((cleanup-form
                     (emacs-hypervisor-effect-aware-reload-cleanup-form effect)))
                (condition-case err
                    (progn
                      (eval cleanup-form)
                      (push effect cleaned))
                  (error
                   (push (append effect
                                 (list :error (format "%S" err)))
                         failures))))
            (push effect unsupported)))
        (list :effects effects
              :cleaned (nreverse cleaned)
              :unsupported (nreverse unsupported)
              :failed (nreverse failures))))))

(defun emacs-hypervisor-effect-aware-reload-cleanup-count (cleanup)
  (cl-count-if
   (lambda (effect)
     (memq (plist-get effect :kind) '(:hook :advice)))
   (plist-get cleanup :cleaned)))

(provide 'emacs-hypervisor-effect-aware-reload)
