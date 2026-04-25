# Host Bootstrap Rules

`host/` builds the shipped native `emacs-hypervisor` binary. `emacs-hypervisor
init` writes a single bundled `init.el` into the provisioned Emacs home. The
authored bootstrap source stays split under `host/emacs-kernel/`; the
generated file is the deployment artifact and follows a strict bootstrap rule
for finding the host executable.

## Binary Resolution Order

The generated bootstrap resolves the host binary in this order:

1. prefer `EMACS_HYPERVISOR_BIN` if it is already set in Emacs's launch environment
2. otherwise try `executable-find` on the launch environment `PATH`
3. load the repo/home `env` file if present
4. if still unresolved, try `EMACS_HYPERVISOR_BIN` / `PATH` again after the env file changes the environment
5. cache the resolved absolute path and launch the subprocess with that cached path

This means:

- `env` is not required for bootstrap
- if `EMACS_HYPERVISOR_BIN` is set, it wins
- otherwise the binary only needs to be reachable from `PATH`
- the env file may help resolution, but it is not the only bootstrap path

## Why The Two-Phase Lookup Exists

The generated `env` file can rewrite `PATH`, `exec-path`, and related process
environment state inside Emacs. If bootstrap only resolved the binary after
loading `env`, a stale or narrow env snapshot could accidentally hide a working
`emacs-hypervisor` already present in the original launch environment.

Resolving before and after env loading gives the desired behavior:

- keep explicit override support via `EMACS_HYPERVISOR_BIN`
- preserve launch-time `PATH` success when it already works
- still allow env-driven resolution when a user intentionally provides it there

## Practical Usage

Installed-user flow:

```bash
emacs-hypervisor init --home ~/.config/emacs
emacs-hypervisor env --home ~/.config/emacs
emacs --init-directory ~/.config/emacs
```

Each generated Emacs home is isolated. Runtime state, package installs, and
local caches live under that selected home.

Generated homes contain `init.el` as the managed bootstrap artifact. User
configuration belongs in `config.el`, and environment snapshots belong in
`env`.

The kernel files still keep normal `require`/`provide` module boundaries so
development and tests can load them directly with `-L host/emacs-kernel`.

Temporary testing with an explicit binary path:

```bash
EMACS_HYPERVISOR_BIN=/path/to/emacs-hypervisor emacs --init-directory /tmp/test-home
```

Temporary testing with `PATH` only:

```bash
PATH=/path/to/bin:$PATH emacs --init-directory /tmp/test-home
```

## `elisp_pack`

`elisp_pack` is an internal Rust library scoped to static Elisp modules under
`elle/runtime-forms/`.

- the shipped runtime is embedded into the host at build time
- `session-base` uses packed `:forms`, the rest currently embed source text
- the generic Elle loader consumes embedded module specs only
- `host/emacs-kernel/` bootstrap files are bundled into generated `init.el`
  separately and are not part of `elisp_pack`

See `host/ELISP-PACK.md` for the design boundary and future structured-pack path.
