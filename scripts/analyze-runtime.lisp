(elle/epoch 10)
## Analyze shared runtime files with Elle local analysis primitives.

(def portrait ((import "std/portrait")))

(def verbose? (not (nil? (sys/env "ANALYZE_RUNTIME_VERBOSE"))))
(def observation-limit 6)

(def runtime-files
  ["elle/protocol.lisp" "elle/graph.lisp" "elle/preflight.lisp" "elle/boot-policy.lisp" "elle/planning.lisp"
   "elle/execution.lisp"])

(defn function-symbols [analysis]
  (map (fn [sym] (keyword (get sym :name))) (filter (fn [sym] (= (get sym :kind) :function)) (compile/symbols analysis))))

(defn print-divider [label]
  (println)
  (println (string/format "== {} ==" label)))

(defn signal-counts [analysis names]
  (def @pure 0)
  (def @io-boundary 0)
  (def @delegating 0)
  (def @yielding 0)
  (each name in names
    (let [sig (compile/signal analysis name)]
      (cond
        (get sig :silent) (assign pure (+ pure 1))
        (not (empty? (get sig :propagates))) (assign delegating (+ delegating 1))
        (get sig :io) (assign io-boundary (+ io-boundary 1))
        (get sig :yields) (assign yielding (+ yielding 1))
        true (assign io-boundary (+ io-boundary 1)))))
  {:pure pure :io io-boundary :delegating delegating :yielding yielding})

(defn function-observations [analysis names]
  (def @items @[])
  (each name in names
    (let [observations (get (portrait:function analysis name) :observations)]
      (when (not (empty? observations))
        (push items {:name (string name) :observations observations}))))
  (freeze items))

(defn print-observations [items]
  (if (empty? items)
    (println "observations: none")
    (let [remaining (length items)
          @shown 0]
      (println (string/format "observations: {} total" remaining))
      (each item in items
        (when (< shown observation-limit)
          (let [name (get item :name)
                observation (first (get item :observations))]
            (println (string/format "  - {} [{}] {}" name (get observation :kind) (get observation :message)))
            (assign shown (+ shown 1)))))
      (when (> remaining observation-limit)
        (println (string/format "  ... {} more" (- remaining observation-limit)))))))

(defn print-summary [path analysis]
  (let* [names (function-symbols analysis)
         counts (signal-counts analysis names)
         graph (compile/call-graph analysis)
         observations (function-observations analysis names)]
    (println (string/format "functions: {}  pure={} io={} delegating={} yielding={}" (length names) (get counts :pure)
                            (get counts :io) (get counts :delegating) (get counts :yielding)))
    (println (string/format "roots: {}  leaves: {}" (length (get graph :roots)) (length (get graph :leaves))))
    (print-observations observations)
    (when verbose?
      (println)
      (println "-- module portrait --")
      (println (portrait:render-module (portrait:module analysis)))
      (println "-- function portraits --")
      (each name in names
        (println (portrait:render (portrait:function analysis name)))))))

(each path in runtime-files
  (print-divider path)
  (print-summary path (compile/analyze (file/read path) {:file path})))
