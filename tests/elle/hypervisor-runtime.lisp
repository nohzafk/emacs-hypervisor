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

(def graph (emacs-hypervisor-graph-module))
(def wire-protocol (emacs-hypervisor-protocol-module))

(def @stub-sent-events @[])
(def @stub-sent-requests @[])
(def @stub-await-responses @[])
(def @stub-await-index 0)
(def @stub-read-messages @[])
(def @stub-read-index 0)

(defn stub-response [id ok payload &named error]
  {:kind :response :id id :ok ok :payload payload :error error})

(defn stub-event [topic payload]
  {:kind :event :topic topic :payload payload})

(defn clear-array! [arr]
  (while (not (empty? arr))
    (pop arr)))

(defn reset-stub-state []
  (clear-array! stub-sent-events)
  (clear-array! stub-sent-requests)
  (clear-array! stub-await-responses)
  (clear-array! stub-read-messages)
  (assign stub-await-index 0)
  (assign stub-read-index 0))

(def protocol
  {:await-response
   (fn [_mailbox _id]
     (let [response (get stub-await-responses stub-await-index)]
       (assign stub-await-index (+ stub-await-index 1))
       response))
   :from-wire (fn [payload] payload)
   :message-id (fn [message] (get message :id))
   :message-kind (fn [message] (get message :kind))
   :message-payload (fn [message] (get message :payload))
   :message-topic (fn [message] (get message :topic))
   :read-message
   (fn [_mailbox _label]
     (let [message (get stub-read-messages stub-read-index)]
       (assign stub-read-index (+ stub-read-index 1))
       message))
   :response-error (fn [message] (get message :error))
   :response-ok? (fn [message] (get message :ok))
   :send-event
   (fn [topic payload]
     (push stub-sent-events {:topic topic :payload payload}))
   :send-report
   (fn [stage phase payload]
     (push stub-sent-events
           {:topic :report
            :payload {:stage stage :phase phase :payload payload}}))
   :send-request
   (fn [id op payload]
     (push stub-sent-requests {:id id :op op :payload payload}))
   :sexp-string string
   :to-wire (fn [payload] payload)})

(def benchmark
  {:eval-payload (fn [payload] payload)
   :append-plist-field
   (fn [fields key value]
     (if value (append fields (list key value)) fields))})
(def mailbox :stub)

(def preflight (emacs-hypervisor-preflight-module protocol graph mailbox benchmark))
(def policy (emacs-hypervisor-boot-policy-module graph preflight))
(def reporting (emacs-hypervisor-reporting-module protocol policy))
(def planning (emacs-hypervisor-planning-module protocol graph))
(def execution (emacs-hypervisor-execution-module protocol graph mailbox benchmark))

(def packages
  (list
   {:name "ui-pkg" :deps (list "core-pkg") :repo "example/ui-pkg" :host nil :branch nil :tag nil :ref nil :local nil :lisp-dir nil}
   {:name "runtime-fail-dependent" :deps (list "runtime-fail-pkg") :repo "example/runtime-fail-dependent" :host nil :branch nil :tag nil :ref nil :local nil :lisp-dir nil}
   {:name "core-pkg" :deps (list) :repo "example/core-pkg" :host nil :branch nil :tag nil :ref nil :local nil :lisp-dir nil}
   {:name "invalid-root" :deps (list "ghost-pkg") :repo "example/invalid-root" :host nil :branch nil :tag nil :ref nil :local nil :lisp-dir nil}
   {:name "runtime-fail-pkg" :deps (list) :repo "example/runtime-fail-pkg" :host nil :branch nil :tag nil :ref nil :local nil :lisp-dir nil}))

