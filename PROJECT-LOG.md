# Emacs Hypervisor Project Log

Last updated: 2026-04-23
Status: shared session/init path working, with remaining productization work

## Purpose

This file is the living project document for `emacs-hypervisor`.
It records:

- what has already been investigated
- what the project is trying to become
- what was learned from `emacs-backbone`
- what was learned from Elle
- the current implementation plan
- the next milestone to tackle

The intent is to keep updating this file as work progresses.

## Milestone 1: Investigate the Gemini Conversation

### Summary

The Gemini conversation points toward a new project, separate from `emacs-backbone`, that uses Elle as the external control plane for Emacs configuration.

The core idea is not "rewrite everything for novelty". The real intent is:

1. keep deterministic, dependency-aware Emacs configuration
2. keep the external orchestrator model
3. replace the current Gleam + Bun backend with an Elle-native runtime
4. explore whether Elle's fibers, processes, signals, and supervisors can make the system more fault-tolerant and more interactive

### Project Identity

The name `Emacs Hypervisor` fits the idea well:

- it is outside Emacs
- it supervises boot and state transitions
- it acts like a control plane rather than just a package loader

### Important Constraint

This project should not replace `emacs-backbone`.

`emacs-backbone` remains the current working implementation and reference design.
`emacs-hypervisor` is the new experimental Elle-native branch of the idea.

### MVP Intent

The likely MVP is:

- thin Emacs Lisp collection layer
- external Elle orchestrator
- deterministic package and config-unit dependency resolution
- startup execution with clear failure handling

### Ambitious Phase-2 Ideas from the Gemini Discussion

These are interesting, but they should not define the MVP:

- interactive remediation of boot failures
- pausing and resuming failed configuration fibers
- supervisor-driven partial degradation
- subtree live reload
- dry-run impact analysis
- deterministic startup profiling

## Milestone 2: Understand the High-Level Concepts

### Control Plane vs Data Plane

The clean mental model is:

- Elle process = control plane
- Emacs = data plane

Emacs should remain responsible for evaluating Emacs Lisp and using the real Emacs package manager.
The external runtime should own orchestration, dependency order, failure policy, state tracking, and higher-level reasoning.

### Stable Contract to Preserve

The most valuable ideas from `emacs-backbone` are not Gleam-specific:

- `package!` declares packages and package dependencies
- `config-unit!` declares config blocks and ordering/runtime constraints
- the backend resolves the graph and drives execution
- failures should skip downstream dependents instead of producing random state

That contract is worth preserving even if the runtime is completely replaced.

### What Should Stay Thin in Emacs Lisp

The Emacs side should stay limited to:

- declaration macros
- serialization/export of declarations
- RPC bridge to the external process
- execution of approved Elisp fragments
- package-manager integration

It should not grow its own dependency resolver again.

## Milestone 3: Investigate `emacs-backbone`

### What the Reference Implementation Already Proves

`emacs-backbone` already demonstrates the important architecture:

1. Emacs Lisp collects declarations with macros.
2. The backend fetches those declarations.
3. Packages are installed in resolved order.
4. Config units are executed in dependency order.
5. Failed dependencies mark downstream units as skipped/failed.

### Key Files

- `lisp/macro-package.el`
  - `package!` is the declaration surface
  - package specs are stored and exported for the backend

- `lisp/macro-config-unit.el`
  - `config-unit!` is the config declaration surface
  - captures `:requires`, `:after`, `:env`, `:executable`, and the body
  - warns against `with-eval-after-load` and `use-package` inside units

- `src/emacs_backbone.gleam`
  - JSON-RPC entrypoint
  - startup flow
  - environment injection
  - package installation phase
  - config execution phase

- `src/unit_executor.gleam`
  - executes resolved unit groups
  - checks runtime deps
  - marks failures
  - skips downstream units when prerequisites fail

### Important Architectural Reading

The current project does not try to replace Emacs package management itself.
It still delegates package work to Emacs/Elpaca and uses the external runtime for orchestration.

That is the correct reference point for `emacs-hypervisor`.

Do not expand scope by trying to invent a new package manager in Elle.

## Milestone 4: Investigate Elle

### Relevant Elle Capabilities

Based on the current Elle documentation:

- `ev/spawn`, `ev/join`, `ev/scope`, `ev/timeout` provide fiber-level structured concurrency
- `std/process` provides processes, mailboxes, monitors, GenServer, and Supervisor
- supervisors support restart strategies and child management
- subprocesses can be supervised
- the language also exposes deeper analysis tooling, but that is not required for MVP

### Why Elle Is Interesting for This Project

Elle gives this project a chance to become:

- more native to the control-plane idea
- less dependent on Bun/JS runtime plumbing
- better structured for long-lived orchestration
- possibly more recoverable for partial-failure boot flows

### Important Caution

Elle's advanced process model is attractive, but it should not be forced into the first version.

Using supervisors too early could make the project more complex than the problem requires.

## Milestone 5: Check Local Environment

Current local state:

- this repository is currently empty
- `cargo` is installed
- `rustc` is installed
- `elle` is not currently installed

This means experimentation is feasible, but Elle needs to be installed or built before implementation spikes can begin.

### Machine Notes

- OS: macOS 15 / Darwin 24.6.0 / arm64
- `cargo`: `1.95.0`
- `rustc`: `1.95.0`

## Milestone 6: Build Elle and Run Practical Spikes

### Result

This milestone succeeded.

Elle was cloned to `/tmp/elle`, built locally, and both debug and release binaries were executed successfully on this machine.

### Build Notes

Source location used for the spike:

- `/tmp/elle`

Commands that worked:

```sh
git clone --depth 1 https://github.com/elle-lisp/elle /tmp/elle
cd /tmp/elle
cargo build -p elle
cargo build --release -p elle
```

Observed results:

- debug build succeeded in about `24.61s`
- release build succeeded in about `59.68s`
- debug binary: `/tmp/elle/target/release/elle`
- release binary: `/tmp/elle/target/release/elle`

Binary sizes:

- debug binary: about `26M`
- release binary: about `5.4M`

Dynamic libraries reported by `otool -L` for the release binary:

- `/usr/lib/libiconv.2.dylib`
- `/usr/lib/libSystem.B.dylib`

This is important because it means the practical deployment story here is:

- the Hypervisor backend can likely be shipped as a normal compiled executable
- it is not literally a fully static universal artifact on this macOS machine
- but it is still much closer to a simple standalone tool than the current Gleam + Bun setup

### Dependency Notes

One useful detail from this machine:

- `pkg-config` did not report `libffi`, `sqlite3`, `zlib`, `zstd`, or `libgit2` package metadata
- despite that, `cargo build -p elle` still succeeded

That means the first practical blocker for this machine was not system libraries.
The real blocker was network access for:

- cloning the repository
- downloading crates from `crates.io`

### Execution Notes

For scripting, `elle -` is the clean mode to use because it reads stdin as a file.
Plain `elle` starts the REPL, which is noisier for automated experiments.

### Working Experiments

#### 1. Hello world

Command:

```sh
printf '(println "hello from elle")\n' | /tmp/elle/target/release/elle -
```

Output:

```text
hello from elle
```

#### 2. Fiber spawn/join

Command:

```sh
printf '(def f (ev/spawn (fn [] (+ 1 2))))\n(println (ev/join f))\n' | /tmp/elle/target/release/elle -
```

Output:

```text
3
```

Interpretation:

- the base fiber model works locally
- this is enough to justify using fibers for lightweight orchestration helpers, timeouts, and structured sub-work

#### 3. GenServer-style process

Command:

```sh
printf '(def process ((import "std/process")))\n(process:start (fn []\n  (process:gen-server-start-link\n    {:init (fn [_] 0)\n     :handle-call (fn [req _from state]\n       (case req\n         :inc [:reply (+ state 1) (+ state 1)]\n         :get [:reply state state]))}\n    nil :name :counter)\n  (process:gen-server-call :counter :inc)\n  (process:gen-server-call :counter :inc)\n  (println (process:gen-server-call :counter :get))))\n' | /tmp/elle/target/debug/elle -
```

Output:

```text
2
```

Interpretation:

- `std/process` is not just theoretical in the docs
- GenServer-like stateful orchestration works locally and is viable for later control-plane experiments

#### 4. Supervisor startup

Command:

```sh
printf '(def process ((import "std/process")))\n(process:start (fn []\n  (let [me (process:self)]\n    (process:supervisor-start-link\n      [{:id :worker :restart :temporary\n        :start (fn []\n          (process:send me [:started (process:self)])\n          (forever (process:recv)))}]\n      :name :sup)\n    (match (process:recv)\n      ([:started pid] (println :supervisor-ok))\n      (_ (println :unexpected))))))\n' | /tmp/elle/target/debug/elle -
```

Output:

```text
supervisor-ok
```

Interpretation:

- supervisor primitives work locally
- they are realistic candidates for phase-2 Hypervisor features
- this still does not change the MVP recommendation: do not make supervisors the foundation before the plain orchestrator exists

### Conclusion From the Spike

The practical answer now is:

- Elle is viable on this machine
- building it locally is straightforward once network access is available
- both fibers and supervisor/process primitives work in real local experiments
- the Hypervisor project can proceed without waiting on further language/toolchain validation

## Milestone 7: Choose the Transport Direction

### User Insight That Changes the Design

A major reason to prefer Elle here over Gleam or a more conventional RPC stack is homoiconicity:

- Elle naturally emits S-expressions
- Emacs naturally parses S-expressions with `read`
- this can remove most of the JSON encoding/decoding and schema boilerplate

That is a real architectural advantage, not just an aesthetic one.

### Decision

The MVP transport should be:

- stdio
- asynchronous process filter on the Emacs side
- S-expressions as the wire format
- a small message dispatcher in Emacs

The MVP transport should **not** be:

- JSON-RPC
- synchronous blocking bootstrap loops
- unstructured "stream arbitrary Lisp forms and `eval` everything immediately" as the whole protocol

### Why Not Keep JSON-RPC?

JSON-RPC is still workable, but it no longer looks like the best fit once Elle is on the table.

Compared with S-expression transport, JSON-RPC adds:

- serialization overhead
- duplicated data-model work
- less natural representation of code-bearing messages
- extra impedance between the two Lisps

For `emacs-backbone`, JSON-RPC made sense because the backend was Gleam/JS-oriented.
For `emacs-hypervisor`, S-expression transport is the more native design.

### Why Raw `eval` Streaming Is Too Loose

The "zombie waiting for brainwaves" idea is directionally right, but the protocol should be slightly stricter than:

- orchestrator prints arbitrary Elisp
- Emacs just `read`s and `eval`s every form directly

That raw model is elegant, but too under-specified for a real control plane.

Problems with making raw `eval` the full protocol:

- no explicit message types
- no versioned protocol surface
- weak error boundaries
- hard to distinguish commands, logs, progress, replies, and events
- hard to correlate request/response pairs
- too easy to turn the transport into an unstructured code hose

The right conclusion is:

- use S-expressions for transport
- but transport **messages as data first**
- only evaluate Elisp in explicitly marked message types

### Recommended Protocol Shape

Each message should be one printed S-expression.
Emacs accumulates chunks in a hidden buffer, repeatedly calls `read`, and dispatches complete forms.

Recommended message families:

- `(:hello ...)`
- `(:ready ...)`
- `(:progress ...)`
- `(:log ...)`
- `(:eval ...)`
- `(:result ...)`
- `(:error ...)`
- `(:event ...)`
- `(:shutdown ...)`

Example direction:

```lisp
(:hello :protocol 1 :pid 1234 :mode :boot)
(:progress :phase :packages :done 4 :total 19)
(:eval :id 41 :form (load-theme 'modus-vivendi t))
(:result :id 41 :ok t :value t)
(:event :name :package-installed :package "magit")
(:error :phase :unit :unit "evil-config" :message "Missing executable: rg")
(:shutdown :reason :boot-complete)
```

This preserves the Lisp advantage while keeping the transport debuggable and evolvable.

### Bootstrap Recommendation

The micro-bootstrap should still be extremely small, but not just:

- start process
- block forever in a `while`
- directly `eval` every incoming form

The Emacs bootstrap should do four things:

1. start the Hypervisor process
2. attach a process filter
3. accumulate partial chunks in a hidden buffer
4. dispatch complete S-expression messages

Conceptually:

