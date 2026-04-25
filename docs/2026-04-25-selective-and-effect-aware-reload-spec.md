# Spec - Selective Reload And Effect-Aware Reload

This spec covers two related reload features that are wired together by
`emacs-hypervisor-reload-config`.

Selective reload lets a user edit `config.el` while Emacs is running, ask
Hypervisor to reload it, and have Hypervisor apply only the `config-unit!`
declarations that changed.

Effect-aware reload cleans up the previous version of a changed or removed
unit for common repeated operations. The goal is to avoid duplicate hooks,
stale advice, and reload drift without pretending arbitrary Elisp is
transactional.

**Attention Conservation Notice**

For: Next-session implementer and reviewers of reload/runtime behavior

What: Implementation contract for selective reload and effect-aware reload

Action: Maintain the selective reload and effect-aware reload implementation

Skip if: You are not changing `emacs-hypervisor-reload-config`

## 1) Scope

In scope:

- Keep `emacs-hypervisor-reload-config` as the user-facing command.
- Detect new, changed, unchanged, and removed `config-unit!` declarations.
- Skip unchanged units during reload.
- Apply new and changed units only.
- For changed and removed units, clean up recognized effects from the previous
  unit body before applying the new body.
- Preserve existing preflight checks for env vars, executables, required
  features, new packages, `:after` ordering, cycles, and blocked units.
- Store a clear reload report in `emacs-hypervisor-last-soft-reload-report`.
- Tell the user what changed, what was skipped, what was cleaned up, and what
  still recommends a restart.

Out of scope:

- General rollback for arbitrary Elisp.
- Full static analysis of Elisp.
- Persistent effect tracking across Emacs restarts.
- Reversing file, network, process, timer, buffer-local, or package-manager
  side effects.
- Moving reload policy into a resident Emacs policy engine.
- Rewriting config bodies before evaluation.

The first implementation should support hooks and advice cleanup. The data
model should leave room for keybindings, variables, themes, and faces later.

## 2) Design Decisions

This spec extends the current Lisp-to-Lisp path documented in `README.md` and
`LISP-TO-LISP-FUTURES.md`.

The product promise is:

> I can edit my Emacs config while Emacs is running, reload through
> Hypervisor, and it will apply only the config units that changed. For
> recognized repeated operations, Hypervisor cleans up the previous version
> before applying or removing a unit, avoiding duplicate hooks, stale advice,
> and reload drift.

This is not rollback. Most config changes do not fail in a useful
transactional sense, and arbitrary Elisp cannot be safely undone. The valuable
behavior is pre-apply cleanup for recognized effects.

The current soft reload in
`elle/runtime-forms/emacs-hypervisor-compose.el` reruns config units on top of
the existing Emacs state and explicitly reports that old config is not
unloaded. These features replace that behavior with selective reload plus
tracked cleanup for a conservative set of effects.

## 3) Data Model

### Unit Identity

A config unit is identified by its exported `:name`.

The reload command must capture previous units before calling
`emacs-hypervisor-reset-declarations`, then capture current units after
loading `config.el`.

Previous state source:

```elisp
(emacs-hypervisor-export-config-units)
```

Current state source after reload:

```elisp
(emacs-hypervisor-export-config-units)
```

### Unit Diff

Compare units with `equal` over the canonical exported entry:

```elisp
(:name NAME
 :requires REQUIRES
 :after AFTER
 :env ENV
 :executable EXECUTABLE
 :body BODY)
```

Diff action shape:

```elisp
(:name NAME
 :action ACTION
 :previous PREVIOUS-ENTRY
 :current CURRENT-ENTRY)
```

`ACTION` values:

- `:unchanged`
- `:new`
- `:changed`
- `:removed`

### Effect Records

Effect records describe cleanup Hypervisor knows how to perform before a
changed or removed unit is applied.

MVP effect shape:

```elisp
(:kind KIND
 :unit NAME
 :source-form FORM
 :cleanup-form FORM
 :supported SUPPORTED
 :reason REASON)
```

MVP supported effects:

```elisp
(:kind :hook
 :source-form (add-hook 'HOOK FUNCTION)
 :cleanup-form (remove-hook 'HOOK FUNCTION)
 :supported t)

(:kind :advice
 :source-form (advice-add 'TARGET WHERE FUNCTION)
 :cleanup-form (advice-remove 'TARGET FUNCTION)
 :supported t)
```

Unsupported effect shape:

```elisp
(:kind :opaque
 :unit NAME
 :source-form FORM
 :cleanup-form nil
 :supported nil
 :reason :unsupported-form)
```

The first recognizer should only support literal global hooks and literal
advice targets. It should not try to clean up local hooks, computed hook names,
computed advice targets, anonymous closures, timers, processes, or package
manager side effects.

### Reload Report

`emacs-hypervisor-last-soft-reload-report` should keep its role as the latest
reload report, but the payload should use the new kind:

```elisp
(:kind :config-reload
 :new-packages NEW-PACKAGES
 :summary SUMMARY
 :reports REPORTS
 :note NOTE)
```

Summary shape:

```elisp
(:applied APPLIED
 :removed REMOVED
 :skipped-unchanged SKIPPED
 :cleaned CLEANED
 :failed FAILED)
```

Per-unit report shape:

