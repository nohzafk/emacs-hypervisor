//! Elle mmdflux plugin -- Mermaid ASCII rendering via the `mmdflux` crate.

use elle_plugin::{EllePrimDef, ElleResult, ElleValue, SIG_ERROR};
use mmdflux::{render_diagram, OutputFormat, RenderConfig, TextColorMode};
use unicode_width::UnicodeWidthStr;

elle_plugin::define_plugin!("mmdflux/", &PRIMITIVES);

const EDGE_LABEL_PIXELS_PER_COLUMN: f64 = 10.0;

extern "C" fn prim_mmdflux_render_ascii(args: *const ElleValue, nargs: usize) -> ElleResult {
    let a = api();
    if nargs != 1 {
        return a.err(
            "arity-error",
            &format!("mmdflux/render-ascii: expected 1 argument, got {}", nargs),
        );
    }

    let source = match required_string("mmdflux/render-ascii", args, nargs, 0) {
        Ok(source) => source,
        Err(result) => return result,
    };

    match render_ascii_with_config(&source, RenderConfig::default(), "mmdflux/render-ascii") {
        Ok(ascii) => a.ok(a.string(&ascii)),
        Err(result) => result,
    }
}

extern "C" fn prim_mmdflux_render_ascii_fit(args: *const ElleValue, nargs: usize) -> ElleResult {
    let a = api();
    if nargs != 2 {
        return a.err(
            "arity-error",
            &format!(
                "mmdflux/render-ascii-fit: expected 2 arguments, got {}",
                nargs
            ),
        );
    }

    let source = match required_string("mmdflux/render-ascii-fit", args, nargs, 0) {
        Ok(source) => source,
        Err(result) => return result,
    };

    let opts = unsafe { a.arg(args, nargs, 1) };
    let config = ascii_fit_config(opts);
    match render_ascii_fit(&source, config, requested_max_width(opts)) {
        Ok(ascii) => a.ok(a.string(&ascii)),
        Err(result) => result,
    }
}

extern "C" fn prim_mmdflux_render_svg(args: *const ElleValue, nargs: usize) -> ElleResult {
    let a = api();
    if nargs != 1 {
        return a.err(
            "arity-error",
            &format!("mmdflux/render-svg: expected 1 argument, got {}", nargs),
        );
    }

    let source = match required_string("mmdflux/render-svg", args, nargs, 0) {
        Ok(source) => source,
        Err(result) => return result,
    };

    match render_svg_with_config(&source, RenderConfig::default(), "mmdflux/render-svg") {
        Ok(svg) => a.ok(a.string(&svg)),
        Err(result) => result,
    }
}

fn required_string(
    primitive: &str,
    args: *const ElleValue,
    nargs: usize,
    index: usize,
) -> Result<String, ElleResult> {
    let a = api();
    let value = unsafe { a.arg(args, nargs, index) };
    match a.get_string(value) {
        Some(source) => Ok(source.to_string()),
        None => Err(a.err(
            "type-error",
            &format!("{primitive}: expected string, got {}", a.type_name(value)),
        )),
    }
}

fn ascii_fit_config(opts: ElleValue) -> RenderConfig {
    let mut config = RenderConfig {
        text_color_mode: TextColorMode::Plain,
        ..RenderConfig::default()
    };

    if let Some(padding) = positive_int_field(opts, "padding") {
        config.padding = Some(padding as usize);
    }

    if let Some(max_width) = positive_int_field(opts, "max-width") {
        config.layout.edge_label_max_width = Some(max_width as f64 * EDGE_LABEL_PIXELS_PER_COLUMN);
    }
    config
}

fn requested_max_width(opts: ElleValue) -> Option<usize> {
    positive_int_field(opts, "max-width").map(|value| value as usize)
}

fn positive_int_field(opts: ElleValue, key: &str) -> Option<i64> {
    let a = api();
    a.get_int(a.get_struct_field(opts, key))
        .filter(|value| *value > 0)
}

fn render_ascii_fit(
    source: &str,
    config: RenderConfig,
    max_width: Option<usize>,
) -> Result<String, ElleResult> {
    let initial = render_ascii_with_config(source, config.clone(), "mmdflux/render-ascii-fit")?;
    if max_width.is_some_and(|width| ascii_display_width(&initial) > width) {
        if let Some(vertical_source) = force_top_level_flowchart_direction(source, "TD") {
            let vertical =
                render_ascii_with_config(&vertical_source, config, "mmdflux/render-ascii-fit")?;
            if ascii_display_width(&vertical) < ascii_display_width(&initial) {
                return Ok(vertical);
            }
        }
    }
    Ok(initial)
}

fn ascii_display_width(output: &str) -> usize {
    output
        .lines()
        .map(UnicodeWidthStr::width)
        .max()
        .unwrap_or(0)
}