```elisp
(defvar emacs-hypervisor--buffer
  (get-buffer-create " *emacs-hypervisor-stream*"))

(defun emacs-hypervisor--dispatch (msg)
  (pcase (car-safe msg)
    (:hello nil)
    (:progress nil)
    (:log nil)
    (:eval
     (let ((form (plist-get (cdr msg) :form))
           (id   (plist-get (cdr msg) :id)))
       (condition-case err
           (progn
             (eval form)
             (emacs-hypervisor--send `(:result :id ,id :ok t)))
         (error
          (emacs-hypervisor--send
           `(:result :id ,id :ok nil :error ,(format "%S" err)))))))
    (_
     (message "[hypervisor] unknown message: %S" msg))))

(defun emacs-hypervisor--filter (proc chunk)
  (with-current-buffer (process-buffer proc)
    (goto-char (point-max))
    (insert chunk)
    (goto-char (point-min))
    (condition-case nil
        (while t
          (let ((msg (read (current-buffer))))
            (delete-region (point-min) (point))
            (emacs-hypervisor--dispatch msg)))
      (end-of-file nil))))

(make-process
 :name "emacs-hypervisor"
 :buffer emacs-hypervisor--buffer
 :command '("hypervisor-binary")
 :filter #'emacs-hypervisor--filter
 :coding 'utf-8-unix
 :noquery t)
```

This is the same core idea as the "zombie waiting for brainwaves" model, but with an actual protocol boundary.

### Transport Choice for MVP

The transport choice for MVP should be:

- stdio
- one Hypervisor process started by Emacs
- one Emacs process filter
- one S-expression message stream in each direction
- explicit `:eval` messages when the orchestrator wants Emacs to execute code

This is the simplest thing that:

- respects the Lisp advantage
- avoids JSON-RPC overhead
- supports streaming progress
- supports responses and errors
- leaves room for daemon mode later

### State Synchronization Model

The right state model is not "perfect bidirectional mirror of all Emacs state".
That would become vague and fragile very quickly.

Instead:

- Hypervisor is authoritative for declarative graph state
- Emacs is authoritative for editor/runtime side effects
- synchronization happens only through explicit protocol events

In other words:

- the Hypervisor owns the plan
- Emacs owns execution side effects
- only named events cross the boundary

### What State the Hypervisor Should Own

- package declarations
- config-unit declarations
- dependency graph
- execution plan
- unit/package lifecycle state
- boot session state
- later: supervisor tree state

### What State Emacs Should Own

- actual loaded features
- actual evaluated Elisp
- package-manager runtime details
- UI/editor state
- buffer/window/frame state

### Policy for Emacs-Originated Mutations

If state changes inside Emacs without going through the Hypervisor, that should be treated as drift, not something the system pretends to model automatically.

For MVP:

- manual package installation inside Emacs is out of scope as a synchronized workflow
- boot orchestration should assume the Hypervisor initiated the relevant actions
- if Emacs mutates important state manually, the safe answer is reload or resync

That is a much better MVP boundary than trying to track every spontaneous Emacs mutation.

### Practical Synchronization Rule

Only these categories should cross the transport in MVP:

- command messages from Hypervisor to Emacs
- completion/failure replies from Emacs to Hypervisor
- package-manager events
- explicit lifecycle notifications

Examples:

```lisp
(:eval :id 101 :form (load-file "/tmp/hypervisor-packages.el"))
(:result :id 101 :ok t)
(:event :name :package-installed :package "consult")
(:event :name :feature-loaded :feature consult)
(:event :name :unit-failed :unit "llm-tools" :reason "EnvDep failure: OPENAI_API_KEY")
```

### What This Means for the First Boot Flow

The first MVP boot flow should look like this:

1. Emacs starts the Hypervisor binary.
2. Hypervisor sends `(:hello ...)`.
3. Emacs replies with startup context if needed.
4. Hypervisor resolves the package/config graph.
5. Hypervisor emits `:eval` commands for package setup and config execution.
6. Emacs returns `:result` or `:error` for each execution step.
7. Hypervisor updates lifecycle state and decides what to skip next.
8. Hypervisor emits final `:shutdown` or idle/ready message.

### Recommendation Summary

Use:

- S-expression transport over stdio
- async process filters
- explicit message dispatch
- explicit `:eval` messages for code execution

Do not use as the primary MVP transport:

- JSON-RPC
- blocking loops in `init.el`
- totally unstructured "eval whatever arrives" streaming

## Milestone 8: Choose the Process Lifecycle

### Decision

The process lifecycle for MVP should be:

- session-scoped subprocess

That means:

- Emacs starts one Hypervisor backend process
- the backend lives for the Emacs session
- reload reuses the same process when possible
- there is no separate daemon discovery, socket attachment, or global service management in MVP

### Why This Is Better Than One-Shot

A one-shot process is too short-lived for what the project is trying to become.

Even if the first boot work is finite, keeping the process alive gives the design room for:

- reload in the same Emacs session
- progress and status inspection
- future subtree reload
- future runtime events

### Why This Is Better Than Daemon Mode for MVP

A true daemon introduces extra operational complexity too early:

- process discovery
- socket or named-pipe transport
- reconnect behavior
- stale daemon handling
- per-project/session routing

That is useful only when the simpler session-scoped model becomes limiting.

### Relationship to `emacs-backbone`

`emacs-backbone` effectively uses the same lifecycle shape, even though it uses JSON-RPC:

- Emacs starts the backend once
- the process is reused during the session
- reload reuses the connection and sends `init` again

That makes session-scoped subprocess the most conservative and defensible default for `emacs-hypervisor`.

## Milestone 9: First Tiny End-to-End Spike

### Result

This milestone succeeded.

The repository now contains the first tiny working end-to-end protocol spike:

- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
- [experiments/lisp/01-emacs-hypervisor-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/01-emacs-hypervisor-spike.el)
- [experiments/elle/01-hello-eval-result.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/01-hello-eval-result.lisp)
- [experiments/bin/01-run-hello-eval-result-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/01-run-hello-eval-result-spike)

### What the Spike Does

The spike proves this exact loop:

1. Emacs starts the Elle backend as a session-scoped subprocess.
2. The backend sends `:hello`.
3. The backend sends one `:eval` request.
4. Emacs evaluates the form and sends back `:result`.
5. The backend validates the reply and sends `:shutdown`.

### Runner Command

The spike can be run with:

```sh
experiments/bin/01-run-hello-eval-result-spike
```

The default runner assumes:

- `emacs` is on `PATH`
- Elle is available at `/tmp/elle/target/release/elle`

It can be overridden with:

- `EMACS_BIN`
- `ELLE_BIN`

### Observed Output

The successful run produced:

```text
(:ok t :state :eval-ran :shutdown :spike-complete :messages 4 :sentinel "finished
")
```

### What This Proves

This spike proves the core transport idea is workable in practice:

- Emacs process filters are enough for the protocol
- S-expression transport over stdio works
- explicit `:eval` messages can be dispatched and acknowledged
- the backend can read one reply from stdin and continue
- the session-scoped subprocess model is operationally simple

### What This Does Not Prove Yet

This is still only a transport spike.

It does not yet prove:

- package orchestration
- config-unit graph execution
- reload behavior across multiple requests
- richer message types like `:progress`, `:log`, or `:event`
- resilience around malformed messages
- a long-lived reusable backend state machine

### Immediate Design Consequence

The project no longer needs to debate whether the stdio S-expression loop is plausible.

That part is now demonstrated.

The next work should move from "can this transport work?" to "what is the first real protocol module and session bootstrap skeleton?"

## Milestone 10: Refine the Bootstrap Boundary

### Decision

The bootstrap mechanism should follow a three-stage model:

1. Stage 0: tiny static Elisp kernel
2. Stage 1: Elle-generated Elisp runtime
3. Stage 2: normal streamed protocol work

This is the right answer to the "can Elisp become nearly zero?" question.

The answer is:

- user-authored Elisp can become nearly zero
- total Elisp cannot become zero
- the irreducible minimum is a tiny trusted bootstrap kernel inside Emacs

### What Must Stay in Stage 0

Stage 0 must do only the work Emacs must know before it can trust anything emitted by the backend:

- start the session-scoped subprocess
- attach the process filter
- accumulate partial stream chunks
- parse complete S-expressions with `read`
- dispatch minimal built-in message types
- send replies back over stdin

That code cannot be generated by Elle first, because Emacs needs it in order to communicate with Elle at all.

### What Can Move Into Stage 1

Once Stage 0 is alive, Elle can generate and stream a richer runtime into Emacs.

That runtime can define:

- extra protocol handlers
- helper functions
- status and logging utilities
- future reload/status commands
- package bridge helpers

This is where most higher-level Elisp should live.

### Practical Shape of `init.el`

The real target is not a large `init.el`.
It is something conceptually close to:

```elisp
(load-file "~/.config/emacs/hypervisor/bootstrap.el")
(emacs-hypervisor-start '("/path/to/hypervisor"))
```

That is "nearly zero" in the only sense that matters for maintenance.

## Milestone 11: Stage 0 / Stage 1 End-to-End Spike

### Result

This milestone succeeded.

The repository now contains a second, more meaningful spike:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
- [experiments/lisp/02-emacs-hypervisor-bootstrap-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/02-emacs-hypervisor-bootstrap-spike.el)
- [experiments/elle/02-bootstrap-stage1-runtime.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/02-bootstrap-stage1-runtime.lisp)
- [experiments/bin/02-run-bootstrap-stage1-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/02-run-bootstrap-stage1-spike)

### What This Spike Proves

This spike proves a more important loop than the first one:

1. Stage 0 Elisp starts the Elle subprocess.
2. Elle sends `:hello`.
3. Elle sends `:eval` that installs a generated Stage 1 runtime.
4. Emacs acknowledges with `:result`.
5. Elle sends a `:log` message handled by the generated Stage 1 runtime, not by Stage 0.
6. Elle sends another `:eval` that calls a function defined by Stage 1.
7. Emacs acknowledges with `:result`.
8. Elle sends `:shutdown`.

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :bootstrap-spike-complete :runtime-events (:stage1-ran) :runtime-logs ("from-stage1") :messages 9 :sentinel "finished
")
```

### Why This Matters

This is the first concrete proof that the architecture can actually work the way intended:

- Stage 0 remains small
- Elle can generate real Elisp runtime code
- generated runtime code can extend protocol handling
- later protocol traffic can depend on functions installed by that generated runtime

That is exactly the mechanism needed to keep user-authored Elisp near zero without pretending Elisp can disappear entirely.

## Milestone 12: First Real Session Skeleton

### Result

This milestone succeeded.

The protocol now has a more realistic session shape:

- `:hello`
- `:hello-ack`
- `:boot-context`
- built-in `:progress`
- built-in `:log`
- multiple `:eval` / `:result` rounds in one session
- Stage 1 runtime handling of `:event`

New files added for this step:

- [experiments/lisp/03-emacs-hypervisor-session-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/03-emacs-hypervisor-session-spike.el)
- [experiments/elle/03-session-handshake-runtime.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/03-session-handshake-runtime.lisp)
- [experiments/bin/03-run-session-handshake-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/03-run-session-handshake-spike)

### Important Kernel Change

The Stage 0 kernel now has two layers of built-in behavior:

1. core dispatch
   - `:hello`
   - `:eval`
   - `:shutdown`

2. fallback dispatch
   - `:progress`
   - `:log`

Runtime dispatch sits between those two layers.

That means:

- Stage 0 always owns session startup and code execution boundaries
- Stage 1 can extend richer non-core protocol traffic
- if Stage 1 does not handle `:progress` or `:log`, Stage 0 still records them

### What the New Spike Proves

The new session spike proves this flow:

1. Elle sends `:hello`.
2. Emacs sends `:hello-ack`.
3. Emacs sends `:boot-context`.
4. Elle validates both handshake replies.
5. Elle emits built-in `:progress` and `:log`.
6. Elle installs a Stage 1 runtime with `:eval`.
7. Elle emits `:event` messages handled by Stage 1.
8. Elle performs multiple `:eval` / `:result` rounds in one session.
9. Elle shuts down cleanly.

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :session-spike-complete :progress 2 :logs 2 :runtime-events ((:event :session-ready) (:event :runtime-installed)) :messages 16 :sentinel "finished
")
```

### Why This Matters

This is the first version that starts to look like a real Hypervisor session instead of a transport toy.

It proves:

- the session-scoped subprocess lifecycle is working in practice
- Emacs can provide explicit boot context at handshake time
- Stage 0 can own baseline observability through `:progress` and `:log`
- Stage 1 can extend the protocol without replacing the kernel
- the session can survive multiple request/reply rounds

### Practical Conclusion

The architecture is now stable enough to stop treating every next step as a pure experiment.

The next work can move toward the first real startup contract:

- declaration exchange
- environment and machine context
- package/config boot phases
- more durable Stage 1 runtime shape

## Milestone 13: First Startup Contract

### Result

This milestone succeeded.

The project now has a first real startup contract for exporting declarations
and environment data from Emacs into the session.

New files added for this step:

- [lisp/emacs-hypervisor-declarations.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-declarations.el)
- [experiments/lisp/04-emacs-hypervisor-session-data-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/04-emacs-hypervisor-session-data-spike.el)
- [experiments/elle/04-session-data-boot-phases.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/04-session-data-boot-phases.lisp)
- [experiments/bin/04-run-session-data-boot-phases-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/04-run-session-data-boot-phases-spike)

### Kernel Extension

The Stage 0 kernel now supports:

- `:request-session-data`
- `:session-data`

The export hook is:

- `emacs-hypervisor-session-data-function`

The default implementation is empty, but the new declarations module provides:

- `package!`
- `config-unit!`
- package export
- config-unit export
- selected environment export
- combined session-data export

### Startup Contract Shape

The first real contract is now:

1. Elle sends `:hello`.
2. Emacs replies with `:hello-ack`.
3. Emacs replies with `:boot-context`.
4. Elle requests declaration/environment payload with `:request-session-data`.
5. Emacs replies with `:session-data`.
6. Elle starts package/config boot phases.

### Session Data Contents

The current `:session-data` payload includes:

- `:packages`
- `:units`
- `:env`

The spike validates real exported content, including:

- packages `evil` and `evil-collection`
- units `evil-config` and `evil-collection-config`
- environment variables `SHELL` and `PATH`

### First Boot-Phase Proof

The new spike proves:

1. the backend can explicitly request declarations/environment
2. Emacs can export real package and config-unit data
3. the backend can validate the returned session data
4. the backend can then run a package phase
5. the backend can then run a config-unit phase
6. Emacs can track those phase transitions through Stage 1 helper code

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :session-data-spike-complete :session-data-replies 1 :progress 4 :logs 2 :phase-events ((:phase :config (:units ("evil-config" "evil-collection-config"))) (:phase :packages (:items ("evil" "evil-collection")))) :messages 18 :sentinel "finished
")
```

### Why This Matters

This is the first step where the project starts to resemble the actual
`emacs-backbone` problem space:

- declarations exist
- the backend receives them explicitly
- boot phases are separated
- environment preconditions are part of the contract

That means the project can now move from protocol scaffolding toward actual
dependency resolution and phase execution semantics.

## Milestone 14: First Dependency Resolution and Failure Propagation Spike

### Result

This milestone succeeded.

The project now has a first explicit dependency-resolution spike that derives
an intended package/unit order from exported declarations and then simulates
failure propagation across phases.

New files added for this step:

- [experiments/lisp/05-emacs-hypervisor-resolution-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/05-emacs-hypervisor-resolution-spike.el)
- [experiments/elle/05-dependency-resolution-failure-propagation.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/05-dependency-resolution-failure-propagation.lisp)
- [experiments/bin/05-run-dependency-resolution-failure-propagation-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/05-run-dependency-resolution-failure-propagation-spike)

### What This Spike Proves

The `05` spike proves the first real control-plane semantics:

1. Elle can request declarations and environment data from Emacs.
2. Elle can derive a package/config plan from the returned startup payload.
3. A failed package can mark downstream packages as skipped.
4. Skipped or failed packages can block dependent config units.
5. Independent branches can continue through the config phase.

### Scenario

The fixture defines:

- packages:
  - `evil`
  - `magit`
  - `evil-collection`, which depends on `evil`

- config units:
  - `magit-config`, which requires `magit`
  - `evil-config`, which requires `evil`
  - `evil-collection-config`, which requires `evil-collection` and comes after `evil-config`

The backend then simulates:

- package `evil` failing
- package `evil-collection` being skipped because it depends on `evil`
- `evil-config` and `evil-collection-config` being skipped because their required package branch failed
- `magit` and `magit-config` continuing successfully because they are independent

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :resolution-spike-complete :session-data-replies 1 :progress 5 :logs 3 :plans ((:package-order ("evil" "magit" "evil-collection") :unit-order ("magit-config" "evil-config" "evil-collection-config"))) :outcomes ((:phase :config :payload (:ran ("magit-config") :skipped ("evil-config" "evil-collection-config"))) (:phase :packages :payload (:ran ("magit") :failed ("evil") :skipped ("evil-collection")))) :messages 22 :sentinel "finished
")
```

### Limitation Exposed by the Spike

The important caveat from `05` was that Elle-side validation was still mostly
string-based against the `:session-data` line.

That was good enough to prove the high-level phase semantics, but it was too
fragile for the next resolver step.

## Milestone 15: Structured Session-Data Parsing and Stable Resolution

### Result

This milestone succeeded.

The project now has a `06` spike that parses `:session-data` with Elle's real
`read` primitive instead of substring-matching the raw line. The resolver now
derives package and config-unit execution order from structured declaration
data and applies failure propagation over those derived plans.

New files added for this step:

- [experiments/lisp/06-emacs-hypervisor-structured-resolution-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/06-emacs-hypervisor-structured-resolution-spike.el)
- [experiments/elle/06-structured-session-data-resolution.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/06-structured-session-data-resolution.lisp)
- [experiments/bin/06-run-structured-session-data-resolution-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/06-run-structured-session-data-resolution-spike)

### What Changed

The key step here is not just "another spike passed".

The important architectural improvement is:

- incoming protocol data is now treated as structured S-expression data in Elle
- the backend no longer depends on substring checks to understand declarations
- package order is derived by a stable topological pass over `:deps`
- config-unit order is derived by a stable topological pass over `:after`
- package failures and config-unit failures are propagated using the derived plan

The stable-order rule in the current spike is:

- if multiple nodes are ready at the same time, keep declaration order among those ready nodes

That gives deterministic output without prematurely introducing concurrency or
supervisor complexity into the core resolver.

### Scenario

The `06` fixture intentionally scrambles declaration order and uses two failure
branches:

- packages:
  - `evil-collection`, which depends on `evil`
  - `magit`
  - `evil`

- config units:
  - `magit-post-config`, which requires `magit` and comes after `magit-config`
  - `evil-collection-config`, which requires `evil-collection` and comes after `evil-config`
  - `core-ui-config`
  - `magit-config`, which requires `magit`
  - `evil-config`, which requires `evil`

The backend then derives:

- package order:
  - `magit`
  - `evil`
  - `evil-collection`

- unit order:
  - `core-ui-config`
  - `magit-config`
  - `magit-post-config`
  - `evil-config`
  - `evil-collection-config`

And simulates:

- package `evil` failing, which skips `evil-collection`
- config unit `magit-config` failing, which skips `magit-post-config`
- the independent `core-ui-config` branch still running
- the `evil` branch config units being skipped because their required package path already failed

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :structured-resolution-spike-complete :session-data-replies 1 :progress 6 :logs 4 :plans ((:package-order ("magit" "evil" "evil-collection") :unit-order ("core-ui-config" "magit-config" "magit-post-config" "evil-config" "evil-collection-config") :env-vars ("SHELL" "PATH"))) :outcomes ((:phase :config :payload (:ran ("core-ui-config") :failed ("magit-config") :skipped ("magit-post-config" "evil-config" "evil-collection-config"))) (:phase :packages :payload (:ran ("magit") :failed ("evil") :skipped ("evil-collection")))) :messages 24 :sentinel "finished
")
```

### Why This Matters

This is the first point where the Hypervisor starts to look like a real
resolver instead of a message-sequencing prototype.

It now proves:

- Elle can consume the Emacs declaration export as data, not text
- plan derivation can be data-driven and deterministic
- package-phase and config-phase propagation can both be modeled in one session
- the bootstrap/session transport is stable enough to support richer control-plane logic

That is the right point to move the next work toward:

- explicit validation errors for missing references and cycles
- runtime prerequisite checks for `:env` and `:executable`
- extracting reusable Elle modules from the spike scripts

## Milestone 16: Quasiquote Wire Serializer

### Result

This milestone succeeded.

The project now has a `07` spike that proves Elle can build outgoing protocol
messages with quasiquote/unquote and then serialize them into exact plain
S-expressions for Emacs without hand-assembling Elisp strings.

New files added for this step:

- [experiments/lisp/07-emacs-hypervisor-wire-serializer-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/07-emacs-hypervisor-wire-serializer-spike.el)
- [experiments/elle/07-quasiquote-wire-serializer.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/07-quasiquote-wire-serializer.lisp)
- [experiments/bin/07-run-quasiquote-wire-serializer-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/07-run-quasiquote-wire-serializer-spike)

### The Design Question

The practical question was:

- are quasiquote/unquote message templates better than manual string construction?

The answer is:

- yes, for constructing message data
- but not if they are emitted with the wrong printer

The key issue discovered in experiments was:

- raw `pp` preserves keywords well, but syntax-bearing code forms can print as syntax objects or quoted symbols
- raw `string` prints plain symbols well, but it drops the `:` prefix from keywords and is not a complete wire serializer

So the real requirement was not just "use quasiquote".
It was:

- use quasiquote/unquote to build the message structure
- then serialize that structure with a purpose-built wire printer

### What the New Serializer Does

The `07` spike adds a small Elle-side serializer that:

- unwraps syntax objects with `syntax->datum`
- prints plain symbols without quote sugar
- preserves keywords with the `:` prefix
- escapes strings via `json/serialize`
- recursively emits nested list structure as plain S-expressions

That is the missing piece that lets Elle emit messages like:

- `:hello`
- `:request-session-data`
- `:progress`
- `:log`
- `:eval`
- `:shutdown`

using one consistent message-construction style.

### What This Spike Proves

The `07` spike proves:

1. Elle can build protocol messages with quasiquote/unquote.
2. Elle can serialize nested Elisp code forms into exact wire text that Emacs can `read`.
3. Elle can send quoted plist payloads inside `:eval` forms without reverting to hand-built strings.
4. The same transport/runtime scenario from `06` still works with the serializer-based emitter.

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :wire-serializer-spike-complete :session-data-replies 1 :progress 6 :logs 4 :plans ((:package-order ("magit" "evil" "evil-collection") :unit-order ("core-ui-config" "magit-config" "magit-post-config" "evil-config" "evil-collection-config") :env-vars ("SHELL" "PATH"))) :outcomes ((:phase :config :payload (:ran ("core-ui-config") :failed ("magit-config") :skipped ("magit-post-config" "evil-config" "evil-collection-config"))) (:phase :packages :payload (:ran ("magit") :failed ("evil") :skipped ("evil-collection")))) :messages 24 :sentinel "finished
")
```

### Why This Matters

This is an important cleanup milestone because it removes a real architectural
wart:

- `06` proved the resolver
- `07` proves the right message-construction model for future Elle code

That means future milestones no longer need to choose between:

- nice quasiquoted message templates
- or exact wire output

They can have both.

## Milestone 17: Validation and Preflight Checks

### Result

This milestone succeeded.

The project now has an `08` spike that explicitly validates graph problems in
Elle and performs first real preflight checks before execution.

New files added for this step:

- [experiments/lisp/08-emacs-hypervisor-validation-preflight-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/08-emacs-hypervisor-validation-preflight-spike.el)
- [experiments/elle/08-validation-preflight-checks.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/08-validation-preflight-checks.lisp)
- [experiments/bin/08-run-validation-preflight-checks-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/08-run-validation-preflight-checks-spike)

### What Changed

The important step here is that the backend now distinguishes between:

- graph validation failures
- preflight environment failures
- preflight executable failures

instead of treating everything as an eventual execution problem.

The `08` spike now validates:

- missing package dependency references from `package! :deps`
- missing package references from `config-unit! :requires`
- missing config-unit references from `config-unit! :after`
- package cycles over `:deps`
- config-unit cycles over `:after`

And it preflights:

- `:env` requirements from exported `:session-data`
- `:executable` requirements by probing Emacs with `executable-find`

### Fixture

The validation fixture intentionally contains both valid and invalid data:

- packages:
  - `ok-pkg`
  - `missing-pkg`, which depends on missing package `ghost-package`
  - `cycle-a`, which depends on `cycle-b`
  - `cycle-b`, which depends on `cycle-a`

- config units:
  - `missing-required-pkg-unit`, which requires missing package `ghost-package`
  - `missing-after-unit`, which comes after missing unit `ghost-unit`
  - `cycle-unit-a`, which comes after `cycle-unit-b`
  - `cycle-unit-b`, which comes after `cycle-unit-a`
  - `preflight-ok-unit`, which requires `ok-pkg`, env `SHELL`, and executable `git`
  - `preflight-bad-unit`, which requires `ok-pkg`, env `HYPERVISOR_MISSING_ENV`, and executable `definitely-not-installed-command`

### Representation Decision

This milestone also forced a practical wire-format decision for failures.

The current answer is:

- human-facing diagnostics travel as `:log`
- structured reports are recorded through explicit `:eval` messages into Emacs

That is not the only long-term design, but it is the simplest shape that works
with the current trusted kernel.

It means the system now has two simultaneous outputs:

- streamed operator-visible warnings
- machine-checkable validation/preflight reports

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :validation-preflight-spike-complete :session-data-replies 1 :progress 6 :logs 8 :validation ((:package-missing ((:name "missing-pkg" :missing ("ghost-package"))) :package-cycles ("cycle-a" "cycle-b") :unit-missing-requires ((:name "missing-required-pkg-unit" :missing ("ghost-package"))) :unit-missing-after ((:name "missing-after-unit" :missing ("ghost-unit"))) :unit-cycles ("cycle-unit-a" "cycle-unit-b"))) :preflight ((:env-checks ((:unit "preflight-ok-unit" :missing nil) (:unit "preflight-bad-unit" :missing ("HYPERVISOR_MISSING_ENV"))) :executable-checks ((:unit "preflight-ok-unit" :ok ("git") :missing nil) (:unit "preflight-bad-unit" :ok nil :missing ("definitely-not-installed-command"))))) :messages 30 :sentinel "finished
")
```

### Why This Matters

This is the first milestone where the Hypervisor has something recognizably
close to a real startup gate.

It now proves:

- Elle can reject structurally invalid declaration graphs before execution
- environment failures can be identified from exported session data
- executable failures can be checked through the Emacs runtime directly
- validation and preflight can be reported as structured artifacts, not just logs

That is the right foundation for the next step:

- decide how a real boot session should stop, degrade, or continue after these failures
- factor the serializer, validation, and preflight helpers out of the spike files
- begin composing validation/preflight with the actual package/config execution path

## Milestone 18: Boot Policy With Subgraph Skip Semantics

### Result

This milestone succeeded.

The project now has a `09` spike that encodes the intended boot policy:

- local declaration failures become `:invalid`
- preflight failures become `:skipped`
- downstream dependents are skipped transitively
- independent branches continue

New files added for this step:

- [experiments/lisp/09-emacs-hypervisor-boot-policy-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/09-emacs-hypervisor-boot-policy-spike.el)
- [experiments/elle/09-boot-policy-subgraph-skip.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/09-boot-policy-subgraph-skip.lisp)
- [experiments/bin/09-run-boot-policy-subgraph-skip-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/09-run-boot-policy-subgraph-skip-spike)

### Policy Shape

The important semantic split is now explicit:

- `:invalid`
  - the node itself is locally wrong
  - examples:
    - missing package dependency
    - missing unit `:after`
    - package cycle member
    - unit cycle member

- `:skipped`
  - the node itself is not locally malformed
  - but some prerequisite or gate blocked it
  - examples:
    - depends on invalid/skipped package
    - comes after invalid/skipped unit
    - fails env or executable preflight

- `:ok`
  - the node survives all gates and the independent branch continues

That is exactly the "subgraph skip" behavior the project wanted.

### Fixture

The `09` fixture is designed to separate invalid nodes from blocked nodes.

Package branch:

- `core-pkg`
- `ui-pkg`, depends on `core-pkg`
- `missing-root`, depends on missing `ghost-pkg`
- `missing-dependent`, depends on `missing-root`
- `cycle-a`, depends on `cycle-b`
- `cycle-b`, depends on `cycle-a`
- `cycle-dependent`, depends on `cycle-a`

Unit branch:

- `core-ui-unit`, requires `core-pkg`
- `ui-unit`, requires `ui-pkg`, after `core-ui-unit`
- `missing-required-unit`, requires missing `ghost-pkg`
- `blocked-by-package-unit`, requires `missing-dependent`
- `invalid-after-unit`, after missing `ghost-unit`
- `cycle-unit-a`, after `cycle-unit-b`
- `cycle-unit-b`, after `cycle-unit-a`
- `cycle-dependent-unit`, after `cycle-unit-a`
- `preflight-bad-unit`, requires `core-pkg`, env `HYPERVISOR_MISSING_ENV`, executable `definitely-not-installed-command`
- `preflight-dependent-unit`, after `preflight-bad-unit`
- `independent-unit`

### What This Spike Proves

The spike proves the exact boot policy now desired:

1. `missing-root` is `:invalid`, while `missing-dependent` is only `:skipped`
2. `cycle-a` and `cycle-b` are `:invalid`, while `cycle-dependent` is only `:skipped`
3. `missing-required-unit` and `invalid-after-unit` are `:invalid`
4. `cycle-unit-a` and `cycle-unit-b` are `:invalid`, while `cycle-dependent-unit` is only `:skipped`
5. `preflight-bad-unit` is `:skipped` because env/executable gates fail
6. `preflight-dependent-unit` is `:skipped` because it depends on that skipped unit
7. `core-ui-unit`, `ui-unit`, and `independent-unit` remain `:ok`

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :boot-policy-subgraph-skip-spike-complete :session-data-replies 1 :progress 5 :reports ((:phase :units :payload ((:name "core-ui-unit" :status :ok :reason :ready :details (:requires ("core-pkg") :after nil)) (:name "ui-unit" :status :ok :reason :ready :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "missing-required-unit" :status :invalid :reason :missing-required-packages :details ("ghost-pkg")) (:name "blocked-by-package-unit" :status :skipped :reason :blocked-by-package :details ("missing-dependent")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "cycle-unit-a" :status :invalid :reason :cycle :details ("cycle-unit-a" "cycle-unit-b")) (:name "cycle-unit-b" :status :invalid :reason :cycle :details ("cycle-unit-a" "cycle-unit-b")) (:name "cycle-dependent-unit" :status :skipped :reason :blocked-by-unit :details ("cycle-unit-a")) (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))) (:name "preflight-dependent-unit" :status :skipped :reason :blocked-by-unit :details ("preflight-bad-unit")) (:name "independent-unit" :status :ok :reason :ready :details (:requires nil :after nil)))) (:phase :packages :payload ((:name "core-pkg" :status :ok :reason :ready :details nil) (:name "ui-pkg" :status :ok :reason :ready :details ("core-pkg")) (:name "missing-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "missing-dependent" :status :skipped :reason :blocked-by-package :details ("missing-root")) (:name "cycle-a" :status :invalid :reason :cycle :details ("cycle-a" "cycle-b")) (:name "cycle-b" :status :invalid :reason :cycle :details ("cycle-a" "cycle-b")) (:name "cycle-dependent" :status :skipped :reason :blocked-by-package :details ("cycle-a"))))) :messages 33 :sentinel "finished
")
```

### Why This Matters

This is the first milestone where the Hypervisor boot policy is both:

- fault-tolerant
- locally precise

It no longer conflates:

- "this node is broken"
- with
- "this node was blocked by something else"

That distinction is what makes the control plane understandable and debuggable.

It is also the clearest conceptual step away from "phase-fatal validation" and
toward a true supervised boot graph.

## Milestone 19: Extract Shared Elle Runtime Modules

### Result

This milestone succeeded.

The project now has a `10` spike that keeps the `09` boot-policy behavior
stable while moving the duplicated Elle-side helpers into shared runtime
files.

New files added for this step:

- [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp)
- [elle/graph.lisp](/Users/randall/projects/emacs-hypervisor/elle/graph.lisp)
- [elle/preflight.lisp](/Users/randall/projects/emacs-hypervisor/elle/preflight.lisp)
- [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
- [experiments/elle/10-runtime-modules-boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/10-runtime-modules-boot-policy.lisp)
- [experiments/lisp/10-emacs-hypervisor-runtime-modules-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/10-emacs-hypervisor-runtime-modules-spike.el)
- [experiments/bin/10-run-runtime-modules-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/10-run-runtime-modules-spike)

### What Changed

The important change here is not new semantics.
The important change is that the current semantics are no longer trapped
inside one large spike script.

The shared Elle runtime is now split into four concerns:

- `protocol.lisp`
  - exact S-expression wire serialization
  - message read/write helpers
  - plist access and `:result` correlation

- `graph.lisp`
  - declaration field access
  - missing-reference collection
  - cycle-core detection that keeps only actual cycle members `:invalid`
  - ordered report resolution

- `preflight.lisp`
  - env-gate checks from exported session data
  - executable probes through Emacs with `executable-find`

- `boot-policy.lisp`
  - package policy derivation
  - unit policy derivation
  - report-log emission

### What The `10` Spike Proves

The new spike proves that the modular path is real, not just aspirational:

1. shared runtime files can be loaded and composed from a numbered spike
2. the subgraph-skip semantics from `09` stay unchanged after extraction
3. package and unit reports still preserve declaration order
4. preflight probing still works through the same stdio `:eval` / `:result` loop
5. the project can now build the next milestone on reusable runtime code instead of another copy-paste spike

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :runtime-modules-spike-complete :session-data-replies 1 :progress 5 :reports ((:phase :units :payload ((:name "core-ui-unit" :status :ok :reason :ready :details (:requires ("core-pkg") :after nil)) (:name "ui-unit" :status :ok :reason :ready :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "missing-required-unit" :status :invalid :reason :missing-required-packages :details ("ghost-pkg")) (:name "blocked-by-package-unit" :status :skipped :reason :blocked-by-package :details ("missing-dependent")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "cycle-unit-a" :status :invalid :reason :cycle :details ("cycle-unit-a" "cycle-unit-b")) (:name "cycle-unit-b" :status :invalid :reason :cycle :details ("cycle-unit-a" "cycle-unit-b")) (:name "cycle-dependent-unit" :status :skipped :reason :blocked-by-unit :details ("cycle-unit-a")) (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))) (:name "preflight-dependent-unit" :status :skipped :reason :blocked-by-unit :details ("preflight-bad-unit")) (:name "independent-unit" :status :ok :reason :ready :details (:requires nil :after nil)))) (:phase :packages :payload ((:name "core-pkg" :status :ok :reason :ready :details nil) (:name "ui-pkg" :status :ok :reason :ready :details ("core-pkg")) (:name "missing-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "missing-dependent" :status :skipped :reason :blocked-by-package :details ("missing-root")) (:name "cycle-a" :status :invalid :reason :cycle :details ("cycle-a" "cycle-b")) (:name "cycle-b" :status :invalid :reason :cycle :details ("cycle-a" "cycle-b")) (:name "cycle-dependent" :status :skipped :reason :blocked-by-package :details ("cycle-a"))))) :messages 33 :sentinel "finished
")
```

### Why This Matters

This milestone gives the project a usable Elle runtime seam.

That matters because the next step is no longer:

- write another bigger spike with duplicated helpers

It becomes:

- keep the policy kernel stable
- add real package/config execution on top of it
- decide how runtime execution failures should be represented

## Milestone 20: Stabilize `10` And Add Elle Analysis Workflow

### Result

This milestone succeeded in two parts:

1. the extracted `10` runtime-modularization spike was repaired and verified
2. the repo now has explicit local-analysis and MCP workflow entrypoints for Elle work

New files added for this step:

- [tools/analyze-runtime.lisp](/Users/randall/projects/emacs-hypervisor/tools/analyze-runtime.lisp)
- [tools/analyze-runtime-modules](/Users/randall/projects/emacs-hypervisor/tools/analyze-runtime-modules)
- [tools/start-elle-mcp](/Users/randall/projects/emacs-hypervisor/tools/start-elle-mcp)
- [.gitignore](/Users/randall/projects/emacs-hypervisor/.gitignore)

Updated files:

- [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)

### What Changed

The first issue was mechanical but important:

- the extracted `derive-unit-reports` helper in
  [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
  had a bracket mismatch

That meant the shared runtime existed on disk but the `10` spike was not yet
actually stable.

The second issue was workflow:

- Elle local analysis and MCP were described conceptually
- but the repo did not yet provide a concrete way to use them here

This milestone fixes both.

### Elle Analysis Workflow

The repo now has a local analysis entrypoint:

- [tools/analyze-runtime.lisp](/Users/randall/projects/emacs-hypervisor/tools/analyze-runtime.lisp)
- [tools/analyze-runtime-modules](/Users/randall/projects/emacs-hypervisor/tools/analyze-runtime-modules)

That script analyzes:

- `elle/protocol.lisp`
- `elle/graph.lisp`
- `elle/preflight.lisp`
- `elle/boot-policy.lisp`

using Elle's own `compile/analyze` and `std/portrait` support.

### Observed Output

The repaired `10` spike now passes with:

```text
(:ok t :shutdown :runtime-modules-spike-complete :session-data-replies 1 :progress 5 :reports ((:phase :units :payload ((:name "core-ui-unit" :status :ok :reason :ready :details (:requires ("core-pkg") :after nil)) (:name "ui-unit" :status :ok :reason :ready :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "missing-required-unit" :status :invalid :reason :missing-required-packages :details ("ghost-pkg")) (:name "blocked-by-package-unit" :status :skipped :reason :blocked-by-package :details ("missing-dependent")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "cycle-unit-a" :status :invalid :reason :cycle :details ("cycle-unit-a" "cycle-unit-b")) (:name "cycle-unit-b" :status :invalid :reason :cycle :details ("cycle-unit-a" "cycle-unit-b")) (:name "cycle-dependent-unit" :status :skipped :reason :blocked-by-unit :details ("cycle-unit-a")) (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))) (:name "preflight-dependent-unit" :status :skipped :reason :blocked-by-unit :details ("preflight-bad-unit")) (:name "independent-unit" :status :ok :reason :ready :details (:requires nil :after nil)))) (:phase :packages :payload ((:name "core-pkg" :status :ok :reason :ready :details nil) (:name "ui-pkg" :status :ok :reason :ready :details ("core-pkg")) (:name "missing-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "missing-dependent" :status :skipped :reason :blocked-by-package :details ("missing-root")) (:name "cycle-a" :status :invalid :reason :cycle :details ("cycle-a" "cycle-b")) (:name "cycle-b" :status :invalid :reason :cycle :details ("cycle-a" "cycle-b")) (:name "cycle-dependent" :status :skipped :reason :blocked-by-package :details ("cycle-a"))))) :messages 33 :sentinel "finished
")
```

The local analysis runner now completes across all shared runtime files.

One useful high-level result from the portraits is:

- each runtime module constructor is `silent`
- impure behavior is concentrated in the helper functions that actually touch I/O, retries, or report resolution
- the helper split in `boot-policy.lisp` makes the effect boundary much clearer than the original nested version

### MCP Workflow

The repo now also has an explicit MCP launcher wrapper:

- [tools/start-elle-mcp](/Users/randall/projects/emacs-hypervisor/tools/start-elle-mcp)

Its job is to standardize the repo workflow:

- use `.elle-mcp/store` as the default persistent graph location
- honor `ELLE_MCP_SERVER` when the server source lives elsewhere
- look in common local paths for an Elle MCP checkout

Important caveat:

- the local Elle checkout used for this project does not currently contain the
  MCP server source
- so the wrapper is ready, but a real MCP run still depends on an available
  `mcp-server.lisp`

The current expected wrapper output in this environment is:

```text
Elle MCP server not found.

Expected one of:
- ELLE_MCP_SERVER=/path/to/tools/mcp-server.lisp
- /tmp/elle/mcp/tools/mcp-server.lisp
- ../elle-mcp/tools/mcp-server.lisp
- .vendor/elle-mcp/tools/mcp-server.lisp
```

## Milestone 21: Activate The Real MCP Server Workflow

### Result

This milestone succeeded.

The Elle MCP workflow is no longer just "prepared".
It is now actually working on this machine.

### What Changed

The earlier blocker turned out to be environmental, not architectural:

1. the Elle checkout in `/tmp/elle` had the `mcp` and `plugins` submodules recorded but uninitialized
2. after those submodules were populated, the MCP plugin build still failed because `bindgen` could not find `libclang.dylib`
3. setting `LIBCLANG_PATH=/Applications/Xcode.app/Contents/Frameworks` allowed the `elle-oxigraph` plugin to build successfully

The repo-local wrapper also needed one path correction:

- the real submodule server file is `/tmp/elle/mcp/mcp-server.lisp`
- not only `/tmp/elle/mcp/tools/mcp-server.lisp`

### Verified Setup

The working setup on this machine is:

```sh
git -C /tmp/elle submodule update --init mcp
git -C /tmp/elle submodule update --init plugins
env LIBCLANG_PATH=/Applications/Xcode.app/Contents/Frameworks make -C /tmp/elle mcp
tools/start-elle-mcp
```

### Verified MCP Behavior

The repo wrapper now starts the real MCP server successfully.

Verified interactions:

1. `initialize`
   - returned `serverInfo.name = "elle-mcp"`
   - returned `serverInfo.version = "0.6.0"`

2. `tools/list`
   - returned the full MCP tool inventory

3. `tools/call` with `analyze_file`
   - successfully analyzed
     [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
   - reported:
     - `Functions: 6`
     - `Silent (1): emacs-hypervisor-boot-policy-module`
     - `I/O (4): derive-package-reports, next-package-report, next-unit-report, derive-unit-reports`
     - `Yielding (1): emit-report-logs`

### Why This Matters

This is the first point where the repo can treat Elle MCP as an active
engineering tool rather than a future setup note.

That changes the next phase materially:

- shared Elle runtime refactors can now use real MCP impact queries
- cross-file Elle changes no longer need to rely only on local reasoning
- the agent workflow in `AGENTS.md` is now backed by a tested server path

## Milestone 22: Runtime Execution Spike Over Shared Runtime

### Result

This milestone succeeded.

The project now has an `11` spike that moves beyond planning-only reports and
executes both package and config-unit phases through Emacs while preserving the
shared boot-policy kernel.

New files added for this step:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- [experiments/elle/11-runtime-execution-session.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/11-runtime-execution-session.lisp)
- [experiments/lisp/11-emacs-hypervisor-runtime-execution-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/11-emacs-hypervisor-runtime-execution-spike.el)
- [experiments/bin/11-run-runtime-execution-session-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/11-run-runtime-execution-session-spike)

Updated files:

- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)

### What Changed

The shared runtime now has a first explicit execution layer:

- `execution.lisp`
  - runs package installs through `:eval`
  - runs config-unit bodies through `:eval`
  - preserves planning-time `:invalid` and `:skipped`
  - introduces runtime `:failed`

This resolves the earlier ambiguity between:

- a node that never should have run
- and
- a node that did run but failed while executing

### Runtime State Split

The current runtime meaning is now:

- `:invalid`
  - local structural problem

- `:skipped`
  - blocked by prerequisite or preflight gate

- `:failed`
  - execution actually started and failed

- `:ok`
  - execution succeeded

### What The `11` Spike Proves

The `11` spike proves:

1. shared planning reports can feed a real package execution phase
2. package runtime failure can downgrade downstream packages to `:skipped`
3. shared planning reports can feed a real config-unit execution phase
4. config-unit runtime failure can downgrade downstream units to `:skipped`
5. planning-time invalid/preflight nodes remain invalid/skipped and are never executed
6. successful independent branches continue even when sibling branches fail at runtime

One bug was found and fixed during this milestone:

- initial package execution only consulted planning reports
- that allowed `runtime-fail-dependent` to execute even after
  `runtime-fail-pkg` failed at runtime
- the shared execution kernel now re-checks already executed package reports
  before installing each package
- this restores the intended subgraph skip semantics during runtime, not only
  during planning

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :runtime-execution-session-spike-complete :session-data-replies 1 :progress 7 :reports ((:phase :units :payload ((:name "core-ui-unit" :status :ok :reason :executed :details (:requires ("core-pkg") :after nil)) (:name "ui-unit" :status :ok :reason :executed :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "blocked-by-runtime-package-unit" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "runtime-fail-unit" :status :failed :reason :execution :details "(error \"simulated unit failure\")") (:name "after-runtime-fail-unit" :status :skipped :reason :blocked-by-unit :details ("runtime-fail-unit")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))) (:name "independent-unit" :status :ok :reason :executed :details (:requires nil :after nil)))) (:phase :packages :payload ((:name "core-pkg" :status :ok :reason :executed :details nil) (:name "ui-pkg" :status :ok :reason :executed :details ("core-pkg")) (:name "runtime-fail-pkg" :status :failed :reason :execution :details "(error \"simulated package failure\")") (:name "runtime-fail-dependent" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "invalid-root" :status :invalid :reason :missing-deps :details ("ghost-pkg"))))) :messages ... )
```

The verified harness expectations for this spike are now:

- `7` progress messages
- `11` `:result` replies
- `12` received `:log` messages

The `12` logs come from:

- `1` runtime info log for runtime install
- `3` planning warnings
- `3` package/runtime warnings
- `5` unit/runtime warnings

### Analysis And MCP Used In This Milestone

This milestone was implemented with both local Elle analysis and the real MCP
server workflow.

Verified during the spike:

- `tools/analyze-runtime-modules`
- MCP `analyze_file` on
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- MCP `impact` on `execute-packages` in
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)

One practical note:

- helper-level MCP lookup on `next-package-execution-report` did not resolve in
  the current analysis view even though file-level analysis succeeded
- for now, source plus file-level analysis remains the ground truth when MCP
  misses a freshly introduced helper

### Why This Matters

This is the first real control-plane execution spike over the shared Elle
runtime.

It is no longer just proving:

- transport
- planning
- policy

It is now proving:

- execution decisions
- execution-state transitions
- runtime failure propagation

### Why This Matters

This milestone makes the Elle side much easier to evolve safely:

- shared runtime code is no longer only "modular by intention"
- the `10` spike can now be treated as a real verified base
- local semantic analysis is now a normal repo workflow
- MCP setup is no longer tribal knowledge

## Milestone 23: Explicit Shared Execution Plans

### Result

This milestone succeeded.

The project now has a `12` spike that derives explicit reusable execution plans
for packages and config units, executes from those plans, and then merges the
runtime results back into full declaration-ordered reports.

New files added for this step:

- [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)
- [experiments/elle/12-runtime-execution-plan-session.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/12-runtime-execution-plan-session.lisp)
- [experiments/lisp/12-emacs-hypervisor-runtime-plan-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/12-emacs-hypervisor-runtime-plan-spike.el)
- [experiments/bin/12-run-runtime-execution-plan-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/12-run-runtime-execution-plan-spike)

Updated files:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- [tools/analyze-runtime.lisp](/Users/randall/projects/emacs-hypervisor/tools/analyze-runtime.lisp)
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)

### What Changed

The new planning layer now makes execution order explicit:

- `planning.lisp`
  - derives package plans from planned `:ok` package reports
  - derives unit plans from planned `:ok` unit reports
  - exposes plan names for inspection/recording
  - merges runtime execution results back into the full planned report set

- `execution.lisp`
  - now also supports executing explicit package plans
  - now also supports executing explicit unit plans
  - keeps the old execution entrypoints so spike `11` remains valid

### What The `12` Spike Proves

The `12` spike proves:

1. executable order can be derived as a reusable runtime artifact instead of being implied by fixture traversal
2. package and unit declarations can be intentionally written out of dependency order and still execute in the correct planned order
3. final report order can remain declaration-aligned even when execution order differs
4. runtime `:failed` and dependent `:skipped` propagation still hold when execution is driven by explicit plans
5. the shared runtime can grow without regressing spike `11`

The fixture is intentionally arranged so declaration order and execution order
diverge.

Examples:

- package declarations put `ui-pkg` before `core-pkg`
- package declarations put `runtime-fail-dependent` before `runtime-fail-pkg`
- unit declarations put `ui-unit` before `core-ui-unit`
- unit declarations put `after-runtime-fail-unit` before `runtime-fail-unit`

The derived plans recorded by the spike are:

- packages:
  - `core-pkg`
  - `ui-pkg`
  - `runtime-fail-pkg`
  - `runtime-fail-dependent`

- units:
  - `core-ui-unit`
  - `ui-unit`
  - `blocked-by-runtime-package-unit`
  - `independent-unit`
  - `runtime-fail-unit`
  - `after-runtime-fail-unit`

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :runtime-execution-plan-session-spike-complete :session-data-replies 1 :progress 8 :plans ((:phase :units :payload ("core-ui-unit" "ui-unit" "blocked-by-runtime-package-unit" "independent-unit" "runtime-fail-unit" "after-runtime-fail-unit")) (:phase :packages :payload ("core-pkg" "ui-pkg" "runtime-fail-pkg" "runtime-fail-dependent"))) :reports ((:phase :units :payload ((:name "ui-unit" :status :ok :reason :executed :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "after-runtime-fail-unit" :status :skipped :reason :blocked-by-unit :details ("runtime-fail-unit")) (:name "core-ui-unit" :status :ok :reason :executed :details (:requires ("core-pkg") :after nil)) (:name "blocked-by-runtime-package-unit" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "independent-unit" :status :ok :reason :executed :details (:requires nil :after nil)) (:name "runtime-fail-unit" :status :failed :reason :execution :details "(error \"simulated unit failure\")") (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))))) (:phase :packages :payload ((:name "ui-pkg" :status :ok :reason :executed :details ("core-pkg")) (:name "runtime-fail-dependent" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "core-pkg" :status :ok :reason :executed :details nil) (:name "invalid-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "runtime-fail-pkg" :status :failed :reason :execution :details "(error \"simulated package failure\")")))) :messages 52 :sentinel "finished
")
```

The verified harness expectations for this spike are now:

- `8` progress messages
- `13` `:result` replies
- `12` received `:log` messages

### Analysis And MCP Used In This Milestone

This milestone again used both local Elle analysis and the real MCP workflow.

Verified during the spike:

- `tools/analyze-runtime-modules` across
  [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp),
  [elle/graph.lisp](/Users/randall/projects/emacs-hypervisor/elle/graph.lisp),
  [elle/preflight.lisp](/Users/randall/projects/emacs-hypervisor/elle/preflight.lisp),
  [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp),
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp), and
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- MCP `analyze_file` on
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)
- MCP `impact` on `derive-package-plan` in
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)

One practical note remains:

- MCP `impact` on a freshly added execution helper
  `execute-package-plan` did not resolve in the current analysis view even
  after file analysis
- source plus successful file-level analysis remain the ground truth when the
  current MCP index misses a new helper

### Why This Matters

This milestone separates three concerns much more cleanly:

- boot policy decides what is executable
- planning decides in what order executable nodes should run
- execution decides what actually happened at runtime

That is a better architecture boundary than letting declaration order double as
the execution contract.

## Milestone 24: Protocol Plan Messages And Stage 1 Package Bridge

### Result

This milestone succeeded.

The project now has a `13` spike that:

- emits execution plans as explicit `:plan` protocol messages
- stores those plan messages directly in the Stage 0 bootstrap
- executes package plans through a Stage 1 package-entry bridge that renders
  Elpaca-shaped forms

New files added for this step:

- [experiments/elle/13-plan-messages-package-bridge.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/13-plan-messages-package-bridge.lisp)
- [experiments/lisp/13-emacs-hypervisor-plan-messages-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/13-emacs-hypervisor-plan-messages-spike.el)
- [experiments/bin/13-run-plan-messages-package-bridge-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/13-run-plan-messages-package-bridge-spike)

Updated files:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
- [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)
- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)

### What Changed

The protocol now has a first explicit planning message:

- `(:plan :phase ... :items ...)`

The bootstrap now stores those messages alongside `:progress` and `:log`
without requiring Stage 1 evaluation just to observe them.

The package execution boundary also moved one step closer to the real
`emacs-backbone` architecture:

- Elle no longer asks Emacs to install packages only by package name in this
  spike
- Elle now sends package-entry install intent
- Stage 1 translates that entry into an Elpaca-shaped form
- the spike still simulates success/failure instead of driving real async
  Elpaca completion

### What The `13` Spike Proves

The `13` spike proves:

1. plans can be first-class wire messages rather than `:eval`-recorded side data
2. Stage 0 can store plan messages directly as part of the trusted kernel
3. the package bridge can stay Emacs-owned while Elle still owns planning and execution policy
4. full package entry data is sufficient to render Elpaca-shaped install forms in Emacs
5. spikes `11` and `12` still pass after the shared runtime grows again

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :plan-messages-package-bridge-spike-complete :session-data-replies 1 :progress 8 :plans ((:plan :phase :packages :items ((:name "core-pkg" :deps nil) (:name "ui-pkg" :deps ("core-pkg")) (:name "runtime-fail-pkg" :deps nil) (:name "runtime-fail-dependent" :deps ("runtime-fail-pkg")))) (:plan :phase :units :items ((:name "core-ui-unit" :requires ("core-pkg") :after nil) (:name "ui-unit" :requires ("ui-pkg") :after ("core-ui-unit")) (:name "blocked-by-runtime-package-unit" :requires ("runtime-fail-pkg") :after nil) (:name "independent-unit" :requires nil :after nil) (:name "runtime-fail-unit" :requires nil :after nil) (:name "after-runtime-fail-unit" :requires nil :after ("runtime-fail-unit"))))) :reports ((:phase :units :payload ((:name "ui-unit" :status :ok :reason :executed :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "after-runtime-fail-unit" :status :skipped :reason :blocked-by-unit :details ("runtime-fail-unit")) (:name "core-ui-unit" :status :ok :reason :executed :details (:requires ("core-pkg") :after nil)) (:name "blocked-by-runtime-package-unit" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "independent-unit" :status :ok :reason :executed :details (:requires nil :after nil)) (:name "runtime-fail-unit" :status :failed :reason :execution :details "(error \"simulated unit failure\")") (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))))) (:phase :packages :payload ((:name "ui-pkg" :status :ok :reason :executed :details ("core-pkg")) (:name "runtime-fail-dependent" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "core-pkg" :status :ok :reason :executed :details nil) (:name "invalid-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "runtime-fail-pkg" :status :failed :reason :execution :details "(error \"simulated package failure\")")))) :package-forms ((elpaca (runtime-fail-pkg :host github :repo "example/runtime-fail-pkg" :branch "main") (emacs-hypervisor-stage1-record-package-success "runtime-fail-pkg")) (elpaca (ui-pkg :host github :repo "example/ui-pkg" :branch "main") (emacs-hypervisor-stage1-record-package-success "ui-pkg")) (elpaca (core-pkg :host github :repo "example/core-pkg" :branch "main") (emacs-hypervisor-stage1-record-package-success "core-pkg"))) :messages 50 :sentinel "finished
")
```

The verified harness expectations for this spike are now:

- `2` received `:plan` messages
- `8` progress messages
- `11` `:result` replies
- `12` received `:log` messages

### Analysis And MCP Used In This Milestone

This milestone again used local Elle analysis and the real MCP workflow.

Verified during the spike:

- MCP `analyze_file` on
  [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp)
- MCP `analyze_file` on
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)
- MCP `analyze_file` on
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- MCP `impact` on `derive-unit-plan` in
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)

### Why This Matters

This milestone resolves one of the biggest remaining ambiguities from spike
`12`:

- plans are now protocol data
- not only runtime-internal state

It also moves the package side toward the right long-term ownership boundary:

- Elle decides what should install and in what order
- Emacs decides how that becomes Elpaca work

That is the same architectural split that made `emacs-backbone` workable, now
adapted to the Hypervisor protocol.

## Milestone 25: Async Package Events Over The Shared Runtime

### Result

This milestone succeeded.

The project now has a `14` spike that keeps `:plan` as a first-class protocol
message, queues package work through the Stage 1 package bridge, and receives
package completion back from Emacs as explicit async `:event` messages.

New files added for this step:

- [experiments/elle/14-async-package-events.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/14-async-package-events.lisp)
- [experiments/lisp/14-emacs-hypervisor-async-package-events-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/14-emacs-hypervisor-async-package-events-spike.el)
- [experiments/bin/14-run-async-package-events-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/14-run-async-package-events-spike)

Updated files:

- [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp)
- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)

### What Changed

The package phase now has an explicit async feedback path:

- Elle still emits package plans through `(:plan :phase :packages ...)`
- Elle still asks Stage 1 in Emacs to start package work from full package-entry
  data
- Stage 1 now sends `(:event :phase :packages :name ... :status ...)` back when
  each queued package finishes
- Elle now waits for those package events instead of pretending package
  completion is synchronously known after the initial `:eval`

This keeps the architecture aligned with `emacs-backbone`:

- orchestration stays outside Emacs
- package-manager integration stays inside Emacs
- package completion becomes wire-visible protocol data

### What The `14` Spike Proves

The `14` spike proves:

1. the shared execution runtime can wait for structured async package completion
   without giving up deterministic plan order
2. Stage 1 can remain the Elpaca-shaped translation boundary while Elle stays
   package-manager agnostic
3. explicit `:event` messages are sufficient to represent package success and
   failure for runtime policy
4. runtime `:failed` and dependent `:skipped` package semantics still merge
   cleanly into the shared reporting path
5. spikes `11`, `12`, and `13` still pass after the async execution seam is
   added

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :async-package-events-spike-complete :session-data-replies 1 :progress 8 :plans ((:plan :phase :packages :items ((:name "core-pkg" :deps nil) (:name "ui-pkg" :deps ("core-pkg")) (:name "runtime-fail-pkg" :deps nil) (:name "runtime-fail-dependent" :deps ("runtime-fail-pkg")))) (:plan :phase :units :items ((:name "core-ui-unit" :requires ("core-pkg") :after nil) (:name "ui-unit" :requires ("ui-pkg") :after ("core-ui-unit")) (:name "blocked-by-runtime-package-unit" :requires ("runtime-fail-pkg") :after nil) (:name "independent-unit" :requires nil :after nil) (:name "runtime-fail-unit" :requires nil :after nil) (:name "after-runtime-fail-unit" :requires nil :after ("runtime-fail-unit"))))) :events ((:send :event :phase :packages :name "core-pkg" :status :ok) (:send :event :phase :packages :name "ui-pkg" :status :ok) (:send :event :phase :packages :name "runtime-fail-pkg" :status :failed :error "(error \"simulated package failure\")")) :reports ((:phase :units :payload ((:name "ui-unit" :status :ok :reason :executed :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "after-runtime-fail-unit" :status :skipped :reason :blocked-by-unit :details ("runtime-fail-unit")) (:name "core-ui-unit" :status :ok :reason :executed :details (:requires ("core-pkg") :after nil)) (:name "blocked-by-runtime-package-unit" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "independent-unit" :status :ok :reason :executed :details (:requires nil :after nil)) (:name "runtime-fail-unit" :status :failed :reason :execution :details "(error \"simulated unit failure\")") (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))))) (:phase :packages :payload ((:name "ui-pkg" :status :ok :reason :executed :details ("core-pkg")) (:name "runtime-fail-dependent" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "core-pkg" :status :ok :reason :executed :details nil) (:name "invalid-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "runtime-fail-pkg" :status :failed :reason :execution :details "(error \"simulated package failure\")")))) :package-forms ((elpaca (runtime-fail-pkg :host github :repo "example/runtime-fail-pkg" :branch "main") (ignore "runtime-fail-pkg")) (elpaca (ui-pkg :host github :repo "example/ui-pkg" :branch "main") (ignore "ui-pkg")) (elpaca (core-pkg :host github :repo "example/core-pkg" :branch "main") (ignore "core-pkg"))) :messages 53 :sentinel "finished
")
```

The verified harness expectations for this spike are now:

- `2` received `:plan` messages
- `3` sent `:event` package completion messages
- `8` progress messages
- `11` `:result` replies
- `12` received `:log` messages

### Analysis Used In This Milestone

This milestone re-ran the repo-local Elle analysis workflow on the shared
runtime modules after the protocol and execution helpers grew again.

Verified during the spike:

- `tools/analyze-runtime-modules` across
  [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp),
  [elle/graph.lisp](/Users/randall/projects/emacs-hypervisor/elle/graph.lisp),
  [elle/preflight.lisp](/Users/randall/projects/emacs-hypervisor/elle/preflight.lisp),
  [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp),
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp), and
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)

One useful semantic check from the analysis output:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  now exposes `execute-package-entry-plan-async` and `await-package-event` as
  the new async boundary

### Why This Matters

This milestone establishes the next real protocol seam for the project:

- planning is already explicit protocol data
- package completion is now explicit protocol data too

That means the project no longer needs to fake the most important runtime edge
between "Emacs started package work" and "Elle knows what actually happened".

## Milestone 26: Elpaca-Callback Package Forms

### Result

This milestone succeeded.

The project now has a `15` spike that keeps the shared async package-event
runtime from spike `14`, but moves the completion signal into the generated
Elpaca-shaped package form itself.

New files added for this step:

- [experiments/elle/15-elpaca-callback-package-events.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/15-elpaca-callback-package-events.lisp)
- [experiments/lisp/15-emacs-hypervisor-elpaca-callback-package-events-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/15-emacs-hypervisor-elpaca-callback-package-events-spike.el)
- [experiments/bin/15-run-elpaca-callback-package-events-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/15-run-elpaca-callback-package-events-spike)

Updated files:

- [PROJECT-LOG.md](/Users/randall/projects/emacs-hypervisor/PROJECT-LOG.md)
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)

### What Changed

The important boundary shift in this spike is on the Emacs side:

- Stage 1 no longer sends the package `:event` directly from
  `start-package-entry`
- Stage 1 now renders package forms whose callback position carries
  `(emacs-hypervisor-stage1-package-callback "...")`
- a fake Elpaca queue processes that form asynchronously and invokes the
  callback later
- the callback reads the queued result and sends the package `:event` back to
  Elle

This means the spike now matches the intended callback ownership more closely:

- queueing work is one step
- callback-driven completion is a later step

### What The `15` Spike Proves

The `15` spike proves:

1. the shared async package-event runtime from spike `14` does not need to
   change to move the event source into Elpaca-style callback position
2. generated package forms can carry callback expressions instead of inert
   placeholders like `(ignore "...")`
3. Stage 1 can simulate queue processing and queue-finished hooks without
   re-inlining package outcome logic into Elle
4. package success and failure still merge into the same runtime report path
   after the callback boundary moves
5. spike `14` remains a valid precursor and the earlier runtime-plan spikes
   still pass

### Observed Output

The successful run produced:

```text
(:ok t :shutdown :elpaca-callback-package-events-spike-complete :session-data-replies 1 :progress 8 :plans ((:plan :phase :packages :items ((:name "core-pkg" :deps nil) (:name "ui-pkg" :deps ("core-pkg")) (:name "runtime-fail-pkg" :deps nil) (:name "runtime-fail-dependent" :deps ("runtime-fail-pkg")))) (:plan :phase :units :items ((:name "core-ui-unit" :requires ("core-pkg") :after nil) (:name "ui-unit" :requires ("ui-pkg") :after ("core-ui-unit")) (:name "blocked-by-runtime-package-unit" :requires ("runtime-fail-pkg") :after nil) (:name "independent-unit" :requires nil :after nil) (:name "runtime-fail-unit" :requires nil :after nil) (:name "after-runtime-fail-unit" :requires nil :after ("runtime-fail-unit"))))) :events ((:send :event :phase :packages :name "core-pkg" :status :ok) (:send :event :phase :packages :name "ui-pkg" :status :ok) (:send :event :phase :packages :name "runtime-fail-pkg" :status :failed :error "(error \"simulated package failure\")")) :callback-log ("core-pkg" "ui-pkg" "runtime-fail-pkg") :reports ((:phase :units :payload ((:name "ui-unit" :status :ok :reason :executed :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "after-runtime-fail-unit" :status :skipped :reason :blocked-by-unit :details ("runtime-fail-unit")) (:name "core-ui-unit" :status :ok :reason :executed :details (:requires ("core-pkg") :after nil)) (:name "blocked-by-runtime-package-unit" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "independent-unit" :status :ok :reason :executed :details (:requires nil :after nil)) (:name "runtime-fail-unit" :status :failed :reason :execution :details "(error \"simulated unit failure\")") (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))))) (:phase :packages :payload ((:name "ui-pkg" :status :ok :reason :executed :details ("core-pkg")) (:name "runtime-fail-dependent" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "core-pkg" :status :ok :reason :executed :details nil) (:name "invalid-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "runtime-fail-pkg" :status :failed :reason :execution :details "(error \"simulated package failure\")")))) :package-forms ((elpaca (runtime-fail-pkg :host github :repo "example/runtime-fail-pkg" :branch "main") (emacs-hypervisor-stage1-package-callback "runtime-fail-pkg")) (elpaca (ui-pkg :host github :repo "example/ui-pkg" :branch "main") (emacs-hypervisor-stage1-package-callback "ui-pkg")) (elpaca (core-pkg :host github :repo "example/core-pkg" :branch "main") (emacs-hypervisor-stage1-package-callback "core-pkg"))) :messages 53 :sentinel "finished
")
```

The verified harness expectations for this spike are now:

- `2` received `:plan` messages
- `3` sent `:event` package completion messages
- `3` callback invocations recorded in Stage 1
- `3` fake Elpaca queue process calls
- `3` fake Elpaca queue-finished hook runs
- `8` progress messages
- `11` `:result` replies
- `12` received `:log` messages

### Why This Matters

This milestone narrows the remaining gap to real Elpaca integration.

The project now has three distinct package-phase layers:

- Elle decides executable order and waits for protocol completion
- Stage 1 renders Elpaca-shaped forms with callback expressions
- the queue backend is what invokes completion, not the queueing function

The next design question is now clearer:

- should the real Elpaca path keep explicit per-package status events
- or should it follow Backbone more closely and derive failures from
  `package_installed` plus `packages_finished`

## Milestone 27: Port Elpaca Compatibility And Queue Workarounds

### Result

This milestone succeeded.

The project now has a reusable Elisp module that ports the important
`emacs-backbone` Elpaca compatibility and queue-tracking workarounds into
Hypervisor.

New files added for this step:

- [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
- [experiments/lisp/16-emacs-hypervisor-elpaca-compatibility-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/16-emacs-hypervisor-elpaca-compatibility-spike.el)
- [experiments/bin/16-run-elpaca-compatibility-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/16-run-elpaca-compatibility-spike)

Updated files:

- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
- [PROJECT-LOG.md](/Users/randall/projects/emacs-hypervisor/PROJECT-LOG.md)

### What Changed

The new reusable module,
[lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el),
ports two categories of behavior from `emacs-backbone`.

Elpaca compatibility workarounds:

- infer `:main` for split-package recipes when Elpaca omits it
- choose the nearest prior shared-source owner instead of a future queue entry
- block later git packages on earlier shared-source owners
- delay clone-skip continuation until a shared package's main file exists

Queue lifecycle tracking:

- begin/reset/cancel package timeout handling
- timeout diagnostics over unfinished Elpaca orders
- `package installed` callback surface
- `packages finished` callback surface
- post-queue hook integration

The important design adjustment is that this layer is protocol-agnostic.

Unlike `emacs-backbone`, it does not hardcode JSON-RPC notifications.
Instead it exposes callback hooks so Stage 1 can decide whether package
completion becomes:

- explicit Hypervisor `:event` messages
- or a higher-level `package_installed` plus `packages_finished` tracker model

### What The `16` Spike Proves

The `16` spike proves:

1. the ported split-package and shared-source workarounds behave as expected on
   fake Elpaca objects
2. the clone-skip wait path schedules a deferred main-file wait instead of
   continuing too early
3. the queue tracker resets timeouts on package progress
4. the `packages finished` callback is idempotent
5. timeout diagnostics and timeout-visibility hooks run through the new module
6. the earlier package-bridge spikes still pass after the new module lands

### Observed Output

The compatibility spike produced:

```text
(:ok t :timers 3 :cancels 2 :installed ("core-pkg") :finished ("completed" "timeout") :visibility 1 :logs 2)
```

This reflects:

- `3` timer starts
- `2` timer cancellations
- one observed installed-package callback
- one completed run and one timeout run
- one timeout-visibility callback
- timeout diagnostics emitted through the logging hook

### Verification

Verified in this milestone:

- `experiments/bin/16-run-elpaca-compatibility-spike`
- `experiments/bin/15-run-elpaca-callback-package-events-spike`
- `experiments/bin/14-run-async-package-events-spike`

### Why This Matters

At this point the project has both sides of the real Elpaca boundary:

- spike `15` proves the generated package form and callback shape
- milestone `27` ports the real compatibility/workaround layer that made
  `emacs-backbone` survive tricky Elpaca cases

The next implementation step is no longer "port the Backbone Elpaca logic".
It is:

- wire this reusable compatibility layer into the real Stage 1 package path
- then decide whether the package completion model stays per-package `:event`
  based or moves to a Backbone-style queue tracker

## Milestone 28: Adopt Tracker-Style Package Runtime In Shared Execution

### Result

This milestone succeeded.

The shared Elle execution runtime now has a tracker-based package path, and the
new spike `17` wires the shared Elpaca compatibility module into Stage 1 using
that model.

New files added for this step:

- [experiments/elle/17-elpaca-tracker-package-events.lisp](/Users/randall/projects/emacs-hypervisor/experiments/elle/17-elpaca-tracker-package-events.lisp)
- [experiments/lisp/17-emacs-hypervisor-elpaca-tracker-package-events-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/17-emacs-hypervisor-elpaca-tracker-package-events-spike.el)
- [experiments/bin/17-run-elpaca-tracker-package-events-spike](/Users/randall/projects/emacs-hypervisor/experiments/bin/17-run-elpaca-tracker-package-events-spike)

Updated files:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
- [PROJECT-LOG.md](/Users/randall/projects/emacs-hypervisor/PROJECT-LOG.md)

### What Changed

The shared execution runtime gained a new package path:

- queue every executable package entry first
- process the package queue once
- wait for tracker events instead of per-package status events
- derive final package reports in Elle after the queue-finished barrier

The new Stage 1 tracker protocol is:

- `(:event :phase :packages :kind :installed :name "...")`
- `(:event :phase :packages :kind :finished :reason "...")`

This matches the recommendation taken from `emacs-backbone`:

- success callbacks are treated as reliable facts
- queue completion is treated as the synchronization barrier
- exact per-package failure notifications are not required on the Emacs side
- Elle derives failed roots and blocked dependents after queue completion

The new Stage 1 spike also now loads the reusable
[lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
module inside the generated runtime, rather than keeping queue tracking purely
inside the earlier fake Elpaca spike.

### What The `17` Spike Proves

The `17` spike proves:

1. the shared Elle execution runtime can queue package forms first and derive
   final package reports after one queue barrier
2. the shared Elpaca compatibility module can drive Hypervisor protocol
   messages through its callback hooks
3. Stage 1 no longer needs to send explicit per-package `:failed` events for
   package runtime failure derivation
4. a dependency package can be queued but still end as `:skipped` after tracker
   derivation if its dependency never reported installation
5. the older callback spike `15` and compatibility spike `16` still pass after
   the shared runtime change

### Observed Output

The tracker spike produced:

```text
(:ok t :shutdown :elpaca-tracker-package-events-spike-complete :session-data-replies 1 :progress 8 :plans ((:plan :phase :packages :items ((:name "core-pkg" :deps nil) (:name "ui-pkg" :deps ("core-pkg")) (:name "runtime-fail-pkg" :deps nil) (:name "runtime-fail-dependent" :deps ("runtime-fail-pkg")))) (:plan :phase :units :items ((:name "core-ui-unit" :requires ("core-pkg") :after nil) (:name "ui-unit" :requires ("ui-pkg") :after ("core-ui-unit")) (:name "blocked-by-runtime-package-unit" :requires ("runtime-fail-pkg") :after nil) (:name "independent-unit" :requires nil :after nil) (:name "runtime-fail-unit" :requires nil :after nil) (:name "after-runtime-fail-unit" :requires nil :after ("runtime-fail-unit"))))) :events ((:send :event :phase :packages :kind :installed :name "core-pkg") (:send :event :phase :packages :kind :installed :name "ui-pkg") (:send :event :phase :packages :kind :finished :reason "completed")) :callback-log ("core-pkg" "ui-pkg") :reports ((:phase :units :payload ((:name "ui-unit" :status :ok :reason :executed :details (:requires ("ui-pkg") :after ("core-ui-unit"))) (:name "after-runtime-fail-unit" :status :skipped :reason :blocked-by-unit :details ("runtime-fail-unit")) (:name "core-ui-unit" :status :ok :reason :executed :details (:requires ("core-pkg") :after nil)) (:name "blocked-by-runtime-package-unit" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "invalid-after-unit" :status :invalid :reason :missing-after-units :details ("ghost-unit")) (:name "independent-unit" :status :ok :reason :executed :details (:requires nil :after nil)) (:name "runtime-fail-unit" :status :failed :reason :execution :details "(error \"simulated unit failure\")") (:name "preflight-bad-unit" :status :skipped :reason :preflight :details (:env ("HYPERVISOR_MISSING_ENV") :executable ("definitely-not-installed-command"))))) (:phase :packages :payload ((:name "ui-pkg" :status :ok :reason :executed :details ("core-pkg")) (:name "runtime-fail-dependent" :status :skipped :reason :blocked-by-package :details ("runtime-fail-pkg")) (:name "core-pkg" :status :ok :reason :executed :details nil) (:name "invalid-root" :status :invalid :reason :missing-deps :details ("ghost-pkg")) (:name "runtime-fail-pkg" :status :failed :reason :execution :details (:tracker :missing-install-callback :finished-reason "completed"))))) :package-forms ((elpaca (runtime-fail-dependent :host github :repo "example/runtime-fail-dependent" :branch "main") (emacs-hypervisor-stage1-package-callback "runtime-fail-dependent")) (elpaca (runtime-fail-pkg :host github :repo "example/runtime-fail-pkg" :branch "main") (emacs-hypervisor-stage1-package-callback "runtime-fail-pkg")) (elpaca (ui-pkg :host github :repo "example/ui-pkg" :branch "main") (emacs-hypervisor-stage1-package-callback "ui-pkg")) (elpaca (core-pkg :host github :repo "example/core-pkg" :branch "main") (emacs-hypervisor-stage1-package-callback "core-pkg"))) :messages 57 :sentinel "finished
")
```

The verified harness expectations for this spike are now:

- `4` package forms queued before queue processing starts
- `1` queue-process call
- `2` package-installed callbacks observed
- `1` queue-finished callback observed
- `3` sent package tracker events
- `8` progress messages

### Verification

Verified in this milestone:

- `experiments/bin/17-run-elpaca-tracker-package-events-spike`
- `experiments/bin/16-run-elpaca-compatibility-spike`
- `experiments/bin/15-run-elpaca-callback-package-events-spike`
- `tools/analyze-runtime-modules`

### Why This Matters

This is the first milestone where the package runtime shape matches the current
architectural decision instead of only pointing toward it.

The project now has:

- a reusable Elpaca compatibility/workaround layer
- a shared Elle execution kernel that understands tracker semantics
- a Stage 1 spike that queues package forms first and processes them once
- a concrete protocol for package success facts and queue completion

The next implementation step is no longer deciding between per-package events
and tracker semantics.
That decision is made for the preferred path.

The remaining work at the end of milestone `28` was:

- swap the fake queue in spike `17` for the real Elpaca load path
- decide whether execution reports should become explicit protocol messages
- promote the tracker package path from spike code into the real startup path

## Milestone 29: Wire Real Elpaca Bootstrap Into The Tracker Spike

### Result

This milestone succeeded.

Spike `17` now runs through the real Elpaca runtime with an isolated temporary
`user-emacs-directory`, while still preserving the tracker-style
`(:installed ...)` plus `(:finished ...)` protocol chosen in the previous
milestone.

### What Changed

The key bootstrap decision for this milestone was:

- keep a session-scoped Emacs subprocess
- set `user-emacs-directory` to a temporary per-run home
- bootstrap Elpaca from a reusable helper instead of embedding ad hoc setup in
  the spike
- follow the useful bootstrap pattern from `emacs-backbone`

The reusable helper now lives in
[lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
as `emacs-hypervisor-elpaca-bootstrap`.

Its job is:

- ensure an isolated runtime `elpaca/` tree under the spike's temporary Emacs
  home
- point that runtime tree back at a shared local Elpaca manager root
- add the correct Elpaca build/source path to `load-path`
- load `elpaca-autoloads` or generate them if needed

For the real package path, spike `17` now uses local package sources already
present on this machine:

- `~/.config/emacs/elpaca/sources/dash`
- `~/.config/emacs/elpaca/sources/s`
- `~/.config/emacs/elpaca/sources/f`

That gives the spike a real Elpaca queue and real package callbacks without
depending on fresh network fetches.

### Important Fixes

Two practical fixes were needed to make the real path stable:

1. `emacs-hypervisor-stage1-process-packages` must not return the raw value of
   `elpaca-process-queues`, because that value expands to a huge Elpaca queue
   object and breaks the Hypervisor S-expression result framing.
2. the recorded Stage 1 package forms should preserve queue order, not reverse
   order, so the spike output matches the dependency plan clearly.

The Stage 1 queue processor now returns a small marker value instead of the raw
queue object, and the recorded package forms are appended in queue order.

### Observed Output

The real-Elpaca tracker spike now produces:

```text
(:ok t :shutdown :elpaca-tracker-package-events-spike-complete :session-data-replies 1 :progress 8 :plans ((:plan :phase :packages :items ((:name "dash" :deps nil) (:name "s" :deps ("dash")) (:name "f" :deps ("s")))) (:plan :phase :units :items ((:name "core-ui-unit" :requires ("dash") :after nil) (:name "ui-unit" :requires ("f") :after ("core-ui-unit")) (:name "independent-unit" :requires nil :after nil) (:name "runtime-fail-unit" :requires nil :after nil) (:name "after-runtime-fail-unit" :requires nil :after ("runtime-fail-unit"))))) :events ((:send :event :phase :packages :kind :installed :name "dash") (:send :event :phase :packages :kind :installed :name "s") (:send :event :phase :packages :kind :installed :name "f") (:send :event :phase :packages :kind :finished :reason "completed")) :callback-log ("dash" "s" "f") ...)
```

The important facts are:

- the package forms are queued in dependency order: `dash`, `s`, `f`
- the tracker emits three installed facts and one finished barrier
- the queue finishes with reason `"completed"`
- the config-unit boot policy still behaves as expected after the package phase

### Verification

Verified in this milestone:

- `experiments/bin/17-run-elpaca-tracker-package-events-spike`
- `experiments/bin/16-run-elpaca-compatibility-spike`
- `experiments/bin/15-run-elpaca-callback-package-events-spike`
- `tools/analyze-runtime-modules`

### Why This Matters

This is the first end-to-end spike where the current architectural choices all
line up at once:

- stdio transport
- session-scoped subprocess lifecycle
- S-expression wire format
- tracker-style package runtime
- real Elpaca bootstrap under an isolated Emacs home

That closes the "fake queue versus real queue" question for the preferred
startup path.

### Current Next Step

The next implementation step is now:

- promote the real Elpaca Stage 1 package path into the shared startup/runtime
  boundary
- decide whether report payloads remain `:log` + `:eval` backed or become
  explicit protocol messages
- decide how real runtime execution failures should be represented once the
  spike-local Stage 1 helpers are moved into shared runtime code

## Milestone 30: Extract A Shared Session Path

### Result

This milestone succeeded.

The project now has a first non-spike end-to-end session path:

- shared Elle backend entrypoint:
  [elle/hypervisor.lisp](/Users/randall/projects/emacs-hypervisor/elle/hypervisor.lisp)
- shared Emacs Stage 1 runtime:
  [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
- shared Emacs session entrypoint:
  [lisp/emacs-hypervisor-session.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-session.el)
- repo-local runner:
  [examples/bin/run-local-elpaca-session](/Users/randall/projects/emacs-hypervisor/examples/bin/run-local-elpaca-session)
- example config:
  [examples/local-elpaca/session.el](/Users/randall/projects/emacs-hypervisor/examples/local-elpaca/session.el)

### What Changed

The Stage 1 package/runtime code extracted from spike `17` is now shared.

The shared Stage 1 runtime is responsible for:

- loading the reusable Elpaca support module
- bootstrapping Elpaca into an isolated Emacs home
- converting package entries into Elpaca forms
- queuing package forms and processing the queue once
- emitting tracker events back to Elle
- executing config-unit bodies
- recording final reports back into Emacs through the current `:eval` path

The shared Elle backend now performs the same boot-policy and execution flow
that the spike established, but without being spike-local:

1. handshake
2. request session data
3. derive planned package and unit reports
4. install the shared Stage 1 runtime
5. execute the tracker-style package phase
6. execute units
7. record reports
8. shutdown

The shared Emacs session entrypoint now provides:

- a default boot context including repo path and Stage 1 runtime paths
- a default backend file
- a repo-local default isolated Emacs home at `.state/emacs-home/`
- a synchronous batch-friendly `emacs-hypervisor-run-session` helper

### Important Fixes

Two integration bugs showed up immediately once the shared path was exercised
outside the spike harness:

1. the async bootstrap uses global callback variables, so the shared session
   entrypoint must set `emacs-hypervisor-context-function` and
   `emacs-hypervisor-session-data-function` directly rather than binding them
   with a temporary `let`
2. the default Stage 1 Emacs home must live inside a writable root for this
   repo session, so the current default moved to `.state/emacs-home/`

Both are now fixed in the shared path.

### Verification

Verified in this milestone:

- `experiments/bin/17-run-elpaca-tracker-package-events-spike`
- `examples/bin/run-local-elpaca-session examples/local-elpaca/session.el`
- `tools/analyze-runtime-modules`

### Why This Matters

This is the first point where the repo contains a reusable program path rather
than only implementation spikes.

It is still not a polished end-user product yet, but the project now has:

- a shared backend entrypoint
- a shared Stage 1 runtime
- a shared Emacs session API
- a runnable example config that uses the shared path

That moves the project from "only proving ideas" to "a minimal working
program with rough edges."

### Current Next Step

The next implementation step is now:

- decide whether runtime reports stay `:log` + `:eval` backed or become
  explicit protocol messages
- decide how real runtime execution failures should be represented in the
  shared backend path
- reduce the remaining gap between the current batch runner and an `init.el`
  driven interactive session path

## Milestone 31: Add A Real Init.el Bootstrap Path

### Result

This milestone succeeded.

The shared backend path is now reachable through a real `init.el` style
bootstrap, not only through the batch session runner.

New files for this step:

- [lisp/emacs-hypervisor-init.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-init.el)
- [examples/local-elpaca/config.el](/Users/randall/projects/emacs-hypervisor/examples/local-elpaca/config.el)
- [examples/local-elpaca/init.el](/Users/randall/projects/emacs-hypervisor/examples/local-elpaca/init.el)
- [examples/bin/run-local-elpaca-init](/Users/randall/projects/emacs-hypervisor/examples/bin/run-local-elpaca-init)

### What Changed

The new init-facing helper does three things:

1. load the shared Hypervisor bootstrap/session files
2. reset and load a declaration-only config file
3. start the shared backend session without requiring a spike harness

The example `init.el` is now effectively:

```elisp
(load-file "/path/to/emacs-hypervisor/lisp/emacs-hypervisor-init.el")
(emacs-hypervisor-initialize
 :config-file "/path/to/local-elpaca-config.el")
```

That is still not literally zero Elisp, but it is close to the intended
bootstrap boundary:

- one trusted bootstrap file
- one declaration-only config file
- backend-controlled orchestration after startup

### Important Fix

This milestone exposed a real message-ordering bug in the shared package
tracker path.

The failure mode was:

- Emacs could send package tracker `:event` messages before the matching
  `:result` for `emacs-hypervisor-stage1-process-packages`
- the shared execution runtime previously awaited the `:result` first
- those earlier tracker events were effectively lost
- the backend then waited forever for a `:finished` event it had already
  consumed incorrectly

The fix landed in
[elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp):

- the tracker package phase now consumes the mixed `:event`/`:result` stream
  directly until it has both the queue result and the `:finished` barrier

This is a real runtime fix, not just an init example change.

### Verification

Verified in this milestone:

- `examples/bin/run-local-elpaca-init`
- `examples/bin/run-local-elpaca-session examples/local-elpaca/session.el`
- `experiments/bin/17-run-elpaca-tracker-package-events-spike`
- `tools/analyze-runtime-modules`

### Why This Matters

At this point the project has three levels of reality:

- spikes, for focused protocol and runtime experiments
- a shared batch/session runner
- a real `init.el` style bootstrap path

That means the remaining work is increasingly product work and UX work, not
basic control-plane viability.

### Current Next Step

The next implementation step is now:

- decide whether runtime reports stay `:log` + `:eval` backed or become
  explicit protocol messages
- decide how runtime execution failures should be surfaced in the shared path
- improve the interactive startup UX around the current `init.el` bootstrap

## Recommendation: Use Fiber/Supervisor or Not?

### Short Answer

Not for the MVP core execution model.

### Recommended Approach

Use a staged design:

1. MVP:
   - keep execution deterministic and mostly straightforward
   - port the `emacs-backbone` orchestration model first
   - use Elle mainly as the external runtime and graph executor
   - optionally use fibers for timeouts, async RPC, and bounded concurrency

2. Phase 2:
   - introduce `std/process` Supervisor for long-lived orchestration
   - treat package installs or config subtrees as supervised children only if the experiments prove the recovery story is real and simpler than the baseline

### Why

`emacs-backbone` already has the crucial semantics:

- dependency graph resolution
- deterministic order
- runtime prerequisite checks
- downstream failure propagation

That is enough to build a first useful Hypervisor.

Supervisors become worth it when you want:

- live reload of subtrees
- restart policies
- interactive repair loops
- long-lived daemon behavior

Those are excellent phase-2 goals, but not the right foundation milestone.

## Implementation Plan

### Phase 1: Pin the Project Shape

1. Write a short design note that defines the MVP in one page.
2. Decide what must remain compatible with `emacs-backbone`.
3. Freeze the initial user-facing contract:
   - keep `package!`
   - keep `config-unit!`
   - keep the idea of package graph first, config graph second

Deliverable:

- an MVP design section in this file or a dedicated design doc

### Phase 2: Investigate Elle Practically

1. Install or build Elle locally.
2. Run minimal experiments:
   - hello-world script
   - stdio process experiment
   - fiber spawn/join experiment
   - supervisor toy example
3. Verify the real packaging story for this project:
   - can the orchestrator be shipped as a simple executable or stable local tool
   - what "single binary" means in practice for this workflow

Deliverable:

- working local Elle toolchain
- a short experiment log added to this file

### Phase 3: Design the Runtime Boundary

1. Choose transport:
   - use stdio with S-expression messages
2. Define process roles:
   - Emacs Lisp frontend
   - Elle orchestrator
   - package-manager bridge
3. Decide whether Hypervisor is:
   - one-shot startup process
   - long-lived daemon
   - session-scoped subprocess first, daemon later

Recommendation:

- start as a session-scoped subprocess
- add daemon mode later if live reload becomes a real goal

Deliverable:

- runtime boundary spec

### Phase 4: Port the Declaration Model

1. Recreate the Emacs Lisp declaration surface.
2. Preserve current semantics from `emacs-backbone`:
   - package metadata
   - package dependencies
   - config-unit dependencies
   - env and executable prerequisites
3. Export declarations to the Elle backend.

Deliverable:

- Emacs Lisp frontend that can collect and serialize declarations

### Phase 5: Port the Graph Engine

1. Implement package dependency resolution.
2. Implement config-unit dependency resolution.
3. Detect:
   - missing nodes
   - circular dependencies
   - invalid declarations
4. Add `dry-run` output early.

Deliverable:

- Elle graph resolver with deterministic output

### Phase 6: Implement the MVP Orchestrator

1. Startup handshake between Emacs and Elle.
2. Package installation orchestration through Emacs.
3. Config-unit execution in resolved order.
4. Failure propagation:
   - failed package blocks dependent units
   - failed config unit blocks downstream config units
5. Logging and visible diagnostics.

Deliverable:

- first end-to-end boot of a small sample config

### Phase 7: Validate Against Real Config Scenarios

1. Test against a minimal sample config.
2. Test against representative multi-package dependencies.
3. Inject failures:
   - missing executable
   - missing env var
   - broken package
   - broken config unit
4. Compare behavior with `emacs-backbone`.

Deliverable:

- a behavior checklist showing parity with baseline goals

### Phase 8: Decide on Supervisor-Driven Features

Only after the MVP works:

1. prototype subtree reload
2. prototype retry/restart policy
3. prototype partial degradation
4. prototype interactive repair flow

Decision gate:

- if supervisors clearly simplify the runtime, adopt them
- if they mainly add complexity, keep the orchestrator simpler

Deliverable:

- explicit go/no-go decision for supervisor-heavy architecture

## Suggested Module Breakdown

Initial likely structure:

- `lisp/`
  - frontend macros
  - RPC client
  - package bridge

- `elle/` or `src/`
  - transport
  - declarations
  - resolver
  - executor
  - diagnostics
  - CLI entrypoint

- `docs/`
  - architecture notes
  - experiments
  - failure semantics

## Immediate Next Milestone

The next milestone should be:

1. decide whether status reports should remain `:log` + `:eval` recorded payloads or graduate into explicit report message types
2. decide how real async Elpaca completion and failure notifications should flow back from Emacs to Elle
3. keep using the local analysis and MCP workflows routinely on shared runtime files before structural Elle refactors
4. make spike `14` about explicit report messages or async package events over the shared planning/execution runtime

## Sources Used So Far

- Gemini share:
  - <https://gemini.google.com/share/e141879897cb>

- Elle repository:
  - <https://github.com/elle-lisp/elle>

- Local reference project:
  - `~/projects/emacs-backbone`

## Milestone 32: Add Init-Path Session Observability

### Result

This milestone succeeded.

The real `init.el` path now exposes enough local process state to behave like
an actual interactive program instead of an opaque subprocess launcher.

### What Changed

This milestone added:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
  - process state, process sentinel, last-event tracking, and process-buffer helpers
- [lisp/emacs-hypervisor-session.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-session.el)
  - richer session summary plus `emacs-hypervisor-show-status` and `emacs-hypervisor-describe-session`
- [lisp/emacs-hypervisor-init.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-init.el)
  - startup announcement and abnormal-exit handling for the real init path

### Why This Matters

The remaining gap is not "can it boot?" anymore.
The remaining gap is now mostly operator UX and protocol semantics.

The next questions are still:

- protocol/report representation
- runtime failure representation
- deeper interactive diagnostics
- broader config validation against real-world scenarios

## Milestone 33: Promote Reports To Protocol Messages

### Result

This milestone succeeded.

The shared backend path no longer uses `:eval` to ask Emacs to persist final
report payloads. Reports are now first-class protocol messages.

### Decision

The project now treats reports as wire-level facts:

- Elle derives planned and executed reports
- Elle emits them over stdio as S-expressions
- Emacs stores the received `:report` messages in the trusted Stage 0 session state
- `:log` remains a human-oriented view, not the source of truth

### Message Shape

The shared path now emits:

- `(:report :stage :planned :phase :packages :items (...))`
- `(:report :stage :planned :phase :units :items (...))`
- `(:report :stage :executed :phase :packages :items (...))`
- `(:report :stage :executed :phase :units :items (...))`

This gives one explicit place to inspect:

- planned readiness
- validation/preflight skips
- runtime execution failures
- final executed outcomes

### Failure Representation

Failures are now represented inside report items instead of being inferred
from warning logs or from side-effectful Emacs-local storage.

The current rule is:

- `:status` carries `:ok`, `:skipped`, `:failed`, or `:invalid`
- `:reason` explains the class of outcome
- `:details` carries the structured payload or error text for that reason

Examples already present in the shared path:

- dependency blocking
- preflight failure
- missing references
- runtime execution error

### Implementation Notes

The main shared-path changes landed in:

- [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp)
  - added `send-report`
- [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
  - added explicit report-message emission helper
- [elle/hypervisor.lisp](/Users/randall/projects/emacs-hypervisor/elle/hypervisor.lisp)
  - emits planned and executed `:report` messages and no longer round-trips report persistence through `:eval`
- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
  - stores incoming `:report` messages in trusted Stage 0 state
- [lisp/emacs-hypervisor-session.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-session.el)
  - prefers protocol report messages in session summaries, with legacy fallback for older spike paths

### Verification

Verified in this milestone:

- `examples/bin/run-local-elpaca-session examples/local-elpaca/session.el`
- `examples/bin/run-local-elpaca-init`
- `experiments/bin/17-run-elpaca-tracker-package-events-spike`
- `tools/analyze-runtime-modules`

### Next Step

The next implementation step is now:

- normalize failure `:details` payloads so they are more uniform across preflight, runtime, and tracker-derived failures
- improve interactive inspection over the current report/progress/log state

## Milestone 34: Normalize Failure Detail Payloads

### Result

This milestone succeeded.

Failure `:details` payloads in the shared runtime are now more uniform and more
machine-readable.

### Decision

The shared path now uses reason-shaped plist payloads for failures instead of a
mix of plain lists, raw strings, and ad hoc tracker tuples.

The current shapes are:

- missing references:
  - `(:missing (...))`
- dependency blockers:
  - `(:blockers (...))`
- cycles:
  - `(:members (...))`
- preflight:
  - `(:env (...) :executable (...))`
- runtime eval failures:
  - `(:source :eval :error "...")`
- package-event failures:
  - `(:source :package-event :error "...")`
- tracker/queue failures:
  - `(:source :tracker ... )`
  - `(:source :queue :error "...")`

### Why This Matters

This reduces protocol ambiguity in two places:

- the report stream is easier to consume programmatically
- warning logs now mirror structured failure payloads instead of inventing a
  separate shape

It also removes the special-case tracker detail shape that previously looked
different from normal execution failures.

### Implementation Notes

The main normalization changes landed in:

- [elle/graph.lisp](/Users/randall/projects/emacs-hypervisor/elle/graph.lisp)
  - added shared helper constructors like `missing-details`, `blocker-details`, `cycle-details`, and `preflight-details`
- [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
  - now emits normalized blocking and preflight details
- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - now emits source-tagged execution error details for eval, package-event, tracker, and queue failures
- [experiments/lisp/17-emacs-hypervisor-elpaca-tracker-package-events-spike.el](/Users/randall/projects/emacs-hypervisor/experiments/lisp/17-emacs-hypervisor-elpaca-tracker-package-events-spike.el)
  - updated expected report payloads for the normalized shapes

### Verification

Verified in this milestone:

- `examples/bin/run-local-elpaca-session examples/local-elpaca/session.el`
- `examples/bin/run-local-elpaca-init`
- `experiments/bin/17-run-elpaca-tracker-package-events-spike`
- `tools/analyze-runtime-modules`

### Next Step

The next implementation step is now:

- build better interactive inspection over the current `:report`, `:progress`, `:log`, and process-state data
- decide whether that inspection remains Emacs-local over the message stream or gains explicit protocol queries

## Milestone 35: Adopt `sexp-rpc` For Shared Sessions

### Result

This milestone succeeded.

The shared Emacs <-> Elle path now speaks a real `sexp-rpc` envelope instead
of ad hoc top-level protocol forms.

### Decision

The project now uses a small Lisp-native RPC/event protocol:

- top-level envelope: `(:rpc ...)`
- protocol name: `:sexp-rpc`
- version: `1`
- kinds:
  - `:request`
  - `:response`
  - `:event`

This keeps the JSON-RPC-like request/response/event discipline while
preserving S-expression payloads on the wire.

The current shared-path operations are:

- requests:
  - `:hello`
  - `:boot-context`
  - `:session-data`
  - `:eval`
- events:
  - `:plan`
  - `:progress`
  - `:log`
  - `:report`
  - `:shutdown`
  - `:package`

### Why This Matters

This gives the project a protocol layer that is:

- more explicit than ad hoc message tags
- still native to Lisp on both sides
- easier to evolve without losing request correlation or async event semantics

It also removes the need to treat every top-level message tag as a special
case in the Emacs bootstrap.

### Implementation Notes

The main protocol migration landed in:

- [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp)
  - defines the `sexp-rpc` envelope, request/response/event helpers, and
    envelope readers
- [elle/hypervisor.lisp](/Users/randall/projects/emacs-hypervisor/elle/hypervisor.lisp)
  - migrated the shared handshake and Stage 1 install path to request/response
    calls
- [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)
  - emits `:plan` events
- [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
  - emits `:log` and `:report` events
- [elle/preflight.lisp](/Users/randall/projects/emacs-hypervisor/elle/preflight.lisp)
  - probes executables through `:eval` requests
- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - migrated eval requests and tracker event handling to the new envelope
- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
  - parses `sexp-rpc` requests/events in the trusted Stage 0 kernel
- [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
  - emits Stage 1 package tracker callbacks as `:package` events
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
  - documents the actual protocol contract now used by the shared session path

Two additional transport/runtime fixes were required while proving the live
path:

- Emacs outbound protocol serialization now escapes strings explicitly instead
  of relying on `prin1-to-string`
- the process filter now restores the process buffer after config code switches
  to another buffer during streamed execution

### Verification

Verified in this milestone:

- `examples/bin/run-local-elpaca-init`
- `emacs --batch -Q --load /Users/randall/projects/emacs-hypervisor/examples/live-demo/init.el --eval "(let ((result (progn (emacs-hypervisor-wait-for-completion 30) (emacs-hypervisor-session-summary)))) (princ (format \"%S\n\" result)))"`
- `tools/analyze-runtime-modules`
- interactive proof with:
  - `/Applications/Emacs.app/Contents/MacOS/Emacs -nw --chdir /Users/randall/projects/emacs-hypervisor --init-directory=/Users/randall/projects/emacs-hypervisor/examples/live-demo/home/ --no-site-file --no-site-lisp --no-splash --no-x-resources`

The interactive proof reached the repo-local `*Hypervisor Demo*` buffer and
completed the Hypervisor session successfully.

### Next Step

The next implementation step is now:

- build better interactive inspection over current `sexp-rpc` state and event history
- decide whether inspection should remain Emacs-local or add explicit protocol queries
- decide whether newline framing is enough long-term or whether `sexp-rpc` should gain explicit length-prefixed framing

## Milestone 36: Make Stage 0 `sexp-rpc`-Only

### Result

This milestone succeeded.

The shared Emacs Stage 0 bootstrap no longer accepts legacy ad hoc top-level
protocol messages. It now parses only `sexp-rpc` envelopes.

### Decision

The project should have one live protocol on the shared path.

That means the trusted bootstrap now treats non-`sexp-rpc` traffic as an
error instead of carrying compatibility handlers for older spike-era message
forms like `:hello`, `:request-session-data`, `:eval`, `:plan`, or
`:shutdown` at the top level.

### Why This Matters

This removes dead protocol branches from the trusted kernel and makes the
current architecture easier to reason about:

- Stage 0 has one wire contract
- shared runtime code no longer appears backward-compatible when it is not
- future protocol work can evolve `sexp-rpc` directly instead of maintaining
  two semantics in the same bootstrap

### Implementation Notes

The cleanup landed in:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
  - removed legacy ad hoc dispatch paths and now errors on non-`sexp-rpc`
    messages
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
  - documents that the shared Stage 0 bootstrap is now `sexp-rpc`-only

Historical numbered spikes remain in the repo as snapshots of the project’s
evolution, but they are no longer treated as compatibility targets for the
shared bootstrap/runtime path.

### Verification

Verified in this milestone:

- `examples/bin/run-local-elpaca-init`
- `emacs --batch -Q --load /Users/randall/projects/emacs-hypervisor/examples/live-demo/init.el --eval "(let ((result (progn (emacs-hypervisor-wait-for-completion 30) (emacs-hypervisor-session-summary)))) (princ (format \"%S\n\" result)))"`

### Next Step

The next implementation step is now:

- build better interactive inspection over current `sexp-rpc` state and event history
- decide whether inspection should remain Emacs-local or add explicit protocol queries
- decide whether newline framing is enough long-term or whether `sexp-rpc` should gain explicit length-prefixed framing

## Milestone 37: Separate Shared Runtime From Historical Spikes

### Result

This milestone succeeded.

The repository layout now separates real shared code from numbered
experiments.

### Decision

Shared Elle modules should live directly under `elle/`.

Historical spike code should live under `experiments/` so it remains available
for reference and targeted reruns without being mixed into the current runtime
surface.

### Repository Shape

The layout is now:

- shared Elle modules in `elle/*.lisp`
- shared Emacs runtime and session files in `lisp/emacs-hypervisor-*.el`
- shared tooling in `bin/`
- historical Elle spikes in `experiments/elle/`
- historical Elisp spikes in `experiments/lisp/`
- historical spike runners in `experiments/bin/`

### Implementation Notes

The refactor included:

- moving shared runtime helpers from `elle/runtime/` into `elle/`
- moving numbered Elle spikes out of `elle/spikes/` into `experiments/elle/`
- moving numbered Elisp spike files into `experiments/lisp/`
- moving numbered spike runner scripts into `experiments/bin/`
- updating shared includes, analysis tooling, runner paths, and repo docs to
  reflect the new structure

`AGENTS.md` now also treats `experiments/` as historical spike space and
points Elle analysis guidance at the shared `elle/` modules.

### Compatibility Note

This refactor does not change the earlier protocol-history decision:

- the shared Stage 0 bootstrap remains `sexp-rpc`-only
- self-contained historical spikes can still run from `experiments/`
- historical spikes that depended on the old shared ad hoc bootstrap are now
  snapshots rather than compatibility targets

### Verification

Verified in this milestone:

- `tools/analyze-runtime-modules`
- `examples/bin/run-local-elpaca-init`
- `experiments/bin/01-run-hello-eval-result-spike`

### Next Step

The next implementation step is still:

- build better interactive inspection over current `sexp-rpc` state and event history
- decide whether inspection should remain Emacs-local or add explicit protocol queries
- decide whether newline framing is enough long-term or whether `sexp-rpc` should gain explicit length-prefixed framing

## Milestone 38: Repo-Home Isolated Bootstrap

### Result

This milestone succeeded.

The repo bootstrap now treats the project directory as the real Emacs home
instead of routing Stage 1 through `.state/emacs-home/` or through the shared
`~/.config/emacs/elpaca/` cache.

With:

- `emacs --init-directory=/Users/randall/projects/emacs-hypervisor`

the effective runtime model is now:

- `user-emacs-directory` is the repo root
- Stage 1 home is the repo root
- Elpaca manager root defaults to repo-root `elpaca/`

### Decision

The project should be tested as an actual isolated Emacs home.

That means:

- no hidden `.state/emacs-home/` default
- no shared-manager Elpaca fallback
- no mirror/symlink workaround from `~/.config/emacs/elpaca/`
- split-package handling should reuse the same mechanism already proven in
  Emacs Backbone

### Implementation Notes

This milestone changed:

- [init.el](/Users/randall/projects/emacs-hypervisor/init.el)
  - repo-root bootstrap now always uses the repo root as
    `:stage1-user-emacs-directory`
- [lisp/emacs-hypervisor-session.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-session.el)
  - removed the `.state/emacs-home/` default
  - Stage 1 home now defaults to `user-emacs-directory`
  - Elpaca manager root now defaults to local `elpaca/` under that home
- [lisp/emacs-hypervisor-init.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-init.el)
  - removed the `.state/emacs-home/` fallback
- [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
  - removed the shared-manager mirror/symlink bootstrap path
  - added direct local Elpaca bootstrap into the repo-local manager root
  - removed the stale external symlink cleanup step from normal bootstrap
  - enabled the full Backbone-style split-package compatibility set:
    - `elpaca-recipe-functions`
    - `elpaca--shared-source-dir`
    - `elpaca-source`
    - `elpaca-git--clone`

### Verification

Verified in this milestone:

- `emacs --batch --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 120) (princ (format \"%s\n\" user-emacs-directory)))"`
- `emacs --batch --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 120) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

### Next Step

The next implementation step is:

- continue debugging the first fully local package queue until the isolated
  repo-home path becomes the normal interactive test path
- keep using Backbone’s split-package compatibility behavior where Elpaca still
  races on shared-source repos

## Milestone 39: Import Backbone Config Into Repo-Root Hypervisor Bootstrap

### Result

This milestone succeeded.

The repo-root [config.el](/Users/randall/projects/emacs-hypervisor/config.el)
can now load a copied Backbone-era configuration through the Hypervisor
bootstrap path without collapsing on the first runtime incompatibility.

The current batch bootstrap reaches a completed session with package execution
working and config-unit execution succeeding except for units intentionally
gated by missing external executables on this machine.

### Decision

The compatibility work was split across two layers:

- repo-root `config.el` gets a minimal Backbone shim only for local symbols and
  support files that are not yet migrated into this repository
- Stage 1 runtime absorbs general Backbone-to-Hypervisor compatibility so the
  imported config does not need one-off recipe or loading hacks per package

This keeps the root config usable as the experiment surface while pushing
reusable semantics into the runtime where they belong.

### Implementation Notes

This milestone added:

- a small Backbone compatibility shim at the top of
  [config.el](/Users/randall/projects/emacs-hypervisor/config.el)
  - `emacs-backbone-user-directory`
  - `emacs-backbone-buffer-name`
  - guarded loading for `config/my-utils.el`
  - guarded loading for `config/avy-can-do-anything.el`
  - guarded loading for local `clis/*.json` tool definitions
- Stage 1 package recipe normalization in
  [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
  - implicit GitHub host for Backbone-style remote `:repo`
  - correct handling for local filesystem repos in `:repo` or `:local`
- shared-source mirroring fixes in
  [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
  - prefer the already-populated manager root checkout over stale generated
    `.state` source directories
  - this fixed the early `mixed-pitch` queue collapse
- config-unit feature loading in
  [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
  - Stage 1 now `require`s declared `:requires` features before evaluating a
    unit body
  - malformed quoted `:requires` payloads are normalized from the local unit
    registry so current wire output remains usable
- Elle execution call sites in
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - pass unit `:requires` through to Stage 1 execution

### Verification

Verified in this milestone:

- `emacs --batch -Q --load /Users/randall/projects/emacs-hypervisor/init.el`
- `emacs --batch -Q --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(let ((result (progn (emacs-hypervisor-wait-for-completion 60) (emacs-hypervisor-session-summary)))) (princ (format \"%S\n\" result)))"`

The last verified run completed with only expected preflight skips for missing
external executables on this machine, including:

- `go-grip`
- `ruff`
- `rumdl`
- `prettier`
- `terminal-notifier`
- `pytest`

### Next Step

The next implementation step should be:

- run a real interactive `emacs` session from the repo-root bootstrap path and
  inspect the UI/runtime behavior directly
- decide whether to keep local fallback normalization for quoted `:requires` or
  clean up the Elle-side wire representation
- improve reporting so completed sessions can summarize successful units and
  preflight skips more compactly

## Milestone 40: Establish Repo-Root `init.el` And `config.el`

### Result

This milestone succeeded.

The repository now has a canonical top-level Emacs bootstrap at `init.el`
and a canonical default declaration file at `config.el`.

### Decision

The real default config path should be repo-root `config.el`, not an example
file under `examples/`.

That means:

- `init.el` at repo root is the canonical bootstrap entrypoint
- `config.el` at repo root is the canonical default declaration file
- `lisp/emacs-hypervisor-init.el` remains the reusable bootstrap library
- `examples/` stays example/demo space rather than the default runtime path

### Implementation Notes

This milestone added:

- [init.el](/Users/randall/projects/emacs-hypervisor/init.el)
  - thin repo-root wrapper around
    [lisp/emacs-hypervisor-init.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-init.el)
- [config.el](/Users/randall/projects/emacs-hypervisor/config.el)
  - current default declarations for the repo-root bootstrap path

The initial root `config.el` uses the same declaration set as the current
local Elpaca working path so the canonical bootstrap remains executable while
the real config surface is still evolving.

### Verification

Verified in this milestone:

- `emacs --batch -Q --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(let ((result (progn (emacs-hypervisor-wait-for-completion 30) (emacs-hypervisor-session-summary)))) (princ (format \"%S\n\" result)))"`

### Next Step

The next implementation step is still:

- build better interactive inspection over current `sexp-rpc` state and event history
- decide whether inspection should remain Emacs-local or add explicit protocol queries
- decide whether newline framing is enough long-term or whether `sexp-rpc` should gain explicit length-prefixed framing

## Milestone 41: Cleanup Repo Layout Around Root Bootstrap

### Result

This milestone succeeded.

The repository layout was cleaned up around the canonical repo-root bootstrap.

Top-level `bin/` is now reserved for future shipped binaries, developer
tooling lives under `tools/`, and the repository now treats repo-root
[init.el](/Users/randall/projects/emacs-hypervisor/init.el) and
[config.el](/Users/randall/projects/emacs-hypervisor/config.el) as the only
live bootstrap path.

### Decision

This cleanup collapsed several repo-organization refactors into one outcome:

- `bin/` should stay reserved for future shipped binary entrypoints
- `tools/` should hold developer analysis programs and MCP/tooling wrappers
- examples are no longer needed as separate runtime entrypoints
- experiment and iteration should happen by editing the canonical root
  `config.el`

### Implementation Notes

This milestone:

- moved local analysis and MCP wrappers out of `bin/` into `tools/`
  - `tools/analyze-runtime-modules`
  - `tools/start-elle-mcp`
- reserved top-level `bin/` for future shipped binaries
  - [bin/README.md](/Users/randall/projects/emacs-hypervisor/bin/README.md)
- removed the `examples/` directory
- removed the current-layout description of `examples/` from
  [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
- updated [bin/README.md](/Users/randall/projects/emacs-hypervisor/bin/README.md)
  so `bin/` is described relative to the root bootstrap path

Historical log entries that mention `examples/` are preserved as history for
earlier milestones, but they no longer describe the current repo layout.

### Verification

Verified in this milestone:

- `tools/analyze-runtime-modules`
- `emacs --batch -Q --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(let ((result (progn (emacs-hypervisor-wait-for-completion 30) (emacs-hypervisor-session-summary)))) (princ (format \"%S\n\" result)))"`

### Next Step

The next implementation step is still:

- build better interactive inspection over current `sexp-rpc` state and event history
- decide whether inspection should remain Emacs-local or add explicit protocol queries
- decide whether newline framing is enough long-term or whether `sexp-rpc` should gain explicit length-prefixed framing

## Milestone 42: Architecture Reset Toward A Minimal Trusted Kernel

### Result

This milestone succeeded.

The project direction is now explicitly reset toward the original Lisp-to-Lisp
advantage instead of continuing to expand the resident Emacs runtime.

### Decision

The reset direction is:

- the repo itself is the real Emacs home during testing
- Emacs should stay a minimal trusted kernel plus declaration/export surface
- Elle should own orchestration, policy, and runtime code generation
- `sexp-rpc` stays
- the async process filter and incremental S-expression parsing stay
- large persistent helper layers in Emacs are transitional and should shrink

This clarifies an important distinction:

- the async non-blocking process filter is still the correct bootstrap pattern
- the mistake was not the filter
- the mistake was keeping too much long-lived execution and package policy in
  Emacs after the transport was working

### Implementation Notes

This milestone updated the repo documentation so it matches the reset target:

- [ARCHITECTURE-RESET.md](/Users/randall/projects/emacs-hypervisor/ARCHITECTURE-RESET.md)
  - defines the reset target
  - now includes a concrete keep/shrink/move/delete matrix for current
    Emacs-side files
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
  - marks the heavier Emacs runtime files as transitional
  - points future work at shrinking the kernel boundary rather than expanding
    diagnostics around the transitional runtime
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
  - clarifies that newline framing still requires incremental chunk handling
  - marks the current larger installed runtime as a temporary shared-path shape,
    not the desired end state

### Verification

Verified in this milestone by reviewing the current shared bootstrap/runtime
files against the reset target:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
- [lisp/emacs-hypervisor-init.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-init.el)
- [lisp/emacs-hypervisor-session.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-session.el)
- [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
- [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)

### Next Step

The next implementation step should be:

- move package-install instruction generation out of resident Emacs runtime code
  and into Elle
- treat
  [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
  as a decomposition target, not a foundation
- keep only the trusted async kernel and the declaration/export surface on the
  Emacs side

## Milestone 43: Move Package Order Generation Into Elle

### Result

This milestone succeeded.

The shared package path no longer sends raw package entries into Emacs for
Elpaca-order construction.

Instead:

- Elle now derives the Elpaca order data from package entries
- Emacs only normalizes local-path details and queues the resulting order

### Decision

This is the first concrete shrink step after the architecture reset.

The important boundary is now:

- Elle owns package-order generation policy
- Emacs owns only the small execution-surface detail of local path expansion
  and Elpaca queue submission

That is a better fit for the target architecture than keeping
`package-entry -> Elpaca order` translation in
[lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el).

### Implementation Notes

This milestone changed:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - added Elle-side `package-entry->elpaca-order`
  - package execution paths now call
    `emacs-hypervisor-stage1-start-package-order`
    instead of sending whole package entries into Emacs
- [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
  - removed resident Emacs helpers that converted package entries into Elpaca
    orders/forms
  - added a smaller
    `emacs-hypervisor-stage1-normalize-package-order`
    helper for local path expansion
  - added
    `emacs-hypervisor-stage1-start-package-order`
    as the reduced queueing surface

### Verification

Verified in this milestone:

- Elle execution module still loads successfully:
  - `printf '(include-file "elle/protocol.lisp") ...' | /tmp/elle/target/release/elle -`
- Emacs-side order normalization and queue form shape:
  - `emacs --batch -Q --eval "(progn (defmacro elpaca (&rest args) \`(quote ,args)) ... )"`

Observed results:

- local repo path `./tmp/demo` normalized to an absolute path
- queue call returned `:queued`
- queued form shape is:
  - `(elpaca (demo :repo "/.../tmp/demo" ...) (emacs-hypervisor-stage1-package-callback "demo"))`

### Next Step

The next implementation step should be:

- move more of the remaining package-phase runtime bridge out of
  [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
  and into Elle-generated forms
- decide whether the package tracker callbacks remain a tiny trusted Emacs
  bridge or also become Elle-installed transient code

## Milestone 44: Replace Shared Runtime Install With Elle-Emitted Session Helpers

### Result

This milestone succeeded.

The shared startup path no longer loads
[lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
to install the package/unit helper layer.

Instead:

- Elle now emits the session-local Elisp helpers directly
- the backend installs those helpers with a single `:eval`
- [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
  remains the temporary Elpaca bridge

### Decision

This is the next concrete step toward the intended Lisp-to-Lisp architecture.

The important shift is:

- the current shared backend no longer depends on a durable resident runtime
  file for package queueing and unit execution helpers
- Elle now owns that startup-time helper generation directly

That is closer to the target model where Emacs keeps only the trusted kernel
and Elle streams the rest as data/code.

### Implementation Notes

This milestone changed:

- [elle/runtime-forms.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms.lisp)
  - new Elle module that emits the transient Emacs helper forms needed for:
    - package tracker callbacks
    - package queue submission
    - package queue processing
    - unit execution
    - minimal session-local debug state
- [elle/hypervisor.lisp](/Users/randall/projects/emacs-hypervisor/elle/hypervisor.lisp)
  - now includes the runtime-forms module
  - now installs emitted session helpers instead of loading the shared runtime
    file

The old runtime file remains in the repo as transitional code, but it is no
longer on the main shared startup path.

### Verification

Verified in this milestone:

- Elle runtime-form module load:
  - `printf '(include-file "elle/runtime-forms.lisp") ...' | /tmp/elle/target/release/elle -`
- shared batch init path:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result from the shared batch init path:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`
- real Elpaca bootstrap activity still occurred
- the shared path no longer needed the old runtime file load to complete

### Next Step

The next implementation step should be:

- shrink
  [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
  so only the Elpaca-specific trusted bridge remains
- decide which current tracker/debug helpers should stay as tiny Emacs-local
  bridge code and which should also become Elle-emitted transient forms

## Milestone 45: Delete The Transitional Shared Runtime File

### Result

This milestone succeeded.

[lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
has been deleted.

### Decision

The file had already been removed from the active shared startup path.

Keeping it in the repo was only preserving dead transitional structure and
making the architecture look larger than it really is. The live model is now:

- trusted Emacs kernel in `lisp/emacs-hypervisor-bootstrap.el`
- declaration/export surface in `lisp/emacs-hypervisor-declarations.el`
- transient helper generation in `elle/runtime-forms.lisp`
- remaining Elpaca bridge in `lisp/emacs-hypervisor-elpaca.el`

### Implementation Notes

This milestone changed:

- deleted
  [lisp/emacs-hypervisor-runtime.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-runtime.el)
- updated
  [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
  to remove the file from the current layout and next-step description
- updated
  [ARCHITECTURE-RESET.md](/Users/randall/projects/emacs-hypervisor/ARCHITECTURE-RESET.md)
  so the runtime-form path is the active model

Historical milestone entries still mention the deleted file where that was the
true state at the time. Those references are preserved as history.

### Verification

Verified in this milestone:

- no live shared-code references remain to:
  - `lisp/emacs-hypervisor-runtime.el`
  - `emacs-hypervisor-stage1-install-runtime`
- active helper entrypoints still live in:
  - [elle/runtime-forms.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms.lisp)
  - [elle/hypervisor.lisp](/Users/randall/projects/emacs-hypervisor/elle/hypervisor.lisp)

### Next Step

The next implementation step should be:

- keep shrinking
  [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
  until only the true Elpaca-specific trusted bridge remains

## Milestone 46: Move Elpaca Setup Policy Out Of The Elisp Bridge

### Result

This milestone succeeded.

The remaining Elpaca bridge is smaller.

Session setup policy that did not need to live in
[lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
was moved into emitted session forms.

### Decision

The boundary is now cleaner:

- the Elisp bridge keeps lower-level Elpaca bootstrap and compatibility helper
  functions
- Elle-emitted session forms own the bootstrap recipe and compatibility
  activation wiring for the current session

That matches the project direction better than keeping those setup decisions in
the resident bridge file.

### Implementation Notes

This milestone changed:

- [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
  - removed the resident bootstrap recipe constant
  - removed the compatibility activation wrapper
  - `emacs-hypervisor-elpaca-bootstrap` now accepts the bootstrap order as an
    argument
- [elle/runtime-forms.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms.lisp)
  - now supplies the bootstrap recipe explicitly
  - now installs the Elpaca compatibility hooks/advice directly for the session
    with a session-local guard

### Verification

Verified in this milestone:

- no live shared-code references remain to:
  - `emacs-hypervisor-elpaca-enable-compatibility`
  - `emacs-hypervisor-elpaca-bootstrap-order`
- Elle runtime-forms module still loads:
  - `printf '(include-file "elle/runtime-forms.lisp") ...' | /tmp/elle/target/release/elle -`
- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- keep runtime bridge and execution helpers in
  [elle/runtime-forms](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms)
  instead of resident Emacs files
- keep shrinking any session-side policy that still lives outside the trusted
  kernel

## Milestone 47: Move The Remaining Elpaca Bridge Into Elle Runtime Forms

### Result

This milestone succeeded.

The active runtime no longer depends on a resident
[lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
file.

The Elpaca bridge now lives in emitted Elle runtime forms alongside the rest
of the transient session helpers.

### Decision

This is closer to the intended architecture:

- trusted Emacs keeps the bootstrap kernel, declaration/export surface, and
  session entry wiring
- Elle owns transient runtime code generation, including the Elpaca bridge
  needed by the current session
- the repo no longer carries a separate resident Elpaca helper layer just to
  be loaded and immediately delegated back into session-local code

### Implementation Notes

This milestone changed:

- [elle/runtime-forms/elpaca-bridge.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/elpaca-bridge.lisp)
  - new emitted module containing:
    - local Elpaca bootstrap
    - split-package `:main` inference
    - shared-source compatibility advice helpers
- [elle/runtime-forms/base.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/base.lisp)
  - reduced to shared prelude and session-state helpers
- [elle/runtime-forms/package-runtime.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/package-runtime.lisp)
  - fixed emitted Elisp boolean literal to use `t`
- [elle/runtime-forms.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms.lisp)
  - now coordinates the split runtime-form directory and installs the emitted
    Elpaca bridge directly
- `lisp/emacs-hypervisor-elpaca.el`
  - removed from the active codebase

### Verification

Verified in this milestone:

- emitted runtime forms compile again:
  - `printf '(include-file "runtime-forms.lisp") ...' | /tmp/elle/target/release/elle -`
- emitted session helper form now contains valid Emacs boolean syntax:
  - `defvar emacs-hypervisor-stage1-open-debug-buffers-on-timeout t`
- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- keep shrinking any remaining session/runtime policy outside
  [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
- keep the split
  [elle/runtime-forms](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms)
  layout as the home for transient Emacs-side runtime code

## Milestone 48: Simplify The Emitted Elpaca Bootstrap

### Result

This milestone succeeded.

The active runtime no longer threads `stage1-user-emacs-directory`,
`elpaca-manager-root`, or `bootstrap-order` through the bootstrap path.

The emitted Elpaca bridge now assumes the repo is the real Emacs home and
boots Elpaca directly under `user-emacs-directory/elpaca`.

### Decision

This is the simpler model:

- `init.el` makes the repo the active `user-emacs-directory`
- the Emacs session exports only lightweight boot context
- the emitted Elpaca bridge owns its fixed bootstrap recipe internally
- no extra manager-root abstraction is carried through Emacs or Elle

### Implementation Notes

This milestone changed:

- [init.el](/Users/randall/projects/emacs-hypervisor/init.el)
  - now sets `user-emacs-directory` to the repo root before initialization
- [lisp/emacs-hypervisor-init.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-init.el)
  - removed `stage1-user-emacs-directory` and `elpaca-manager-root` arguments
- [lisp/emacs-hypervisor-session.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-session.el)
  - removed the session-side manager-root and stage1-home customization layer
- [elle/hypervisor.lisp](/Users/randall/projects/emacs-hypervisor/elle/hypervisor.lisp)
  - no longer expects those fields from `:boot-context`
- [elle/runtime-forms.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms.lisp)
  - no longer threads bootstrap arguments into emitted helper installation
- [elle/runtime-forms/package-runtime.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/package-runtime.lisp)
  - now calls `(emacs-hypervisor-elpaca-bootstrap)` directly
- [elle/runtime-forms/elpaca-bridge.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/elpaca-bridge.lisp)
  - now uses a fixed internal bootstrap recipe and a repo-local `elpaca/` root

### Verification

Verified in this milestone:

- no active code references remain to:
  - `stage1-user-emacs-directory`
  - `elpaca-manager-root`
  - `bootstrap-order`
- emitted runtime forms still compile:
  - `printf '(include-file "runtime-forms.lisp") ...' | /tmp/elle/target/release/elle -`
- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- keep simplifying emitted runtime helpers that still expose unnecessary
  orchestration vocabulary
- keep the repo-root-home assumption explicit and avoid re-introducing
  indirection unless a real requirement appears

## Milestone 49: Rename The Live Runtime Surface Away From `stage1`

### Result

This milestone succeeded.

The active emitted runtime no longer uses `stage1` naming for its package and
unit helper surface.

The live vocabulary is now `runtime-*`, which matches the actual role of these
helpers better.

### Decision

The `stage1` name was leftover implementation history, not a useful runtime
concept.

For the active codebase:

- Elpaca bridge helpers keep `emacs-hypervisor-elpaca-*`
- transient session/runtime helpers use `emacs-hypervisor-runtime-*`
- historical spike references in the log remain untouched

### Implementation Notes

This milestone changed:

- [elle/runtime-forms/base.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/base.lisp)
  - renamed emitted session state vars such as:
    - `emacs-hypervisor-runtime-package-forms`
    - `emacs-hypervisor-runtime-package-callback-log`
    - `emacs-hypervisor-runtime-queue-process-count`
- [elle/runtime-forms/package-runtime.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/package-runtime.lisp)
  - renamed package/runtime vars and helpers from `emacs-hypervisor-stage1-*`
    to `emacs-hypervisor-runtime-*`
- [elle/runtime-forms/unit-runtime.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/unit-runtime.lisp)
  - renamed emitted unit helpers to `emacs-hypervisor-runtime-*`
- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - updated Elle-side eval calls to target the renamed runtime helpers
- [lisp/emacs-hypervisor-session.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-session.el)
  - updated session summary inspection to read the renamed runtime state var

### Verification

Verified in this milestone:

- no active code references remain to `emacs-hypervisor-stage1-*`
- emitted runtime forms still compile:
  - `printf '(include-file "runtime-forms.lisp") ...' | /tmp/elle/target/release/elle -`
- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- keep shrinking or deleting any remaining dead execution paths that still
  describe obsolete package-install helpers
- continue simplifying the emitted Elpaca/runtime bridge without reintroducing
  earlier stage abstractions

## Milestone 50: Remove Dead Package Execution Paths

### Result

This milestone succeeded.

The active execution module now exposes only the tracker-based package path
that the live backend actually uses.

Obsolete direct and async package execution branches were removed from the
active codebase.

### Decision

The live backend already commits to the tracker flow:

- queue package orders
- run `elpaca-process-queues`
- observe `:installed` and `:finished` protocol events
- derive final package reports after queue completion

Keeping older direct package execution branches was only increasing surface
area and leaving references to non-existent helpers in the active runtime.

### Implementation Notes

This milestone changed:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - removed unused direct package execution helpers
  - removed unused async package execution helpers
  - removed exports for dead package execution entrypoints
  - kept `execute-package-entry-plan-tracker` as the live package path
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
  - updated the current MCP impact example to point at
    `execute-package-entry-plan-tracker`

### Verification

Verified in this milestone:

- no active code references remain to:
  - `emacs-hypervisor-runtime-install-package`
  - `execute-packages`
  - `execute-package-plan`
  - `execute-package-entry-plan`
  - `execute-package-entry-plan-async`
- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- keep simplifying the remaining runtime/Elpaca bridge code around the actual
  tracker-based package path
- review whether the current timeout/debug helpers should stay emitted as-is or
  be reduced further

## Milestone 51: Collapse `emacs-hypervisor-init.el` Into `init.el`

### Result

This milestone succeeded.

The repo no longer needs a separate
`lisp/emacs-hypervisor-init.el` helper file.

The repo-home startup glue now lives directly in
[init.el](/Users/randall/projects/emacs-hypervisor/init.el).

### Decision

This matches the current design rule better:

- keep only the Elisp that is required before the Elle session is started
- avoid preserving extra library layers when they only wrap repo-local startup
  glue
- keep the trusted kernel separate, but let `init.el` own its own boot path

`lisp/emacs-hypervisor-bootstrap.el` remains the kernel.
`init.el` is now just the repo-home entrypoint that wires that kernel up.

### Implementation Notes

This milestone changed:

- [init.el](/Users/randall/projects/emacs-hypervisor/init.el)
  - now loads the remaining active Elisp modules directly
  - now resets declarations, loads `config.el`, installs the process sentinel,
    and starts the session directly
- `lisp/emacs-hypervisor-init.el`
  - removed from the active codebase
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
  - updated the active file layout and next-step notes
- [ARCHITECTURE-RESET.md](/Users/randall/projects/emacs-hypervisor/ARCHITECTURE-RESET.md)
  - updated the reset notes to reflect that init-path glue now lives in
    `init.el`

### Verification

Verified in this milestone:

- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- examine whether the remaining emitted timeout/debug helpers are still worth
  keeping as part of the runtime surface

## Milestone 52: Finalize Direct Elpaca Attempt Logging

### Result

This milestone succeeded.

The direct package queue path no longer records a malformed wrapper-era form in
its execution events.

### Decision

After removing `emacs-hypervisor-runtime-start-package-order` from the active
runtime design, one leftover artifact remained in the Elle execution path:

- package attempt events still stored `:form '(unquote queue-form)`

That was not the real package order datum and made the runtime log look more
complicated than the actual architecture.

For the live runtime, the useful package attempt event is simply:

- phase
- event kind
- package name

The full `elpaca` wrapper and recipe/order data are execution mechanics and can
be reconstructed from the plan when needed.

### Implementation Notes

This milestone changed:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - removed wrapper-era `:form` logging from package attempt events
  - kept package attempt events minimal with phase/event/name only
  - kept direct emitted `(elpaca ...)` queueing unchanged

### Verification

Verified in this milestone:

- active runtime code no longer references
  `emacs-hypervisor-runtime-start-package-order`
- package attempt events no longer include malformed quoted queue metadata

### Next Step

The next implementation step should be:

- continue iterating real package/config compatibility issues from
  [config.el](/Users/randall/projects/emacs-hypervisor/config.el), starting
  with the next real package failure exposed by the live runtime

## Milestone 53: Add Real Repo-Home Environment Injection

### Result

This milestone succeeded.

Hypervisor now has real environment injection for Emacs runtime usage, not just
Elle-side env export for planning/preflight.

### Decision

The current repo-home architecture needs environment variables inside Emacs
itself for:

- top-level config code evaluated from [config.el](/Users/randall/projects/emacs-hypervisor/config.el)
- subprocesses started by Emacs
- executable lookup through `exec-path`
- shell-dependent packages and commands

Exporting a tiny env subset to Elle was not enough.

The correct minimal design is:

- trusted Emacs boot code loads a repo-local env file before `config.el`
- Emacs runtime state is updated in place
- Elle still receives env values for reporting and preflight, but from the
  injected runtime state

The loader should follow Backbone's already-verified implementation closely,
instead of introducing a Hypervisor-specific variant.

### Implementation Notes

This milestone changed:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
  - added `emacs-hypervisor-load-envvars-file`
  - kept it close to Backbone's verified env loader contract
  - applies injected vars to `process-environment`
  - rebuilds `exec-path` from injected `PATH`
  - updates `shell-file-name`
- [init.el](/Users/randall/projects/emacs-hypervisor/init.el)
  - now loads repo-root `env` before `config.el`
  - respects `EMACS_HYPERVISOR_ENV_FILE` as an override path
- [lisp/emacs-hypervisor-declarations.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-declarations.el)
  - now exports declared `config-unit! :env` names in addition to session env
    defaults
  - keeps Elle preflight aligned with the real injected Emacs environment
- [bin/hypervisor-env](/Users/randall/projects/emacs-hypervisor/bin/hypervisor-env)
  - added a user-facing generator for the Lisp env snapshot file
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
  - documented the repo-home env file contract and generator tool

### Verification

Verified in this milestone:

- Hypervisor loads a temporary env file before `config.el`
- injected variables become visible through `getenv`
- injected `PATH` is reflected in `exec-path`
- declared `:env` names such as `JIRA_API_TOKEN` are exported from the injected
  Emacs environment

### Next Step

The next implementation step should be:

- decide whether to keep the repo-root `env` file as the permanent default
  contract, or add a separate user-facing setup note for generating it from the
  login shell on first use

## Milestone 54: Buffer Unmatched `sexp-rpc` Messages In Elle

### Result

This milestone succeeded.

The shared Elle protocol helpers no longer drop unrelated valid `sexp-rpc`
messages while waiting for a specific response or event topic.

### Decision

The current session model uses one async stdio stream for:

- request/response traffic
- package tracker events
- runtime progress/report events

That means a waiter for one message kind must not consume and lose another
message that arrives first.

The protocol layer now keeps a small in-memory pending-message mailbox so
unmatched messages remain available for the next waiter.

### Implementation Notes

This milestone changed:

- [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp)
  - split raw stream reads from mailbox-aware message waits
  - added a pending-message mailbox inside the shared protocol module
  - changed `await-response` and `await-event-topic` to buffer unmatched
    messages instead of recursively dropping them
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
  - documented the mailbox-based matching semantics for the shared stream

### Verification

Verified in this milestone:

- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- tighten the package timeout semantics so timeout completion cannot race ahead
  of the real Elpaca queue in confusing ways

## Milestone 55: Make Package Timeout A Terminal Failure, Not Synthetic Completion

### Result

This milestone succeeded.

The emitted package runtime no longer translates package timeout into a fake
`packages finished` completion event.

Timeout is now its own terminal package event, and Elle derives package failure
from that timeout instead of pretending the Elpaca queue completed normally.

### Decision

Backbone used timeout as a way to proceed with configuration after stalled
package activity.

For Hypervisor's current architecture, that behavior is too confusing because
the backend can derive final package reports and move on while Elpaca may still
be active in Emacs.

The simpler and more honest contract is:

- `:finished` means the queue actually finished
- `:timeout` means the package phase failed to complete in time
- timeout blocks later unit execution instead of acting like a synthetic queue
  completion

### Implementation Notes

This milestone changed:

- [elle/runtime-forms/package-runtime.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/package-runtime.lisp)
  - added an explicit `:timeout` package event
  - stopped sending synthetic `:finished "timeout"` events
  - stops accepting later package callback reports after timeout
- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - treats `:timeout` as a terminal tracker event
  - derives `(:source :tracker :error :timeout)` for timed out package phases
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
  - documented the explicit `:timeout` package event and failure shape

### Verification

Verified in this milestone:

- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- decide whether package timeout should stay as an emitted runtime policy at all
  or move to a user-configurable/session-level policy layer

## Milestone 56: Port Backbone's Elpaca Installer Version Declaration

### Result

This milestone succeeded.

The emitted Hypervisor Elpaca bootstrap now declares
`elpaca-installer-version` the same way Backbone does.

### Decision

The repo-home Hypervisor bootstrap should carry the same Elpaca installer
compatibility declaration that Backbone already relies on, rather than tolerate
startup warnings from Elpaca's installer version check.

### Implementation Notes

This milestone changed:

- [elle/runtime-forms/elpaca-bridge.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/elpaca-bridge.lisp)
  - added `(defvar elpaca-installer-version 0.12)` to the emitted Elpaca
    bootstrap forms

### Verification

Verified in this milestone:

- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- verify the interactive repo-home startup path stays warning-free while
  continuing to simplify the emitted Elpaca bridge

## Milestone 57: Fix Malformed Elpaca Order Emission

### Result

This milestone succeeded.

The Elle execution path now emits the package order form correctly when asking
Emacs to queue an Elpaca package.

### Decision

The live runtime was reaching `:hypervisor-session-complete` while leaving most
config units blocked because package queueing itself was failing.

The root cause was a malformed quoted order form in the Elle-side eval request,
which caused Emacs to fail package queueing with errors like:

- `(:source :queue :error "(invalid-function 1)")`

That had to be fixed before any further UX or runtime work.

### Implementation Notes

This milestone changed:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - fixed the emitted `emacs-hypervisor-runtime-start-package-order` eval form
    from malformed quoted syntax to `(quote ,order)`

### Verification

Verified in this milestone:

- rerun the shared batch init path and inspect package/unit reports after the
  queue form fix

### Next Step

The next implementation step should be:

- verify that queued packages now reach real installed/executed reports and
  then iterate on any remaining package or unit-level failures from the user
  config

## Milestone 58: Add A Live Emacs Log Buffer For Hypervisor Sessions

### Result

This milestone succeeded.

The trusted Emacs bootstrap now exposes a dedicated interactive log buffer for
Hypervisor sessions.

### Decision

The hidden process buffer is useful for transport internals, but it is not the
right surface for watching a live session.

The bootstrap now keeps a separate log buffer so the user can inspect:

- backend process start
- process lifecycle events
- sent protocol messages
- received protocol messages

without depending on batch output or the hidden stream buffer.

### Implementation Notes

This milestone changed:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
  - added `*emacs-hypervisor-log*`
  - added `emacs-hypervisor-open-log-buffer`
  - logs process start and process sentinel events
  - logs protocol send/receive traffic into the interactive log buffer

### Verification

Verified in this milestone:

- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 60) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- use the live log buffer to inspect the current package and unit execution
  path in interactive Emacs and continue fixing the remaining queue/runtime
  issues in the imported config

## Milestone 59: Emit Bare Symbols For Recipe-Less Elpaca Packages

### Result

This milestone succeeded.

Recipe-less packages are no longer emitted as one-element lists when Hypervisor
queues Elpaca orders.

### Decision

The live runtime was still failing package processing even after the queue-form
quoting fix.

Inspection of the recorded package attempt forms showed queue requests like:

- `(elpaca (mixed-pitch) ...)`
- `(elpaca (jinx) ...)`

For plain archive packages, Hypervisor should emit a bare package symbol
instead:

- `(elpaca mixed-pitch ...)`

### Implementation Notes

This milestone changed:

- [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
  - changed `package-entry->elpaca-order` so empty-recipe packages emit the
    package symbol directly instead of `(name)`

### Verification

Verified in this milestone:

- rerun the shared batch init path and inspect the package attempt forms and
  reports after changing recipe-less package emission

### Next Step

The next implementation step should be:

- verify which packages now install successfully and then fix the remaining
  package/unit failures from the imported config one by one

## Milestone 60: Simplify The Emitted Package Runtime

### Result

This milestone succeeded.

The emitted package runtime is now centered on the actual tracker flow and no
longer carries the extra debug/instrumentation layer that was not feeding the
live control path.

### Decision

The live package path only needs:

- queue package orders
- normalize local package recipes
- observe installed/finished events
- guard the queue with a simple timeout

It does not need to keep extra emitted state for:

- queued package form snapshots
- package callback logs
- queue process counters
- timeout visibility hooks
- detailed Elpaca timeout logging infrastructure

Those details were increasing the emitted surface without materially helping the
current architecture.

### Implementation Notes

This milestone changed:

- [elle/runtime-forms/base.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/base.lisp)
  - removed emitted runtime state for:
    - `emacs-hypervisor-runtime-package-forms`
    - `emacs-hypervisor-runtime-package-callback-log`
    - `emacs-hypervisor-runtime-queue-process-count`
- [elle/runtime-forms/package-runtime.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms/package-runtime.lisp)
  - removed extra timeout/debug policy vars
  - removed detailed timeout inspection/logging helpers
  - kept the minimal timeout gate and tracker event callbacks
  - stopped storing queued package forms in emitted session state

### Verification

Verified in this milestone:

- emitted runtime forms still compile:
  - `printf '(include-file "runtime-forms.lisp") ...' | /tmp/elle/target/release/elle -`
- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- review whether the remaining timeout itself should stay emitted or move into
  an even smaller protocol/runtime contract

## Milestone 61: Collapse `emacs-hypervisor-session.el` Into `init.el`

### Result

This milestone succeeded.

The repo no longer needs a separate
`lisp/emacs-hypervisor-session.el` helper file.

The active resident Elisp surface is now:

- [lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-bootstrap.el)
- [lisp/emacs-hypervisor-declarations.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-declarations.el)
- [init.el](/Users/randall/projects/emacs-hypervisor/init.el)

### Decision

This is closer to the intended boundary:

- the trusted kernel stays in `bootstrap.el`
- the declaration/export surface stays in `declarations.el`
- repo-home startup glue lives directly in `init.el`
- extra session wrapper layers are not kept around unless they provide a real
  boundary the runtime still needs

### Implementation Notes

This milestone changed:

- [init.el](/Users/randall/projects/emacs-hypervisor/init.el)
  - now sets the boot context function directly
  - now sets the session-data export hook directly
  - now starts the Elle subprocess directly through the kernel
- `lisp/emacs-hypervisor-session.el`
  - removed from the active codebase
- [AGENTS.md](/Users/randall/projects/emacs-hypervisor/AGENTS.md)
  - updated the active file layout and next-step notes
- [ARCHITECTURE-RESET.md](/Users/randall/projects/emacs-hypervisor/ARCHITECTURE-RESET.md)
  - updated the reset notes to reflect the smaller resident Elisp surface

### Verification

Verified in this milestone:

- shared batch init path still completes:
  - `emacs --batch -Q --init-directory=/Users/randall/projects/emacs-hypervisor --load /Users/randall/projects/emacs-hypervisor/init.el --eval "(progn (emacs-hypervisor-wait-for-completion 30) (princ (format \"%S\n\" (emacs-hypervisor-status))))"`

Observed result:

- session completed successfully with
  `:shutdown :hypervisor-session-complete`

### Next Step

The next implementation step should be:

- examine whether the remaining emitted timeout/debug helpers are still worth
  keeping as part of the runtime surface
