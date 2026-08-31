(elle/epoch 12)
## Shared helper forms emitted into Emacs at session startup.

(include-file "runtime-forms/module-loader.lisp")

(def module-loader (emacs-hypervisor-runtime-forms-module-loader-module))

(defn emacs-hypervisor-runtime-forms-module []
  (defn append-all [lists]
    (if (empty? lists)
      ()
      (append (first lists) (append-all (rest lists)))))

  (defn module-field [entry key]
    (match entry
      () nil
      (field value & rest) (if (= field key) value (module-field rest key))
      _ nil))

  (defn embedded-module-spec [entry]
    (let [env-name (module-field entry :env-name)
          path (module-field entry :path)
          source (sys/env env-name)]
      (assert source (string "expected embedded module source in " env-name))
      {:path path :source source}))

  (defn module-entry [manifest name]
    (letrec [loop (fn [remaining]
                    (match remaining
                      () nil
                      (entry & rest)
                        (if (= (module-field entry :name) name) entry (loop rest))
                      _ nil))]
      (loop manifest)))

  (defn module-spec [manifest name]
    (let [entry (module-entry manifest name)]
      (assert entry (string "expected embedded runtime module " name))
      (embedded-module-spec entry)))

  (defn module-ready-marker [manifest name]
    (let [entry (module-entry manifest name)]
      (assert entry (string "expected embedded runtime module " name))
      (let [ready-marker (module-field entry :ready-marker)]
        (assert ready-marker (string "expected ready marker for embedded runtime module " name))
        ready-marker)))

  (defn load-module-by-name [manifest name]
    (module-loader:load-module-form (module-spec manifest name) (module-ready-marker manifest name)))

  (defn install-config-surface-form [manifest]
    (append-all (list '(progn) (load-module-by-name manifest "REPORT_CORE") (load-module-by-name manifest "REPORT")
                      '((emacs-hypervisor-report-reset) (emacs-hypervisor-report-session-started))
                      (load-module-by-name manifest "ELLE_CANONICALIZE")
                      (load-module-by-name manifest "EFFECT_REGISTRY")
                      (load-module-by-name manifest "EFFECT_AWARE_RELOAD")
                      (load-module-by-name manifest "EFFECT_KIND_HOOK")
                      (load-module-by-name manifest "EFFECT_KIND_ADVICE")
                      (load-module-by-name manifest "EFFECT_KIND_KEYBINDING")
                      (load-module-by-name manifest "DECLARATIONS") (load-module-by-name manifest "LINT")
                      (load-module-by-name manifest "SELECTIVE_RELOAD")
                      (load-module-by-name manifest "CONFIG_PATHS") (load-module-by-name manifest "CONFIG_LOADER")
                      (load-module-by-name manifest "RELOAD_REPORT") (load-module-by-name manifest "RELOAD_POLICY")
                      (load-module-by-name manifest "COMPOSE") '(:emacs-hypervisor-config-surface-ready))))

  (defn install-session-helpers-form [manifest]
    (append-all (list '(progn) (load-module-by-name manifest "SESSION_BASE")
                      (load-module-by-name manifest "PACKAGE_LOCK")
                      (load-module-by-name manifest "PACKAGE_BRIDGE") (load-module-by-name manifest "PACKAGE_RUNTIME")
                      (load-module-by-name manifest "UNIT_RUNTIME")
                      '((emacs-hypervisor-bridge-activate) :emacs-hypervisor-session-helpers-ready))))

  {:install-config-surface-form install-config-surface-form :install-session-helpers-form install-session-helpers-form})
