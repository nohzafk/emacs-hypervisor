# Improvement Plan (2026-07-08)

Findings from a full-repo audit (Elle orchestration layer, elisp runtime-forms,
trusted Emacs kernel, Rust host, documentation), organized into independent,
implementable work packages. Each numbered doc is self-contained: findings,
exact file/line targets, required behavior, and acceptance criteria.

## Work packages

| Doc | Area | Highlights |
|---|---|---|
| [01-elle-orchestration-correctness.md](01-elle-orchestration-correctness.md) | `elle/*.lisp`, `host/emacs-kernel/emacs-hypervisor-events.el` | Multi-executable preflight, gate units on real package outcomes, stop overloading `:shutdown` for startup-complete, debug-output gating, env-list trimming, dead-code removal, Elle test gaps |
| [02-package-management-correctness.md](02-package-management-correctness.md) | `elle/runtime-forms/emacs-hypervisor-package-*.el` | Adopt path skips revision checkout, archive upgrade reports show `? -> ?`, prune/upgrade abort on first failure, lock schema validation, cross-module `require` hygiene |
| [03-effects-and-reload-fixes.md](03-effects-and-reload-fixes.md) | `elle/runtime-forms/emacs-hypervisor-{selective-reload,effect-*,reload-report,report}.el` | Selective-reload identity defeated by embedded provenance, keybinding retraction misreports success, report buffer resets point on every refresh, dead fallback code |
| [04-docs-accuracy-overhaul.md](04-docs-accuracy-overhaul.md) | `AGENTS.md`, `README.md`, `docs/*.md`, `host/*.md`, `justfile` | Machine-specific path rot, removed-feature docs (extensions opt-in, egui), ELISP-PACK stale claims, broken links/anchors, test-harness hardening against broken libgccjit |
| [05-host-and-kernel.md](05-host-and-kernel.md) | `host/src/*.rs`, `host/emacs-kernel/*.el` | Rust host + trusted kernel findings |

## Test baseline (verified 2026-07-08)

- `./.elle/target/release/elle tests/elle/hypervisor-runtime.lisp` — all pass.
- ERT: 122 tests; **7 fail** with stock invocation on machines with a broken
  `libgccjit` (native-comp trampoline compilation is triggered by `cl-letf`
  mocks of C built-ins). All 122 pass with
  `--eval '(setq native-comp-enable-subr-trampolines nil)'` added before
  loading tests. Doc 04 makes the `justfile` recipe do this unconditionally.

Run ERT suite:

```bash
emacs --batch -Q \
  --eval '(setq native-comp-enable-subr-trampolines nil)' \
  -L host/emacs-kernel -L elle/runtime-forms -L tests/elisp \
  -l tests/elisp/emacs-hypervisor-bootstrap-test.el \
  -f ert-run-tests-batch-and-exit
```