(def units
  (list
   {:name "ui-unit"
    :requires (list "ui-pkg")
    :after (list "core-ui-unit")
    :env (list)
    :executable (list)
    :body '(progn :ui-ok)}
   {:name "after-runtime-fail-unit"
    :requires (list)
    :after (list "runtime-fail-unit")
    :env (list)
    :executable (list)
    :body '(progn :after-fail-ok)}
   {:name "core-ui-unit"
    :requires (list "core-pkg")
    :after (list)
    :env (list)
    :executable (list)
    :body '(progn :core-ok)}
   {:name "blocked-by-invalid-package-unit"
    :requires (list "invalid-root")
    :after (list)
    :env (list)
    :executable (list)
    :body '(progn :blocked-invalid-ok)}
   {:name "blocked-by-runtime-package-unit"
    :requires (list "runtime-fail-pkg")
    :after (list)
    :env (list)
    :executable (list)
    :body '(progn :blocked-ok)}
   {:name "invalid-after-unit"
    :requires (list)
    :after (list "ghost-unit")
    :env (list)
    :executable (list)
    :body '(progn :invalid-ok)}
   {:name "independent-unit"
    :requires (list)
    :after (list)
    :env (list)
    :executable (list)
    :body '(progn :independent-ok)}
   {:name "runtime-fail-unit"
    :requires (list)
    :after (list)
    :env (list)
    :executable (list)
    :body '(error "simulated unit failure")}
   {:name "preflight-bad-unit"
    :requires (list)
    :after (list)
    :env (list "HYPERVISOR_MISSING_ENV")
    :executable (list "definitely-not-installed-command")
    :body '(progn :preflight-ok)}))

(def env
  (list
   {:name "PATH" :value "/usr/bin"}
   {:name "SHELL" :value "/bin/fish"}
   {:name "HYPERVISOR_MISSING_ENV" :value ""}))

(def executable-reports
  (list
   {:name "preflight-bad-unit" :missing (list "definitely-not-installed-command")}))

# ============================================================================
# 0. Protocol printing preserves nested arrays as recursive s-expressions.
# ============================================================================

(assert
 (= (wire-protocol:sexp-string ["Open" ["a" "window"]])
    "[\"Open\" [\"a\" \"window\"]]")
 "protocol prints immutable arrays recursively")
(assert
 (= (wire-protocol:sexp-string @["Tabs" "[" "]"])
    "[\"Tabs\" \"[\" \"]\"]")
 "protocol prints mutable arrays recursively")
(assert
 (= (wire-protocol:sexp-string
     (wire-protocol:to-wire
      (wire-protocol:from-wire
       [(quote (:name "unit")) ["Open" "a"]])))
    "[(:name \"unit\") [\"Open\" \"a\"]]")
 "protocol converts nested arrays through from-wire/to-wire")
(let* [decoded
       (wire-protocol:from-wire-session-data
        (quote
         (:packages ((:name "pkg"
                      :deps ()
                      :repo "example/pkg"
                      :host nil
                      :branch nil
                      :tag nil
                      :ref nil
                      :files nil
                      :local nil
                      :no-compilation nil))
          :units ((:name "plist-unit"
                   :requires ("pkg")
                   :after ()
                   :env ()
                   :executable ()
                   :body (progn
                           (setq x (quote (:a 1 :b 2)))
                           t)))
          :env ((:name "PATH" :value "/usr/bin")))))
       unit (first (get decoded :units))
       package (first (get decoded :packages))
       env-entry (first (get decoded :env))
       body (get unit :body)]
  (assert (= (get package :name) "pkg") "session decoder decodes packages")
  (assert (= (get env-entry :value) "/usr/bin") "session decoder decodes env")
  (assert (= (get unit :requires) (list "pkg")) "session decoder decodes unit metadata")
  (assert
   (= body
      '(progn
         (setq x (quote (:a 1 :b 2)))
         t))
   "session decoder preserves raw unit body")
  (assert
   (= (wire-protocol:sexp-string body)
      "(progn (setq x (quote (:a 1 :b 2))) t)")
   "session decoder does not struct-convert plist literals inside body"))
(println "  0. protocol arrays and session decoding: ok")

# ============================================================================
# 0b. Boot policy derives stale init warnings from boot context.
# ============================================================================

(let* [warning
       (policy:bootstrap-warning
        {:init-generated true
         :init-content-hash "fnv1a64:old"
         :init-file "/tmp/home/init.el"
         :binary "/tmp/bin/emacs-hypervisor"
         :repo-dir "/tmp/home"}
        "fnv1a64:new")]
  (assert warning "boot-policy reports stale generated init")
  (assert (= (get warning :kind) :bootstrap-hash) "bootstrap warning kind")
  (assert (= (get warning :current-hash) "fnv1a64:old") "bootstrap warning current hash")
  (assert (= (get warning :expected-hash) "fnv1a64:new") "bootstrap warning expected hash")
  (assert
   (string/contains? (get warning :message) "init --home /tmp/home --upgrade")
   "bootstrap warning includes upgrade command"))

(assert
 (nil?
  (policy:bootstrap-warning
   {:init-generated true
    :init-content-hash "fnv1a64:new"
    :binary "/tmp/bin/emacs-hypervisor"
    :repo-dir "/tmp/home"}
   "fnv1a64:new"))
 "boot-policy suppresses warning for matching init hash")

(assert
 (nil?
  (policy:bootstrap-warning
   {:init-generated false
    :init-content-hash "fnv1a64:old"
    :binary "/tmp/bin/emacs-hypervisor"
    :repo-dir "/tmp/home"}
   "fnv1a64:new"))
 "boot-policy suppresses warning for unmanaged init")

(reset-stub-state)
(reporting:emit-bootstrap-warning
 {:init-generated true
  :init-content-hash nil
  :init-file "/tmp/home/init.el"
  :binary "/tmp/bin/emacs-hypervisor"
  :repo-dir "/tmp/home"}
 "fnv1a64:new")
(assert (= (length stub-sent-events) 1) "boot-policy emits one warning event")
(assert (= (get (get stub-sent-events 0) :topic) :warning) "boot-policy emits :warning topic")
(assert
 (string/contains?
  (get (get (get stub-sent-events 0) :payload) :message)
  "has no content hash")
 "boot-policy missing-hash warning message")
(println "  0b. bootstrap warning policy: ok")

# ============================================================================
# 1. Boot policy preserves invalid, blocked, and preflight detail shapes.
# ============================================================================

(let* [{:reports planned-package-reports}
       (policy:derive-package-reports packages)
       {:reports planned-unit-reports}
       (policy:derive-unit-reports
        units
        (graph:known-names packages)
        planned-package-reports
        env
       executable-reports)
       invalid-root (graph:find-entry planned-package-reports "invalid-root")
       blocked-unit (graph:find-entry planned-unit-reports "blocked-by-invalid-package-unit")
       invalid-after (graph:find-entry planned-unit-reports "invalid-after-unit")
       preflight-bad (graph:find-entry planned-unit-reports "preflight-bad-unit")]
  (assert (= (get invalid-root :status) :invalid) "boot-policy invalid package status")
  (assert (= (get invalid-root :reason) :missing-deps) "boot-policy invalid package reason")
  (assert (= (get (get invalid-root :details) :missing) (list "ghost-pkg")) "boot-policy invalid package details")
  (assert (= (get blocked-unit :status) :skipped) "boot-policy blocked unit status")
  (assert (= (get blocked-unit :reason) :blocked-by-package) "boot-policy blocked unit reason")
  (assert (= (get (get blocked-unit :details) :blockers) (list "invalid-root")) "boot-policy blocked unit details")
  (assert (= (get invalid-after :reason) :missing-after-units) "boot-policy invalid after reason")
  (assert (= (get (get invalid-after :details) :missing) (list "ghost-unit")) "boot-policy invalid after details")
  (assert (= (get preflight-bad :status) :skipped) "boot-policy preflight status")
  (assert (= (get preflight-bad :reason) :preflight) "boot-policy preflight reason")
  (assert (= (get (get preflight-bad :details) :env) (list "HYPERVISOR_MISSING_ENV")) "boot-policy preflight env details")
  (assert (= (get (get preflight-bad :details) :executable) (list "definitely-not-installed-command")) "boot-policy preflight executable details"))

(let* [{:reports reports}
       (policy:derive-unit-reports
        (list
         {:name "feature-unit"
          :requires (list "project")
          :after (list)
          :env (list)
          :executable (list)
          :body '(progn :feature-ok)})
        ()
        ()
        env
        ())
       feature-unit (graph:find-entry reports "feature-unit")]
  (assert (= (get feature-unit :status) :ok)
          "boot-policy treats :requires as runtime features, not declared package names"))

(println "  1. boot policy: ok")

# ============================================================================
# 2. Planning emits dependency order, not declaration order.
# ============================================================================

(let* [{:reports planned-package-reports}
       (policy:derive-package-reports packages)
       {:reports planned-unit-reports}
       (policy:derive-unit-reports
        units
        (graph:known-names packages)
        planned-package-reports
        env
        executable-reports)
       package-plan (planning:derive-package-plan packages planned-package-reports)
       unit-plan (planning:derive-unit-plan units planned-unit-reports)]
  (reset-stub-state)
  (planning:emit-plan-message package-plan)
  (planning:emit-plan-message unit-plan)
  (assert
   (= (map (fn [{:name name}] name) (planning:plan-items package-plan))
      (list "core-pkg" "ui-pkg" "runtime-fail-pkg" "runtime-fail-dependent"))
   "planning package order")
  (assert
   (= (map (fn [{:name name}] name) (planning:plan-items unit-plan))
      (list "core-ui-unit"
            "ui-unit"
            "blocked-by-runtime-package-unit"
            "independent-unit"
            "runtime-fail-unit"
            "after-runtime-fail-unit"))
   "planning unit order")
  (assert (= (length stub-sent-events) 2) "planning emitted two plan messages")
  (assert (= (get (get stub-sent-events 0) :topic) :plan) "planning emits :plan topic")
  (assert (= (get (get stub-sent-events 1) :topic) :plan) "planning emits second :plan topic"))
(println "  2. planning: ok")

# ============================================================================
# 3. Batch execution derives package failure and dependent skip.
# ============================================================================

(let* [{:reports planned-package-reports}
       (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages
        (stub-event :package
                    {:phase :packages :kind :installed :name "core-pkg"}))
  (push stub-read-messages
        (stub-event :package
                    {:phase :packages :kind :installed :name "ui-pkg"}))
  (push stub-read-messages
        (stub-event :package
                    {:phase :packages :kind :failed :name "runtime-fail-pkg"
                     :reason "clone failed"}))
  (push stub-read-messages
        (stub-event :package
                    {:phase :packages :kind :finished :reason "completed"}))
  (push stub-read-messages
        (stub-response 10 true
                       (list {:name "core-pkg" :status :installed}
                             {:name "ui-pkg" :status :installed}
                             {:name "runtime-fail-pkg" :status :failed :error "clone failed"}
                             {:name "runtime-fail-dependent" :status :failed :error "blocked"})))
  (let* [{:reports package-reports
          :installed installed
          :next-id next-id}
         (execution:execute-package-entry-plan-tracker
          (planning:plan-items package-plan)
          10)
         core (graph:find-entry package-reports "core-pkg")
         ui (graph:find-entry package-reports "ui-pkg")
         runtime-fail (graph:find-entry package-reports "runtime-fail-pkg")
         blocked (graph:find-entry package-reports "runtime-fail-dependent")]
    (assert (= next-id 11) "tracker next id")
    (assert (= (length stub-sent-requests) 1) "tracker sends one batch eval")
    (let* [batch-request (get stub-sent-requests 0)
           batch-form (wire-protocol:plist-get (get batch-request :payload) :form)
           call-head (syntax->datum (first batch-form))]
      (assert
       (= call-head 'emacs-hypervisor-runtime-install-package-batch)
       "tracker calls install-package-batch"))
    (assert (graph:member? installed "core-pkg") "tracker installed contains core")
    (assert (graph:member? installed "ui-pkg") "tracker installed contains ui")
    (assert (= (get core :status) :ok) "tracker core status")
    (assert (= (get ui :status) :ok) "tracker ui status")
    (assert (= (get runtime-fail :status) :failed) "tracker root failure")
    (assert (= (get (get runtime-fail :details) :source) :eval) "tracker failure source")
    (assert (= (get (get runtime-fail :details) :error) "clone failed") "tracker failure error detail")
    (assert (= (get blocked :status) :skipped) "tracker blocks dependent package")
    (assert (= (get (get blocked :details) :blockers) (list "runtime-fail-pkg")) "tracker blocked details")))
(println "  3. batch execution: ok")

(let* [local-entry
       {:name "elle-lsp-bridge"
        :deps (list)
        :repo nil
        :host nil
        :branch nil
        :tag nil
        :ref nil
        :local "/tmp/elle-lsp-bridge"
        :lisp-dir "lisp"}
       local-plan-items
       (list {:name "elle-lsp-bridge" :entry local-entry})]
  (reset-stub-state)
  (push stub-read-messages
        (stub-event :package
                    {:phase :packages :kind :installed :name "elle-lsp-bridge"}))
  (push stub-read-messages
        (stub-event :package
                    {:phase :packages :kind :finished :reason "completed"}))
  (push stub-read-messages
        (stub-response 50 true
                       (list {:name "elle-lsp-bridge" :status :installed})))
  (execution:execute-package-entry-plan-tracker local-plan-items 50)
  (let* [batch-request (get stub-sent-requests 0)
         batch-form (wire-protocol:plist-get (get batch-request :payload) :form)
         quote-form (first (rest batch-form))
         entries (first (rest quote-form))
         entry (first entries)]
    (assert (= (length entries) 1) "batch contains one entry")
    (assert (= (wire-protocol:plist-get entry :name) "elle-lsp-bridge") "entry preserves name")
    (assert (= (wire-protocol:plist-get entry :local) "/tmp/elle-lsp-bridge") "entry preserves local path")
    (assert (= (wire-protocol:plist-get entry :lisp-dir) "lisp") "entry preserves lisp-dir")))
(println "  3a. local package install spec: ok")

(let* [{:reports planned-package-reports}
       (policy:derive-package-reports packages)
       package-plan (planning:derive-package-plan packages planned-package-reports)]
  (reset-stub-state)
  (push stub-read-messages
        (stub-response 40 false nil :error "package install failed"))
  (let* [{:reports package-reports
          :installed installed
          :next-id next-id}
         (execution:execute-package-entry-plan-tracker
          (planning:plan-items package-plan)
          40)
         core (graph:find-entry package-reports "core-pkg")
         ui (graph:find-entry package-reports "ui-pkg")
         runtime-fail (graph:find-entry package-reports "runtime-fail-pkg")
         blocked (graph:find-entry package-reports "runtime-fail-dependent")]
    (assert (= next-id 41) "tracker failed batch next id")
    (assert (empty? installed) "tracker reports no installed on batch failure")
    (assert (= (get core :status) :failed) "tracker fails all packages on batch failure")
    (assert (= (get ui :status) :failed) "tracker fails ui on batch failure")
    (assert (= (get (get ui :details) :source) :eval) "tracker failure source is eval")
    (assert (= (get (get ui :details) :error) "package install failed") "tracker failure error detail")
    (assert (= (get runtime-fail :status) :failed) "tracker fails missing root after batch failure")
    (assert (= (get blocked :status) :failed) "tracker fails dependents after batch failure")))
(println "  3b. tracker batch failure: ok")

(reset-stub-state)
(let [{:reports reports :installed installed :next-id next-id}
      (execution:execute-package-entry-plan-tracker () 30)]
  (assert (= next-id 30) "empty package plan preserves next id")
  (assert (empty? reports) "empty package plan has no reports")
  (assert (empty? installed) "empty package plan has no installed packages")
  (assert (= (length stub-sent-requests) 0) "empty package plan sends no eval requests"))
(println "  3c. empty package plan: ok")

# ============================================================================
# 4. Unit execution preserves runtime failure propagation.
# ============================================================================

(let* [{:reports planned-package-reports}
       (policy:derive-package-reports packages)
       {:reports planned-unit-reports}
       (policy:derive-unit-reports
        units
        (graph:known-names packages)
        planned-package-reports
        env
        executable-reports)
       package-reports
       (list
        (graph:make-report "ui-pkg" :ok :executed (list "core-pkg"))
        (graph:make-report "runtime-fail-dependent" :skipped :blocked-by-package {:blockers (list "runtime-fail-pkg")})
        (graph:make-report "core-pkg" :ok :executed (list))
        (graph:make-report "invalid-root" :invalid :missing-deps {:missing (list "ghost-pkg")})
        (graph:make-report "runtime-fail-pkg" :failed :execution {:source :tracker :finished-reason "completed"}))
       unit-plan (planning:derive-unit-plan units planned-unit-reports)]
  (reset-stub-state)
  (push stub-await-responses (stub-response 20 true :core-unit-ok))
  (push stub-await-responses (stub-response 21 true :independent-ok))
  (push stub-await-responses (stub-response 22 true :runtime-fail-eval))
  (push stub-await-responses (stub-response 23 false nil :error "(error \"simulated unit failure\")"))
  (let* [{:reports unit-reports :next-id next-id}
         (execution:execute-unit-plan
          (planning:plan-items unit-plan)
          package-reports
          20)
         core (graph:find-entry unit-reports "core-ui-unit")
         blocked-by-package (graph:find-entry unit-reports "blocked-by-runtime-package-unit")
         independent (graph:find-entry unit-reports "independent-unit")
         runtime-fail (graph:find-entry unit-reports "runtime-fail-unit")
         ui (graph:find-entry unit-reports "ui-unit")
         after-runtime-fail (graph:find-entry unit-reports "after-runtime-fail-unit")]
    (assert (= next-id 24) "unit next id")
    (assert (= (length stub-sent-requests) 4) "unit execution only evals runnable items")
    (assert (= (get core :status) :ok) "unit core status")
    (assert (= (get independent :status) :ok) "unit independent status")
    (assert (= (get ui :status) :ok) "unit ui status")
    (assert (= (get blocked-by-package :status) :skipped) "unit blocked by package")
    (assert (= (get runtime-fail :status) :failed) "unit runtime failure")
    (assert (= (get (get runtime-fail :details) :source) :eval) "unit runtime failure source")
    (assert (= (get after-runtime-fail :status) :skipped) "unit after failure skipped")
    (assert (= (get (get after-runtime-fail :details) :blockers) (list "runtime-fail-unit")) "unit after failure blockers")))
(println "  4. unit execution: ok")

(println "tests/elle/hypervisor-runtime.lisp: all tests passed")
