# Spec: Package Lockfile, Check Subcommand, Org Source Mapping

Status: implemented, with deviations noted below.

Implementation notes:

- **Part 1** is implemented as specified. Lock visibility flows through the
  extended `:package` event payloads (`:rev`, `:locked`); dedicated startup
  report rendering of the revision column is follow-up work.
- **Part 2** is implemented with one deviation: duplicate package/unit name
  detection landed in the Emacs-side lint pass (as a `:severity :error`
  finding, which fails the check) rather than in Elle's boot policy, so it
  required no graph changes. Moving it into boot policy so normal startup
  also reports duplicates remains open.
- **Part 3** is implemented for declaration entries, effect records, and
  diff identity. Report-buffer jump buttons and threading `:source` into
  Elle-side planned/executed reports are follow-up work.

Three independent features, ordered by suggested implementation order. Each
part stands alone; none depends on another, though Part 2 (`check`) and
Part 3 (source mapping) compound: lint findings and planning failures become
dramatically more useful when they cite `config.org` locations.

**Attention Conservation Notice.** Design document for contributors. Nothing
here is user-facing yet. For current behavior see the
[README](../README.md).

---

# Part 1 — Package Lockfile, Upgrade, and Prune

## Motivation

Hypervisor's pitch is determinism, but the package layer is its least
deterministic part:

- A bare `(package! magit)` or `:branch`-tracking declaration installs
  whatever HEAD is at clone time. The same `config.org` on a second machine,
  or after `just emacs-home-e2e-reset`, produces different package states.
  Nothing records what was actually installed.
- There is no upgrade flow. The closest operation is
  `emacs-hypervisor-rebuild-package`, which is a clean reinstall aimed at
  local `:build` development, not a deliberate "move this package forward".
- A package deleted from `config.org` stays installed in
  `hypervisor/packages/` and `hypervisor/sources/` forever, keeps loading on
  activation, and is invisible to every report.

## Goals

1. A fresh install from `config.org` + `hypervisor.lock` reproduces the exact
   package revisions of the machine that wrote the lock.
2. Moving a package forward is a deliberate, named operation with a visible
   before/after revision delta.
3. Undeclared-but-installed packages are visible in the startup report and
   removable with one command.

## Non-Goals

- No dependency solver. `:deps` ordering and the
  `package-compute-transaction` bypass in the bridge are unchanged.
- No archive mirroring or content-addressed store.
- No automatic background upgrades. Upgrade is always user-initiated.
- No lock entries for transitive archive dependencies pulled in by
  `Package-Requires` (recorded as informational only; see Prune closure).

## The Lockfile

### Location

`<hypervisor-config-dir>/hypervisor.lock` — next to `config.org`, in the
user-owned directory, so it travels with the dotfiles repo. It is data the
user commits, not a managed bootstrap artifact, so it does not belong in the
generated Emacs home.

### Format

Printed S-expression, schema-versioned, one entry per declared package,
sorted by `:name` for stable VCS diffs:

```elisp
(:schema-version 1
 :entries
 ((:name "consult"
   :kind :archive
   :archive "melpa"
   :version (2 6))
  (:name "magit"
   :kind :vc
   :url "https://github.com/magit/magit"
   :branch nil
   :rev "0aa26864e3fc4e6949db9b7d94c7d5f10486b0e3"
   :locked-at "2026-06-10T08:00:00Z")))
```

| Field | Meaning |
|---|---|
| `:kind` | `:vc` for package-vc bridge installs, `:archive` for `package-install` entries |
| `:url` | Resolved clone URL at lock time (`emacs-hypervisor-bridge--build-url`) |
| `:branch` | Declared `:branch`, recorded for drift detection |
| `:rev` | `git rev-parse HEAD` of the staging clone after checkout/adopt |
| `:version` | `package-desc-version` for archive installs |
| `:locked-at` | ISO-8601 write timestamp, informational |

The file is rewritten atomically (write to temp file in the same directory,
then `rename-file`) after any operation that changes installed state.

### Who owns it

The Emacs-side bridge. It owns the staging clones and is the only component
that can observe the concrete revision that was installed. Elle keeps
planning ownership and gains visibility through the existing `:package`
event payloads, extended with a `:rev` field:

```lisp
(:phase :packages :kind :installed :name "magit"
 :rev "0aa2686..." :locked :hit)   ;; :hit | :miss | :pinned
```

`:locked` reports how the revision was chosen, and the startup report
renders it, so "this machine restored locked revisions" is visible at boot.

