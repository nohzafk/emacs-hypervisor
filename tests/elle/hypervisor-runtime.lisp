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
(include-file "../../elle/preflight.lisp")
(include-file "../../elle/boot-policy.lisp")
(include-file "../../elle/reporting.lisp")
(include-file "../../elle/planning.lisp")
(include-file "../../elle/execution.lisp")
(include-file "../../elle/extensions.lisp")
(include-file "../../elle/extension-mermaid.lisp")
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
(def extensions (emacs-hypervisor-extensions-module protocol))
(def mermaid-extension (emacs-hypervisor-mermaid-extension-module extensions))
(def runtime-module-loader (emacs-hypervisor-runtime-forms-module-loader-module))

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
                                                            :extensions (:extensions-enabled t :extensions "mermaid"
                                                            :mermaid-enabled t))))
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
                         {:name "missing-bin" :executable (list "definitely-not-installed-command")})
       probe-env (list {:name "PATH" :value "/bin:/usr/bin"})
       {:next-id next-id :reports reports} (preflight:probe-executables probe-units 10 probe-env)
       has-sh (graph:find-entry reports "has-sh")
       missing-bin (graph:find-entry reports "missing-bin")]
  (assert (= next-id 10) "path preflight does not consume rpc ids")
  (assert (= (get has-sh :missing) (list)) "path preflight finds present executable")
  (assert (= (get missing-bin :missing) (list "definitely-not-installed-command"))
          "path preflight reports missing executable"))
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
# 3. Batch execution treats successful Emacs batch as authoritative.
# ============================================================================

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "core-pkg"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "ui-pkg"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "runtime-fail-pkg"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "runtime-fail-dependent"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :finished :reason "completed"}))
  (push stub-read-messages
        (stub-response 10 true
                       (list {:name "core-pkg" :status :installed}
                             {:name "ui-pkg" :status :installed :deps (list "core-pkg")}
                             {:name "runtime-fail-pkg" :status :installed}
                             {:name "runtime-fail-dependent" :status :installed :deps (list "runtime-fail-pkg")})))
  (let* [{:reports package-reports :installed installed :next-id next-id :ok ok?} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 10)
         core (graph:find-entry package-reports "core-pkg")]
    (assert (= next-id 11) "tracker next id")
    (assert (= ok? true) "tracker reports successful package batch as ok")
    (assert (= (length stub-sent-requests) 1) "tracker sends one batch eval")
    (let* [batch-request (get stub-sent-requests 0)
           batch-form (wire-protocol:plist-get (get batch-request :payload) :form)]
      (assert (= batch-form
                 '(emacs-hypervisor-runtime-install-package-batch '("core-pkg" "ui-pkg" "runtime-fail-pkg"
                 "runtime-fail-dependent"))) "tracker sends planned package names to install-package-batch")
      (assert (nil? (get batch-request :form-string)) "tracker sends structured eval form instead of string form"))
    (assert (= (length installed) 4) "tracker success records installed package events")
    (assert (= (length package-reports) 4) "tracker success returns package event reports")
    (assert (= (graph:entry-field core :status) :ok) "tracker success package report status")
    (assert (= (graph:entry-field core :reason) :installed) "tracker success package report reason")))
(println "  3. batch execution: ok")

(let* [local-plan-names (list "elle-lsp-bridge")
       planned-package-reports (list (graph:make-report "elle-lsp-bridge" :ok :ready (list)))]
  (reset-stub-state)
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "elle-lsp-bridge"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :finished :reason "completed"}))
  (push stub-read-messages (stub-response 50 true (list {:name "elle-lsp-bridge" :status :installed})))
  (execution:execute-package-entry-plan-tracker local-plan-names planned-package-reports 50)
  (let* [batch-request (get stub-sent-requests 0)
         batch-form (wire-protocol:plist-get (get batch-request :payload) :form)]
    (assert (= batch-form '(emacs-hypervisor-runtime-install-package-batch '("elle-lsp-bridge")))
            "batch sends local package names from the Elle plan")))
