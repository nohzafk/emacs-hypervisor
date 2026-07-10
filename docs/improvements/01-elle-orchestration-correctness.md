# WP1 — Elle Orchestration Layer Correctness

Scope: `elle/preflight.lisp`, `elle/execution.lisp`, `elle/hypervisor.lisp`,
`elle/graph.lisp`, `elle/boot-policy.lisp`,
`host/emacs-kernel/emacs-hypervisor-events.el`,
`elle/runtime-forms/emacs-hypervisor-report.el`,
`tests/elle/hypervisor-runtime.lisp`,
`tests/elisp/emacs-hypervisor-bootstrap-test.el`.

Elle syntax reference: `.elle/stdlib.lisp`, `.elle/prelude.lisp`, and existing
module code. Elle modules are constructed as `(defn <name>-module [deps...] ... {:exports ...})`.

## 1.1 Preflight only probes the first declared executable (BUG)

`elle/preflight.lisp:37-42` — `probe-executables` takes
`(first (graph:entry-field unit :executable))` per unit, but `:executable` is
a list (`elle/runtime-forms/emacs-hypervisor-declarations.el:96-97` documents
"Optional list of executables required by the unit"). The Emacs-side reload
policy checks the whole list (`emacs-hypervisor-reload-policy.el:36-39`), so a
unit declaring `:executable ("git" "rg")` with `rg` missing passes boot
preflight but is skipped on hot reload — inconsistent and wrong.

**Required change**

- `executable-probe-report` (`preflight.lisp:34-35`) currently maps one probe
  to `:missing (list binary)` or `()`. Rework the pipeline so each unit probes
  *every* binary in its `:executable` list and collects all missing binaries
  into `:missing`.
- Suggested shape:
  ```lisp
  (defn missing-executables [unit path-dirs]
    (filter (fn [binary] (nil? (executable-path binary path-dirs)))
            (graph:entry-field unit :executable)))

  (defn probe-executables [units next-id env]
    (let [path-dirs (path-entries env)]
      {:next-id next-id
       :reports (map (fn [unit]
                       {:name (graph:entry-name unit)
                        :missing (missing-executables unit path-dirs)})
                     units)}))
  ```
  Keep `probe-executable`/`executable-probe-report` only if still referenced;
  otherwise delete them. Keep the exported map keys unchanged
  (`:env-missing-for-unit`, `:executable-missing-for-unit`,
  `:probe-executables`, `:units-with-executables`).

**Test** — extend the "0b" executable-preflight test in
`tests/elle/hypervisor-runtime.lisp` (around lines 266-276): add a unit with
`:executable` of two entries where only the second is missing from the fake
PATH; assert the missing one appears in `:missing`. Also assert a unit with
both missing reports both.

## 1.2 Real package failures never gate unit execution (BUG)

`elle/execution.lisp:147-163` — `next-unit-plan-report` receives
`package-reports` (the merged **post-execution** package reports, threaded from
`elle/hypervisor.lisp:267-271`) and `executed-unit-reports`, but reads neither.
Only the static `planned-report` (computed by `boot-policy` before any install
ran) decides whether a unit executes. Consequence: a package that fails at
install time (network/build error) does not skip its dependent units — they run
anyway and fail opaquely inside Emacs, instead of a clean
`:skipped :blocked-by-package` report.

**Required change**

In `next-unit-plan-report`, when `planned-status` is `:ok`, additionally check
the unit's `:requires` (via `graph:entry-field entry :requires`) against
`package-reports`: for each required name that corresponds to a declared
package report, if that report's actual `:status` is not `:ok`, short-circuit
and return a blocked report instead of sending the eval request. Reuse the
existing blocked-report constructor in `elle/graph.lisp` (`blocked-report` /
the same shape `boot-policy:next-unit-report` produces for
`known-report-blockers`), with reason `:blocked-by-package` and the failing
package names as blockers. Mirror the lookup style of
`boot-policy.lisp`'s `known-report-blockers` logic. Only gate on names that
actually appear in `package-reports` — `:requires` entries that are plain Emacs
features (not declared packages) must not be affected (see test
"unit :requires means feature, not package" at
`tests/elle/hypervisor-runtime.lisp:354-362`).

If `executed-unit-reports` remains unused after this change, remove that
parameter (adjust `execute-unit-plan` and its `collect-report-state` callback
accordingly) — do not leave dead plumbing.

**Test** — new case in `tests/elle/hypervisor-runtime.lisp` next to test "4.
unit execution": build `package-reports` containing a `:failed` package `p`,
a unit `u1` with `:requires (p)` and `:ok` planned-report, and a unit `u2`
requiring nothing. Assert `u1` is `:skipped` with the package named as blocker
and no eval request is sent for it, and `u2` still executes.

## 1.3 Startup-complete is sent on the `:shutdown` topic (BUG)

`elle/hypervisor.lisp:46-47` sends startup-complete via
`(protocol:send-event :shutdown payload)`; `hypervisor.lisp:288-289` calls it
with `(:reason :startup-complete :status :ready)` and then the process *keeps
running* to serve extension calls. On the Emacs side,
`emacs-hypervisor-events--handle-shutdown`
(`host/emacs-kernel/emacs-hypervisor-events.el:133-145`) treats any `:shutdown`
message as session completion: sets `emacs-hypervisor--completed t`. The
sentinel (`host/emacs-kernel/emacs-hypervisor-bootstrap.el:47-54`) then never
flips state to `:failed` if the Elle process later crashes during the
extension-actor phase — post-startup crashes are silently reported as a
completed session.

