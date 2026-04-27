;;; emacs-hypervisor-effect-kind-hook.el --- Hook effect support -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-effect-registry)

(defun emacs-hypervisor-effect-kind-hook-form-p (form)
  (and (consp form)
       (eq (car form) 'add-hook)
       (memq (length form) '(3 4 5))
       (or (< (length form) 5)
           (null (nth 4 form)))))

(defun emacs-hypervisor-effect-kind-hook-rewrite-form (unit-name form)
  (if (emacs-hypervisor-effect-kind-hook-form-p form)
      (list
       'emacs-hypervisor-register-hook-effect
       :unit unit-name
       :target (nth 1 form)
       :function (nth 2 form)
       :depth (if (> (length form) 3) (nth 3 form) nil)
       :local (if (> (length form) 4) (nth 4 form) nil)
       :source (list 'quote
                     (emacs-hypervisor-effect-aware-reload-source-plist
                      form)))
    form))

;;;###autoload
(cl-defun emacs-hypervisor-register-hook-effect
    (&key unit target function depth local source)
  "Install and record a global `add-hook' effect."
  (when local
    (error "Local hook effects are not supported by Hypervisor reload"))
  (emacs-hypervisor-effect-registry-install-function-effect
   :unit unit
   :kind :hook
   :target target
   :where nil
   :function function
   :source source
   :install (lambda (function-symbol)
              (add-hook target function-symbol depth local))
   :apply (lambda (function-symbol)
            (list 'add-hook
                  (emacs-hypervisor-effect-registry-quote-value target)
                  (emacs-hypervisor-effect-registry-function-ref
                   function-symbol)
                  depth
                  local))
   :retract (lambda (function-symbol generated)
              `(progn
                 (remove-hook
                  ',target
                  #',function-symbol
                  ,local)
                 ,@(emacs-hypervisor-effect-registry-generated-function-cleanup-forms
                    function-symbol
                    generated)))
   :cleanup-form (lambda (function-symbol)
                   (list 'remove-hook
                         (emacs-hypervisor-effect-registry-quote-value
                          target)
                         (emacs-hypervisor-effect-registry-function-ref
                          function-symbol)))
   :metadata (list :depth depth
                   :local local)))

(emacs-hypervisor-effect-aware-reload-register-effect-spec
 (list :kind :hook
       :operator 'add-hook
       :predicate #'emacs-hypervisor-effect-kind-hook-form-p
       :rewrite #'emacs-hypervisor-effect-kind-hook-rewrite-form))

(provide 'emacs-hypervisor-effect-kind-hook)
