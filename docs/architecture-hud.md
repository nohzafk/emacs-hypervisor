# HUD Extension Architecture

## Overview

The HUD is a translucent corner overlay rendered inside Emacs that shows live
workspace status: current git branch, working-tree change summary, MCP server
availability, and the status of active config units.

It is implemented as a four-layer stack:

1. An egui/eframe application compiled to WebAssembly — the rendering surface.
2. A bare HTTP server embedded in the host binary that serves the WASM assets.
3. An Elle extension actor (`extension-hud.lisp`) that owns authoritative state.
4. An Elisp module (`emacs-hypervisor-hud.el`) that manages the Emacs child
   frame and bridges events to the WASM renderer.

The key architectural principle is **actor-mediated state**. All state lives in
the Elle actor. Emacs and the WASM renderer are pure output surfaces. Neither
the Elisp module nor the WASM canvas stores authoritative data.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  emacs-hypervisor binary (Rust)                                     │
│                                                                     │
│  ┌──────────────────────────┐   ┌───────────────────────────────┐  │
│  │  Elle VM                 │   │  HUD asset server             │  │
│  │                          │   │  (bare TcpListener, port 0)   │  │
│  │  extension-hud actor     │   │                               │  │
│  │  @*hud-state*            │   │  GET /index.html              │  │
│  │                          │   │  GET /pkg/hud_wasm.js         │  │
│  │  protocol:send-event     │   │  GET /pkg/hud_wasm_bg.wasm    │  │
│  │    :hud-state-changed ───┼───┼──→ EMACS_HYPERVISOR_           │  │
│  │                          │   │     EMBEDDED_HUD_URL env var  │  │
│  └────────────┬─────────────┘   └───────────────────────────────┘  │
│               │ sexp-rpc over stdio                                 │
└───────────────┼─────────────────────────────────────────────────────┘
                │
                │  S-expression messages (newline-delimited)
                │
