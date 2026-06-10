# RFC: Manifest-Based Extensions

Status: discussion draft. Nothing here is committed work; this exists to
frame the decision before a second extension appears or Mermaid is
extracted from the tree.

**Attention Conservation Notice.** For contributors deciding how extensions
should be packaged, discovered, and loaded once they live outside this
repository. For what an extension *is*, see
[architecture.md § Extensions](architecture.md#extensions); for the current
canonical extension, see [architecture-mermaid.md](architecture-mermaid.md).

## Motivation

Mermaid was built in-tree as an experiment in reusing the live Elle runtime
for plugin-backed features. The experiment worked, and the stated direction
is to extract it. That extraction is currently impossible without forking
the core, because adding or removing an extension touches five hard-coded
points spread across three languages:

| Touch point | File | Coupling |
|---|---|---|
| Plugin build list | `.elle-plugins` | build-time, names the cdylib to compile and embed |
| Artifact embedding | `host/build.rs` | reads `.elle-plugins`, bakes plugin bytes + set digest into the binary |
| Handler wiring | `elle/hypervisor.lisp` | `(mermaid-extension:register settings {})` literally in the entrypoint |
| Handler module | `elle/extension-mermaid.lisp` | included via `include-file` at compile time |
| Elisp surface | `elle/runtime-forms/modules.manifest` + `emacs-hypervisor-markdown-mermaid.el` | embedded with the core runtime modules |

The generic layers are already in good shape — `elle/extensions.lisp` owns
dispatch and the actor loop, `emacs-hypervisor-extensions.el` owns settings
export, and the host already extracts embedded plugins to a cache and
addresses them with per-plugin env vars
(`EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_<NAME>_PATH`). What is missing is a
**data representation of an extension**, so that the set of extensions is an
input to the system rather than part of its source.

## Goals

1. An extension is fully described by a manifest file; the core never names
   a specific extension in code.
2. Extensions can ship outside the binary: dropped into a directory, picked
   up at startup, no rebuild of `emacs-hypervisor`.
3. Embedded (in-binary) extensions and external extensions go through the
   identical registration path; embedding becomes a packaging detail.
4. A broken or incompatible extension degrades to a reported failure, not a
   startup crash — consistent with the fail-forward posture everywhere else.
5. Mermaid is the proving ground: first converted to manifest form in-tree,
   then extracted.

## Non-Goals

- No extension marketplace, registry service, or auto-download. Acquisition
  is the user's problem in v1 (a `extension install` subcommand is sketched
  at the end, out of scope).
- No sandboxing. A native plugin is arbitrary code; the trust model is
  explicit user opt-in, not containment.
- No new wire protocol. `:extension-call` dispatch through
  `elle/extensions.lisp` is unchanged.
- No hot loading/unloading of extensions mid-session. The set is fixed at
  registry construction, as today.

## The Manifest

One file, `extension.manifest`, printed S-expression, at the root of an
extension directory:

```elisp
(:schema-version 1
 :name "mermaid"
 :version "0.4.0"
 :requires (:elle-epoch 10
            :plugin-abi 1
            :min-hypervisor "0.9.0")
 :plugin (:import-name "mmdflux"
          :artifacts ((:target "aarch64-apple-darwin"  :path "lib/libelle_mmdflux.dylib")
                      (:target "x86_64-unknown-linux-gnu" :path "lib/libelle_mmdflux.so")))
 :methods ((:name :render :fn "render"))
 :elisp ("lisp/emacs-hypervisor-markdown-mermaid.el")
 :settings (:defaults (:render-style "auto")))
```

| Field | Meaning |
|---|---|
| `:name` | Extension keyword as used in `emacs-hypervisor-extensions` and `:extension-call` payloads |
| `:requires` | Compatibility gates checked before any loading happens |
| `:plugin` | The stable-ABI cdylib: import name plus per-target artifact paths. Optional only for the degenerate case of an Elisp-only feature — which, per the architecture definition, is then *not* an extension; the field is effectively required |
| `:methods` | The dispatch surface: method keyword → plugin function name |
| `:elisp` | Runtime Elisp modules to install into the session, in order |
| `:settings` | Defaults merged under the Emacs-side settings export |