fn force_top_level_flowchart_direction(source: &str, direction: &str) -> Option<String> {
    let mut out = String::with_capacity(source.len() + direction.len() + 1);
    let mut changed = false;

    for line in source.lines() {
        if !changed {
            if let Some(rewritten) = rewrite_flowchart_header(line, direction) {
                out.push_str(&rewritten);
                out.push('\n');
                changed = true;
                continue;
            }
        }
        out.push_str(line);
        out.push('\n');
    }

    changed.then_some(out)
}

fn rewrite_flowchart_header(line: &str, direction: &str) -> Option<String> {
    let indent_len = line.len() - line.trim_start().len();
    let indent = &line[..indent_len];
    let trimmed = line[indent_len..].trim_end();
    let trailing = &line[indent_len + trimmed.len()..];
    let mut parts = trimmed.split_whitespace();
    let keyword = parts.next()?;
    if !(keyword.eq_ignore_ascii_case("flowchart") || keyword.eq_ignore_ascii_case("graph")) {
        return None;
    }

    let existing_direction = parts.next();
    if existing_direction.is_some_and(|token| token.eq_ignore_ascii_case(direction)) {
        return None;
    }
    Some(format!("{indent}{keyword} {direction}{trailing}"))
}

fn render_ascii_with_config(
    source: &str,
    config: RenderConfig,
    primitive: &str,
) -> Result<String, ElleResult> {
    render_diagram(source, OutputFormat::Ascii, &config)
        .map_err(|error| api().err("mmdflux-error", &format!("{primitive}: {error}")))
}

fn render_svg_with_config(
    source: &str,
    config: RenderConfig,
    primitive: &str,
) -> Result<String, ElleResult> {
    render_diagram(source, OutputFormat::Svg, &config)
        .map_err(|error| api().err("mmdflux-error", &format!("{primitive}: {error}")))
}

static PRIMITIVES: &[EllePrimDef] = &[
    EllePrimDef::exact(
        "mmdflux/render-ascii",
        prim_mmdflux_render_ascii,
        SIG_ERROR,
        1,
        "Render a Mermaid diagram to ASCII art.",
        "mmdflux",
        r#"(mmdflux/render-ascii "flowchart LR; A-->B-->C")"#,
    ),
    EllePrimDef::exact(
        "mmdflux/render-ascii-fit",
        prim_mmdflux_render_ascii_fit,
        SIG_ERROR,
        2,
        "Render a Mermaid diagram to ASCII art with options. Options: {:max-width N :padding N}.",
        "mmdflux",
        r#"(mmdflux/render-ascii-fit "flowchart LR; A-->B-->C" {:max-width 80})"#,
    ),
    EllePrimDef::exact(
        "mmdflux/render-svg",
        prim_mmdflux_render_svg,
        SIG_ERROR,
        1,
        "Render a Mermaid diagram to SVG.",
        "mmdflux",
        r#"(mmdflux/render-svg "flowchart LR; A-->B-->C")"#,
    ),
];

#[cfg(test)]
mod tests {
    use super::*;

    const WIDE_FLOWCHART: &str = r#"flowchart LR
    subgraph S1["Stage 1 - Stable Kernel"]
        direction TB
        A["Emacs home"] --> B["load generated init.el"]
        B --> C["kernel boots"]
    end

    subgraph S2["Stage 2 - Control Plane"]
        direction TB
        D["launch emacs-hypervisor serve"]
        D --> E["sexp-rpc session established"]
    end

    subgraph S3["Stage 3 - Session Runtime"]
        direction TB
        F["emit runtime forms"]
        F --> G["package planning"]
        G --> H["config-unit execution"]
        H --> I["reload + reports ready"]
    end

    S1 --> S2 --> S3
"#;

    #[test]
    fn top_level_lr_flowchart_can_be_forced_vertical() {
        let rewritten = force_top_level_flowchart_direction("flowchart LR\nA --> B\n", "TD")
            .expect("header should be rewritten");

        assert_eq!(rewritten, "flowchart TD\nA --> B\n");
    }

    #[test]
    fn ascii_fit_uses_vertical_fallback_for_wide_top_level_lr_diagrams() {
        let config = RenderConfig {
            text_color_mode: TextColorMode::Plain,
            ..RenderConfig::default()
        };

        let normal = assert_rendered(render_ascii_with_config(
            WIDE_FLOWCHART,
            config.clone(),
            "mmdflux/render-ascii-fit",
        ));
        let fitted = assert_rendered(render_ascii_fit(WIDE_FLOWCHART, config, Some(80)));

        assert!(ascii_display_width(&normal) > 80);
        assert!(ascii_display_width(&fitted) <= 80);
        assert!(fitted.contains("Stage 1 - Stable Kernel"));
        assert!(fitted.contains("Stage 2 - Control Plane"));
        assert!(fitted.contains("Stage 3 - Session Runtime"));
    }

    fn assert_rendered(result: Result<String, ElleResult>) -> String {
        match result {
            Ok(output) => output,
            Err(_) => panic!("render should succeed"),
        }
    }
}