## Resolution Precedence

When installing a VC package, the bridge resolves the target revision in
this order:

1. **Declared `:ref` or `:tag`** — the declaration is the source of intent.
   Install it and update the lock entry to match. If the lock disagreed, log
   a `:log` event noting the override.
2. **Lock entry `:rev`** — clone, then `git checkout <rev>` (the existing
   `emacs-hypervisor-bridge--checkout-ref` path). A locked revision forces
   the non-shallow clone shape, exactly as a declared `:ref` does today in
   `emacs-hypervisor-bridge--clone-command`.
3. **Neither** — current behavior: shallow clone of `:branch` or the default
   branch HEAD. After adopt, write the resulting revision to the lock.

Archive packages mirror this with `:version`: a lock hit installs that exact
version when the archive still serves it, otherwise installs latest and
records the drift in the report (archives garbage-collect old versions; the
lock cannot fight that, only surface it).

`:local` packages get a lock entry with `:rev` of the local checkout for
informational purposes only — local paths are inherently unlocked and the
entry never drives resolution.

### Backfill

On bridge activation, installed packages with no lock entry get one
backfilled (`git rev-parse HEAD` in the staging clone is cheap). This makes
adopting the lockfile on an existing home a no-op rather than a migration.

## Upgrade

### Surface

| Surface | Behavior |
|---|---|
| `M-x emacs-hypervisor-upgrade-package` | Completion over declared packages, upgrades one |
| `M-x emacs-hypervisor-upgrade-all-packages` | Upgrades every declared package |
| `EMACS_HYPERVISOR_UPGRADE_PACKAGES=name1,name2` | Upgrade listed packages during startup; `all` upgrades everything |

The env var is handled exactly where `EMACS_HYPERVISOR_REBUILD_PACKAGES` is
today: `package-run-form` in `elle/execution.lisp` selects an upgrade form
instead of the plain run form.

### Semantics

Upgrade means: ignore the lock entry, honor the declaration.

- Declared `:ref`/`:tag`: upgrade is a no-op; report "pinned by
  declaration, skipped".
- Declared `:branch` or bare: re-resolve that branch/default HEAD.
- Archive: `package-refresh-contents`, then install latest.

Mechanically, VC upgrade reuses `emacs-hypervisor-bridge-rebuild`
end-to-end (unload features, delete staging + package dirs, purge eln cache,
re-clone, `:submodules`/`:build`, adopt) — the only difference from rebuild
is that the lock entry is rewritten afterward and the report includes the
revision delta:

```text
[Hypervisor] Upgraded magit: 0aa2686 -> 4f81c9d
```

`emacs-hypervisor-last-upgrade-report` keeps the structured result
(`(:name NAME :previous-rev R1 :current-rev R2 :status :ok|:failed ...)`)
for the report buffer.

## Prune

### Orphan definition

A package directory under `hypervisor/packages/` (or a staging clone under
`hypervisor/sources/`) whose name is **not in the keep set**:

```text
keep = declared package names
     ∪ transitive Package-Requires closure of installed declared packages
```

The closure matters: archive dependencies that `package-install` pulled in
to satisfy `Package-Requires` live in the same `package-user-dir` and are
not declared in `config.org`. Pruning them would break declared packages.
The closure is computed from `package-alist` requirement metadata at prune
time. Built-in packages are excluded by construction (they are not under
`package-user-dir`).

### Surface

- **Startup report**: orphans appear as a warning-level summary line
  ("3 installed packages are not declared: foo, bar, baz") sourced from a
  bridge scan during activation. No automatic deletion, ever.
- **`M-x emacs-hypervisor-prune-packages`**: lists orphans, asks for
  confirmation, then for each runs the removal steps already proven by
  `emacs-hypervisor-bridge-rebuild` (unload features, `package-delete`,
  delete staging + package dirs, purge eln cache, clear
  `package-vc-selected-packages`) minus the reinstall, and drops the lock
  entry.

## Code Anchors

| Change | Location |
|---|---|
| Lock read/write, atomic rewrite, backfill | new `elle/runtime-forms/emacs-hypervisor-package-lock.el` |
| Revision resolution precedence, `git rev-parse` capture | `emacs-hypervisor-package-bridge.el` (`--clone-command`, `--checkout-ref`, `--adopt`, `--archive-install`) |
| Upgrade commands + env var plumbing | `emacs-hypervisor-package-runtime.el`, `elle/execution.lisp` (`package-run-form`) |
| Orphan scan + prune command | `emacs-hypervisor-package-bridge.el`, `emacs-hypervisor-package-runtime.el` |
| `:rev` / `:locked` in package events, report rendering | `emacs-hypervisor-package-runtime.el`, `emacs-hypervisor-report.el` |
| Manifest entry for the new runtime module | `elle/runtime-forms/modules.manifest` |

