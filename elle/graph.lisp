## Shared graph, validation, and reporting helpers.

(defn emacs-hypervisor-graph-module []
  (defn member? [xs value]
    (any? (fn [item] (= item value)) xs))

  (defn entry-name [{:name name}]
    name)

  (defn entry-field [entry key]
    (let [value (get entry key ())]
      (if (nil? value) () value)))

  (defn non-nil-values [values]
    (filter (fn [value] (not (nil? value))) values))

  (defn known-names [entries]
    (map entry-name entries))

  (defn missing-refs-for [refs known]
    (filter (fn [ref] (not (member? known ref))) refs))

  (defn missing-ref-entry [entry field known]
    (let [missing (missing-refs-for (entry-field entry field) known)]
      (if (empty? missing)
        nil
        {:name (entry-name entry) :missing missing})))

  (defn collect-missing-ref-entries [entries field known]
    (non-nil-values
     (map (fn [entry] (missing-ref-entry entry field known)) entries)))

  (defn has-no-missing-refs? [entry field known]
    (empty? (missing-refs-for (entry-field entry field) known)))

  (defn remove-entry-by-name [entries name]
    (filter (fn [entry] (not (= (entry-name entry) name))) entries))

  (defn valid-cycle-entries [entries dep-key known]
    (filter (fn [entry] (has-no-missing-refs? entry dep-key known)) entries))

  (defn deps-in-current [entry dep-key current-names]
    (filter
     (fn [dep] (member? current-names dep))
     (entry-field entry dep-key)))

  (defn has-dependent-in-current? [current dep-key name]
    (any?
     (fn [other]
       (member? (entry-field other dep-key) name))
     current))

  (defn cycle-core-entry? [entry current dep-key current-names]
    (let [name (entry-name entry)
          deps (deps-in-current entry dep-key current-names)]
      (and (not (empty? deps))
           (has-dependent-in-current? current dep-key name))))

  (defn cycle-names [entries dep-key known]
    (let [valid-entries (valid-cycle-entries entries dep-key known)]
      (letrec
          [prune-cycle-core
           (fn [current]
             (let [current-names (known-names current)
                   kept
                   (filter
                    (fn [entry]
                      (cycle-core-entry?
                       entry
                       current
                       dep-key
                       current-names))
                    current)]
               (if (= (length kept) (length current))
                 kept
                 (prune-cycle-core kept))))]
        (known-names (prune-cycle-core valid-entries)))))

  (defn find-entry [entries name]
    (match entries
      (() nil)
      ((entry & rest)
       (if (= (entry-name entry) name)
         entry
         (find-entry rest name)))
      (_ nil)))

  (defn report-status [reports name]
    (if-let [entry (find-entry reports name)]
      (get entry :status)
      nil))

  (defn make-report [name status reason details]
    {:name name :status status :reason reason :details details})

  (defn missing-details [missing]
    {:missing missing})

  (defn cycle-details [members]
    {:members members})

  (defn blocker-details [blockers]
    {:blockers blockers})

  (defn preflight-details [env executable]
    {:env env :executable executable})

  (defn missing-entry-report [name reason {:missing missing}]
    (make-report
     name
     :invalid
     reason
     (missing-details missing)))

  (defn entry-missing-report [name reason missing-entries]
    (if-let [missing-entry (find-entry missing-entries name)]
      (missing-entry-report name reason missing-entry)
      nil))

  (defn cycle-entry-report [name members]
    (make-report name :invalid :cycle (cycle-details members)))

  (defn invalid-package-report [entry missing-entries cycle-members]
    (let [name (entry-name entry)]
      (if-let [missing-report
               (entry-missing-report name :missing-deps missing-entries)]
        missing-report
        (if (member? cycle-members name)
          (cycle-entry-report name cycle-members)
          nil))))

  (defn invalid-unit-report [entry missing-requires missing-after cycle-members]
    (let [name (entry-name entry)]
      (if-let [missing-report
               (entry-missing-report
                name
                :missing-required-packages
                missing-requires)]
        missing-report
        (if-let [missing-report
                 (entry-missing-report
                  name
                  :missing-after-units
                  missing-after)]
          missing-report
          (if (member? cycle-members name)
            (cycle-entry-report name cycle-members)
            nil)))))

  (defn non-invalid-entries [entries invalid-reports]
    (filter
     (fn [entry]
       (nil? (find-entry invalid-reports (entry-name entry))))
     entries))

  (defn all-known? [names reports]
    (all? (fn [name] (not (nil? (find-entry reports name)))) names))

  (defn resolve-reports-loop [remaining reports ready? make-next-report]
    (if (empty? remaining)
      reports
      (let [ready (filter (fn [entry] (ready? entry reports)) remaining)]
        (assert (not (empty? ready)) "expected at least one ready entry")
        (let [next (first ready)]
          (resolve-reports-loop
           (remove-entry-by-name remaining (entry-name next))
           (cons (make-next-report next reports) reports)
           ready?
           make-next-report)))))

  (defn ordered-reports [entries reports]
    (map (fn [entry] (find-entry reports (entry-name entry))) entries))

  {:all-known? all-known?
   :collect-missing-ref-entries collect-missing-ref-entries
   :cycle-names cycle-names
   :cycle-details cycle-details
   :blocker-details blocker-details
   :entry-field entry-field
   :entry-name entry-name
   :find-entry find-entry
   :invalid-package-report invalid-package-report
   :invalid-unit-report invalid-unit-report
   :known-names known-names
   :make-report make-report
   :missing-details missing-details
   :non-invalid-entries non-invalid-entries
   :non-nil-values non-nil-values
   :ordered-reports ordered-reports
   :preflight-details preflight-details
   :report-status report-status
   :resolve-reports-loop resolve-reports-loop})
