# `sexp-rpc` Notes

`emacs-hypervisor` now uses a small Lisp-native RPC/event protocol named
`sexp-rpc`.

The current wire contract is:

- transport: `stdio`
- lifecycle: session-scoped subprocess
- framing: one serialized message per line
- payload format: S-expressions
- envelope: `:request`, `:response`, and `:event`

This is intentionally JSON-RPC-shaped in semantics, but not JSON-RPC in
encoding.

## Envelope

Every protocol message is a top-level `:rpc` form:

```lisp
(:rpc :protocol :sexp-rpc :version 1 :kind :request ...)
(:rpc :protocol :sexp-rpc :version 1 :kind :response ...)
(:rpc :protocol :sexp-rpc :version 1 :kind :event ...)
```

### Request

```lisp
(:rpc
 :protocol :sexp-rpc
 :version 1
 :kind :request
 :id 3
 :op :session-data
 :payload (:fields (:packages :units :env)))
```

### Response

Successful:

```lisp
(:rpc
 :protocol :sexp-rpc
 :version 1
 :kind :response
 :id 3
 :ok t
 :payload (:packages (...) :units (...) :env (...)))
```

Failure:

```lisp
(:rpc
 :protocol :sexp-rpc
 :version 1
 :kind :response
 :id 4
 :ok nil
 :error "(error \"...\")")
```

### Event

```lisp
(:rpc
 :protocol :sexp-rpc
 :version 1
 :kind :event
 :topic :report
 :payload (:stage :executed :phase :units :items (...)))
```

## Current Shared-Path Operations

The shared backend currently uses these request operations:

- `:hello`
- `:boot-context`
- `:session-data`
- `:eval`

The current shared-path event topics are:

- `:plan`
- `:progress`
- `:log`
- `:report`
- `:shutdown`
- `:package`

`:package` is currently used by the Stage 1 Elpaca tracker bridge for:

- `(:phase :packages :kind :installed :name "...")`
- `(:phase :packages :kind :finished :reason "...")`
- `(:phase :packages :kind :timeout :reason "...")`

## Handshake

The current startup flow is:

1. Elle sends `:hello`
2. Emacs responds with protocol/version/mode/transport facts
3. Elle sends `:boot-context`
4. Emacs responds with session-level facts such as:
   - `:session-name`
   - `:ui`
   - `:transport`
   - `:repo-dir`
   - `:stage1-user-emacs-directory`
   - `:elpaca-manager-root`
5. Elle sends `:session-data`
6. Emacs responds with:
   - `:packages`
   - `:units`
   - `:env`
7. Elle sends `:eval` to install transient session helpers inside Emacs
8. Elle emits `:plan`, `:progress`, `:log`, `:report`, and `:shutdown` events

This is the current shared-path handshake, not the desired steady-state size of
the Emacs runtime. The architecture reset direction is to keep the handshake
shape but shrink the amount of runtime Elisp that gets installed by
step 7.

## Why `sexp-rpc`

This preserves the Lisp-to-Lisp properties the project wants:

- Emacs can parse incoming values with `read`
- Elle can construct messages naturally with quasiquote/unquote
- protocol payloads stay native Lisp data instead of becoming JSON objects
- code-as-data remains available where the trusted `:eval` escape hatch is
  necessary

At the same time, it keeps the parts of RPC discipline that matter:

- request/response correlation with `:id`
- explicit async events
- explicit success/failure responses
- a stable versioned envelope

## Transport Rule

The current transport rule is:

- each protocol message must serialize to a single physical line
- string payloads must be escaped during serialization
- readers may treat newline as the frame boundary

The async Emacs process filter still must handle incomplete S-expressions.
Newline is the outer message frame boundary, but process I/O can still deliver
partial chunks. The trusted kernel therefore needs incremental buffering plus
`read`, not a blocking loop that assumes whole messages arrive at once.

This is why Emacs now uses explicit S-expression serialization for outbound
messages instead of raw `prin1-to-string`.

Length-prefixed framing is still possible later if the project needs a more
general transport boundary, but it is not required for the current shared
session path.

## Matching Semantics

`sexp-rpc` is request/response correlated by `:id`, but the transport is still
one shared async stream.

That means Elle must not discard unrelated messages while waiting for:

- a specific `:response`
- a specific `:event` topic

The shared protocol helpers therefore keep an in-memory pending-message mailbox.
If Elle reads a valid `sexp-rpc` message that does not satisfy the current
waiter, it is buffered and retried by later waits instead of being dropped.

This keeps the current line-framed stdio design simple while avoiding a class
of ordering bugs where package events or later eval responses can arrive while
another waiter is active.

## Failure Representation

Reports remain the source of truth for execution outcomes.

Important report item fields:

- `:status`
  - `:ok`
  - `:skipped`
  - `:failed`
  - `:invalid`
- `:reason`
  - examples: `:executed`, `:blocked-by-package`, `:blocked-by-unit`,
    `:preflight`, `:missing-deps`, `:missing-after-units`, `:execution`
- `:details`
  - structured reason payload

The current normalized failure payload shapes are:

- missing references:
  - `(:missing (...))`
- dependency blockers:
  - `(:blockers (...))`
- cycles:
  - `(:members (...))`
- preflight:
  - `(:env (...) :executable (...))`
- eval failures:
  - `(:source :eval :error "...")`
- package-event failures:
  - `(:source :package-event :error "...")`
- tracker/queue failures:
  - `(:source :tracker ...)`
  - `(:source :tracker :error :timeout)`
  - `(:source :queue :error "...")`

## Stage Boundaries

Stage 0 remains the trusted Emacs kernel:

- start the backend
- parse incoming `sexp-rpc` messages
- answer core requests
- store only the minimum session state needed for lifecycle and inspection
- handle shutdown and process-sentinel state
- support incremental parsing of chunked stdio input

Current shared path:

- Elle installs transient session helper forms inside Emacs
- those helper forms currently include Elpaca bootstrap hookup, tracker
  callbacks, and unit execution helpers
- the old shared runtime file is no longer required on the main startup path

Target direction:

- Emacs keeps only the trusted kernel plus declaration/export surface
- Elle emits smaller, more transient runtime forms for package/config execution
- large persistent helper layers in Emacs are transitional, not architectural
- `Stage 1` should be treated as a migration label, not a durable subsystem

## Compatibility Note

The shared Stage 0 bootstrap is now `sexp-rpc`-only.

Historical numbered spike files that still speak older ad hoc top-level
messages remain useful as design snapshots, but they are no longer a
compatibility target for the shared bootstrap/runtime path.
