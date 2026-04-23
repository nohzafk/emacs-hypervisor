## Shared env and executable preflight helpers.

(defn emacs-hypervisor-preflight-module [protocol graph]
  (def plist-get protocol:plist-get)

  (defn env-entry-value [env name]
    (let [matches
          (filter (fn [entry] (= (plist-get entry :name) name)) env)]
      (if (empty? matches)
        nil
        (plist-get (first matches) :value))))

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
    (let [result (protocol:await-response id)]
      (assert (protocol:response-ok? result)
              (string "executable probe should succeed for " binary))
      (let [value (protocol:message-payload result)]
        (list :binary binary :ok (not (nil? value)) :value value))))

  (defn probe-executables [units next-id]
    (letrec
        [loop
         (fn [remaining current-id reports]
           (if (empty? remaining)
             (list :next-id current-id :reports (reverse reports))
             (let* [unit (first remaining)
                    binary (first (graph:entry-field unit :executable))
                    check (probe-executable binary current-id)]
               (loop
                (rest remaining)
                (+ current-id 1)
                (cons
                 (list
                  :name (graph:entry-name unit)
                  :missing (if (plist-get check :ok) () (list binary)))
                 reports)))))]
      (loop units next-id ())))

  (defn executable-missing-for-unit [reports unit-name]
    (let [entry (graph:find-entry reports unit-name)]
      (if (nil? entry) () (plist-get entry :missing))))

  {:env-missing-for-unit env-missing-for-unit
   :executable-missing-for-unit executable-missing-for-unit
   :probe-executables probe-executables
   :units-with-executables units-with-executables})
