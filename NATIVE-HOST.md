# Native Host Workflow

`emacs-hypervisor` is the shipped native binary.

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

Build the native host artifact in the repo:

```bash
just build
```

Common repo automation lives in `justfile`.

Canonical live test flow:

```bash
just live-test /tmp/test3
```

Equivalent step-by-step flow:

```bash
just build
just reset-home /tmp/test3
just run-emacs /tmp/test3
```

The built artifact lives at:

- `target/release/emacs-hypervisor`
- `target/debug/emacs-hypervisor` when built with the debug path

The native host runs the embedded Elle backend and embedded runtime helper
Elisp modules.

## Emacs Startup

Generated installed-user `init.el` resolves `emacs-hypervisor` in two phases:

- first from `EMACS_HYPERVISOR_BIN` or the launch-environment `PATH`
- then, if still unresolved, again after loading the home `env` file

Once resolved, startup caches the absolute binary path before launching the
subprocess.

Each initialized Emacs home is self-contained. Startup state, package installs,
and local caches stay under that home.

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
