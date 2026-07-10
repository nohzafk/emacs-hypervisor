# WP2 — Package Management Correctness & Resilience

Scope: `elle/runtime-forms/emacs-hypervisor-package-bridge.el`,
`elle/runtime-forms/emacs-hypervisor-package-runtime.el`,
`elle/runtime-forms/emacs-hypervisor-package-lock.el`,
`elle/runtime-forms/emacs-hypervisor-unit-runtime.el`,
`tests/elisp/emacs-hypervisor-bootstrap-test.el`.

Run tests with the invocation in `docs/improvements/README.md` (trampolines
disabled).

## 2.1 `--adopt` never enforces the resolved revision on pre-existing clones (BUG)

`emacs-hypervisor-package-bridge.el:402-433` (`emacs-hypervisor-bridge--adopt`).
`--checkout-ref` (line 263) is only invoked from `--start-clone`'s sentinel
(line 299), i.e. only on the fresh-clone path. `emacs-hypervisor-bridge-install-batch`
(lines 464-503) excludes entries whose staging clone already exists on disk
(`--clone-present-p`, line 472) from `to-clone` and routes them straight to
`--adopt` with **no revision enforcement**. A leftover clone from an
interrupted install (or a manually staged checkout) is adopted at whatever
commit happens to be checked out, ignoring the declared `:ref`/`:tag` and the
locked `:rev`.

**Required change** — in `--adopt`, call
`(emacs-hypervisor-bridge--checkout-ref entry)` as the first statement inside
the `unless (package-installed-p sym)` block, before `--prepare-checkout`
(line 414), so the build step also runs against the correct commit. Revision
enforcement becomes idempotent regardless of which path reached `--adopt`.

**Test** — model on `emacs-hypervisor-bridge-install-batch-preserves-plan-order`
(test file ~line 2675): stub `--clone-present-p` to return `t` for a VC entry
carrying a locked `:rev`; assert `--checkout-ref` (or the underlying `git
checkout` invocation) runs before `package-vc-install-from-checkout`.

## 2.2 Archive-package upgrades always report `? -> ?` (BUG)

`emacs-hypervisor-package-runtime.el:169-202`
(`emacs-hypervisor-runtime--upgrade-entry`) reads previous/current via
`(plist-get (emacs-hypervisor-package-lock-entry name) :rev)` (lines 173, 194),
but `--record-archive-lock` (`package-bridge.el:378-393`) writes archive
entries with `:version`, not `:rev` (line 388). Every archive-package upgrade
logs "Upgraded X: ? -> ?".

**Required change** — add
`(defun emacs-hypervisor-bridge--lock-marker (entry) (or (plist-get entry :rev) (plist-get entry :version)))`
in package-bridge.el (or a runtime-local equivalent) and use it for both the
`previous` and `current` lookups in `--upgrade-entry`.

**Test** — mirror `emacs-hypervisor-upgrade-updates-lock-and-reports-rev-delta`
(test file ~line 2954) with a `:kind :archive` lock entry whose `:version`
changes; assert the report carries the real before/after values.

## 2.3 Prune and upgrade-all abort on first per-item failure (BUG)

Three related fragilities:

1. `emacs-hypervisor-prune-packages`
   (`emacs-hypervisor-package-runtime.el:242-261`): the `dolist` over orphans
   (lines 257-258) calls `emacs-hypervisor-bridge-remove-package` unguarded.
   One locked file/permission error aborts the loop; remaining orphans stay
   un-pruned with no summary.
2. `--purge-package` (`package-bridge.el:541-564`) wraps `package-delete` and
   `.eln` deletion in `ignore-errors` but the clone-dir/pkg-dir deletion loop
   (lines 556-557) has no guard — the most likely step to throw.
3. `emacs-hypervisor-upgrade-all-packages`
   (`package-runtime.el:228-240`) `mapcar`s `--upgrade-entry` over all declared
   packages; `--upgrade-entry` calls `(package-refresh-contents)` unguarded
   once **per archive package** (line ~182). A single network failure throws
   out of the whole batch — no reports for remaining packages — and the archive
   index is redundantly re-fetched N times.

**Required changes**

- Wrap each per-orphan removal in `condition-case`; collect `(name . reason)`
  failures; message a `"Pruned N of M packages"` summary naming failures.
- Wrap the clone-dir/pkg-dir deletion loop in `ignore-errors`, matching the
  tolerance already applied to the other purge steps.
- Hoist `package-refresh-contents` out of `--upgrade-entry` into
  `emacs-hypervisor-upgrade-all-packages`: call once before the loop, guarded
  by `condition-case`, only when at least one archive entry exists. On refresh
  failure, mark affected archive entries `:failed` with the network reason and
  continue with VC entries. `emacs-hypervisor-upgrade-package` (single) keeps a
  guarded refresh for its own path. Wrap each per-entry upgrade in
  `condition-case` so one failure yields a `:failed` report, not an abort.

**Tests** — (a) prune with the first removal stubbed to signal; assert the
second orphan is still removed and the summary names the failure. (b)
upgrade-all with `package-refresh-contents` stubbed to signal; assert VC
entries still upgrade and archive entries report `:failed`. (c) assert
`package-refresh-contents` is invoked exactly once for a batch containing two
archive packages.

