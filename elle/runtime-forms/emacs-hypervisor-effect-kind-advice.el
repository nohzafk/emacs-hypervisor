;;; emacs-hypervisor-effect-kind-advice.el --- Advice effect support -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-effect-registry)

;;;###autoload
(cl-defun emacs-hypervisor-register-advice-effect
    (&key unit target where function source)
  "Install and record an `advice-add' effect."
  (emacs-hypervisor-effect-registry-install-function-effect
   :unit unit
   :kind :advice
   :target target
   :where where
   :function function
   :source source
   :install (lambda (function-symbol)
              (advice-add target where function-symbol))
   :apply (lambda (function-symbol)
            (list 'advice-add
                  (emacs-hypervisor-effect-registry-quote-value target)
                  where
                  (emacs-hypervisor-effect-registry-function-ref
                   function-symbol)))
   :retract (lambda (function-symbol generated)
              `(progn
                 (advice-remove ',target #',function-symbol)
                 ,@(emacs-hypervisor-effect-registry-generated-function-cleanup-forms
                    function-symbol
                    generated)))
   :cleanup-form (lambda (function-symbol)
                   (list 'advice-remove
                         (emacs-hypervisor-effect-registry-quote-value
                          target)
                         (emacs-hypervisor-effect-registry-function-ref
                          function-symbol)))
   :metadata (list :where where)))

(emacs-hypervisor-effect-aware-reload-define-function-effect-kind
 :kind :advice
 :operator 'advice-add
 :arities '(4)
 :slots '((:target 1)
          (:where 2)
          (:function 3))
 :register-fn 'emacs-hypervisor-register-advice-effect)

(provide 'emacs-hypervisor-effect-kind-advice)
