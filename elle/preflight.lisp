(elle/epoch 12)
## Shared env and executable preflight helpers.

(defn emacs-hypervisor-preflight-module [_protocol graph _mailbox _benchmark]
  (defn env-entry-value [env name]
    (if-let [entry (graph:find-entry env name)] (get entry :value) nil))

  (defn env-missing-for-unit [unit env]
    (filter (fn [name]
              (let [value (env-entry-value env name)]
                (or (nil? value) (= value "")))) (graph:entry-field unit :env)))

  (defn units-with-executables [units]
    (filter (fn [unit] (not (empty? (graph:entry-field unit :executable)))) units))

  (defn path-entries [env]
    (if-let [path-value (env-entry-value env "PATH")] (string/split path-value ":") ()))

  (defn executable-path [binary path-dirs]
    (cond
      (string/starts-with? binary "/") (if (file/exists? binary) binary nil)
      true
        (letrec [loop (fn [dirs]
                        (if (empty? dirs)
                          nil
                          (let [candidate (path/join (first dirs) binary)]
                            (if (file/exists? candidate) candidate (loop (rest dirs))))))]
          (loop path-dirs))))

  (defn missing-executables [unit path-dirs]
    (filter (fn [binary] (nil? (executable-path binary path-dirs))) (graph:entry-field unit :executable)))

  (defn probe-executables [units next-id env]
    (let [path-dirs (path-entries env)]
      {:next-id next-id
       :reports (map (fn [unit] {:name (graph:entry-name unit) :missing (missing-executables unit path-dirs)}) units)}))

  (defn executable-missing-for-unit [reports unit-name]
    (if-let [entry (graph:find-entry reports unit-name)] (get entry :missing ()) ()))

  {:env-missing-for-unit env-missing-for-unit
   :executable-missing-for-unit executable-missing-for-unit
   :probe-executables probe-executables
   :units-with-executables units-with-executables})
