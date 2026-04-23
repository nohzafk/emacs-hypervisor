## hypervisor.lisp
##
## Shared Hypervisor backend:
## 1. perform the standard handshake and session-data request
## 2. derive package and unit plans from the shared runtime modules
## 3. install transient session helpers inside Emacs
## 4. execute the real Elpaca tracker package phase
## 5. execute units and record reports back into Emacs

(include-file "protocol.lisp")
(include-file "graph.lisp")
(include-file "benchmark.lisp")
(include-file "preflight.lisp")
(include-file "boot-policy.lisp")
(include-file "planning.lisp")
(include-file "execution.lisp")
(include-file "runtime-forms.lisp")

(def protocol (emacs-hypervisor-protocol-module))
(def mailbox (protocol:make-mailbox))
(def graph (emacs-hypervisor-graph-module))
(def runtime-forms (emacs-hypervisor-runtime-forms-module))

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
          {:session-name boot-session-name & _boot-context}
          boot-context
          benchmark-enabled
          (not (= (get boot-context :benchmark-enabled) false))
          benchmark
          (emacs-hypervisor-benchmark-module protocol benchmark-enabled)
          preflight
          (emacs-hypervisor-preflight-module protocol graph mailbox benchmark)
          policy
          (emacs-hypervisor-boot-policy-module protocol graph preflight)
          planning
          (emacs-hypervisor-planning-module protocol graph)
          execution
          (emacs-hypervisor-execution-module protocol graph mailbox benchmark)
          session-name (or boot-session-name "hypervisor-session")]
     (protocol:send-request
      3
      :session-data
      '(:fields (:packages :units :env)))
     (let* [session-data-response (protocol:await-response mailbox 3)
            _ (assert (protocol:response-ok? session-data-response)
                      "expected successful :session-data response")
            {:packages packages :units units :env env}
            (protocol:from-wire (protocol:message-payload session-data-response))
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
         '(:phase :handshake :step :session-data-parsed :done 1 :total 8))
        (protocol:send-event
         :log
         `(:level :info
           :message ,(string "prepared session helper forms for " session-name)))
        (protocol:send-request
         4
         :eval
         (benchmark:eval-payload
          `(:form ,(runtime-forms:install-session-helpers-form)
            :metric-name :install-session-helpers
            :metric-kind :runtime-setup
            :phase :startup)))
        (let [runtime-result (protocol:await-response mailbox 4)]
          (assert (protocol:response-ok? runtime-result)
                  "session helper install should succeed"))
        (protocol:send-event
         :progress
         '(:phase :planning :step :policy-derived :done 2 :total 8))
        (policy:emit-report-message :planned :packages planned-package-reports)
        (policy:emit-report-message :planned :units planned-unit-reports)
        (policy:emit-report-logs "planned-package" planned-package-reports)
        (policy:emit-report-logs "planned-unit" planned-unit-reports)
        (planning:emit-plan-message package-plan)
        (planning:emit-plan-message unit-plan)
        (protocol:send-event
         :progress
         '(:phase :planning :step :plans-emitted :done 3 :total 8))
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
          (policy:emit-report-logs "package" package-reports)
          (policy:emit-report-message :executed :packages package-reports)
          (protocol:send-event
           :progress
           '(:phase :packages :step :executed :done 4 :total 8))
          (policy:emit-report-logs "unit" unit-reports)
          (policy:emit-report-message :executed :units unit-reports)
          (protocol:send-event
           :progress
           '(:phase :units :step :executed :done 5 :total 8))
          (protocol:send-event
           :progress
           '(:phase :reporting :step :reports-emitted :done 6 :total 8))
          (protocol:send-event
           :progress
           '(:phase :events :step :execution-recorded :done 7 :total 8))
          (protocol:send-event
           :progress
           '(:phase :shutdown :step :ready :done 8 :total 8))
          (protocol:send-event
           :shutdown
           '(:reason :hypervisor-session-complete)))))))
