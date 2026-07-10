# WP5 — Rust Host & Trusted Emacs Kernel

Scope: `host/src/main.rs`, `host/build.rs`, `host/Cargo.toml`,
`host/elisp_pack/`, `host/emacs-kernel/*.el`,
`tests/elisp/emacs-hypervisor-bootstrap-test.el`.

Run ERT with the invocation in `docs/improvements/README.md` (trampolines
disabled). Rust tests: `cargo test --manifest-path host/Cargo.toml` (main.rs
has an embedded test module) and
`cargo test --offline --locked --manifest-path host/elisp_pack/Cargo.toml`.

Note: WP1 §1.3 already covers the `:shutdown`-topic/startup-complete overload.
Items 5.6 and WP1 §1.3 touch the same state machinery — implement them
together or sequence WP1 first.

## Trusted kernel (elisp)

### 5.1 Parse errors and dispatch errors share one destructive handler (BUG, highest severity)

`emacs-hypervisor-sexp-rpc.el:243-265` — `--consume-input` wraps both
`(read (current-buffer))` and `(emacs-hypervisor--dispatch value)` in one
`condition-case` whose handler **erases the entire input buffer** and
re-signals. So an error inside any event handler (or the "Unsupported
non-sexp-rpc message" error at `sexp-rpc.el:236` for stray stdout text):

1. discards every complete-but-unprocessed message already buffered in the
   same chunk (e.g. a `:shutdown` right behind the poisoned message), and
2. propagates out of the process filter through `accept-process-output` —
   `emacs-hypervisor-wait-for-completion` (`bootstrap.el:77-92`),
   `emacs-hypervisor-await-response` (`sexp-rpc.el:201-215`), and
   `emacs-hypervisor--check-finish` (`home-startup.el:183-210`) all loop on it
   unguarded, so `check` mode can die with a raw backtrace instead of its
   documented exit codes.

**Required change** — separate the two failure domains:

- Keep the buffer-erasing recovery **only** around the `read` (a genuine
  framing corruption means buffered bytes are unusable).
- Wrap `(emacs-hypervisor--dispatch value)` in its own `condition-case` that
  records the error (append to warnings/log via the existing events
  machinery, or `message`) and **continues** the consume loop, preserving
  remaining buffered messages and never signaling out of the filter.

**Tests** — (a) feed the filter one message whose handler throws followed by a
`:shutdown` event in the same string; assert the shutdown is still processed.
(b) feed garbage bytes then a valid message in a subsequent call; assert
recovery. Existing filter tests (partial input, re-entrancy) must keep
passing.

### 5.2 Crash before any `:shutdown` leaves `emacs-hypervisor-readiness` stuck at `loading` (BUG)

`emacs-hypervisor-bootstrap.el:47-54` — the sentinel sets `--state :failed`
but never `--completed`; `emacs-hypervisor-readiness`
(`session-state.el:184-203`) requires `--completed` for both the `ready` and
`failed` branches. A hard crash with no `:shutdown` event (binary missing,
segfault) leaves the documented external-launcher API reporting `loading`
forever.

**Required change** — in the sentinel's abnormal-exit branch, also set
`emacs-hypervisor--completed t` (or change `readiness` to treat
`:state :failed` as terminal regardless of `--completed`; pick whichever keeps
`emacs-hypervisor-session-active-p` semantics intact). Coordinate with WP1
§1.3 (`:session-ready` topic): after both changes, the matrix must be —
ready+alive ⇒ `ready`; died after `:shutdown` ⇒ completed; died without
`:shutdown` ⇒ `failed`, even if `:session-ready` was seen.

**Test** — simulate process death with no shutdown event; assert `readiness`
returns `failed`.

### 5.3 `emacs-hypervisor-load-envvars-file` violates its NOERROR contract (BUG)

`emacs-hypervisor-bootstrap.el:20-42` — docstring promises NOERROR covers
"doesn't exist or is unreadable", but only existence is guarded; an unreadable
or malformed env file aborts the whole startup
(`home-startup.el:232` calls with `noerror t` relying on the documented
"env file can help, but is not required" policy).

**Required change** — wrap `insert-file-contents` + `read` in
`condition-case`; when `noerror`, warn (`display-warning`) and return nil
instead of signaling. While here: fix the docstring's return-value claim (it
returns the parsed env sexp, not "names of changed envvars") — align one to
the other; and record `emacs-hypervisor-loaded-env-file` even when the parsed
list is empty (`when-let` at line 29 currently skips it).

