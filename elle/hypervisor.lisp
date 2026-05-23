(elle/epoch 10)
## hypervisor.lisp
##
## Shared Hypervisor backend:
## 1. perform the standard handshake and read boot context
## 2. install emitted declaration forms inside Emacs
## 3. ask Emacs to load repo config using those emitted forms
## 4. request exported session-data from Emacs
## 5. derive plans, install runtime helpers, then execute

(include-file "protocol.lisp")
(include-file "graph.lisp")
(include-file "benchmark.lisp")
(include-file "preflight.lisp")
(include-file "boot-policy.lisp")
(include-file "reporting.lisp")
(include-file "planning.lisp")
(include-file "execution.lisp")
(include-file "runtime-forms.lisp")

(def protocol (emacs-hypervisor-protocol-module))
(def mailbox (protocol:make-mailbox))
(def graph (emacs-hypervisor-graph-module))
(def runtime-forms (emacs-hypervisor-runtime-forms-module))

(defn emacs-hypervisor-embedded-module-spec [env-name source-path]
  (let [forms-source (sys/env env-name)]
    (assert forms-source
            (string "expected embedded module forms in " env-name))
    {:path source-path
     :forms (read-all forms-source)}))

(defn emacs-hypervisor-config-load-failure-message [config-file config-org-file error]
  (string
   "config load failed for "
   (or config-org-file config-file "<unknown config>")
   ": "
   error))

(defn emacs-hypervisor-send-shutdown [payload]
  (protocol:send-event :shutdown payload)
  (sys/exit 0))

(defn emacs-hypervisor-handle-config-load-failure
    [config-load-result config-file config-org-file]
  (let* [config-error
         (or (protocol:response-error config-load-result) :unknown-error)
         config-source (or config-org-file config-file "<unknown config>")
         config-message
         (emacs-hypervisor-config-load-failure-message
          config-file
          config-org-file
          config-error)]
    (protocol:send-event
     :log
     `(:level :error
       :phase :startup
       :step :load-config
       :source ,config-source
       :message ,config-message
       :details ,config-error))
    (emacs-hypervisor-send-shutdown
     `(:reason :config-load-failed
       :status :failed
       :phase :startup
       :step :load-config
       :source ,config-source
       :message ,config-message
       :details ,config-error))))