```elisp
(:name NAME
 :status STATUS
 :reason REASON
 :action ACTION
 :cleanup CLEANUP-SUMMARY
 :details DETAILS)
```

Example user message:

```text
[Hypervisor] Reload: 3 changed applied, 44 unchanged skipped,
2 old effects cleaned.
```

## 4) API Surface

### User-Facing Command

Keep the existing command:

```elisp
(emacs-hypervisor-reload-config)
```

The command should still:

- reject reload while a Hypervisor session is actively starting/running
- reload env vars from the configured env file
- reload declarations from `config.el`
- warn when new package declarations require restart

The command should now:

- diff previous and current config units
- skip unchanged units
- clean up recognized old effects for changed and removed units
- apply only new and changed units
- report opaque removed or changed effects without treating opacity as a
  restart recommendation

No new interactive command is required for the first implementation.

### Internal Modules

Selective reload lives in
`elle/runtime-forms/emacs-hypervisor-selective-reload.el`:

```elisp
(emacs-hypervisor-selective-reload-diff-units previous-units current-units)
(emacs-hypervisor-selective-reload-reports
 diffs make-report run-current remove-previous)
```

Effect-aware reload lives in
`elle/runtime-forms/emacs-hypervisor-effect-aware-reload.el`:

```elisp
(emacs-hypervisor-effect-aware-reload-unit-effects name entry)
(emacs-hypervisor-effect-aware-reload-cleanup-form effect)
(emacs-hypervisor-effect-aware-reload-cleanup-unit name entry)
(emacs-hypervisor-effect-aware-reload-cleanup-count cleanup)
```

`elle/runtime-forms/emacs-hypervisor-compose.el` wires both features into the
user-facing `emacs-hypervisor-reload-config` command.

### Effect Recognition

Initial hook support:

```elisp
(add-hook 'HOOK FUNCTION)
(add-hook 'HOOK FUNCTION DEPTH)
(add-hook 'HOOK FUNCTION DEPTH nil)
```

Cleanup:

```elisp
(remove-hook 'HOOK FUNCTION)
```

Initial advice support:

```elisp
(advice-add 'TARGET WHERE FUNCTION)
```

Cleanup:

```elisp
(advice-remove 'TARGET FUNCTION)
```

`FUNCTION` should be a symbol or function-quoted symbol in the MVP. Other
function shapes should be reported as opaque.

## 5) Authorization And Permissions

This feature is local to the running Emacs session.

It does not add network access, filesystem writes, subprocess execution, or a
new trust boundary. It evaluates the same user config that the current reload
path already evaluates.

The trust rule remains:

- Elle and the reload helpers decide what to plan and report.
- The trusted Emacs eval surface executes structured Lisp forms.
- Unknown forms are preserved, not rewritten.

## 6) Migration Plan

1. Add unit diff helpers.

   Backout: keep calling the current `emacs-hypervisor--soft-reload-unit-reports`.

2. Add effect recognition for previous unit bodies.

   Backout: report all effects as opaque and keep selective reload.

3. Add cleanup execution for supported hook and advice effects.

   Backout: skip cleanup execution and keep the report-only recognizer.

4. Integrate selective reload into `emacs-hypervisor-reload-config`.

   Backout: keep a feature flag or local branch point that restores the
   current rerun-all behavior.

5. Update report and message text.

   Backout: preserve the old summary shape while keeping selective execution.

No data migration is required. This is runtime behavior inside the live Emacs
session.

## 7) Test Plan

Add ERT coverage under `tests/elisp/emacs-hypervisor-bootstrap-test.el` or a
new focused reload test file.

Required tests:

- unchanged unit is skipped and not evaluated again
- changed unit is evaluated
- new unit is evaluated
- removed unit is not evaluated
- previous `add-hook` effect is cleaned before changed unit is applied
- previous `advice-add` effect is cleaned before changed unit is applied
- unsupported previous effect is reported as opaque
- pending new package still skips dependent units
- `:after` ordering still blocks units when dependencies fail
- cycle detection still reports cycles
- report summary counts applied, skipped unchanged, cleaned, and failed units

Run:

```bash
just test
```

If shared Elle modules are touched, also run:

```bash
just analyze-runtime
```

## 8) Rollout Gates

Before merging implementation:

- Existing startup tests pass.
- Existing runtime execution tests pass.
- Reload with an unchanged `config.el` reports skipped unchanged units.
- Reload after changing one hook unit removes the old hook function and adds
  the new one.
- Reload after changing one advice unit removes the old advice function and
  adds the new one.
- Reload still warns when new package declarations require restart.
- A live test home can run `emacs-hypervisor-reload-config` without rerunning
  every config unit.

## Next Session Checklist

Implement in this order:

1. Capture `previous-units` before reset/load in `emacs-hypervisor-reload-config`.
2. Build `previous-by-name` and `current-by-name` hash tables.
3. Produce `:new`, `:changed`, `:unchanged`, and `:removed` diff entries.
4. Add hook and advice effect recognizers for previous bodies.
5. Execute cleanup forms for supported previous effects.
6. Reuse existing preflight and `:after` scheduling for new and changed units.
7. Skip unchanged units with an explicit report entry.
8. Add report summary and user-facing message text.
9. Add ERT coverage for the diff, cleanup, selective execution, and reporting.
