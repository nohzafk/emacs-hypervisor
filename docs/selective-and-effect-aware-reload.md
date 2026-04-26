# Selective Reload And Effect-Aware Reload

Two related reload features wired together by
`emacs-hypervisor-reload-config`.

Selective reload applies only the `config-unit!` declarations that changed
when a user edits `config.org` or `config.el` and reloads.

Effect-aware reload cleans up the previous version of a changed or removed
unit for recognized repeated operations, avoiding duplicate hooks, stale
advice, and reload drift.

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

### Effect Records

Effect records describe cleanup Hypervisor performs before a changed or
removed unit is applied.

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

The recognizer supports literal global hooks and literal advice targets. It
does not clean up local hooks, computed hook names, computed advice targets,
lambdas hidden inside computed expressions, timers, processes, or package
manager side effects.

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
from the unit name, effect kind, target symbol, and a hash of the lambda form.
Cleanup derives the same name from the previous unit body, then removes the
hook or advice by symbol.

Other function shapes are reported as opaque.

## Limitations

- No general rollback for arbitrary Elisp.
- No persistent effect tracking across Emacs restarts.
- Does not reverse file, network, process, timer, buffer-local, or
  package-manager side effects.
- Hook and advice cleanup only; keybindings, variables, themes, and faces are
  not yet tracked.
