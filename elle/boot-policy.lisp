## Shared boot-policy helpers built on graph + preflight modules.

(defn emacs-hypervisor-boot-policy-module [protocol graph preflight]
  (def plist-get protocol:plist-get)

  (defn next-package-report [entry reports]
    (let [deps (graph:entry-field entry :deps)
          blockers
          (filter
           (fn [dep] (not (= (graph:report-status reports dep) :ok)))
           deps)]
      (if (empty? blockers)
        (graph:make-report (graph:entry-name entry) :ok :ready deps)
        (graph:make-report
         (graph:entry-name entry)
         :skipped
         :blocked-by-package
         (graph:blocker-details blockers)))))

  (defn derive-package-reports [packages]
    (let [package-names (graph:known-names packages)
          package-missing
          (graph:collect-missing-ref-entries packages :deps package-names)
          package-cycles (graph:cycle-names packages :deps package-names)
          invalid-package-reports
          (graph:non-nil-values
           (map
            (fn [entry]
              (graph:invalid-package-report entry package-missing package-cycles))
            packages))
          remaining-packages
          (graph:non-invalid-entries packages invalid-package-reports)
          package-reports-unordered
          (graph:resolve-reports-loop
           remaining-packages
           invalid-package-reports
           (fn [entry reports]
             (graph:all-known? (graph:entry-field entry :deps) reports))
           (fn [entry reports]
             (next-package-report entry reports)))]
      (list
       :cycles package-cycles
       :missing package-missing
       :reports (graph:ordered-reports packages package-reports-unordered))))

  (defn next-unit-report [entry reports package-reports env executable-reports]
    (let [package-blockers
          (filter
           (fn [dep] (not (= (graph:report-status package-reports dep) :ok)))
           (graph:entry-field entry :requires))
          unit-blockers
          (filter
           (fn [dep] (not (= (graph:report-status reports dep) :ok)))
           (graph:entry-field entry :after))
          env-missing (preflight:env-missing-for-unit entry env)
          executable-missing
          (preflight:executable-missing-for-unit
           executable-reports
           (graph:entry-name entry))]
      (if (not (empty? package-blockers))
        (graph:make-report
         (graph:entry-name entry)
         :skipped
         :blocked-by-package
         (graph:blocker-details package-blockers))
        (if (not (empty? unit-blockers))
          (graph:make-report
           (graph:entry-name entry)
           :skipped
           :blocked-by-unit
           (graph:blocker-details unit-blockers))
          (if (or (not (empty? env-missing))
                  (not (empty? executable-missing)))
            (graph:make-report
             (graph:entry-name entry)
             :skipped
             :preflight
             (graph:preflight-details env-missing executable-missing))
            (graph:make-report
             (graph:entry-name entry)
             :ok
             :ready
             (list
              :requires (graph:entry-field entry :requires)
              :after (graph:entry-field entry :after))))))))

  (defn derive-unit-reports [units package-names package-reports env executable-reports]
    (let [unit-names (graph:known-names units)
          unit-missing-requires
          (graph:collect-missing-ref-entries units :requires package-names)
          unit-missing-after
          (graph:collect-missing-ref-entries units :after unit-names)
          unit-cycles (graph:cycle-names units :after unit-names)
          invalid-unit-reports
          (graph:non-nil-values
           (map
            (fn [entry]
              (graph:invalid-unit-report
               entry
               unit-missing-requires
               unit-missing-after
               unit-cycles))
            units))
          remaining-units (graph:non-invalid-entries units invalid-unit-reports)
          unit-reports-unordered
          (graph:resolve-reports-loop
           remaining-units
           invalid-unit-reports
           (fn [entry reports]
             (graph:all-known? (graph:entry-field entry :after) reports))
           (fn [entry reports]
             (next-unit-report
              entry
              reports
              package-reports
              env
              executable-reports)))]
      (list
       :cycles unit-cycles
       :missing-after unit-missing-after
       :missing-requires unit-missing-requires
       :reports (graph:ordered-reports units unit-reports-unordered))))

  (defn emit-report-logs [label reports]
    (map
     (fn [report]
       (if (= (plist-get report :status) :ok)
         nil
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
              (protocol:sexp-string (plist-get report :details)))))))
     reports))

  (defn emit-report-message [stage phase reports]
    (protocol:send-report stage phase reports))

  {:derive-package-reports derive-package-reports
   :derive-unit-reports derive-unit-reports
   :emit-report-message emit-report-message
   :emit-report-logs emit-report-logs})
