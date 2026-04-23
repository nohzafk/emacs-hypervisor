## Base emitted forms for loading the Elpaca bridge and resetting session state.

(defn emacs-hypervisor-runtime-forms-base-module []
  (defn prelude-forms []
    '((require 'cl-lib)))

  (defn session-state-forms []
    '((defvar emacs-hypervisor-execution-events nil)
      (defvar emacs-hypervisor-installed-packages nil)))

  (defn session-reset-forms []
    '((setq emacs-hypervisor-execution-events nil)
      (setq emacs-hypervisor-installed-packages nil)))

  {:prelude-forms prelude-forms
   :session-reset-forms session-reset-forms
   :session-state-forms session-state-forms})
