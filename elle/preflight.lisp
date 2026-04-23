## Shared env and executable preflight helpers.

(defn emacs-hypervisor-preflight-module [protocol graph mailbox benchmark]
  (defn env-entry-value [env name]
    (if-let [entry (graph:find-entry env name)]
      (get entry :value)
      nil))

  (defn env-missing-for-unit [unit env]
    (filter
     (fn [name]
       (let [value (env-entry-value env name)]
         (or (nil? value) (= value ""))))
     (graph:entry-field unit :env)))

  (defn units-with-executables [units]
    (filter
     (fn [unit] (not (empty? (graph:entry-field unit :executable))))
     units))

  (defn probe-executable [binary id]
    (protocol:send-request
     id
     :eval
     (benchmark:eval-payload
      `(:form (executable-find ,binary)
        :metric-name :probe-executable
        :metric-kind :executable-probe
        :phase :preflight
        :item-name ,binary)))
    (let [result (protocol:await-response mailbox id)]
      (assert (protocol:response-ok? result)
              (string "executable probe should succeed for " binary))
      (let [value (protocol:message-payload result)]
        {:binary binary :ok (not (nil? value)) :value value})))

  (defn executable-probe-report [unit {:binary binary :ok ok?}]
    {:name (graph:entry-name unit)
     :missing (if ok? () (list binary))})

  (defn next-executable-probe-state [{:next-id current-id :reports reports} unit]
    (let [binary (first (graph:entry-field unit :executable))
          check (probe-executable binary current-id)]
      {:next-id (+ current-id 1)
       :reports
       (cons
        (executable-probe-report unit check)
        reports)}))

  (defn probe-executables [units next-id]
    (let [{:next-id current-id :reports reports}
          (reduce
           next-executable-probe-state
           {:next-id next-id :reports ()}
           units)]
      {:next-id current-id
       :reports (reverse reports)}))

  (defn executable-missing-for-unit [reports unit-name]
    (if-let [entry (graph:find-entry reports unit-name)]
      (get entry :missing ())
      ()))

  {:env-missing-for-unit env-missing-for-unit
   :executable-missing-for-unit executable-missing-for-unit
   :probe-executables probe-executables
   :units-with-executables units-with-executables})