## 2.4 Lock reader accepts any schema version

`emacs-hypervisor-package-lock.el:22-33` — `emacs-hypervisor-package-lock-read`
checks only that `:schema-version` is present, not that it equals
`emacs-hypervisor-package-lock-schema-version`. A future/hand-edited schema is
silently accepted and rewritten by `--write` (lines 44-63), potentially
destroying fields the current code doesn't know about.

**Required change** — treat a mismatched schema version as unreadable: return
nil (and `display-warning` naming the file and both versions) rather than
adopting the data. Add a roundtrip test with a bumped `:schema-version`.

Minor: `emacs-hypervisor-package-lock-remove` (lines 74-81) re-reads the
lockfile to check existence; reuse the already-read `entries`.

## 2.5 Cross-module `require`/special-variable hygiene

These modules load via `eval-buffer` in manifest order today, so dynamic-scope
resolution happens to work — but any standalone byte-compilation or reordering
breaks it silently:

- `emacs-hypervisor-package-runtime.el:183` let-binds
  `emacs-hypervisor-bridge-ignore-lock` (defvar'd in package-bridge.el:21-22)
  without requiring that module. Under `lexical-binding: t`, compiling this
  file standalone turns the binding lexical — silently defeating the
  ignore-lock override during upgrades.
- `emacs-hypervisor-config-loader.el:24-43` let-binds
  `org-babel-default-header-args` and the tangle comment-format vars while
  `(require 'ob-tangle)` only happens inside the function body — same footgun
  for the tangle-comment injection.
- `emacs-hypervisor-package-runtime.el` uses
  `emacs-hypervisor-installed-packages` / `emacs-hypervisor-execution-events`
  (session-base), several `emacs-hypervisor-bridge-*` functions, and lock
  functions without requiring their modules. Same for
  `emacs-hypervisor-unit-runtime.el:40-41,52-53` (session-base vars).
- `emacs-hypervisor-runtime-note-package-event`/`...-unit-event`
  (package-runtime.el:9-11, unit-runtime.el:14-16) call report functions
  guarded only by `fboundp` with no `declare-function`.

**Required changes**

- Add `(require 'emacs-hypervisor-session-base)`,
  `(require 'emacs-hypervisor-package-lock)`,
  `(require 'emacs-hypervisor-package-bridge)` to
  `emacs-hypervisor-package-runtime.el`; add
  `(require 'emacs-hypervisor-session-base)` to
  `emacs-hypervisor-unit-runtime.el`. Verify each target file `provide`s the
  matching feature; add `provide` lines if missing. **Constraint:** modules are
  evaluated by `module-loader.lisp` via `eval-buffer` in manifest order — the
  added requires must resolve via `load-path` in the ERT harness *and* be
  no-ops (already loaded / `featurep`) in the live session. Check how existing
  runtime-forms `require` each other (e.g. `emacs-hypervisor-report.el`
  requires `emacs-hypervisor-report-core`) and follow the same pattern.
- In `config-loader.el`, hoist declarations: either top-level
  `(require 'ob-tangle)` or `defvar` forward declarations for the three
  `org-babel-*` special variables before the function definition.
- Add `declare-function` forms for the `fboundp`-guarded report calls.
- `emacs-hypervisor-session-base.el:3` requires `cl-lib` but uses none of it —
  drop it.
- `emacs-hypervisor-effect-registry.el:156` uses one-arg `(eval retract)`;
  change to `(eval retract t)` (matching `emacs-hypervisor-reload-policy.el:91`)
  — coordinate with WP3 §3.2 which restructures the same call site; if WP3 is
  already merged, this item is covered.

**Verification** — byte-compile the touched files standalone and confirm no
free-variable/undefined-function warnings for the symbols above:

```bash
emacs --batch -Q --eval '(setq native-comp-enable-subr-trampolines nil)' \
  -L host/emacs-kernel -L elle/runtime-forms \
  --eval '(setq byte-compile-error-on-warn nil)' \
  -f batch-byte-compile elle/runtime-forms/emacs-hypervisor-package-runtime.el \
  elle/runtime-forms/emacs-hypervisor-unit-runtime.el
# then remove the generated .elc files
```

## 2.6 Session-base test coverage

`emacs-hypervisor-session-base.el` has zero dedicated ERT coverage; the test
file re-`defvar`s its variables (test file lines 52-53) instead of requiring
the module. After 2.5 adds proper `provide`/`require`, replace those ad-hoc
`defvar`s with a `require` and add a minimal test asserting the module's
variables exist and reset behavior works.

## Acceptance criteria

- Full ERT suite passes (trampolines disabled), including the new tests in
  2.1-2.4.
- Byte-compiling `emacs-hypervisor-package-runtime.el` and
  `emacs-hypervisor-unit-runtime.el` standalone produces no warnings about the
  symbols named in 2.5.
- Elle suite still passes (`./.elle/target/release/elle
  tests/elle/hypervisor-runtime.lisp`) — these modules are shipped to Emacs
  verbatim, and the module-order test from WP1 (if present) must still hold.
