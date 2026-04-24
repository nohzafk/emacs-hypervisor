# Native Host Workflow

`emacs-hypervisor` is the shipped native binary. The repo also keeps a small
`bin/emacs-hypervisor` wrapper as a developer convenience for local builds.

## Normal Usage

Run the native host directly:

```bash
emacs-hypervisor
emacs-hypervisor serve
```

Initialize a fresh Emacs home with the minimal resident bootstrap:

```bash
emacs-hypervisor init
```

Write an env snapshot file for the Emacs home:

```bash
emacs-hypervisor env
```

Build just the native host artifact in the repo:

```bash
tools/build-hypervisor
```

The native host defaults to the embedded backend path:

- uses `target/release/emacs-hypervisor`
- auto-builds it when missing
- runs the embedded Elle backend and embedded helper Elisp sources

## Repo Wrapper

The repo-local wrapper at `bin/emacs-hypervisor` is only for development inside
this checkout. It forwards to the built binary under `target/`.

Two environment variables shape that wrapper behavior:

- `EMACS_HYPERVISOR_BUILD_MODE`
  - `auto` (default): build the native binary if it does not exist
  - `always`: rebuild before every launch
  - `never`: do not build automatically

- `EMACS_HYPERVISOR_DEBUG`
  - `0` (default): use `target/release/emacs-hypervisor`
  - `1`: use `target/debug/emacs-hypervisor`

Examples:

```bash
EMACS_HYPERVISOR_BUILD_MODE=always bin/emacs-hypervisor
EMACS_HYPERVISOR_DEBUG=1 bin/emacs-hypervisor
EMACS_HYPERVISOR_BUILD_MODE=never bin/emacs-hypervisor
```

## Emacs Startup

Generated installed-user `init.el` resolves `emacs-hypervisor` in two phases:

- first from `EMACS_HYPERVISOR_BIN` or the launch-environment `PATH`
- then, if still unresolved, again after loading the home `env` file

Once resolved, startup caches the absolute binary path before launching the
subprocess.

The repo-root development `init.el` still prefers the repo-local wrapper for
convenience during local iteration.

## Init Behavior

`emacs-hypervisor init` detects the Emacs home directory and defaults to
`~/.config/emacs` (or `XDG_CONFIG_HOME/emacs` when set).

Safety rule:

- if the target Emacs home already exists and is not empty, `init` aborts

Generated files:

- `init.el`
- `lisp/emacs-hypervisor-bootstrap.el`
- `lisp/emacs-hypervisor-sexp-rpc.el`
- `lisp/emacs-hypervisor-session-state.el`

User-owned files remain separate:

- `early-init.el`
- `config.el`
