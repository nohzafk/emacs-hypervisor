(elle/epoch 10)
## tests/elle/hypervisor-runtime.lisp
##
## Regression checks extracted from the removed numbered spikes. These cover
## the durable shared-path semantics that still matter after the architecture
## reset:
## - boot-policy invalid/blocking/preflight reports
## - explicit planning order independent of declaration order
## - tracker-based package execution report derivation
## - unit execution failure propagation

(include-file "../../elle/graph.lisp")
(include-file "../../elle/protocol.lisp")
(include-file "../../elle/benchmark.lisp")
(include-file "../../elle/preflight.lisp")
(include-file "../../elle/boot-policy.lisp")
(include-file "../../elle/reporting.lisp")
(include-file "../../elle/planning.lisp")
(include-file "../../elle/execution.lisp")
(include-file "../../elle/runtime-forms/module-loader.lisp")

(def graph (emacs-hypervisor-graph-module))
(def wire-protocol (emacs-hypervisor-protocol-module))

(def @stub-sent-events @[])
(def @stub-sent-requests @[])
(def @stub-sent-responses @[])
(def @stub-await-responses @[])
(def @stub-await-index 0)
(def @stub-read-messages @[])
(def @stub-read-index 0)

(defn stub-response [id ok payload &named error]
  {:kind :response :id id :ok ok :payload payload :error error})

(defn stub-event [topic payload]
  {:kind :event :topic topic :payload payload})

(defn clear-array! [arr]
  (while (not (empty? arr)) (pop arr)))

(defn reset-stub-state []
  (clear-array! stub-sent-events)
  (clear-array! stub-sent-requests)
  (clear-array! stub-sent-responses)
  (clear-array! stub-await-responses)
  (clear-array! stub-read-messages)
  (assign stub-await-index 0)
  (assign stub-read-index 0))

(def protocol
  {:await-response (fn [_mailbox _id]
                     (let [response (get stub-await-responses stub-await-index)]
                       (assign stub-await-index (+ stub-await-index 1))
                       response))
   :from-wire (fn [payload] payload)
   :message-id (fn [message] (get message :id))
   :message-kind (fn [message] (get message :kind))
   :message-payload (fn [message] (get message :payload))
   :message-topic (fn [message] (get message :topic))
   :read-message (fn [_mailbox _label]
                   (let [message (get stub-read-messages stub-read-index)]
                     (assign stub-read-index (+ stub-read-index 1))
                     message))
   :plist-get wire-protocol:plist-get
   :response-error (fn [message] (get message :error))
   :response-ok? (fn [message] (get message :ok))
   :send-event (fn [topic payload] (push stub-sent-events {:topic topic :payload (wire-protocol:to-wire payload)}))
   :send-report (fn [stage phase payload]
                  (push stub-sent-events
                        {:topic :report :payload {:stage stage :phase phase :payload (wire-protocol:to-wire payload)}}))
   :send-response (fn [id payload] (push stub-sent-responses {:id id :ok true :payload (wire-protocol:to-wire payload)}))
   :send-error-response (fn [id error] (push stub-sent-responses {:id id :ok false :error error}))
   :send-eval-form-string-request (fn [id form-string]
                                    (push stub-sent-requests {:id id :op :eval :form-string form-string}))
   :send-request (fn [id op payload] (push stub-sent-requests {:id id :op op :payload payload}))
   :sexp-string wire-protocol:sexp-string
   :to-wire wire-protocol:to-wire})

(def benchmark
  {:eval-payload (fn [payload] payload)
   :append-plist-field (fn [fields key value] (if value (append fields (list key value)) fields))})
(def mailbox :stub)

(def preflight (emacs-hypervisor-preflight-module protocol graph mailbox benchmark))
(def policy (emacs-hypervisor-boot-policy-module graph preflight))
(def reporting (emacs-hypervisor-reporting-module protocol policy))
(def planning (emacs-hypervisor-planning-module protocol graph))
(def execution (emacs-hypervisor-execution-module protocol graph mailbox benchmark))
(def runtime-module-loader (emacs-hypervisor-runtime-forms-module-loader-module))
(def benchmark-enabled-module (emacs-hypervisor-benchmark-module protocol true))
(def benchmark-disabled-module (emacs-hypervisor-benchmark-module protocol false))

(def packages
  (list {:name "ui-pkg"
         :deps (list "core-pkg")
         :repo "example/ui-pkg"
         :host nil
         :branch nil
         :tag nil
         :ref nil
         :local nil
         :lisp-dir nil}
        {:name "runtime-fail-dependent"
         :deps (list "runtime-fail-pkg")
         :repo "example/runtime-fail-dependent"
         :host nil
         :branch nil
         :tag nil
         :ref nil
         :local nil
         :lisp-dir nil}
        {:name "core-pkg"
         :deps (list)
         :repo "example/core-pkg"
         :host nil
         :branch nil
         :tag nil
         :ref nil
         :local nil
         :lisp-dir nil}
        {:name "invalid-root"
         :deps (list "ghost-pkg")
         :repo "example/invalid-root"
         :host nil
         :branch nil
         :tag nil
         :ref nil
         :local nil
         :lisp-dir nil}
        {:name "runtime-fail-pkg"
         :deps (list)
         :repo "example/runtime-fail-pkg"
         :host nil
         :branch nil
         :tag nil
         :ref nil
         :local nil
         :lisp-dir nil}))

(def installed-packages
  (map (fn
       [{:name name :deps deps :repo repo :host host :branch branch :tag tag :ref ref :local local :lisp-dir lisp-dir}]
         {:name name
          :deps deps
          :repo repo
          :host host
          :branch branch
          :tag tag
          :ref ref
          :local local
          :lisp-dir lisp-dir
          :installed true}) packages))

