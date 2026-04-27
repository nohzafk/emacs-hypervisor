# `elisp_pack`

Internal Rust library (`host/elisp_pack/`) that packs static `.el` files under
`elle/runtime-forms/` into canonical top-level Elisp form data at build time.

## Why

Runtime Elisp modules are authored as normal `.el` files so they can be edited,
tested, and byte-compiled like any Elisp. But the binary needs to embed them in
a structured form that Elle can emit into Emacs. `elisp_pack` bridges this gap
without a manual conversion step during development.

Dynamic, session-specific forms are still generated directly by Elle ---
`elisp_pack` only handles static modules.

## How It Works

`elisp_pack` uses tree-sitter with tree-sitter-elisp to parse `.el` source
into a concrete syntax tree, then lowers the CST into canonical top-level form
data.

**API:**

```rust
pack_file(path) -> PackedModule
PackedModule.forms_source  // canonical Elisp form string
```

**Normalization:**

- Preserves atoms, strings, chars, numbers, vectors, bytecode, hash tables,
  and string-text-property forms.
- Rewrites quote shorthand: `'x` to `(quote x)`, `#'x` to `(function x)`.
- Lowers quasiquote / unquote / unquote-splicing into explicit forms.
- Strips comments and formatting while preserving code structure.

**Limitations:**

- Nested quasiquote is rejected.
- Unsupported reader forms beyond the grammar may need follow-up work.

## Module Spec Contract

Elle treats each static Elisp module as a spec with:

- `:path` --- module identity
- `:forms` or `:source` --- exactly one; `:forms` is the packed path,
  `:source` is the raw embedded source fallback

Currently `session-base` uses packed `:forms` loading. The remaining static
modules still use source-backed loading. The packer is ready for wider
`:forms` rollout.

## Scope

Packable files (all under `elle/runtime-forms/`):

```text
emacs-hypervisor-session-base.el        # session lifecycle
emacs-hypervisor-declarations.el        # package!/config-unit! macros
emacs-hypervisor-elpaca-bridge.el       # Elpaca integration
emacs-hypervisor-package-runtime.el     # package event handling
emacs-hypervisor-unit-runtime.el        # unit execution helpers
emacs-hypervisor-selective-reload.el    # reload diffing + scheduling
emacs-hypervisor-effect-registry.el     # generic effect records
emacs-hypervisor-effect-aware-reload.el # effect rewrite dispatcher + cleanup
emacs-hypervisor-effect-kind-hook.el    # add-hook effect kind
emacs-hypervisor-effect-kind-advice.el  # advice-add effect kind
emacs-hypervisor-effect-kind-keybinding.el # keybinding effect kind
emacs-hypervisor-compose.el             # wires reload into M-x command
emacs-hypervisor-report-core.el         # report data structures
emacs-hypervisor-report.el              # startup report rendering
```

**Out of scope:** files under `host/emacs-kernel/`. Those are embedded as
source text for `emacs-hypervisor init` and bundled into the generated `init.el`
installed in the Emacs home directory.
