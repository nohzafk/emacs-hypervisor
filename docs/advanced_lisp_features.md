# Advanced Features From Lisp-To-Lisp Magic

This note explores capabilities that become possible *specifically because*
config-unit bodies cross the Emacs/Elle boundary as structured Lisp data, not
opaque strings. It deliberately looks beyond what
[LISP-TO-LISP-FUTURES.md](file:///Users/randall/projects/emacs-hypervisor/LISP-TO-LISP-FUTURES.md)
already covers (portraits, dependency inference, form-addressed failures,
targeted rewrites, reload diffs, undo/transactions, policy checks, interactive
remediation).

Everything here is grounded in the architecture described in
[README.md](file:///Users/randall/projects/emacs-hypervisor/README.md) and the
code that already exists in [elle/](file:///Users/randall/projects/emacs-hypervisor/elle)
and [elle/runtime-forms/](file:///Users/randall/projects/emacs-hypervisor/elle/runtime-forms).

---

## 1. Speculative Execution With Structural Rollback

The futures doc mentions undo and transaction support, but there's a more
powerful version: **speculative execution**.

Because Elle holds the structured body *before* sending it to Emacs for eval,
Elle can:

1. Emit a **snapshot preamble** that captures the pre-eval state of every
   symbol the body will touch (variables via `symbol-value`, hooks via
   `symbol-value`, keymaps via deep copy, advice list via
   `advice--symbol-function`).
2. Send the unit body for eval.
3. If the eval fails or the user rejects the result interactively, emit a
   **rollback form** that restores every captured symbol to its snapshot.

This is not general Elisp rollback—it's *body-scoped* rollback. Elle knows
exactly which symbols the body touches because it can walk the structured
forms. The snapshot is precise, not global.

**What this enables:**
- "Try this config change; undo it if you don't like it" as a first-class
  workflow.
- Config unit A/B testing: apply variant A, snapshot, apply variant B, let the
  user choose.
- Safe interactive config exploration during a live session.

**What it requires:**
- The body portrait recognizer (already planned) to extract touched symbols.
- A new `emacs-hypervisor-runtime-snapshot-symbols` helper in the unit runtime.
- A rollback message type in the protocol, or an `:eval` that carries the
  rollback form.

---

## 2. Cross-Unit Effect Interference Detection

Individual body portraits tell you what one unit does. But the real power is
**cross-unit analysis**: detecting when two units touch the same hook, keymap,
variable, or advice target in conflicting ways.

Because Elle holds *all* unit bodies simultaneously as structured data, it can
build an **effect interference graph**:

```
unit "vertico" → writes `completing-read-function`
unit "ivy"     → writes `completing-read-function`
→ CONFLICT: two units write the same variable
```

```
unit "magit"    → binds `C-x g` in `global-map`
unit "my-keys"  → binds `C-x g` in `global-map`
→ CONFLICT: two units bind the same key in the same keymap
```

```
unit "orderless" → adds advice on `completion-styles`
unit "prescient" → adds advice on `completion-styles`
→ WARNING: two units advise the same function
```

This is impossible with string-based config loading. You'd need a full Elisp
interpreter to detect these conflicts. With structured bodies, Elle can detect
them statically before any eval happens.

**What this enables:**
- Pre-boot conflict reports that explain *why* two packages fight.
- Automatic ordering suggestions: "unit X should run after unit Y because Y
  sets a variable that X overrides."
- A visual config conflict map.

**What it requires:**
- The body portrait recognizer extended to track target identities (hook names,
  keymap symbols, variable names, advice targets).
- A cross-unit analysis pass in [elle/boot-policy.lisp](file:///Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp) or a new `elle/analysis.lisp`.

---

## 3. Config-Unit Provenance And Time-Travel

Because unit bodies are structured data, Elle can **hash each body** and
maintain a content-addressed history:

```
unit "magit" @ sha256:abc123 → body (progn (setq magit-display-buffer-function ...) ...)
unit "magit" @ sha256:def456 → body (progn (setq magit-display-buffer-function ...) ...)
```

Combined with the existing reload diff infrastructure in
[emacs-hypervisor-compose.el](file:///Users/randall/projects/emacs-hypervisor/elle/runtime-forms/emacs-hypervisor-compose.el),
this enables:

- **"What changed in my magit config since last week?"** — a structural diff
  between two body hashes, not a text diff of config.el.
- **"Roll back my vertico unit to what it was yesterday"** — restore a previous
  body hash and reload selectively.
- **Bisect a config regression** — binary search through body history to find
  which change broke something.

The structural diff is more useful than text diff because it understands form
boundaries. "You added an `add-hook` call and changed a `setq`" is better than
"lines 14-17 changed."

**What this enables:**
- Config change history that works at the semantic level.
- Regression bisection for config breakage.
- Shareable config snapshots: "here's the exact body that makes vertico work
  the way I like."

**What it requires:**
- A persistent body store (content-addressed, outside the live session).
- Body hashing in the declaration export path.
- A diff renderer that works on structured forms.

---

## 4. Body-Aware Lazy Deferral

Today, `config-unit!` is always eager—the `:requires` keyword controls feature
preloading, not whether the unit runs. But because Elle can inspect the body
structure, it can make a smarter decision:

If a unit body consists *entirely* of:
- `add-hook` calls with literal hook/function names
- `with-eval-after-load` wrapping
- autoload-safe `define-key` calls (binding to commands, not lambdas)
- `setq` on variables that don't need the package loaded

...then Elle knows the body is **pre-load safe** and can emit it early
without waiting for package installation. Conversely, if the body contains
`(require 'magit)` or touches `magit-mode-map` directly, it genuinely needs
the package.

This is different from the user declaring `:requires`—it's Elle *verifying*
the user's declaration against the actual body, or making the decision
automatically.

**What this enables:**
- Faster startup by running safe units immediately, deferring only what truly
  needs packages.
- Automatic detection of over-eager `:requires` declarations that slow startup.
- A "why is this unit waiting?" explanation grounded in actual body analysis.

**What it requires:**
- The body portrait recognizer with a "pre-load safety" classification.
- A planning pass in [elle/planning.lisp](file:///Users/randall/projects/emacs-hypervisor/elle/planning.lisp) that uses body safety as a scheduling signal.

---

## 5. Config-Unit Isolation Via Synthetic Lexical Scopes

Emacs config units today run in the global environment. One unit's `defvar` or
`setq` can silently affect another unit. Because Elle controls the exact form
sent to Emacs for eval, it can **wrap each unit body in a synthetic lexical
scope**:

```elisp
;; Instead of:
(progn
  (setq my-temp-var 42)
  (add-hook 'foo-hook (lambda () my-temp-var))
  t)

;; Elle emits:
(let ((my-temp-var 42))
  (add-hook 'foo-hook (lambda () my-temp-var))
  t)
```

Elle can detect which `setq` targets are unit-local (not referenced by other
units, not known global variables) and automatically promote them to `let`
bindings. This gives config units implicit isolation without the user writing
`let` everywhere.

More ambitiously, Elle could detect when a unit *intends* to set a global
(like `setq-default`) versus when it's using a temporary, and only isolate
temporaries.

**What this enables:**
- Implicit config unit sandboxing.
- Elimination of accidental cross-unit variable leakage.
- Clearer separation of "this unit configures a global" vs "this unit uses a
  scratch variable."

**What it requires:**
- Body analysis to classify `setq` targets as local-intent vs global-intent.
- A rewrite pass that promotes local-intent `setq` to `let`.
- The existing targeted rewrite infrastructure from LISP-TO-LISP-FUTURES.md.

---

## 6. Profile-Aware Body Specialization

Because Elle can transform bodies before they reach Emacs, it can support
**config profiles**—different body variants selected at boot time:

```lisp
;; In config.el, the user writes:
(config-unit! vertico
  :config
  (vertico-mode 1)
  (setq vertico-count 10))

;; But in a "minimal" profile, Elle rewrites the body to:
(progn
  (vertico-mode 1)
  t)

;; In a "presentation" profile, Elle rewrites to:
(progn
  (vertico-mode 1)
  (setq vertico-count 20)
  (setq vertico-resize t)
  t)
```

The user declares one config, but Elle specializes it per-profile. This works
because bodies are data, not strings—Elle can splice, filter, and augment
individual forms.

A simpler version: **conditional body pruning**. If the user marks certain
forms with a recognizable pattern (like a comment or a wrapper), Elle can
strip them in specific boot modes:

```elisp
(config-unit! org
  :config
  ;; Always:
  (setq org-directory "~/org")
  ;; Heavy, skip in minimal:
  (require 'org-roam)
  (org-roam-mode 1))
```

Elle could recognize `(require 'org-roam)` + `(org-roam-mode 1)` as a
heavyweight block and skip it in a "fast boot" profile.

**What this enables:**
- Multiple Emacs personalities from one config.el.
- "Fast boot" mode that strips heavy config automatically.
- Per-machine specialization (laptop vs desktop, GUI vs terminal).

**What it requires:**
- A profile declaration surface (could be a boot-context field).
- Body transformation rules per profile.
- The existing `:eval` payload path already supports arbitrary body forms.

---

## 7. Structural Config Linting

Beyond dependency inference and conflict detection, Elle can implement a
**structural linter** for common Emacs configuration mistakes:

| Pattern | Lint |
|---------|------|
| `(setq package-name-mode t)` | "Did you mean `(package-name-mode 1)`? `setq` on a minor mode variable doesn't activate the mode." |
| `(global-set-key (kbd "C-x C-f") 'find-file)` | "This rebinds `C-x C-f` to its default. Intentional?" |
| `(add-hook 'after-init-hook ...)` | "This runs after init, but Hypervisor already handles startup ordering. Consider removing the hook wrapper." |
| `(require 'evil)` inside body | "This blocks startup. Consider adding `:requires (evil)` so Hypervisor can manage the dependency." |
| `(load-file "/path/to/file.el")` | "Direct `load-file` bypasses Hypervisor. Consider a separate config-unit." |
| `(eval-after-load ...)` | "Deprecated. Use `with-eval-after-load` instead." |
| `(setq foo bar)` where `foo` is `defcustom` | "Consider `customize-set-variable` for `defcustom` variables to trigger setters." |

None of this requires executing the code. It's pure structural pattern matching
on the body forms that Elle already holds.

**What this enables:**
- Catch common mistakes before they hit the Emacs runtime.
- Educational: teach users better Emacs configuration patterns.
- CI-runnable config validation without starting Emacs.

**What it requires:**
- A lint rule registry (list of pattern → message pairs).
- A body walker that checks each form against the registry.
- Report integration with the existing [emacs-hypervisor-report.el](file:///Users/randall/projects/emacs-hypervisor/elle/runtime-forms/emacs-hypervisor-report.el).

---

## 8. Declarative Config Surface Compiled To Elisp Bodies

The most ambitious possibility: because the body is structured data that Elle
transforms before sending to Emacs, the user doesn't have to write Elisp at
all. Elle could accept a higher-level declarative surface and **compile it
down** to Elisp bodies:

```lisp
(config-unit! magit
  :requires (magit)
  :config
  (:keybindings
    (("C-x g" . magit-status)
     ("C-x M-g" . magit-dispatch)))
  (:hooks
    ((git-commit-setup-hook . git-commit-turn-on-flyspell)))
  (:variables
    ((magit-display-buffer-function . magit-display-buffer-same-window-except-diff-v1))))
```

Elle compiles this to:

```elisp
(progn
  (keymap-global-set "C-x g" #'magit-status)
  (keymap-global-set "C-x M-g" #'magit-dispatch)
  (add-hook 'git-commit-setup-hook #'git-commit-turn-on-flyspell)
  (setq magit-display-buffer-function
        #'magit-display-buffer-same-window-except-diff-v1)
  t)
```

The declarative surface is *fully* analyzable—no pattern matching needed.
Conflicts, dependencies, effects, and cleanup are all trivially derivable from
the declaration structure. The raw Elisp escape hatch (`:config` with actual
code) remains for anything the declarative surface can't express.

This is the ultimate form of the Lisp-to-Lisp advantage: the config is
structured data at every layer. Emacs Lisp is the *compilation target*, not
the *authoring language*.

**What this enables:**
- Perfect analysis, conflict detection, and cleanup for declarative config.
- Simpler config for 90% of use cases.
- Migration tooling: analyze existing Elisp bodies and suggest declarative
  equivalents.

**What it requires:**
- A declarative config surface definition.
- A compiler from declarations to Elisp body forms.
- Fallback to raw Elisp for escape hatches.

---

## 9. Live Config Instrumentation And Profiling

Because Elle wraps each unit body before sending it, it can **instrument
individual forms** without the user adding any profiling code:

```elisp
;; Original body:
(progn
  (setq vertico-count 10)
  (vertico-mode 1)
  t)

;; Elle-instrumented body:
(progn
  (emacs-hypervisor--instrument "vertico" 0 '(setq vertico-count 10)
    (setq vertico-count 10))
  (emacs-hypervisor--instrument "vertico" 1 '(vertico-mode 1)
    (vertico-mode 1))
  t)
```

The `--instrument` wrapper can capture:
- Wall time for each form.
- Whether the form signaled.
- What global state the form mutated (by snapshotting before/after).

This gives **per-form profiling** of config startup, not just per-unit timing.
The user can see that `(vertico-mode 1)` takes 200ms while the `setq` is
instant, without adding any measurement code themselves.

Combined with the existing benchmark module in
[elle/benchmark.lisp](file:///Users/randall/projects/emacs-hypervisor/elle/benchmark.lisp),
this creates a complete startup performance picture from individual form
timings up to session totals.

**What this enables:**
- "Which exact form in my org config is slow?" answered without manual profiling.
- Automatic detection of startup bottlenecks at form granularity.
- Before/after performance comparison when a unit body changes.

**What it requires:**
- A body-wrapping pass that inserts instrumentation around each top-level form.
- An `emacs-hypervisor--instrument` helper in the unit runtime.
- Report integration for per-form timing data.

---

## 10. Config-Aware Completion And Documentation

Because Elle holds all unit bodies as structured data, it can generate
**config-aware documentation** that no existing tool provides:

- "Which config unit sets `vertico-count`?" → search all bodies for
  `(setq vertico-count ...)`.
- "What hooks does my config install on `after-init-hook`?" → search all
  bodies for `(add-hook 'after-init-hook ...)`.
- "Show me every keybinding my config defines" → extract all `define-key`,
  `keymap-set`, `global-set-key` forms across all units.

This is a **config-level `describe-*` family**: not "what does this symbol
do in Emacs" but "what does my config do with this symbol."

As a completion source, this feeds into Emacs introspection. As an export,
it generates a human-readable "here's what my config does" document
automatically.

**What this enables:**
- Self-documenting config that stays accurate as bodies change.
- "Explain my config" as a first-class command.
- Config search: find every unit that touches a given symbol.

**What it requires:**
- Body indexing: a reverse map from symbol → (unit, form-path).
- A query surface (Emacs command or Elle CLI).

---

## Ordering By Implementation Feasibility

From easiest to hardest, building on what exists today:

| # | Feature | Builds On |
|---|---------|-----------|
| 7 | Structural Config Linting | Body walker only, no new runtime |
| 10 | Config-Aware Completion/Docs | Body walker + indexing |
| 2 | Cross-Unit Interference | Body portraits (planned) |
| 4 | Body-Aware Lazy Deferral | Body portraits + planning changes |
| 9 | Live Instrumentation | Body wrapping + benchmark module |
| 3 | Provenance / Time-Travel | Persistent store + reload diffs |
| 1 | Speculative Execution | Body portraits + snapshot runtime |
| 5 | Synthetic Lexical Scopes | Body analysis + rewrite pass |
| 6 | Profile Specialization | Body transformation + boot context |
| 8 | Declarative Config Surface | New authoring surface + compiler |

The first three are essentially "more analysis of data Elle already holds."
The middle three are "new runtime helpers that use the analysis."
The last two are "new authoring surfaces that compile into the existing path."
