(elle/epoch 10)
## Event-emission helpers for derived reports and bootstrap warnings.
##
## Policy modules (boot-policy, planning, execution) return data. This
## module is the only place report data turns into wire events.

(defn emacs-hypervisor-reporting-module [protocol policy]
  (defn report-field [report key]
    (case (type-of report)
      :struct (get report key)
      :@struct (get report key)
      :list (protocol:plist-get report key)
      nil))

  (defn non-ok-reports [reports]
    (filter (fn [report] (not (= (report-field report :status) :ok))) reports))

  (defn report-log-message [label count total]
    (string label " reports not ok: " (number->string count) " of " (number->string total)))

  (defn emit-report-logs [label reports]
    (let [non-ok (non-ok-reports reports)]
      (when (not (empty? non-ok))
        (protocol:send-event :log `(:level :warn :message ,(report-log-message label (length non-ok) (length reports))
                                           :count ,(length non-ok) :total ,(length reports))))))

  (defn emit-report-message [stage phase reports]
    (protocol:send-report stage phase reports))

  (defn emit-bootstrap-warning [boot-context expected-hash]
    (if-let [warning (policy:bootstrap-warning boot-context expected-hash)] (protocol:send-event :warning warning) nil))

  {:emit-bootstrap-warning emit-bootstrap-warning
   :emit-report-logs emit-report-logs
   :emit-report-message emit-report-message})