The schema is versioned independently of the hypervisor version, like the
effect-record schema.

## Discovery

Search order, first manifest wins per name:

1. **Embedded set** — manifests bundled into the binary at build time
   (today's `.elle-plugins` becomes a list of in-tree extension directories;
   `build.rs` embeds each directory's manifest, plugin artifact, and Elisp
   files instead of bare cdylib bytes).
2. **User directory** — `$XDG_CONFIG_HOME/emacs-hypervisor/extensions/<name>/`.
3. **`EMACS_HYPERVISOR_EXTENSION_PATH`** — colon-separated extra roots, for
   development; supersedes both (this generalizes the existing
   `EMACS_HYPERVISOR_ELLE_PLUGINS` ad-hoc override, which is retired).

A user-directory manifest shadowing an embedded one is allowed and reported
(`:log` event), so a newer external Mermaid can override the bundled one.

Only extensions named in `emacs-hypervisor-extensions` are loaded at all.
Discovery of a directory is not consent to run it.

## Registration

`elle/hypervisor.lisp` replaces the hard-coded wiring with a generic loop:

```lisp
;; today
(defn emacs-hypervisor-extension-registry [settings]
  (let [handlers (mermaid-extension:register settings {})]
    (extensions:make-registry settings handlers)))

;; proposed
(defn emacs-hypervisor-extension-registry [settings]
  (extensions:make-registry
   settings
   (extensions:load-from-manifests (extensions:discover-enabled settings))))
```

For each enabled extension, `load-from-manifests`:

1. Checks `:requires` gates. Failure → record an unavailability reason,
   skip.
2. Resolves the artifact for the current target, `(protect (import path))`
   it. Failure → record reason, skip.
3. Builds the handler struct from `:methods` (see the design question
   below).
4. Sends the `:elisp` module sources into Emacs through the existing
   module-loader `:eval` path — the same mechanism that installs embedded
   runtime forms today, so external Elisp is delivered identically to
   `emacs-hypervisor-markdown-mermaid.el` now.

The current behavior of *erroring* on an enabled-but-unsupported extension
(`unsupported-extensions`) is downgraded: the session continues, and the
startup report gets a per-extension status line with the structured reason
(`:abi-mismatch`, `:artifact-missing`, `:import-failed`, `:not-found`).
One broken extension should not take down startup any more than one broken
config unit does.

## The Central Design Question: where does handler logic live?

Mermaid's Elle handler (`elle/extension-mermaid.lisp`, 69 lines) does three
things: validate `:source`, normalize `:style`, merge viewport/options, and
call the plugin. The question for external extensions is who ships that
glue, since the core's Elle source is compiled into the binary and
`include-file` is compile-time only.

### Option A — convention-based generic handler (recommended)

The manifest's `:methods` table is the handler. A single shared shim in
`elle/extensions.lisp` maps `(:extension :mermaid :method :render :args A)`
to calling exported plugin function `render` with the args struct, and
normalizes the `{:ok ...}` / error envelope. All extension-specific logic —
argument validation, option merging, defaults — moves into the plugin
itself (Rust side), which already receives an options struct today.

- **Pros:** zero third-party Elle code; no runtime Elle loading capability
  required; the trust surface stays "one dlopen", which users already
  accept; the manifest fully describes dispatch.
- **Cons:** plugins must own their arg handling; Mermaid's current Elle
  normalization (`normalize-render-style`, viewport merging) migrates into
  `mmdflux`'s plugin entry points. This is a real but one-time migration,
  and arguably where that logic always belonged — the Elle layer was doing
  the plugin's input validation for it.

### Option B — extensions ship Elle source, loaded at runtime

