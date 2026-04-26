# Emacs Hypervisor

A single native binary for deterministic, reloadable Emacs configuration
orchestration.

Hypervisor is a small foundation for building your own Emacs config, not a
distribution. You keep ownership of `config.org` (or `config.el`); Hypervisor
provides package declarations, config-unit declarations, dependency planning,
reload support, and a Lisp-native control plane around Emacs.

## Motivation

Hypervisor grew out of
[`emacs-backbone`](https://github.com/nohzafk/emacs-backbone), which treated
Emacs config as a dependency graph instead of a long, order-sensitive script.
Three ideas drove the evolution from Backbone to Hypervisor:

**Config as a fault-tolerant dependency graph.** Backbone proved that
topological sorting and explicit dependencies make config deterministic. Hypervisor
takes this further: startup becomes an observable orchestration session with
preflight checks, failure propagation, execution plans, and reports. The
long-term direction is Erlang-style supervisor trees for config units.

**Lisp-to-Lisp homoiconicity.** Backbone used Gleam + JSON-RPC to communicate
with Emacs --- any language can talk to Emacs over a wire protocol, but using
another Lisp has a unique advantage: config-unit bodies travel as structured
Lisp data, not opaque strings. Elle (a Janet-like Lisp over Rust) can inspect
and rewrite Elisp forms directly. This powers effect-aware reload: Hypervisor
can recognize `(add-hook 'my-hook (lambda () ...))`, rewrite the lambda to a
named function, and automatically remove it before re-applying the unit.

**Single binary, no framework to clone.** Traditional Emacs config frameworks
require cloning a repo into `~/.config/emacs` because Emacs must load an
`init.el` written in Elisp. Hypervisor compiles to a single binary with all
Elle source and runtime Elisp embedded. Your Emacs home contains generated
bootstrap files, while your own `config.org` or `config.el` lives in the
Hypervisor config directory.

## User-Facing Model

The entire user-facing surface is two macros:

| Macro | Purpose |
|---|---|
| `package!` | Declare packages and their dependencies |
| `config-unit!` | Declare named blocks of configuration |

This gives you a bare framework for organizing your own configuration. It does
not choose your packages, keybindings, UI, editing model, or workflow.

## Features

- **Single binary** --- `emacs-hypervisor` with the embedded Elle backend,
  runtime Elisp, and all orchestration logic.
- **Generated bootstrap** --- a small trusted kernel in the Emacs home; your
  config lives in the Hypervisor config directory.
- **Literate config** --- `config.org` is auto-tangled at startup and reload;
  no manual tangle step needed.
- **Elpaca-backed packages** --- `package!` declarations feed into Elpaca for
  installation.
- **Topological sorting** --- packages and config units resolve in deterministic
  order.
- **Preflight checks** --- missing packages, missing dependencies, cycles, env
  vars, executables, and required features are caught before execution.
- **Eager, fail-fast startup** --- surface errors immediately instead of hiding
  them behind lazy loading.
- **Selective reload** --- apply only new and changed units in a running session.
- **Effect-aware reload** --- automatically clean old hooks and advice before
  re-applying a changed unit.
- **Startup reports** --- progress events, package events, status inspection,
  and optional metrics.

## Why Eager Startup

Hypervisor treats startup as the place to prove your config is internally
consistent. Lazy loading can hide broken config until hours into a session,
when the original context is gone. Hypervisor takes the opposite tradeoff:
resolve the graph, run config units in deterministic order, surface errors
immediately.

Eager does not mean force-loading every package. `:requires` should be used
only when the body truly needs a feature loaded first (package-local variables,
keymaps, macros, non-autoloaded functions). Hook registration, global
keybindings, autoloaded commands, and pre-load-safe variable setup can run
eagerly without `:requires`.

## Reload

### Selective Reload

`M-x emacs-hypervisor-reload-config` reloads `config.org`, when present, or
`config.el` in a running session. It diffs the previous declarations against
the new ones:

- **Unchanged** units are skipped.
- **New** and **changed** units are applied.
- **Removed** units are not evaluated again.

Edit one unit without replaying every package integration, mode setup, and hook
registration in the session.

### Effect-Aware Reload

Before re-applying a changed unit, Hypervisor cleans up recognized effects from
the previous version. This prevents the most common reload drift in long-lived
sessions: duplicate hook entries, duplicated advice, and stale generated
functions.

```elisp
;; On reload, the old hook entry is removed before the new body is applied
(config-unit! project-hooks
  :config
  (add-hook 'prog-mode-hook #'display-line-numbers-mode))

;; On reload, the old advice is removed before the new body is applied
(config-unit! save-behavior
  :config
  (advice-add 'save-buffer :before #'delete-trailing-whitespace))
```

The recognizer is intentionally conservative. Unknown or computed effects are
reported as **opaque** instead of being reset unsafely.

| Recognized form | Cleanup action |
|---|---|
| `(add-hook 'HOOK FN)` | `(remove-hook 'HOOK FN)` |
| `(add-hook 'HOOK FN DEPTH)` | `(remove-hook 'HOOK FN)` |
| `(add-hook 'HOOK FN DEPTH nil)` | `(remove-hook 'HOOK FN)` |
| `(advice-add 'TARGET WHERE FN)` | `(advice-remove 'TARGET FN)` |

### Anonymous Lambdas

Anonymous functions are normally impossible to remove because each reload
creates a new lambda object. Hypervisor rewrites hook and advice lambdas to
generated named functions before installing them:

```elisp
;; You write:
(config-unit! text-editing
  :config
  (add-hook 'text-mode-hook
            (lambda () (setq-local fill-column 80))))

;; Hypervisor emits:
(defalias 'emacs-hypervisor--generated--text-editing--add-hook--text-mode-hook--HASH
  #'(lambda () (setq-local fill-column 80)))
(add-hook 'text-mode-hook
          #'emacs-hypervisor--generated--text-editing--add-hook--text-mode-hook--HASH)
```

On the next reload, the old named function is removed from the hook before the
new body is applied. This is the Lisp-to-Lisp advantage: the unit body is
structured Lisp data, so Hypervisor can recognize the form and emit a safer
version without string parsing.

## Literate Config (config.org)

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

`M-x emacs-hypervisor-reload-config` also tangles `config.org` before reloading,
so edits to the Org file take effect immediately.

Tangling uses Emacs's built-in `org-babel-tangle-file` with a language filter
for `elisp` and `emacs-lisp`. The typical overhead is under 200ms for a
2000-line config.

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
| `emacs-hypervisor init [--home DIR]` | Write generated bootstrap files into an Emacs home |
| `emacs-hypervisor env [--home DIR] [-o FILE]` | Write a shell environment snapshot |

Default Emacs home: `$XDG_CONFIG_HOME/emacs` if set, otherwise
`$HOME/.config/emacs`.

Default Hypervisor config directory: `$XDG_CONFIG_HOME/emacs-hypervisor` if
set, otherwise `$HOME/.config/emacs-hypervisor`.

## Generated Home Layout

Do not edit generated files in the Emacs home. The generated `early-init.el`
loads the user-owned `early-init.el` from the Hypervisor config directory when
that file exists.

```
~/.config/emacs/
├── init.el        # generated, managed by Hypervisor
├── early-init.el  # generated proxy to Hypervisor config early-init.el
└── env            # optional, generated by `emacs-hypervisor env`
```

```
~/.config/emacs-hypervisor/
├── early-init.el  # optional, user-owned startup customization
├── config.org     # literate config (preferred, auto-tangled)
└── config.el      # plain config fallback
```

## Reference

### `package!` options

| Option | Purpose |
|---|---|
| `:repo` | Git repository (e.g. `"magit/transient"`) |
| `:host` | Git host (`"github"`, `"gitlab"`, etc.) |
| `:branch` | Branch to track |
| `:tag` | Tag to pin |
| `:ref` | Exact ref to pin |
| `:files` | File patterns to include |
| `:deps` | Package dependencies |
| `:local` | Local filesystem path |
| `:no-compilation` | Skip native compilation |

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
| `emacs-hypervisor-config-org-file` | `config.org` in Hypervisor config directory | Literate config file to tangle and load when present |
| `emacs-hypervisor-env-file` | `env` in Emacs home | Env snapshot file (or `EMACS_HYPERVISOR_ENV_FILE`) |
| `emacs-hypervisor-binary-name` | `"emacs-hypervisor"` | Binary name for `PATH` lookup |
| `emacs-hypervisor-open-buffer-on-abnormal-exit` | `t` | Show process buffer on abnormal exit |

## Architecture

One rule: **Emacs keeps a small trusted kernel; Elle owns orchestration
policy.**

```mermaid
flowchart TD
    subgraph Emacs
        Kernel["trusted kernel<br/>sexp-rpc · session state · eval surface"]
        Decls["package! / config-unit! declarations"]
        Runtime["emitted runtime helpers<br/>Elpaca bridge · unit execution · reload · reports"]
    end

    subgraph Binary["emacs-hypervisor binary"]
        Elle["Elle backend"]
        Embedded["embedded Elle source + runtime Elisp"]
    end

    Kernel <-- "sexp-rpc over stdio" --> Elle
    Decls -- "export session data" --> Elle
    Elle -- "emit forms via :eval" --> Runtime
    Embedded -. "bundled at compile time" .-> Elle
```

| Layer | Lifetime | Owns |
|---|---|---|
| **Emacs kernel** | Resident, small | Process startup, session state, sexp-rpc dispatch, `package!` / `config-unit!` macros, trusted `:eval` surface |
| **Elle backend** | Runs in binary | Dependency graphs, preflight checks, boot policy, execution ordering, failure propagation, reports |
| **Runtime forms** | Transient, per session | Elpaca bridge, unit execution, reload, report rendering --- execution substrate, not a second policy engine |

### Three-Stage Bootstrap

```mermaid
flowchart LR
    subgraph S1["Stage 1 — Stable Kernel"]
        direction TB
        A["Emacs home"] --> B["load generated init.el"]
        B --> C["kernel boots"]
    end

    subgraph S2["Stage 2 — Control Plane"]
        direction TB
        D["launch emacs-hypervisor serve"]
        D --> E["sexp-rpc session established"]
    end

    subgraph S3["Stage 3 — Session Runtime"]
        direction TB
        F["emit runtime forms"]
        F --> G["package planning"]
        G --> H["config-unit execution"]
        H --> I["reload + reports ready"]
    end

    S1 --> S2 --> S3
```

**Stage 1 --- Stable kernel.** The generated `init.el` contains the trusted
Emacs kernel: process startup, session state, sexp-rpc parsing, request
dispatch, and the small eval surface used by the host.

**Stage 2 --- Control plane.** Emacs launches `emacs-hypervisor serve`, then
Emacs and Elle exchange request, response, and event messages over stdio using
S-expressions.

**Stage 3 --- Session runtime.** The binary embeds Elle source and runtime
Elisp forms; Elle sends them into Emacs for the current session, then runs
package planning, config-unit execution, reload support, reports, and shutdown.

### Lisp-to-Lisp Data Flow

The key invariant: **protocol metadata and code data are decoded with different
rules.** Protocol fields become normal Elle data for graph and planning code.
Config-unit `:body` fields remain raw Lisp code --- Elle never recursively
converts plist-like lists inside a body, because `(foo (:a 1 :b 2))` is
code/data, not a protocol plist.

The path through the system:

1. `config-unit!` captures the body as `(progn ... t)`.
2. Emacs canonicalizes reader-hostile forms while preserving semantics.
3. Emacs sends session data through sexp-rpc.
4. Elle decodes package, unit, and env metadata; each unit `:body` stays raw.
5. Elle emits `(emacs-hypervisor-runtime-run-unit NAME 'BODY 'REQUIRES)`.
6. Emacs evaluates the structured body directly.

This homoiconic surface is what makes structural inspection, targeted rewrites,
effect-aware reload, and interactive remediation practical without re-parsing
opaque strings.

## File Guide

```
emacs-hypervisor/
├── host/                              # Rust native host
│   ├── src/main.rs                    # CLI entrypoint (init, env, serve)
│   ├── build.rs                       # embeds Elle source + Elisp at compile time
│   ├── emacs-kernel/                  # trusted Emacs kernel (bundled into init.el)
│   │   ├── home-startup.el            #   home bootstrap wrapper
│   │   ├── emacs-hypervisor-bootstrap.el    #   process startup, sexp-rpc, eval surface
│   │   ├── emacs-hypervisor-session-state.el#   session state management
│   │   └── emacs-hypervisor-sexp-rpc.el     #   S-expression wire protocol
│   └── elisp_pack/                    # build-time Elisp packer (Rust crate)
│       └── src/lib.rs
│
├── elle/                              # Elle backend (embedded in binary)
│   ├── hypervisor.lisp                # backend entrypoint
│   ├── protocol.lisp                  # sexp-rpc helpers, wire decoding
│   ├── graph.lisp                     # dependency graph construction
│   ├── preflight.lisp                 # preflight validation checks
│   ├── boot-policy.lisp               # boot policy decisions
│   ├── planning.lisp                  # execution plan generation
│   ├── execution.lisp                 # config-unit execution
│   ├── runtime-forms.lisp             # coordinates emitted runtime modules
│   └── runtime-forms/                 # transient Elisp emitted per session
│       ├── module-loader.lisp         #   module loading coordinator
│       ├── emacs-hypervisor-declarations.el       #   package!/config-unit! macros
│       ├── emacs-hypervisor-elpaca-bridge.el       #   Elpaca integration
│       ├── emacs-hypervisor-package-runtime.el     #   package event handling
│       ├── emacs-hypervisor-unit-runtime.el        #   unit execution helpers
│       ├── emacs-hypervisor-session-base.el        #   session lifecycle
│       ├── emacs-hypervisor-selective-reload.el    #   reload diffing + scheduling
│       ├── emacs-hypervisor-effect-aware-reload.el #   effect detection + cleanup
│       ├── emacs-hypervisor-compose.el             #   wires reload into M-x command
│       ├── emacs-hypervisor-report-core.el         #   report data structures
│       └── emacs-hypervisor-report.el              #   startup report rendering
│
├── tests/
│   ├── elle/hypervisor-runtime.lisp               # Elle runtime semantics tests
│   └── elisp/emacs-hypervisor-bootstrap-test.el   # kernel + runtime helper tests
│
├── scripts/
│   └── analyze-runtime.lisp           # compile-aware analysis script
│
├── config.org                         # repo test configuration
├── config/                            # repo-local support files for config.org
├── early-init.el                      # repo test early-init
└── justfile                           # build, test, and dev commands
```

## Development

For working on Hypervisor itself, not normal user configuration.

```bash
just bootstrap-elle          # use repo-local Elle checkout
just build                   # build the binary
just test                    # run tests
just analyze-runtime         # compile-aware analysis after Elle changes
just emacs-home-live-test    # full live Emacs home test
```

Step-by-step live testing: `just build && just emacs-home-reset && just emacs-home-run`

## Further Reading

| Document | Topic |
|---|---|
| [`PROTOCOL.md`](PROTOCOL.md) | sexp-rpc message shape and failure payloads |
| [`LISP-TO-LISP-FUTURES.md`](LISP-TO-LISP-FUTURES.md) | Future capabilities from homoiconic config bodies |
| [`host/README.md`](host/README.md) | Generated-home bootstrap rules |
| [`host/ELISP-PACK.md`](host/ELISP-PACK.md) | Static Elisp packing boundary |
| [`PROJECT-LOG.md`](PROJECT-LOG.md) | Historical implementation context |
| `docs/` | Historical design notes and captured ideas |
