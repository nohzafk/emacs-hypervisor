# Emacs Hypervisor

`emacs-hypervisor` is an Elle-native external control plane for Emacs
configuration.

The current project direction is:

- transport: `stdio`
- lifecycle: session-scoped subprocess
- wire format: S-expressions
- protocol layer: `sexp-rpc`
- Emacs role: minimal trusted kernel + declaration/export + evaluation surface
- Elle role: graph resolution, boot policy, orchestration, and runtime code generation

This repository is still in spike mode.
The current implementation history lives in
[PROJECT-LOG.md](/Users/randall/projects/emacs-hypervisor/PROJECT-LOG.md).
The current architecture reset target lives in
[ARCHITECTURE-RESET.md](/Users/randall/projects/emacs-hypervisor/ARCHITECTURE-RESET.md).

## Layout

- [config.el](/Users/randall/projects/emacs-hypervisor/config.el)
  - primary repo config declarations source used when provisioning a test home
- [env](/Users/randall/projects/emacs-hypervisor/env)
  - optional env snapshot example in the same Lisp format emitted by `emacs-hypervisor env`
- [host/templates/lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/host/templates/lisp/emacs-hypervisor-bootstrap.el)
  - install-time trusted Emacs kernel template: process, framing, async filter, RPC dispatch
- [lisp/emacs-hypervisor-declarations.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-declarations.el)
  - `package!` and `config-unit!` declaration/export surface
- [elle](/Users/randall/projects/emacs-hypervisor/elle)
  - shared Elle protocol, graph, preflight, planning, execution, and hypervisor modules
  - this is the intended long-term home for orchestration and runtime policy
- [elle/runtime-forms.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms.lisp)
  - coordinator for Elle-emitted transient Emacs helper forms
- [elle/runtime-forms](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms)
  - split emitted runtime modules sent into Emacs at session startup
  - includes shared base state, Elpaca bridge/runtime, and unit execution helpers
- [experiments/elle](/Users/randall/projects/emacs-hypervisor/experiments/elle)
  - numbered Elle protocol and orchestration spikes
- [experiments/lisp](/Users/randall/projects/emacs-hypervisor/experiments/lisp)
  - numbered Elisp spike frontends
- [elle/hypervisor.lisp](/Users/randall/projects/emacs-hypervisor/elle/hypervisor.lisp)
  - non-spike Elle backend entrypoint using the shared runtime modules
- [PROTOCOL.md](/Users/randall/projects/emacs-hypervisor/PROTOCOL.md)
  - protocol notes and current message semantics
- [bin](/Users/randall/projects/emacs-hypervisor/bin)
  - user-facing helper entrypoints
  - includes `bin/hypervisor-env` to scrape the current shell environment into
    repo-root `env`
- [scripts](/Users/randall/projects/emacs-hypervisor/scripts)
  - developer analysis programs and MCP/tooling wrappers
- [experiments/bin](/Users/randall/projects/emacs-hypervisor/experiments/bin)
  - spike runners

## Home Environment Injection

Provisioned Emacs homes can load an environment snapshot before
[config.el](/Users/randall/projects/emacs-hypervisor/config.el) is evaluated.

- default file: `HOME/env` in the provisioned Emacs home
- override path: `EMACS_HYPERVISOR_ENV_FILE`
- format: Lisp list of `"KEY=VALUE"` strings, matching the Backbone env file
  shape

Generate/update the home-local env file from the current shell with:

```bash
emacs-hypervisor env --home /tmp/test-home
```

This is a real Emacs runtime injection step, not just Elle preflight data:

- updates `process-environment`
- rebuilds `exec-path` from injected `PATH`
- updates `shell-file-name`
- happens before `config.el` is loaded

## Agent Workflow With Elle Analysis And MCP

Elle already ships with analysis tools that are useful for working on this
repo. The relevant upstream docs are:

- [Elle analysis overview](https://github.com/elle-lisp/elle/blob/main/docs/analysis/README.md)
- [Agent reasoning](https://github.com/elle-lisp/elle/blob/main/docs/analysis/agent-reasoning.md)
- [MCP server](https://github.com/elle-lisp/elle/blob/main/docs/mcp.md)

For this codebase, an agent should use them in this order:

1. Understand the local Elle file with portrait-style analysis.
2. Query cross-file impact with MCP when a change crosses module boundaries.
3. Prefer compile-aware refactoring tools over blind text edits when changing Elle code at scale.
4. Re-analyze after edits so the semantic graph matches source reality.

### Local Analysis

Use local analysis first when working on shared files under
[elle](/Users/randall/projects/emacs-hypervisor/elle). Treat
[experiments/elle](/Users/randall/projects/emacs-hypervisor/experiments/elle)
as historical spike snapshots unless the task is explicitly about a spike.

Typical upstream pattern:

```lisp
(def a (compile/analyze (file/read "elle/boot-policy.lisp")
                        {:file "elle/boot-policy.lisp"}))
(def portrait-lib ((import "std/portrait")))
(println (portrait-lib:render (portrait-lib:module a)))
```

This is useful for checking:

- signal profile
- captures
- call relationships
- composition properties

Repo-local shortcut:

```bash
just analyze-runtime
```

This runs Elle local analysis over the shared modules under
[elle](/Users/randall/projects/emacs-hypervisor/elle).

### MCP / Knowledge Graph

Use MCP when the question is not local to one file.

Examples for this repo:

- what spikes call or depend on a shared runtime helper
- which functions reference protocol serialization or report derivation
- what changes would cascade if a runtime helper is renamed or split

Typical workflow:

1. start the Elle MCP server against a persistent store
2. analyze the relevant repo files
3. query the graph with SPARQL or `impact`
4. refactor with compile-aware tools if the change is structural

Upstream build/run commands from Elle:

```bash
make mcp
elle tools/mcp-server.lisp
```

Repo-local wrapper:

```bash
just bootstrap-elle
just start-elle-mcp
```

This wrapper:

- expects the repo-local Elle checkout at `.elle` by default
- uses the repo-local release binary at `.elle/target/release/elle` by default
- uses a repo-local graph store at `.elle-mcp/store`
- accepts `ELLE_MCP_SERVER` when the MCP server lives outside this repo
- checks common local locations such as:
  - `.elle/mcp/mcp-server.lisp`
  - `.elle/mcp/tools/mcp-server.lisp`

Current practical setup for this machine:

1. bootstrap the repo-local Elle checkout:
   - `just bootstrap-elle`
2. build the MCP plugins when needed:
   - `env LIBCLANG_PATH=/Applications/Xcode.app/Contents/Frameworks make -C .elle mcp`
3. start the repo wrapper:
   - `just start-elle-mcp`

The `LIBCLANG_PATH` detail matters here because the `elle-oxigraph` plugin
build goes through `bindgen` and needs `libclang.dylib`.

Verified on this machine:

- MCP `initialize`
- `tools/list`
- `tools/call` with `analyze_file` against
  [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp)
- `tools/call` with `analyze_file` against
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- `tools/call` with `analyze_file` against
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)
- `tools/call` with `impact` against `execute-package-entry-plan-tracker` in
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- `tools/call` with `impact` against `derive-package-plan` in
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp)

Examples of MCP tools that matter here:

- `analyze_file`
- `portrait`
- `sparql_query`
- `impact`
- `compile_rename`
- `compile_extract`
- `compile_parallelize`
- `trace`

### Practical Guidance For This Repo

Use normal repo editing for small, clearly bounded changes.
Reach for Elle analysis/MCP when:

- changing shared helpers in
  [elle/protocol.lisp](/Users/randall/projects/emacs-hypervisor/elle/protocol.lisp),
  [elle/graph.lisp](/Users/randall/projects/emacs-hypervisor/elle/graph.lisp),
  [elle/preflight.lisp](/Users/randall/projects/emacs-hypervisor/elle/preflight.lisp), or
  [elle/boot-policy.lisp](/Users/randall/projects/emacs-hypervisor/elle/boot-policy.lisp), or
  [elle/planning.lisp](/Users/randall/projects/emacs-hypervisor/elle/planning.lisp), or
  [elle/execution.lisp](/Users/randall/projects/emacs-hypervisor/elle/execution.lisp)
- renaming exported helper functions used by multiple spikes
- checking whether a refactor changes signal/capture behavior
- tracing Elle behavior into Rust primitives while debugging Elle semantics

The working rule is:

- source code is ground truth
- re-analysis keeps the graph honest
- MCP is for impact, structure, and safe refactoring
- portrait is for understanding one file deeply before changing it

## Current Next Step

The current next implementation step is:

1. freeze the trusted Emacs kernel boundary around
   [host/templates/lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/host/templates/lisp/emacs-hypervisor-bootstrap.el)
2. keep package/config execution policy and generated runtime forms in
   [elle](/Users/randall/projects/emacs-hypervisor/elle)
   and
   [elle/runtime-forms](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms)
3. keep using provisioned Emacs homes during testing
4. keep generated `init.el` as thin startup glue and avoid re-growing resident Emacs wrappers
5. keep using local analysis and MCP before structural changes to shared Elle modules
