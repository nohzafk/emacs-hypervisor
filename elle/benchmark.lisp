(elle/epoch 10)
## Shared benchmark and instrumentation helpers.

(defn emacs-hypervisor-benchmark-module [protocol enabled?]
  (defn append-plist-field [fields key value]
    (if value (append fields (list key value)) fields))

  (defn metric-payload-key? [key]
    (any? (fn [candidate] (= candidate key)) '(:metric-name :metric-kind :phase :item-name)))

  (defn strip-metric-fields [payload]
    (if (empty? payload)
      ()
      (let [key (first payload)
            tail (rest payload)]
        (if (empty? tail)
          (list key)
          (let [value (first tail)
                remaining (rest tail)]
            (if (metric-payload-key? key)
              (strip-metric-fields remaining)
              (pair key (pair value (strip-metric-fields remaining)))))))))

  (defn elapsed-ms [started-at]
    (* 1000.0 (- (clock/monotonic) started-at)))

  (defn emit-metric [phase name duration-ms metric-kind item-name]
    (if enabled?
      (protocol:send-event :metric (let [fields `(:source :elle :phase ,phase :name ,name :duration-ms ,duration-ms)
                                         fields (append-plist-field fields :metric-kind metric-kind)
                                         fields (append-plist-field fields :item-name item-name)]
                                     fields))
      nil))

  (defn measure [phase name thunk]
    (if enabled?
      (let [started-at (clock/monotonic)
            result (thunk)]
        (emit-metric phase name (elapsed-ms started-at) nil nil)
        result)
      (thunk)))

  (defn payload-datum [payload]
    (if (= (type-of payload) :syntax) (syntax->datum payload) payload))

  (defn eval-payload [payload]
    (let [payload (payload-datum payload)]
      (if enabled? payload (strip-metric-fields payload))))

  {:append-plist-field append-plist-field
   :elapsed-ms elapsed-ms
   :emit-metric emit-metric
   :eval-payload eval-payload
   :measure measure})
