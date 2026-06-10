# Effect System

The effect system gives Hypervisor's reload the ability to clean up
recognized Emacs side effects. Each supported effect is represented as a
first-class registry record with enough identity, provenance, and retract
information to undo it on the next reload.

**Attention Conservation Notice.** For contributors adding new effect kinds,
debugging retraction, or understanding the registry contract. Skip if you only
need the user-facing reload behavior — see the
[README](../README.md#effect-aware-reload) and [docs/reload.md](reload.md).

## Effect Record Contract

An effect record is an Emacs Lisp plist.

```elisp
(:schema-version 1
 :id "hook/prog-mode-hook/line-numbers"
 :instance-id "reload-12/effect-4"
 :unit "editing"
 :kind :hook
 :target prog-mode-hook
 :function emacs-hypervisor--hook/prog-mode-hook/line-numbers
 :source (:form (add-hook 'prog-mode-hook #'display-line-numbers-mode)
          :file "config.org" :heading "Editing" :line 14 :tangled-line 87)
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
| `:source` | Provenance plist: always `:form` (the original source form); plus `:file`, `:heading` (org configs), `:line`, and `:tangled-line` when the config was loaded through the position-recording loader. |
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

### Registry State

The runtime keeps an ordered list of effect records.

```elisp
emacs-hypervisor-effect-registry-current
```

The registry records effects in application order. Cleanup retracts records in
reverse application order, so dependent effects unwind safely.

The registry is session-scoped. It does not persist across Emacs restarts.

### Supported Effect Kinds

| Source form | Effect kind | Retract strategy |
|---|---|---|
| `add-hook` | `:hook` | `remove-hook` |
| `advice-add` | `:advice` | `advice-remove` |
| `keymap-set`, `define-key`, `global-set-key`, `keymap-global-set` | `:keybinding` | Unset the Hypervisor-owned binding when it is still current |

### Opaque And Irreversible Effects

Unsupported effects can get opaque records when enough provenance is available.

```elisp
(:schema-version 1
 :id "opaque/editing/3"
 :instance-id "reload-12/effect-9"
 :unit "editing"
 :kind :opaque
 :target nil
 :source (:form FORM :file "config.org" :line 31)
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

### Future Inference

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

### Hook And Advice Registration

The hook helper has this shape:

```elisp
(emacs-hypervisor-register-hook-effect
 :unit "editing-hooks"
 :target hook
 :function (lambda () (setq-local fill-column 80))
 :depth nil
 :local nil
 :source '(:form (add-hook hook (lambda () (setq-local fill-column 80)))
           :file "config.org" :heading "Editing" :line 14))
```

At runtime the helper receives actual values from the executed form:

- `:target` is the concrete hook symbol.
- `:function` is the actual symbol or lexical closure.
- `:depth` and `:local` are the concrete add-hook arguments.

For anonymous functions, the helper:

1. Generates an owned symbol for this concrete effect instance.
2. Stores the closure in that symbol's function cell with `fset`.
3. Calls `add-hook` with the owned symbol.
4. Records a `:hook` effect with a concrete `remove-hook` retract form.

Advice registration follows the same pattern, using `advice-add` and
`advice-remove`.

Covered by tests:

- symbol hook functions are added, recorded, and removed
- lambda hook functions preserve closures and are removed by generated symbol
- symbol advice functions are added, recorded, and removed
- lambda advice functions preserve closures and are removed by generated symbol

### Keybinding Registration

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

Covered by tests:

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

## How the Existing Path Works

1. **Macro time.** `config-unit!` calls
   `emacs-hypervisor-effect-aware-reload-normalize-body`, which walks the
   body and rewrites `add-hook` / `advice-add` / keybinding calls into
   registration helper calls. The rewritten body is stored in the unit's
   `:body` field.

2. **Eval time.** When the body is evaluated, the register function:
   - If the function argument is a symbol: uses it directly
   - If it is a lambda/closure: generates a symbol via
     `emacs-hypervisor-effect-registry--generated-function-symbol`, calls
     `fset` to store the closure in that symbol's function cell
   - Calls the appropriate Emacs primitive (`add-hook`, `advice-add`, or the
     keybinding function) with the (possibly generated) symbol
   - Builds a retract form
   - Calls `emacs-hypervisor-effect-registry-record` to store the effect

3. **Reload time.** For changed/removed units,
   `emacs-hypervisor-effect-registry-retract-unit` iterates the unit's
   active effects in reverse application order and `eval`s each `:retract`
   form. Then the new body is evaluated, producing new registry records.

4. **No source fallback.** Cleanup uses registry records only. If a unit
   has no active records, cleanup is a no-op for that unit; restart Emacs
   to clear any pre-registry live state.

## How to Add a New Effect Kind

Each new effect kind should live in its own module, with exactly three pieces:

### 1. Recognizer predicate

Identify whether a source form matches this effect kind. See existing
examples in `emacs-hypervisor-effect-kind-hook.el` and
`emacs-hypervisor-effect-kind-advice.el`.

### 2. Rewriter spec

Register a spec with
`emacs-hypervisor-effect-aware-reload-register-effect-spec`. Each entry
declares the source operator, effect kind, recognizer predicate, and rewrite
function. The shared rewriter dispatches through that table.

The rewriter already walks into `progn`, `let`, `let*`, `when`,
`unless`, `if`, `cond`, `dolist`, `dotimes`. It does NOT walk into
`quote`, `function`, `lambda`, `defun`, `defmacro`, or unknown macro
calls.

### 3. Register function

A `cl-defun` in the effect-kind module that:

1. Captures any state needed for retraction (installed definition, previous
   value, timer object, etc.)
2. Applies the effect
3. Builds a retract form as a quoted s-expression
4. Calls `emacs-hypervisor-effect-registry-install-function-effect` or
   `emacs-hypervisor-effect-registry-record` with the standard fields

The registry, retraction logic, reload integration, and test
infrastructure require no changes. The reload command
(`emacs-hypervisor-reload-config`) already retracts all effect kinds
generically.

### Implementation files

| File | Role |
|---|---|
| `elle/runtime-forms/emacs-hypervisor-effect-registry.el` | Runtime registry: record, retract, query by unit |
| `elle/runtime-forms/emacs-hypervisor-effect-aware-reload.el` | Body rewriter dispatcher + cleanup integration |
| `elle/runtime-forms/emacs-hypervisor-effect-kind-hook.el` | `add-hook` effect recognizer, rewriter, installer |
| `elle/runtime-forms/emacs-hypervisor-effect-kind-advice.el` | `advice-add` effect recognizer, rewriter, installer |
| `elle/runtime-forms/emacs-hypervisor-effect-kind-keybinding.el` | keybinding effect recognizers, rewriter, installer |
| `elle/runtime-forms/emacs-hypervisor-declarations.el` | `config-unit!` macro, calls the body rewriter at macro-expansion time |
| `elle/runtime-forms/emacs-hypervisor-config-loader.el` | Config loading and Org tangling helpers used by startup and reload |
| `elle/runtime-forms/emacs-hypervisor-reload-policy.el` | Emacs-resident reload policy: preflight checks, dependency blocking, cleanup, execution |
| `elle/runtime-forms/emacs-hypervisor-reload-report.el` | Reload report summaries, warnings, and cleanup log formatting |
| `elle/runtime-forms/emacs-hypervisor-compose.el` | User-facing reload command wiring |
| `elle/runtime-forms/emacs-hypervisor-selective-reload.el` | Unit diffing: new/changed/unchanged/removed |
| `tests/elisp/emacs-hypervisor-bootstrap-test.el` | All existing tests |

## Planned Effect Kinds

Implement in this order.

### Phase 2: Timers

**Source forms:** `run-with-timer`, `run-at-time`, `run-with-idle-timer`

Re-evaluating config creates duplicate timers. This is a common source of
reload bugs.

**Key difference from hooks/advice:** Timer functions return a timer
object that must be captured for cancellation. The current rewriter
pattern just rewrites the form in place. For timers, the register function
must capture the return value.

The rewriter should rewrite:

```elisp
(run-with-timer SECS REPEAT FUNCTION ARGS...)
```

to:

```elisp
(emacs-hypervisor-register-timer-effect
 :unit UNIT
 :delay SECS
 :repeat REPEAT
 :function FUNCTION
 :args '(ARGS...)
 :source '(:form ORIGINAL-FORM))
```

The register function calls `run-with-timer` internally and stores the
returned timer object in the retract closure.

**Retract:** `(cancel-timer TIMER-OBJECT)`. Timer objects are compared
with `eq`, so store the exact object.

**`:metadata`:** `(:delay SECS :repeat REPEAT :timer TIMER-OBJECT)`

**Test expectations:**

- Timer is created and recorded
- Reload cancels old timer and creates new one
- Removed unit cancels timer
- Idle timer variant works

### Phase 3: Variables

**Source forms:** `setq`, `setq-default`, `customize-set-variable`

Not every `setq` is a configuration effect. A `setq` inside a `dolist` body
or a `let` block is often runtime logic, not a config declaration. The
recognizer should be conservative.

**Scoping rule:** Recognize `setq` / `setq-default` /
`customize-set-variable` only at the top level of the unit body (direct
children of the outermost `progn`). Do NOT recognize them inside `let`,
`when`, `dolist`, etc. This avoids tracking runtime assignments as config
effects.

This is a departure from hook/advice handling, where the rewriter walks
into control flow. For variables, the cost of a false positive (restoring
a variable the user didn't intend as config) is higher than missing a
nested `setq`.

**`setq` handles multiple pairs:** `(setq a 1 b 2)` sets two variables.
The rewriter should split this into separate register calls, one per
variable.

**Retract strategy:**

1. Snapshot `(symbol-value SYM)` or `(default-value SYM)` before applying
2. Apply the new value
3. Retract form: check if current value still `equal`s the
   Hypervisor-applied value. If yes, restore previous. If no, skip and
   log (something external changed it).

**`:metadata`:** `(:previous-value PREV :applied-value NEW)`

**Test expectations:**

- Variable is set and recorded
- Reload restores previous value and sets new one
- Removed unit restores previous value
- Externally changed variable is not clobbered
- `setq` with multiple pairs produces multiple records
- `setq` inside `when`/`dolist` is NOT tracked

### Phase 4: Faces

**Source forms:** `set-face-attribute`, `custom-set-faces`

**Retract:** Snapshot face attributes at apply time with
`face-attribute`. Retract restores them. Same divergence guard as
variables.

### Phase 5: Function cells

**Source forms:** `defun`, `fset`, `defalias`

**Retract:** Snapshot previous function cell with `(symbol-function SYM)`
if `fboundp`. Retract restores previous cell or calls `fmakunbound` if
the function was new.

**Scoping:** Only recognize these at the top level of the body, similar
to variables.

## Future Effect Vocabulary

The registry schema is intended to grow. These effect kinds are future work
and should not be treated as supported until a later implementation adds them.

| Source form | Future effect kind | Possible retract strategy |
|---|---|---|
| `setq` | `:variable` | Restore previous value |
| `set-face-attribute` | `:face` | Restore previous attributes |
| `add-to-list` | `:list-mutation` | Remove owned element |
| `run-with-timer` | `:timer` | `cancel-timer` |
| `defun`, `fset` | `:function-def` | Restore old function cell |
| Package install | `:package` | Mark persistent or irreversible |
| Process start | `:process` | Kill process or hand to supervisor |

## Additional Features

These use the effect registry but do not change it.

### Body Portraits

A read-only summary of what the recognizer found in a unit body. After
walking the body, collect the recognized effects:

```elisp
(:unit "editing"
 :recognized ((:kind :hook :target prog-mode-hook)
              (:kind :keybinding :map global-map :key "C-c e")))
```

Not a separate data structure. Just the recognizer output collected
instead of rewritten. Unrecognized forms are left alone — they
re-evaluate on reload as they always have.

Useful for: linting, reload reports.

### Structural Linting

Pattern-match rules on source body forms. No execution required.
Conservative: warn, do not block.

| Pattern | Diagnostic |
|---|---|
| `(add-hook 'H (lambda ...))` | Anonymous hook; managed registration recommended |
| `(advice-add 'T :W (lambda ...))` | Anonymous advice; managed registration recommended |
| `(eval-after-load ...)` | Deprecated; prefer `with-eval-after-load` |
| `(load-file ...)` | Bypasses Hypervisor visibility |
| `(setq minor-mode t)` | Did you mean `(minor-mode 1)`? |
| `(global-set-key ...)` | Prefer managed keybinding registration |

### Form-Addressed Failure Reports

Every registration call carries `:source` with the original form. When
the register function fails, the error handler has the unit name, effect
kind, source form, and failure condition. This produces:

```
Error in unit editing
  Effect: keybinding global-map "C-c e"
  Form: (keymap-set global-map "C-c e" #'some-command)
  Error: void-function some-command
```

Instead of the current generic: `Error in unit editing: void-function
some-command`.

### Registry Introspection

Query the live registry:

```elisp
(emacs-hypervisor-effect-registry-effects-for-unit UNIT)
(emacs-hypervisor-effect-registry-effects-for-kind KIND)   ; new
(emacs-hypervisor-effect-registry-effects-for-target TARGET) ; new
```

User-facing commands:

```
M-x hypervisor-list-effects
M-x hypervisor-explain-hook RET prog-mode-hook
M-x hypervisor-explain-key RET C-c e
```

Build after enough kinds exist to be useful.

### Timing Instrumentation

Wrap register functions with `current-time` before/after. Store elapsed
in `:metadata`. Aggregate per unit and per reload.

## Design Constraints

- **Preserve unknown forms.** Unrecognized forms pass through unchanged
  and re-evaluate on reload as they always have.
- **Registry path only.** Cleanup uses register functions + registry
  records. There is no static fallback.
- **Session-scoped.** The registry does not persist across restarts.
  Fresh startup evaluates everything. The problem is live reload.
- **Conservative recognizer.** When in doubt, leave a form unrecognized.
  An unrecognized form just re-evaluates without cleanup (same as today).
  A false positive could break config by retracting something that should
  stay.

## What This Is Not

Explicitly excluded from this design:

- Dependency inference or cross-unit conflict detection
- Transactional rollback or speculative execution
- Impact analysis or package symbol databases
- Profile systems or source-to-source migration
- Time-travel, provenance stores, or query languages
- Declarative config surfaces or capability declarations

The effect system is narrow: recognize common config side effects, give
them identity and retract closures, use the registry to keep reload clean.

## Remaining Work

- Decide whether unknown macro bodies should stay opaque or expose explicit
  extension points.
- Specify and implement any future effect kinds separately.

Source location metadata is implemented: effect-record `:source` plists now
carry `:file`, `:heading`, and `:line` alongside `:form` when the config was
loaded through the position-recording loader (see
[docs/spec-lockfile-check-source-map.md](spec-lockfile-check-source-map.md),
Part 3).
