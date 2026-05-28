# HUD Extension Architecture

## Overview

The HUD is a corner overlay rendered inside Emacs that shows live workspace
status for the active buffer's project: resolved project root, current git
branch, working-tree change count, last commit, MCP server availability, and
GitHub CLI availability.

It is implemented as a four-layer stack:

1. An egui/eframe application compiled to WebAssembly — the rendering surface.
2. A bare HTTP server embedded in the host binary that serves the WASM assets.
3. An Elle extension actor (`extension-hud.lisp`) that owns authoritative state
   and collects git data natively via libgit2.
4. An Elisp module (`emacs-hypervisor-hud.el`) that manages the Emacs child
   frame, drives event-driven data collection, and bridges events to the WASM
   renderer.

The key architectural principle is **actor-mediated state**. All authoritative
state lives in the Elle actor. Emacs and the WASM renderer are output surfaces:
Emacs gathers per-buffer *context* (which repo, is MCP up, is `gh` present) and
sends it to the actor; the actor collects git data and emits authoritative
state back. Neither the Elisp module nor the WASM canvas stores authoritative
data.

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
│  │  std/git (libgit2 FFI)   │   │  GET /pkg/hud_wasm.js         │  │
│  │                          │   │  GET /pkg/hud_wasm_bg.wasm    │  │
│  │  protocol:send-event     │   │                               │  │
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
│       │  emacs-hypervisor-hud--push-state-to-wasm  ─────────────┐   │
│       │                                                         │   │
│       ├─ :request :extension-call :hud :collect  (context)     │   │
│       │       ↑                                                 │   │
│       │  buffer-switch / save / toggle  → debounced trigger     │   │
│       │                                                         │   │
│       └─ :request :extension-call :hud :action                 │   │
│                 ↑                                               │   │
│  xwidget-webkit-pre-navigation-functions hook                   │   │
│       (intercepts emacs-hud:// URIs)                            │   │
│                                                                 │   │
│  ┌──────────────────────────────────────────────────────────┐   │   │
│  │  Child frame (undecorated, no-accept-focus)              │   │   │
│  │  ┌────────────────────────────────────────────────────┐  │   │   │
│  │  │  xwidget-webkit session                            │  │   │   │
│  │  │  http://127.0.0.1:<port>/index.html#bg=..&fg=..    │  │   │   │
│  │  │                                                    │  │   │   │
│  │  │  ┌──────────────────────────────────────────────┐  │  │   │   │
│  │  │  │  egui WASM canvas (WebGL)                    │  │  │   │   │
│  │  │  │                                              │  │  │   │   │
│  │  │  │  window.hudPushState(json) ←────────────────┼──┼──┘   │   │
│  │  │  │  window.hudPushTheme(json) ←────────────────┼──┼──────┘   │
│  │  │  └──────────────────────────────────────────────┘  │      │   │
│  │  └────────────────────────────────────────────────────┘      │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Component Stack

### 1. WASM Front-end (`hud-wasm/`)

**Source:** `hud-wasm/src/lib.rs`, `hud-wasm/index.html`
**Build target:** `wasm32-unknown-unknown` via `wasm-pack`

The WASM module is an `eframe` application that renders using egui's
immediate-mode UI toolkit over a WebGL canvas. It has no network access and no
side effects beyond drawing pixels. It is purely a renderer: it does not emit
navigation events (there are currently no interactive buttons).

**State schema (`HudState`):**

```rust
pub struct HudState {
    pub branch: String,         // current git branch (serde default "main")
    pub changes: String,        // e.g. "1 file", "30 files"
    #[serde(rename = "mcp-online")]   pub mcp_online: bool,
    pub units: Vec<UnitInfo>,   // config unit name + status (optional)
    pub location: String,       // e.g. "Local"
    #[serde(rename = "last-commit")]  pub last_commit: String,   // short oid
    #[serde(rename = "gh-available")] pub gh_available: bool,
    #[serde(rename = "project-name")] pub project_name: String,
    #[serde(rename = "project-root")] pub project_root: String,  // full path
}

pub struct UnitInfo {
    pub name: String,
    pub status: String,  // "running" | "failed" | other
}
```

The `project-root` row renders at the top of the card as a debugging aid so the
resolved repo path is always visible.

**Theme schema (`ThemeColors`):**

```rust
pub struct ThemeColors {
    pub bg: String,  // hex, e.g. "#1e1e2e" (default dark "#0c0c10")
    pub fg: String,  // hex (default "#e6ebff")
}
```

The renderer derives a light/dark presentation from the background luminance:
card fill, muted text, and stroke colors are computed from `bg`/`fg`. The egui
panels themselves are transparent so only the rounded card shows.

**Globals:**

- `GLOBAL_STATE: Mutex<HudState>` — current state.
- `GLOBAL_THEME: Mutex<ThemeColors>` — current theme.
- `REPAINT_SIGNAL: Mutex<Option<egui::Context>>` — a cloned egui context used
  to trigger a repaint when state or theme is pushed from outside the loop.

**Receiving state and theme from Emacs:**

Two functions are exported via `wasm_bindgen` and exposed by the HTML shell:

```javascript
window.hudPushState = (jsonStr) => push_state(jsonStr);
window.hudPushTheme = (jsonStr) => push_theme(jsonStr);
```

Emacs calls these via `xwidget-webkit-execute-script`. Each push replaces the
corresponding global and requests a repaint.

**Type fix-up (`fixup_sexp_rpc_json`):** Emacs's `json-encode` of sexp-rpc
values can emit booleans as the strings `"true"`/`"false"` and empty lists as
`null`. Before deserializing into `HudState`, `push_state` coerces the
`mcp-online`/`gh-available` string-booleans to JSON booleans and `null` `units`
to `[]`. (Emacs also normalizes most of this on its side; see §4.)

**Theme bootstrap (first paint):** `index.html` reads `#bg=..&fg=..` from the
URL fragment on load and calls `push_theme` before any state arrives, so the
first frame paints in the Emacs theme instead of flashing the dark default.

---

### 2. Asset Embedding and Serving

**Build-time (`host/build.rs`):**

During `cargo build`, `build.rs` reads the three compiled WASM assets and writes
them as byte-array literals into an embedded Rust source file:

```
hud-wasm/index.html           → HUD_INDEX_HTML_BYTES: &[u8]
hud-wasm/pkg/hud_wasm_bg.wasm → HUD_WASM_BG_BYTES:    &[u8]
hud-wasm/pkg/hud_wasm.js      → HUD_WASM_JS_BYTES:    &[u8]
```

(These are written as `pub const ... = &[..];` literals, not `include_bytes!`.)
The WASM assets must be built by `wasm-pack` before `cargo build` runs; the
build scripts (`scripts/build-hypervisor`) enforce that ordering.
`cargo:rerun-if-changed` directives refresh the embedded bytes when
`index.html`, `hud_wasm_bg.wasm`, or `hud_wasm.js` change.

**Runtime (`host/src/main.rs` — `start_hud_server`):**

At process startup, before the Elle VM is initialized, `start_hud_server()`
binds a `TcpListener` on `127.0.0.1:0` (OS-assigned ephemeral port). A dedicated
thread services incoming HTTP/1.1 requests, routing by path:

| Path                    | Served bytes           | Content-Type             |
|-------------------------|------------------------|--------------------------|
| `/` or `/index.html`    | `HUD_INDEX_HTML_BYTES` | `text/html`              |
| `/pkg/hud_wasm.js`      | `HUD_WASM_JS_BYTES`    | `application/javascript` |
| `/pkg/hud_wasm_bg.wasm` | `HUD_WASM_BG_BYTES`    | `application/wasm`       |

Responses include `Access-Control-Allow-Origin: *` and `Connection: close`.

The assigned port is published to Emacs via an environment variable before the
Elle VM starts:

```rust
env::set_var(
    "EMACS_HYPERVISOR_EMBEDDED_HUD_URL",
    format!("http://127.0.0.1:{}/index.html", hud_port),
);
```

The Elle runtime-forms module (`runtime-forms.lisp`) reads this variable and
emits `(setq emacs-hypervisor-hud--url ...)` into the Emacs bootstrap, so the
URL is set before any HUD frame is created.

---

### 3. Elle Extension Actor (`elle/extension-hud.lisp`)

The Elle actor is the single source of truth for HUD state. It runs inside the
extension actor loop (`extensions:run-extension-actor`), a cooperative
message-dispatch loop over the sexp-rpc mailbox. The module is constructed with
both the extensions helper and the protocol module:

```lisp
(def hud-extension (emacs-hypervisor-hud-extension-module extensions protocol))
```

**Authoritative state:**

```lisp
(def @*hud-state*
  {:branch "main" :changes "0 files" :mcp-online false :units ()
   :location "Local" :last-commit "" :gh-available false
   :project-name "" :project-root ""})
```

The `@` sigil marks this as a mutable cell. All writes go through `assign`/`put`.

**Native git collection (`collect-git-data`):**

Git data is collected natively in-process via `std/git`, an FFI binding to
libgit2. `ensure-git` lazy-loads the module on first use (logging a warning if
libgit2 is unavailable). For a given repo path the actor:

- opens the repo (`git:open`),
- reads `git:head` and strips a leading `refs/heads/` to get the branch,
- reads `git:status` and counts changed entries,
- reads `git:log {:limit 1}` for the short last-commit oid,
- closes the repo.

**Ignored-file handling:** libgit2's default status options include ignored
files, which the git CLI excludes. Ignored entries decode to `:index nil
:workdir nil`, so the change count includes only entries with a real index or
workdir status:

```lisp
(count (fn [e] (or (get e :index) (get e :workdir))) status-list)
```

Each step is wrapped in `protect`; failures are surfaced via `log-debug`
(`:log` events) rather than silently collapsing to "0 files", so a missing
libgit2 or an open/status error is observable in the hypervisor log stream.

> libgit2 itself is loaded cross-platform by a repo-local patch to `std/git`
> (`patches/elle/*.patch`, applied during `scripts/bootstrap-elle`). It probes
> `libgit2.dylib`/`libgit2.so` and the common Homebrew/MacPorts/multiarch
> install dirs directly, so no `DYLD_LIBRARY_PATH`/`LD_LIBRARY_PATH` is needed.

**Handler dispatch table (`make-handler`):**

| Method     | Handler           | Effect                                                        |
|------------|-------------------|---------------------------------------------------------------|
| `:open`    | `open-hud`        | Emits current state, returns `{:action :show}`                |
| `:close`   | `close-hud`       | Returns `{:action :hide}`                                     |
| `:collect` | `collect`         | Collects git data natively + merges Emacs-provided context, then emits state |
| `:state`   | `get-state`       | Returns `{:ok true :state @*hud-state*}`                      |
| `:action`  | `handle-action`   | Routes click-back commands (e.g. `rerun-diagnostics`)         |

`:collect` is the canonical data-collection entry point (it replaced an older
`:update` method). Its arguments carry context Emacs computes per-buffer:
`:repo_path`, `:mcp_online`, `:gh_available`, `:location`. The actor records
`:project-root` from the path, derives `:project-name` from its last segment,
fills git fields from `collect-git-data` (or the `"—"` / `"0 files"` fallback
when the path is not a git repo or collection fails), and merges the non-git
fields.

**State change events:**

After mutating `@*hud-state*`, the actor emits a `:hud-state-changed` event with
the wire-encoded state as the payload:

```lisp
(defn emit-state-changed []
  (protocol:send-event :hud-state-changed (protocol:to-wire *hud-state*)))
```

Emacs receives this via the sexp-rpc dispatch loop (see
`host/emacs-kernel/emacs-hypervisor-sexp-rpc.el`, which routes
`:hud-state-changed` to `emacs-hypervisor-hud--on-state-changed`).

**Actor registration (`hypervisor.lisp`):**

```lisp
(defn emacs-hypervisor-extension-registry [settings]
  (let [handlers (hud-extension:register settings
                  (mermaid-extension:register settings {}))]
    (extensions:make-registry settings handlers)))
```

`register` adds the `:hud` key to the shared handlers map, making the actor
addressable via `extension-call :hud <method>`. Extensions are always
registered — there is no opt-in/enabled gate.

---

### 4. Elisp Rendering Surface (`elle/runtime-forms/emacs-hypervisor-hud.el`)

The Elisp module manages frames, hooks, the xwidget session, and per-buffer
context collection. It does not own authoritative state.

**Frame management:**

`emacs-hypervisor-hud--make-frame` creates an undecorated child frame anchored
to the parent frame: `no-accept-focus`/`no-focus-on-map` (never steals focus),
`undecorated`, `unsplittable`, no scroll bars/fringe/mode line, and
`background-color`/`foreground-color` taken from the `default` face so the frame
matches the theme before the canvas paints. The new frame is immediately pointed
at a private placeholder buffer (`" *emacs-hypervisor-hud-placeholder*"`) so
session setup never captures and kills one of the user's real buffers.

`emacs-hypervisor-hud--reposition-frame` locks the frame to the top-right corner
and runs on `window-size-change-functions` and `focus-in-hook`.

**xwidget session lifecycle:**

`emacs-hypervisor-hud--initialize-session` loads
`(emacs-hypervisor-hud--url-with-theme)` — the asset URL plus a `#bg=..&fg=..`
fragment carrying the current theme — into a new xwidget-webkit session, saving
and restoring window configurations so the parent layout is undisturbed. The
xwidget buffer's mode line, header line, fringe, and line numbers are
suppressed. The placeholder buffer is only killed if its name begins with a
space (i.e. our own). After a short delay it pushes the theme again and starts
the initial collect retry loop.

**State push path:**

```elisp
(defun emacs-hypervisor-hud--push-state-to-wasm (state-plist)
  (let* ((sanitized (emacs-hypervisor-hud--fixup-sexp-rpc-plist state-plist))
         (json-str (json-encode sanitized))
         (script (format "if (window.hudPushState) { window.hudPushState(%S); }" json-str)))
    (xwidget-webkit-execute-script emacs-hypervisor-hud--session script)))
```

`--fixup-sexp-rpc-plist` converts Elle `true`/`false` symbols to `t`/
`:json-false` and `nil` array fields (e.g. `:units`) to empty vectors so
`json-encode` produces valid JSON. `--on-state-changed` calls this when a
`:hud-state-changed` event arrives.

**Theme push:** `--push-theme` sends `{:bg .. :fg ..}` (from the `default` face)
to `window.hudPushTheme`. Theme bypasses the actor — it is a presentation
concern — and is pushed on session init and on every collect trigger.

**Event-driven data collection:**

```
[buffer switch / selection change / save / toggle]
   → debounced idle timer (0.5s; saves use 0.1s, no debounce)
   → emacs-hypervisor-hud--trigger-collect
   → push theme + resolve context
   → emacs-hypervisor-extension-call :hud :collect
        {:repo_path .. :mcp_online .. :gh_available .. :location "Local"}
```

`--resolve-repo-path` deliberately resolves the repo from the buffer shown in
the **parent frame's selected window**, not `current-buffer` — collection runs
from idle timers where `current-buffer` is unpredictable (often the xwidget
buffer or the minibuffer). It uses `vc-root-dir`, falling back to a `.git`
sentinel search. Context also includes whether the hypervisor is live
(`mcp_online`) and whether `gh` is on PATH (`gh_available`).

Triggers are registered by `--setup-trigger-hooks` on
`window-buffer-change-functions`, `window-selection-change-functions`, and
`after-save-hook`. `--retry-initial-collect` retries the first collect up to 5
times (1s backoff) because the actor may not be ready during Emacs startup.

A `emacs-hypervisor-hud-debug` defcustom (currently `t`) logs the resolved repo,
the received state payload, and the pushed JSON to `*Messages*`, making it easy
to distinguish a backend collection issue (payload already wrong) from a
frontend display issue (payload correct, render wrong).

**Click-back routing:**

`emacs-hypervisor-hud--pre-navigation-hook` is registered on
`xwidget-webkit-pre-navigation-functions`. When a navigation URL on the HUD
session starts with `emacs-hud://`, it extracts the command, calls
`emacs-hypervisor-extension-call :hud :action {:command ..}`, dispatches the
returned `:action` (e.g. `:rerun-diagnostics` → `emacs-hypervisor-run-diagnostics`),
and returns `'block` to suppress navigation.

> The click-back path is fully wired on the Emacs and actor sides, but the
> current WASM renderer emits no `emacs-hud://` navigations (it has no
> interactive buttons). The hook is dormant until the renderer adds them.

**Public API:**

| Command                          | Effect                                                |
|----------------------------------|-------------------------------------------------------|
| `emacs-hypervisor-hud-toggle`    | Show if hidden, hide if visible                       |
| `emacs-hypervisor-hud-show`      | Re-show + collect, or initialize the session          |
| `emacs-hypervisor-hud-hide`      | Make the child frame invisible                        |
| `emacs-hypervisor-hud-push-state`| Trigger a collect cycle (legacy name)                 |
| `emacs-hypervisor-hud-refresh`   | Pull `:state` from the actor and push it to the WASM  |
| `emacs-hypervisor-hud-cleanup`   | Tear down hooks, frame, and xwidget buffer            |

Note: `show` initializes the session directly on the Emacs side rather than
routing through the actor's `:open` method; `:open`/`open-hud` remain available
for actor-driven shows.

---

## Data Flow Diagrams

### Collect / State Push Flow

```
[buffer switch / save / toggle / re-show]
          │
          ▼
  emacs-hypervisor-hud--trigger-collect
   → emacs-hypervisor-hud--push-theme  (window.hudPushTheme)
   → resolve repo path from parent frame's selected window
   → mcp_online = (emacs-hypervisor-live-p), gh_available = (executable-find "gh")
          │
          ▼
  emacs-hypervisor-extension-call :hud :collect
    {:repo_path .. :mcp_online .. :gh_available .. :location "Local"}
          │  (sexp-rpc :extension-call request over stdio)
          ▼
  Elle actor: collect
   → record :project-root / :project-name from path
   → collect-git-data via std/git (libgit2): branch, change count
     (excluding ignored), short last-commit
   → merge mcp/gh/location
          │
          ▼
  emit-state-changed
   → protocol:send-event :hud-state-changed (to-wire @*hud-state*)
          │  (sexp-rpc event over stdio)
          ▼
  Emacs sexp-rpc dispatch → emacs-hypervisor-hud--on-state-changed
          │
          ▼
  emacs-hypervisor-hud--push-state-to-wasm
   → --fixup-sexp-rpc-plist → json-encode → xwidget-webkit-execute-script
          │
          ▼
  window.hudPushState("{...json...}")   [inside WebKit process]
          │
          ▼
  push_state(json) [Rust/WASM]
   → fixup_sexp_rpc_json → serde_json::from_value::<HudState>
   → GLOBAL_STATE.lock() = new_state → ctx.request_repaint()
          │
          ▼
  egui update() runs next frame → reads GLOBAL_STATE/GLOBAL_THEME → WebGL
```

### Click-Back Flow (dormant — no WASM emitter yet)

```
[WASM renderer navigates to emacs-hud://command/<cmd>]   (not currently emitted)
          │
          ▼
  xwidget-webkit-pre-navigation-functions → --pre-navigation-hook
   checks xwidget == session AND url prefix "emacs-hud://"
          │
          ▼
  emacs-hypervisor-extension-call :hud :action {:command "<cmd>"}
          │  (sexp-rpc :extension-call over stdio)
          ▼
  actor handle-action → e.g. {:action :rerun-diagnostics}
          │
          ▼
  Emacs dispatches the action; returns 'block (navigation suppressed)
```

### Initial Load Flow

```
[emacs-hypervisor serve starts]
          │
          ▼
  start_hud_server() → binds TcpListener on 127.0.0.1:0
  env::set_var("EMACS_HYPERVISOR_EMBEDDED_HUD_URL",
               "http://127.0.0.1:<port>/index.html")
          │
          ▼
  Elle VM starts; runtime-forms emits
    (setq emacs-hypervisor-hud--url "http://127.0.0.1:<port>/index.html")
          │
          ▼
  [User calls emacs-hypervisor-hud-toggle / -show]
          │
          ▼
  emacs-hypervisor-hud--initialize-session
   → make child frame (placeholder buffer)
   → xwidget-webkit-new-session  ".../index.html#bg=..&fg=.."
          │
          ▼
  WebKit fetches /index.html, /pkg/hud_wasm.js, /pkg/hud_wasm_bg.wasm
   → init() → start("hud-canvas")
   → index.html applies theme from URL fragment (push_theme)
   → window.hudPushState / window.hudPushTheme exposed
          │
          ▼
  --retry-initial-collect → --trigger-collect (retries until actor ready)
   → :collect → actor emits :hud-state-changed → first real frame
```

---

## Tech Stack

| Layer           | Technology                                               |
|-----------------|----------------------------------------------------------|
| WASM renderer   | Rust, eframe 0.31, egui, WebGL                           |
| WASM build      | wasm-pack, wasm-bindgen, serde_json, lazy_static         |
| WASM runtime    | xwidget-webkit (WebKit2GTK on Linux, WKWebView on macOS) |
| Asset embedding | Rust build.rs, byte-array literals                       |
| Asset serving   | Bare `TcpListener` HTTP/1.1 in a Rust thread             |
| Extension actor | Elle (custom Lisp dialect), mutable `@struct` cells      |
| Git data        | std/git → libgit2 via FFI (`ffi/native`)                 |
| IPC protocol    | sexp-rpc over stdio (newline-delimited S-expressions)    |
| Elisp surface   | Emacs Lisp, xwidget-webkit API, child-frame API          |

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
hud-wasm/index.html    ← hand-written HTML shell with <canvas> + theme bootstrap
       │
       │  cargo build (host/build.rs reads these files)
       ▼
embedded HUD source (byte-array literals)
  HUD_INDEX_HTML_BYTES: &[u8]
  HUD_WASM_BG_BYTES:    &[u8]
  HUD_WASM_JS_BYTES:    &[u8]
       │
       │  compiled into emacs-hypervisor binary
       ▼
emacs-hypervisor  (single self-contained binary)
  — no separate WASM files required at runtime
  — no npm, no CDN, no file system access for HUD assets
```

`scripts/build-hypervisor` enforces this ordering: WASM is built before `cargo
build` runs, so `build.rs` always finds the compiled artifacts.

Note on libgit2: `scripts/bootstrap-elle` clones upstream Elle at the pinned
ref and applies `patches/elle/*.patch` (cross-platform libgit2 loading) before
building, so the runtime resolves libgit2 without any environment setup.

---

## Failure Modes

### Host process dies / asset server stops responding

The xwidget-webkit session holds an open HTTP connection to the embedded server.
If the `emacs-hypervisor` process exits:

- The TCP connections drop; WebKit may show an error page or go blank.
- The Elle actor and all extension state are gone.
- `emacs-hypervisor-hud-cleanup` (registered on `kill-emacs-hook`) destroys the
  child frame and releases the xwidget buffer on Emacs exit. If Emacs outlives
  the hypervisor, the frame persists in a broken state until toggled.

### libgit2 unavailable

If `std/git` cannot load libgit2, `ensure-git` logs a warning and
`collect-git-data` returns nil. `:collect` then falls back to `:branch "—"`,
`:changes "0 files"`, `:last-commit ""` while still reporting the resolved
project root and non-git context. No crash; the cause is visible in the
`:log` event stream (and, with `emacs-hypervisor-hud-debug`, in `*Messages*`).

### Asset URL not set

If `EMACS_HYPERVISOR_EMBEDDED_HUD_URL` is not set when
`emacs-hypervisor-hud-show` is called, `emacs-hypervisor-hud--url` is nil and the
command errors:

```
HUD Error: HUD HTML assets URL not set. Is the hypervisor session active?
```

If the Emacs binary lacks xwidget support, `--initialize-session` errors with a
clear message and runs cleanup.

### Actor model resilience properties

- **No shared mutable state across process boundaries.** The WASM canvas and the
  Elisp layer are stateless renderers. A crash or stale state in either does not
  corrupt the authoritative `@*hud-state*`.
- **Idempotent pushes.** `push_state`/`push_theme` are total replacements — a
  lost push is corrected by the next one.
- **Click-backs are fire-and-forget.** The Elisp layer blocks briefly on the
  response; it holds no locks and accumulates no deferred state.
- **Context vs. authority split.** Emacs supplies only per-buffer *context*
  (repo path, MCP/`gh` availability); the actor remains the sole authority over
  the rendered state.
