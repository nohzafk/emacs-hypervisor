# Effect Registry Spec

The effect registry is the runtime data model for reloadable Emacs side
effects. Each effect is represented as a first-class record with enough
identity, provenance, and retract information to clean it up later.

**Attention Conservation Notice**

For: Contributors working on reload, effect inference, or runtime forms

What: Hook, advice, and keybinding effect record schema and registry semantics for reload
cleanup

Action: Use this as the contract before changing supported cleanup or adding
new effect kinds

Skip if: You only need the current user-facing reload behavior

## Scope

This spec defines the effect record shape and registry semantics for the
registry-backed implementation. The implementation scope is intentionally small:

- `add-hook` effects
- `advice-add` effects
- keybinding effects from `keymap-set`, `define-key`, `global-set-key`, and
  `keymap-global-set`
- anonymous lambda naming for those two effect kinds
- runtime registration for loop/computed hook and advice targets in supported
  body forms

It does not implement variable, face, timer, process, package, or general
rollback support.

## Effect Record

An effect record is an Emacs Lisp plist.

```elisp
(:schema-version 1
 :id "hook/prog-mode-hook/line-numbers"
 :instance-id "reload-12/effect-4"
 :unit "editing"
 :kind :hook
 :target prog-mode-hook
 :function emacs-hypervisor--hook/prog-mode-hook/line-numbers
 :source (:file "config.org" :line 14 :form-index 2)
 :apply (add-hook 'prog-mode-hook
                  #'emacs-hypervisor--hook/prog-mode-hook/line-numbers)
 :retract (remove-hook 'prog-mode-hook
                       #'emacs-hypervisor--hook/prog-mode-hook/line-numbers)
 :body-hash "b7c7b7bb40"
 :reversible t
 :persistent nil
 :status :active
 :metadata nil)
```

### Required Fields

| Field | Meaning |
|---|---|
| `:schema-version` | Effect record schema version. Starts at `1`. |
| `:id` | Stable logical identity for the effect when one can be derived. Use strings for generated IDs to avoid unbounded symbol interning. |
| `:instance-id` | Concrete runtime identity for this installed effect. This may change every reload. |
| `:unit` | Owning `config-unit!` name. |
| `:kind` | Effect kind. The bundled effect kinds are `:hook`, `:advice`, and `:keybinding`. |
| `:target` | Runtime target that was mutated. For hooks this is the hook symbol; for advice this is the advised symbol; for keybindings this includes the map expression and key. |
| `:source` | Best available source location or form provenance. |
| `:apply` | Form, thunk, or structured operation that applied the effect. |
| `:retract` | Form, thunk, or structured operation that reverses the effect. May be nil for irreversible effects. |
| `:body-hash` | Hash of the user body or normalized operation body. |
| `:reversible` | Non-nil when `:retract` is expected to perform supported cleanup. |
| `:persistent` | Non-nil when the effect intentionally survives reload cleanup. |
| `:status` | Runtime state, usually `:active`, `:retracted`, `:failed`, or `:opaque`. |
| `:metadata` | Extra kind-specific fields. |

### Identity Rules

`:id` is the logical identity. It should be stable across reloads when the
same user-level effect is still present. Static top-level effects can derive it
from:

- unit name
- effect kind
- target
- user-provided id, when available
- source location, when available
- body hash

`:instance-id` is the concrete installed identity. It exists because one source
form can install multiple effects at runtime:

```elisp
(dolist (hook '(text-mode-hook prog-mode-hook))
  (add-hook hook
            (lambda () (setq-local fill-column 80))))
```

The two loop iterations may share a source location and body hash, but they are
two separate runtime effects with different concrete targets. Cleanup should use
the previous registry's `:instance-id`, `:target`, and `:retract`, not try to
reconstruct the old effect from source.

## Registry State

The runtime keeps an ordered list of effect records.

```elisp
emacs-hypervisor-effect-registry-current
```

The registry records effects in application order. Cleanup retracts records in
reverse application order, so dependent effects unwind safely.

During reload:

1. Save the previous unit's effect records.
2. Retract the previous records for changed or removed units.
3. Evaluate the current unit.
4. Record the current unit's newly applied effects.
5. Report active, retracted, and failed registry effects.

The registry is session-scoped. It does not persist across Emacs restarts.

## Supported Effect Kinds

The current registry supports the bundled effect kinds handled by effect-aware
reload.

| Source form | Effect kind | Retract strategy |
|---|---|---|
| `add-hook` | `:hook` | `remove-hook` |
| `advice-add` | `:advice` | `advice-remove` |
| `keymap-set`, `define-key`, `global-set-key`, `keymap-global-set` | `:keybinding` | Unset the Hypervisor-owned binding when it is still current |

Other effect kinds remain out of scope for this implementation.

## Runtime Hook And Advice Registration

The current implementation rewrites supported `add-hook` and `advice-add`
calls to runtime registration helpers. Runtime registration is what lets loop
iterations and computed targets produce concrete cleanup records.

The hook helper has this shape:

```elisp
(emacs-hypervisor-register-hook-effect
 :unit "editing-hooks"
 :target hook
 :function (lambda () (setq-local fill-column 80))
 :depth nil
 :local nil
 :source '(:file "config.org" :line 14 :form-index 0))
```

At runtime the helper receives actual values from the executed form:

- `:target` is the concrete hook symbol.
- `:function` is the actual symbol or lexical closure.
- `:depth` and `:local` are the concrete add-hook arguments.

For anonymous functions, the helper:

1. Generate an owned symbol for this concrete effect instance.
2. Store the closure in that symbol's function cell with `fset`.
3. Call `add-hook` with the owned symbol.
4. Record a `:hook` effect with a concrete `remove-hook` retract form.

Advice registration follows the same pattern, using `advice-add` and
`advice-remove`.

## Runtime Keybinding Registration

Keybinding helpers record the binding Hypervisor installed. The retract path
unsets that binding when it is still current, which prevents deleted or moved
config from leaving stale keybindings behind.

Supported source forms normalize into one helper:

```elisp
(emacs-hypervisor-register-keybinding-effect
 :unit "editing-keys"
 :operator 'keymap-set
 :map global-map
 :map-form 'global-map
 :key "C-c e"
 :definition #'some-command
 :source '(:form (keymap-set global-map "C-c e" #'some-command)))
```

The register function stores the exact runtime keymap object in a session-local
state table so retracting does not serialize large keymaps into the effect
record. Before cleanup it checks whether the current binding still matches the
Hypervisor-installed binding. If another package or user action changed the
binding, cleanup is skipped and a warning is displayed instead of clobbering the
external change.

## Future Effect Vocabulary

The registry schema is intended to grow, but these effect kinds are future work.
They should not be treated as supported until a later spec or implementation
adds them.

| Source form | Future effect kind | Possible retract strategy |
|---|---|---|
| `setq` | `:variable` | Restore previous value |
| `set-face-attribute` | `:face` | Restore previous attributes |
| `add-to-list` | `:list-mutation` | Remove owned element |
| `run-with-timer` | `:timer` | `cancel-timer` |
| `defun`, `fset` | `:function-def` | Restore old function cell |
| Package install | `:package` | Mark persistent or irreversible |
| Process start | `:process` | Kill process or hand to supervisor |

## Opaque And Irreversible Effects

Unsupported effects can get opaque records when enough provenance is available.

```elisp
(:schema-version 1
 :id "opaque/editing/3"
 :instance-id "reload-12/effect-9"
 :unit "editing"
 :kind :opaque
 :target nil
 :source (:file "config.org" :line 31 :form-index 3)
 :apply FORM
 :retract nil
 :body-hash "9fb402ac13"
 :reversible nil
 :persistent nil
 :status :opaque
 :metadata (:reason :unsupported-form))
```

Irreversible effects use `:reversible nil`. Effects that intentionally survive
reload use `:persistent t`.

## Future Inference

This data shape gives effect inference a stable output target. Static analysis
can infer records before evaluation. Runtime helpers can produce records from
actual execution. Both paths should converge on the same plist schema.

