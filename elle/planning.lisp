(elle/epoch 10)
## Shared execution planning helpers.

(defn emacs-hypervisor-planning-module [protocol graph]
  (defn ready-for-plan? [entry dep-key ordered-names]
    (all? (fn [dep] (graph:member? ordered-names dep)) (graph:entry-field entry dep-key)))

  (defn planned-ok-entries [entries planned-reports]
    (filter (fn [entry]
              (let [report (graph:find-entry planned-reports (graph:entry-name entry))]
                (and (= (graph:entry-field report :status) :ok) (not (= (graph:entry-field report :reason) :installed)))))
            entries))

  (defn installed-entries [entries planned-reports]
    (filter (fn [entry]
              (let [report (graph:find-entry planned-reports (graph:entry-name entry))]
                (and (= (graph:entry-field report :status) :ok) (= (graph:entry-field report :reason) :installed))))
            entries))

  (defn plan-entry [phase entry]
    (if (= phase :units)
      {:name (graph:entry-name entry)
       :index (graph:entry-field entry :index)
       :requires (graph:entry-field entry :requires)
       :after (graph:entry-field entry :after)}
      entry))

  (defn make-plan-item [phase entry planned-report]
    {:phase phase :name (graph:entry-name entry) :entry (plan-entry phase entry) :planned-report planned-report})

  (defn ready-plan-entries [entries dep-key ordered-names]
    (filter (fn [entry] (ready-for-plan? entry dep-key ordered-names)) entries))

  (defn next-ready-plan-entry [entries dep-key ordered-names]
    (let [ready (ready-plan-entries entries dep-key ordered-names)]
      (assert (not (empty? ready)) "expected at least one ready plan entry")
      (first ready)))

  (defn phase-plan [phase names items]
    {:phase phase :names names :items items})

  (defn derive-phase-plan [phase entries planned-reports dep-key]
    (let [plan-entries (planned-ok-entries entries planned-reports)]
      (letrec [loop (fn [remaining ready-names ordered-names ordered-items]
                      (if (empty? remaining)
                        {:names (reverse ordered-names) :items (reverse ordered-items)}
                        (let* [next (next-ready-plan-entry remaining dep-key ready-names)
                               name (graph:entry-name next)]
                          (loop (graph:remove-entry-by-name remaining name) (pair name ready-names)
                                (pair name ordered-names)
                                (pair (make-plan-item phase next (graph:find-entry planned-reports name)) ordered-items)))))]
        (let [result (loop plan-entries (graph:known-names (installed-entries entries planned-reports)) () ())]
          (phase-plan phase (get result :names) (get result :items))))))

  (defn derive-package-plan [packages planned-package-reports]
    (derive-phase-plan :packages packages planned-package-reports :deps))

  (defn derive-unit-plan [units planned-unit-reports]
    (derive-phase-plan :units units planned-unit-reports :after))

  (defn plan-items [plan]
    (get plan :items))

  (defn plan-names [plan]
    (get plan :names))

  (defn plan-message-item [plan-item]
    (let [phase (graph:entry-field plan-item :phase)
          entry (graph:entry-field plan-item :entry)
          name (graph:entry-name plan-item)]
      (match phase
        :packages {:name name :deps (graph:entry-field entry :deps)}
        _ {:name name :requires (graph:entry-field entry :requires) :after (graph:entry-field entry :after)})))

  (defn emit-plan-message [plan]
    (protocol:send-event :plan {:phase (graph:entry-field plan :phase)
                                :items (map plan-message-item (graph:entry-field plan :items))}))

  (defn merge-executed-reports [planned-reports executed-reports]
    (if (empty? executed-reports)
      planned-reports
      (map (fn [planned-report]
             (or (graph:find-entry executed-reports (graph:entry-name planned-report)) planned-report)) planned-reports)))

  {:derive-package-plan derive-package-plan
   :derive-unit-plan derive-unit-plan
   :emit-plan-message emit-plan-message
   :merge-executed-reports merge-executed-reports
   :plan-items plan-items
   :plan-names plan-names})