**Test** — env file containing malformed sexp with `noerror t`: startup helper
proceeds, warning recorded. Without `noerror`: signals.

### 5.4 Eval error responses carry a useless backtrace

`emacs-hypervisor-sexp-rpc.el:124-138` — `(with-output-to-string (backtrace))`
runs in the `condition-case` handler after unwinding, so the captured trace
never includes frames from the failing form.

**Required change** — capture the backtrace at signal time using
`handler-bind` (Emacs 30 is the dev baseline; kernel targets 29.1+ — if 29
compatibility is required, use `condition-case` with `:debugger`-style capture
via `debugger` binding, or gate on `(fboundp 'handler-bind)` and keep the old
behavior as fallback). Assert in a test that the backtrace string mentions a
function name from inside the evaluated form.

### 5.5 Binary resolution ignores env-file overrides (BUG)

`home-startup.el:53-65,224-233` — the documented algorithm (comment at lines
45-51) retries resolution after the env file loads "if still unresolved", but
any pre-env-file hit is cached in `emacs-hypervisor-binary`, so
`EMACS_HYPERVISOR_BIN`/`PATH` from the env file can never override a stale
same-named binary found on the launch PATH.

**Required change** — after loading the env file, re-resolve when
`EMACS_HYPERVISOR_BIN` is set or PATH changed, preferring the env-file result;
or simpler: always re-run resolution after env load and take the new result if
it differs (log when it does). Keep "first found wins" only within a single
resolution pass. Add a test with a fake env file overriding
`EMACS_HYPERVISOR_BIN`.

### 5.6 Unguarded `load` of user early-init in the trusted stage

`host/emacs-kernel/early-init.el:16-19` — an error in the user-owned
early-init crashes trusted Emacs before any isolation exists.

**Required change** — wrap in `condition-case`, stash the error in a defvar
the session state/report can surface later (mirroring the
`:config-load-failed` pattern), and continue startup. Test: user early-init
that signals; assert Emacs-side load continues and the error is recorded.

### 5.7 Kernel code-quality cleanups (bundle into whichever item touches the file)

- Dead `handled` variable in `--dispatch-rpc-request`
  (`sexp-rpc.el:140-182`) — remove.
- Unknown-topic events dropped silently (`events.el:147-151`) — log via
  `display-warning` or the log-messages list.
- Triplicated `defvar`s across session-state/events/sexp-rpc
  (`--process`, `--state`, `--completed`, etc.) — consolidate ownership in
  `emacs-hypervisor-session-state.el` and reduce other files to `require` +
  (where load order forbids) a single commented forward declaration.
- `emacs-hypervisor-start` (`bootstrap.el:56-75`) — call
  `emacs-hypervisor-reset` (or reset `--finish-notified` minimally) at entry
  so a stale flag can't suppress finish notification.
- XDG path logic duplicated in `early-init.el:9-15` vs
  `home-startup.el:9-21` — acceptable due to load order, but add a comment in
  both pointing at the other.

## Rust host

### 5.8 `init` refuses directories containing only noise files (BUG)

`host/src/main.rs:381-400` — `ensure_home_is_empty` treats any entry as
non-empty; on macOS a Finder-created `.DS_Store` makes
`emacs-hypervisor init --home DIR` fail on a logically empty directory.

**Required change** — ignore a small allowlist of noise entries
(`.DS_Store` at minimum; decide deliberately whether to skip all dotfiles —
skipping `.git` is defensible for "init into a fresh dotfiles repo"). List the
ignored names in the error message when refusal still happens. Add unit tests
beside `init_writes_generated_bootstrap_files`.

### 5.9 Compile-time `.elle` default breaks installed binaries (BUG)

`host/src/main.rs:205-211` — `default_elle_home_path()` embeds
`env!("CARGO_MANIFEST_DIR")/../.elle` at compile time; `run_serve`
(`main.rs:349-351`) falls back to it, so a copied/installed binary resolves a
path that only exists on the build machine.

