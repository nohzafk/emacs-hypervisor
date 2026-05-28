## The Core Vision

The goal is to modernize the Emacs user interface and break away from its rigid, window-alignment-based layouts. This is achieved by creating floating, interactive, modern UI components (such as signature help popups or a persistent corner Heads-Up Display) using a fast, decoupled rendering stack.

---

## Technical Architecture & Stack

The proposed stack leverages a combination of Emacs's native layout capabilities and a modern immediate-mode GUI framework compiled to WebAssembly.

* **Emacs Child Frame:** Serving as the visual container. It is configured to be undecorated, non-focusable, and anchored relative to the parent frame.
* **`xwidget-webkit` Session:** Embedded directly inside the child frame's buffer to act as a highly performant web rendering canvas.
* **`egui` (Rust) compiled to WASM:** Runs inside the WebKit session, rendering components at 60fps onto an HTML5 canvas.

### 1. Lifecycle & Resource Management

* **The Anti-Pattern:** Spawning WebKit instances or reloading WASM bundles dynamically on-demand. WebKit initialization and WASM loading introduce hundreds of milliseconds of latency, causing noticeable interface lag.
* **The Solution:** Long-lived instances. Create a single persistent child frame/xwidget instance per functional role (e.g., one for signature help, one for the corner HUD).
* **Visibility Control:** Use Emacs to dynamically show, hide, reparent, or reposition these long-lived frames instantly without tearing down the underlying WebKit/WASM processes.

### 2. Data & Rendering Separation (The "WASM as Renderer" Model)

* **Fixed Logic (WASM):** The WASM blob contains only structural rendering logic—how to lay out items, draw UI chips, handle colors, and manage internal UI animations. It acts as an immediate-mode rendering server.
* **Dynamic Data (Elisp):** The actual content (e.g., function names, variables, git state) is dynamic. Elisp pushes state payloads as JSON across the runtime bridge.
* **The Protocol Schema:** To add new layouts or widget types, the structural schema must be updated in Rust and recompiled. To change *what data* is displayed within an existing schema, Elisp simply transmits a modified payload without requiring a recompile.

---

## The Communication Bridge

To maintain high performance, communication between Emacs and WASM operates across a strict, asymmetric bridge.

### Data Feed (Elisp $\rightarrow$ WASM)

* **Mechanism:** Elisp serializes state to JSON and evaluates it within WebKit using `xwidget-webkit-execute-script`, targeting a global JavaScript function that pipes the data straight into a `wasm_bindgen` entry point.
* **Performance:** Occurs in single-digit milliseconds. Suitable for execution on frequent typing hooks or 1Hz timers ($< 200\text{ Hz}$).
* **Alternative Evolution:** Hypervisor can host a local WebSocket server. The WASM app connects via WS, and Hypervisor feeds it state directly via an out-of-band `sexp-rpc` channel from Emacs, bypassing the Elisp $\rightarrow$ JS execution bridge entirely.

### Interactive Click-Back Path (WASM $\rightarrow$ Elisp)

* **The Design Principle:** High-frequency state changes (e.g., smoothly dragging a UI slider, text input fields) are handled entirely within WASM at 60fps. Only *committed actions* (releasing the slider, pressing Enter, clicking a button) cross back to Emacs.
* **Mechanism:** WASM triggers a browser location update using a custom URI scheme (e.g., `window.location = "emacs-hud://command/foo"`).
* **Emacs Handling:** Elisp intercepts the navigation attempt using `xwidget-webkit-pre-navigation-functions` (or the `xwidget-event` signal), blocks the actual browser redirection, matches the command via pattern matching (like `pcase`), and executes the native Elisp function. Round-trip latency is roughly 5–10ms.

---

## Pre-Implementation Verification: Native Log-Tailing Demo

Before introducing the complexities of the Emacs environment (such as child-frame layout bugs, `xwidget-webkit` memory quirks, and Elisp-to-JS bridge parsing constraints), a dedicated de-risking phase is executed in isolation.

### 1. Objective & Setup

* **Goal:** Validate `egui`'s layout engine, immediate-mode state model, and raw rendering performance under continuous, high-frequency updates.
* **Approach:** Build a standalone, **native desktop window application** using Rust and `egui`'s native desktop backend (`eframe`). This bypasses WebAssembly compilation and WebKit wrapping entirely during initial proof-of-concept testing.

### 2. The Use Case: Log-Tailing Engine

* **Mechanics:** The demo application acts as a real-time log-tailing viewer, continually ingesting and processing high-frequency text streams from external files or mock event generators.
* **Why Log Tailing?** Ingestion of rapid, unpredictable text streams serves as an ideal stress test for immediate-mode rendering architectures. It forces the framework to handle continuous layout calculation, automatic text wrapping, memory reallocation for growing data sets, and scroll-anchor management at a locked native frame rate.

### 3. Key Hypotheses Validated

