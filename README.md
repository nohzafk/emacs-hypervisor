# Emacs Hypervisor

A single native binary, written in [Elle](https://github.com/elle-lisp/elle)
(a modern Lisp over Rust), for deterministic, reloadable Emacs configuration.

Drop it on your `PATH`, point it at an Emacs home, and it generates a small
trusted kernel that launches a Lisp-native control plane over stdio. No
framework repo to clone, no external runtime.

Hypervisor is a foundation for building your own config, not an Emacs
distribution. You keep ownership of `config.org` (or `config.el`); Hypervisor
provides package declarations, config-unit declarations, dependency planning,
reload support, and the orchestration runtime around Emacs.

## Why Emacs Hypervisor

**Know your config is correct in five seconds, not two hours.** Most Emacs
configs are order-sensitive scripts where a missing dependency or misordered
`require` becomes an intermittent bug that surfaces hours later, hidden behind
lazy loading, with no context. Hypervisor treats your config as a dependency
graph --- topologically sorted, preflight-validated, and eagerly executed in
deterministic order. If something is broken, you know at startup.

**Fail forward, not fail hard.** A single broken package or config unit does
not take down the rest of your session. Failed packages skip their dependents;
failed units skip their `:after` chain --- but everything else continues
normally. The startup report shows exactly what failed, what was skipped, and
why, so you can fix the one broken piece without restarting.

**Reload without stale state.** Re-evaluating Elisp is easy; undoing what the
old version did is not. A normal reload leaves duplicate hooks, stale advice,
and orphaned keybindings. Hypervisor tracks `add-hook`, `advice-add`, and
common keybinding forms as runtime effect records. On reload, it retracts the
previous effects before applying the new version --- the live session matches
the file you just edited.

**Single binary, zero framework overhead.** One executable, no Rust toolchain,
no framework repo to clone into your Emacs home. Your config lives in its own
directory and is never overwritten by upgrades.

## User-Facing Model

The entire user-facing surface is two macros:

| Macro | Purpose |
|---|---|
| `package!` | Declare packages and their dependencies |
| `config-unit!` | Declare named blocks of configuration |

This gives you a bare framework for organizing your own configuration. It does
not choose your packages, keybindings, UI, editing model, or workflow.

## Features

- **Literate config** --- write `config.org` and Hypervisor auto-tangles it at
  startup and reload; no manual tangle step needed.
- **Built-in package management** --- `package!` declarations install through
  Emacs's built-in `package-vc-install` (Emacs 29.1+) with `Package-Requires:`
  resolved against GNU ELPA, NonGNU ELPA, and MELPA. The bridge clones git sources and adopts
  them via `package-vc-install-from-checkout`. Clean, transactional rebuilding of local packages is supported via env vars and in-session Lisp commands.
- **Reproducible installs** --- a `hypervisor.lock` next to your config records
  every installed revision; a fresh machine restores the exact same package
  state. Deliberate upgrades (`M-x emacs-hypervisor-upgrade-package`) and
  orphan pruning (`M-x emacs-hypervisor-prune-packages`) keep the lock and the
  installed set in step with your declarations.
- **Preflight checks** --- circular dependencies, duplicate names, unset env
  vars, and missing executables are caught before startup execution begins;
  absent `:requires` features are caught before the affected unit body runs.
- **Batch validation** --- `emacs-hypervisor check` runs the same graph,
  preflight, and planning code in batch Emacs without executing anything, so a
  dotfiles repo can validate its config in CI.
- **Source provenance** --- every declaration records its `config.org` heading
  and line; failures, lint findings, and startup report problems cite the
  exact location, and the report buffer links jump straight to it.
- **Fault-tolerant execution** --- a failed package or unit skips its
  dependents; independent units continue normally.
- **Selective reload** --- edit one unit and apply only what changed, without
  replaying the entire config.
- **Effect-aware reload** --- automatically clean old hooks, advice, and
  keybindings before re-applying a changed unit.
- **Startup reports** --- progress events, package status with installed
  revisions and lock state, unit results, and optional metrics give you full
  visibility into what happened and why.

## Config Example

```elisp
(package! magit)
(package! transient
  :repo "magit/transient"
  :branch "main")

(config-unit! magit-ui
  :requires (magit)
  :executable (git)
  :config
  (keymap-set global-map "C-x g" #'magit-status))

(config-unit! project-hooks
  :after (magit-ui)
  :config
  (add-hook 'magit-mode-hook
            (lambda ()
              (setq-local truncate-lines t))))
```

`magit-ui` requires the `magit` feature before it runs. `project-hooks` only
needs `magit-ui` to have completed first; its hook registration can run eagerly
without loading another package feature.

## Literate Config

Hypervisor supports literate configuration via Org-mode. Place a `config.org`
in the Hypervisor config directory instead of `config.el`, and Hypervisor will
automatically tangle it before loading. No manual tangle step is required.

The Hypervisor config directory is `$XDG_CONFIG_HOME/emacs-hypervisor` when
`XDG_CONFIG_HOME` is set, otherwise `$HOME/.config/emacs-hypervisor`.

```org
* Magit

#+begin_src emacs-lisp
(package! magit)
(config-unit! magit-ui
  :requires (magit)
  :executable (git)
  :config
  (keymap-set global-map "C-x g" #'magit-status))
#+end_src
```

When `config.org` is present, `config.el` is not needed. Hypervisor
automatically tangles all `elisp` and `emacs-lisp` source blocks into a hidden
`.config.tangled.el` and loads that. No `:tangle` header is required on your
blocks. Blocks with `:tangle no` are still respected and skipped.

If both `config.org` and `config.el` exist, Hypervisor uses `config.org` and
warns that `config.el` is ignored.

Tangling uses Emacs's built-in `org-babel-tangle-file` with a language filter
for `elisp` and `emacs-lisp`. The typical overhead is under 200ms for a
2000-line config.

### Splitting a large literate config

`emacs-hypervisor-config-org-file` accepts an ordered list of paths as well as
a single path. Each file is tangled separately and the results are
concatenated in list order into one `.config.tangled.el`, so a config that has
outgrown one file can be split without an Org `#+INCLUDE` step:

```elisp
;; In the Hypervisor config early-init.el
(setq emacs-hypervisor-config-org-file
      (mapcar (lambda (name)
                (expand-file-name name "~/.config/emacs-hypervisor/chapters/"))
              '("00-overview.org"
                "10-editor.org"
                "20-languages.org")))
```

List order is load order. Hypervisor does not scan a directory for you: a
literate config is order-sensitive, because `package!` must be declared before
the `config-unit!` that requires it, so the order is worth stating explicitly
rather than deriving from file names.

Hypervisor has no notion of what the files represent. Split them however suits
the config; the names above are only an example.

Every block keeps provenance to the file it was written in, so a failing unit
reports and jumps to the right source file rather than to a merged whole.

The shadow `.config.tangled.el` is written to the Hypervisor config directory,
whatever directory the sources live in. That directory is what the config sees
as `load-file-name` and `default-directory` while it loads, so a config that
keeps its sources in a subdirectory still resolves its own relative paths, such
as a `lisp/` directory, against the config root.

Presence of any listed file selects the literate startup path. Files that do
not exist are skipped, so a list may name optional, machine-specific chapters.

## Why Eager Loading

Lazy loading is the default tradeoff in most Emacs configs: defer everything to
make startup fast, and hope nothing is broken.

If you are building a simple config, that is fine. But if you are developing a
complex one --- adding packages, wiring integrations, iterating on hook
behavior --- lazy loading works against you. You add a keybinding for a command
that does not exist yet, and nothing tells you. You misspell a hook variable,
and nothing fails. You `require` a feature that a package has not installed yet,
and you will not find out until you open that file type two hours later, in the
middle of real work, with no context about what went wrong. The feedback loop
is: edit, restart, wait, use Emacs for a while, and *maybe* discover the
problem. That is not a development workflow; it is a lottery.

Hypervisor takes the opposite tradeoff: resolve the entire dependency graph, run
config units in deterministic order, and prove the config is internally
consistent at startup. If something is broken, you know in five seconds.

Eager does not mean force-loading every package. `:requires` should be used
only when the body truly needs a feature loaded first (package-local variables,
keymaps, macros, non-autoloaded functions). Hook registration, global
keybindings, autoloaded commands, and pre-load-safe variable setup can all run
eagerly without `:requires`.

## Reload

Eager loading gives you a tight feedback loop at startup. Reload extends that
loop into your running session.

When you are actively working on your config --- tweaking a hook, moving a
keybinding, adjusting advice --- you do not want to restart Emacs every time.
`M-x emacs-hypervisor-reload-config` reloads `config.org` (or `config.el`),
diffs the previous declarations against the new ones, and applies only what
changed:

- **Unchanged** units are skipped.
- **New** and **changed** units are re-applied.
- **Removed** units are not evaluated again.

The hard part is not re-evaluation --- Emacs can already do that. The hard part
is that `add-hook` appends, `advice-add` mutates, and keybinding forms
overwrite. A normal reload is additive: fix a hook body and the old one is
still there; delete a keybinding and it survives until restart. After enough
reloads, the live session drifts from the file you are editing.

Hypervisor solves this with an **effect registry**. Each `add-hook`,
`advice-add`, and keybinding call is recorded as a runtime effect record. On
reload, changed units retract their previous effects before applying the new
version --- so the live session matches the file you just saved.

```text
[Hypervisor] Reload started
[Hypervisor] Reload cleaned hook prog-mode-hook -> display-line-numbers-mode for project-hooks
[Hypervisor] Reload cleaned keybinding global-map C-c e -> eval-expression for editing-keys
[Hypervisor] Reload re-applied unit: project-hooks
[Hypervisor] Reload: 1 changed applied, 12 unchanged skipped, 2 old effects cleaned.
```

The recognizer is intentionally conservative: it tracks hooks, advice, and
keybindings in executed body positions. Unrecognized forms re-evaluate on
reload as they always have --- the worst case is the status quo, not breakage.

See [docs/reload.md](docs/reload.md) for the full data model and API, and
[docs/effect-system.md](docs/effect-system.md) for the registry contract.

## Requirements

- Emacs 29.1 or later (uses built-in `package-vc-install`)
- `git` on `PATH`
- Network access on first run (clones VC packages and refreshes archive indices)

## Usage

Download the `emacs-hypervisor` binary for your platform, make it executable,
and place it somewhere on `PATH`.

```bash
mkdir -p ~/.local/bin
chmod +x emacs-hypervisor
mv emacs-hypervisor ~/.local/bin/emacs-hypervisor
```

Initialize an Emacs home:

```bash
emacs-hypervisor init --home ~/.config/emacs
```

`init` refuses to initialize a non-empty home. This is deliberate: the generated
`init.el` is a managed bootstrap artifact, while your configuration belongs in
the Hypervisor config directory.

After upgrading or reinstalling the binary, refresh an existing generated home:

```bash
emacs-hypervisor init --home ~/.config/emacs --upgrade
```

`init --upgrade` only rewrites files that were generated by Emacs Hypervisor. It
refuses to overwrite unmanaged `init.el` or `early-init.el` files. Generated
`init.el` files include a content hash; Emacs reports that hash in the boot
context, and Elle compares it with the hash embedded in the current binary. When
the generated bootstrap is stale, Elle sends a warning event that Emacs records
in the startup report and displays through the normal warning UI.

Create or edit your config. Use either a literate Org file or a plain Elisp
file:

```text
~/.config/emacs-hypervisor/config.org     # literate config (recommended)
~/.config/emacs-hypervisor/config.el      # or plain Elisp
~/.config/emacs-hypervisor/early-init.el  # optional bootstrap customization
```

Optionally capture the current shell environment for Emacs:

```bash
emacs-hypervisor env --home ~/.config/emacs
```

`env` writes a Lisp list of `"KEY=VALUE"` strings. The generated startup loads
that file before user config, updates `process-environment`, and rebuilds
`exec-path` from `PATH`. It intentionally leaves `shell-file-name` to user
config.

Start Emacs:

```bash
emacs --init-directory ~/.config/emacs
```

If GUI Emacs cannot see your shell `PATH`, or if you want to test a specific
binary, launch Emacs with `EMACS_HYPERVISOR_BIN`:

```bash
EMACS_HYPERVISOR_BIN=/path/to/emacs-hypervisor \
  emacs --init-directory ~/.config/emacs
```

`EMACS_HYPERVISOR_BIN` is an absolute or relative path to the host binary the
generated `init.el` should launch. It wins over `PATH` lookup and is useful for
temporary testing, GUI launches, and installations where the binary is not in
Emacs's inherited environment.

## Subcommands

| Command | Purpose |
|---|---|
| `emacs-hypervisor` | Start the stdio backend (alias for `serve`) |
| `emacs-hypervisor serve` | Start the stdio backend explicitly |
| `emacs-hypervisor init [--home DIR] [--upgrade]` | Write or refresh generated bootstrap files in an Emacs home |
| `emacs-hypervisor env [--home DIR] [-o FILE]` | Write a shell environment snapshot |
| `emacs-hypervisor check [--home DIR] [--emacs PATH] [--format human\|sexp] [--strict]` | Validate the config structurally without executing it |

### `check`

`check` runs a plan-only Hypervisor session in batch Emacs: the config is
tangled and loaded, the dependency graph is built, and preflight, planning,
and structural lint findings are reported — but no package is installed and
no config-unit body is executed. The verdict reuses the exact graph,
preflight, and planning code that real startup uses, so a passing `check`
means startup planning will agree.

Exit codes: `0` no findings (lint warnings allowed unless `--strict`),
`1` invalid or failed planned items, `2` harness errors (Emacs missing,
home not initialized, no shutdown received). This makes a dotfiles repo
CI-able: run `emacs-hypervisor check` on every push.

Default Emacs home: `$XDG_CONFIG_HOME/emacs` if set, otherwise
`$HOME/.config/emacs`.

Default Hypervisor config directory: `$XDG_CONFIG_HOME/emacs-hypervisor` if
set, otherwise `$HOME/.config/emacs-hypervisor`.

## Generated Home Layout

Do not edit generated files in the Emacs home. The generated `early-init.el`
loads the user-owned `early-init.el` from the Hypervisor config directory when
that file exists.

```text
~/.config/emacs/
├── init.el        # generated, managed by Hypervisor
├── early-init.el  # generated proxy to Hypervisor config early-init.el
└── env            # optional, generated by `emacs-hypervisor env`
```

```text
~/.config/emacs-hypervisor/
├── early-init.el    # optional, user-owned startup customization
├── config.org       # literate config (preferred, auto-tangled)
├── config.el        # plain config fallback
└── hypervisor.lock  # installed package revisions, written by Hypervisor
```

`hypervisor.lock` lives beside your config so it travels with your dotfiles
repo --- commit it. See [Package Lockfile](#package-lockfile).

## Reference

### `package!` options

Bare `(package! consult)` installs from `package-archives`. Any of `:repo`,
`:host`, or `:local` switches to the package-vc bridge (git clone of the
upstream source, then adoption via `package-vc-install-from-checkout`).
`Package-Requires:` deps are resolved against the archives either way.

| Option | Purpose |
|---|---|
| `:repo` | Git repository (e.g. `"magit/magit"`); a full URL is used as-is |
| `:host` | Git host (`"github"` (default), `"gitlab"`, `"codeberg"`, `"sourcehut"`) |
| `:branch` | Branch to track |
| `:tag` | Tag to pin |
| `:ref` | Exact commit to pin |
| `:local` | Local filesystem path instead of a remote URL |
| `:lisp-dir` | Subdirectory containing the `.el` files (rare; for non-standard layouts) |
| `:deps` | Package dependencies (used by Elle's topological sort) |
| `:submodules` | Non-nil: `git submodule update --init --recursive` in the checkout (package-vc does not fetch submodules) |
| `:build` | Shell command (or list of commands) run in the package root after submodules, before activation — e.g. to compile a native/WASM artifact not committed to the repo |

`:submodules` and `:build` run in the cloned checkout before
`package-vc-install-from-checkout`, so the artifacts are present when the
package is symlinked, byte-compiled, and activated. Example for a package whose
UI is compiled locally from a bundled submodule:

```elisp
(package! emacs-parquet-explorer
  :local "~/projects/emacs-parquet-explorer"
  :lisp-dir "lisp"
  :submodules t
  :build "cd ui && wasm-pack build --target web --release")
```

### Package Rebuilding

For local package development (using `:local` paths), changes made in your local repository are not loaded live automatically. The package bridge clones the source into a staging directory (`~/.config/emacs/hypervisor/sources/<pkg-name>`) and prepares/builds it before adoption into `packages/<pkg-name>`.

To force a clean rebuild of a package (which drops staging/package caches, re-clones the latest commits, re-runs the `:build` step, and reinstalls):

- **In-Session Interactive Command:** Run `M-x emacs-hypervisor-rebuild-package` inside Emacs. It provides autocompletion for all declared packages.
- **Environment Variable:** Launch Emacs or start the session with the `EMACS_HYPERVISOR_REBUILD_PACKAGES` environment variable set to a comma-separated list of packages to rebuild:

  ```bash
  EMACS_HYPERVISOR_REBUILD_PACKAGES=emacs-parquet-explorer emacs --init-directory ~/.config/emacs
  ```

### Package Lockfile

Hypervisor records every concretely installed package revision in
`hypervisor.lock`, next to `config.org` in the Hypervisor config directory —
commit it with your dotfiles. VC packages record the adopted commit
(`git rev-parse HEAD` of the staging clone); archive packages record the
installed version. Entries are sorted by name and rewritten atomically, so
VCS diffs stay stable.

Resolution precedence at install time: a declared `:ref`/`:tag` always wins
(and rewrites the lock to match), then the locked revision, then the
branch or default HEAD (whose result is written to the lock). A fresh
install from `config.org` + `hypervisor.lock` therefore reproduces the
revisions of the machine that wrote the lock. `:local` packages never
resolve through the lock. Already-installed packages without a lock entry
are backfilled on startup, so adopting the lockfile on an existing home is
automatic.

### Package Upgrade

Upgrading means: ignore the lock, honor the declaration.

- **`M-x emacs-hypervisor-upgrade-package`** — upgrade one declared package
  (with completion). Packages pinned by `:ref`/`:tag` report "pinned" and
  are skipped.
- **`M-x emacs-hypervisor-upgrade-all-packages`** — upgrade everything.
- **`EMACS_HYPERVISOR_UPGRADE_PACKAGES=name1,name2`** (or `all`) — upgrade
  during startup, analogous to `EMACS_HYPERVISOR_REBUILD_PACKAGES`.

Upgrades reuse the clean-rebuild path, rewrite the lock entry, and report
the revision delta (`Upgraded magit: 0aa2686 -> 4f81c9d`).

### Package Prune

Packages removed from your config stay installed until pruned. At startup,
Hypervisor reports installed-but-undeclared packages (the keep set includes
the transitive `Package-Requires` closure of declared packages, so archive
dependencies are never flagged). **`M-x emacs-hypervisor-prune-packages`**
lists the orphans and removes them after confirmation, including their
staging clones, native-compiled artifacts, and lock entries. Nothing is
ever deleted automatically.

### `config-unit!` options

| Option | Purpose |
|---|---|
| `:after` | Run this unit only after the named units have completed |
| `:requires` | Load these package features before running the body |
| `:env` | Skip this unit if any of these environment variables are unset |
| `:executable` | Skip this unit if any of these binaries are missing from `PATH` |
| `:config` | The configuration body |

### Elisp bootstrap variables

Set these in the Hypervisor config `early-init.el` before the generated
`init.el` runs.

| Variable | Default | Purpose |
|---|---|---|
| `emacs-hypervisor-config-file` | `config.el` in Hypervisor config directory | Plain config file to load when `config.org` is absent |
| `emacs-hypervisor-config-org-file` | `config.org` in Hypervisor config directory | Literate config to tangle and load when present. One path, or an ordered list of paths tangled in list order |
| `emacs-hypervisor-env-file` | `env` in Emacs home | Env snapshot file (or `EMACS_HYPERVISOR_ENV_FILE`) |
| `emacs-hypervisor-binary-name` | `"emacs-hypervisor"` | Binary name for `PATH` lookup |
| `emacs-hypervisor-open-buffer-on-abnormal-exit` | `t` | Show process buffer on abnormal exit |

Startup uses three diagnostic buffers: ` *emacs-hypervisor*` is the stdio
protocol buffer, ` *emacs-hypervisor details*` receives incidental output from
Emacs-side runtime evaluation, and ` *emacs-hypervisor stderr*` receives
stderr from the host subprocess.

### Runtime variables

Set these in your `config.org` or `config.el`. They take effect during the
startup session.

| Variable | Default | Purpose |
|---|---|---|
| `emacs-hypervisor-show-report-on-startup` | `nil` | When non-nil, display the startup report after package processing finishes, or at the first config-unit when there is no package work. The report always appears when a config-unit fails, regardless of this setting. |
| `emacs-hypervisor-display-initial-buffer-on-finish` | `t` | When the startup report is hidden, display `initial-buffer-choice` after a clean startup. |
| `emacs-hypervisor-clone-concurrency` | `8` | Maximum number of parallel git clones during initial package install. |
| `emacs-hypervisor-default-host` | `"github"` | Host assumed for `:repo` shorthand when no `:host` is given. |

## Extension Design

Extensions keep the Elle control plane alive after startup so Emacs can send
typed requests over the existing `sexp-rpc` pipe. They are local-only: no
network listener is opened, and Emacs sends data payloads rather than remote
`:eval` forms.

Extensions activate automatically: when an extension's backing native plugin
is embedded in the binary and loads successfully, its handler is registered
and the extension is available for the whole session. There is no opt-in
option and no startup validation step — if a plugin fails to import, its
extension key is simply absent from the handler registry, and any later
`:extension-call` request for it receives a per-request
`extension-unavailable` error.

The extension layer is intentionally separate from individual extension features:

- `emacs-hypervisor-extensions.el` owns extension feature settings
  registration (feature modules contribute settings plists that travel to
  Elle in the session data).
- `elle/extensions.lisp` owns extension request dispatch and handler lookup.
- Each extension feature adds its own Emacs runtime module and Elle handler module.

Future extensions should follow the same shape: add any required Elle plugin,
add one feature-specific runtime module that registers its settings, then add
one Elle handler module that registers its extension methods with the generic
dispatcher.

### Mermaid Extension

The first extension feature renders Mermaid diagrams in Markdown buffers through
the Elle [`mmdflux`](https://github.com/kevinswiber/mmdflux#readme) plugin.
Mermaid rendering is available once the binary is built with the `mmdflux`
plugin (`just build`) — no configuration required.

Hypervisor installs `emacs-hypervisor-markdown-mermaid-mode` for
`markdown-mode`, `markdown-ts-mode`, and `gfm-mode`. The mode renders a bounded
preview below fenced Mermaid blocks natively as a vector SVG image, falling back to ASCII art
otherwise. Previews display the compatible SVG returned by mmdflux directly. The inline image preview is capped by
`emacs-hypervisor-markdown-mermaid-preview-max-width` and
`emacs-hypervisor-markdown-mermaid-preview-max-height`, which default to the
current `fill-column` width and 30% of the current window height. This mirrors
Org's inline-image posture: previews stay inside the editing context, and full
inspection happens in an image viewer.

Click an image preview with mouse-1 to open the full diagram in a dedicated image
viewer buffer. The viewer uses standard Emacs image-mode navigation and adds
visible header-line hints for zoom, fit, refresh, source jump, and quit.
Viewer buffers are backed by SVG cache files under the Hypervisor
temporary cache directory and are cleaned up automatically when Emacs exits.

The Mermaid keybindings are:

| Context | Key | Action |
|---|---|---|
| Markdown source buffer | `C-c C-r` | Refresh Mermaid previews in the current buffer. |
| Inline image preview | mouse-1 | Open the full diagram viewer. |
| Mermaid viewer | `+` or `=` / `-` | Enlarge or shrink the image. |
| Mermaid viewer | `0` | Show the image at original size. |
| Mermaid viewer | `w` | Fit the image to the window width. |
| Mermaid viewer | `f` | Fit the full image to the window. |
| Mermaid viewer | `g` | Refresh the viewer from the original source block. |
| Mermaid viewer | `RET` | Jump back to the original Markdown block. |
| Mermaid viewer | `q` | Close the viewer window. |

The Mermaid display commands are:

| Command | Purpose |
|---|---|
| `emacs-hypervisor-markdown-mermaid-open-viewer` | Open the full image viewer for the inline preview at point. |
| `emacs-hypervisor-markdown-mermaid-open-viewer-at-mouse` | Open the viewer from the clicked image preview. |
| `emacs-hypervisor-markdown-mermaid-refresh-viewer` | Re-render the viewer from the original source block. |
| `emacs-hypervisor-markdown-mermaid-close-viewer` | Close the current Mermaid viewer window. |
| `emacs-hypervisor-markdown-mermaid-jump-to-source` | Return from the viewer to the original Markdown block. |

Set `emacs-hypervisor-markdown-mermaid-render-style` to `:svg`, `:ascii`, or
`:auto` to choose explicitly. Emacs sends the current window width with each
request, and the Elle `mmdflux` plugin uses that width as a fit hint for ASCII
output.

When window configurations change (such as during window splits or frame
resizing), the Mermaid overlays automatically re-render (debounced) to fit the
new viewport column width dynamically.

Customize the text/ASCII diagram styling using the variable:

* `emacs-hypervisor-markdown-mermaid-ascii-style`: Choose the text layout style:
  - `unicode` (default): Uses elegant box-drawing Unicode characters (e.g. `┌`, `┐`, `─`, `│`) for clean vector-like drawing in plain text.
  - `ansi`: Employs Unicode box-drawing characters alongside terminal-style ANSI escape colorization.
  - `ascii`: Falls back to standard plain old ASCII (`+`, `-`, `|`).

SVG rendering uses `mermaid-layered` layout and `lossless` path simplification
by default, while theme and theme mode are left to mmdflux unless configured.
Tune the renderer with:

| Option | Default | Purpose |
|---|---|---|
| `emacs-hypervisor-markdown-mermaid-layout-engine` | `"mermaid-layered"` | Selects the mmdflux layout engine. |
| `emacs-hypervisor-markdown-mermaid-edge-preset` | `nil` | Optional mmdflux edge preset override. |
| `emacs-hypervisor-markdown-mermaid-path-simplification` | `"lossless"` | Controls routed SVG path simplification. |
| `emacs-hypervisor-markdown-mermaid-theme` | `nil` | Optional mmdflux SVG theme override. |
| `emacs-hypervisor-markdown-mermaid-theme-mode` | `nil` | Optional mmdflux SVG theme output mode override. |
| `emacs-hypervisor-markdown-mermaid-ascii-style` | `'unicode` | Style for text renders: `unicode`, `ansi`, or `ascii`. |

The Emacs option names mirror mmdflux render controls. See the
[`mmdflux` docs](https://github.com/kevinswiber/mmdflux#readme) for accepted
values and renderer-specific behavior.

The binary must be built with the matching runtime Elle plugin available.
Runtime Elle plugin defaults live in `.elle-plugins`, so the standard build
first builds `mmdflux` and then embeds the plugin library bytes into the
`emacs-hypervisor` binary:

```bash
just build
```

For local development that also needs MCP Elle plugin artifacts, build through
the developer recipe:

```bash
just dev
```

`just dev` keeps the normal Hypervisor build path and also builds Elle's local
MCP Elle plugin artifacts. `just install` depends on `just dev`, so local Emacs
testing leaves Codex MCP support ready too.

For a local install, only the host binary is copied:

```bash
just install
```

At runtime, embedded Elle plugins are written to a private cache directory and
prepended to Elle's module search path before Hypervisor starts. This keeps
distribution to one file while still satisfying the operating system dynamic
loader.

Set `EMACS_HYPERVISOR_ELLE_PLUGINS` to override the runtime Elle plugin list for
ad hoc builds. Set `EMACS_HYPERVISOR_ELLE_PLUGIN_CACHE_DIR` to override the
runtime extraction cache root.

## Development

For working on Hypervisor itself, not normal user configuration.

```bash
just build                   # build runtime Elle plugins and binary
just dev                     # same build, plus MCP Elle plugin artifacts
just clean                   # remove rebuildable local artifacts and caches
just fmt                     # format Elle Lisp files at 120 columns
just install-hooks           # enable repo Git hooks
just test                    # run tests
just analyze-runtime         # compile-aware analysis after Elle changes
just emacs-home-e2e-reset    # full live Emacs home test from a clean home
```

Step-by-step live testing: `just emacs-home-e2e-reset`

The build uses a repo-local Elle checkout (`.elle`, pinned by `.elle-ref`).
`scripts/bootstrap-elle` clones it and applies the repo-maintained fixes in
`patches/elle/*.patch` on top of the pinned ref --- currently two:

- `0001-region-match-rest-alias-borrow.patch`
  ([elle-lisp/elle#999](https://github.com/elle-lisp/elle/issues/999)): a
  `(a & rest)` pattern binds `rest` to a borrowed subview of the scrutinee
  with no owning reference, so passing it as an owned-param call argument
  (e.g. a recursive `match` walk over a `map`-built list) freed the caller's
  still-live scrutinee region. The lowerer marks these bindings borrowed and
  mints the callee's release.
- `0002-io-stdin-readline-past-buffer.patch`: `port/read-line` reserves 64 KiB,
  but a line has no upper bound and the worker reads to the newline however far
  away it is. Sockets and files already answer such a line whole, through
  `complete_port_op` / `read_result`; stdin has its own worker and its own
  converter, and `stdin_to_completion` still clamped the worker's bytes to the
  reservation and dropped the rest. Since this transport is stdin, any config
  whose session-data message exceeds 64 KiB made the host read a truncated
  s-expression and exit 1 during Emacs startup. The stdin converter now routes
  through `process_raw_completion` like the pool one does.

Patches are candidates for upstream submission and are reverted/reapplied
idempotently across ref changes.

## Further Reading

| Document | Topic |
|---|---|
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | sexp-rpc message shape and failure payloads |
| [`docs/architecture.md`](docs/architecture.md) | Three-stage bootstrap, Lisp-to-Lisp data flow, source map |
| [`docs/architecture-mermaid.md`](docs/architecture-mermaid.md) | Architecture diagrams (Mermaid) |
| [`docs/emacs-image-horizontal-scroll.md`](docs/emacs-image-horizontal-scroll.md) | Horizontal scrolling over inline image previews |
| [`docs/reload.md`](docs/reload.md) | Selective reload design, effect-aware reload API |
| [`docs/effect-system.md`](docs/effect-system.md) | Effect registry contract, adding new effect kinds |
| [`docs/spec-lockfile-check-source-map.md`](docs/spec-lockfile-check-source-map.md) | Lockfile, `check`, and source-mapping design and status |
| [`docs/rfc-extension-manifest.md`](docs/rfc-extension-manifest.md) | Manifest-based extension packaging (discussion draft) |
| [`host/README.md`](host/README.md) | Generated-home bootstrap rules |
| [`host/ELISP-PACK.md`](host/ELISP-PACK.md) | Static Elisp packing boundary |
