# Elle `mmdflux` Plugin

The `mmdflux` plugin is an Elle-native dynamically loaded library that extends the [Elle Lisp](https://github.com/elle-lisp/elle) environment with high-performance Mermaid diagram rendering. It wraps the [`mmdflux`](https://github.com/kevinswiber/mmdflux#readme) Rust engine to generate vector SVGs and responsive ASCII/Unicode box-drawing text layouts.

---

## Primitives Reference

The plugin registers three core primitive functions under the `mmdflux/` namespace. These can be invoked directly from Elle Lisp code:

### 1. `mmdflux/render-ascii`
Renders a raw Mermaid diagram to standard ASCII art using the engine's default rules.
* **Signature:** `(mmdflux/render-ascii source-string)`
* **Example:**
  ```lisp
  (mmdflux/render-ascii "flowchart LR; A-->B-->C")
  ```

### 2. `mmdflux/render-ascii-fit`
Renders a Mermaid diagram to text art with dynamic layout viewport fitting and custom character options. If the diagram exceeds the `:max-width` limit in its horizontal form, the layout engine attempts to force top-level flowchart direction to vertical (`TD`/`TB`) to optimize fit.
* **Signature:** `(mmdflux/render-ascii-fit source-string options-map)`
* **Supported Options:**
  - `:max-width` (Integer): Fits the text layout width inside this column count.
  - `:padding` (Integer): Padding spaces around the diagram.
  - `:unicode` (Boolean symbol `'true`/`'false`): Enables elegant rounded box-drawing Unicode characters (`┌`, `┐`, `─`, `│`) instead of `+`, `-`, and `|` symbols.
  - `:ansi` (Boolean symbol `'true`/`'false`): Enables terminal-style ANSI escape colorization.
* **Example:**
  ```lisp
  (mmdflux/render-ascii-fit "flowchart LR; A-->B" {:max-width 80 :unicode true :ansi false})
  ```

### 3. `mmdflux/render-svg`
Renders a Mermaid diagram to a clean vector SVG string. Under macOS, it automatically routes the output through the **In-Memory SVG Marker Flattening** post-processor to ensure native compatibility.
* **Signature:** `(mmdflux/render-svg source-string options-map)`
* **Supported Options:**
  - `:layout-engine` (String): The routing layout engine (e.g. `"mermaid-layered"`, `"flux-layered"`).
  - `:edge-preset` (String): Edge routing styles (e.g. `"basis"`, `"straight"`, `"polyline"`).
  - `:path-simplification` (String): Simplification level (`"none"`, `"lossless"`, `"lossy"`).
  - `:theme` (String): Optional mmdflux SVG theme name.
  - `:theme-mode` (String): SVG theme output mode (`"static"`, `"dynamic"`).
* **Example:**
  ```lisp
  (mmdflux/render-svg "flowchart LR; A-->B" {:layout-engine "mermaid-layered" :path-simplification "lossless"})
  ```

---

## In-Memory SVG Marker Flattening

To maintain compatibility with macOS's native vector image preview, the plugin includes a built-in post-processor that modifies SVG outputs.

### Why We Flatten SVG Markers

Standard Mermaid flowcharts represent edge arrowheads using SVG `<marker>` elements in the `<defs>` block and reference them on paths via `marker-end="url(#arrowhead)"`. 

However, on macOS, Emacs compiled with `--with-native-image-api` relies on Apple's private **CoreSVG** framework to render vector images. To keep the framework lightweight, Apple did not implement the full SVG specification. CoreSVG lacks support for the `<marker>` tag. When it encounters one, it renders the edge lines correctly but silently ignores the arrowheads, leaving flowcharts without arrows.

Spawning an external `resvg` process to convert SVG to PNG works, but introduces dynamic runtime binary requirements, disk cache IO, and child process overhead.

CoreSVG fully supports basic shapes, `<path>` tags, and group transforms (`<g transform="...">`). By parsing the SVG string in-memory and "flattening" the `<marker>` references into standard inline paths with translation and rotation matrices, we get **pixel-perfect vector arrowheads natively on macOS with zero external dependencies**.

---

### How the Algorithm Works

The flattening algorithm runs inside `flatten_svg_markers` in `src/lib.rs` and works through these deterministic steps:

#### 1. Extract Marker Definitions
The parser scans the SVG string for `<marker>` elements in `<defs>` and extracts:
* `id`: The reference name (e.g. `"arrowhead"`).
* `refX` & `refY`: The local coordinate point inside the marker that aligns with the path endpoint.
* `markerWidth` & `markerHeight`: The physical dimensions of the marker.
* `viewBox`: The coordinate window of the marker's inner paths (typically `10.0 x 10.0`).
* `inner_content`: The literal `<path>` or `<polygon>` tags drawing the arrow shape itself.

#### 2. Parse Path Edges
The algorithm searches for `<path>` tags containing `marker-end="url(#...)"` or `marker-start="url(#...)"` attributes.

#### 3. Extract Coordinates & Calculate Tangents
For any matching path, it parses the floating-point numbers from the `d` path data attribute:
* For `marker-end`, the last two coordinate pairs are extracted:
  * $P_2(x_2, y_2)$: The exact endpoint of the path.
  * $P_1(x_1, y_1)$: The vertex or control point immediately preceding it.
* The tangent direction vector $\vec{v}$ of the line ending at the node is:
  $$\vec{v} = (x_2 - x_1, y_2 - y_1)$$
* The rotation angle $\theta$ (in degrees) is calculated via:
  $$\theta_{\text{deg}} = \operatorname{atan2}(y_2 - y_1, x_2 - x_1) \times \frac{180}{\pi}$$

#### 4. Build the Transformed Group
The `marker-end` attribute is stripped from the `<path>`, and a nested group is injected immediately following it. The transformation is mathematically identical to standard marker rendering:

```xml
<!-- Translation to path end, rotation along tangent, and scaling to marker size -->
<g transform="translate(x2, y2) rotate(theta_deg) scale(scale_x, scale_y)">
  <!-- Inner translation shifting the marker's alignment reference to origin -->
  <g transform="translate(-refX, -refY)">
    <!-- Original vector path (with color set to match the edge line's stroke) -->
    <path d="..." fill="stroke_color" />
  </g>
</g>
```

#### 5. Defs Cleanup
Finally, the original `<marker>` declarations are stripped from the `<defs>` block to keep the XML clean and prevent any unused assets from bloating the output.

---

## Building and Loading (Upstream Elle Plugin)

The `mmdflux` plugin compiles to a dynamically-loaded shared library (`libelle_mmdflux.dylib` on macOS or `libelle_mmdflux.so` on Linux/Unix). 

### As a Member of the Elle Workspace
To build this plugin as part of the upstream Elle repository layout:
1. Place the `mmdflux` folder inside the `plugins/` directory of the `elle` repository.
2. Build all plugins from the `elle` root:
   ```bash
   make plugins
   ```
   Or build only the `elle-mmdflux` plugin:
   ```bash
   cargo build --release -p elle-mmdflux
   ```
This places the compiled library (`libelle_mmdflux.dylib` / `.so`) in `target/release/` of the main `elle` workspace.

### Standalone Build
To compile the plugin independently outside of the `elle` workspace:
```bash
cargo build --release
```
This produces the shared library inside the plugin's local `target/release/` directory.

### Loading the Plugin in Elle Lisp
Once compiled, you can load the plugin dynamically inside any Elle Lisp session via the standard import system:

```lisp
(import "plugin/mmdflux")
```

#### Library Discovery Path
Elle locates the compiled shared library using standard directory searching:
1. It automatically looks inside `target/release/` relative to the current working directory.
2. If built standalone or located in a custom directory, tell Elle where to find the library using the `--path` CLI flag:
   ```bash
   elle --path=/path/to/plugin/target/release
   ```
