## Shared env and executable preflight helpers.

(defn emacs-hypervisor-preflight-module [protocol graph mailbox]
  (def plist-get protocol:plist-get)

  (defn env-entry-value [env name]
    (if-let [entry (graph:find-entry env name)]
      (plist-get entry :value)
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
     `(:form (executable-find ,binary)))
    (let [result (protocol:await-response mailbox id)]
      (assert (protocol:response-ok? result)
              (string "executable probe should succeed for " binary))
      (let [value (protocol:message-payload result)]
        (list :binary binary :ok (not (nil? value)) :value value))))

  (defn executable-probe-report [unit check]
    (list
     :name (graph:entry-name unit)
     :missing (if (plist-get check :ok) () (list (plist-get check :binary)))))

  (defn next-executable-probe-state [state unit]
    (let* [current-id (plist-get state :next-id)
           binary (first (graph:entry-field unit :executable))
           check (probe-executable binary current-id)]
      (list
       :next-id (+ current-id 1)
       :reports
       (cons
        (executable-probe-report unit check)
        (plist-get state :reports)))))

  (defn probe-executables [units next-id]
    (let [state
          (reduce
           next-executable-probe-state
           (list :next-id next-id :reports ())
           units)]
      (list
       :next-id (plist-get state :next-id)
       :reports (reverse (plist-get state :reports)))))

  (defn executable-missing-for-unit [reports unit-name]
    (let [entry (graph:find-entry reports unit-name)]
      (if (nil? entry) () (plist-get entry :missing))))

  {:env-missing-for-unit env-missing-for-unit
   :executable-missing-for-unit executable-missing-for-unit
   :probe-executables probe-executables
   :units-with-executables units-with-executables})
