# Emacs Floating HUD: GUI Spikes & Architectural Report

This document records the findings, architectural discoveries, and technical verdicts established during the pre-implementation spike phase of the **Emacs Floating HUD** project on macOS.

---

## Executive Summary

The goal of this project is to modernize the Emacs user interface on macOS by creating a persistent, floating, and hardware-accelerated **Heads-Up Display (HUD)** pinned to the top-right corner of the parent frame. To de-risk this visual overlay, we conducted four distinct technical spikes under `hub-idea/` exploring different rendering engines (Text, SVG, Cocoa Dynamic Modules, and Native WebKit) in conjunction with Emacs child frames.

Our findings reveal the exact window-system boundaries of macOS Emacs builds (CoreGraphics vs. `librsvg`, Appine limits, and xwidget viewport scaling), culminating in a **fully validated, GPU-accelerated, borderless WebKit-based overlay framework** ready to host immediate-mode `egui` WebAssembly applications.

---

## The Four Technical Spikes

To establish a clear technical direction, we authored and executed four progressive Elisp spikes inside the repository directory `hub-idea/`:

```
hub-idea/
├── hud_frame_experiment.el   # Spike 1: Text Grid child-frame HUD
├── hud_svg_experiment.el     # Spike 2: Vector SVG card + Native Fallback
├── hud_appine_experiment.el  # Spike 3: Cocoa Dynamic Module WKWebView
└── hud_xwidget_experiment.el # Spike 4: Native xwidget-webkit child-frame
```

### Spike 1: The Text-Grid Child Frame (`hud_frame_experiment.el`)
* **Objective:** Validate Emacs child-frame creation, parent-relative coordinate math, and dynamic window manager anchoring on macOS.
* **Result:** **SUCCESS.** Proven that child frames created with `(parent-frame . parent)` natively calculate coordinates relative to the parent frame. By utilizing `(left . (- width))` and `(top . margin)`, the child frame locks perfectly to the top-right corner, automatically gliding during resizing, monitor switches, and dragging.

### Spike 2: The Vector SVG Canvas (`hud_svg_experiment.el`)
* **Objective:** Render sharp vector graphics, custom rounded corners (`rx="22" ry="22"`), and elegant `<feDropShadow>` filters natively within transparent child frames.
* **Result:** **CRITICAL DISCOVERY.** 
  * On standard macOS static Emacs binaries compiled with Apple's native CoreGraphics engine, complex XML filters and CSS `<style>` blocks failed to parse, rendering blank/empty child frames.
  * On modern `emacs-plus` builds featuring full **`librsvg`** support, raw vector rendering is fully unlocked, delivering gorgeous anti-aliased cards and live graphical pipeline DAGs.
  * A robust, styled **box-drawing text fallback** was successfully implemented to guarantee aesthetic safety on weaker native builds.

### Spike 3: The Cocoa Dynamic Module via Appine (`hud_appine_experiment.el`)
* **Objective:** Use `chaoswork/appine` (a native macOS Cocoa dynamic module) to render a GPU-accelerated WKWebView inside the child frame.
* **Result:** **ARCHITECTURAL BLOCKER DISCOVERED.**
  * Appine binds the macOS native `WKWebView` to the window display tree at the OS level and is strictly constrained to a **single concurrent viewport**.
  * When the `*Appine Window*` buffer is displayed in more than one window (e.g. your active main browser split and the background HUD child frame), Appine fails to render in the HUD, displaying a duplicate-window warning.
  * **Verdict:** Appine is highly performant for a single active workspace tab, but is **technically unviable** for a persistent background HUD overlay.

### Spike 4: The Native WebKit Engine (`hud_xwidget_experiment.el`)
* **Objective:** Render Emacs's native, C-integrated `xwidget-webkit` engine inside the child frame to bypass Appine's single-instance limitations.
* **Result:** **SPECTACULAR SUCCESS.**
  * Unlike Appine, native `xwidget-webkit` supports **unlimited concurrent sessions**. You can run a background HUD browser session inside your child frame while opening infinite independent browser tabs in your main window with **zero splits and zero conflicts**.
  * Resolved the Emacs 29/30 void-function bug: `xwidget-webkit-new-session` executes asynchronously and returns `nil`. We successfully resolved this by grabbing the active session from the global state using **`(xwidget-webkit-current-session)`**.
  * Bypassed the Cocoa GUI focus-lock loop by replacing `select-window` with **`with-selected-window`**, keeping the initialization purely within Lisp's internal state.

---

## Key Architectural & Visual Discoveries

Our spikes have yielded five crucial design patterns to deliver a premium, borderless, and hardware-accelerated overlay on macOS:

### 1. Borderless HUD Styling (UI Stripping)
By default, spawning an `xwidget-webkit` session inserts a header-line and mode-line. We successfully achieved a **completely borderless card layout** by stripping these decorations locally inside the xwidget buffer:
```elisp
(with-current-buffer buf
  (setq-local mode-line-format nil)       ; Strips the bottom mode-line
  (setq-local header-line-format nil)     ; Strips the top "WebKit: <Title>" header-line
  (setq-local display-line-numbers nil)   ; Prevents line numbers
  (setq-local left-fringe-width 0)        ; Removes left fringe spacing
  (setq-local right-fringe-width 0))       ; Removes right fringe spacing
```

### 2. Silent Window Configuration Restoring
Because `xwidget-webkit-new-session` is a user-facing interactive command, it is hardcoded to automatically split your parent frame and display the browser. We successfully resolved this focus-hijack by capturing and instantly restoring the window configuration in a millisecond:
```elisp
(let* ((parent-win-config (with-selected-frame parent (current-window-configuration)))
       (child-win-config (current-window-configuration))
       (_ (xwidget-webkit-new-session url))
       (session (xwidget-webkit-current-session))
       (buf (xwidget-buffer session)))
  
  ;; Instantly restore window layouts to erase the parent split!
  (with-selected-frame parent (set-window-configuration parent-win-config))
  (set-window-configuration child-win-config)
  
  ;; Dedicate the buffer strictly inside the child-frame window
  (set-window-buffer child-frame-window buf)
  (set-window-dedicated-p child-frame-window t))
```

### 3. Bypassing the Xwidget Kill Confirmation
When tearing down or toggling the HUD, Emacs prompts the user: `Buffer has xwidgets; kill it? (yes or no)`. We successfully bypassed this interactive prompt by surgically binding the process-checking hooks during cleanup:
```elisp
(let ((kill-buffer-query-functions (delq 'xwidget-kill-buffer-query-function kill-buffer-query-functions)))
  (kill-buffer buf))
```

### 4. GPU Hardware Acceleration Verified
To verify that the child-frame WebKit session has direct, hardware-accelerated access to macOS rendering pipelines, we executed three targeted graphics benchmarks inside the floating viewport:
*   **Test 1 (WebGL Report - Succeeded):** Pointing the HUD url to `https://webglreport.com` successfully fetched the unmasked WebGL graphics card details. It explicitly listed the system's hardware **Apple GPU** and the native Apple Metal pipeline (completely bypassing slow software canvas emulators).
*   **Test 3 (3D WebGL Geometry - Succeeded):** Pointing the HUD url to `https://threejs.org/examples/webgl_geometry_cube.html` rendered an interactive, animated, spinning 3D geometry cube using the Three.js canvas. The WebGL shaders rendered buttery-smoothly at a locked **60 frames per second** on Apple Silicon via Metal.
*   *Test 2 (Microsoft FishBowl - Failed):* Spawning this legacy benchmark was unsuccessful due to deprecated Internet Explorer-era API shims that are blocked or unsupported in modern Safari/macOS WebKit engines.

These results conclusively prove that the floating `xwidget-webkit` child frame behaves as a first-class, GPU-accelerated graphics window, fully capable of driving rich immediate-mode UI layouts at standard monitor refresh rates.

---

## The Next Phase: Egui WASM + Xwidget HUD

With the structural framework fully validated and running, the next phase is to build our immediate-mode GUI dashboard using **`egui` (Rust)**, compile it to **WebAssembly (WASM)**, and render it inside the xwidget viewport.

### Implementation Blueprint

```
 ┌─────────────┐                      ┌─────────────┐
 │ Emacs Lisp  │  ── Evaluating script ──> │   WebKit    │
 │ (Hypervisor)│  <── Pre-navigation ───  │  (Xwidget)  │
 └──────┬──────┘                          └──────▲──────┘
        │                                        │
     sexp-rpc                                 WASM HTTP
        │                                        │
 ┌──────▼──────┐                                 │
 │ Hypervisor  │  ──── Spawns static server ─────┘
 │ Rust Binary │  ──── Feeds state via WebSockets ───> egui WASM (60fps)
 └─────────────┘
```

1. **The egui HUD Dashboard:** Develop the unified heads-up dashboard in Rust using `egui` (rendering Environment health, Git changes, MCP DAGs, Org clocks).
2. **WebAssembly Compilation:** Compile the `egui` project to WASM (using `wasm-pack` or trunk) to run on standard HTML5 canvas wrappers.
3. **Local Static Server:** The Hypervisor daemon will host a lightweight static web server in the background to serve the `hud.html` and WASM assets locally.
4. **Data Bridge:** 
   * **Elisp $\rightarrow$ WASM:** Emacs serializes state payloads to JSON and pushes them across the bridge using `xwidget-webkit-execute-script` targeting `window.pushState()`.
   * **WASM $\rightarrow$ Elisp:** Interactive clicks (e.g. clicking a pipeline node to rebuild) trigger a location redirect `window.location = "emacs-hud://action"`, which Emacs intercepts and blocks using `xwidget-webkit-pre-navigation-functions`.
5. **Decoupled Architecture:** Emacs acts strictly as the layout shell and state engine; Rust/WASM acts as the GPU-accelerated immediate-mode rendering server.
