## Shared execution planning helpers.

(defn emacs-hypervisor-planning-module [protocol graph]
  (def plist-get protocol:plist-get)

  (defn member? [xs value]
    (any? (fn [item] (= item value)) xs))

  (defn remove-entry-by-name [entries name]
    (filter (fn [entry] (not (= (graph:entry-name entry) name))) entries))

  (defn ready-for-plan? [entry dep-key ordered-names]
    (all?
     (fn [dep] (member? ordered-names dep))
     (graph:entry-field entry dep-key)))

  (defn planned-ok-entries [entries planned-reports]
    (filter
     (fn [entry]
       (= (graph:report-status planned-reports (graph:entry-name entry)) :ok))
     entries))

  (defn make-plan-item [phase entry planned-report]
    (list
     :phase phase
     :name (graph:entry-name entry)
     :entry entry
     :planned-report planned-report))

  (defn ready-plan-entries [entries dep-key ordered-names]
    (filter
     (fn [entry] (ready-for-plan? entry dep-key ordered-names))
     entries))

  (defn next-ready-plan-entry [entries dep-key ordered-names]
    (let [ready (ready-plan-entries entries dep-key ordered-names)]
      (assert (not (empty? ready)) "expected at least one ready plan entry")
      (first ready)))

  (defn phase-plan [phase items]
    (list
     :phase phase
     :items items))

  (defn derive-phase-plan [phase entries planned-reports dep-key]
    (letrec
        [loop
         (fn [remaining ordered-names ordered-items]
           (if (empty? remaining)
             (reverse ordered-items)
             (let* [next (next-ready-plan-entry remaining dep-key ordered-names)
                    name (graph:entry-name next)]
               (loop
                (remove-entry-by-name remaining name)
                (cons name ordered-names)
                (cons
                 (make-plan-item phase next (graph:find-entry planned-reports name))
                 ordered-items)))))]
      (phase-plan
       phase
       (loop (planned-ok-entries entries planned-reports) () ()))))

  (defn derive-package-plan [packages planned-package-reports]
    (derive-phase-plan :packages packages planned-package-reports :deps))

  (defn derive-unit-plan [units planned-unit-reports]
    (derive-phase-plan :units units planned-unit-reports :after))

  (defn plan-items [plan]
    (plist-get plan :items))

  (defn plan-message-item [item]
    (let [entry (plist-get item :entry)
          name (plist-get item :name)]
      (match (plist-get item :phase)
        (:packages
         (list
          :name name
          :deps (graph:entry-field entry :deps)))
        (_
         (list
          :name name
          :requires (graph:entry-field entry :requires)
          :after (graph:entry-field entry :after))))))

  (defn emit-plan-message [plan]
    (protocol:send-event
     :plan
     `(:phase ,(plist-get plan :phase)
       :items ,(map plan-message-item (plan-items plan)))))

  (defn merge-executed-reports [planned-reports executed-reports]
    (map
     (fn [report]
       (if-let [executed (graph:find-entry executed-reports (plist-get report :name))]
         executed
         report))
     planned-reports))

  {:derive-package-plan derive-package-plan
   :derive-unit-plan derive-unit-plan
   :emit-plan-message emit-plan-message
   :merge-executed-reports merge-executed-reports
   :plan-items plan-items})
