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
(include-file "preflight.lisp")
(include-file "boot-policy.lisp")
(include-file "planning.lisp")
(include-file "execution.lisp")
(include-file "runtime-forms.lisp")

(def protocol (emacs-hypervisor-protocol-module))
(def mailbox (protocol:make-mailbox))
(def graph (emacs-hypervisor-graph-module protocol:plist-get))
(def preflight (emacs-hypervisor-preflight-module protocol graph mailbox))
(def policy (emacs-hypervisor-boot-policy-module protocol graph preflight))
(def planning (emacs-hypervisor-planning-module protocol graph))
(def execution (emacs-hypervisor-execution-module protocol graph mailbox))
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
     (let [hello-payload (protocol:message-payload hello-response)]
       (assert (= (protocol:plist-get hello-payload :protocol) :sexp-rpc)
               "expected :sexp-rpc protocol in :hello response")
       (assert (= (protocol:plist-get hello-payload :version) 1)
               "expected version 1 in :hello response")))

   (protocol:send-request 2 :boot-context ())

   (let* [boot-context-response (protocol:await-response mailbox 2)
          _ (assert (protocol:response-ok? boot-context-response)
                    "expected successful :boot-context response")
          boot-payload (protocol:message-payload boot-context-response)
          session-name
          (or (protocol:plist-get boot-payload :session-name)
              "hypervisor-session")]
     (protocol:send-request
      3
      :session-data
      '(:fields (:packages :units :env)))
     (let* [session-data-response (protocol:await-response mailbox 3)
            _ (assert (protocol:response-ok? session-data-response)
                      "expected successful :session-data response")
            payload (protocol:message-payload session-data-response)
            packages (protocol:plist-get payload :packages)
            units (protocol:plist-get payload :units)
            env (protocol:plist-get payload :env)
            package-resolution (policy:derive-package-reports packages)
            planned-package-reports (protocol:plist-get package-resolution :reports)
            package-names (graph:known-names packages)
            executable-probes
            (preflight:probe-executables
             (preflight:units-with-executables units)
             10)
            executable-reports (protocol:plist-get executable-probes :reports)
            unit-resolution
            (policy:derive-unit-reports
             units
             package-names
             planned-package-reports
             env
             executable-reports)
            planned-unit-reports (protocol:plist-get unit-resolution :reports)
            package-plan (planning:derive-package-plan packages planned-package-reports)
            unit-plan (planning:derive-unit-plan units planned-unit-reports)]
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
        `(:form ,(runtime-forms:install-session-helpers-form)))
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
               (protocol:plist-get executed-package-plan :reports))
              executed-unit-plan
              (execution:execute-unit-plan
               (planning:plan-items unit-plan)
               package-reports
               (protocol:plist-get executed-package-plan :next-id))
              unit-reports
              (planning:merge-executed-reports
               planned-unit-reports
               (protocol:plist-get executed-unit-plan :reports))]
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
