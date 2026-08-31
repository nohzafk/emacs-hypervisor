(elle/epoch 12)
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

  (defn failed-eval-report [name error source-entry]
    (graph:report-with-source (graph:make-report name :failed :execution (eval-execution-details error)) source-entry))

  (defn eval-report-state [current-id name ok-report result source-entry]
    (report-state (+ current-id 1)
                  (if (execution-ok? result) ok-report (failed-eval-report name (execution-error result) source-entry))))

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

  (defn planned-package-details [planned-reports name]
    (graph:entry-field (graph:find-entry planned-reports name) :details))

  (defn installed-package-report [name planned-reports]  ## The planned report already carries the declaration's :source; copy it
    ## forward so executed reports keep provenance.
    (graph:report-with-source (graph:make-report name :ok :installed (planned-package-details planned-reports name))
                              (graph:find-entry planned-reports name)))

  (defn unit-execution-details [entry]
    {:requires (graph:entry-field entry :requires) :after (graph:entry-field entry :after)})

  (defn executed-unit-report [name entry]
    (graph:report-with-source (graph:make-report name :ok :executed (unit-execution-details entry)) entry))

  ## Split a comma-separated package list from an env var, trimming
  ## whitespace around each name and dropping empty entries so values like
  ## "magit, transient" match their packages.
  (defn parse-package-list-value [value]
    (if (nil? value)
      ()
      (->list (filter (fn [x] (not (= x ""))) (map string/trim (string/split value ","))))))

  (defn env-package-list-member? [env-name name]
    (let [env-value (sys/env env-name)]
      (or (= env-value "all") (graph:member? (parse-package-list-value env-value) name))))

  (defn package-run-form [name]
    (if (env-package-list-member? "EMACS_HYPERVISOR_UPGRADE_PACKAGES" name)
      (list 'emacs-hypervisor-runtime-upgrade-package name)
      (if (env-package-list-member? "EMACS_HYPERVISOR_REBUILD_PACKAGES" name)
        (list 'emacs-hypervisor-runtime-rebuild-package name)
        (list 'emacs-hypervisor-runtime-run-package name))))

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
      (eval-report-state current-id name (installed-package-report name planned-reports) result
                         (graph:find-entry planned-reports name))))

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

  ## Packages that were planned :ok can still fail at install time; a unit
  ## requiring one of them must be skipped instead of failing opaquely inside
  ## Emacs. Only names with an actual package report gate the unit — plain
  ## Emacs features in :requires are unaffected.
  (defn package-blocked-report [name entry package-reports]
    (let [blockers (graph:known-report-blockers package-reports (graph:entry-field entry :requires))]
      (if (empty? blockers)
        nil
        (graph:report-with-source (graph:blocked-report name :blocked-by-package blockers) entry))))

  (defn next-unit-plan-report [plan-item package-reports current-id]
    (let [name (graph:entry-field plan-item :name)
          entry (graph:entry-field plan-item :entry)
          planned-report (graph:entry-field plan-item :planned-report)
          planned-status (graph:entry-field planned-report :status)]
      (if (not (= planned-status :ok))
        {:next-id current-id :report planned-report}
        (if-let [blocked-report (package-blocked-report name entry package-reports)]
                {:next-id current-id :report blocked-report}
                (let [index (graph:entry-field entry :index)
                      _request-sent (send-eval-form-request current-id (unit-run-at-index-form index) :run-unit :unit
                                                            :units name)
                      result (protocol:await-response mailbox current-id)]
                  (eval-report-state current-id name (executed-unit-report name entry) result entry))))))

  (defn execute-unit-plan [plan-items package-reports next-id]
    (collect-report-state plan-items next-id
                          (fn [plan-item _collected current-id]
                            (next-unit-plan-report plan-item package-reports current-id))))

  {:execute-package-entry-plan-tracker execute-package-entry-plan-tracker
   :execute-unit-plan execute-unit-plan
   :parse-package-list-value parse-package-list-value})