(def units
  (list {:name "ui-unit"
         :index 0
         :requires (list "ui-pkg")
         :after (list "core-ui-unit")
         :env (list)
         :executable (list)
         :body '(progn :ui-ok)}
        {:name "after-runtime-fail-unit"
         :index 1
         :requires (list)
         :after (list "runtime-fail-unit")
         :env (list)
         :executable (list)
         :body '(progn :after-fail-ok)}
        {:name "core-ui-unit"
         :index 2
         :requires (list "core-pkg")
         :after (list)
         :env (list)
         :executable (list)
         :body '(progn :core-ok)}
        {:name "blocked-by-invalid-package-unit"
         :index 3
         :requires (list "invalid-root")
         :after (list)
         :env (list)
         :executable (list)
         :body '(progn :blocked-invalid-ok)}
        {:name "blocked-by-runtime-package-unit"
         :index 4
         :requires (list "runtime-fail-pkg")
         :after (list)
         :env (list)
         :executable (list)
         :body '(progn :blocked-ok)}
        {:name "invalid-after-unit"
         :index 5
         :requires (list)
         :after (list "ghost-unit")
         :env (list)
         :executable (list)
         :body '(progn :invalid-ok)}
        {:name "independent-unit"
         :index 6
         :requires (list)
         :after (list)
         :env (list)
         :executable (list)
         :body '(progn :independent-ok)}
        {:name "runtime-fail-unit"
         :index 7
         :requires (list)
         :after (list)
         :env (list)
         :executable (list)
         :body '(error "simulated unit failure")}
        {:name "preflight-bad-unit"
         :index 8
         :requires (list)
         :after (list)
         :env (list "HYPERVISOR_MISSING_ENV")
         :executable (list "definitely-not-installed-command")
         :body '(progn :preflight-ok)}))

(def env
  (list {:name "PATH" :value "/usr/bin"} {:name "SHELL" :value "/bin/fish"} {:name "HYPERVISOR_MISSING_ENV" :value ""}))

(def executable-reports (list {:name "preflight-bad-unit" :missing (list "definitely-not-installed-command")}))

# ============================================================================
# 0. Protocol printing preserves nested arrays as recursive s-expressions.
# ============================================================================

(assert (= (wire-protocol:sexp-string ["Open" ["a" "window"]]) "[\"Open\" [\"a\" \"window\"]]")
        "protocol prints immutable arrays recursively")
(assert (= (wire-protocol:sexp-string @["Tabs" "[" "]"]) "[\"Tabs\" \"[\" \"]\"]")
        "protocol prints mutable arrays recursively")
(assert (= (wire-protocol:sexp-string (list :ok true :payload nil :duration-ms 1.5))
           "(:ok true :payload nil :duration-ms 1.5)") "protocol prints primitive scalars without unsafe conversion")
(assert (= (wire-protocol:sexp-string (wire-protocol:to-wire (wire-protocol:from-wire [(quote (:name "unit"))
                                      ["Open" "a"]]))) "[(:name \"unit\") [\"Open\" \"a\"]]")
        "protocol converts nested arrays through from-wire/to-wire")
(let* [decoded (wire-protocol:from-wire-session-data (quote (:packages ((:name "pkg" :deps () :repo "example/pkg"
                                                            :host nil :branch nil :tag nil :ref nil :local nil))
                                                            :units ((:name "plist-unit" :requires ("pkg") :after ()
                                                            :env () :executable ()
                                                            :body (progn (setq x (quote (:a 1 :b 2))) t)))
                                                            :env ((:name "PATH" :value "/usr/bin"))
                                                            :extensions (:mermaid-enabled t))))
       unit (first (get decoded :units))
       package (first (get decoded :packages))
       env-entry (first (get decoded :env))
       extensions-settings (get decoded :extensions)
       body (get unit :body)]
  (assert (= (get package :name) "pkg") "session decoder decodes packages")
  (assert (= (get env-entry :value) "/usr/bin") "session decoder decodes env")
  (assert (= (get extensions-settings :mermaid-enabled) 't) "session decoder decodes extension settings")
  (assert (= (get unit :requires) (list "pkg")) "session decoder decodes unit metadata")
  (assert (= body '(progn (setq x (quote (:a 1 :b 2))) t)) "session decoder preserves raw unit body")
  (assert (= (wire-protocol:sexp-string body) "(progn (setq x (quote (:a 1 :b 2))) t)")
          "session decoder does not struct-convert plist literals inside body"))
(println "  0. protocol arrays and session decoding: ok")

(let [probe-message (wire-protocol:make-request 10 :eval (list :form (list 'executable-find "git")))]
  (assert (= (wire-protocol:sexp-string probe-message)
             "(:rpc :protocol :sexp-rpc :version 1 :kind :request :id 10 :op :eval :payload (:form (executable-find \"git\")))")
          "protocol serializes executable probe requests"))
(println "  0a. executable probe serialization: ok")

(let* [probe-units (list {:name "has-sh" :executable (list "sh")}
                         {:name "missing-bin" :executable (list "definitely-not-installed-command")}
                         {:name "second-missing" :executable (list "sh" "definitely-not-installed-command")}
                         {:name "both-missing" :executable (list "missing-command-one" "missing-command-two")})
       probe-env (list {:name "PATH" :value "/bin:/usr/bin"})
       {:next-id next-id :reports reports} (preflight:probe-executables probe-units 10 probe-env)
       has-sh (graph:find-entry reports "has-sh")
       missing-bin (graph:find-entry reports "missing-bin")
       second-missing (graph:find-entry reports "second-missing")
       both-missing (graph:find-entry reports "both-missing")]
  (assert (= next-id 10) "path preflight does not consume rpc ids")
  (assert (= (get has-sh :missing) (list)) "path preflight finds present executable")
  (assert (= (get missing-bin :missing) (list "definitely-not-installed-command"))
          "path preflight reports missing executable")
  (assert (= (get second-missing :missing) (list "definitely-not-installed-command"))
          "path preflight probes every declared executable, not just the first")
  (assert (= (get both-missing :missing) (list "missing-command-one" "missing-command-two"))
          "path preflight reports all missing executables for a unit"))
(println "  0b. executable PATH preflight: ok")

(let* [{:reports installed-package-reports} (policy:derive-package-reports installed-packages)
       installed-plan (planning:derive-package-plan installed-packages installed-package-reports)
       core-report (graph:find-entry installed-package-reports "core-pkg")]
  (assert (= (graph:entry-field core-report :reason) :installed) "installed package report reason")
  (assert (= (length (planning:plan-items installed-plan)) 0) "installed packages are omitted from install plan"))
(println "  0c. installed package planning: ok")

# ============================================================================
# 0d. Boot policy derives stale init warnings from boot context.
# ============================================================================

(let* [warning (policy:bootstrap-warning {:init-generated true
                                          :init-content-hash "fnv1a64:old"
                                          :init-file "/tmp/home/init.el"
                                          :binary "/tmp/bin/emacs-hypervisor"
                                          :repo-dir "/tmp/home"} "fnv1a64:new")]
  (assert warning "boot-policy reports stale generated init")
  (assert (= (get warning :kind) :bootstrap-hash) "bootstrap warning kind")
  (assert (= (get warning :current-hash) "fnv1a64:old") "bootstrap warning current hash")
  (assert (= (get warning :expected-hash) "fnv1a64:new") "bootstrap warning expected hash")
  (assert (string/contains? (get warning :message) "init --home /tmp/home --upgrade")
          "bootstrap warning includes upgrade command"))

(assert (nil? (policy:bootstrap-warning {:init-generated true
                                         :init-content-hash "fnv1a64:new"
                                         :binary "/tmp/bin/emacs-hypervisor"
                                         :repo-dir "/tmp/home"} "fnv1a64:new"))
        "boot-policy suppresses warning for matching init hash")

(assert (nil? (policy:bootstrap-warning {:init-generated false
                                         :init-content-hash "fnv1a64:old"
                                         :binary "/tmp/bin/emacs-hypervisor"
                                         :repo-dir "/tmp/home"} "fnv1a64:new"))
        "boot-policy suppresses warning for unmanaged init")

(reset-stub-state)
(reporting:emit-bootstrap-warning {:init-generated true
                                   :init-content-hash nil
                                   :init-file "/tmp/home/init.el"
                                   :binary "/tmp/bin/emacs-hypervisor"
                                   :repo-dir "/tmp/home"} "fnv1a64:new")
(assert (= (length stub-sent-events) 1) "boot-policy emits one warning event")
(assert (= (get (get stub-sent-events 0) :topic) :warning) "boot-policy emits :warning topic")
(assert (string/contains? (wire-protocol:plist-get (get (get stub-sent-events 0) :payload) :message)
                          "has no content hash") "boot-policy missing-hash warning message")
(println "  0d. bootstrap warning policy: ok")

# ============================================================================
# 1. Boot policy preserves invalid, blocked, and preflight detail shapes.
# ============================================================================

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       {:reports planned-unit-reports} (policy:derive-unit-reports units (graph:known-names packages)
       planned-package-reports env executable-reports)
       invalid-root (graph:find-entry planned-package-reports "invalid-root")
       blocked-unit (graph:find-entry planned-unit-reports "blocked-by-invalid-package-unit")
       invalid-after (graph:find-entry planned-unit-reports "invalid-after-unit")
       preflight-bad (graph:find-entry planned-unit-reports "preflight-bad-unit")]
  (assert (= (graph:entry-field invalid-root :status) :invalid) "boot-policy invalid package status")
  (assert (= (graph:entry-field invalid-root :reason) :missing-deps) "boot-policy invalid package reason")
  (assert (= (graph:entry-field (graph:entry-field invalid-root :details) :missing) (list "ghost-pkg"))
          "boot-policy invalid package details")
  (assert (= (graph:entry-field blocked-unit :status) :skipped) "boot-policy blocked unit status")
  (assert (= (graph:entry-field blocked-unit :reason) :blocked-by-package) "boot-policy blocked unit reason")
  (assert (= (graph:entry-field (graph:entry-field blocked-unit :details) :blockers) (list "invalid-root"))
          "boot-policy blocked unit details")
  (assert (= (graph:entry-field invalid-after :reason) :missing-after-units) "boot-policy invalid after reason")
  (assert (= (graph:entry-field (graph:entry-field invalid-after :details) :missing) (list "ghost-unit"))
          "boot-policy invalid after details")
  (assert (= (graph:entry-field preflight-bad :status) :skipped) "boot-policy preflight status")
  (assert (= (graph:entry-field preflight-bad :reason) :preflight) "boot-policy preflight reason")
  (assert (= (graph:entry-field (graph:entry-field preflight-bad :details) :env) (list "HYPERVISOR_MISSING_ENV"))
          "boot-policy preflight env details")
  (assert (= (graph:entry-field (graph:entry-field preflight-bad :details) :executable)
             (list "definitely-not-installed-command")) "boot-policy preflight executable details"))

(let* [{:reports reports} (policy:derive-unit-reports (list {:name "feature-unit"
                                                            :requires (list "project")
                                                            :after (list)
                                                            :env (list)
                                                            :executable (list)
                                                            :body '(progn :feature-ok)}) () () env ())
       feature-unit (graph:find-entry reports "feature-unit")]
  (assert (= (graph:entry-field feature-unit :status) :ok)
          "boot-policy treats :requires as runtime features, not declared package names"))

(println "  1. boot policy: ok")

# ============================================================================
# 1a. Boot policy marks duplicate names invalid and threads source provenance.
# ============================================================================

(let* [dup-packages (list {:name "dup-pkg" :deps (list) :source {:file "config.org" :heading "Tools" :line 3}}
                          {:name "dup-pkg" :deps (list)} {:name "unique-pkg" :deps (list)})
       {:reports reports :duplicates duplicates} (policy:derive-package-reports dup-packages)
       dup-report (graph:find-entry reports "dup-pkg")
       unique-report (graph:find-entry reports "unique-pkg")]
  (assert (= duplicates (list "dup-pkg")) "boot-policy collects duplicate package names")
  (assert (= (graph:entry-field dup-report :status) :invalid) "duplicate package status")
  (assert (= (graph:entry-field dup-report :reason) :duplicate-name) "duplicate package reason")
  (assert (= (graph:entry-field (graph:entry-field dup-report :details) :occurrences) 2)
          "duplicate package occurrence count")
  (assert (= (graph:entry-field (graph:entry-field dup-report :source) :heading) "Tools")
          "duplicate package report carries source")
  (assert (= (graph:entry-field unique-report :status) :ok) "unique package unaffected by duplicates"))

(let* [dup-units (list {:name "dup-unit" :requires (list) :after (list) :env (list) :executable (list) :body '(progn t)}
                       {:name "dup-unit"
                        :requires (list)
                        :after (list)
                        :env (list)
                        :executable (list)
                        :body '(progn 2 t)})
       {:reports reports} (policy:derive-unit-reports dup-units () () env ())
       dup-report (graph:find-entry reports "dup-unit")]
  (assert (= (graph:entry-field dup-report :status) :invalid) "duplicate unit status")
  (assert (= (graph:entry-field dup-report :reason) :duplicate-name) "duplicate unit reason"))

(let* [sourced-units (list {:name "sourced-unit"
                            :index 0
                            :requires (list)
                            :after (list)
                            :env (list)
                            :executable (list)
                            :body '(progn t)
                            :source {:file "config.org" :heading "Magit" :line 14}}
                           {:name "sourced-bad-unit"
                            :index 1
                            :requires (list)
                            :after (list)
                            :env (list "HYPERVISOR_MISSING_ENV")
                            :executable (list)
                            :body '(progn t)
                            :source {:file "config.org" :heading "Broken" :line 30}})
       {:reports reports} (policy:derive-unit-reports sourced-units () () env ())
       ready-report (graph:find-entry reports "sourced-unit")
       preflight-report (graph:find-entry reports "sourced-bad-unit")]
  (assert (= (graph:entry-field (graph:entry-field ready-report :source) :file) "config.org")
          "ready unit report carries source file")
  (assert (= (graph:entry-field (graph:entry-field ready-report :source) :line) 14)
          "ready unit report carries source line")
  (assert (= (graph:entry-field preflight-report :status) :skipped) "sourced preflight unit skipped")
  (assert (= (graph:entry-field (graph:entry-field preflight-report :source) :heading) "Broken")
          "preflight unit report carries source heading"))

## Executed and failed unit reports keep declaration provenance.
(let* [sourced-units (list {:name "sourced-run-unit"
                            :index 0
                            :requires (list)
                            :after (list)
                            :env (list)
                            :executable (list)
                            :body '(progn t)
                            :source {:file "config.org" :heading "Magit" :line 14}}
                           {:name "sourced-fail-unit"
                            :index 1
                            :requires (list)
                            :after (list)
                            :env (list)
                            :executable (list)
                            :body '(error "boom")
                            :source {:file "config.org" :heading "Broken" :line 30}})
       {:reports planned-unit-reports} (policy:derive-unit-reports sourced-units () () env ())
       unit-plan (planning:derive-unit-plan sourced-units planned-unit-reports)]
  (reset-stub-state)
  (push stub-await-responses (stub-response 40 true :sourced-ok))
  (push stub-await-responses (stub-response 41 false nil :error "(error \"boom\")"))
  (let* [{:reports unit-reports} (execution:execute-unit-plan (planning:plan-items unit-plan) () 40)
         executed (graph:find-entry unit-reports "sourced-run-unit")
         failed (graph:find-entry unit-reports "sourced-fail-unit")]
    (assert (= (graph:entry-field executed :status) :ok) "sourced unit executes")
    (assert (= (graph:entry-field (graph:entry-field executed :source) :line) 14) "executed unit report carries source")
    (assert (= (graph:entry-field failed :status) :failed) "sourced unit failure recorded")
    (assert (= (graph:entry-field (graph:entry-field failed :source) :heading) "Broken")
            "failed unit report carries source")))

(println "  1a. duplicate names and source provenance: ok")

# ============================================================================
# 1b. A genuine :after cycle marks every member invalid with :cycle.
# ============================================================================

(let* [cycle-units (list {:name "cycle-a"
                          :index 0
                          :requires (list)
                          :after (list "cycle-b")
                          :env (list)
                          :executable (list)
                          :body '(progn t)}
                         {:name "cycle-b"
                          :index 1
                          :requires (list)
                          :after (list "cycle-a")
                          :env (list)
                          :executable (list)
                          :body '(progn t)}
                         {:name "cycle-free"
                          :index 2
                          :requires (list)
                          :after (list)
                          :env (list)
                          :executable (list)
                          :body '(progn t)})
       cycle-names (graph:cycle-names cycle-units :after (graph:known-names cycle-units))
       {:reports reports :cycles cycles} (policy:derive-unit-reports cycle-units () () env ())
       cycle-a (graph:find-entry reports "cycle-a")
       cycle-b (graph:find-entry reports "cycle-b")
       cycle-free (graph:find-entry reports "cycle-free")]
  (assert (= cycle-names (list "cycle-a" "cycle-b")) "cycle-names finds mutually :after units")
  (assert (= cycles (list "cycle-a" "cycle-b")) "derive-unit-reports records cycle members")
  (assert (= (graph:entry-field cycle-a :status) :invalid) "cycle unit a status")
  (assert (= (graph:entry-field cycle-a :reason) :cycle) "cycle unit a reason")
  (assert (= (graph:entry-field (graph:entry-field cycle-a :details) :members) (list "cycle-a" "cycle-b"))
          "cycle report lists all cycle members")
  (assert (= (graph:entry-field cycle-b :status) :invalid) "cycle unit b status")
  (assert (= (graph:entry-field cycle-b :reason) :cycle) "cycle unit b reason")
  (assert (= (graph:entry-field cycle-free :status) :ok) "unit outside the cycle unaffected"))
(println "  1b. genuine :after cycle: ok")

# ============================================================================
# 2. Planning emits dependency order, not declaration order.
# ============================================================================

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       {:reports planned-unit-reports} (policy:derive-unit-reports units (graph:known-names packages)
       planned-package-reports env executable-reports)
       package-plan (planning:derive-package-plan packages planned-package-reports)
       unit-plan (planning:derive-unit-plan units planned-unit-reports)]
  (reset-stub-state)
  (reporting:emit-report-message :planned :packages planned-package-reports)
  (planning:emit-plan-message package-plan)
  (planning:emit-plan-message unit-plan)
  (let* [report-event (first (filter (fn [event] (= (get event :topic) :report)) stub-sent-events))
         report-payload (get report-event :payload)
         report-items (get report-payload :payload)
         first-report (first report-items)]
    (assert (= (get report-event :topic) :report) "reporting emits :report topic")
    (assert (= (get report-payload :stage) :planned) "report payload preserves stage")
    (assert (= (get report-payload :phase) :packages) "report payload preserves phase")
    (assert (= (length report-items) (length planned-package-reports)) "startup report payload preserves count")
    (assert (= (wire-protocol:plist-get first-report :name) "ui-pkg") "startup report payload preserves report names")
    (assert (= (wire-protocol:plist-get first-report :status) :ok) "startup report payload preserves report status")
    (assert (= (wire-protocol:plist-get first-report :reason) :ready) "startup report payload preserves report reason")
    (assert (not (nil? (wire-protocol:sexp-string (wire-protocol:make-report-message :planned :packages report-items))))
            "report payload is wire serializable"))
  (assert (= (map (fn [{:name name}] name) (planning:plan-items package-plan))
             (list "core-pkg" "ui-pkg" "runtime-fail-pkg" "runtime-fail-dependent")) "planning package order")
  (assert (= (planning:plan-names package-plan) (list "core-pkg" "ui-pkg" "runtime-fail-pkg" "runtime-fail-dependent"))
          "planning exposes package names in execution order")
  (assert (= (map (fn [{:name name}] name) (planning:plan-items unit-plan))
             (list "core-ui-unit" "ui-unit" "blocked-by-runtime-package-unit" "independent-unit" "runtime-fail-unit"
                   "after-runtime-fail-unit")) "planning unit order")
  (assert (= (length (filter (fn [event] (= (get event :topic) :plan)) stub-sent-events)) 2)
          "planning emits two plan messages"))
(println "  2. planning: ok")

(reset-stub-state)
(reporting:emit-report-logs "unit"
                            (list (graph:make-report "ok-unit" :ok :ready ())
                                  (graph:make-report "bad-detail-unit" :skipped
                                                     :blocked-by-package {:blockers (list "bad-package")
                                                     :body '(progn (lambda () :opaque))})
                                  (graph:make-report "other-bad-detail-unit" :invalid
                                                     :cycle {:members (list "other-bad-detail-unit")
                                                     :body '(progn (lambda () :opaque))})))
(let* [event (get stub-sent-events 0)
       payload (get event :payload)]
  (assert (= (length stub-sent-events) 1) "report logs emit one aggregate warning")
  (assert (= (get event :topic) :log) "report logs emit log topic")
  (assert (= (wire-protocol:plist-get payload :message) "unit reports not ok: 2 of 3")
          "report logs summarize non-ok reports without stringifying details")
  (assert (= (wire-protocol:plist-get payload :count) 2) "report logs include non-ok count")
  (assert (= (wire-protocol:plist-get payload :total) 3) "report logs include report total"))
(reset-stub-state)
(reporting:emit-report-message :executed
                               :units (list (graph:make-report "opaque-detail-unit" :skipped
                                            :blocked-by-package (list :blockers (list "bad-package")))))
(let* [event (first (filter (fn [event] (= (get event :topic) :report)) stub-sent-events))
       payload (get event :payload)
       items (get payload :payload)
       report (first items)
       details (wire-protocol:plist-get report :details)]
  (assert (= (get event :topic) :report) "report message emits report topic")
  (assert (= (wire-protocol:plist-get report :name) "opaque-detail-unit") "report message preserves report name")
  (assert (= (wire-protocol:plist-get report :status) :skipped) "report message preserves report status")
  (assert (= (wire-protocol:plist-get report :reason) :blocked-by-package) "report message preserves report reason")
  (assert (= (wire-protocol:plist-get details :blockers) (list "bad-package")) "report message preserves detail fields")
  (assert (not (nil? (wire-protocol:sexp-string (wire-protocol:make-report-message :executed :units items))))
          "report message is wire serializable"))
(println "  2a. report logs: ok")

# ============================================================================
# 3. Per-package execution: one eval per package, with failure isolation.
# ============================================================================

## 3. Success: begin eval + one run-package eval per package + finished eval.
(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-response 10 true nil))  ## begin
  (push stub-read-messages (stub-response 11 true nil))  ## core-pkg
  (push stub-read-messages (stub-response 12 true nil))  ## ui-pkg
  (push stub-read-messages (stub-response 13 true nil))  ## runtime-fail-pkg
  (push stub-read-messages (stub-response 14 true nil))  ## runtime-fail-dependent
  (push stub-read-messages (stub-response 15 true nil))  ## finished
  (let* [{:reports package-reports :installed installed :next-id next-id :ok ok?} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 10)
         core (graph:find-entry package-reports "core-pkg")]
    (assert (= next-id 16) "tracker next id (begin + 4 packages + finished)")
    (assert (= ok? true) "tracker reports successful per-package run as ok")
    (assert (= (length stub-sent-requests) 6) "tracker sends begin + one eval per package + finished")
    (let* [begin-request (get stub-sent-requests 0)
           begin-form (wire-protocol:plist-get (get begin-request :payload) :form)
           core-request (get stub-sent-requests 1)
           core-form (wire-protocol:plist-get (get core-request :payload) :form)]
      (assert (= begin-form '(emacs-hypervisor-runtime-begin-package-installation))
              "tracker brackets the loop with a begin eval")
      (assert (= core-form '(emacs-hypervisor-runtime-run-package "core-pkg")) "tracker installs one package per eval")
      (assert (nil? (get core-request :form-string)) "tracker sends structured eval form instead of string form"))
    (assert (= (length installed) 4) "tracker records installed packages")
    (assert (= (length package-reports) 4) "tracker returns one report per package")
    (assert (= (graph:entry-field core :status) :ok) "tracker success package report status")
    (assert (= (graph:entry-field core :reason) :installed) "tracker success package report reason")))
(println "  3. per-package execution: ok")

## 3a. Local package name flows into the per-package run form.
(let* [local-plan-names (list "elle-lsp-bridge")
       planned-package-reports (list (graph:make-report "elle-lsp-bridge" :ok :ready (list)))]
  (reset-stub-state)
  (push stub-read-messages (stub-response 50 true nil))  ## begin
  (push stub-read-messages (stub-response 51 true nil))  ## elle-lsp-bridge
  (push stub-read-messages (stub-response 52 true nil))  ## finished
  (execution:execute-package-entry-plan-tracker local-plan-names planned-package-reports 50)
  (let* [run-request (get stub-sent-requests 1)
         run-form (wire-protocol:plist-get (get run-request :payload) :form)]
    (assert (= run-form '(emacs-hypervisor-runtime-run-package "elle-lsp-bridge"))
            "run form sends local package name from the Elle plan")))
(println "  3a. local package name run form: ok")

(let* [decoded (wire-protocol:from-wire-session-data (quote (:packages ((:name "transient" :repo "magit/transient"
                                                            :host nil :branch "main" :tag nil :ref nil :deps ()
                                                            :local nil :lisp-dir nil :installed transient) (:name "magit"
                                                            :repo nil :host nil :branch nil :tag nil :ref nil
                                                            :deps ("transient") :local nil :lisp-dir nil :installed nil))
                                                            :units () :env ())))
       packages (get decoded :packages)
       {:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-response 60 true nil))  ## begin
  (push stub-read-messages (stub-response 61 true nil))  ## magit
  (push stub-read-messages (stub-response 62 true nil))  ## finished
  (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan) planned-package-reports 60)
  (let* [run-request (get stub-sent-requests 1)
         run-form (wire-protocol:plist-get (get run-request :payload) :form)]
    (assert (= run-form '(emacs-hypervisor-runtime-run-package "magit"))
            "run form sends decoded live package name from the Elle plan")))
(println "  3b. decoded live package run form: ok")

## 3c. Failure isolation: a failed package does not fail the others.
(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-response 20 true nil))  ## begin
  (push stub-read-messages (stub-response 21 true nil))  ## core-pkg
  (push stub-read-messages (stub-response 22 true nil))  ## ui-pkg
  (push stub-read-messages (stub-response 23 false nil :error "clone failed"))  ## runtime-fail-pkg
  (push stub-read-messages (stub-response 24 false nil :error "dep missing"))  ## runtime-fail-dependent
  (push stub-read-messages (stub-response 25 true nil))  ## finished
  (let* [{:reports package-reports :installed installed :next-id next-id :ok ok?} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 20)
         core (graph:find-entry package-reports "core-pkg")
         ui (graph:find-entry package-reports "ui-pkg")
         runtime-fail (graph:find-entry package-reports "runtime-fail-pkg")
         dependent (graph:find-entry package-reports "runtime-fail-dependent")]
    (assert (= next-id 26) "tracker isolation next id")
    (assert (= ok? false) "tracker reports overall failure when any package fails")
    (assert (= (length installed) 2) "tracker keeps the successful packages installed")
    (assert (= (graph:entry-field core :status) :ok) "isolation keeps the first package ok")
    (assert (= (graph:entry-field ui :status) :ok) "isolation keeps the second package ok")
    (assert (= (graph:entry-field runtime-fail :status) :failed) "isolation marks the failing package failed")
    (assert (= (graph:entry-field (graph:entry-field runtime-fail :details) :source) :eval)
            "failed package report source is eval")
    (assert (= (graph:entry-field (graph:entry-field runtime-fail :details) :error) "clone failed")
            "failed package report preserves the error detail")
    (assert (= (graph:entry-field dependent :status) :failed) "isolation marks the dependent failed too")))
(println "  3c. failure isolation: ok")

## 3c1. A multiline failure keeps only the first error line.
(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-response 30 true nil))  ## begin
  (push stub-read-messages
        (stub-response 31 false nil :error "(void-function transient--set-layout)\n  backtrace()\n  eval(...)"))  ## core-pkg
  (push stub-read-messages (stub-response 32 true nil))  ## ui-pkg
  (push stub-read-messages (stub-response 33 true nil))  ## runtime-fail-pkg
  (push stub-read-messages (stub-response 34 true nil))  ## runtime-fail-dependent
  (push stub-read-messages (stub-response 35 true nil))  ## finished
  (let* [{:reports package-reports} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 30)
         core (graph:find-entry package-reports "core-pkg")
         error-detail (graph:entry-field (graph:entry-field core :details) :error)]
    (assert (= error-detail "(void-function transient--set-layout)") "multiline failure keeps only the first error line")))
(println "  3c1. multiline failure detail: ok")

## 3d. Scale: the per-package loop handles many packages.
(let* [many-packages (map (fn [i]
                            {:name (concat "live-pkg" (number->string i))
                             :deps (list)
                             :repo nil
                             :host nil
                             :branch nil
                             :tag nil
                             :ref nil
                             :local nil
                             :lisp-dir nil}) (->list (range 0 80)))
       {:reports planned-package-reports} (policy:derive-package-reports many-packages)
       package-plan (planning:derive-package-plan many-packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-response 80 true nil))  ## begin
  (map (fn [i] (push stub-read-messages (stub-response (+ 81 i) true nil))) (->list (range 0 80)))
  (push stub-read-messages (stub-response 161 true nil))  ## finished
  (let* [{:reports package-reports :installed installed :next-id next-id :ok ok?} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 80)]
    (assert (= next-id 162) "tracker large plan next id (begin + 80 packages + finished)")
    (assert (= ok? true) "tracker large plan all ok")
    (assert (= (length installed) 80) "tracker large plan installs all packages")
    (assert (= (length package-reports) 80) "tracker large plan report count")))
(println "  3d. large per-package plan: ok")

(let* [many-planned (map (fn [i] (graph:make-report (concat "pkg" (number->string i)) :ok :ready ()))
                         (->list (range 0 120)))
       many-executed (map (fn [i] (graph:make-report (concat "pkg" (number->string i)) :ok :executed ()))
                          (->list (range 0 120)))
       merged (planning:merge-executed-reports many-planned many-executed)]
  (assert (= (length merged) 120) "large merge preserves report count")
  (assert (= (graph:entry-field (first merged) :reason) :executed) "large merge replaces first report")
  (assert (= (graph:entry-field (last merged) :reason) :executed) "large merge replaces last report"))
(println "  3f. large report merge: ok")

(reset-stub-state)
(let [{:reports reports :installed installed :next-id next-id} (execution:execute-package-entry-plan-tracker () () 30)]
  (assert (= next-id 30) "empty package plan preserves next id")
  (assert (empty? reports) "empty package plan has no reports")
  (assert (empty? installed) "empty package plan has no installed packages")
  (assert (= (length stub-sent-requests) 0) "empty package plan sends no eval requests"))
(println "  3g. empty package plan: ok")

# ============================================================================
# 4. Unit execution preserves runtime failure propagation.
# ============================================================================

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       {:reports planned-unit-reports} (policy:derive-unit-reports units (graph:known-names packages)
       planned-package-reports env executable-reports)
       package-reports (list (graph:make-report "ui-pkg" :ok :executed (list "core-pkg"))
                             (graph:make-report "runtime-fail-dependent" :skipped
                                                :blocked-by-package (list :blockers (list "runtime-fail-pkg")))
                             (graph:make-report "core-pkg" :ok :executed (list))
                             (graph:make-report "invalid-root" :invalid :missing-deps (list :missing (list "ghost-pkg")))
                             (graph:make-report "runtime-fail-pkg" :ok :executed (list)))
       unit-plan (planning:derive-unit-plan units planned-unit-reports)]
  (reset-stub-state)
  (push stub-await-responses (stub-response 20 true :core-unit-ok))
  (push stub-await-responses (stub-response 21 true :ui-unit-ok))
  (push stub-await-responses (stub-response 22 true :blocked-runtime-package-ok))
  (push stub-await-responses (stub-response 23 true :independent-ok))
  (push stub-await-responses (stub-response 24 false nil :error "(error \"simulated unit failure\")"))
  (push stub-await-responses (stub-response 25 true :after-fail-ok))
  (let* [{:reports unit-reports :next-id next-id} (execution:execute-unit-plan (planning:plan-items unit-plan)
         package-reports 20)
         core (graph:find-entry unit-reports "core-ui-unit")
         blocked-by-package (graph:find-entry unit-reports "blocked-by-runtime-package-unit")
         independent (graph:find-entry unit-reports "independent-unit")
         runtime-fail (graph:find-entry unit-reports "runtime-fail-unit")
         ui (graph:find-entry unit-reports "ui-unit")
         after-runtime-fail (graph:find-entry unit-reports "after-runtime-fail-unit")]
    (assert (= next-id 26) "unit next id")
    (assert (= (length stub-sent-requests) 6) "unit execution only evals runnable items")
    (assert (= (graph:entry-field core :status) :ok) "unit core status")
    (assert (= (graph:entry-field independent :status) :ok) "unit independent status")
    (assert (= (graph:entry-field ui :status) :ok) "unit ui status")
    (assert (= (graph:entry-field blocked-by-package :status) :ok) "unit runs after successful package phase")
    (assert (= (graph:entry-field runtime-fail :status) :failed) "unit runtime failure")
    (assert (= (graph:entry-field (graph:entry-field runtime-fail :details) :source) :eval)
            "unit runtime failure source")
    (assert (= (graph:entry-field after-runtime-fail :status) :ok) "unit execution continues after runtime failure")))
(println "  4. unit execution: ok")

# ============================================================================
# 4a. A package that failed at install time gates its dependent units.
# ============================================================================

(let* [gate-units (list {:name "gated-unit"
                         :index 0
                         :requires (list "install-fail-pkg")
                         :after (list)
                         :env (list)
                         :executable (list)
                         :body '(progn :gated)}
                        {:name "free-unit"
                         :index 1
                         :requires (list)
                         :after (list)
                         :env (list)
                         :executable (list)
                         :body '(progn :free)})
       {:reports planned-unit-reports} (policy:derive-unit-reports gate-units () () env ())
       unit-plan (planning:derive-unit-plan gate-units planned-unit-reports)
       package-reports (list (graph:make-report "install-fail-pkg" :failed
                                                :execution {:source :eval :error "clone failed"}))]
  (assert (= (graph:entry-field (graph:find-entry planned-unit-reports "gated-unit") :status) :ok)
          "gated unit is planned :ok before package execution")
  (reset-stub-state)
  (push stub-await-responses (stub-response 70 true :free-ok))
  (let* [{:reports unit-reports :next-id next-id} (execution:execute-unit-plan (planning:plan-items unit-plan)
         package-reports 70)
         gated (graph:find-entry unit-reports "gated-unit")
         free (graph:find-entry unit-reports "free-unit")]
    (assert (= next-id 71) "package-gated unit consumes no rpc id")
    (assert (= (length stub-sent-requests) 1) "no eval request is sent for a package-gated unit")
    (assert (= (graph:entry-field gated :status) :skipped) "package-gated unit is skipped")
    (assert (= (graph:entry-field gated :reason) :blocked-by-package) "package-gated unit reason")
    (assert (= (graph:entry-field (graph:entry-field gated :details) :blockers) (list "install-fail-pkg"))
            "package-gated unit names the failed package")
    (assert (= (graph:entry-field free :status) :ok) "unit without failed requires still executes")))

## :requires entries that are plain Emacs features (no package report) never gate.
(let* [feature-units (list {:name "feature-gated-unit"
                            :index 0
                            :requires (list "some-feature")
                            :after (list)
                            :env (list)
                            :executable (list)
                            :body '(progn :feature)})
       {:reports planned-unit-reports} (policy:derive-unit-reports feature-units () () env ())
       unit-plan (planning:derive-unit-plan feature-units planned-unit-reports)
       package-reports (list (graph:make-report "install-fail-pkg" :failed
                                                :execution {:source :eval :error "clone failed"}))]
  (reset-stub-state)
  (push stub-await-responses (stub-response 80 true :feature-ok))
  (let* [{:reports unit-reports} (execution:execute-unit-plan (planning:plan-items unit-plan) package-reports 80)
         feature-unit (graph:find-entry unit-reports "feature-gated-unit")]
    (assert (= (length stub-sent-requests) 1) "feature-requiring unit still evaluated")
    (assert (= (graph:entry-field feature-unit :status) :ok)
            "feature :requires without a package report does not gate execution")))
(println "  4a. failed package gates dependent units: ok")

# ============================================================================
# 4b. Env package-list values are trimmed and empties dropped.
# ============================================================================

(assert (= (execution:parse-package-list-value "magit, transient ,,  vertico") (list "magit" "transient" "vertico"))
        "package list env values are trimmed per element")
(assert (= (execution:parse-package-list-value nil) ()) "nil package list env value parses to empty")
(assert (= (execution:parse-package-list-value " , ") ()) "whitespace-only package list parses to empty")
(println "  4b. env package list trimming: ok")

# ============================================================================
# 5. Runtime form loaders emit Elisp list bindings, not vectors.
# ============================================================================

(let* [form (runtime-module-loader:load-module-form {:path "report-core.el" :source "(provide 'report-core)"}
                                                    :report-core-ready)
       first-loader (first form)
       bindings (second first-loader)]
  (assert (= (syntax->datum (first first-loader)) 'let) "runtime loader emits let")
  (assert (= (type-of bindings) :list) "runtime loader let bindings are a list")
  (assert (= (syntax->datum (first (first bindings))) 'emacs-hypervisor-source-path)
          "runtime loader first binding names source path"))

(println "  6. runtime form loader shape: ok")

# ============================================================================
# 7. Benchmark module: metric stripping and enable gating.
# ============================================================================

(let [payload (list :form '(progn t) :metric-name :run-unit :metric-kind :unit :phase :startup :item-name "u")]
  (assert (= (benchmark-enabled-module:eval-payload payload) payload)
          "enabled benchmark keeps metric fields in eval payload")
  (assert (= (benchmark-disabled-module:eval-payload payload) (list :form '(progn t)))
          "disabled benchmark strips metric fields from eval payload"))

## Stripping is shallow: nested lists and maps inside kept values survive.
(let [nested-payload (list :form '(progn (setq x '(:metric-name :inner :phase :inner-phase)) t)
                           :context {:phase :keep-me} :metric-name :outer :phase :startup)]
  (assert (= (benchmark-disabled-module:eval-payload nested-payload)
             (list :form '(progn (setq x '(:metric-name :inner :phase :inner-phase)) t) :context {:phase :keep-me}))
          "metric stripping preserves nested values that contain metric-like keys"))

(reset-stub-state)
(benchmark-disabled-module:emit-metric :planning :noop 1.0 nil nil)
(assert (= (length stub-sent-events) 0) "disabled benchmark emits no metric events")
(benchmark-enabled-module:emit-metric :planning :probe 2.5 :planning "probe-item")
(assert (= (length stub-sent-events) 1) "enabled benchmark emits a metric event")
(assert (= (get (get stub-sent-events 0) :topic) :metric) "benchmark metric event topic")
(println "  7. benchmark module: ok")

# ============================================================================
# 8. Runtime form installers list modules in manifest order (static check).
# ============================================================================

(defn runtime-forms-repo-file [relative]
  (if (file/exists? relative) relative (string "../../" relative)))

(defn manifest-module-names []
  (map (fn [line] (first (string/split (string/trim line) "|")))
       (filter (fn [line] (not (= (string/trim line) "")))
               (file/lines (runtime-forms-repo-file "elle/runtime-forms/modules.manifest")))))

## The names referenced by install-config-surface-form and
## install-session-helpers-form, in source order. Both installers are
## defined in that order, so occurrence order in the file is install order.
(defn runtime-forms-install-order []
  (->list (map (fn [segment] (first (string/split segment "\"")))
               (rest (string/split (file/read (runtime-forms-repo-file "elle/runtime-forms.lisp"))
                                   "load-module-by-name manifest \"")))))

(let [manifest-names (manifest-module-names)
      install-names (runtime-forms-install-order)]
  (assert (= (length manifest-names) 21) "modules.manifest entry count")
  (assert (= install-names manifest-names) "runtime-forms.lisp installs modules in modules.manifest order"))
(println "  8. runtime form module order: ok")

(println "tests/elle/hypervisor-runtime.lisp: all tests passed")