## Test Expectations

- Installing a VC package writes a lock entry whose `:rev` matches the
  staging clone HEAD.
- A clean home + lockfile install checks out the locked revision, not
  branch HEAD.
- A declared `:ref` that disagrees with the lock wins, and the lock is
  rewritten to match.
- Upgrade rewrites the lock entry and reports the revision delta; a
  `:ref`-pinned package reports skipped.
- The prune keep-set includes the `Package-Requires` closure of declared
  packages; a dependency-only package is never listed as an orphan.
- Lock rewrite is sorted by name and atomic (temp + rename).
- Backfill adds entries for installed-but-unlocked packages without
  touching installed state.

## What This Is Not

No solver, no global cache, no auto-update, no lock entries driving
`:local` development paths, no attempt to lock Emacs or archive index
state.

---

# Part 2 — `check` Subcommand

## Motivation

Today the fastest way to find out whether a config edit is structurally
broken is to restart Emacs. The graph, preflight, and planning machinery
that produces the answer already exists — it just only runs inside a full
interactive startup. Exposing it as a batch subcommand turns "know your
config is correct in five seconds" into "know before you even restart", and
makes an Emacs config CI-able: a dotfiles repo can run
`emacs-hypervisor check` on every push.

## The One Invariant

> `check` must reach its verdict by running the **same backend code path**
> as a real startup — handshake, config load, session-data export,
> preflight, boot policy, planning — and stopping before execution.

It is a plan-only session, not a reimplementation. If `check` says the
config is valid, startup planning will agree, by construction.

## CLI Surface

```bash
emacs-hypervisor check [--home DIR] [--emacs PATH] [--format human|sexp] [--strict]
```

| Exit code | Meaning |
|---|---|
| `0` | No findings (lint warnings allowed unless `--strict`) |
| `1` | At least one invalid/failed planned item, or any finding under `--strict` |
| `2` | Harness error: Emacs not found, home not initialized, tangle/load crash of the harness itself |

`--home` defaults like every other subcommand. `--emacs` overrides `PATH`
lookup of the Emacs binary.

## Mechanism

The normal topology is Emacs-launches-Hypervisor. `check` adds one CLI
entry that inverts the spawn but preserves the topology underneath:

1. **CLI** (`host/src/main.rs`): resolve the Emacs binary, then spawn
   `emacs --batch --init-directory HOME` with `EMACS_HYPERVISOR_CHECK=1`
   and `EMACS_HYPERVISOR_BIN` pointed at the current executable.
2. **Kernel**: boots exactly as today (batch is already a supported `:ui`),
   launches `emacs-hypervisor serve` as usual, and includes `:check t` in
   the `:boot-context` response when the env var is set.
3. **Elle backend** (`elle/hypervisor.lisp`): runs the existing pipeline —
   install config surface, tangle/load config, request session-data, derive
   package reports, probe executables, derive unit reports, derive plans —
   then, when `:check` is set, **skips**
   `execute-package-entry-plan-tracker` and `execute-unit-plan`, emits the
   planned reports plus lint findings, and shuts down with
   `(:reason :check-complete :status :ok|:failed)`.
4. **Kernel, check mode**: renders the verdict to stdout (`--format`) and
   calls `kill-emacs` with the appropriate code.
5. **CLI**: propagates the Emacs exit code.

No new protocol ops. One new boot-context field, one branch in the backend,
one rendering path in the kernel.

## Checks Performed

| Check | Where it lives | Status |
|---|---|---|
| Tangle failure (`config.org` → tangled file) | config-load failure path | exists |
| Config load error (macro errors, missing `:config`, reader failures) | config-load failure path | exists |
| Cycles in package/unit graphs | `elle/graph.lisp` | exists |
| Missing `:deps` / `:requires` / `:after` references | `elle/boot-policy.lisp` | exists |
| Unset `:env` variables | `elle/preflight.lisp` | exists |
| Missing `:executable` binaries | `elle/preflight.lisp` (probe) | exists |
| Duplicate package / unit names | `elle/boot-policy.lisp` | **new** (also benefits normal startup) |
| Structural lint over unit bodies | new Emacs-side pass | **new** |

