# Native Host

`host/` builds the `emacs-hypervisor` binary. The authored bootstrap source
lives under `host/emacs-kernel/`; `emacs-hypervisor init` bundles it into a
single generated `init.el` deployed to the Emacs home.

## Binary Resolution

The generated `init.el` resolves the host binary with a two-phase lookup:

| Phase | Steps |
|---|---|
| **Before env** | 1. Use `EMACS_HYPERVISOR_BIN` if set. 2. Try `executable-find` on the launch `PATH`. |
| **Load env** | 3. Load the home `env` file if present (may rewrite `PATH` / `exec-path`). |
| **After env** | 4. If still unresolved, try `EMACS_HYPERVISOR_BIN` / `PATH` again. 5. Cache the resolved absolute path. |

**Why two phases?** The `env` file can rewrite `PATH` and `exec-path` inside
Emacs. If bootstrap only resolved after loading `env`, a stale or narrow
snapshot could hide a working binary already present in the original launch
environment. Resolving before and after means:

- `EMACS_HYPERVISOR_BIN` always wins when set.
- A binary already on `PATH` works without an `env` file.
- The `env` file can still provide resolution when the user intends it.

## Commands

```bash
# Bootstrap an Emacs home
emacs-hypervisor init --home ~/.config/emacs
emacs-hypervisor env --home ~/.config/emacs
emacs --init-directory ~/.config/emacs

# Override the binary path for testing
EMACS_HYPERVISOR_BIN=/path/to/emacs-hypervisor emacs --init-directory /tmp/test-home

# Override PATH only
PATH=/path/to/bin:$PATH emacs --init-directory /tmp/test-home

# Run kernel tests directly
emacs --batch -Q \
  -L host/emacs-kernel \
  -L elle/runtime-forms \
  -L tests/elisp \
  -l tests/elisp/emacs-hypervisor-bootstrap-test.el \
  -f ert-run-tests-batch-and-exit
```

Each generated Emacs home is isolated --- runtime state, package installs, and
local caches live under that home. Kernel files keep normal `require`/`provide`
boundaries so development and tests can load them directly with
`-L host/emacs-kernel`.

## `elisp_pack`

Internal Rust library that packs static `.el` files under `elle/runtime-forms/`
into the binary at build time. Kernel files under `host/emacs-kernel/` are
bundled separately into the generated `init.el` and are not part of
`elisp_pack`.

See [`ELISP-PACK.md`](ELISP-PACK.md) for details.
