(elle/epoch 10)
## Shared execution helpers for package and unit runtime phases.

(defn emacs-hypervisor-execution-module [protocol graph mailbox benchmark]
  (defn eval-payload [form metric-name metric-kind phase item-name]
    (let [fields `(:form ,form)
          fields (benchmark:append-plist-field fields :metric-name metric-name)
          fields (benchmark:append-plist-field fields :metric-kind metric-kind)
          fields (benchmark:append-plist-field fields :phase phase)
          fields (benchmark:append-plist-field fields :item-name item-name)]
      (benchmark:eval-payload fields)))

  (defn send-eval-form-request [id form metric-name metric-kind phase item-name]
    (protocol:send-request id :eval (eval-payload form metric-name metric-kind phase item-name)))

  (defn eval-form [id form metric-name metric-kind phase item-name]
    (send-eval-form-request id form metric-name metric-kind phase item-name)
    (protocol:await-response mailbox id))

  (defn package-install-batch-form [names]
    (list 'emacs-hypervisor-runtime-install-package-batch (list 'quote names)))

  (defn unit-run-at-index-form [index]
    (list 'emacs-hypervisor-runtime-run-unit-at-index index))

  (defn execution-error [result]
    (protocol:response-error result))

  (defn execution-error-message [error]
    (if (nil? error)
      "eval failed"
      (case (type-of error)
        :string
          (or (first (string/split error "\n")) "eval failed")
        :keyword (concat ":" (string error))
        :integer (number->string error)
        :boolean (if error "true" "false")
        "eval failed")))

  (defn execution-ok? [result]
    (protocol:response-ok? result))

  (defn eval-execution-details [error]
    {:source :eval :error (execution-error-message error)})

  (defn report-state [next-id report]
    {:next-id next-id :report report})

  (defn blocked-report-state [name current-id reason blockers]
    (report-state current-id (graph:blocked-report name reason blockers)))

  (defn failed-eval-report [name error]
    (graph:make-report name :failed :execution (eval-execution-details error)))

  (defn eval-report-state [current-id name ok-report result]
    (report-state (+ current-id 1)
                  (if (execution-ok? result) ok-report (failed-eval-report name (execution-error result)))))

  (defn collect-report-state [items next-id next-state]
    (letrec [loop (fn [remaining current-id collected]
                    (if (empty? remaining)
                      {:next-id current-id :reports (reverse collected)}
                      (let [{:next-id next-id :report report} (next-state (first remaining) collected current-id)]
                        (loop (rest remaining) next-id (pair report collected)))))]
      (loop items next-id ())))

  (defn package-event-message? [message]
    (and (= (protocol:message-kind message) :event) (= (protocol:message-topic message) :package)))

  (defn drain-events-until-response [process-id]
    (letrec [loop (fn [package-events]
                    (let [message (protocol:read-message mailbox ":package event or :response")]
                      (if (and (= (protocol:message-kind message) :response)
                               (= (protocol:message-id message) process-id))
                        {:response message :package-events (reverse package-events)}
                        (loop (if (package-event-message? message)
                                (pair (protocol:from-wire (protocol:message-payload message)) package-events)
                                package-events)))))]
      (loop ())))

  (defn all-failed-batch-reports [names error]
    (map (fn [name] (failed-eval-report name error)) names))

  (defn package-event-kind [event]
    (graph:entry-field event :kind))

  (defn package-event-name [event]
    (graph:entry-field event :name))

  (defn package-event-reason [event]
    (graph:entry-field event :reason))

  (defn package-event-for-name [events name]
    (letrec [loop (fn [remaining found]
                    (match remaining
                      () found
                      (event & rest)
                        (loop rest (if (= (package-event-name event) name) event found))
                      _ found))]
      (loop events nil)))

  (defn package-events-with-kind [events kind]
    (filter (fn [event] (= (package-event-kind event) kind)) events))

  (defn package-installed-names [events]
    (map package-event-name (package-events-with-kind events :installed)))

  (defn package-failed-events [events]
    (package-events-with-kind events :failed))

  (defn planned-package-details [planned-reports name]
    (graph:entry-field (graph:find-entry planned-reports name) :details))

  (defn installed-package-report [name planned-reports]
    (graph:make-report name :ok :installed (planned-package-details planned-reports name)))

  (defn package-event-report [name planned-reports event fallback-error]
    (if (nil? event)
      (if (nil? fallback-error) nil (failed-eval-report name fallback-error))
      (match (package-event-kind event)
        :installed (installed-package-report name planned-reports)
        :failed
          (failed-eval-report name (or (package-event-reason event) fallback-error))
        _ nil)))

  (defn package-event-reports [names planned-reports events fallback-error]
    (graph:non-nil-values (map (fn [name]
                                 (package-event-report name planned-reports (package-event-for-name events name)
                                                       fallback-error)) names)))

  (defn unit-execution-details [entry]
    {:requires (graph:entry-field entry :requires) :after (graph:entry-field entry :after)})

  (defn executed-unit-report [name entry]
    (graph:make-report name :ok :executed (unit-execution-details entry)))

  (defn unit-run-form [name]
    (list 'emacs-hypervisor-runtime-run-unit name))

  (defn execute-unit-entry-state [name entry package-reports executed-unit-reports current-id]
    (let [package-blockers (graph:known-report-blockers package-reports (graph:entry-field entry :requires))
          unit-blockers (graph:report-blockers executed-unit-reports (graph:entry-field entry :after))]
      (match [(empty? package-blockers) (empty? unit-blockers)]
        [false _] (blocked-report-state name current-id :blocked-by-package package-blockers)
        [true false] (blocked-report-state name current-id :blocked-by-unit unit-blockers)
        _
          (let [result (eval-form current-id (unit-run-form name) :run-unit :unit :units name)]
            (eval-report-state current-id name (executed-unit-report name entry) result)))))

  (defn package-run-form [name]
    (list 'emacs-hypervisor-runtime-run-package name))

  (defn package-begin-form []
    (list 'emacs-hypervisor-runtime-begin-package-installation))

  (defn package-finished-form [reason]
    (list 'emacs-hypervisor-runtime-notify-packages-finished reason))

  (defn package-report-ok? [report]
    (= (graph:entry-field report :status) :ok))

  (defn package-reports-ok? [reports]
    (empty? (filter (fn [report] (not (package-report-ok? report))) reports)))

  (defn package-report-installed-names [reports]
    (map (fn [report] (graph:entry-name report)) (filter package-report-ok? reports)))

  ## Install one package per eval round-trip, like next-unit-plan-report,
  ## deriving the report from the eval response. Draining events keeps the
  ## per-package installed/failed events from accumulating in the mailbox.
  (defn next-package-plan-report [name planned-reports current-id]
    (let [_request-sent (send-eval-form-request current-id (package-run-form name) :install-package :package
                                                :packages name)
          drained (drain-events-until-response current-id)
          result (get drained :response)]
      (eval-report-state current-id name (installed-package-report name planned-reports) result)))

  ## Drive package installation one package at a time, like the unit plan, so
  ## Emacs returns to its event loop between packages and repaints the report.
  ## The phase begin and finished evals bracket the loop so the report opens
  ## and the installation metric is recorded exactly once.
  (defn execute-package-entry-plan-tracker [names planned-reports next-id]
    (if (empty? names)
      {:next-id next-id :reports () :installed () :ok true}
      (let [begin-id next-id
            _begin-sent (send-eval-form-request begin-id (package-begin-form) :begin-packages :package :packages nil)
            _begin-drained (drain-events-until-response begin-id)
            collected (collect-report-state names (+ begin-id 1)
                                            (fn [name _collected current-id]
                                              (next-package-plan-report name planned-reports current-id)))
            reports (get collected :reports)
            finished-id (get collected :next-id)
            _finished-sent (send-eval-form-request finished-id (package-finished-form "completed") :finished-packages
                                                   :package :packages nil)
            _finished-drained (drain-events-until-response finished-id)]
        {:next-id (+ finished-id 1)
         :reports reports
         :installed (package-report-installed-names reports)
         :ok (package-reports-ok? reports)})))

  (defn next-unit-execution-report [entry planned-report package-reports executed-unit-reports current-id]
    (let [name (graph:entry-name entry)
          planned-status (graph:entry-field planned-report :status)]
      (if (not (= planned-status :ok))
        {:next-id current-id :report planned-report}
        (execute-unit-entry-state name entry package-reports executed-unit-reports current-id))))

  (defn execute-units [units planned-reports package-reports next-id]
    (collect-report-state units next-id
                          (fn [entry executed-reports current-id]
                            (let [name (graph:entry-name entry)
                                  planned-report (graph:find-entry planned-reports name)]
                              (next-unit-execution-report entry planned-report package-reports executed-reports
                                                          current-id)))))

  (defn next-unit-plan-report [plan-item package-reports executed-unit-reports current-id]
    (let [name (graph:entry-field plan-item :name)
          entry (graph:entry-field plan-item :entry)
          planned-report (graph:entry-field plan-item :planned-report)
          planned-status (graph:entry-field planned-report :status)]
      (if (not (= planned-status :ok))
        {:next-id current-id :report planned-report}
        (let [index (graph:entry-field entry :index)
              _request-sent (send-eval-form-request current-id (unit-run-at-index-form index) :run-unit :unit
                                                    :units name)
              result (protocol:await-response mailbox current-id)]
          (eval-report-state current-id name (executed-unit-report name entry) result)))))

  (defn execute-unit-plan [plan-items package-reports next-id]
    (collect-report-state plan-items next-id
                          (fn [plan-item executed-reports current-id]
                            (next-unit-plan-report plan-item package-reports executed-reports current-id))))

  {:execute-package-entry-plan-tracker execute-package-entry-plan-tracker
   :execute-unit-plan execute-unit-plan
   :execute-units execute-units})
