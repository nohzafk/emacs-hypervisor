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

  (defn eval-form [id form metric-name metric-kind phase item-name]
    (protocol:send-request
     id
     :eval
     (eval-payload form metric-name metric-kind phase item-name))
    (protocol:await-response mailbox id))

  (defn package-entry-install-spec [entry]
    (let* [name (graph:entry-name entry)
           host (graph:entry-field entry :host)
           repo (graph:entry-field entry :repo)
           branch (graph:entry-field entry :branch)
           tag (graph:entry-field entry :tag)
           ref (graph:entry-field entry :ref)
           local (graph:entry-field entry :local)
           lisp-dir (graph:entry-field entry :lisp-dir)
           fields (list :name name)
           fields (benchmark:append-plist-field fields :repo repo)
           fields (benchmark:append-plist-field fields :host host)
           fields (benchmark:append-plist-field fields :branch branch)
           fields (benchmark:append-plist-field fields :tag tag)
           fields (benchmark:append-plist-field fields :ref ref)
           fields (benchmark:append-plist-field fields :local local)
           fields (benchmark:append-plist-field fields :lisp-dir lisp-dir)]
      fields))

  (defn package-install-batch-form [plan-items]
    (let [entries (map
                   (fn [{:entry entry}] (package-entry-install-spec entry))
                   plan-items)]
      (list 'emacs-hypervisor-runtime-install-package-batch
            (list 'quote entries))))

  (defn execution-error [result]
    (protocol:response-error result))

  (defn execution-ok? [result]
    (protocol:response-ok? result))

  (defn eval-execution-details [error]
    {:source :eval :error error})

  (defn batch-install-results [result]
    (protocol:from-wire (protocol:message-payload result)))

  (defn report-state [next-id report]
    {:next-id next-id
     :report report})

  (defn blocked-report-state [name current-id reason blockers]
    (report-state
     current-id
     (graph:blocked-report name reason blockers)))

  (defn failed-eval-report [name error]
    (graph:make-report
     name
     :failed
     :execution
     (eval-execution-details error)))

  (defn eval-report-state [current-id name ok-report result]
    (report-state
     (+ current-id 1)
     (if (execution-ok? result)
       ok-report
       (failed-eval-report name (execution-error result)))))

  (defn collect-report-state [items next-id next-state]
    (letrec
        [loop
         (fn [remaining current-id collected]
           (if (empty? remaining)
             {:next-id current-id :reports (reverse collected)}
             (let [{:next-id next-id :report report}
                   (next-state (first remaining) collected current-id)]
               (loop
                (rest remaining)
                next-id
                (pair report collected)))))]
      (loop items next-id ())))

  (defn collect-reports [items next-report]
    (letrec
        [loop
         (fn [remaining collected]
           (if (empty? remaining)
             (reverse collected)
             (loop
              (rest remaining)
              (pair (next-report (first remaining) collected) collected))))]
      (loop items ())))

  (defn executed-package-report [name entry]
    (graph:make-report
     name
     :ok
     :executed
     (graph:entry-field entry :deps)))

  (defn drain-events-until-response [process-id]
    (let [message (protocol:read-message mailbox ":package event or :response")]
      (if (and (= (protocol:message-kind message) :response)
               (= (protocol:message-id message) process-id))
        message
        (drain-events-until-response process-id))))

  (defn batch-result-status [batch-result]
    (and batch-result (get batch-result :status)))

  (defn batch-installed-names [batch-results]
    (map
     (fn [r] (get r :name))
     (filter
      (fn [r] (= (batch-result-status r) :installed))
      batch-results)))

  (defn batch-package-report [plan-item batch-results final-reports]
    (let* [{:entry entry :name name} plan-item
           batch-result (graph:find-entry batch-results name)
           status (batch-result-status batch-result)]
      (match status
        :installed
         (executed-package-report name entry)
        :failed
         (let [deps (graph:entry-field entry :deps)
               blockers (graph:report-blockers final-reports deps)]
           (if (empty? blockers)
             (failed-eval-report
              name
              (get batch-result :error "install failed"))
             (graph:blocked-report name :blocked-by-package blockers)))
        _
         (failed-eval-report name "missing install result"))))

  (defn derive-batch-package-reports [plan-items batch-results]
    (collect-reports
     plan-items
     (fn [plan-item final-reports]
       (batch-package-report plan-item batch-results final-reports))))

  (defn all-failed-batch-reports [plan-items error]
    (map
     (fn [{:name name}] (failed-eval-report name error))
     plan-items))

  (defn unit-execution-details [entry]
    {:requires (graph:entry-field entry :requires)
     :after (graph:entry-field entry :after)})

  (defn executed-unit-report [name entry]
    (graph:make-report
     name
     :ok
     :executed
     (unit-execution-details entry)))

  (defn unit-run-form [entry]
    `(emacs-hypervisor-runtime-run-unit
      ,(graph:entry-name entry)
      ,(list 'quote (graph:entry-field entry :body))
      ,(list 'quote (graph:entry-field entry :requires))))

  (defn execute-unit-entry-state
      [name entry package-reports executed-unit-reports current-id]
    (let [package-blockers
          (graph:known-report-blockers package-reports (graph:entry-field entry :requires))
          unit-blockers
          (graph:report-blockers executed-unit-reports (graph:entry-field entry :after))]
      (match [(empty? package-blockers) (empty? unit-blockers)]
        [false _]
         (blocked-report-state
          name
          current-id
          :blocked-by-package
          package-blockers)
        [true false]
         (blocked-report-state
          name
          current-id
          :blocked-by-unit
          unit-blockers)
        _
         (let [result
               (eval-form
                current-id
                (unit-run-form entry)
                :run-unit
                :unit
                :units
                name)]
           (eval-report-state
            current-id
            name
            (executed-unit-report name entry)
            result)))))

  (defn execute-package-entry-plan-tracker [plan-items next-id]
    (if (empty? plan-items)
      {:next-id next-id :reports () :installed ()}
      (let [process-id next-id
            _ (protocol:send-request
               process-id
               :eval
               (eval-payload
                (package-install-batch-form plan-items)
                :install-package-batch
                :package-install
                :packages
                nil))
            result (drain-events-until-response process-id)]
        (if (execution-ok? result)
          (let [batch-results (batch-install-results result)
                reports (derive-batch-package-reports plan-items batch-results)
                installed (batch-installed-names batch-results)]
            {:next-id (+ process-id 1)
             :reports reports
             :installed installed})
          {:next-id (+ process-id 1)
           :reports (all-failed-batch-reports plan-items (execution-error result))
           :installed ()}))))

  (defn next-unit-execution-report [entry planned-report package-reports executed-unit-reports current-id]
    (let [name (graph:entry-name entry)
          planned-status (get planned-report :status)]
      (if (not (= planned-status :ok))
        {:next-id current-id :report planned-report}
        (execute-unit-entry-state
         name
         entry
         package-reports
         executed-unit-reports
         current-id))))

  (defn execute-units [units planned-reports package-reports next-id]
    (collect-report-state
     units
     next-id
     (fn [entry executed-reports current-id]
       (let [name (graph:entry-name entry)
             planned-report (graph:find-entry planned-reports name)]
         (next-unit-execution-report
          entry
          planned-report
          package-reports
          executed-reports
          current-id)))))

  (defn next-unit-plan-report
      [{:entry entry :name name} package-reports executed-unit-reports current-id]
    (execute-unit-entry-state
     name
     entry
     package-reports
     executed-unit-reports
     current-id))

  (defn execute-unit-plan [plan-items package-reports next-id]
    (collect-report-state
     plan-items
     next-id
     (fn [plan-item executed-reports current-id]
       (next-unit-plan-report
        plan-item
        package-reports
        executed-reports
        current-id))))

  {:execute-package-entry-plan-tracker execute-package-entry-plan-tracker
   :execute-unit-plan execute-unit-plan
   :execute-units execute-units})