(println "  3a. local package name batch: ok")

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
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "magit"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :finished :reason "completed"}))
  (push stub-read-messages (stub-response 60 true (list {:name "magit" :status :installed})))
  (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan) planned-package-reports 60)
  (let* [batch-request (get stub-sent-requests 0)
         batch-form (wire-protocol:plist-get (get batch-request :payload) :form)]
    (assert (= batch-form '(emacs-hypervisor-runtime-install-package-batch '("magit")))
            "batch sends decoded live package names from the Elle plan")))
(println "  3b. decoded live package batch: ok")

(let* [planned-package-reports (list (graph:make-report "consult" :ok :installed (list))
                                     (graph:make-report "websocket" :ok :installed (list))
                                     (graph:make-report "consult-snapfile" :ok :ready (list "consult" "websocket")))]
  (reset-stub-state)
  (push stub-read-messages
        (stub-event :package {:phase :packages :kind :failed :name "consult-snapfile" :reason "clone failed"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :finished :reason "completed"}))
  (push stub-read-messages (stub-response 65 false nil :error "clone failed"))
  (let* [{:reports package-reports :installed installed :next-id next-id} (execution:execute-package-entry-plan-tracker (list "consult-snapfile")
         planned-package-reports 65)
         snapfile (graph:find-entry package-reports "consult-snapfile")]
    (assert (= next-id 66) "tracker raw wire plist next id")
    (assert (empty? installed) "tracker raw wire plist reports no installed packages")
    (assert (= (graph:entry-field snapfile :status) :failed) "tracker raw wire plist failure status")
    (assert (= (graph:entry-field (graph:entry-field snapfile :details) :error) "clone failed")
            "tracker error response preserves error detail")))
(println "  3b1. package error response: ok")

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "core-pkg"}))
  (push stub-read-messages (stub-event :package {:phase :packages :kind :installed :name "ui-pkg"}))
  (push stub-read-messages
        (stub-event :package {:phase :packages :kind :failed :name "runtime-fail-pkg" :reason "runtime failed"}))
  (push stub-read-messages (stub-response 66 false nil :error "runtime failed"))
  (let* [{:reports package-reports :installed installed :next-id next-id} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 66)
         core (graph:find-entry package-reports "core-pkg")
         ui (graph:find-entry package-reports "ui-pkg")
         runtime-fail (graph:find-entry package-reports "runtime-fail-pkg")
         dependent (graph:find-entry package-reports "runtime-fail-dependent")]
    (assert (= next-id 67) "tracker mixed package events next id")
    (assert (= (length installed) 2) "tracker mixed package events installed count")
    (assert (= (graph:entry-field core :status) :ok) "tracker mixed keeps installed root ok")
    (assert (= (graph:entry-field ui :status) :ok) "tracker mixed keeps installed dependent ok")
    (assert (= (graph:entry-field runtime-fail :status) :failed) "tracker mixed failed package status")
    (assert (= (graph:entry-field dependent :status) :failed) "tracker mixed missing event uses batch error")))
(println "  3b2. mixed package events: ok")

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages (stub-response 40 false nil :error "package install failed"))
  (let* [{:reports package-reports :installed installed :next-id next-id} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 40)
         core (graph:find-entry package-reports "core-pkg")
         ui (graph:find-entry package-reports "ui-pkg")
         runtime-fail (graph:find-entry package-reports "runtime-fail-pkg")
         blocked (graph:find-entry package-reports "runtime-fail-dependent")]
    (assert (= next-id 41) "tracker failed batch next id")
    (assert (empty? installed) "tracker reports no installed on batch failure")
    (assert (= (graph:entry-field core :status) :failed) "tracker fails all packages on batch failure")
    (assert (= (graph:entry-field ui :status) :failed) "tracker fails ui on batch failure")
    (assert (= (graph:entry-field (graph:entry-field ui :details) :source) :eval) "tracker failure source is eval")
    (assert (= (graph:entry-field (graph:entry-field ui :details) :error) "package install failed")
            "tracker failure error detail")
    (assert (= (graph:entry-field runtime-fail :status) :failed) "tracker fails missing root after batch failure")
    (assert (= (graph:entry-field blocked :status) :failed) "tracker fails dependents after batch failure")))