(protocol:with-mailbox-reader
 mailbox
 (fn []
   (protocol:send-request
    1
    :hello
    '(:mode :hypervisor-session))

   (let [hello-response (protocol:await-response mailbox 1)]
     (assert (protocol:response-ok? hello-response)
             "expected successful :hello response")
     (let [{:protocol hello-protocol
            :version hello-version}
           (protocol:from-wire (protocol:message-payload hello-response))]
       (assert (= hello-protocol :sexp-rpc)
               "expected :sexp-rpc protocol in :hello response")
       (assert (= hello-version 1)
               "expected version 1 in :hello response")))

   (protocol:send-request 2 :boot-context ())

   (let* [boot-context-response (protocol:await-response mailbox 2)
          _ (assert (protocol:response-ok? boot-context-response)
                    "expected successful :boot-context response")
          boot-context
          (protocol:from-wire (protocol:message-payload boot-context-response))
          boot-session-name (get boot-context :session-name)
          boot-config-file (get boot-context :config-file)
          boot-config-org-file (get boot-context :config-org-file)
          boot-repo-dir (get boot-context :repo-dir)
          boot-expected-init-hash (sys/env "EMACS_HYPERVISOR_EMBEDDED_INIT_HASH")
          report-core-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_REPORT_CORE_FORMS"
           "elle/runtime-forms/emacs-hypervisor-report-core.el")
          report-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_REPORT_FORMS"
           "elle/runtime-forms/emacs-hypervisor-report.el")
          elle-canonicalize-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_ELLE_CANONICALIZE_FORMS"
           "elle/runtime-forms/emacs-hypervisor-elle-canonicalize.el")
          declarations-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_DECLARATIONS_FORMS"
           "elle/runtime-forms/emacs-hypervisor-declarations.el")
          effect-registry-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_EFFECT_REGISTRY_FORMS"
           "elle/runtime-forms/emacs-hypervisor-effect-registry.el")
          effect-aware-reload-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_EFFECT_AWARE_RELOAD_FORMS"
           "elle/runtime-forms/emacs-hypervisor-effect-aware-reload.el")
          effect-kind-hook-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_EFFECT_KIND_HOOK_FORMS"
           "elle/runtime-forms/emacs-hypervisor-effect-kind-hook.el")
          effect-kind-advice-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_EFFECT_KIND_ADVICE_FORMS"
           "elle/runtime-forms/emacs-hypervisor-effect-kind-advice.el")
          effect-kind-keybinding-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_EFFECT_KIND_KEYBINDING_FORMS"
           "elle/runtime-forms/emacs-hypervisor-effect-kind-keybinding.el")
          selective-reload-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_SELECTIVE_RELOAD_FORMS"
           "elle/runtime-forms/emacs-hypervisor-selective-reload.el")
          config-paths-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_CONFIG_PATHS_FORMS"
           "elle/runtime-forms/emacs-hypervisor-config-paths.el")
          compose-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_COMPOSE_FORMS"
           "elle/runtime-forms/emacs-hypervisor-compose.el")
          session-base-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_SESSION_BASE_FORMS"
           "elle/runtime-forms/emacs-hypervisor-session-base.el")
          package-bridge-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_PACKAGE_BRIDGE_FORMS"
           "elle/runtime-forms/emacs-hypervisor-package-bridge.el")
          package-runtime-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_PACKAGE_RUNTIME_FORMS"
           "elle/runtime-forms/emacs-hypervisor-package-runtime.el")
          unit-runtime-module
          (emacs-hypervisor-embedded-module-spec
           "EMACS_HYPERVISOR_EMBEDDED_UNIT_RUNTIME_FORMS"
           "elle/runtime-forms/emacs-hypervisor-unit-runtime.el")
          config-file
          (or boot-config-file
              (and boot-repo-dir
                   (string boot-repo-dir "/config.el")))
          config-org-file boot-config-org-file
          _ (assert config-file
                    "expected :config-file or :repo-dir in boot context")
          benchmark-enabled
          (not (= (get boot-context :benchmark-enabled) false))
          benchmark
          (emacs-hypervisor-benchmark-module protocol benchmark-enabled)
          preflight
          (emacs-hypervisor-preflight-module protocol graph mailbox benchmark)
          policy
          (emacs-hypervisor-boot-policy-module graph preflight)
          reporting
          (emacs-hypervisor-reporting-module protocol policy)
          planning
          (emacs-hypervisor-planning-module protocol graph)
          execution
          (emacs-hypervisor-execution-module protocol graph mailbox benchmark)
          session-name (or boot-session-name "hypervisor-session")]
     (reporting:emit-bootstrap-warning boot-context boot-expected-init-hash)
     (protocol:send-event
      :log
      `(:level :info
        :message ,(string "installing config surface for " session-name)))
     (protocol:send-request
      3
      :eval
      (benchmark:eval-payload
       `(:form ,(runtime-forms:install-config-surface-form
                 report-core-module
                 report-module
                 elle-canonicalize-module
                 effect-registry-module
                 effect-aware-reload-module
                 effect-kind-hook-module
                 effect-kind-advice-module
                 effect-kind-keybinding-module
                 declarations-module
                 selective-reload-module
                 config-paths-module
                 compose-module)
         :metric-name :install-config-surface
         :metric-kind :runtime-setup
         :phase :startup)))
     (let [config-surface-result (protocol:await-response mailbox 3)]
       (assert (protocol:response-ok? config-surface-result)
               (string "config surface install should succeed: "
                       (or (protocol:response-error config-surface-result)
                           :unknown-error))))
     (protocol:send-event
      :progress
      '(:phase :startup :step :config-surface-installed :done 1 :total 10))
     (when config-org-file
       (protocol:send-event
        :log
        `(:level :info
          :message ,(string "tangling " config-org-file " before loading config"))))
     (protocol:send-request
     4
      :eval
      (benchmark:eval-payload
       (if config-org-file
         `(:form (let [(tangled-file
                        (expand-file-name
                         ".config.tangled.el"
                         (file-name-directory ,config-org-file)))]
                   (emacs-hypervisor-reset-declarations)
                   (require (quote ob-tangle))
                   (org-babel-tangle-file
                    ,config-org-file
                    tangled-file
                    (rx string-start (or "elisp" "emacs-lisp") string-end))
                   (load-file tangled-file)
                   :ok)
           :metric-name :load-config
           :metric-kind :runtime-setup
           :phase :startup)
         `(:form (progn
                   (emacs-hypervisor-reset-declarations)
                   (load-file ,config-file)
                   :ok)
           :metric-name :load-config
           :metric-kind :runtime-setup
           :phase :startup))))
     (let [config-load-result (protocol:await-response mailbox 4)]
       (if (protocol:response-ok? config-load-result)
         (begin
           (protocol:send-event
            :progress
            '(:phase :startup :step :config-loaded :done 2 :total 10))
           (protocol:send-request
            5
            :session-data
            '(:fields (:packages :units :env)))
           (let* [session-data-response (protocol:await-response mailbox 5)
                  _ (assert (protocol:response-ok? session-data-response)
                            "expected successful :session-data response")
                  {:packages raw-packages :units raw-units :env raw-env}
                  (protocol:from-wire-session-data
                   (protocol:message-payload session-data-response))
                  packages (or raw-packages ())
                  units (or raw-units ())
                  env (or raw-env ())
                  session-analysis-started-at (clock/monotonic)
                  {:reports planned-package-reports}
                  (benchmark:measure
                   :planning
                   :derive-package-reports
                   (fn [] (policy:derive-package-reports packages)))
                  package-names (graph:known-names packages)
                  {:reports executable-reports}
                  (benchmark:measure
                   :preflight
                   :probe-executables
                   (fn []
                     (preflight:probe-executables
                      (preflight:units-with-executables units)
                      10)))
                  {:reports planned-unit-reports}
                  (benchmark:measure
                   :planning
                   :derive-unit-reports
                   (fn []
                     (policy:derive-unit-reports
                      units
                      package-names
                      planned-package-reports
                      env
                      executable-reports)))
                  package-plan
                  (benchmark:measure
                   :planning
                   :derive-package-plan
                   (fn []
                     (planning:derive-package-plan packages planned-package-reports)))
                  unit-plan
                  (benchmark:measure
                   :planning
                   :derive-unit-plan
                   (fn []
                     (planning:derive-unit-plan units planned-unit-reports)))]
             (benchmark:emit-metric
              :planning
              :session-analysis-total
              (benchmark:elapsed-ms session-analysis-started-at)
              nil
              nil)
             (protocol:send-event
              :progress
              '(:phase :handshake :step :session-data-parsed :done 3 :total 10))
             (protocol:send-event
              :log
              `(:level :info
                :message ,(string "prepared session helper forms for " session-name)))
             (protocol:send-request
              6
              :eval
              (benchmark:eval-payload
               `(:form ,(runtime-forms:install-session-helpers-form
                         session-base-module
                         package-bridge-module
                         package-runtime-module
                         unit-runtime-module)
                 :metric-name :install-session-helpers
                 :metric-kind :runtime-setup
                 :phase :startup)))
             (let [runtime-result (protocol:await-response mailbox 6)]
               (assert (protocol:response-ok? runtime-result)
                       (string "session helper install should succeed: "
                               (or (protocol:response-error runtime-result)
                                   :unknown-error))))
             (protocol:send-event
              :progress
              '(:phase :planning :step :policy-derived :done 4 :total 10))
             (reporting:emit-report-message :planned :packages planned-package-reports)
             (reporting:emit-report-message :planned :units planned-unit-reports)
             (reporting:emit-report-logs "planned-package" planned-package-reports)
             (reporting:emit-report-logs "planned-unit" planned-unit-reports)
             (planning:emit-plan-message package-plan)
             (planning:emit-plan-message unit-plan)
             (protocol:send-event
              :progress
              '(:phase :planning :step :plans-emitted :done 5 :total 10))
             (let* [executed-package-plan
                    (execution:execute-package-entry-plan-tracker
                     (planning:plan-items package-plan)
                     30)
                    package-reports
                    (planning:merge-executed-reports
                     planned-package-reports
                     (get executed-package-plan :reports))
                    {:next-id next-id}
                    executed-package-plan
                    executed-unit-plan
                    (execution:execute-unit-plan
                     (planning:plan-items unit-plan)
                     package-reports
                     next-id)
                    unit-reports
                    (planning:merge-executed-reports
                     planned-unit-reports
                     (get executed-unit-plan :reports))]
               (reporting:emit-report-logs "package" package-reports)
               (reporting:emit-report-message :executed :packages package-reports)
               (protocol:send-event
                :progress
                '(:phase :packages :step :executed :done 6 :total 10))
               (reporting:emit-report-logs "unit" unit-reports)
               (reporting:emit-report-message :executed :units unit-reports)
               (protocol:send-event
                :progress
                '(:phase :units :step :executed :done 7 :total 10))
               (protocol:send-event
                :progress
                '(:phase :reporting :step :reports-emitted :done 8 :total 10))
               (protocol:send-event
                :progress
                '(:phase :events :step :execution-recorded :done 9 :total 10))
               (protocol:send-event
                :progress
                '(:phase :shutdown :step :ready :done 10 :total 10))
               (emacs-hypervisor-send-shutdown
                '(:reason :hypervisor-session-complete)))))
         (emacs-hypervisor-handle-config-load-failure
          config-load-result
          config-file
          config-org-file))))))
