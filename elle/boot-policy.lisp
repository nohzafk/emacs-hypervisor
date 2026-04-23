## Shared boot-policy helpers built on graph + preflight modules.

(defn emacs-hypervisor-boot-policy-module [protocol graph preflight]
  (def plist-get protocol:plist-get)

  (defn blocked-deps [reports names]
    (filter
     (fn [dep] (not (= (graph:report-status reports dep) :ok)))
     names))

  (defn blocked-report [name reason blockers]
    (graph:make-report
     name
     :skipped
     reason
     (graph:blocker-details blockers)))

  (defn ready-package-report [entry]
    (graph:make-report
     (graph:entry-name entry)
     :ok
     :ready
     (graph:entry-field entry :deps)))

  (defn ready-unit-report [entry]
    (graph:make-report
     (graph:entry-name entry)
     :ok
     :ready
     (list
      :requires (graph:entry-field entry :requires)
      :after (graph:entry-field entry :after))))

  (defn preflight-report [entry env-missing executable-missing]
    (graph:make-report
     (graph:entry-name entry)
     :skipped
     :preflight
     (graph:preflight-details env-missing executable-missing)))

  (defn invalid-reports [entries invalid-report]
    (graph:non-nil-values (map invalid-report entries)))

  (defn derive-phase-reports [entries invalid-reports ready? next-report]
    (let [remaining-entries
          (graph:non-invalid-entries entries invalid-reports)
          unordered-reports
          (graph:resolve-reports-loop
           remaining-entries
           invalid-reports
           ready?
           next-report)]
      (graph:ordered-reports entries unordered-reports)))

  (defn next-package-report [entry reports]
    (let [blockers (blocked-deps reports (graph:entry-field entry :deps))]
      (if (empty? blockers)
        (ready-package-report entry)
        (blocked-report
         (graph:entry-name entry)
         :blocked-by-package
         blockers))))

  (defn derive-package-reports [packages]
    (let [package-names (graph:known-names packages)
          package-missing
          (graph:collect-missing-ref-entries packages :deps package-names)
          package-cycles (graph:cycle-names packages :deps package-names)
          invalid-package-reports
          (invalid-reports
           packages
           (fn [entry]
             (graph:invalid-package-report entry package-missing package-cycles)))]
      (list
       :cycles package-cycles
       :missing package-missing
       :reports
       (derive-phase-reports
        packages
        invalid-package-reports
        (fn [entry reports]
          (graph:all-known? (graph:entry-field entry :deps) reports))
        next-package-report))))

  (defn next-unit-report [entry reports package-reports env executable-reports]
    (let [package-blockers
          (blocked-deps package-reports (graph:entry-field entry :requires))
          unit-blockers
          (blocked-deps reports (graph:entry-field entry :after))
          env-missing (preflight:env-missing-for-unit entry env)
          executable-missing
          (preflight:executable-missing-for-unit
           executable-reports
           (graph:entry-name entry))]
      (cond
        ((not (empty? package-blockers))
         (blocked-report
          (graph:entry-name entry)
          :blocked-by-package
          package-blockers))
        ((not (empty? unit-blockers))
         (blocked-report
          (graph:entry-name entry)
          :blocked-by-unit
          unit-blockers))
        ((or (not (empty? env-missing))
             (not (empty? executable-missing)))
         (preflight-report entry env-missing executable-missing))
        (else
         (ready-unit-report entry)))))

  (defn derive-unit-reports [units package-names package-reports env executable-reports]
    (let [unit-names (graph:known-names units)
          unit-missing-requires
          (graph:collect-missing-ref-entries units :requires package-names)
          unit-missing-after
          (graph:collect-missing-ref-entries units :after unit-names)
          unit-cycles (graph:cycle-names units :after unit-names)
          invalid-unit-reports
          (invalid-reports
           units
           (fn [entry]
             (graph:invalid-unit-report
              entry
              unit-missing-requires
              unit-missing-after
              unit-cycles)))]
      (list
       :cycles unit-cycles
       :missing-after unit-missing-after
       :missing-requires unit-missing-requires
       :reports
       (derive-phase-reports
        units
        invalid-unit-reports
        (fn [entry reports]
          (graph:all-known? (graph:entry-field entry :after) reports))
        (fn [entry reports]
          (next-unit-report
           entry
           reports
           package-reports
           env
           executable-reports))))))

  (defn emit-report-logs [label reports]
    (each report in reports
      (when (not (= (plist-get report :status) :ok))
        (protocol:send-event
         :log
         `(:level :warn
           :message
           ,(string
             label
             " "
             (plist-get report :name)
             " -> "
             (string (plist-get report :reason))
             " "
             (protocol:sexp-string (plist-get report :details))))))))

  (defn emit-report-message [stage phase reports]
    (protocol:send-report stage phase reports))

  {:derive-package-reports derive-package-reports
   :derive-unit-reports derive-unit-reports
   :emit-report-message emit-report-message
   :emit-report-logs emit-report-logs})
