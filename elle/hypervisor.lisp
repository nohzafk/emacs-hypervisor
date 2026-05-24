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

(defn emacs-hypervisor-runtime-module-manifest []
  (let [source (sys/env "EMACS_HYPERVISOR_EMBEDDED_RUNTIME_MODULES")]
    (assert source "expected embedded runtime module manifest")
    (read source)))

(defn emacs-hypervisor-config-load-failure-message [config-file config-org-file error]
  (string "config load failed for " (or config-org-file config-file "<unknown config>") ": " error))

(defn emacs-hypervisor-send-shutdown [payload]
  (protocol:send-event :shutdown payload)
  (sys/exit 0))

(defn emacs-hypervisor-handle-config-load-failure [config-load-result config-file config-org-file]
  (let* [config-error (or (protocol:response-error config-load-result) :unknown-error)
         config-source (or config-org-file config-file "<unknown config>")
         config-message (emacs-hypervisor-config-load-failure-message config-file config-org-file config-error)]
    (protocol:send-event :log `(:level :error :phase :startup :step :load-config :source ,config-source
                                       :message ,config-message :details ,config-error))
    (emacs-hypervisor-send-shutdown `(:reason :config-load-failed :status :failed :phase :startup :step :load-config
                                              :source ,config-source :message ,config-message :details ,config-error))))

(defn emacs-hypervisor-debug-value-summary [value]
  (if (nil? value)
    "nil"
    (let [kind (type-of value)]
      (case kind
        :string value
        :keyword (string ":" (string value))
        :symbol (string value)
        :integer (number->string value)
        :float (string value)
        :boolean (if value "true" "false")
        :list
          (string "<list len=" (number->string (length value)) ">")
        :array
          (string "<array len=" (number->string (length value)) ">")
        :@array
          (string "<@array len=" (number->string (length value)) ">")
        :struct "<struct>"
        :@struct "<@struct>"
        (string "<" (string kind) ">")))))

(defn emacs-hypervisor-debug-wire-string [value]
  (protocol:sexp-string (protocol:to-wire value)))

(defn emacs-hypervisor-debug-report-items [label reports limit]
  (letrec [loop (fn [remaining index]
                  (when (and (not (empty? remaining)) (< index limit))
                    (let [report (first remaining)]
                      (eprintln "[Hypervisor debug] report-item " label " index=" (number->string index) " type="
                                (emacs-hypervisor-debug-value-summary report) " raw="
                                (emacs-hypervisor-debug-wire-string report)))
                    (loop (rest remaining) (+ index 1))))]
    (loop reports 0)))

(defn emacs-hypervisor-debug-send-report [stage phase reports]
  (let [label (string "stage=" (emacs-hypervisor-debug-value-summary stage) " phase="
                      (emacs-hypervisor-debug-value-summary phase))]
    (eprintln "[Hypervisor debug] report-send " label " type=" (emacs-hypervisor-debug-value-summary reports) " count="
              (number->string (length reports)))
    (emacs-hypervisor-debug-report-items label reports 8)
    (protocol:send-report stage phase reports)))

(defn emacs-hypervisor-debug-package-items [packages limit]
  (letrec [loop (fn [remaining index]
                  (when (and (not (empty? remaining)) (< index limit))
                    (let [entry (first remaining)]
                      (eprintln "[Hypervisor debug] source-package index=" (number->string index) " type="
                                (emacs-hypervisor-debug-value-summary entry) " raw="
                                (emacs-hypervisor-debug-wire-string entry)))
                    (loop (rest remaining) (+ index 1))))]
    (loop packages 0)))

