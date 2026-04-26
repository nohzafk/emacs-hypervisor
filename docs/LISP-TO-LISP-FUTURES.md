# Lisp-To-Lisp Future Directions

This note captures future feature areas unlocked by preserving config-unit
bodies as structured Lisp data across the Emacs/Elle boundary.

**Attention Conservation Notice**

For: Contributors working on config units, runtime forms, planning, reload, or reports

What: Future capabilities made possible by Lisp-to-Lisp homoiconicity

Action: Use this before extending analysis, reload, remediation, or instrumentation

Skip if: You only need current startup behavior or command usage

## Core Thesis

Emacs config is not just text to load. It is Lisp data that can stay
structured across the Emacs/Elle boundary, be reasoned about by Elle, and then
return to Emacs as executable Lisp.

The current path already avoids opaque string evaluation. The larger
opportunity is that Elle can eventually treat config units as inspectable,
annotatable, transformable program data.

This does not require a full static analyzer. The practical direction is a
conservative recognizer for common Emacs configuration forms, with unknown
forms preserved and passed through unchanged.

## Current Baseline

Today, the Lisp-to-Lisp path supports the core runtime flow:

- `config-unit!` captures the unit body as `(progn ... t)`.
- Emacs canonicalizes reader-hostile forms while preserving semantics.
- Emacs sends session data through `sexp-rpc`.
- Elle decodes metadata while preserving each unit `:body` as raw code data.
- Elle emits `(emacs-hypervisor-runtime-run-unit NAME 'BODY 'REQUIRES)`.
- Emacs evaluates the structured body directly.

This gives Elle enough structure for current planning and reporting. The next
step is to use that same structure for deeper inspection and safer runtime
behavior.

## Config Body Portraits

Elle could generate a structural portrait for each `config-unit!` body.

Useful signals include:

- variables written by `setq`, `setq-default`, and `customize-set-variable`
- hooks touched by `add-hook` and `remove-hook`
- keymaps touched by `define-key`, `keymap-set`, and related forms
- advice installed by `advice-add`
- features loaded by `require`
- package-local symbols referenced by the body
- dynamic or high-risk forms such as `eval`, `load-file`, `shell-command`, or
  process creation

The output should be descriptive first. For example, a report could say that
unit `magit` mutates keymaps, installs hooks, and depends on the `magit`
feature.

## Dependency Inference

Elle could infer soft dependencies from the actual body forms, then compare
them with declared `:requires` and `:after` metadata.

Examples of useful inference:

- `(require 'consult)` implies a feature dependency on `consult`.
- `(with-eval-after-load 'magit ...)` implies a deferred relationship with `magit`.
- `(define-key magit-mode-map ...)` suggests that `magit` may need to be loaded first.
- `(add-hook 'magit-mode-hook ...)` may not require eager loading and could
  remain early.

Initial behavior should be advisory. Elle can report missing, unnecessary, or
over-eager declarations without changing execution behavior.

## Form-Addressed Failure Reports

Runtime failures could point to the specific subform that failed, not only the
unit name.

A richer failure payload could include:

- unit name
- form path inside the body
- failing subform
- error symbol and message
- nearest recognized effect category, such as keymap mutation or hook setup

This would let reports explain failures in config terms. For example, a
failure in `(define-key magit-mode-map ...)` could be reported as a keymap
mutation before the relevant package feature was available.

## Targeted Rewrites

Elle could rewrite known safe patterns before sending a body back to Emacs.

Candidate rewrites include:

- wrapping package-local keymap mutations in `with-eval-after-load`
- adding instrumentation around individual top-level body forms
- splitting a mixed unit into pre-load-safe and post-load sections
- normalizing equivalent config forms into one internal representation

Rewrites should be explicit planned artifacts, not invisible mutation. Reports
should show the original body, the recognized pattern, and the emitted form
when a rewrite occurs.

## Live Reload With Structural Diffs

Soft reload can eventually use structural diffs instead of rerunning every
unit on top of existing Emacs state.

Implementation target:
`docs/2026-04-25-selective-and-effect-aware-reload-spec.md`.

Possible diff outcomes:

- unchanged unit: skip
- changed keybinding: restore old binding and apply the new one
- changed hook: remove old hook target and add the new one
- changed advice: remove old advice and install the new advice
- changed theme setup: disable replaced themes before loading new themes
- changed variable assignment: restore or update tracked values

This requires effect tracking, but the Lisp-to-Lisp body representation makes
the comparison possible.

## Undo And Transaction Support

Some Emacs configuration effects have practical inverse operations.

Examples:

- `add-hook` can pair with `remove-hook`.
- `advice-add` can pair with `advice-remove`.
- `define-key` can snapshot and restore the previous binding.
- `setq` can snapshot and restore the previous value.
- `enable-theme` can pair with `disable-theme`.

Elle could generate wrappers that snapshot known state before evaluating a
unit. That would make selected config units partially transactional without
requiring Emacs to become a resident policy engine.

## Policy And Capability Checks

Because config bodies remain structured, Elle can classify what a unit is
allowed to do before Emacs evaluates it.

Possible categories:

- pure declaration
- variable setup
- hook registration
- keymap mutation
- package loading
- file access
- process creation
- dynamic evaluation

The first useful version can be a report-only capability summary. Later
versions could enforce policy for specific boot modes, such as restricted
startup, CI validation, or interactive remediation.

## Interactive Remediation

Failure reports and body portraits can support guided repair.

Potential remediation actions:

- suggest adding `:requires` when a package-local symbol fails
- suggest moving a form behind `with-eval-after-load`
- suggest splitting a large unit when it mixes unrelated effects
- suggest removing an eager `:requires` when the body only registers hooks or
  autoload-safe bindings
- generate a minimal patch for clear, conservative fixes

The important boundary is that suggestions should be evidence-backed. Elle
should prefer "this form looks like a package-local keymap mutation" over
claiming full semantic certainty.

## Design Constraints

Elisp is dynamic, so the system should not pretend to understand every form.

Important constraints:

- Preserve unknown forms unchanged.
- Prefer warnings before rewrites.
- Make every rewrite visible in reports.
- Keep the trusted Emacs kernel small.
- Keep resident policy in Elle, not in long-lived Emacs helpers.
- Treat source code as ground truth and generated forms as runtime artifacts.

The near-term opportunity is not full program verification. It is better
startup intelligence, more precise reports, safer reload, and clearer repair
paths by using the structure that Lisp already gives us.
