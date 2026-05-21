# Reload

Two related reload features wired together by
`emacs-hypervisor-reload-config`.

**Selective reload** applies only the `config-unit!` declarations that changed
when a user edits `config.org` or `config.el` and reloads.

**Effect-aware reload** cleans up the previous version of a changed or removed
unit for recognized effects, avoiding duplicate hooks, stale advice, stale
keybindings, and reload drift.

**Attention Conservation Notice.** For contributors working on reload, effect
recognition, or runtime forms. Skip if you only need the user-facing reload
behavior — see the [README](../README.md#reload).

## Design

This is not rollback. Arbitrary Elisp cannot be safely undone. The valuable
behavior is pre-apply cleanup for recognized effects.

> I can edit my Emacs config while Emacs is running, reload through
> Hypervisor, and it will apply only the config units that changed. For
> recognized effects, Hypervisor cleans up the previous version
> before applying or removing a unit, avoiding duplicate hooks, stale advice,
> stale keybindings, and reload drift.

The supported effect set is deliberately narrow. Hypervisor currently supports
`add-hook`, `advice-add`, and keybinding cleanup. Other side effects are left
untracked. See [docs/effect-system.md](effect-system.md) for the full effect
registry contract and extension guide.

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

Cleanup uses runtime registry records created when a config unit is evaluated.
Each record stores the owning unit, concrete target, concrete function symbol,
source form, and an evaluable retract form. See
[docs/effect-system.md](effect-system.md) for the full record schema.

There is no static cleanup fallback. If a previous unit has no active registry
records, cleanup is a no-op for that unit and a restart clears any older live
state.

The recognizer supports hook, advice, and keybinding targets that are literal or
computed at runtime. It rewrites supported calls in executed body positions,
including
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

## Reload Integration

Changed and removed units clean up through registry records only. A previous
unit body without active registry records has no cleanup to run; restarting
Emacs clears any older live state.

During reload:

1. Save the previous unit's effect records.
2. Retract the previous records for changed or removed units.
3. Evaluate the current unit.
4. Record the current unit's newly applied effects.
5. Report active, retracted, and failed registry effects.

Reload logs the user-facing cleanup story as it runs:

```text
[Hypervisor] Reload started
[Hypervisor] Reload cleaned hook prog-mode-hook -> display-line-numbers-mode for project-hooks
[Hypervisor] Reload cleaned advice save-buffer :before -> delete-trailing-whitespace for save-behavior
[Hypervisor] Reload cleaned keybinding global-map C-c e -> edit-command for editing-keys
[Hypervisor] Reload re-applied unit: project-hooks
[Hypervisor] Reload: 3 changed applied, 44 unchanged skipped, 3 old effects cleaned.
```

Covered by tests:

- current selective reload tests remain green
- reload reports count registry-cleaned hook/advice/keybinding effects
- reload logs start, cleaned effects, applied units, and summary
- raw previous bodies without registry records do not synthesize cleanup

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
- Leaves untracked forms alone.

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
(emacs-hypervisor-effect-aware-reload-register-effect-spec spec)
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
```

Bundled effect kinds in `elle/runtime-forms/emacs-hypervisor-effect-kind-*.el`:

```elisp
(emacs-hypervisor-register-hook-effect
 :unit unit :target hook :function function :depth depth :local local)
(emacs-hypervisor-register-advice-effect
 :unit unit :target target :where where :function function)
(emacs-hypervisor-register-keybinding-effect
 :unit unit :operator operator :map map :map-form map-form
 :key key :definition definition)
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

Keybinding support:

```elisp
(keymap-set MAP KEY DEFINITION)
(define-key KEYMAP KEY DEFINITION)
(global-set-key KEY COMMAND)
(keymap-global-set KEY DEFINITION)
```

`FUNCTION` may be a symbol, function-quoted symbol, anonymous `(lambda ...)`,
or anonymous `#'(lambda ...)`.

Anonymous lambdas are rewritten to a generated internal function name derived
from the unit name, effect kind, concrete runtime target, and a hash of the
function value. Cleanup uses the previous registry record, then removes the
hook or advice by symbol.

Keybinding cleanup unsets the binding Hypervisor installed when it is still the
live binding. This prevents deleted or moved config from leaving stale
keybindings behind. If the live binding no longer matches the
Hypervisor-installed binding, cleanup skips the key and displays a warning
instead of clobbering the external change.

Unsupported source shapes outside the rewritten body positions are left
untracked.

## Limitations

- No general rollback for arbitrary Elisp.
- No persistent effect tracking across Emacs restarts.
- Does not reverse file, network, process, timer, buffer-local, or
  package-manager side effects.
- Variables, themes, faces, function cells, timers, and package-manager side
  effects are not yet tracked.
