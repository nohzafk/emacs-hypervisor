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

  (defn derive-phase-plan [phase entries planned-reports dep-key]
    (letrec
        [loop
         (fn [remaining ordered-names ordered-items]
           (if (empty? remaining)
             (reverse ordered-items)
             (let [ready
                   (filter
                    (fn [entry] (ready-for-plan? entry dep-key ordered-names))
                    remaining)]
               (assert (not (empty? ready)) "expected at least one ready plan entry")
               (let* [next (first ready)
                      name (graph:entry-name next)]
                 (loop
                  (remove-entry-by-name remaining name)
                  (cons name ordered-names)
                  (cons
                   (make-plan-item phase next (graph:find-entry planned-reports name))
                   ordered-items))))))]
      (let [items (loop (planned-ok-entries entries planned-reports) () ())]
        (list
         :phase phase
         :items items
         :names (map (fn [item] (plist-get item :name)) items)))))

  (defn derive-package-plan [packages planned-package-reports]
    (derive-phase-plan :packages packages planned-package-reports :deps))

  (defn derive-unit-plan [units planned-unit-reports]
    (derive-phase-plan :units units planned-unit-reports :after))

  (defn plan-items [plan]
    (plist-get plan :items))

  (defn plan-names [plan]
    (plist-get plan :names))

  (defn plan-message-items [plan]
    (map
     (fn [item]
       (let [entry (plist-get item :entry)
             phase (plist-get item :phase)]
         (if (= phase :packages)
           (list
            :name (plist-get item :name)
            :deps (graph:entry-field entry :deps))
           (list
            :name (plist-get item :name)
            :requires (graph:entry-field entry :requires)
            :after (graph:entry-field entry :after)))))
     (plan-items plan)))

  (defn emit-plan-message [plan]
    (protocol:send-event
     :plan
     `(:phase ,(plist-get plan :phase)
       :items ,(plan-message-items plan))))

  (defn merge-executed-reports [planned-reports executed-reports]
    (map
     (fn [report]
       (let [executed (graph:find-entry executed-reports (plist-get report :name))]
         (if (nil? executed) report executed)))
     planned-reports))

  {:derive-package-plan derive-package-plan
   :derive-unit-plan derive-unit-plan
   :emit-plan-message emit-plan-message
   :merge-executed-reports merge-executed-reports
   :plan-message-items plan-message-items
   :plan-items plan-items
   :plan-names plan-names})
