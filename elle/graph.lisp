## Shared graph, validation, and reporting helpers.

(defn emacs-hypervisor-graph-module [plist-get]
  (defn member? [xs value]
    (any? (fn [item] (= item value)) xs))

  (defn entry-name [entry]
    (plist-get entry :name))

  (defn entry-field [entry key]
    (let [value (plist-get entry key)]
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
        (list :name (entry-name entry) :missing missing))))

  (defn collect-missing-ref-entries [entries field known]
    (non-nil-values
     (map (fn [entry] (missing-ref-entry entry field known)) entries)))

  (defn has-no-missing-refs? [entry field known]
    (empty? (missing-refs-for (entry-field entry field) known)))

  (defn remove-entry-by-name [entries name]
    (filter (fn [entry] (not (= (entry-name entry) name))) entries))

  (defn cycle-names [entries dep-key known]
    (let [valid-entries
          (filter (fn [entry] (has-no-missing-refs? entry dep-key known)) entries)]
      (letrec
          [prune-cycle-core
           (fn [current]
             (let [current-names (known-names current)
                   kept
                   (filter
                    (fn [entry]
                      (let [name (entry-name entry)
                            deps-in-current
                            (filter
                             (fn [dep] (member? current-names dep))
                             (entry-field entry dep-key))
                            has-dependent-in-current
                            (any?
                             (fn [other]
                               (member? (entry-field other dep-key) name))
                             current)]
                        (and (not (empty? deps-in-current))
                             has-dependent-in-current)))
                    current)]
               (if (= (length kept) (length current))
                 kept
                 (prune-cycle-core kept))))]
        (known-names (prune-cycle-core valid-entries)))))

  (defn find-entry [entries name]
    (let [matches (filter (fn [entry] (= (entry-name entry) name)) entries)]
      (if (empty? matches) nil (first matches))))

  (defn report-for [reports name]
    (find-entry reports name))

  (defn report-status [reports name]
    (let [entry (report-for reports name)]
      (if (nil? entry) nil (plist-get entry :status))))

  (defn make-report [name status reason details]
    (list :name name :status status :reason reason :details details))

  (defn missing-details [missing]
    (list :missing missing))

  (defn cycle-details [members]
    (list :members members))

  (defn blocker-details [blockers]
    (list :blockers blockers))

  (defn preflight-details [env executable]
    (list :env env :executable executable))

  (defn invalid-package-report [entry missing-entries cycle-members]
    (let [name (entry-name entry)
          missing-entry (find-entry missing-entries (entry-name entry))]
      (if (not (nil? missing-entry))
        (make-report
         name
         :invalid
         :missing-deps
         (missing-details (plist-get missing-entry :missing)))
        (if (member? cycle-members name)
          (make-report name :invalid :cycle (cycle-details cycle-members))
          nil))))

  (defn invalid-unit-report [entry missing-requires missing-after cycle-members]
    (let [name (entry-name entry)
          missing-required-entry (find-entry missing-requires name)
          missing-after-entry (find-entry missing-after name)]
      (if (not (nil? missing-required-entry))
        (make-report
         name
         :invalid
         :missing-required-packages
         (missing-details (plist-get missing-required-entry :missing)))
        (if (not (nil? missing-after-entry))
          (make-report
           name
           :invalid
           :missing-after-units
           (missing-details (plist-get missing-after-entry :missing)))
          (if (member? cycle-members name)
            (make-report name :invalid :cycle (cycle-details cycle-members))
            nil)))))

  (defn non-invalid-entries [entries invalid-reports]
    (filter
     (fn [entry]
       (nil? (find-entry invalid-reports (entry-name entry))))
     entries))

  (defn all-known? [names reports]
    (all? (fn [name] (not (nil? (report-for reports name)))) names))

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