* **UI Fluidity Under Load:** Proves that immediate-mode redraw cycles do not introduce frame drops or text stuttering, even when rendering hundreds of active string mutations per second.
* **Ergonomics of State Mutation:** Verifies how cleanly backend variables translate to structural layouts on screen without explicit UI-tree widget manipulation.
* **Decoupled Readiness:** Ensures that the core structural rendering code can easily be isolated, wrapped behind a generic data-ingestion interface, and ready to swap its input source from local OS file streams to JSON payloads over a WASM wire.

---

## Feature Specification: The Corner HUD

A persistent, floating interface card pinned to the top-right corner of the frame to aggregate project, layout, and task status.

### 1. UI/UX and Show/Hide Policies

* **Master Toggle:** Managed via an explicit command (`M-x hypervisor-hud-toggle`) bound to a key like `C-c h h`. Opt-in and hidden by default.
* **Frame-level Bound:** Tied to parent frame focus rather than local buffer switches.
* **Auto-Relocation (Anti-Occlusion):** If the user's cursor (`point`) physically moves into the screen region occupied by the HUD, the child frame automatically slides to an alternate screen corner to prevent blocking code visibility.
* **Minibuffer Suppression:** Automatically hides during fullscreen or disruptive popovers by hooking into `minibuffer-setup-hook` and `minibuffer-exit-hook`.
* **Granular Customization:** Individual widgets within the HUD can be toggled via a gear/settings icon directly in the UI. Preferences are saved natively in an Elisp `defcustom`.
* **Visual Styling:** Uses a semi-transparent background to reduce occlusion. Elements use color shifts for state updates; peripheral animations (sliding/bouncing) are strictly prohibited to avoid distracting the developer.

### 2. The Five Core Widgets

| Widget | Display Elements | Update Hooks / Sources | Core Value Proposition |
| --- | --- | --- | --- |
| **1. Project & Git Card** | Project name, current branch, ahead/behind counters (chips), dirty-file count badge, relative time of last commit. | `magit-refresh-buffer-hook`<br>

<br>`vc-after-checkin-hook`<br>

<br>30-second polling timer (for remote sync). | Removes the need to disrupt workflow running `M-x magit-status` or checking text-dense modelines. |
| **2. Diagnostics Distribution** | Colored error/warning counts. A thin vertical strip mapping out the active file from top-to-bottom displaying spatial clusters of diagnostics. | `flymake-after-syntax-check-hook`<br>

<br>`flycheck-after-check-hook` | Provides spatial awareness of code errors (a structural minimap), which is impossible in text-only modelines. Hovering/clicking a mark jumps to that line. |
| **3. Build & Test Status** | Compilation/test pass-fail status chips, execution runtime duration, and relative time since last execution (e.g., `✓ 4.2s`, `ran 2m ago`). | Manual user invocation, directory watchers, file savers, or CI updates via `forge`. | Eradicates dedicated terminal split-panes by providing status summaries directly in the HUD. Clicking reruns. |
| **4. Hypervisor Unit Health** | Real-time counts of system units (Running, Failed, Reloading) alongside a micro-thumbnail visualization of the Unit Directed Acyclic Graph (DAG) highlighting failures in red. | Direct native event streams out of the Hypervisor engine via `sexp-rpc`. | Dogfoods the system pipeline; visualizes architecture states impossible via text interfaces. |
| **5. Org Clock & Task** | Current clocked-in task name (truncated), active elapsed time, and a progress bar based on effort estimations. | `org-clock-in-hook`<br>

<br>`org-clock-out-hook`<br>

<br>1Hz background timer when active. | Keeps immediate goals visible in the peripheral view without switching buffers to check the Org agenda. |

---

## Implementation Blueprints

### 1. Elisp: Child Frame Construction

```elisp
(defvar emacs-hypervisor-hud--frame nil)
(defvar emacs-hypervisor-hud--xwidget nil)

(defun emacs-hypervisor-hud--make-frame (parent)
  (make-frame
   `((parent-frame        . ,parent)
     (no-accept-focus     . t)
     (no-focus-on-map     . t)
     (minibuffer          . nil)
     (undecorated         . t)
     (visibility          . nil)
     (left . (- 20))                 ; Pinned 20px from right edge
     (top . 20)                      ; 20px from top edge
     (width . 36) (height . 28)      ; Char units (~340x520px)
     (internal-border-width . 0)
     (vertical-scroll-bars . nil)
     (horizontal-scroll-bars . nil)
     (left-fringe . 0) (right-fringe . 0)
     (tool-bar-lines . 0) (menu-bar-lines . 0)
     (mode-line-format . nil))))

(defun emacs-hypervisor-hud-show ()
  (interactive)
  (unless (frame-live-p emacs-hypervisor-hud--frame)
    (setq emacs-hypervisor-hud--frame
          (emacs-hypervisor-hud--make-frame (selected-frame)))
    (with-selected-frame emacs-hypervisor-hud--frame
      (let ((xw (xwidget-webkit-new-session "about:blank")))
        (setq emacs-hypervisor-hud--xwidget xw)
        (xwidget-webkit-goto-url xw "http://127.0.0.1:8765/hud.html"))))
  (make-frame-visible emacs-hypervisor-hud--frame))

