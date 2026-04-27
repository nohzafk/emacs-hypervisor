# Generalized Effect System

Extending the effect registry beyond hooks and advice to track all
recognized configuration side effects through a single lifecycle.

**Attention Conservation Notice**

For: Agent or contributor implementing new effect kinds

What: Handover document for generalizing the effect registry to
keybindings, timers, variables, faces, and function cells

Action: Read this before adding new effect kinds. Understand the existing
implementation first, then follow the pattern described here.

Skip if: You only need the current hook/advice reload behavior

## Context

Emacs Hypervisor manages Emacs configuration as a dependency graph of
`config-unit!` declarations. On reload, it diffs previous and current
units, cleans up recognized side effects from changed/removed units, then
re-evaluates only what changed.

The problem this solves: re-evaluating Elisp is easy, but undoing what the
old version did is not. A normal reload leaves duplicate hook entries,
stale advice, orphaned keybindings, and leaked timers. After enough
reloads, the live session no longer matches the config file.

Today, Hypervisor tracks `add-hook` and `advice-add` as runtime effect
records. On reload, it retracts the previous effects before applying the
new version. This is the killer feature for daily editing in long-lived
sessions.

The limitation: only hooks and advice are tracked. Keybindings, timers,
variables, faces, and function definitions are not. If you delete a
`keymap-set` from your config and reload, the old keybinding survives
until restart.

## Goal

Generalize the effect registry from two effect kinds to many, using the
same architecture that already works for hooks and advice.

This is not a redesign. The existing registry, retraction, and reload
integration remain unchanged. The work is adding new recognizer clauses,
rewriter specs, and register functions that produce the same record
shape the registry already consumes.

## Verdict And Gap

The plan is sound, but it needs one preparatory phase before keybindings.
The hook/advice path should first be expressed as the first two entries in
a general effect dispatch table. That proves the extension point using
already-supported behavior before adding a new effect kind with new
retraction semantics.

Phase 0 does three things:

1. Move `add-hook` and `advice-add` registry rewriting behind effect specs:
   source operator, effect kind, recognizer predicate, and rewrite function.
2. Remove the old static cleanup fallback. If a live session predates the
   registry rewrite, restart Emacs instead of reconstructing cleanup from
   source.
3. Make cleanup accounting generic for registry-backed effects.

Decision: do not add a new keybinding recognizer until Phase 0 is passing
the existing hook/advice tests unchanged. That gives Phase 1 a clean
mechanical path: add one spec, one register function, and focused tests.

## Existing Implementation

Read these files before starting:

| File | Role |
|---|---|
| `elle/runtime-forms/emacs-hypervisor-effect-registry.el` | Runtime registry: record, retract, query by unit |
| `elle/runtime-forms/emacs-hypervisor-effect-aware-reload.el` | Body rewriter + cleanup integration |
| `elle/runtime-forms/emacs-hypervisor-declarations.el` | `config-unit!` macro, calls the body rewriter at macro-expansion time |
| `elle/runtime-forms/emacs-hypervisor-compose.el` | Reload command, wires selective reload + effect cleanup |
| `elle/runtime-forms/emacs-hypervisor-selective-reload.el` | Unit diffing: new/changed/unchanged/removed |
| `tests/elisp/emacs-hypervisor-bootstrap-test.el` | All existing tests |

### How the existing hook/advice path works

1. **Macro time.** `config-unit!` calls
   `emacs-hypervisor-effect-aware-reload-normalize-body`, which walks the
   body and rewrites `add-hook` / `advice-add` calls into
   `emacs-hypervisor-register-hook-effect` /
   `emacs-hypervisor-register-advice-effect` calls. The rewritten body is
   stored in the unit's `:body` field.

2. **Eval time.** When the body is evaluated, the register function:
   - If the function argument is a symbol: uses it directly
   - If it is a lambda/closure: generates a symbol via
     `emacs-hypervisor-effect-registry--generated-function-symbol`, calls
     `fset` to store the closure in that symbol's function cell
   - Calls `add-hook` or `advice-add` with the (possibly generated) symbol
   - Builds a retract form (`remove-hook`/`advice-remove` + `fmakunbound`
     if generated)
   - Calls `emacs-hypervisor-effect-registry-record` to store the effect

3. **Reload time.** For changed/removed units,
   `emacs-hypervisor-effect-registry-retract-unit` iterates the unit's
   active effects in reverse application order and `eval`s each `:retract`
   form. Then the new body is evaluated, producing new registry records.

4. **No source fallback.** Cleanup uses registry records only. If a unit
   has no active records, cleanup is a no-op for that unit; restart Emacs
   to clear any pre-registry live state.

### What the registry record looks like

From `emacs-hypervisor-effect-registry-record`:

```elisp
(:schema-version 1
 :id             "hook/editing/prog-mode-hook/a1b2c3d4e5"
 :instance-id    "editing/hook/3"
 :unit           "editing"
 :kind           :hook
 :target         prog-mode-hook
 :function       emacs-hypervisor--generated-editing-hook-prog-mode-hook-a1b2c3
 :source         (:form (add-hook 'prog-mode-hook (lambda () ...)))
 :apply          (add-hook 'prog-mode-hook #'emacs-hypervisor--generated-...)
 :retract        (progn (remove-hook 'prog-mode-hook #'...) (fmakunbound '...))
 :body-hash      "a1b2c3d4e5"
 :reversible     t
 :persistent     nil
 :status         :active
 :supported      t
 :reason         nil
 :metadata       (:depth nil :local nil :generated-function t))
```

