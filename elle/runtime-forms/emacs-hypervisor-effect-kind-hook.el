;;; emacs-hypervisor-effect-kind-hook.el --- Hook effect support -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'emacs-hypervisor-effect-aware-reload)
(require 'emacs-hypervisor-effect-registry)

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

(emacs-hypervisor-effect-aware-reload-define-function-effect-kind
 :kind :hook
 :operator 'add-hook
 :arities '(3 4 5)
 :extra-predicate (lambda (form)
                    (or (< (length form) 5)
                        (null (nth 4 form))))
 :slots '((:target 1)
          (:function 2)
          (:depth 3 :optional t)
          (:local 4 :optional t))
 :register-fn 'emacs-hypervisor-register-hook-effect)

(provide 'emacs-hypervisor-effect-kind-hook)
