## Shared helper forms emitted into Emacs at session startup.

(include-file "runtime-forms/module-loader.lisp")

(def module-loader (emacs-hypervisor-runtime-forms-module-loader-module))

(defn emacs-hypervisor-runtime-forms-module []
  (defn append-all [lists]
    (if (empty? lists)
      ()
      (append (first lists) (append-all (rest lists)))))

  (defn install-config-surface-form [report-core-module report-module declarations-module compose-module]
    (append-all
     (list
      '(progn)
      (module-loader:load-module-form report-core-module :emacs-hypervisor-report-core-ready)
      (module-loader:load-module-form report-module :emacs-hypervisor-report-ready)
      '((emacs-hypervisor-report-reset)
        (emacs-hypervisor-report-session-started))
      (module-loader:load-module-form declarations-module :emacs-hypervisor-config-surface-ready)
      (module-loader:load-module-form compose-module :emacs-hypervisor-compose-ready)
      '(:emacs-hypervisor-config-surface-ready))))

  (defn install-session-helpers-form [session-base-module elpaca-bridge-module package-runtime-module unit-runtime-module]
    (append-all
     (list
      '(progn)
      (module-loader:load-module-form session-base-module :emacs-hypervisor-session-base-ready)
      (module-loader:load-module-form elpaca-bridge-module :emacs-hypervisor-elpaca-bridge-ready)
      (module-loader:load-module-form package-runtime-module :emacs-hypervisor-package-runtime-ready)
      (module-loader:load-module-form unit-runtime-module :emacs-hypervisor-unit-runtime-ready)
      '(:emacs-hypervisor-session-helpers-ready))))

  {:install-config-surface-form install-config-surface-form
   :install-session-helpers-form install-session-helpers-form})