**Required change** — make the fallback runtime-resolved: check in order (1)
explicit config/flag (existing behavior), (2) an env var
(`EMACS_HYPERVISOR_ELLE_HOME`) if one fits existing conventions, (3) the
compile-time repo path **only if it exists**, else fail with a clear error
naming the searched locations instead of silently pointing at a phantom path.
Also rename one of the two unrelated `repo_root()` helpers
(`main.rs:205-207` vs `build.rs:24-27`) to stop the semantic collision.

### 5.10 `env` subcommand writes secrets world-readable (SECURITY)

`host/src/main.rs:610-661` — only `SHELL` is excluded; `ANTHROPIC_API_KEY`,
`AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, etc. are written verbatim to
`HOME/env` via `write_file` (`main.rs:402-409`) with default umask.

**Required change** —

- Exclude names matching a denylist of secret patterns (suffixes `_TOKEN`,
  `_KEY`, `_SECRET`, `_PASSWORD`, `_CREDENTIALS`; prefixes `AWS_`; plus
  `GITHUB_TOKEN`-style exact names). Print a one-line summary of how many
  entries were skipped and a flag (`--include NAME`, repeatable) to
  re-include specific ones deliberately.
- Write the env file with `0o600` on unix (mirror the existing
  `fs::set_permissions` pattern at `main.rs:261-266`).
- Extend the `env_entries_skip_shell` test for the new exclusions and add a
  permissions assertion (unix-gated).

### 5.11 Upgrade writes are non-atomic with no backup

`host/src/main.rs:546-608` (`run_init_upgrade`) — two independent in-place
`write_file` calls; a failure between them leaves `init.el`/`early-init.el`
inconsistent, with the previous contents already destroyed.

**Required change** — write both files to temp names in the target directory
and `fs::rename` into place only after both writes succeed (rename is atomic
on same filesystem). Extend `init_upgrade_rewrites_generated_bootstrap_files`.

### 5.12 Resolve the dead `elisp_pack` build dependency

`host/Cargo.toml:12` declares `elisp_pack` as a build-dependency that
`host/build.rs` never calls (wiring removed in commit `7794d4c`); meanwhile
`expand_source` (`build.rs:145-181`) splices `.el` sources with zero syntax
validation, so a malformed module now surfaces as a `serve`-time VM failure
instead of a `cargo build` failure.

**Required change (pick one, coordinate with WP4 §4.7 which documents the
status):**

- (a) Re-wire: call `elisp_pack` validation (`pack_file`/`pack_source`) from
  `expand_source` for each embedded `.el`, failing the build on parse errors —
  restores build-time validation and makes `host/ELISP-PACK.md` true again; or
- (b) Remove: delete the build-dependency (and decide the crate's fate —
  keep as a workspace member with its own tests, or remove entirely), cutting
  tree-sitter from the build graph.

Option (a) is preferred if build-time cost is acceptable; it catches real
regressions (WP1-WP3 edit these `.el` files heavily).

### 5.13 Host code-quality cleanups

- Deduplicate the two hand-rolled FNV-1a-64 implementations
  (`main.rs:434-441`, `build.rs:12-22`) — a tiny shared module or accept the
  duplication with cross-referencing comments (build.rs cannot depend on the
  bin crate; a small `host/src/hash.rs` included via `include!` from build.rs
  is one pragmatic pattern).
- The `--home` default help text is copy-pasted four times
  (`main.rs:44-47,86,141-143,160-162`) — hoist into a `const`.

## Test-coverage gaps worth closing alongside the fixes

- Kernel: malformed-input filter test (5.1), abnormal-exit readiness test
  (5.2), env-file NOERROR tests (5.3), backtrace-content assertion (5.4),
  binary re-resolution test (5.5), early-init isolation test (5.6).
- Host: `run_env` end-to-end (exclusions + permissions), `ensure_home_is_empty`
  noise-file cases, upgrade atomicity.

## Acceptance criteria

- Full ERT suite passes (trampolines disabled) with new tests included.
- `cargo test --manifest-path host/Cargo.toml` passes; elisp_pack decision
  implemented consistently with docs (WP4 §4.7).
- A message whose handler throws no longer destroys queued messages nor
  crashes `check` mode.
- `emacs-hypervisor-readiness` reports `failed` after an eventless crash.
- `emacs-hypervisor env` output contains no values for names matching the
  secret denylist and the file is `0600` on unix.
