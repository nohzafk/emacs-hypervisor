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

The embedded runtime module inventory lives in
`elle/runtime-forms/modules.manifest`. The host build reads that manifest to
embed module sources, and the packer test reads the same manifest so coverage
stays aligned with the runtime inventory.

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

Currently **all** modules load via `:source`: `elle/runtime-forms.lisp`
builds `{:path path :source source}` for every manifest entry. The packer is
implemented and unit-tested (`cargo test --manifest-path
host/elisp_pack/Cargo.toml`), and `host/build.rs` uses it to **validate**
every embedded module at build time — a malformed `.el` fails `cargo build`
instead of surfacing as a serve-time VM error. Loading through packed
`:forms` is still pending rollout.

## Scope

The packable-file inventory is `elle/runtime-forms/modules.manifest` — the
same manifest the host build reads to embed module sources, so packer
coverage stays aligned with the runtime inventory. Examples of entries:

```text
emacs-hypervisor-declarations.el        # package!/config-unit! macros
emacs-hypervisor-package-bridge.el      # package.el/package-vc bridge
emacs-hypervisor-effect-registry.el     # generic effect records
emacs-hypervisor-report.el              # startup report rendering
```

**Out of scope:** files under `host/emacs-kernel/`. Those are embedded as
source text for `emacs-hypervisor init` and bundled into the generated `init.el`
installed in the Emacs home directory.
