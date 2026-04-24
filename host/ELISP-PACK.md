# `elisp_pack` Design

`elisp_pack` is an internal Rust library for packing authored static Elisp files
under `elle/runtime-forms/` into canonical top-level form data.

## Goals

- keep static support code authored as normal `.el` files
- scope packing to `elle/runtime-forms/*.el`
- avoid a separate manual conversion step during development
- keep dynamic, session-specific runtime forms in Elle

## Shape

`elisp_pack` lives at `host/elisp_pack` and is intentionally isolated from the
current shipped runtime path.

Current status:

- runtime source-of-truth files live under `elle/runtime-forms/*.el`
- the shipped host embeds build-time snapshots of the static modules
- `session-base` now ships through the structured `:forms` path
- the Elle runtime currently mixes one packed module with source-backed embedded module specs for the rest
- `elisp_pack` is now tree-sitter-backed and ready for wider `:forms` rollout

## Runtime Contract

The Elle backend treats static Elisp modules as module specs with:

- `:path`
- exactly one of `:forms` or `:source`

Current runtime behavior:

- `session-base` uses packed `:forms` loading
- the remaining static modules still use embedded source-backed loading
- dynamic/session-specific generated forms still come directly from Elle

## Scope

The intended packable scope is intentionally narrow:

- `elle/runtime-forms/emacs-hypervisor-report-core.el`
- `elle/runtime-forms/emacs-hypervisor-report.el`
- `elle/runtime-forms/emacs-hypervisor-declarations.el`
- `elle/runtime-forms/emacs-hypervisor-compose.el`
- `elle/runtime-forms/emacs-hypervisor-session-base.el`
- `elle/runtime-forms/emacs-hypervisor-elpaca-bridge.el`
- `elle/runtime-forms/emacs-hypervisor-package-runtime.el`
- `elle/runtime-forms/emacs-hypervisor-unit-runtime.el`

Files under `host/templates/lisp/` are out of scope for `elisp_pack`.

Those bootstrap files are embedded as source text for `emacs-hypervisor init`
because they are installed as real user files in the Emacs home directory.

## Parser Strategy

`elisp_pack` now uses `tree-sitter` with `tree-sitter-elisp` to parse `.el`
source into a concrete syntax tree, then lowers that CST into canonical top-level
Elisp form data.

Current normalization behavior:

- preserves ordinary atoms, strings, chars, numbers, vectors, bytecode, hash tables, and string-text-property forms
- rewrites quote shorthand into explicit forms, such as `'x` -> `(quote x)` and `#'x` -> `(function x)`
- lowers quasiquote / unquote / unquote-splicing into explicit forms for the current macro-heavy runtime files
- ignores comments and formatting while preserving code structure

Current limitations:

- nested quasiquote is still rejected
- arbitrary unsupported reader forms beyond the grammar and current lowering rules may still need follow-up work
- only `session-base` is switched back to consuming packed `:forms` so far

The API boundary remains:

- `pack_file(path) -> PackedModule`
- `PackedModule.forms_source`

That keeps the source-of-truth as `.el` while making a structured runtime path
possible once we re-enable `:forms` loading.
