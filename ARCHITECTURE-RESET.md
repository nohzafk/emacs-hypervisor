# Architecture Reset

`emacs-hypervisor` drifted away from its intended advantage.

The intended advantage was:

- Emacs and Elle both speak Lisp data directly
- Emacs stays tiny
- Elle owns orchestration, policy, and code generation
- Emacs mainly evaluates trusted forms and reports results

The current implementation still has the right transport direction, but too
much framework logic stayed resident in Emacs. That made the bootstrap heavier
than Emacs Backbone instead of simpler.

This document defines the reset target.

## Target Model

The desired architecture is:

- one real Emacs home
  - provisioned with `emacs-hypervisor init`
- one minimal trusted Emacs kernel
- one session-scoped Elle subprocess
- one Lisp-native protocol
- Elle generates the runtime Elisp needed for package installation and config
  execution

The core idea is:

- Emacs should not host a large permanent Hypervisor framework
- Elle should send code and plans into Emacs
- Emacs should stay close to a programmable evaluation surface

## Minimal Trusted Emacs Kernel

The trusted Emacs kernel should do only these things:

1. start the Elle subprocess
2. read framed S-expression protocol messages asynchronously
3. answer a very small set of core requests
4. evaluate explicit trusted forms
5. send back success, error, and event messages
6. maintain only the minimum local lifecycle state needed for startup and
   shutdown

That means the kernel is responsible for:

- process startup and sentinel handling
- async process filter
- message framing and parsing
- request/response correlation
- a small trusted `:eval` escape hatch
- declaration export for `package!` and `config-unit!`

That means the kernel is not responsible for:

- package planning policy
- package dependency resolution
- unit execution ordering
- preflight policy
- rich report derivation
- persistent package runtime helpers beyond what Elpaca itself requires

## Keep In Emacs

These pieces still belong in Emacs:

- [early-init.el](/Users/randall/projects/emacs-hypervisor/early-init.el)
  - ordinary user-owned early-init behavior for a provisioned Emacs home
- [host/templates/lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/host/templates/lisp/emacs-hypervisor-bootstrap.el)
  - trusted kernel
- [lisp/emacs-hypervisor-declarations.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-declarations.el)
  - declaration/export surface
- minimal generated `init.el` startup glue
  - emitted by `emacs-hypervisor init`

These files should shrink, not grow.

## Move To Elle

The following logic should move out of resident Emacs code and into Elle code
generation or Elle-side orchestration:

- Elpaca bootstrap form generation
- Elpaca compatibility/workaround policy
- package plan construction
- topological sorting
- package installation instruction generation
- unit execution sequencing
- preflight policy
- package-to-report derivation
- unit-to-report derivation
- boot policy decisions
- most runtime helper forms currently staged through shared Emacs runtime files

In the target design, Elle should be able to emit forms like:

- bootstrap Elpaca locally
- install package set in the required order
- evaluate config units in the required order
- report outcomes back to Elle using the protocol

## Shrink Or Delete In Emacs

These current concepts are transitional and should disappear or shrink
aggressively:

- `Stage 1` as a durable architecture concept
- separate `stage1 home`
- manager-root indirection unless explicitly required for a future use case
- large persistent helper layers in
  [lisp/emacs-hypervisor-elpaca.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-elpaca.el)
- extra local state machines that duplicate Elle-side orchestration

The working simplification rule is:

- if logic is policy, it belongs in Elle
- if logic is execution surface or trusted bridge behavior, it may stay in Emacs

## Current File Matrix

The current Emacs-side code should be treated like this:

### Keep

- [early-init.el](/Users/randall/projects/emacs-hypervisor/early-init.el)
  - keep as ordinary user-owned early-init behavior
- [host/templates/lisp/emacs-hypervisor-bootstrap.el](/Users/randall/projects/emacs-hypervisor/host/templates/lisp/emacs-hypervisor-bootstrap.el)
  - keep as the trusted kernel
  - includes the async process filter, incremental S-expression parsing,
    request dispatch, and lifecycle handling
- [lisp/emacs-hypervisor-declarations.el](/Users/randall/projects/emacs-hypervisor/lisp/emacs-hypervisor-declarations.el)
  - keep as the declaration/export surface

### Shrink

- generated `init.el`
  - keep only provisioned-home startup glue
  - avoid re-growing wrapper layers that duplicate the kernel boundary

### Move To Elle

- package plan construction
- topological sorting
- preflight and boot-policy decisions
- Elpaca install instruction generation
- unit execution sequencing
- report derivation and failure propagation policy
- transient runtime helper forms now emitted from
  [elle/runtime-forms](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms)
  and coordinated by
  [elle/runtime-forms.lisp](/Users/randall/projects/emacs-hypervisor/elle/runtime-forms.lisp)

### Delete When Replaced

- the old shared runtime file has been removed from the active codebase
- the resident Elpaca bridge file has now been removed from the active codebase

## Protocol Direction

`sexp-rpc` still fits the intended architecture.

The reset does not require abandoning:

- `stdio`
- session-scoped subprocess lifecycle
- S-expression payloads
- request/response/event envelope

The protocol should remain small.

Preferred steady-state operations:

- `:hello`
- `:boot-context`
- `:session-data`
- `:eval`
- optional explicit event topics for progress/log/report

The reset is about moving framework ownership, not replacing the protocol.

## Why This Is Better Than Backbone

Backbone keeps most framework logic in Emacs.

Hypervisor only has an advantage over Backbone if:

- Emacs becomes smaller than Backbone
- Elle owns more of the orchestration than Backbone’s external process did

If Hypervisor keeps both:

- a rich external orchestrator
- and a large persistent Emacs framework

then it becomes strictly worse than Backbone in complexity.

So the reset target is simple:

- keep the external orchestrator
- remove the large Emacs framework

## Migration Order

The reset should happen in this order:

1. Freeze the trusted Emacs kernel boundary.
2. Mark current Emacs-side files as `keep`, `move`, or `delete`.
3. Move Elpaca bootstrap/instruction generation into Elle-produced forms.
4. Move package and unit execution orchestration into Elle-produced forms.
5. Reduce Emacs-side runtime helpers until only the trusted kernel remains.
6. Re-test provisioned Emacs homes after each shrink step.

## Working Rule

When deciding where new code belongs:

- if Emacs must parse, evaluate, or report it directly, it may stay in Emacs
- if Elle can decide it ahead of time and emit Lisp for Emacs to run, it should
  move to Elle

This reset is the current intended direction for the project.