┌───────────────┼─────────────────────────────────────────────────────┐
│  Emacs        │                                                     │
│               ↓                                                     │
│  sexp-rpc dispatch                                                  │
│       │                                                             │
│       ├─ :event :hud-state-changed                                  │
│       │       ↓                                                     │
│       │  emacs-hypervisor-hud--on-state-changed                     │
│       │       ↓                                                     │
│       │  emacs-hypervisor-hud-push-state  ─────────────────────┐   │
│       │                                                         │   │
│       └─ :request :extension-call :hud                          │   │
│                 ↑                                               │   │
│  xwidget-webkit-pre-navigation-functions hook                   │   │
│       (intercepts emacs-hud:// URIs)                            │   │
│                                                                 │   │
│  ┌──────────────────────────────────────────────────────────┐   │   │
│  │  Child frame (undecorated, no-accept-focus)              │   │   │
│  │  ┌────────────────────────────────────────────────────┐  │   │   │
│  │  │  xwidget-webkit session                            │  │   │   │
│  │  │  http://127.0.0.1:<port>/index.html                │  │   │   │
│  │  │                                                    │  │   │   │
│  │  │  ┌──────────────────────────────────────────────┐  │  │   │   │
│  │  │  │  egui WASM canvas (WebGL)                    │  │  │   │   │
│  │  │  │                                              │  │  │   │   │
│  │  │  │  window.hudPushState(json) ←────────────────┼──┼──┘   │   │
│  │  │  │                                              │  │      │   │
│  │  │  │  button click → location.href =              │  │      │   │
│  │  │  │    "emacs-hud://command/<action>" ──────────►│  │      │   │
│  │  │  └──────────────────────────────────────────────┘  │      │   │
│  │  └────────────────────────────────────────────────────┘      │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Component Stack

### 1. WASM Front-end (`hud-wasm/`)

**Source:** `hud-wasm/src/lib.rs`  
**Build target:** `wasm32-unknown-unknown` via `wasm-pack`

The WASM module is an `eframe` application that renders using egui's
immediate-mode UI toolkit over a WebGL canvas. It has no network access and
no side effects beyond drawing pixels and emitting navigation events.

**State schema (`HudState`):**

```rust
pub struct HudState {
    pub branch: String,       // current git branch
    pub changes: String,      // diff summary, e.g. "+3 -1"
    pub mcp_online: bool,     // MCP server reachability
    pub units: Vec<UnitInfo>, // config unit name + status
}

pub struct UnitInfo {
    pub name: String,
    pub status: String,  // "running" | "failed" | other
}
```

A `GLOBAL_STATE: Mutex<HudState>` holds the current state. A
`REPAINT_SIGNAL: Mutex<Option<egui::Context>>` holds a cloned egui context
used to trigger a repaint when state is pushed from outside the render loop.

**Receiving state from Emacs:**

The `push_state(json: &str)` function is exported via `wasm_bindgen`. The HTML
shell exposes it as `window.hudPushState`:

```javascript
window.hudPushState = (jsonStr) => { push_state(jsonStr); };
```

Emacs calls this via `xwidget-webkit-execute-script`.

**Emitting click-back events:**

When a button is clicked inside egui, the WASM code navigates to an
`emacs-hud://` URI:

```rust
win.location().set_href("emacs-hud://command/rerun-diagnostics")
```

This is intercepted by the Elisp pre-navigation hook before any real navigation
occurs (see section 4).

---

### 2. Asset Embedding and Serving

**Build-time (`host/build.rs`):**

During `cargo build`, `build.rs` reads the three compiled WASM assets and
encodes them as byte array literals into `$OUT_DIR/embedded_hud.rs`:

```
hud-wasm/index.html          → HUD_INDEX_HTML_BYTES: &[u8]
hud-wasm/pkg/hud_wasm_bg.wasm → HUD_WASM_BG_BYTES:   &[u8]
hud-wasm/pkg/hud_wasm.js      → HUD_WASM_JS_BYTES:   &[u8]
```

The WASM assets must be built by `wasm-pack` before `cargo build` runs. The
`just build` recipe handles this ordering.

**Runtime (`host/src/main.rs` — `start_hud_server`):**

At process startup, before the Elle VM is initialized, `start_hud_server()`
binds a `TcpListener` on `127.0.0.1:0` (OS-assigned ephemeral port). A
dedicated thread services incoming HTTP/1.1 requests, routing by path:

| Path                       | Served bytes             | Content-Type         |
|----------------------------|--------------------------|----------------------|
| `/` or `/index.html`       | `HUD_INDEX_HTML_BYTES`   | `text/html`          |
| `/pkg/hud_wasm.js`         | `HUD_WASM_JS_BYTES`      | `application/javascript` |
| `/pkg/hud_wasm_bg.wasm`    | `HUD_WASM_BG_BYTES`      | `application/wasm`   |

The assigned port is published to Emacs via an environment variable before the
Elle VM starts:

```rust
env::set_var(
    "EMACS_HYPERVISOR_EMBEDDED_HUD_URL",
    format!("http://127.0.0.1:{}/index.html", hud_port),
);
```

The Elisp bootstrap reads this variable and sets `emacs-hypervisor-hud--url`
before any HUD frame is created.

---

### 3. Elle Extension Actor (`elle/extension-hud.lisp`)

The Elle actor is the single source of truth for HUD state. It runs inside the
extension actor loop (`extensions:run-extension-actor`) which is a cooperative
message-dispatch loop over the sexp-rpc mailbox.

**Authoritative state:**

```lisp
(def @*hud-state* {:branch "main" :changes "+0 -0" :mcp-online false :units ()})
```

The `@` sigil marks this as a mutable cell (`@struct`). All writes go through
`assign`.

**Handler dispatch table:**

| Method    | Handler function  | Effect                                      |
|-----------|-------------------|---------------------------------------------|
| `:open`   | `open-hud`        | Returns `{:action :show}` — Elisp shows the frame |
| `:close`  | `close-hud`       | Returns `{:action :hide}` — Elisp hides the frame |
| `:update` | `update-state`    | Merges partial fields into `@*hud-state*`   |
| `:state`  | `get-state`       | Returns current `@*hud-state*`              |
| `:action` | (target arch)     | Routes click-back commands from Emacs       |

**State change events (target architecture):**

After any mutation of `@*hud-state*`, the actor emits a `:hud-state-changed`
event carrying the new state as the payload:

```lisp
(protocol:send-event :hud-state-changed *hud-state*)
```

Emacs receives this event via the sexp-rpc dispatch loop and calls
`emacs-hypervisor-hud--on-state-changed`, which pushes the state as JSON into
the WASM renderer.

**Actor registration:**

`extension-hud.lisp` exports a `register` function. In `hypervisor.lisp`:

```lisp
(def hud-extension (emacs-hypervisor-hud-extension-module extensions))
;; ...
(let* [handlers (hud-extension:register settings
                  (mermaid-extension:register settings {}))]
  ...)
```

The `:hud` key is added to the shared handlers map, making the actor
addressable via `extension-call :hud <method>` requests from Emacs.

---

### 4. Elisp Rendering Surface (`elle/runtime-forms/emacs-hypervisor-hud.el`)

The Elisp module is a thin surface — it manages frames, hooks, and the
xwidget session. It does not own state and does not make policy decisions.

**Frame management:**

`emacs-hypervisor-hud--make-frame` creates an undecorated child frame
attached to the current parent frame with these key parameters:

- `parent-frame` — anchors the child to the Emacs frame
- `no-accept-focus t`, `no-focus-on-map t` — overlay never steals focus
- `undecorated t` — no title bar or window chrome
- `unsplittable t`, no scroll bars, no fringe, no mode line

The frame is positioned in the top-right corner via
`emacs-hypervisor-hud--reposition-frame`, which is called on
`window-size-change-functions` and `focus-in-hook` to keep the HUD locked
in place as the parent frame resizes.

**xwidget session lifecycle:**

`emacs-hypervisor-hud--initialize-session` loads
`emacs-hypervisor-hud--url` (the `http://127.0.0.1:<port>/index.html` URL
set from the env var) into a new xwidget-webkit session inside the child frame.
The xwidget buffer's mode line, header line, fringe, and line numbers are all
suppressed.

**State push path:**

```elisp
(defun emacs-hypervisor-hud-push-state (state-plist)
  (let* ((json-str (json-encode state-plist))
         (script (format "if (window.hudPushState) { window.hudPushState(%S); }" json-str)))
    (xwidget-webkit-execute-script emacs-hypervisor-hud--session script)))
```

Called by the sexp-rpc event handler when a `:hud-state-changed` event arrives.

**Click-back routing:**

The `xwidget-webkit-pre-navigation-functions` hook intercepts all navigation
events on the HUD session. When the URL starts with `emacs-hud://`:

1. The hook extracts the command name from the path.
2. It dispatches to the appropriate action (currently `rerun-diagnostics`).
3. In the target architecture, it calls
   `emacs-hypervisor-extension-call :hud :action` with the command as an arg,
   routing the action through the Elle actor.
4. It returns `'block` to prevent actual navigation.

---

## Data Flow Diagrams

### State Push Flow

```
[Something changes workspace state]
          │
          ▼
  Elle actor receives :update request
  (emacs-hypervisor-extension-call :hud :update {:branch "feat/x" ...})
          │
          ▼
  update-state merges fields into @*hud-state*
          │
          ▼
  protocol:send-event :hud-state-changed *hud-state*
          │  (sexp-rpc event over stdio)
          ▼
  Emacs sexp-rpc dispatch router
          │
          ▼
  emacs-hypervisor-hud--on-state-changed (event handler)
          │
          ▼
  emacs-hypervisor-hud-push-state (plist)
          │  json-encode → xwidget-webkit-execute-script
          ▼
  window.hudPushState("{...json...}")   [inside WebKit process]
          │
          ▼
  push_state(json) [Rust/WASM]
  → serde_json::from_str::<HudState>
  → GLOBAL_STATE.lock() = new_state
  → ctx.request_repaint()
          │
          ▼
  egui update() runs next frame
  → reads GLOBAL_STATE
  → renders new pixels via WebGL
```

### Click-Back Flow

```
[User clicks "Re-run Diagnostics" button in egui UI]
          │
          ▼
  btn.clicked() → true
  window.location.set_href("emacs-hud://command/rerun-diagnostics")
          │  (navigation event inside WebKit)
          ▼
  xwidget-webkit-pre-navigation-functions hook fires
          │
          ▼
  emacs-hypervisor-hud--pre-navigation-hook
  checks: xwidget == emacs-hypervisor-hud--session
          AND url starts with "emacs-hud://"
          │
          ▼
  extract cmd = "rerun-diagnostics"
          │
          ▼
  [target architecture]
  emacs-hypervisor-extension-call :hud :action {:cmd "rerun-diagnostics"}
          │  (sexp-rpc :extension-call request over stdio)
          ▼
  extensions:dispatch-extension-call
  → hud handler :action method
  → actor executes the action
          │
          ▼
  return 'block  (navigation suppressed)
```

### Initial Load Flow

```
[emacs-hypervisor serve starts]
          │
          ▼
  start_hud_server() → binds TcpListener on 127.0.0.1:0
  env::set_var("EMACS_HYPERVISOR_EMBEDDED_HUD_URL", "http://127.0.0.1:<port>/index.html")
          │
          ▼
  Elle VM starts, install_elisp_modules() sets env vars for runtime modules
          │
          ▼
  Emacs bootstrap loads sexp-rpc + session-state modules
  Elisp reads EMACS_HYPERVISOR_EMBEDDED_HUD_URL
  → (setq emacs-hypervisor-hud--url "http://127.0.0.1:<port>/index.html")
          │
          ▼
  [User or boot sequence calls (emacs-hypervisor-extension-call :hud :open)]
          │
          ▼
  Elle actor: open-hud → returns {:action :show}
  Emacs: emacs-hypervisor-hud-show
  → emacs-hypervisor-hud--initialize-session
  → xwidget-webkit-new-session "http://127.0.0.1:<port>/index.html"
          │
          ▼
  WebKit fetches /index.html from embedded HTTP server
  → parses HTML, fetches /pkg/hud_wasm.js
  → fetches /pkg/hud_wasm_bg.wasm
  → init() → start("hud-canvas") → window.hudPushState exposed
          │
          ▼
  Elle actor calls :state → returns @*hud-state*
  Emacs calls emacs-hypervisor-hud-push-state with initial state
  → egui renders first frame with live data
```

---

## Tech Stack

| Layer           | Technology                                      |
|-----------------|-------------------------------------------------|
| WASM renderer   | Rust, eframe 0.31, egui, WebGL                 |
| WASM build      | wasm-pack, wasm-bindgen, serde_json, lazy_static |
| WASM runtime    | xwidget-webkit (WebKit2GTK on Linux, WKWebView on macOS) |
| Asset embedding | Rust build.rs, `include_bytes!`, byte array literals |
| Asset serving   | Bare `TcpListener` HTTP/1.1 in a Rust thread    |
| Extension actor | Elle (custom Lisp dialect), mutable `@struct` cells |
| IPC protocol    | sexp-rpc over stdio (newline-delimited S-expressions) |
| Elisp surface   | Emacs Lisp, xwidget-webkit API, child-frame API |

---

## Build Pipeline

```
hud-wasm/src/lib.rs
       │
       │  wasm-pack build --target web
       ▼
hud-wasm/pkg/
  hud_wasm.js          ← JS glue generated by wasm-bindgen
  hud_wasm_bg.wasm     ← compiled WASM binary
hud-wasm/index.html    ← hand-written HTML shell with <canvas>
       │
       │  cargo build (host/build.rs reads these files)
       ▼
$OUT_DIR/embedded_hud.rs
  HUD_INDEX_HTML_BYTES: &[u8]  = include_bytes!("...index.html")
  HUD_WASM_BG_BYTES:   &[u8]  = include_bytes!("...hud_wasm_bg.wasm")
  HUD_WASM_JS_BYTES:   &[u8]  = include_bytes!("...hud_wasm.js")
       │
       │  compiled into emacs-hypervisor binary
       ▼
emacs-hypervisor  (single self-contained binary)
  — no separate WASM files required at runtime
  — no npm, no CDN, no file system access for HUD assets
```

The `just build` recipe enforces this ordering: WASM is built before `cargo
build` runs, so `build.rs` always finds the compiled artifacts.

`cargo:rerun-if-changed` directives in `build.rs` ensure the embedded bytes
are refreshed whenever `index.html`, `hud_wasm_bg.wasm`, or `hud_wasm.js`
changes.

---

## Failure Modes

### Host process dies / asset server stops responding

The xwidget-webkit session holds an open HTTP connection to the embedded server.
If the `emacs-hypervisor` process exits:

- The TCP connections are dropped; WebKit may show an error page or go blank.
- The Elle actor and all extension state are gone.
- `emacs-hypervisor-hud-cleanup` should be called on session teardown to
  destroy the child frame and release the xwidget buffer.
- The `kill-emacs-hook` registration ensures cleanup runs when Emacs exits, but
  if Emacs outlives the hypervisor process the frame will persist in a broken
  state until toggled.

**Mitigation:** The bootstrap layer monitors the stdio pipe. When the
hypervisor process exits, the sexp-rpc reader loop should detect EOF and
trigger a cleanup event.

### Extension misconfigured or absent

If `:hud` is not in the extensions list passed via session-data, the extension
actor is never registered. Calls to `:open` or `:update` return an
`extension-unavailable` error response. The HUD frame is never created.
No crash; the session continues without the HUD.

If `EMACS_HYPERVISOR_EMBEDDED_HUD_URL` is not set when
`emacs-hypervisor-hud-show` is called, it throws an error:

```
HUD Error: HUD HTML assets URL not set. Is the hypervisor session active?
```

### Actor model resilience properties

The actor model provides several failure-isolation benefits over a
direct split-brain design:

- **No shared mutable state across process boundaries.** The WASM canvas and
  the Elisp layer are stateless renderers. A crash or stale state in either
  does not corrupt the authoritative `@*hud-state*`.
- **Idempotent state pushes.** `push_state` is a total replacement — if a push
  is lost, the next push restores correctness.
- **Click-backs are fire-and-forget requests.** If the hypervisor is busy, the
  Elisp layer blocks briefly on the response; it does not hold locks or
  accumulate deferred state.
- **Extension registration is explicit.** Unsupported extensions cause a
  startup error with a clear message rather than a silent no-op or a crash
  mid-session.