The registry core (`record`, `retract`, `retract-unit`,
`effects-for-unit`) operates on this plist generically. It does not
inspect `:kind`. It only needs `:retract` to be an evaluable form and
`:status` / `:reversible` / `:supported` to be set.

## How to Add a New Effect Kind

Each new effect kind needs exactly three things, all in
`emacs-hypervisor-effect-aware-reload.el` and
`emacs-hypervisor-effect-registry.el`:

### 1. Recognizer predicate

Identify whether a source form matches this effect kind. See existing
examples: `--registry-hook-form-p`, `--registry-advice-form-p`.

### 2. Rewriter spec

Add an entry to
`emacs-hypervisor-effect-aware-reload--registry-effect-specs`. Each entry
declares the source operator, effect kind, recognizer predicate, and
rewrite function. The shared rewriter dispatches through that table.

The rewriter already walks into `progn`, `let`, `let*`, `when`,
`unless`, `if`, `cond`, `dolist`, `dotimes`. It does NOT walk into
`quote`, `function`, `lambda`, `defun`, `defmacro`, or unknown macro
calls.

### 3. Register function

A `cl-defun` in `emacs-hypervisor-effect-registry.el` that:

1. Captures any state needed for retraction (previous binding, previous
   value, timer object, etc.)
2. Applies the effect
3. Builds a retract form as a quoted s-expression
4. Calls `emacs-hypervisor-effect-registry-record` with the standard fields

The registry, retraction logic, reload integration, and test
infrastructure require no changes. The reload command
(`emacs-hypervisor-reload-config`) already retracts all effect kinds
generically.

## Planned Effect Kinds

Implement in this order.

### Phase 0: Normalize Existing Hook/Advice Effects

**Source forms:** `add-hook`, `advice-add`

**Why first:** This is the lowest-risk proof that the generalized path
preserves current behavior. No new user-visible effect kind should be
added until hook/advice still pass through the same lifecycle from a
generic dispatch table.

**Expected shape:**

```elisp
(:kind :hook
 :operator 'add-hook
 :predicate #'emacs-hypervisor-effect-aware-reload--registry-hook-form-p
 :rewrite #'emacs-hypervisor-effect-aware-reload--registry-hook-form)
```

**Test expectations:**

- Hook/advice normalization still rewrites to the existing register calls
- Unsupported local hooks remain untracked
- Existing generated lambda hook/advice cleanup tests still pass
- Cleanup summary counting is ready for non-hook/advice registry records
- Raw previous bodies without registry records do not synthesize cleanup

### Phase 1: Keybindings

**Source forms:** `keymap-set`, `define-key`, `global-set-key`,
`keymap-global-set`

**Why first:** Highest user impact. Deleted keybinding config survives
until restart today.

**Form variance:** These have different signatures:

```elisp
(keymap-set MAP KEY DEFINITION)          ; Emacs 29+, preferred
(define-key KEYMAP KEY DEF)              ; classic
(global-set-key KEY COMMAND)             ; shorthand for global-map
(keymap-global-set KEY DEFINITION)       ; Emacs 29+ shorthand
```

The recognizer must handle each form's arity and argument positions. The
rewriter should normalize them into a single register call:

```elisp
(emacs-hypervisor-register-keybinding-effect
 :unit UNIT
 :map MAP-FORM          ; the keymap expression
 :key KEY-FORM          ; the key string/vector
 :definition DEF-FORM   ; the command
 :source '(:form ORIGINAL-FORM))
```

For `global-set-key` and `keymap-global-set`, `:map` is `global-map`
(literally the symbol, not quoted — it is evaluated at runtime to get the
actual keymap object).

**Retract strategy:**

1. At apply time, snapshot the previous binding:
   `(keymap-lookup MAP KEY)` (Emacs 29+) or `(lookup-key MAP KEY)`
2. Apply the new binding
3. Retract form: if previous binding was nil, use `(keymap-unset MAP KEY)`
   (Emacs 29+) or `(define-key MAP KEY nil)`. If previous binding existed,
   restore it with `keymap-set`/`define-key`.
4. **Divergence guard:** before retract, check if the current binding
   still equals what Hypervisor installed. If something external changed
   it, skip retraction and log a warning instead of clobbering the
   external change.

**`:metadata`:** `(:key KEY :previous-binding PREV)`

**Test expectations:**

- Keybinding is installed and recorded in registry
- Reload retracts old binding and installs new one
- Removed unit restores previous binding (or unsets if none)
- Externally changed binding is not clobbered on retract
- `global-set-key` and `keymap-set` both work
- Keybinding inside `dolist` records one effect per iteration

### Phase 2: Timers

**Source forms:** `run-with-timer`, `run-at-time`, `run-with-idle-timer`

**Why second:** Re-evaluating config creates duplicate timers. This is a
common source of reload bugs.

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

**Why this is subtle:** Not every `setq` is a configuration effect. A
`setq` inside a `dolist` body or a `let` block is often runtime logic,
not a config declaration. The recognizer should be conservative.

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

## Additional Features (Built on Top)

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
