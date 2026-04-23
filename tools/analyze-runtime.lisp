(elle/epoch 8)
## Analyze shared runtime files with Elle local analysis primitives.

(def portrait ((import "std/portrait")))

(def runtime-files
  ["elle/protocol.lisp"
   "elle/graph.lisp"
   "elle/preflight.lisp"
   "elle/boot-policy.lisp"
   "elle/planning.lisp"
   "elle/execution.lisp"])

(defn function-symbols [analysis]
  (map
   (fn [sym] (keyword (get sym :name)))
   (filter
    (fn [sym] (= (get sym :kind) :function))
    (compile/symbols analysis))))

(defn print-divider [label]
  (println)
  (println (string/format "== {} ==" label)))

(each path in runtime-files
  (print-divider path)
  (let [analysis (compile/analyze (file/read path) {:file path})]
    (println "-- module portrait --")
    (println (portrait:render-module (portrait:module analysis)))
    (println "-- function portraits --")
    (each name in (function-symbols analysis)
      (println (portrait:render (portrait:function analysis name))))))