Bodies are never executed. Runtime errors inside `:config` remain a startup
concern.

### Structural lint

The lint pass is the table already specified in
[effect-system.md § Structural Linting](effect-system.md#structural-linting):
pattern matches over exported unit bodies, conservative, warn-only. It runs
Emacs-side at session-data export time when `:check` is set, and findings
travel in the session-data payload as a `:lint` field:

```elisp
(:lint ((:unit "editing" :rule :eval-after-load
         :message "prefer with-eval-after-load"
         :form (eval-after-load ...))))
```

Each finding carries the unit name and, once Part 3 lands, an org source
location. Lint findings do not affect the exit code unless `--strict`.

## Output

Human format groups by severity:

```text
emacs-hypervisor check: 2 problems, 1 warning

INVALID  unit project-hooks    missing :after unit: magit-ui
INVALID  package transient     cycle: transient -> magit -> transient
WARN     unit editing          (eval-after-load ...): prefer with-eval-after-load

config: ~/.config/emacs-hypervisor/config.org
exit: 1
```

`--format sexp` prints a single toplevel plist (`:status`, `:planned-packages`,
`:planned-units`, `:lint`) for tooling.

## Non-Goals

- No body execution, no package installation, no network. A future
  `--network` flag could verify archive resolvability; explicitly out of
  scope here.
- Not a replacement for the startup report — `check` answers "is the
  structure valid", not "did execution succeed".

## Code Anchors

| Change | Location |
|---|---|
| `check` CLI command, Emacs spawn, exit propagation | `host/src/main.rs` |
| `:check` in boot-context, verdict rendering, `kill-emacs` | `host/emacs-kernel/emacs-hypervisor-bootstrap.el` |
| Plan-only branch | `elle/hypervisor.lisp` |
| Duplicate-name detection | `elle/boot-policy.lisp` or `elle/graph.lisp` |
| Lint pass + `:lint` export | new `elle/runtime-forms/emacs-hypervisor-lint.el`, `emacs-hypervisor-declarations.el` (session-data export) |

## Test Expectations

- The repo's own `config.org` exits 0.
- A config with a unit cycle exits 1 and names the cycle members.
- A unit with an unset `:env` var exits 1; setting the var flips it to 0.
- Lint-only findings exit 0 without `--strict`, 1 with it.
- For the same config, `check`'s planned reports equal the `:planned`
  reports of a real startup (same statuses, same reasons).
- `check` leaves no session artifacts in the home beyond the tangled file.

---

# Part 3 — Org Source Mapping

## Motivation

Every report, log line, and effect record identifies things by unit name,
and every trail dead-ends in the hidden `.config.tangled.el`. For literate
configs — the recommended path — the user edits `config.org` headings, but
failures point nowhere near them. The effect record contract already
specifies `:source (:file ... :line ...)` and lists real source locations as
remaining work.

This feature gives every `package!` and `config-unit!` declaration a
provenance plist resolving to the **org file, heading, and line** the user
actually edits. It multiplies the value of everything that already exists
(startup reports, reload logs, failure details, effect records) and
everything planned (lint findings, form-addressed failure reports, registry
introspection).

## Source Plist

```elisp
;; literate config
(:file "/home/u/.config/emacs-hypervisor/config.org"
 :heading "Magit"
 :line 14            ; line in config.org
 :tangled-line 87)   ; line in .config.tangled.el, kept for debugging

;; plain config.el
(:file "/home/u/.config/emacs-hypervisor/config.el"
 :line 31)
```

## Mechanism

Two cooperating changes, both inside
`elle/runtime-forms/emacs-hypervisor-config-loader.el` and
`emacs-hypervisor-declarations.el`.

### 1. Tangle with link comments

`emacs-hypervisor--tangle-config-org-file` binds
`org-babel-default-header-args` to inject `:comments link` for the tangle
call. Org then brackets each tangled block with comments of the form:

```elisp
;; [[file:config.org::*Magit][Magit:1]]
... block content ...
;; Magit:1 ends here
```

This reuses Org's own provenance machinery instead of re-parsing the org
file; positions are exact even for duplicated heading names. Blocks where
the user explicitly set `:comments` keep their setting. The markers are
ordinary comments — load semantics of the tangled file are unchanged.

### 2. Position-recording loader

`emacs-hypervisor-load-startup-config` stops calling `load-file` and
instead calls a new `emacs-hypervisor--load-with-source-map`, which:

1. Visits the load target in a temp buffer.
2. Builds the line → `(:file :heading :line)` map by scanning the
   `[[file:...::...]]` link comments (for `config.el`, the map is identity:
   file + line).
3. Reads top-level forms one at a time, noting the line of each form's
   start, and evaluates each with the dynamic variable
   `emacs-hypervisor--current-source` bound to the resolved source plist.

`package!` and `config-unit!` expansions gain one field:
`:source (emacs-hypervisor--capture-source)` — evaluated when the `push`
runs, i.e. exactly while the loader's binding is in effect. Forms outside
any mapped block (or loaded by other means, e.g. `eval-buffer` during
development) capture `nil` and everything degrades to today's behavior.

The reload path (`emacs-hypervisor-reload-config`) goes through the same
loader, so the map is rebuilt on every reload for free.

## The Identity Invariant

> **`:source` never participates in unit identity or diffing.**

Selective reload compares exported entries with `equal`
(`emacs-hypervisor-selective-reload-unit-equal-p`). If `:source` were part
of the compared entry, adding a comment at the top of `config.org` would
shift every line number below it and mark every unit `:changed`, defeating
selective reload entirely. The diff must compare entries with `:source`
stripped (the same treatment `:index` needs — reordering currently dirties
units through `:index`; stripping both makes diffing purely content-based,
with ordering still enforced separately by `:after`).

## Consumers

| Consumer | Change |
|---|---|
| Startup report (`emacs-hypervisor-report.el`) | Failed/invalid items render `config.org · Magit · line 14`; report buffer entries become buttons that jump to the org location |
| Reload logs/report (`emacs-hypervisor-reload-report.el`) | Cleanup and failure lines cite the source |
| Effect records (`emacs-hypervisor-effect-aware-reload.el` → kind modules) | The normalizer already threads the unit name into register helper calls; it additionally threads the unit's `:source`, finally populating the contract's `:source` field with file/line instead of bare `:form` |
| Failure details (`docs/PROTOCOL.md` detail shapes) | `:execution` details gain `:source`, enabling the form-addressed failure reports sketched in effect-system.md |
| `check` lint findings (Part 2) | Findings cite org locations |

The source plist crosses the wire as ordinary protocol metadata (a plist of
atoms — decoded by `from-wire` like every other field; it is not body data
and needs no homoiconicity care).

## Edge Cases

- **Duplicate heading names**: Org's `::*Heading` links can be ambiguous in
  pathological cases; the map keeps `:tangled-line` as the unambiguous
  fallback and jump targets verify the heading text before jumping.
- **`:tangle no` blocks**: never tangled, never mapped — no change.
- **User-set `:comments no`** on a block: that block loses org mapping;
  declarations in it carry tangled-file coordinates only.
- **Performance**: one extra buffer scan of the tangled file plus
  read-per-form instead of `load-file`. Budget: ≤ 50ms on a 2000-line
  config, measured via the existing `:metric` plumbing
  (`:load-config`).

## Code Anchors

| Change | Location |
|---|---|
| `:comments link` injection | `emacs-hypervisor-config-loader.el` (`--tangle-config-org-file`) |
| Position-recording loader + marker parser | `emacs-hypervisor-config-loader.el` (new `--load-with-source-map`) |
| `:source` capture in macros | `emacs-hypervisor-declarations.el` (`package!`, `config-unit!`) |
| Strip `:source`/`:index` from diff identity | `emacs-hypervisor-selective-reload.el` (`unit-equal-p`) |
| Thread source into effect registration | `emacs-hypervisor-effect-aware-reload.el`, `emacs-hypervisor-effect-kind-*.el` |
| Report rendering + jump buttons | `emacs-hypervisor-report.el`, `emacs-hypervisor-reload-report.el` |

## Test Expectations

- A unit declared under `* Magit` in `config.org` exports
  `:source` with the org file, heading `"Magit"`, and the declaration's org
  line.
- Inserting text above a unit in `config.org` and reloading marks that unit
  `:unchanged`.
- A `config.el` declaration exports file + line, no heading.
- An effect record created by a mapped unit carries `:source` with file and
  line per the effect-record contract.
- A unit body that signals during reload produces a failure report citing
  the org location.
- `eval-buffer` of a config region outside the loader still registers
  declarations, with `:source nil`.

## What This Is Not

No source-to-source rewriting of `config.org`, no org parsing beyond the
link comments Org itself emits, no attempt to map *inner* forms of a body to
sub-block positions (the declaration is the unit of provenance; `:form` in
effect records keeps identifying the inner site).
