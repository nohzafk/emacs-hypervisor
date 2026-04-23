## Shared helper forms emitted into Emacs at session startup.

(include-file "runtime-forms/base.lisp")
(include-file "runtime-forms/elpaca-bridge.lisp")
(include-file "runtime-forms/package-runtime.lisp")
(include-file "runtime-forms/unit-runtime.lisp")

(def base (emacs-hypervisor-runtime-forms-base-module))
(def elpaca-bridge (emacs-hypervisor-runtime-forms-elpaca-bridge-module))
(def package-runtime (emacs-hypervisor-runtime-forms-package-module))
(def unit-runtime (emacs-hypervisor-runtime-forms-unit-module))

(defn emacs-hypervisor-runtime-forms-module []
  (defn append-all [lists]
    (if (empty? lists)
      ()
      (append (first lists) (append-all (rest lists)))))

  (defn install-session-helpers-form []
    (append-all
     (list
      '(progn)
      (base:prelude-forms)
      (base:session-state-forms)
      (elpaca-bridge:runtime-forms)
      (package-runtime:session-policy-forms)
      (package-runtime:runtime-forms)
      (unit-runtime:runtime-forms)
      (base:session-reset-forms)
      (package-runtime:session-reset-forms)
      (package-runtime:compatibility-install-forms)
      '(:emacs-hypervisor-session-helpers-ready))))

  {:install-session-helpers-form install-session-helpers-form})
