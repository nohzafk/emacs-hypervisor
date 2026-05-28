(elle/epoch 10)
## HUD extension — state aggregation for the xwidget-webkit child-frame HUD.
## The actual rendering happens in Emacs via xwidget-webkit + egui WASM.
## This module manages HUD state and bridges it to Emacs over RPC events.
##
## Architecture: actor-mediated.
## All state changes and user actions flow through the extension actor:
##   Emacs → sexp-rpc :extension-call → actor → response / event → Emacs
## State pushes to the WASM renderer are driven by :hud-state-changed events
## emitted by this actor, not by Emacs-side polling.
##
## Data collection: git data is collected natively via std/git (libgit2 FFI).
## Emacs sends :hud :collect with the repo path; the actor opens the repo,
## reads branch/status/log, and emits the updated state.

(defn emacs-hypervisor-hud-extension-module [extensions protocol]
  (def @*hud-state*
    {:branch "main"
     :changes "0 files"
     :mcp-online false
     :units ()
     :location "Local"
     :last-commit ""
     :gh-available false
     :project-name ""
     :project-root ""})

  ## Lazy-load std/git — returns the module or nil if unavailable.
  ## Same protect+sentinel pattern as mermaid uses for mmdflux.
  (def @*git* nil)
  (def @*git-loaded* false)

  (defn ensure-git []  ## Load std/git on first use. Returns the module or nil.
    (when (not *git-loaded*)
      (assign *git-loaded* true)
      (let [[ok? mod] (protect ((import "std/git")))]
        (if ok?
          (assign *git* mod)
          (do
            (protocol:send-event :log {:level :warning :message (string "HUD: std/git unavailable: " mod)})
            nil))))
    *git*)

  (defn log-debug [message]  ## Emit a HUD debug log event so backend collection can be observed from
    ## Emacs.  These surface in the hypervisor log stream.
    (protocol:send-event :log {:level :info :message (string "HUD: " message)}))

  (defn collect-git-data [repo-path]  ## Open a git repo at repo-path, collect branch/status/log, close.
    ## Returns a struct with git fields, or nil if not a git repo.
    (let [git (ensure-git)]
      (if (not git)
        (do
          (log-debug "collect-git-data: std/git unavailable")
          nil)
        (let [[open-ok? repo] (protect (git:open repo-path))]
          (if (not open-ok?)
            (do
              (log-debug (string "collect-git-data: git:open failed for " repo-path " -> " repo))
              nil)
            (let [result (protect (let* [head-info (let [[ok? h] (protect (git:head repo))]
                                                     (if ok? h nil))
                                         branch-name (if head-info
                                                       (let [name (get head-info :name)]
                                                         (if (string/starts-with? name "refs/heads/")
                                                           (slice name 11)
                                                           name))
                                                       "HEAD")  ## Capture status errors explicitly instead of
                                         ## silently collapsing them to "0 files".
                                         status-res (protect (git:status repo))
                                         status-list (let [[ok? s] status-res]
                                                       (if ok?
                                                         s
                                                         (do
                                                           (log-debug (string "git:status failed: " (get status-res 1)))
                                                           ())))  ## libgit2's default status options include
                                         ## ignored files; git's CLI excludes them.
                                         ## Ignored entries decode to index=nil
                                         ## workdir=nil, so count only entries with a
                                         ## real index or workdir change.
                                         changed-count (count (fn [e] (or (get e :index) (get e :workdir))) status-list)
                                         changes-str (if (= changed-count 1) "1 file" (string changed-count " files"))
                                         log-entries (let [[ok? l] (protect (git:log repo {:limit 1}))]
                                                       (if ok? l ()))
                                         last-commit (if (empty? log-entries)
                                                       ""
                                                       (slice (get (first log-entries) :oid) 0 7))]
                                    (log-debug (string "collected branch=" branch-name " changes=" changes-str " repo="
                                                       repo-path))
                                    {:branch branch-name :changes changes-str :last-commit last-commit}))]
              (protect (git:close repo))
              (let [[ok? data] result]
                (if ok?
                  data
                  (do
                    (log-debug (string "collect-git-data: collection error -> " (get result 1)))
                    nil)))))))))

  (defn emit-state-changed []  ## Notify Emacs that HUD state has been updated.
    ## The Elisp event handler pushes the new state to the xwidget WASM renderer.
    (protocol:send-event :hud-state-changed (protocol:to-wire *hud-state*)))

  (defn open-hud [_args]  ## Signal Emacs to show the xwidget child-frame HUD.
    ## After opening, emit the current state so the renderer is populated.
    (emit-state-changed)
    {:ok true :action :show})

  (defn close-hud [_args]  ## Signal Emacs to hide the xwidget child-frame HUD.
    {:ok true :action :hide})

  (defn collect [args]  ## Collect HUD data natively. Git data via libgit2 FFI, other fields from Emacs.
    ## This is the canonical data collection method — replaces the old :update method.
    (let [repo-path (extensions:extension-call-field args :repo_path)
          mcp-online (extensions:extension-call-field args :mcp_online)
          gh-available (extensions:extension-call-field args :gh_available)
          location (extensions:extension-call-field args :location)]
      (assign *hud-state* (put *hud-state* :project-root (if repo-path repo-path "")))

      ## Collect git data if we have a repo path
      (let [git-data (when repo-path (collect-git-data repo-path))]
        (if git-data
          (do
            (assign *hud-state* (put *hud-state* :branch (get git-data :branch)))
            (assign *hud-state* (put *hud-state* :changes (get git-data :changes)))
            (assign *hud-state* (put *hud-state* :last-commit (get git-data :last-commit)))
            (when repo-path
              (let [parts (string/split repo-path "/")
                    project-name (last parts)]
                (assign *hud-state* (put *hud-state* :project-name project-name)))))  ## Not a git repo or failed — clear git fields, keep project name from path
          (do
            (assign *hud-state* (put *hud-state* :branch "—"))
            (assign *hud-state* (put *hud-state* :changes "0 files"))
            (assign *hud-state* (put *hud-state* :last-commit ""))
            (when repo-path
              (let [parts (string/split repo-path "/")
                    project-name (last parts)]
                (assign *hud-state* (put *hud-state* :project-name project-name)))))))

      ## Non-git fields from Emacs
      (when (not (nil? mcp-online)) (assign *hud-state* (put *hud-state* :mcp-online mcp-online)))
      (when (not (nil? gh-available)) (assign *hud-state* (put *hud-state* :gh-available gh-available)))
      (when location (assign *hud-state* (put *hud-state* :location location)))

      (emit-state-changed)
      {:ok true}))

  (defn get-state [_args]  ## Return the current HUD state for Emacs to push into the WASM renderer.
    ## Used for initial load or manual refresh when the event stream is missed.
    {:ok true :state *hud-state*})

  (defn handle-action [args]  ## Handle an interactive command routed from the WASM renderer via Emacs.
    ## Click actions in egui trigger emacs-hud:// URIs → Emacs intercepts →
    ## routes here via :extension-call :hud :action.
    (let [command (extensions:extension-call-field args :command)]
      (case command
        "rerun-diagnostics" {:ok true :action :rerun-diagnostics}
        {:ok false :error :unknown-command :message (string "unknown HUD command: " command)})))

  (defn make-handler [_settings]
    {:open (fn [args] (open-hud args))
     :close (fn [args] (close-hud args))
     :collect (fn [args] (collect args))
     :state (fn [args] (get-state args))
     :action (fn [args] (handle-action args))})

  (defn register [settings handlers]
    (let [handler (make-handler settings)]
      (put handlers :hud handler)))

  {:register register})