**Required change**

- Add a distinct topic, `:session-ready`, for startup-complete:
  `emacs-hypervisor-send-startup-complete` in `hypervisor.lisp` sends
  `(protocol:send-event :session-ready payload)`.
- In `emacs-hypervisor-events.el`, add a `:session-ready` handler that records
  readiness (reuse whatever user-visible behavior `--handle-shutdown` performed
  for the `:startup-complete` reason — e.g. state `:completed`/report refresh —
  **without** preventing the sentinel from marking a later abnormal exit as
  `:failed`). The cleanest split: `:session-ready` sets a new
  `emacs-hypervisor--ready` flag plus any UI notification; the sentinel treats
  "process died and no `:shutdown` was received" as `:failed` even when ready.
  Study `emacs-hypervisor-events--handlers` (`events.el:23-31`) and
  `emacs-hypervisor--session-active-p` / session-state helpers in
  `host/emacs-kernel/emacs-hypervisor-session-state.el` before changing state
  semantics; existing ERT tests around session state
  (`emacs-hypervisor-session-active-p-allows-completed-live-process` etc.) must
  be updated deliberately, not just patched to pass.
- Keep `:shutdown` exclusively for actual termination
  (`emacs-hypervisor-send-shutdown`, which calls `sys/exit`), including the
  check-mode and config-load-failure paths.

**Test** — ERT: simulate `:session-ready` event then a process death; assert
state ends `:failed`. Simulate `:shutdown` event then process death; assert
state stays completed. Update existing shutdown-topic tests for the new topic.

## 1.4 Unconditional debug instrumentation in the report path

`elle/hypervisor.lisp:79-129` — the `emacs-hypervisor-debug-*` family
(`debug-value-summary`, `debug-wire-string`, `debug-report-items`,
`debug-send-report`, `debug-package-items`) `eprintln`s raw wire sexps on
every normal session (call sites at lines 256-260, 275, 279). There is no way
to send a report without paying this cost.

**Required change** — gate all debug output behind an env var
(`EMACS_HYPERVISOR_DEBUG`, non-empty ⇒ enabled) checked once at module setup
(`sys/env` is available — see `execution.lisp:86-89` usage). When disabled,
`debug-send-report` must degrade to a plain `protocol:send-report` call with
zero summary/serialization work.

## 1.5 Dead validation branch: `:missing-required-packages`

`elle/boot-policy.lisp:70-78` always passes literal `()` for
`missing-requires`, so the `:missing-required-packages` branch in
`graph:invalid-unit-report` (`elle/graph.lisp:147-153`) can never fire, and the
matching rendering support in
`elle/runtime-forms/emacs-hypervisor-report.el:153,216` is unreachable. This is
leftover from when `:requires` meant "declared package name".

**Required change** — remove the `missing-requires` parameter and the
`:missing-required-packages` branch from `graph.lisp`, the `()` plumbing in
`boot-policy.lisp`, and the dead rendering arms in `emacs-hypervisor-report.el`
(lines 153 and 216 — verify by grep for `missing-required-packages`). Run both
test suites; no behavior may change.

## 1.6 Env package-list values are not trimmed

`elle/execution.lisp:86-89` — `env-package-list-member?` splits
`EMACS_HYPERVISOR_UPGRADE_PACKAGES` / `EMACS_HYPERVISOR_REBUILD_PACKAGES` on
`","` without trimming, so `"magit, transient"` fails to match `transient`.

**Required change** — trim whitespace from each element after split (check
`.elle/stdlib.lisp` for `string/trim`; if absent, strip leading/trailing spaces
manually) and drop empty strings. Add a test in
`tests/elle/hypervisor-runtime.lisp` if the function is reachable from the test
harness; otherwise cover via the existing execution tests' env setup.

## 1.7 Elle test-coverage gaps

Add to `tests/elle/hypervisor-runtime.lisp` (follow the existing
`(defn check [...]` / numbered-section style):

1. **Genuine cycle**: two units mutually `:after` each other; assert both get
   `:status :invalid :reason :cycle` via `graph:cycle-names` /
   `derive-unit-reports`. (Currently only missing-reference and duplicate
   cases are tested; `graph.lisp:72-93` cycle machinery has no direct test.)
2. **`benchmark.lisp`**: include the real module (it is currently stubbed at
   test lines 81-83). Test `strip-metric-fields` (nested maps/lists), and
   `eval-payload` in enabled vs disabled mode.
3. **`runtime-forms.lisp` module order**: test that
   `install-config-surface-form` / `install-session-helpers-form` list modules
   in an order consistent with the manifest
   (`elle/runtime-forms/modules.manifest`) — a static order assertion that
   catches accidental reordering before it becomes a live `require` failure.

## Acceptance criteria

- `./.elle/target/release/elle tests/elle/hypervisor-runtime.lisp` passes with
  the new tests present.
- Full ERT suite passes (see docs/improvements/README.md for the invocation
  with `native-comp-enable-subr-trampolines` disabled).
- `grep -rn "missing-required-packages" elle/` returns nothing.
- With `EMACS_HYPERVISOR_DEBUG` unset, a normal session emits no debug
  `eprintln` output.