(println "  3c. tracker batch failure: ok")

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages
        (stub-response 45 false nil :error "(void-function transient--set-layout)\n  backtrace()\n  eval(...)"))
  (let* [{:reports package-reports :installed installed :next-id next-id} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 45)
         core (graph:find-entry package-reports "core-pkg")
         error-detail (graph:entry-field (graph:entry-field core :details) :error)]
    (assert (= next-id 46) "tracker multiline failed batch next id")
    (assert (empty? installed) "tracker multiline failure reports no installed")
    (assert (= error-detail "(void-function transient--set-layout)")
            "tracker multiline failure keeps only first error line")))
(println "  3c1. tracker multiline batch failure: ok")

(let* [{:reports planned-package-reports} (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages
        (stub-event :package {:phase :packages :kind :finished :reason "package directory permission denied"}))
  (push stub-read-messages (stub-response 70 false nil :error "package directory permission denied"))
  (let* [{:reports package-reports :installed installed :next-id next-id} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 70)
         core (graph:find-entry package-reports "core-pkg")]
    (assert (= next-id 71) "tracker nil batch next id")
    (assert (empty? installed) "tracker failed batch reports no installed packages")
    (assert (= (graph:entry-field core :status) :failed) "tracker failed batch fails package")
    (assert (= (graph:entry-field (graph:entry-field core :details) :error) "package directory permission denied")
            "tracker failed batch explains package error")))
(println "  3d. tracker package error result: ok")

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
  (push stub-read-messages
        (stub-event :package {:phase :packages :kind :finished :reason "package directory permission denied"}))
  (push stub-read-messages (stub-response 80 false nil :error "package directory permission denied"))
  (let* [{:reports package-reports :installed installed :next-id next-id} (execution:execute-package-entry-plan-tracker (planning:plan-names package-plan)
         planned-package-reports 80)]
    (assert (= next-id 81) "tracker large nil batch next id")
    (assert (empty? installed) "tracker large failed batch reports no installed packages")
    (assert (= (length package-reports) 80) "tracker large nil batch report count")
    (assert (= (graph:entry-field (first package-reports) :status) :failed)
            "tracker large nil batch first package fails")
    (assert (= (graph:entry-field (last package-reports) :status) :failed) "tracker large nil batch last package fails")))
(println "  3e. tracker large nil batch result: ok")

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
# 5. Extension dispatch returns plugin-backed Mermaid render payloads.
# ============================================================================

(def fake-mmdflux
  {:render-ascii-fit (fn [source opts] (string "+-- width=" (get opts :max-width) " " source " --+"))
   :render-svg (fn [source opts]
                 (string "<svg data-layout=\"" (get opts :layout-engine) "\" data-simplify=\""
                         (get opts :path-simplification) "\"><text>" source "</text></svg>"))})

(defn extension-request [id extension method args]
  {:kind :request :id id :op :extension-call :payload {:extension extension :method method :args args}})

(reset-stub-state)
(extensions:dispatch-extension-call (extensions:make-registry {}
                                    {:mermaid {:render (fn [args] (mermaid-extension:render fake-mmdflux args))}})
                                    (extension-request 90 :mermaid
                                                       :render {:source "flowchart LR\n  A -- \"label\" --> B"
                                                       :style :ascii
                                                       :viewport {:width 42}}))
(let* [response (get stub-sent-responses 0)
       payload (wire-protocol:from-wire (get response :payload))]
  (assert (= (get response :id) 90) "extension ASCII response id")
  (assert (= (get payload :ok) true) "extension ASCII payload ok")
  (assert (= (get payload :kind) :text) "extension ASCII payload kind")
  (assert (= (get payload :mime) "text/plain") "extension ASCII payload mime")
  (assert (string/contains? (get payload :text) "width=42") "extension ASCII forwards viewport width")
  (assert (string/contains? (get payload :text) "A -- \"label\" --> B")
          "extension ASCII passes Mermaid source through to mmdflux")
  (assert (= (get payload :renderer) :mmdflux) "extension ASCII payload renderer"))

(reset-stub-state)
(extensions:dispatch-extension-call (extensions:make-registry {}
                                    {:mermaid {:render (fn [args] (mermaid-extension:render fake-mmdflux args))}})
                                    (extension-request 91 :mermaid :render {:source "flowchart TD; A-->B" :style :ascii}))
(let* [payload (wire-protocol:from-wire (get (get stub-sent-responses 0) :payload))]
  (assert (= (get payload :kind) :text) "extension ASCII payload kind")
  (assert (= (get payload :mime) "text/plain") "extension ASCII payload mime")
  (assert (string/contains? (get payload :text) "flowchart TD; A-->B") "extension ASCII payload includes source"))

