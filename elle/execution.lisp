## Shared execution helpers for package and unit runtime phases.

(defn emacs-hypervisor-execution-module [protocol graph mailbox]
  (def plist-get protocol:plist-get)

  (defn member? [xs value]
    (any? (fn [item] (= item value)) xs))

  (defn eval-form [id form]
    (protocol:send-request id :eval `(:form ,form))
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
      ((enabled fields)
       (append-recipe-fields recipe enabled fields))
      (_ recipe)))

  (defn package-entry-order [entry]
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

  (defn execution-error [result]
    (protocol:response-error result))

  (defn execution-ok? [result]
    (protocol:response-ok? result))

  (defn event-payload [event]
    (protocol:message-payload event))

  (defn eval-execution-details [error]
    (list :source :eval :error error))

  (defn queued-package-report? [report]
    (and (= (plist-get report :status) :ok)
         (= (plist-get report :reason) :queued)))

  (defn queued-package-entry-report [name entry]
    (graph:make-report
     name
     :ok
     :queued
     (graph:entry-field entry :deps)))

  (defn report-blockers [reports names]
    (filter
     (fn [name] (not (= (graph:report-status reports name) :ok)))
     names))

  (defn blocked-report [name reason blockers]
    (graph:make-report
     name
     :skipped
     reason
     (graph:blocker-details blockers)))

  (defn report-state [next-id report]
    (list :next-id next-id :report report))

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
             (list :next-id current-id :reports (reverse collected))
             (let [next (next-state (first remaining) collected current-id)]
               (loop
                (rest remaining)
                (plist-get next :next-id)
                (cons (plist-get next :report) collected)))))]
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

  (defn next-tracker-package-entry-plan-state [plan-item queued-package-reports current-id]
    (let* [entry (plist-get plan-item :entry)
           name (plist-get plan-item :name)
           order (package-entry-order entry)
           package-blockers
           (report-blockers queued-package-reports
                            (graph:entry-field entry :deps))]
      (cond
        ((not (empty? package-blockers))
         (blocked-report-state
          name
          current-id
          :blocked-by-package
          package-blockers))
        (true
         (let [queue-form (package-entry-queue-form name order)
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
                   :queued))]
           (eval-report-state
            current-id
            name
            (queued-package-entry-report name entry)
            queue-result))))))

  (defn queue-package-entry-plan [plan-items next-id]
    (collect-report-state
     plan-items
     next-id
     (fn [plan-item queued-reports current-id]
       (next-tracker-package-entry-plan-state
        plan-item
        queued-reports
        current-id))))

  (defn tracker-failure-details [reason]
    (match reason
      (nil
       (list :source :tracker :error :missing-install-callback))
      ("timeout"
       (list :source :tracker :error :timeout))
      ((:queue-start-error error)
       (list :source :queue :error error))
      (_
       (list
        :source :tracker
        :error :missing-install-callback
        :finished-reason reason))))

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
      (list
       :result process-result
       :installed (reverse installed)
       :reason finished-reason)
      nil))

  (defn tracker-process-result [process-id process-result message]
    (if (tracker-process-result-id? message process-id)
      message
      process-result))

  (defn advance-package-tracker-state
      [process-id installed finished-reason process-result message]
    (match [(protocol:message-kind message)
            (protocol:message-topic message)
            (event-payload message)]
      ([:event :package (:phase :packages :kind :installed :name name)]
       (collect-package-tracker-state
        process-id
        (tracker-installed installed name)
        finished-reason
        process-result))
      ([:event :package (:phase :packages :kind :finished & fields)]
       (collect-package-tracker-state
        process-id
        installed
        (plist-get fields :reason)
        process-result))
      ([:event :package (:phase :packages :kind :timeout & fields)]
       (collect-package-tracker-state
        process-id
        installed
        (or (plist-get fields :reason) "timeout")
        process-result))
      (_
       (collect-package-tracker-state
        process-id
        installed
        finished-reason
        (tracker-process-result process-id process-result message)))))

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
      [plan-item queued-package-reports final-package-reports installed-names finished-reason]
    (let* [entry (plist-get plan-item :entry)
           name (plist-get plan-item :name)
           queued-report (graph:find-entry queued-package-reports name)]
      (cond
        ((not (queued-package-report? queued-report))
         queued-report)
        ((member? installed-names name)
         (executed-package-report name entry))
        (true
         (let [package-blockers
               (report-blockers
                final-package-reports
                (graph:entry-field entry :deps))]
           (if (empty? package-blockers)
             (failed-package-report name finished-reason)
             (blocked-report name :blocked-by-package package-blockers)))))))

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
     (fn [plan-item]
       (queued-package-report?
        (graph:find-entry
         queued-package-reports
         (plist-get plan-item :name))))
     plan-items))

  (defn tracker-report-state [tracker-state]
    (let [process-result (plist-get tracker-state :result)]
      (if (execution-ok? process-result)
        tracker-state
        (list
         :installed ()
         :reason (list :queue-start-error (execution-error process-result))))))

  (defn unit-execution-details [entry]
    (list
     :requires (graph:entry-field entry :requires)
     :after (graph:entry-field entry :after)))

  (defn executed-unit-report [name entry]
    (graph:make-report
     name
     :ok
     :executed
     (unit-execution-details entry)))

  (defn execute-unit-entry-state
      [name entry package-reports executed-unit-reports current-id]
    (let [package-blockers
          (report-blockers package-reports (graph:entry-field entry :requires))
          unit-blockers
          (report-blockers executed-unit-reports (graph:entry-field entry :after))]
      (cond
        ((not (empty? package-blockers))
         (blocked-report-state
          name
          current-id
          :blocked-by-package
          package-blockers))
        ((not (empty? unit-blockers))
         (blocked-report-state
          name
          current-id
          :blocked-by-unit
          unit-blockers))
        (true
         (let [result
               (eval-form
                current-id
                `(emacs-hypervisor-runtime-run-unit
                  ,name
                  ,(graph:entry-field entry :body)
                  ',(graph:entry-field entry :requires)))]
           (eval-report-state
            current-id
            name
            (executed-unit-report name entry)
            result))))))

  (defn execute-package-entry-plan-tracker [plan-items next-id]
    (let* [queued-plan
           (queue-package-entry-plan plan-items next-id)
           queued-package-reports
           (plist-get queued-plan :reports)
           queued-plan-items
           (queued-tracker-plan-items plan-items queued-package-reports)
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
              report-state (tracker-report-state tracker-state)
              installed-names (plist-get report-state :installed)
              finished-reason (plist-get report-state :reason)]
          (list
           :next-id (+ process-id 1)
           :reports
           (derive-tracker-package-reports
            plan-items
            queued-package-reports
            installed-names
            finished-reason)
           :installed installed-names
           :finished-reason finished-reason)))))

  (defn next-unit-execution-report [entry planned-report package-reports executed-unit-reports current-id]
    (let [name (graph:entry-name entry)
          planned-status (plist-get planned-report :status)]
      (if (not (= planned-status :ok))
        (list :next-id current-id :report planned-report)
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

  (defn next-unit-plan-report [plan-item package-reports executed-unit-reports current-id]
    (let* [entry (plist-get plan-item :entry)
           name (plist-get plan-item :name)]
      (execute-unit-entry-state
       name
       entry
       package-reports
       executed-unit-reports
       current-id)))

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
