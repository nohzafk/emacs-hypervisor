# Selective Reload And Effect-Aware Reload

Two related reload features wired together by
`emacs-hypervisor-reload-config`.

Selective reload applies only the `config-unit!` declarations that changed
when a user edits `config.org` or `config.el` and reloads.

Effect-aware reload cleans up the previous version of a changed or removed
unit for recognized repeated operations, avoiding duplicate hooks, stale
advice, and reload drift.

The supported effect set is deliberately narrow. Hypervisor currently supports
only `add-hook` and `advice-add` cleanup. Other side effects remain opaque.

## Design

This is not rollback. Arbitrary Elisp cannot be safely undone. The valuable
behavior is pre-apply cleanup for recognized effects.

> I can edit my Emacs config while Emacs is running, reload through
> Hypervisor, and it will apply only the config units that changed. For
> recognized repeated operations, Hypervisor cleans up the previous version
> before applying or removing a unit, avoiding duplicate hooks, stale advice,
> and reload drift.

## Data Model

### Unit Identity

A config unit is identified by its exported `:name`.

The reload command captures previous units before calling
`emacs-hypervisor-reset-declarations`, then captures current units after
tangling/loading `config.org` or loading `config.el`.

```elisp
(emacs-hypervisor-export-config-units)
```

### Unit Diff

Units are compared with `equal` over the canonical exported entry:

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
 :action ACTION          ; :unchanged | :new | :changed | :removed
 :previous PREVIOUS-ENTRY
 :current CURRENT-ENTRY)
```

### Cleanup Effect Records

Cleanup effect records describe cleanup Hypervisor performs before a changed or
removed unit is applied. The registry-backed path records richer runtime effect
records; see [effect-registry.md](effect-registry.md).

```elisp
(:kind KIND
 :unit NAME
 :source-form FORM
 :cleanup-form FORM
 :supported SUPPORTED
 :reason REASON)
```

Supported effects:

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

Unsupported forms are reported as opaque:

```elisp
(:kind :opaque
 :unit NAME
 :source-form FORM
 :cleanup-form nil
 :supported nil
 :reason :unsupported-form)
```

The recognizer supports hook and advice targets that are literal or computed at
runtime. It rewrites supported calls in executed body positions, including
`progn`, `let`, `let*`, `when`, `unless`, `if`, `cond`, `dolist`, and
`dotimes`.

The recognizer does not rewrite quoted data, function literals, lambda bodies,
function definitions, unknown macro/helper-call bodies, timers, processes, or
package manager side effects. Local hooks with non-nil `LOCAL` are not tracked.

### Reload Report

`emacs-hypervisor-last-soft-reload-report` payload:

```elisp
(:kind :config-reload
 :new-packages NEW-PACKAGES
 :summary (:applied N :removed N :skipped-unchanged N :cleaned N :failed N)
 :reports ((:name NAME :status STATUS :reason REASON
            :action ACTION :cleanup CLEANUP-SUMMARY :details DETAILS) ...)
 :note NOTE)
```

Example user message:

```text
[Hypervisor] Reload: 3 changed applied, 44 unchanged skipped,
2 old effects cleaned.
```

## API

### User-Facing Command

```elisp
(emacs-hypervisor-reload-config)
```

- Rejects reload while a Hypervisor session is actively starting/running.
- Reloads env vars from the configured env file.
- Reloads declarations from `config.org` or `config.el`.
- Warns when new package declarations require restart.
- Diffs previous and current config units.
- Skips unchanged units.
- Cleans up recognized old effects for changed and removed units.
- Applies only new and changed units.
- Reports opaque effects without treating opacity as a restart recommendation.

### Internal Modules

Selective reload in
`elle/runtime-forms/emacs-hypervisor-selective-reload.el`:

```elisp
(emacs-hypervisor-selective-reload-diff-units previous-units current-units)
(emacs-hypervisor-selective-reload-reports
 diffs make-report run-current remove-previous)
```

Effect-aware reload in
`elle/runtime-forms/emacs-hypervisor-effect-aware-reload.el`:

```elisp
(emacs-hypervisor-effect-aware-reload-unit-effects name entry)
(emacs-hypervisor-effect-aware-reload-cleanup-form effect)
(emacs-hypervisor-effect-aware-reload-cleanup-unit name entry)
(emacs-hypervisor-effect-aware-reload-cleanup-count cleanup)
```

Effect registry in
`elle/runtime-forms/emacs-hypervisor-effect-registry.el`:

```elisp
(emacs-hypervisor-effect-registry-record effect)
(emacs-hypervisor-effect-registry-effects-for-unit unit)
(emacs-hypervisor-effect-registry-retract effect)
(emacs-hypervisor-effect-registry-retract-unit unit)
(emacs-hypervisor-register-hook-effect
 :unit unit :target hook :function function :depth depth :local local)
(emacs-hypervisor-register-advice-effect
 :unit unit :target target :where where :function function)
```

`elle/runtime-forms/emacs-hypervisor-compose.el` wires both into
`emacs-hypervisor-reload-config`.

### Effect Recognition

Hook support:

```elisp
(add-hook 'HOOK FUNCTION)
(add-hook 'HOOK FUNCTION DEPTH)
(add-hook 'HOOK FUNCTION DEPTH nil)
```

Advice support:

```elisp
(advice-add 'TARGET WHERE FUNCTION)
```

`FUNCTION` may be a symbol, function-quoted symbol, anonymous `(lambda ...)`,
or anonymous `#'(lambda ...)`.

Anonymous lambdas are rewritten to a generated internal function name derived
from the unit name, effect kind, concrete runtime target, and a hash of the
function value. Cleanup uses the previous registry record, then removes the
hook or advice by symbol.

Unsupported source shapes outside the rewritten body positions are reported as
opaque.

## Limitations

- No general rollback for arbitrary Elisp.
- No persistent effect tracking across Emacs restarts.
- Does not reverse file, network, process, timer, buffer-local, or
  package-manager side effects.
- Hook and advice cleanup only; keybindings, variables, themes, and faces are
  not yet tracked.
- The registry contains hook and advice records only. Other effect kinds are
  future vocabulary, not supported behavior.