The manifest lists an Elle module file exporting a `register` function with
the current module shape, and the backend evaluates it at registry-build
time.

- **Pros:** preserves today's expressiveness; complex orchestration (multi
  plugin calls, caching, state) stays in Lisp.
- **Cons:** requires Elle to load and evaluate source at runtime —
  `include-file` is compile-time, and whether the embedded VM exposes a
  suitable `eval`/load of third-party source is an **open question on Elle
  itself**; doubles the trust surface (native code *and* code running
  inside the control plane with protocol access); versioning the internal
  module API (`protocol`, `extensions`) becomes a public compatibility
  contract overnight.

**Recommendation:** Option A for v1. The dispatch table in
`elle/extensions.lisp` already treats handlers as opaque method maps, so
the shim slots in without touching dispatch. If a future extension
genuinely needs orchestration logic, Option B can be added behind the same
manifest (`:handler-module` field) once Elle's runtime-loading story is
settled — the manifest format does not foreclose it.

## Compatibility and Trust

- **ABI gating.** The plugin ABI version in `:requires` is checked against
  the host's `elle-plugin` crate ABI before `import` is attempted, turning
  today's opaque import failure into a named report reason. The existing
  embedded-set digest (`EMBEDDED_ELLE_PLUGIN_SET_DIGEST`) continues to
  version the cache directory for embedded artifacts; external artifacts
  are loaded from their own directory and never copied into that cache.
- **Consent.** Enabling is explicit and name-by-name via
  `emacs-hypervisor-extensions`, exactly as today. The startup report shows
  each loaded extension with its origin (embedded / user dir / env path),
  version, and artifact path, so what native code entered the process is
  always inspectable after the fact.
- **No execution before consent.** Manifests of non-enabled extensions are
  at most parsed, never imported.

## Migration Plan

1. **Manifest-ify in place.** Add `extension.manifest` for Mermaid in-tree;
   teach `build.rs` to embed manifest-described extension directories
   instead of the bare `.elle-plugins` list. Behavior identical, wiring now
   data-driven.
2. **Generic registry.** Replace the hard-coded registration in
   `hypervisor.lisp` with the manifest loop; move Mermaid's Elle-side arg
   normalization into `mmdflux` (Option A migration);
   `elle/extension-mermaid.lisp` shrinks toward deletion.
3. **External discovery.** Add the user-directory and
   `EMACS_HYPERVISOR_EXTENSION_PATH` search, the per-extension report
   lines, and the fail-forward downgrade of `unsupported-extensions`.
4. **Extract.** Move the Mermaid Elisp + manifest + plugin build into the
   `mmdflux`-side repo (or its own); the core keeps embedding it as a
   convenience for as long as desired, now purely as a packaging choice.

Steps 1–2 are worth doing even if extraction never happens: they delete the
per-extension special cases from the entrypoint and the build.

## Out of Scope, Sketched for Later

- `emacs-hypervisor extension install <path|url>` — verify manifest +
  target artifact, copy into the user directory, print what was installed.
- `emacs-hypervisor extension list` — discovery roots, versions, gate
  results, without starting a session (pairs naturally with the `check`
  subcommand harness).
- Per-extension settings schema validation from `:settings`.

## Open Questions

1. Does Elle's embedded VM expose (or plan to expose) runtime evaluation of
   external source? This decides whether Option B is ever on the table.
2. Should the plugin ABI version be exported by the `elle-plugin` crate as
   a queryable constant, so the gate can be checked without attempting
   `import`?
3. Artifact naming per target: adopt Rust target triples (as drafted) or a
   simpler `os-arch` pair?
4. Does a manifest need a checksum block for its artifacts, given that the
   trust model is directory-based consent rather than supply-chain
   verification?
5. When a user-directory extension shadows an embedded one, should the
   embedded version remain available as an explicit fallback
   (`mermaid@embedded`), or is shadowing absolute?
