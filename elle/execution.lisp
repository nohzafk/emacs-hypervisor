## Shared execution helpers for package and unit runtime phases.

(defn emacs-hypervisor-execution-module [protocol graph]
  (def plist-get protocol:plist-get)

  (defn member? [xs value]
    (any? (fn [item] (= item value)) xs))

  (defn eval-form [id form]
    (protocol:send-request id :eval `(:form ,form))
    (protocol:await-response id))

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

  (defn package-entry->elpaca-order [entry]
    (let* [name (read (plist-get entry :name))
           host (plist-get entry :host)
           repo (plist-get entry :repo)
           repo-is-local (local-repo-string? repo)
           branch (plist-get entry :branch)
           tag (plist-get entry :tag)
           ref (plist-get entry :ref)
           files (plist-get entry :files)
           local (plist-get entry :local)
           no-compilation (plist-get entry :no-compilation)
           recipe ()
           recipe
           (if (and host (not repo-is-local))
             (append recipe `(:host ,(normalize-host host)))
             recipe)
           recipe
           (if (and repo (not repo-is-local) (nil? host))
             (append recipe '(:host github))
             recipe)
           recipe
           (if (and repo (not repo-is-local))
             (append recipe `(:repo ,repo))
             recipe)
           recipe
           (if branch
             (append recipe `(:branch ,branch))
             recipe)
           recipe
           (if tag
             (append recipe `(:tag ,tag))
             recipe)
           recipe
           (if ref
             (append recipe `(:ref ,ref))
             recipe)
           recipe
           (if files
             (append recipe `(:files ,files))
             recipe)
           recipe
           (if local
             (append recipe `(:repo ,(expand-home-path local)))
             recipe)
           recipe
           (if (and repo-is-local (not local))
             (append recipe `(:repo ,(expand-home-path repo)))
             recipe)
           recipe
           (if no-compilation
             (append recipe '(:build (:not elpaca--byte-compile)))
             recipe)]
      (if (empty? recipe)
        name
        (cons name recipe))))

  (defn package-entry->queue-form [name order]
    `(elpaca ,order
       (emacs-hypervisor-runtime-package-callback ,name)))

  (defn execution-error [result]
    (protocol:response-error result))

  (defn execution-ok? [result]
    (protocol:response-ok? result))

  (defn event-payload [event]
    (protocol:message-payload event))

  (defn event-status [event]
    (plist-get (event-payload event) :status))

  (defn event-error [event]
    (plist-get (event-payload event) :error))

  (defn event-phase [event]
    (plist-get (event-payload event) :phase))

  (defn event-kind [event]
    (plist-get (event-payload event) :kind))

  (defn event-name [event]
    (plist-get (event-payload event) :name))

  (defn event-reason [event]
    (plist-get (event-payload event) :reason))

  (defn eval-execution-details [error]
    (list :source :eval :error error))

  (defn package-event-execution-details [error]
    (list :source :package-event :error error))

  (defn await-package-tracker-event []
    (let [message (protocol:await-event-topic :package ":package event")]
      (if (and (= (event-phase message) :packages)
               (or (= (event-kind message) :installed)
                   (= (event-kind message) :finished)
                   (= (event-kind message) :timeout)))
        message
        (await-package-tracker-event))))

  (defn queued-package-report? [report]
    (and (= (plist-get report :status) :ok)
         (= (plist-get report :reason) :queued)))

  (defn next-tracker-package-entry-plan-state [plan-item queued-package-reports current-id]
    (let* [entry (plist-get plan-item :entry)
           name (plist-get plan-item :name)
           order (package-entry->elpaca-order entry)
           package-blockers
           (filter
            (fn [dep] (not (= (graph:report-status queued-package-reports dep) :ok)))
            (graph:entry-field entry :deps))]
      (if (not (empty? package-blockers))
        (list
         :next-id current-id
         :report
         (graph:make-report
          name
          :skipped
          :blocked-by-package
          (graph:blocker-details package-blockers)))
        (let* [queue-form (package-entry->queue-form name order)
               queue-result
               (eval-form
                current-id
                `(progn
                   (push
                    (list
                     :phase :packages
                     :event :attempt
                     :name ,name)
                    emacs-hypervisor-execution-events)
                   ,queue-form
                   :queued))
               next-id (+ current-id 1)]
          (if (execution-ok? queue-result)
            (list
             :next-id next-id
             :report
             (graph:make-report
              name
              :ok
              :queued
              (graph:entry-field entry :deps)))
            (list
             :next-id next-id
             :report
             (graph:make-report
              name
              :failed
              :execution
              (eval-execution-details (execution-error queue-result)))))))))

  (defn queue-package-entry-plan [plan-items next-id]
    (letrec
        [loop
         (fn [remaining current-id queued-reports]
           (if (empty? remaining)
             (list :next-id current-id :reports (reverse queued-reports))
             (let [next
                   (next-tracker-package-entry-plan-state
                    (first remaining)
                    queued-reports
                    current-id)]
               (loop
                (rest remaining)
                (plist-get next :next-id)
                (cons (plist-get next :report) queued-reports)))))]
      (loop plan-items next-id ())))

  (defn collect-package-tracker-events [installed]
    (let [message (await-package-tracker-event)]
      (if (= (event-kind message) :installed)
        (let [name (event-name message)]
          (collect-package-tracker-events
           (if (member? installed name)
             installed
             (cons name installed))))
        (list
         :installed (reverse installed)
         :reason (event-reason message)))))

  (defn tracker-failure-details [reason]
    (if (nil? reason)
      (list :source :tracker :error :missing-install-callback)
      (if (= reason "timeout")
        (list :source :tracker :error :timeout)
      (if (and (= (type-of reason) :list)
               (= (first reason) :queue-start-error))
        (list
         :source :queue
         :error (first (rest reason)))
        (list
         :source :tracker
         :error :missing-install-callback
         :finished-reason reason)))))

  (defn tracker-process-result-id? [message process-id]
    (and (= (protocol:message-kind message) :response)
         (= (protocol:message-id message) process-id)))

  (defn collect-package-tracker-state
      [process-id installed finished-reason process-result]
    (if (and process-result
             (or (not (execution-ok? process-result))
                 finished-reason))
      (list
       :result process-result
       :installed (reverse installed)
       :reason finished-reason)
      (let [message (protocol:read-message ":package event or :response")]
        (if (= (protocol:message-kind message) :event)
          (if (and (= (protocol:message-topic message) :package)
                   (= (event-phase message) :packages)
                   (= (event-kind message) :installed))
            (let [name (event-name message)]
              (collect-package-tracker-state
               process-id
               (if (member? installed name)
                 installed
                 (cons name installed))
               finished-reason
               process-result))
            (if (and (= (protocol:message-topic message) :package)
                     (= (event-phase message) :packages)
                     (= (event-kind message) :finished))
              (collect-package-tracker-state
               process-id
               installed
               (event-reason message)
               process-result)
              (if (and (= (protocol:message-topic message) :package)
                       (= (event-phase message) :packages)
                       (= (event-kind message) :timeout))
                (collect-package-tracker-state
                 process-id
                 installed
                 (or (event-reason message) "timeout")
                 process-result)
              (collect-package-tracker-state
               process-id
               installed
               finished-reason
               process-result))))
          (if (tracker-process-result-id? message process-id)
            (collect-package-tracker-state
             process-id
             installed
             finished-reason
             message)
            (collect-package-tracker-state
             process-id
             installed
             finished-reason
             process-result))))))

  (defn next-tracker-package-entry-report
      [plan-item queued-package-reports final-package-reports installed-names finished-reason]
    (let* [entry (plist-get plan-item :entry)
           name (plist-get plan-item :name)
           queued-report (graph:find-entry queued-package-reports name)]
      (if (not (queued-package-report? queued-report))
        queued-report
        (if (member? installed-names name)
          (graph:make-report
           name
           :ok
           :executed
           (graph:entry-field entry :deps))
          (let [package-blockers
                (filter
                 (fn [dep] (not (= (graph:report-status final-package-reports dep) :ok)))
                 (graph:entry-field entry :deps))]
            (if (not (empty? package-blockers))
              (graph:make-report
               name
               :skipped
               :blocked-by-package
               (graph:blocker-details package-blockers))
              (graph:make-report
               name
               :failed
               :execution
               (tracker-failure-details finished-reason))))))))

  (defn derive-tracker-package-reports
      [plan-items queued-package-reports installed-names finished-reason]
    (letrec
        [loop
         (fn [remaining final-package-reports]
           (if (empty? remaining)
             (reverse final-package-reports)
             (loop
              (rest remaining)
              (cons
               (next-tracker-package-entry-report
                (first remaining)
                queued-package-reports
                final-package-reports
                installed-names
                finished-reason)
               final-package-reports))))]
      (loop plan-items ())))

  (defn execute-package-entry-plan-tracker [plan-items next-id]
    (let* [queued-plan
           (queue-package-entry-plan plan-items next-id)
           queued-package-reports
           (plist-get queued-plan :reports)
           queued-plan-items
           (filter
            (fn [plan-item]
              (queued-package-report?
               (graph:find-entry
                queued-package-reports
                (plist-get plan-item :name))))
            plan-items)
           process-id
           (plist-get queued-plan :next-id)]
      (if (empty? queued-plan-items)
        (list
         :next-id process-id
         :reports queued-package-reports
         :installed ())
        (let [_
              (protocol:send-request
               process-id
               :eval
               `(:form (emacs-hypervisor-runtime-process-packages)))
              tracker-state
              (collect-package-tracker-state process-id () nil nil)
              process-result
              (plist-get tracker-state :result)]
          (if (execution-ok? process-result)
            (let* [installed-names
                   (plist-get tracker-state :installed)
                   finished-reason
                   (plist-get tracker-state :reason)]
              (list
               :next-id (+ process-id 1)
               :reports
               (derive-tracker-package-reports
                plan-items
                queued-package-reports
                installed-names
                finished-reason)
               :installed installed-names
               :finished-reason finished-reason))
            (list
             :next-id (+ process-id 1)
             :reports
             (derive-tracker-package-reports
              plan-items
              queued-package-reports
              ()
              (list :queue-start-error (execution-error process-result)))
             :installed ()))))))

  (defn next-unit-execution-report [entry planned-report package-reports executed-unit-reports current-id]
    (let [name (graph:entry-name entry)
          planned-status (plist-get planned-report :status)]
      (if (not (= planned-status :ok))
        (list :next-id current-id :report planned-report)
        (let [package-blockers
              (filter
               (fn [dep] (not (= (graph:report-status package-reports dep) :ok)))
               (graph:entry-field entry :requires))
              unit-blockers
              (filter
               (fn [dep] (not (= (graph:report-status executed-unit-reports dep) :ok)))
               (graph:entry-field entry :after))]
          (if (not (empty? package-blockers))
            (list
             :next-id current-id
             :report
             (graph:make-report
              name
              :skipped
              :blocked-by-package
              (graph:blocker-details package-blockers)))
            (if (not (empty? unit-blockers))
              (list
               :next-id current-id
               :report
               (graph:make-report
                name
                :skipped
                :blocked-by-unit
                (graph:blocker-details unit-blockers)))
              (let [result
                    (eval-form
                     current-id
                     `(emacs-hypervisor-runtime-run-unit
                       ,name
                       ,(graph:entry-field entry :body)
                       ',(graph:entry-field entry :requires)))
                    next-report
                    (if (execution-ok? result)
                      (graph:make-report
                       name
                       :ok
                       :executed
                       (list
                        :requires (graph:entry-field entry :requires)
                        :after (graph:entry-field entry :after)))
                      (graph:make-report
                       name
                       :failed
                       :execution
                       (eval-execution-details (execution-error result))))]
                (list :next-id (+ current-id 1) :report next-report))))))))

  (defn execute-units [units planned-reports package-reports next-id]
    (letrec
        [loop
         (fn [remaining current-id executed-reports]
           (if (empty? remaining)
             (list :next-id current-id :reports (reverse executed-reports))
             (let* [entry (first remaining)
                    name (graph:entry-name entry)
                    planned-report (graph:find-entry planned-reports name)
                    next
                    (next-unit-execution-report
                     entry
                     planned-report
                     package-reports
                     executed-reports
                     current-id)]
               (loop
                (rest remaining)
                (plist-get next :next-id)
                (cons (plist-get next :report) executed-reports)))))]
      (loop units next-id ())))

  (defn next-unit-plan-report [plan-item package-reports executed-unit-reports current-id]
    (let* [entry (plist-get plan-item :entry)
           name (plist-get plan-item :name)
           package-blockers
           (filter
            (fn [dep] (not (= (graph:report-status package-reports dep) :ok)))
            (graph:entry-field entry :requires))
           unit-blockers
           (filter
            (fn [dep] (not (= (graph:report-status executed-unit-reports dep) :ok)))
            (graph:entry-field entry :after))]
      (if (not (empty? package-blockers))
        (list
         :next-id current-id
         :report
         (graph:make-report
          name
          :skipped
          :blocked-by-package
          (graph:blocker-details package-blockers)))
        (if (not (empty? unit-blockers))
          (list
           :next-id current-id
           :report
           (graph:make-report
            name
            :skipped
            :blocked-by-unit
            (graph:blocker-details unit-blockers)))
          (let [result
                (eval-form
                 current-id
                 `(emacs-hypervisor-runtime-run-unit
                   ,name
                   ,(graph:entry-field entry :body)
                   ',(graph:entry-field entry :requires)))
                next-report
                (if (execution-ok? result)
                  (graph:make-report
                   name
                   :ok
                   :executed
                   (list
                    :requires (graph:entry-field entry :requires)
                    :after (graph:entry-field entry :after)))
                  (graph:make-report
                   name
                   :failed
                   :execution
                   (eval-execution-details (execution-error result))))]
            (list :next-id (+ current-id 1) :report next-report))))))

  (defn execute-unit-plan [plan-items package-reports next-id]
    (letrec
        [loop
         (fn [remaining current-id executed-reports]
           (if (empty? remaining)
             (list :next-id current-id :reports (reverse executed-reports))
             (let [next
                   (next-unit-plan-report
                    (first remaining)
                    package-reports
                    executed-reports
                    current-id)]
               (loop
                (rest remaining)
                (plist-get next :next-id)
                (cons (plist-get next :report) executed-reports)))))]
      (loop plan-items next-id ())))

  {:execute-package-entry-plan-tracker execute-package-entry-plan-tracker
   :execute-unit-plan execute-unit-plan
   :execute-units execute-units})
