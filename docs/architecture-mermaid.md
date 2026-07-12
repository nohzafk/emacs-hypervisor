# Mermaid Extension Architecture

## Overview

The Mermaid extension renders Mermaid diagram fences inline in Emacs markdown buffers. It produces either SVG images (displayed as overlays via `create-image`) or ASCII art text (displayed as plain overlays). Rendering is performed by **mmdflux**, a native Rust plugin loaded into the Elle runtime through the [stable plugin ABI](architecture.md#extensions). The extension follows the same actor infrastructure used by all Hypervisor extensions: requests arrive from Emacs over sexp-rpc, are dispatched to the actor, rendered by the plugin, and the response is sent back to Emacs.

---

## Architecture Diagram

```text
Emacs markdown buffer
  │
  ├─ after-change-functions / window-configuration-change-hook
  │    └─ debounced idle timer (default 0.8s)
  │         └─ emacs-hypervisor-markdown-mermaid-render-buffer
  │              └─ per fenced ```mermaid block:
  │                   └─ emacs-hypervisor-extension-call :mermaid :render
  │                        └─ sexp-rpc request → Elle subprocess stdin
  │
  │           ┌── Elle subprocess ────────────────────────────────────┐
  │           │  mailbox reader fiber (run-mailbox-reader)            │
  │           │    └─ route-message → :other queue                    │
  │           │         └─ extension actor (run-extension-actor)      │
  │           │              └─ dispatch-extension-call               │
  │           │                   └─ mermaid handler → :render fn     │
  │           │                        └─ mmdflux Rust plugin         │
  │           │                             ├─ render-svg             │
  │           │                             └─ render-ascii-fit       │
  │           └───────────────────────────────────────────────────────┘
  │
  └─ Elle stdout → Emacs process filter
       └─ dispatch-rpc-response → pending-responses
            └─ await-response unblocks
                 └─ response plist {:ok true :kind :image :svg "..."}
                      └─ create-image from in-memory SVG bytes
                           └─ overlay at block-end position
```

---

## Component Stack

### 1. mmdflux Rust Plugin

mmdflux is a native Rust crate compiled as an Elle plugin — a `cdylib` (`libelle_mmdflux`) built against the stable plugin ABI in the `.elle-plugins` workspace. It is **embedded and dlopened at runtime**: `build.rs` bundles the compiled dynamic library as bytes inside the `emacs-hypervisor` binary at build time; at startup the host extracts it to a cache directory and the Elle VM loads it via `(import spec)`. The binary therefore stays self-contained with no external plugin files required at runtime.

Discovery order at startup:

1. `EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_MMDFLUX_PATH` environment variable (set by the host binary when embedding)
2. Fallback string `"plugin/mmdflux"`

The Elle `(import spec)` call is wrapped in `(protect ...)`. If the import fails, `load-mmdflux` returns `nil` and `make-handler` returns `nil`, causing `register` to skip adding `:mermaid` to the handler map. The extension is then simply absent for the session: any later `:extension-call` request for `:mermaid` receives a per-request `extension-unavailable` error from the generic dispatcher (`elle/extensions.lisp`). There is no startup validation step.

Exported functions used by the extension:

| Function | Purpose |
|---|---|
| `mmdflux:render-svg` | Render Mermaid source to SVG string |
| `mmdflux:render-ascii-fit` | Render Mermaid source to ASCII art, constrained by viewport width |

Both functions accept a source string and an options struct. See configuration section for available option keys.

### 2. Elle Extension Actor (`elle/extension-mermaid.lisp`)

The extension is a pure function module: `emacs-hypervisor-mermaid-extension-module` takes the `extensions` module as its only argument and returns a `{:register register :render render}` struct.

## Handler registration

`register` calls `make-handler`, which calls `load-mmdflux`. If the plugin loaded successfully, it returns a single-method handler map:

```lisp
{:render (fn [args] (render mmdflux args))}
```

If the plugin is absent, `make-handler` returns `nil` and the `:mermaid` key is omitted from the registry.

## Render dispatch

The `:render` method is the only method. It:

1. Extracts `:source` from `args` — must be a string or returns `:invalid-request`.
2. Normalises `:style` via `normalize-render-style`: accepts `"svg"`, `"ascii"`, or defaults to `ascii` when absent or unrecognised.
3. Dispatches to `render-svg` or `render-ascii`.

## render-svg

Calls `mmdflux:render-svg source (render-options args)`. On success returns:

```lisp
{:ok true :kind :image :mime "image/svg+xml" :svg "<svg...>" :renderer :mmdflux}
```

## render-ascii

Extracts `:viewport {:width N}` from `args`, merges it with `render-options`, then calls `mmdflux:render-ascii-fit source fit-opts` (includes `:max-width` and `:padding 1`). On success returns:

```lisp
{:ok true :kind :text :mime "text/plain" :text "..." :renderer :mmdflux}
```

## Error payloads

All error paths return a structured payload via `extension-error-payload`:

```lisp
{:ok false :error <kind> :message <string> :renderer :mmdflux}
```

Error kinds: `:invalid-request`, `:render-failed`.

`protect-message` extracts a human-readable string from whatever the plugin throws (struct, string, or other).

### 3. Extension Actor Infrastructure (`elle/extensions.lisp`)

All extensions share a single actor loop and dispatch table.

## Registry

Built in `hypervisor.lisp` after session startup completes:

```lisp
(defn emacs-hypervisor-extension-registry [settings]
  (let [handlers (mermaid-extension:register settings {})]
    (extensions:make-registry settings handlers)))
```

`make-registry` returns `{:settings settings :handlers handlers}` where `handlers` is a map of keywords to handler structs (e.g. `{:mermaid {...}}`).

## Dispatch

`dispatch-extension-call` extracts `:extension`, `:method`, and `:args` from the wire payload, looks up the handler in `(get registry :handlers)`, looks up the method function in the handler, and calls it. Errors for unknown extension or unknown method are sent as error responses via `protocol:send-error-response`.

## Actor loop

`run-extension-actor` is a blocking `while true` loop that reads from the shared mailbox (`protocol:read-message`), which in turn calls `await-mailbox-message` → `pop-arrival-message`. Incoming messages routed to the `:other` queue (i.e. requests, not responses or events) are processed here.

`handle-extension-message` checks `message-kind`:

- `:request` with op `:extension-call` → `dispatch-extension-call`
- `:request` with any other op → error response
- `:event`, `:response`, other → silently ignored

### 4. Elisp Rendering Layer (`elle/runtime-forms/emacs-hypervisor-markdown-mermaid.el`)

## Minor mode

`emacs-hypervisor-markdown-mermaid-mode` is a buffer-local minor mode (lighter `" HV-Mermaid"`). On enable it installs two hooks:

- `after-change-functions` → `emacs-hypervisor-markdown-mermaid--schedule-refresh`
- `window-configuration-change-hook` → `emacs-hypervisor-markdown-mermaid--schedule-refresh`

On first enable, it immediately calls `render-buffer` if the mermaid extension is active.

On disable it removes the hooks and calls `clear-buffer` to remove all overlays.

Auto-enabling: `emacs-hypervisor-markdown-mermaid-install-hooks` adds `emacs-hypervisor-markdown-mermaid-maybe-enable` to `markdown-mode-hook`, `markdown-ts-mode-hook`, and `gfm-mode-hook`.

## Debounced refresh

`--schedule-refresh` cancels any pending idle timer and schedules a new one via `run-with-idle-timer` at the configured delay. The timer fires `--auto-refresh-buffer`, which checks the buffer is live and the mode is still active before calling `render-buffer`.

## Source block scanning

`--source-blocks` scans the buffer with two successive `re-search-forward` calls:

1. Opening fence: `` ^[ \t]*```[ \t]*mermaid[^\n]*\n ``
2. Closing fence: `` ^[ \t]*```[ \t]*$ ``

Each matched block is a list: `(block-start block-end source-start source-end source-text)`.

## RPC call

`--render-block` calls `emacs-hypervisor-extension-call :mermaid :render` with:

```elisp
(:source <string>
 :style  <:svg | :ascii>
 :options (:layout-engine ... :edge-preset ... :path-simplification ... :theme ... :theme-mode ... :unicode ... :ansi ...)
 :viewport (:width <columns>))
```

Timeout is 10 seconds. `:style` is resolved by `--render-style` from the `emacs-hypervisor-markdown-mermaid-render-style` customisation: `:auto` checks `(image-type-available-p 'svg)` and falls back to `:ascii` if SVG is unsupported.

## SVG display pipeline

On a successful `:image` response with `mime "image/svg+xml"`:

1. `--render-object` builds a render plist including `block-start`, `block-end`, `source-*`, `source-buffer`, and the raw SVG string.
2. `--prepare-image-cache` writes the SVG to a temp file under `temporary-file-directory/emacs-hypervisor/mermaid/` (named `<base>-line-<N>-<hash8>-<hash8>.svg`), then calls `--create-preview-image` with `:max-width` / `:max-height` bounds.
3. `--create-preview-image` calls `(create-image data 'svg t :ascent center :scale 1 :max-width W :max-height H)`. Falls back without `:max-height` if Emacs does not support that property.
4. The image object is stored in the render plist as `:preview-image`.
5. An overlay is inserted at `block-end` with `after-string` set to `"\n<propertized-space>\n"` where the space carries the `display` property pointing to the image.

## ASCII display

On a successful `:text` response, an overlay is inserted at `block-end` with `after-string` set to `"\n<ascii-text>\n"`.

## Overlay management

All overlays are tracked in the buffer-local `emacs-hypervisor-markdown-mermaid--overlays` list. `clear-buffer` deletes all overlays and resets the list.

Each image overlay also stores:

- `emacs-hypervisor-markdown-mermaid-render` → render plist (for viewer access)
- `help-echo` → `"mouse-1: open diagram viewer; C-c C-r: refresh"`
- `keymap` → `emacs-hypervisor-markdown-mermaid-preview-map`

Cache files are deleted on `kill-emacs` via `kill-emacs-hook`.

## Viewer mode

`emacs-hypervisor-markdown-mermaid-viewer-mode` is a major mode derived from `image-mode`. A viewer buffer is created by inserting the SVG cache file contents, setting the visited filename to the cache file, then activating the mode. The buffer is read-only and `buffer-offer-save` is nil.

Viewer keybindings (in addition to `image-mode-map`):

| Key | Action |
|---|---|
| `j` / `k` | Scroll image down / up |
| `+` / `=` | Zoom in |
| `-` | Zoom out |
| `0` | Original size |
| `w` | Fit to width |
| `f` | Fit to window |
| `g` | Refresh from source |
| `RET` | Jump to source block |
| `q` | Close viewer |

Opening a viewer: click `mouse-1` on an inline preview or call `emacs-hypervisor-markdown-mermaid-open-viewer`. Display policy is controlled by `emacs-hypervisor-markdown-mermaid-viewer-display-action` (other-window / side-window / frame).

---

## Data Flow: Full Render Round-Trip

```text
User edits markdown buffer
  │
  ├─ after-change-functions fires → --schedule-refresh
  │    └─ cancel existing idle timer
  │    └─ run-with-idle-timer 0.8s → --auto-refresh-buffer
  │
  └─ idle timer fires
       └─ emacs-hypervisor-markdown-mermaid-render-buffer
            ├─ clear existing overlays
            └─ for each fenced ```mermaid block:
                 │
                 ├─ emacs-hypervisor-extension-call :mermaid :render <plist> 10
                 │    └─ emacs-hypervisor-request :extension-call {:extension :mermaid
                 │                                                  :method :render
                 │                                                  :args {...}}
                 │         └─ process-send-string to Elle subprocess stdin
                 │              (sexp-rpc line: (:rpc :protocol :sexp-rpc :version 1
                 │                                :kind :request :id N :op :extension-call
                 │                                :payload (:extension :mermaid ...)))
                 │
                 │    ── Elle subprocess ──────────────────────────────────────────
                 │    run-mailbox-reader fiber reads stdin line
                 │      └─ route-message → :other queue (requests go here)
                 │           └─ monitor:broadcast wakes extension actor
                 │
                 │    run-extension-actor loop wakes
                 │      └─ pop-arrival-message from :other queue
                 │           └─ handle-extension-message
                 │                └─ dispatch-extension-call
                 │                     ├─ lookup :mermaid handler
                 │                     ├─ lookup :render method fn
                 │                     └─ (method-fn args)
                 │                          └─ render mmdflux args
                 │                               ├─ normalize-render-style → :svg
                 │                               └─ render-svg mmdflux source args
                 │                                    └─ mmdflux:render-svg source opts
                 │                                         └─ Rust → SVG string
                 │                                    └─ {:ok true :kind :image
                 │                                        :mime "image/svg+xml"
                 │                                        :svg "<svg...>"
                 │                                        :renderer :mmdflux}
                 │                          └─ protocol:send-response id payload
                 │                               └─ println sexp-rpc envelope to stdout
                 │    ────────────────────────────────────────────────────────────
                 │
                 │    Emacs process filter receives stdout line
                 │      └─ parse sexp-rpc envelope
                 │           └─ dispatch-rpc-response by id
                 │                └─ store in pending-responses table
                 │                     └─ await-response unblocks
                 │
                 └─ response plist {:ok true :kind :image :svg "..." ...}
                      ├─ --display-for-response
                      │    └─ --render-object → render plist
                      │         └─ --prepare-image-cache
                      │              ├─ write SVG to temp file
                      │              └─ create-image svg 'svg t :max-width W :max-height H
                      └─ --insert-overlay at block-end
                           └─ after-string = "\n<propertized-space with display image>\n"
                                └─ image visible inline below fence
```

### Plugin Loading

```text
hypervisor.lisp startup
  └─ emacs-hypervisor-extension-registry settings
       └─ mermaid-extension:register settings {}
            └─ make-handler settings
                 └─ load-mmdflux
                      ├─ spec = EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_MMDFLUX_PATH
                      │         or "plugin/mmdflux"
                      └─ (protect (import spec))
                           ├─ ok? = true  → return plugin object
                           └─ ok? = false → return nil
                                └─ make-handler returns nil
                                     └─ register skips :mermaid key
                                          └─ unsupported-extensions detects mismatch → error
```

When embedded via `EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_MMDFLUX_PATH`, the host binary sets the env var to a path it extracted from the embedded binary at startup, before forking the Elle subprocess.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Lisp runtime | Elle (custom dialect with fibers, monitors, `ev/scope`) |
| Wire protocol | sexp-rpc: newline-delimited S-expressions over subprocess stdin/stdout |
| Rendering plugin | mmdflux Rust crate (SVG + ASCII rendering), embedded `cdylib`, dlopened at runtime |
| Emacs display | `create-image` with `'svg` type, `after-string` overlays |
| Viewer | `image-mode`-derived major mode with zoom/scroll |
| Concurrency | Elle fibers: mailbox reader fiber + extension actor fiber share a monitor |

---

## Configuration

All variables belong to the `emacs-hypervisor-markdown-mermaid` customisation group.

| Variable | Type | Default | Effect |
|---|---|---|---|
| `emacs-hypervisor-markdown-mermaid-render-style` | `:auto` / `:svg` / `:ascii` | `:auto` | Render style. `:auto` uses SVG when `(image-type-available-p 'svg)`, ASCII otherwise. |
| `emacs-hypervisor-markdown-mermaid-auto-refresh-delay` | number or nil | `0.8` | Seconds of idle time before re-rendering after a buffer edit. `nil` disables auto-refresh. |
| `emacs-hypervisor-markdown-mermaid-layout-engine` | string | `"mermaid-layered"` | mmdflux layout engine. Also accepts `"flux-layered"`. |
| `emacs-hypervisor-markdown-mermaid-edge-preset` | string or nil | `nil` | SVG edge routing preset. `nil` uses mmdflux's engine default. Options: `"straight"`, `"polyline"`, `"step"`, `"smooth-step"`, `"curved-step"`, `"basis"`. |
| `emacs-hypervisor-markdown-mermaid-path-simplification` | string | `"lossless"` | SVG path simplification level: `"none"`, `"lossless"`, `"lossy"`, `"minimal"`. |
| `emacs-hypervisor-markdown-mermaid-theme` | string or nil | `nil` | Named SVG theme. `nil` uses mmdflux/diagram default. Options include `"zinc-light"`, `"zinc-dark"`, standard Mermaid themes, or a custom string. |
| `emacs-hypervisor-markdown-mermaid-theme-mode` | string or nil | `nil` | SVG theme output mode: `"static"` or `"dynamic"` (CSS variables). `nil` uses mmdflux default. |
| `emacs-hypervisor-markdown-mermaid-ascii-style` | symbol | `unicode` | ASCII render character set: `unicode` (box-drawing), `ansi` (box-drawing + ANSI colour), `ascii` (plain). |
| `emacs-hypervisor-markdown-mermaid-preview-max-width` | symbol or integer or nil | `fill-column` | Inline preview max width. `fill-column` = fill-column × char-width pixels. `window` = window pixel width. Integer = pixels. `nil` = no limit. |
| `emacs-hypervisor-markdown-mermaid-preview-max-height` | float or integer or nil | `0.30` | Inline preview max height. Float = fraction of window pixel height. Integer = pixels. `nil` = no limit. |
| `emacs-hypervisor-markdown-mermaid-viewer-display-action` | symbol | `other-window` | How to open the full-size viewer: `other-window`, `side-window`, or `frame`. |
| `emacs-hypervisor-markdown-mermaid-viewer-fit-on-open` | boolean | `t` | When non-nil, fit-to-width is applied when a viewer is first opened. |
| `emacs-hypervisor-markdown-mermaid-preview-use-slices` | nil or `t` | `nil` | Slice large inline previews to reduce redisplay flicker. Leave nil unless flicker is observed. |
