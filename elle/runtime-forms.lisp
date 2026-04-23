## Shared helper forms emitted into Emacs at session startup.

(include-file "runtime-forms/base.lisp")
(include-file "runtime-forms/source-loader.lisp")
(include-file "runtime-forms/elpaca-bridge.lisp")
(include-file "runtime-forms/package-runtime.lisp")
(include-file "runtime-forms/unit-runtime.lisp")

(def base (emacs-hypervisor-runtime-forms-base-module))
(def source-loader (emacs-hypervisor-runtime-forms-source-loader-module))
(def elpaca-bridge (emacs-hypervisor-runtime-forms-elpaca-bridge-module))
(def package-runtime (emacs-hypervisor-runtime-forms-package-module))
(def unit-runtime (emacs-hypervisor-runtime-forms-unit-module))

(defn emacs-hypervisor-runtime-forms-module []
  (defn append-all [lists]
    (if (empty? lists)
      ()
      (append (first lists) (append-all (rest lists)))))

  (defn install-config-surface-form [report-core-source-path report-source-path declarations-source-path compose-source-path]
    (append-all
     (list
      '(progn)
      (base:prelude-forms)
      (source-loader:load-source-form report-core-source-path :emacs-hypervisor-report-core-ready)
      (source-loader:load-source-form report-source-path :emacs-hypervisor-report-ready)
      '((emacs-hypervisor-report-reset)
        (emacs-hypervisor-report-session-started))
      (source-loader:load-source-form declarations-source-path :emacs-hypervisor-config-surface-ready)
      (source-loader:load-source-form compose-source-path :emacs-hypervisor-compose-ready)
      '(:emacs-hypervisor-config-surface-ready))))

  (defn install-session-helpers-form []
    (append-all
     (list
      '(progn)
      (base:session-state-forms)
      (elpaca-bridge:runtime-forms)
      (package-runtime:session-policy-forms)
      (package-runtime:runtime-forms)
      (unit-runtime:runtime-forms)
      (base:session-reset-forms)
      (package-runtime:session-reset-forms)
      (package-runtime:compatibility-install-forms)
      '(:emacs-hypervisor-session-helpers-ready))))

  {:install-config-surface-form install-config-surface-form
   :install-session-helpers-form install-session-helpers-form})
