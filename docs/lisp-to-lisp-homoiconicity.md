# Lisp-to-Lisp Homoiconicity

`config-unit!` bodies cross the Elle/Emacs boundary as structured Lisp data,
not as printed strings. Emacs exports bodies as Elisp forms, serializes them
as readable s-expressions, Elle reads them as data, and sends them back to
Emacs as quoted forms for direct `eval`.

## Semantic Model

| Term | Meaning |
| --- | --- |
| Structured body | A config-unit `:body` stored as an Elisp form such as `(progn ... t)`, not as a printed string. |
| Wire s-expression | One textual s-expression line sent over stdio by `sexp-rpc`; the text is transport, but the payload model is Lisp data. |
| Elle array | Elle's representation for Emacs vector syntax read from `[...]`; printed recursively by `protocol:sexp-string`. |
| Reader-hostile symbol | Elisp syntax that Elle cannot currently read, especially bare `1+` and `1-` symbols. |
| Canonicalization | Emacs-side rewrite that turns safe hostile call forms like `(1+ x)` into `(+ x 1)` before export. |

## Invariants

1. `elle/protocol.lisp` and repo-owned Elisp runtime forms are in scope; the
   Elle compiler/Rust reader is not modified for this feature.
2. `config-unit!` bodies are not stringified for normal execution.
3. Emacs vectors in config bodies preserve string elements on the wire,
   including keys like `"["` and `"]"` used by `transient`.
4. `#'` and `'` reader shortcuts are not emitted by the Emacs serializer,
   because Elle's reader does not accept them.
5. `1+` and `1-` are rewritten only in call position. Bare occurrences fail
   loudly rather than silently changing meaning.
6. Runtime execution `eval`s structured forms directly, not `(read body)`.

## Data Flow

```text
Emacs config-unit! body as form
  -> Emacs serializer prints reader-compatible data
  -> Elle protocol recursively prints arrays on outbound eval requests
  -> execution builds and sends quoted run-unit forms
  -> Emacs runtime evals structured body directly
```

## Implementation

### Code Anchors

| Component | Location |
| --- | --- |
| Recursive array printing in Elle protocol | `elle/protocol.lisp` (`sexp-string`) |
| Recursive array traversal in `from-wire` / `to-wire` | `elle/protocol.lisp` |
| Structured config-unit body export | `elle/runtime-forms/emacs-hypervisor-declarations.el` |
| Canonicalize `1+` / `1-` call forms | `elle/runtime-forms/emacs-hypervisor-declarations.el` |
| Direct runtime eval of structured bodies | `elle/runtime-forms/emacs-hypervisor-unit-runtime.el`, `elle/runtime-forms/emacs-hypervisor-compose.el` |
| Quote bodies/requires in Elle-emitted run-unit forms | `elle/execution.lisp` |
| Avoid Emacs reader shortcuts on outbound messages | `host/templates/lisp/emacs-hypervisor-sexp-rpc.el` |

### Emacs Serializer

Emacs `prin1-to-string` with `print-quoted` bound to nil. This avoids
emitting `#'` and `'` shortcuts that Elle's reader cannot parse.

### Elle Protocol

`protocol:sexp-string` recursively traverses arrays, correctly quoting string
elements. The previous behavior fell back to `(string value)` for arrays,
producing unquoted vector elements such as `[Open ...]`.

### Config-Unit Export

`config-unit!` stores bodies as forms and exports canonicalized forms,
keeping session data inspectable by Elle. The export path canonicalizes
`(1+ x)` to `(+ x 1)` and `(1- x)` to `(- x 1)` in call position only.

### Runtime Execution

`emacs-hypervisor-runtime-run-unit` and soft reload expect structured body
forms. String bodies are no longer the intended path.

## Limitations

- Elle reader compatibility is scoped to observed blockers: vectors,
  quote/function shortcuts, and `1+`/`1-`. Additional reader-hostile Elisp
  syntax may appear as more bodies cross as data.
- `1+`/`1-` canonicalization is Emacs-side; broader Elle reader support may
  replace it later.
