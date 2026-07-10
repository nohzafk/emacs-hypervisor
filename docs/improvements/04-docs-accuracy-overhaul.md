# WP4 — Documentation Accuracy Overhaul & Test-Harness Hardening

Scope: `AGENTS.md`, `README.md`, `docs/architecture.md`,
`docs/architecture-mermaid.md`, `docs/effect-system.md`, `host/ELISP-PACK.md`,
`justfile`. Documentation-only except for the `justfile` change; no runtime
code changes in this package.

## 4.1 `justfile` test recipe fails on machines with broken libgccjit

The ERT tests mock C built-ins with `cl-letf`, which triggers native-comp
trampoline compilation. On machines where libgccjit is broken (observed here:
`ld: library 'emutls_w' not found`), 7 of 122 tests fail for environmental
reasons. Verified fix: disabling trampolines makes all 122 pass and is safe in
batch test mode.

**Required change** — in the `test` recipe (`justfile:56-65`), add
`--eval '(setq native-comp-enable-subr-trampolines nil)'` immediately after
`-Q` in the emacs invocation.

## 4.2 `AGENTS.md` path rot

Every absolute link uses `/Users/randall/projects/emacs-hypervisor/...` —
wrong prefix for any machine but the original author's, and several targets no
longer exist. Affected lines: 17, 19, 23, 25, 27, 29, 31, 33, 35, 38, 40, 43,
45, 47, 49, 51, 55, 57, 103, 105, 107, 133, 193, 195, 197, 199, 201, 220-225,
242, 244, 246, 248.

**Required changes**

1. Convert every absolute link to a repo-relative path
   (`[elle/boot-policy.lisp](elle/boot-policy.lisp)`).
2. Fix moved targets:
   - `host/templates/lisp/emacs-hypervisor-bootstrap.el` (lines 31, 242) →
     `host/emacs-kernel/emacs-hypervisor-bootstrap.el`
   - root `PROTOCOL.md` (line 49) → `docs/PROTOCOL.md`
3. Remove references to files that do not exist and have no git history or
   were deleted:
   - `config.org`, `config/`, `env` bullets (lines 25-29) — replace with a
     bullet describing the real mechanism: `scripts/emacs-home-e2e` generates a
     throwaway `config.org`, and `emacs-hypervisor env` produces env
     snapshots.
   - `bin/` and `bin/hypervisor-env` (lines 51-54) — replaced by the
     `emacs-hypervisor env` subcommand.
   - `experiments/README.md` (lines 57, 105) — never existed; point at
     `tests/elle/hypervisor-runtime.lisp` and
     `tests/elisp/emacs-hypervisor-bootstrap-test.el` for the preserved spike
     regression coverage.
4. Line 15: drop/soften "This repository is still in spike mode" — it
   contradicts the same document and the feature depth of the codebase.

## 4.3 `README.md` documents removed features

1. **Extensions opt-in gating is gone.** Commit `b629fb9` removed the
   `emacs-hypervisor-extensions` defcustom and gating; extensions are now
   always enabled when their native plugin loads
   (`elle/extension-mermaid.lisp:59-67` registers purely on plugin import
   success; `emacs-hypervisor-markdown-mermaid.el:689-692` hardcodes
   `:mermaid-enabled t`). But README still documents the old model:
   - line 473: delete the `emacs-hypervisor-extensions` row from the Runtime
     Variables table (and the `"mermaid,egui"` example — `egui` was removed
     entirely in commit `eb79621`, moved to the separate `emacs-egui-panel`
     project).
   - lines 475-493 ("Extension Design"): rewrite to state extensions activate
     automatically when their backing native plugin is embedded and loads;
     failure mode is per-request `extension-unavailable`, not startup
     validation.
   - lines 494-502: delete the `(setq emacs-hypervisor-extensions "mermaid")`
     snippet; replace with "Mermaid rendering is available once the binary is
     built with the `mmdflux` plugin (`just build`) — no configuration
     required."
2. Line 640: fix `[PROTOCOL.md](PROTOCOL.md)` → `docs/PROTOCOL.md`.
3. "Further Reading" table (lines 636-648): add a row for
   `docs/architecture-mermaid.md` (currently unreachable from README).

Verify quoted line numbers by grep before editing — they may have drifted.

## 4.4 `docs/architecture.md` stale File Guide

Lines 285-287: `config.org` and `config/` do not exist (deleted in commit
`0da8fb0`); rewrite to describe the real e2e mechanism
(`scripts/emacs-home-e2e` generates config on the fly, or copies from
`--config-source PATH`). The root `early-init.el` entry mislabels an orphaned
file — either delete the doc line and flag the orphan file in the doc PR
description, or relabel it honestly as currently unused.

## 4.5 `docs/architecture-mermaid.md` describes a nonexistent gate

Line 53 claims `unsupported-extensions` raises an error at startup; that
function does not exist anywhere in `elle/`. Rewrite to the actual behavior:
plugin import failure → `make-handler` returns nil
(`elle/extension-mermaid.lisp:59-67`) → extension key omitted from the handler
registry → later `:extension-call` requests for `:mermaid` receive
`extension-unavailable` (`elle/extensions.lisp:14-15,34-35`).

## 4.6 `docs/effect-system.md` broken anchor

Line 11: `../README.md#effect-aware-reload` — no such heading. Point at
`../README.md#reload` (the actual `## Reload` section).

## 4.7 `host/ELISP-PACK.md` stale claims

1. "Module Spec Contract": claims `session-base` uses packed `:forms` loading.
   False — `elle/runtime-forms.lisp:20-25` builds `{:path path :source
   source}` for every manifest entry; `host/build.rs` never calls
   `elisp_pack::pack_file` (the wiring was added in `bf880c1` and removed in
   `7794d4c`). Rewrite as: all modules currently load via `:source`;
   `elisp_pack` is implemented and unit-tested but not wired into
   `host/build.rs`; `:forms` rollout is pending.
2. "Scope" packable-files list: 17 files listed, manifest has 23. Replace the
   hardcoded list with a pointer to `elle/runtime-forms/modules.manifest` as
   the source of truth (optionally keeping a few examples).

## 4.8 Guard against recurrence

Add a repo check that fails when machine-specific absolute paths appear in
markdown:

- New recipe in `justfile` (group `Test`), e.g.:
  ```
  check-docs:
      ! grep -rn --include='*.md' '/Users/' . --exclude-dir=.git --exclude-dir=.elle --exclude-dir=target --exclude-dir=docs/improvements
  ```
  (Adjust exclusions so vendored `.elle/` docs and this improvements folder's
  audit notes don't trip it; verify the grep exits nonzero on match and the
  `!` inverts correctly under `bash -euo pipefail` — test both outcomes.)
- Mention the new recipe in `AGENTS.md`'s workflow section and wire it into
  the `test` recipe as a dependency or first step.

## 4.9 Orphan doc

`docs/emacs-image-horizontal-scroll.md` is referenced from nowhere. Add it to
README's Further Reading table if still relevant, or note it for deletion in
the PR description (do not delete unilaterally).

## Acceptance criteria

- `just test` passes on this machine end-to-end (including the previously
  failing 7 ERT tests).
- `just check-docs` (or equivalent) passes, and fails when a `/Users/...` path
  is introduced into a tracked markdown file outside the exclusions.
- No markdown link in `AGENTS.md`/`README.md`/`docs/` points at a nonexistent
  file or anchor (spot-check with a link-extraction grep).
- README no longer mentions `emacs-hypervisor-extensions` or `egui`.