The important boundary is that cleanup uses concrete previous records. Static
source analysis can improve planning and previews, but it should not be required
to reconstruct a dynamic loop effect after the fact.

## Implemented Runtime Path

### Registry Module

`elle/runtime-forms/emacs-hypervisor-effect-registry.el` provides the generic
record/retract API:

```elisp
(emacs-hypervisor-effect-registry-record EFFECT)
(emacs-hypervisor-effect-registry-effects-for-unit UNIT)
(emacs-hypervisor-effect-registry-retract EFFECT)
(emacs-hypervisor-effect-registry-retract-unit UNIT)
(emacs-hypervisor-effect-registry-install-function-effect ...)
```

Effect-kind modules provide concrete installers. The default supported modules
are:

- `emacs-hypervisor-effect-kind-hook.el`
- `emacs-hypervisor-effect-kind-advice.el`
- `emacs-hypervisor-effect-kind-keybinding.el`

The registry stores active records in application order and retracts them in
reverse order.

Covered by tests:

- records preserve required plist fields
- records can be filtered by unit
- retract skips irreversible or opaque records
- retract runs in reverse application order

### Hook, Advice, And Keybinding Registration Helpers

The bundled effect kinds use explicit helpers:

```elisp
(emacs-hypervisor-register-hook-effect
 :unit UNIT :target HOOK :function FUNCTION :depth DEPTH :local LOCAL
 :source SOURCE)

(emacs-hypervisor-register-advice-effect
 :unit UNIT :target TARGET :where WHERE :function FUNCTION
 :source SOURCE)

(emacs-hypervisor-register-keybinding-effect
 :unit UNIT :operator OPERATOR :map MAP :map-form MAP-FORM
 :key KEY :definition DEFINITION :source SOURCE)
```

For anonymous functions, generate an owned symbol, store the actual closure with
`fset`, then use that symbol in `add-hook` or `advice-add`. Record the concrete
`remove-hook` or `advice-remove` retract form.

Covered by tests:

- symbol hook functions are added, recorded, and removed
- lambda hook functions preserve closures and are removed by generated symbol
- symbol advice functions are added, recorded, and removed
- lambda advice functions preserve closures and are removed by generated symbol
- keybindings are added, recorded, unset when stale, and guarded against
  external divergence

### Supported Call Rewrites

The normalizer rewrites supported hook, advice, and keybinding calls to
registration helpers inside simple executed forms, including
`progn`, `let`, `let*`, `when`, `unless`, `if`, `cond`, `dolist`, and `dotimes`.

The normalizer does not rewrite inside quoted data, `function` forms that are
not the supported function argument, `lambda`, `defun`, or unknown macro bodies
in the first pass.

Covered by tests:

- existing top-level hook/advice/keybinding cleanup still passes
- `dolist` over literal hooks or keybindings records one concrete effect per
  iteration
- loop-created lambdas preserve per-iteration lexical captures
- changed units retract previous loop effects before applying current effects

### Reload Integration

Changed and removed units clean up through registry records only. A previous
unit body without active registry records has no cleanup to run; restarting
Emacs clears any older live state.

Reload logs the user-facing cleanup story as it runs:

```text
[Hypervisor] Reload started
[Hypervisor] Reload cleaned hook prog-mode-hook -> display-line-numbers-mode for project-hooks
[Hypervisor] Reload cleaned keybinding global-map C-c e -> eval-expression for editing-keys
[Hypervisor] Reload re-applied unit: project-hooks
[Hypervisor] Reload: 1 changed applied, 12 unchanged skipped, 2 old effects cleaned.
```

Covered by tests:

- current selective reload tests remain green
- reload reports count registry-cleaned hook/advice/keybinding effects
- reload logs start, cleaned effects, applied units, and summary
- raw previous bodies without registry records do not synthesize cleanup

## Remaining Work

- Add source location metadata beyond the current source-form provenance.
- Decide whether unknown macro bodies should stay opaque or expose explicit
  extension points.
- Specify and implement any future effect kinds separately.