(protocol:with-mailbox-reader mailbox
                              (fn []
                                (protocol:send-request 1 :hello '(:mode :hypervisor-session))

                                (let [hello-response (protocol:await-response mailbox 1)]
                                  (assert (protocol:response-ok? hello-response) "expected successful :hello response")
                                  (let [{:protocol hello-protocol :version hello-version} (protocol:from-wire (protocol:message-payload hello-response))]
                                    (assert (= hello-protocol :sexp-rpc)
                                            "expected :sexp-rpc protocol in :hello response")
                                    (assert (= hello-version 1) "expected version 1 in :hello response")))

                                (protocol:send-request 2 :boot-context ())

                                (let* [boot-context-response (protocol:await-response mailbox 2)
                                       _ (assert (protocol:response-ok? boot-context-response)
                                                 "expected successful :boot-context response")
                                       boot-context (protocol:from-wire (protocol:message-payload boot-context-response))
                                       boot-session-name (get boot-context :session-name)
                                       boot-config-file (and (get boot-context :config-file)
                                       (string (get boot-context :config-file)))
                                       boot-config-org-file (and (get boot-context :config-org-file)
                                       (string (get boot-context :config-org-file)))
                                       boot-repo-dir (and (get boot-context :repo-dir)
                                                          (string (get boot-context :repo-dir)))
                                       boot-expected-init-hash (sys/env "EMACS_HYPERVISOR_EMBEDDED_INIT_HASH")
                                       runtime-module-manifest (emacs-hypervisor-runtime-module-manifest)
                                       config-file (or boot-config-file
                                                       (and boot-repo-dir (string boot-repo-dir "/config.el")))
                                       config-org-file boot-config-org-file
                                       _ (assert config-file "expected :config-file or :repo-dir in boot context")
                                       benchmark-enabled (and (not (nil? (get boot-context :benchmark-enabled)))
                                       (not (= (get boot-context :benchmark-enabled) false)))
                                       benchmark (emacs-hypervisor-benchmark-module protocol benchmark-enabled)
                                       preflight (emacs-hypervisor-preflight-module protocol graph mailbox benchmark)
                                       policy (emacs-hypervisor-boot-policy-module graph preflight)
                                       reporting (emacs-hypervisor-reporting-module protocol policy)
                                       planning (emacs-hypervisor-planning-module protocol graph)
                                       execution (emacs-hypervisor-execution-module protocol graph mailbox benchmark)
                                       session-name (or boot-session-name "hypervisor-session")]
                                  (reporting:emit-bootstrap-warning boot-context boot-expected-init-hash)
                                  (protocol:send-event :log `(:level :info :message "installing config surface"))
                                  (protocol:send-request 3
                                                         :eval (benchmark:eval-payload `(:form ,(runtime-forms:install-config-surface-form runtime-module-manifest)
                                                         :metric-name :install-config-surface :metric-kind
                                                         :runtime-setup :phase :startup)))
                                  (let [config-surface-result (protocol:await-response mailbox 3)]
                                    (assert (protocol:response-ok? config-surface-result)
                                            (string "config surface install should succeed: "
                                                    (or (protocol:response-error config-surface-result) :unknown-error))))
                                  (protocol:send-event :progress '(:phase :startup :step :config-surface-installed
                                                       :done 1 :total 10))
                                  (when config-org-file
                                    (protocol:send-event :log `(:level :info
                                                         :message "tangling literate config before loading config")))
                                  (let [config-load-payload (benchmark:eval-payload (list :form '(emacs-hypervisor-load-startup-config)
                                        :metric-name :load-config :metric-kind :runtime-setup :phase :startup))]
                                    (protocol:send-request 4 :eval config-load-payload))
                                  (let [config-load-result (protocol:await-response mailbox 4)]
                                    (if (protocol:response-ok? config-load-result)
                                      (begin
                                        (protocol:send-event :progress '(:phase :startup :step :config-loaded :done 2
                                        :total 10))
                                        (protocol:send-request 5 :session-data '(:fields (:packages :units :env)))
                                        (let* [session-data-response (protocol:await-response mailbox 5)
                                               _ (assert (protocol:response-ok? session-data-response)
                                                         "expected successful :session-data response")
                                               {:packages raw-packages :units raw-units :env raw-env} (protocol:from-wire-session-data (protocol:message-payload session-data-response))
                                               packages (or raw-packages ())
                                               units (or raw-units ())
                                               env (or raw-env ())
                                               session-analysis-started-at (clock/monotonic)
                                               {:reports planned-package-reports} (benchmark:measure :planning
                                               :derive-package-reports (fn [] (policy:derive-package-reports packages)))
                                               package-names (graph:known-names packages)
                                               {:reports executable-reports} (benchmark:measure :preflight
                                               :probe-executables (fn []
                                                 (preflight:probe-executables (preflight:units-with-executables units)
                                                 10 env)))
                                               {:reports planned-unit-reports} (benchmark:measure :planning
                                               :derive-unit-reports (fn []
                                                 (policy:derive-unit-reports units package-names planned-package-reports
                                                 env executable-reports)))
                                               package-plan (benchmark:measure :planning
                                               :derive-package-plan (fn []
                                                 (planning:derive-package-plan packages planned-package-reports)))
                                               unit-plan (benchmark:measure :planning
                                               :derive-unit-plan (fn []
                                                 (planning:derive-unit-plan units planned-unit-reports)))]
                                          (benchmark:emit-metric :planning
                                          :session-analysis-total (benchmark:elapsed-ms session-analysis-started-at) nil
                                          nil)
                                          (protocol:send-event :progress '(:phase :handshake :step :session-data-parsed
                                          :done 3 :total 10))
                                          (protocol:send-event :log `(:level :info
                                          :message "prepared session helper forms"))
                                          (protocol:send-request 6
                                          :eval (benchmark:eval-payload `(:form ,(runtime-forms:install-session-helpers-form runtime-module-manifest)
                                          :metric-name :install-session-helpers :metric-kind :runtime-setup :phase
                                          :startup)))
                                          (let [runtime-result (protocol:await-response mailbox 6)]
                                            (assert (protocol:response-ok? runtime-result)
                                                    (string "session helper install should succeed: "
                                                            (or (protocol:response-error runtime-result) :unknown-error))))
                                          (protocol:send-event :progress '(:phase :planning :step :policy-derived
                                          :done 4 :total 10))
                                          (eprintln "[Hypervisor debug] source packages count="
                                                    (number->string (length packages)))
                                          (emacs-hypervisor-debug-package-items packages 5)
                                          (emacs-hypervisor-debug-send-report :planned :packages planned-package-reports)
                                          (emacs-hypervisor-debug-send-report :planned :units planned-unit-reports)
                                          (planning:emit-plan-message package-plan)
                                          (planning:emit-plan-message unit-plan)
                                          (protocol:send-event :progress '(:phase :planning :step :plans-emitted :done 5
                                          :total 10))
                                          (let* [executed-package-plan (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
                                                 planned-package-reports 30)
                                                 package-reports (planning:merge-executed-reports planned-package-reports
                                                 (get executed-package-plan :reports))
                                                 {:next-id next-id} executed-package-plan
                                                 executed-unit-plan (execution:execute-unit-plan (planning:plan-items unit-plan)
                                                 package-reports next-id)
                                                 unit-reports (planning:merge-executed-reports planned-unit-reports
                                                 (get executed-unit-plan :reports))]
                                            (reporting:emit-report-logs "package" package-reports)
                                            (emacs-hypervisor-debug-send-report :executed :packages package-reports)
                                            (protocol:send-event :progress '(:phase :packages :step :executed :done 6
                                            :total 10))
                                            (reporting:emit-report-logs "unit" unit-reports)
                                            (emacs-hypervisor-debug-send-report :executed :units unit-reports)
                                            (protocol:send-event :progress '(:phase :units :step :executed :done 7
                                            :total 10))
                                            (protocol:send-event :progress '(:phase :reporting :step :reports-emitted
                                            :done 8 :total 10))
                                            (protocol:send-event :progress '(:phase :events :step :execution-recorded
                                            :done 9 :total 10))
                                            (protocol:send-event :progress '(:phase :shutdown :step :ready :done 10
                                            :total 10))
                                            (emacs-hypervisor-send-shutdown '(:reason :hypervisor-session-complete)))))
                                      (emacs-hypervisor-handle-config-load-failure config-load-result config-file
                                      config-org-file))))))