(def wide-ascii-source
  "flowchart LR
    subgraph S1[\"Stage 1 — Stable Kernel\"]
        direction TB
        A[\"Emacs home\"] --> B[\"load generated init.el\"]
        B --> C[\"kernel boots\"]
    end

    subgraph S2[\"Stage 2 — Control Plane\"]
        direction TB
        D[\"launch emacs-hypervisor serve\"]
        D --> E[\"sexp-rpc session established\"]
    end

    subgraph S3[\"Stage 3 — Session Runtime\"]
        direction TB
        F[\"emit runtime forms\"]
        F --> G[\"package planning\"]
        G --> H[\"config-unit execution\"]
        H --> I[\"reload + reports ready\"]
    end

    S1 --> S2 --> S3
")

(reset-stub-state)
(extensions:dispatch-extension-call (extensions:make-registry {}
                                    {:mermaid {:render (fn [args] (mermaid-extension:render fake-mmdflux args))}})
                                    (extension-request 92 :mermaid
                                                       :render {:source wide-ascii-source
                                                       :style :ascii
                                                       :viewport {:width 80}}))
(let* [payload (wire-protocol:from-wire (get (get stub-sent-responses 0) :payload))]
  (assert (string/contains? (get payload :text) "width=80") "wide ASCII forwards viewport width"))

(reset-stub-state)
(extensions:dispatch-extension-call (extensions:make-registry {}
                                    {:mermaid {:render (fn [args] (mermaid-extension:render fake-mmdflux args))}})
                                    (extension-request 95 :mermaid
                                                       :render {:source "flowchart TD; A-->B"
                                                       :style :svg
                                                       :options {:layout-engine "mermaid-layered"
                                                       :path-simplification "lossy"}}))
(let* [payload (wire-protocol:from-wire (get (get stub-sent-responses 0) :payload))]
  (assert (= (get payload :kind) :image) "extension SVG payload kind")
  (assert (= (get payload :mime) "image/svg+xml") "extension SVG payload mime")
  (assert (string/contains? (get payload :svg) "<svg") "extension SVG payload includes svg")
  (assert (string/contains? (get payload :svg) "mermaid-layered") "extension SVG forwards render options")
  (assert (= (get payload :renderer) :mmdflux) "extension SVG payload renderer"))

(defn assert-mermaid-style-kind [style kind]
  (let [payload (mermaid-extension:render fake-mmdflux {:source "flowchart TD; A-->B" :style style})]
    (assert (= (get payload :kind) kind) "extension normalizes style variants")))

(assert-mermaid-style-kind :svg :image)
(assert-mermaid-style-kind 'svg :image)
(assert-mermaid-style-kind "svg" :image)
(assert-mermaid-style-kind :ascii :text)
(assert-mermaid-style-kind 'ascii :text)
(assert-mermaid-style-kind "ascii" :text)
(assert-mermaid-style-kind nil :text)

(reset-stub-state)
(extensions:dispatch-extension-call (extensions:make-registry {}
                                    {:mermaid {:render (fn [args] (mermaid-extension:render fake-mmdflux args))}})
                                    (extension-request 94 :mermaid :render {:source "flowchart LR; A-->B" :style :png}))
(let* [payload (wire-protocol:from-wire (get (get stub-sent-responses 0) :payload))]
  (assert (= (get payload :ok) false) "extension invalid style returns payload error")
  (assert (= (get payload :error) :invalid-request) "extension invalid style error kind"))

(reset-stub-state)
(extensions:dispatch-extension-call (extensions:make-registry {} {})
                                    (extension-request 93 :mermaid :render {:source "flowchart LR; A-->B" :style :ascii}))
(let [response (get stub-sent-responses 0)]
  (assert (= (get response :ok) false) "extension unavailable sends RPC error")
  (assert (string/contains? (get response :error) "mermaid") "extension unavailable names extension"))

(println "  5. extension dispatch: ok")

# ============================================================================
# 6. Runtime form loaders emit Elisp list bindings, not vectors.
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

(println "tests/elle/hypervisor-runtime.lisp: all tests passed")