```

### 2. Rust: Structural Schema & Application Dispatch

```rust
#[derive(Default, Deserialize)]
struct HudState {
    project:     Option<ProjectInfo>,
    diagnostics: Option<DiagnosticSummary>,
    build:       Option<BuildStatus>,
    units:       Option<UnitHealth>,
    clock:       Option<OrgClock>,
    visible:     WidgetVisibility,  // Stores per-widget enabled settings
}

impl eframe::App for HudApp {
    fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(Color32::from_black_alpha(220))) // Translucent
            .show(ctx, |ui| {
                if self.state.visible.project     { self.draw_project(ui);    }
                if self.state.visible.diagnostics { self.draw_diagnostics(ui);}
                if self.state.visible.build       { self.draw_build(ui);      }
                if self.state.visible.units       { self.draw_units(ui);      }
                if self.state.visible.clock       { self.draw_clock(ui);      }
            });
    }
}

// Global invocation entry point exposed to JavaScript bridge
#[wasm_bindgen]
pub fn push_state(json: &str) {
    let new_state: HudState = serde_json::from_str(json).unwrap();
    GLOBAL_STATE.lock().replace(new_state);
    request_repaint(); // Force immediate-mode cycle refresh
}

```

### 3. Elisp: Data Processing & State Feed

```elisp
(defun emacs-hypervisor-hud--push (state-plist)
  (when (xwidget-live-p emacs-hypervisor-hud--xwidget)
    (xwidget-webkit-execute-script
     emacs-hypervisor-hud--xwidget
     (format "window.hudPushState(%S)"
             (json-encode state-plist)))))

(defun emacs-hypervisor-hud--collect-state ()
  (list :project     (emacs-hypervisor-hud--project-info)
        :diagnostics (emacs-hypervisor-hud--diagnostic-summary)
        :build       (emacs-hypervisor-hud--build-status)
        :units       (emacs-hypervisor-hud--unit-health)
        :clock       (emacs-hypervisor-hud--org-clock)
        :visible     emacs-hypervisor-hud-widgets))

(defun emacs-hypervisor-hud--refresh ()
  (emacs-hypervisor-hud--push (emacs-hypervisor-hud--collect-state)))

;; System event hooks targeting the payload refresh
(add-hook 'flymake-after-syntax-check-hook #'emacs-hypervisor-hud--refresh)
(add-hook 'magit-refresh-buffer-hook       #'emacs-hypervisor-hud--refresh)
(add-hook 'org-clock-in-hook               #'emacs-hypervisor-hud--refresh)
(run-at-time 1 1 #'emacs-hypervisor-hud--refresh) ;; 1Hz Fallback backstop

```

### 4. Rust $\rightarrow$ Elisp Interactivity Handler

```rust
// Fired from inside the Rust WebAssembly layer on user interaction
fn on_build_chip_click(&self) {
    web_sys::window().unwrap()
        .location()
        .set_href("emacs-hud://command/rerun-build").unwrap();
}

```

```elisp
;; Caught and parsed back inside Emacs
(defun emacs-hypervisor-hud--handle-url (url)
  (when (string-prefix-p "emacs-hud://" url)
    (pcase (string-remove-prefix "emacs-hud://command/" url)
      ("rerun-build" (project-compile))
      ("magit-status" (call-interactively #'magit-status))
      ("toggle-widget-clock"
       (setf (plist-get emacs-hypervisor-hud-widgets :clock)
             (not (plist-get emacs-hypervisor-hud-widgets :clock)))
       (emacs-hypervisor-hud--refresh))
      (cmd (message "Unknown HUD command: %s" cmd)))
    'block)) ;; Return 'block symbol to halt actual WebKit page navigation

```

---

## Estimated Blueprint Scope

The initial Minimum Viable Product (MVP) containing a working framework with the first functioning widget (Project/Git Card) scales across a minimal code surface:

* **Emacs Lisp Layer:** $\approx 80\text{ lines}$ (Handles frame configurations, data collation, hook bindings, and URI routing).
* **Rust App Layer:** $\approx 150\text{ lines}$ (Sets up base `egui` wrappers, handles incoming serde JSON schemas, and includes one drawing layout pass).
* **JavaScript Glue:** $\approx 20\text{ lines}$ (Exposes the global window function hooking browser executions to `wasm_bindgen`).
* **Infrastructure:** Run a generic local static web file server (`python -m http.server`) to provide the runtime endpoint.
* **Subsequent Expansion Costs:** Adding any subsequent widgets safely budgets out to roughly $30\text{--}50\text{ lines}$ of Rust UI placement code, and $\approx 10\text{ lines}$ of matching Elisp payload definitions.
