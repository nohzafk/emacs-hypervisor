;;; emacs-hypervisor-effect-aware-reload.el --- Reload effect cleanup -*- lexical-binding: t; -*-

(require 'cl-lib)

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
   (t
    (list :kind :opaque
          :unit name
          :source-form form
          :cleanup-form nil
          :supported nil
          :reason :unsupported-form))))

(defun emacs-hypervisor-effect-aware-reload-unit-effects (name entry)
  (mapcar (lambda (form)
            (emacs-hypervisor-effect-aware-reload-form-effect name form))
          (emacs-hypervisor-effect-aware-reload--body-effect-forms
           (plist-get entry :body))))

(defun emacs-hypervisor-effect-aware-reload-cleanup-unit (name entry)
  (let ((effects (emacs-hypervisor-effect-aware-reload-unit-effects name entry))
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
          :failed (nreverse failures))))

(defun emacs-hypervisor-effect-aware-reload-cleanup-count (cleanup)
  (length (plist-get cleanup :cleaned)))

(provide 'emacs-hypervisor-effect-aware-reload)
