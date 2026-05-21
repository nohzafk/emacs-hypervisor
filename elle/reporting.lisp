## Event-emission helpers for derived reports and bootstrap warnings.
##
## Policy modules (boot-policy, planning, execution) return data. This
## module is the only place report data turns into wire events.

(defn emacs-hypervisor-reporting-module [protocol policy]
  (defn emit-report-logs [label reports]
    (each {:status status :name name :reason reason :details details} in reports
      (when (not (= status :ok))
        (protocol:send-event
         :log
         `(:level :warn
           :message
           ,(string
             label
             " "
             name
             " -> "
             (string reason)
             " "
             (protocol:sexp-string (protocol:to-wire details))))))))

  (defn emit-report-message [stage phase reports]
    (protocol:send-report stage phase (protocol:to-wire reports)))

  (defn emit-bootstrap-warning [boot-context expected-hash]
    (if-let [warning (policy:bootstrap-warning boot-context expected-hash)]
      (protocol:send-event :warning (protocol:to-wire warning))
      nil))

  {:emit-bootstrap-warning emit-bootstrap-warning
   :emit-report-logs emit-report-logs
   :emit-report-message emit-report-message})
