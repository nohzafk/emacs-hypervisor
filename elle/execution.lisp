## Shared execution helpers for package and unit runtime phases.

(defn emacs-hypervisor-execution-module [protocol graph mailbox benchmark]

  (defn member? [xs value]
    (any? (fn [item] (= item value)) xs))

  (defn append-plist-field [fields key value]
    (if value
      (append fields (list key value))
      fields))

  (defn eval-payload [form metric-name metric-kind phase item-name]
    (let [fields `(:form ,form)
          fields (append-plist-field fields :metric-name metric-name)
          fields (append-plist-field fields :metric-kind metric-kind)
          fields (append-plist-field fields :phase phase)
          fields (append-plist-field fields :item-name item-name)]
      (benchmark:eval-payload fields)))

  (defn eval-form [id form metric-name metric-kind phase item-name]
    (protocol:send-request
     id
     :eval
     (eval-payload form metric-name metric-kind phase item-name))
    (protocol:await-response mailbox id))

  (defn local-repo-string? [repo]
    (and (= (type-of repo) :string)
         (or (string/starts-with? repo "/")
             (string/starts-with? repo "~")
             (string/starts-with? repo "./")
             (string/starts-with? repo "../"))))

  (defn expand-home-path [path]
    (if (and (= (type-of path) :string)
             (string/starts-with? path "~/"))
      (if-let [home (sys/env "HOME")]
        (string home "/" (slice path 2))
        path)
      path))

  (defn normalize-host [host]
    (if (= (type-of host) :string)
      (read host)
      host))

  (defn append-recipe-fields [recipe enabled? fields]
    (if enabled?
      (append recipe fields)
      recipe))

  (defn append-recipe-spec [recipe spec]
    (match spec
      (enabled fields)
       (append-recipe-fields recipe enabled fields)
      _ recipe))

  (defn package-entry-order [entry]
    (let* [{:name name-string
            :host host
            :repo repo
            :branch branch
            :tag tag
            :ref ref
            :files files
            :local local
            :no-compilation no-compilation}
           entry
           name (read name-string)
           repo-is-local (local-repo-string? repo)
           recipe-specs
           (list
            (list
             (and host (not repo-is-local))
             `(:host ,(normalize-host host)))
            (list
             (and repo (not repo-is-local) (nil? host))
             '(:host github))
            (list
             (and repo (not repo-is-local))
             `(:repo ,repo))
            (list branch `(:branch ,branch))
            (list tag `(:tag ,tag))
            (list ref `(:ref ,ref))
            (list files `(:files ,files))
            (list local `(:repo ,(expand-home-path local)))
            (list
             (and repo-is-local (not local))
             `(:repo ,(expand-home-path repo)))
            (list
             no-compilation
             '(:build (:not elpaca--byte-compile))))
           recipe
           (reduce append-recipe-spec () recipe-specs)]
        (if (empty? recipe)
          name
          (cons name recipe))))

  (defn package-entry-queue-form [name order]
    `(elpaca ,order
       (emacs-hypervisor-runtime-package-callback ,name)))

  (defn package-entry-queue-step-form [name order]
    `(condition-case err
       (progn
         (push
          (list
           :phase :packages
           :event :attempt
           :name ,name)
          emacs-hypervisor-execution-events)
         ,(package-entry-queue-form name order)
         (push
          (list :name ,name :status :queued)
          emacs-hypervisor-batch-queue-results))
       (error
        (push
         (list :name ,name :status :failed :error (format "%S" err))
         emacs-hypervisor-batch-queue-results))))

  (defn package-queue-batch-form [plan-items]
    (append
     '(let ((emacs-hypervisor-batch-queue-results ())))
     (append
      '((emacs-hypervisor-runtime-ensure-package-manager))
      (append
       (map
        (fn [{:entry entry :name name}]
          (package-entry-queue-step-form
           name
           (package-entry-order entry)))
        plan-items)
       '((nreverse emacs-hypervisor-batch-queue-results))))))

  (defn execution-error [result]
    (protocol:response-error result))

  (defn execution-ok? [result]
    (protocol:response-ok? result))

  (defn event-payload [event]
    (protocol:from-wire (protocol:message-payload event)))

  (defn eval-execution-details [error]
    {:source :eval :error error})

  (defn queued-package-report? [report]
    (and (= (get report :status) :ok)
         (= (get report :reason) :queued)))

  (defn queued-package-entry-report [name entry]
    (graph:make-report
     name
     :ok
     :queued
     (graph:entry-field entry :deps)))

  (defn ordered-plan-reports [plan-items reports]
    (map
     (fn [{:name name}]
       (graph:find-entry reports name))
     plan-items))

  (defn package-plan-item-blockers [{:entry entry} queued-package-reports]
    (report-blockers
     queued-package-reports
     (graph:entry-field entry :deps)))

  (defn queueable-plan-items [plan-items queued-package-reports]
    (filter
     (fn [plan-item]
       (empty?
        (package-plan-item-blockers
         plan-item
         queued-package-reports)))
     plan-items))

  (defn remove-plan-items [plan-items removed-plan-items]
    (let [removed-names (map (fn [{:name name}] name) removed-plan-items)]
      (filter
       (fn [{:name name}]
         (not (member? removed-names name)))
       plan-items)))

  (defn blocked-package-entry-report
      [{:entry entry :name name} queued-package-reports]
    (blocked-report
     name
     :blocked-by-package
     (package-plan-item-blockers
      {:entry entry :name name}
      queued-package-reports)))

  (defn queued-package-batch-results [result]
    (protocol:from-wire (protocol:message-payload result)))

  (defn queued-package-batch-entry [queue-results name]
    (graph:find-entry queue-results name))

  (defn queued-package-batch-report
      [{:entry entry :name name} queue-results]
    (if-let [queue-result (queued-package-batch-entry queue-results name)]
      (if (= (get queue-result :status) :queued)
        (queued-package-entry-report name entry)
        (failed-eval-report
         name
         (get queue-result :error "missing queue error")))
      (failed-eval-report name "missing queue result")))

  (defn queue-ready-package-batch-state [ready-plan-items current-id]
    (let [queue-result
          (eval-form
           current-id
           (package-queue-batch-form ready-plan-items)
           :queue-package-batch
           :package-queue
           :packages
           nil)]
      (if (execution-ok? queue-result)
        (let [queue-results (queued-package-batch-results queue-result)]
          {:next-id (+ current-id 1)
           :reports
           (map
            (fn [plan-item]
              (queued-package-batch-report
               plan-item
               queue-results))
            ready-plan-items)})
        {:next-id (+ current-id 1)
         :reports
         (map
          (fn [{:name name}]
            (failed-eval-report name (execution-error queue-result)))
          ready-plan-items)})))

  (defn report-blockers [reports names]
    (filter
     (fn [name] (not (= (graph:report-status reports name) :ok)))
     names))

  (defn known-report-blockers [reports names]
    (filter
     (fn [name]
       (if-let [report (graph:find-entry reports name)]
         (not (= (get report :status) :ok))
         false))
     names))

  (defn blocked-report [name reason blockers]
    (graph:make-report
     name
     :skipped
     reason
     (graph:blocker-details blockers)))

  (defn report-state [next-id report]
    {:next-id next-id
     :report report})

  (defn blocked-report-state [name current-id reason blockers]
    (report-state
     current-id
     (blocked-report name reason blockers)))

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
                (cons report collected)))))]
      (loop items next-id ())))

  (defn collect-reports [items next-report]
    (letrec
        [loop
         (fn [remaining collected]
           (if (empty? remaining)
             (reverse collected)
             (loop
              (rest remaining)
              (cons (next-report (first remaining) collected) collected))))]
      (loop items ())))

  (defn queue-package-entry-plan [plan-items next-id]
    (letrec
        [loop
         (fn [remaining current-id queued-reports]
           (if (empty? remaining)
             {:next-id current-id
              :reports (ordered-plan-reports plan-items queued-reports)}
             (let [ready-plan-items
                   (queueable-plan-items remaining queued-reports)]
               (if (empty? ready-plan-items)
                 {:next-id current-id
                  :reports
                  (ordered-plan-reports
                   plan-items
                   (append
                    (map
                     (fn [plan-item]
                       (blocked-package-entry-report
                        plan-item
                        queued-reports))
                     remaining)
                    queued-reports))}
                 (let [{:next-id next-id :reports ready-reports}
                       (queue-ready-package-batch-state
                        ready-plan-items
                        current-id)]
                   (loop
                    (remove-plan-items remaining ready-plan-items)
                    next-id
                    (append ready-reports queued-reports)))))))]
      (loop plan-items next-id ())))

  (defn tracker-failure-details [reason]
    (match reason
      nil
       {:source :tracker :error :missing-install-callback}
      "timeout"
       {:source :tracker :error :timeout}
      (:queue-start-error error)
       {:source :queue :error error}
      _
       {:source :tracker
        :error :missing-install-callback
        :finished-reason reason}))

  (defn tracker-process-result-id? [message process-id]
    (and (= (protocol:message-kind message) :response)
         (= (protocol:message-id message) process-id)))

  (defn tracker-installed [installed name]
    (if (member? installed name)
      installed
      (cons name installed)))

  (defn tracker-state [installed finished-reason process-result]
    (if (and process-result
             (or (not (execution-ok? process-result))
                 finished-reason))
      {:result process-result
       :installed (reverse installed)
       :reason finished-reason}
      nil))

  (defn tracker-process-result [process-id process-result message]
    (if (tracker-process-result-id? message process-id)
      message
      process-result))

  (defn advance-package-tracker-state
      [process-id installed finished-reason process-result message]
    (if (and (= (protocol:message-kind message) :event)
             (= (protocol:message-topic message) :package))
      (let [payload (event-payload message)
            name (get payload :name)
            reason (get payload :reason)]
        (match [(get payload :phase) (get payload :kind)]
          [:packages :installed]
           (collect-package-tracker-state
            process-id
            (tracker-installed installed name)
            finished-reason
            process-result)
          [:packages :finished]
           (collect-package-tracker-state
            process-id
            installed
            reason
            process-result)
          [:packages :timeout]
           (collect-package-tracker-state
            process-id
            installed
            (or reason "timeout")
            process-result)
          _
           (collect-package-tracker-state
            process-id
            installed
            finished-reason
            process-result)))
      (collect-package-tracker-state
       process-id
       installed
       finished-reason
       (tracker-process-result process-id process-result message))))

  (defn collect-package-tracker-state
      [process-id installed finished-reason process-result]
    (if-let [state (tracker-state installed finished-reason process-result)]
      state
      (advance-package-tracker-state
       process-id
       installed
       finished-reason
       process-result
       (protocol:read-message mailbox ":package event or :response"))))

  (defn executed-package-report [name entry]
    (graph:make-report
     name
     :ok
     :executed
     (graph:entry-field entry :deps)))

  (defn failed-package-report [name finished-reason]
    (graph:make-report
     name
     :failed
     :execution
     (tracker-failure-details finished-reason)))

  (defn next-tracker-package-entry-report
      [{:entry entry :name name}
       queued-package-reports
       final-package-reports
       installed-names
       finished-reason]
    (let [queued-report (graph:find-entry queued-package-reports name)]
      (match [(queued-package-report? queued-report)
              (member? installed-names name)]
        [false _]
         queued-report
        [true true]
         (executed-package-report name entry)
        _
         (let [package-blockers
               (report-blockers
                final-package-reports
                (graph:entry-field entry :deps))]
           (match (empty? package-blockers)
             true
              (failed-package-report name finished-reason)
             _
              (blocked-report name :blocked-by-package package-blockers))))))

  (defn derive-tracker-package-reports
      [plan-items queued-package-reports installed-names finished-reason]
    (collect-reports
     plan-items
     (fn [plan-item final-package-reports]
       (next-tracker-package-entry-report
        plan-item
        queued-package-reports
        final-package-reports
        installed-names
        finished-reason))))

  (defn queued-tracker-plan-items [plan-items queued-package-reports]
    (filter
     (fn [{:name name}]
       (queued-package-report?
        (graph:find-entry
         queued-package-reports
         name)))
     plan-items))

  (defn tracker-report-state [{:result process-result :installed installed :reason reason}]
    (let [queue-start-error (list :queue-start-error (execution-error process-result))]
      (if (execution-ok? process-result)
        {:result process-result
         :installed installed
         :reason reason}
        {:installed installed
         :reason (or reason queue-start-error)})))

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
          (known-report-blockers package-reports (graph:entry-field entry :requires))
          unit-blockers
          (report-blockers executed-unit-reports (graph:entry-field entry :after))]
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
    (let [{:reports queued-package-reports :next-id process-id}
          (queue-package-entry-plan plan-items next-id)
          queued-plan-items
          (queued-tracker-plan-items plan-items queued-package-reports)]
      (if (empty? queued-plan-items)
        {:next-id process-id
         :reports queued-package-reports
         :installed ()}
         (let [_
              (protocol:send-request
               process-id
               :eval
               (eval-payload
                '(emacs-hypervisor-runtime-process-packages)
                :process-packages
                :package-start
                :packages
                nil))
              tracker-state
              (collect-package-tracker-state process-id () nil nil)
              {:installed installed-names :reason finished-reason}
              (tracker-report-state tracker-state)]
          {:next-id (+ process-id 1)
           :reports
           (derive-tracker-package-reports
            plan-items
            queued-package-reports
            installed-names
            finished-reason)
           :installed installed-names
           :finished-reason finished-reason}))))

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
