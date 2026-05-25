//! Elle mmdflux plugin -- Mermaid ASCII rendering via the `mmdflux` crate.

use elle_plugin::{EllePrimDef, ElleResult, ElleValue, SIG_ERROR};
use mmdflux::format::EdgePreset;
use mmdflux::simplification::PathSimplification;
use mmdflux::{
    render_diagram, EngineAlgorithmId, OutputFormat, RenderConfig, SvgThemeConfig, SvgThemeMode,
    TextColorMode,
};
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
    let format = if boolean_field(opts, "unicode").unwrap_or(false) {
        OutputFormat::Text
    } else {
        OutputFormat::Ascii
    };

    match render_text_fit(&source, config, requested_max_width(opts), format) {
        Ok(ascii) => a.ok(a.string(&ascii)),
        Err(result) => result,
    }
}

extern "C" fn prim_mmdflux_render_svg(args: *const ElleValue, nargs: usize) -> ElleResult {
    let a = api();
    if nargs != 2 {
        return a.err(
            "arity-error",
            &format!("mmdflux/render-svg: expected 2 arguments, got {}", nargs),
        );
    }

    let source = match required_string("mmdflux/render-svg", args, nargs, 0) {
        Ok(source) => source,
        Err(result) => return result,
    };

    let opts = unsafe { a.arg(args, nargs, 1) };
    let config = match svg_config(opts) {
        Ok(config) => config,
        Err(result) => return result,
    };

    match render_svg_with_config(&source, config, "mmdflux/render-svg") {
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

fn boolean_field(opts: ElleValue, key: &str) -> Option<bool> {
    let a = api();
    a.get_bool(a.get_struct_field(opts, key))
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

    if boolean_field(opts, "ansi").unwrap_or(false) {
        config.text_color_mode = TextColorMode::Ansi;
    }

    config
}

fn requested_max_width(opts: ElleValue) -> Option<usize> {
    positive_int_field(opts, "max-width").map(|value| value as usize)
}

fn svg_config(opts: ElleValue) -> Result<RenderConfig, ElleResult> {
    let mut config = RenderConfig::default();

    config.layout_engine = optional_engine_field(opts, "layout-engine")?;
    config.edge_preset = optional_edge_preset_field(opts, "edge-preset")?;
    config.path_simplification =
        optional_path_simplification_field(opts, "path-simplification")?.unwrap_or_default();
    config.svg_theme = optional_svg_theme_config(opts)?;

    Ok(config)
}

fn positive_int_field(opts: ElleValue, key: &str) -> Option<i64> {
    let a = api();
    a.get_int(a.get_struct_field(opts, key))
        .filter(|value| *value > 0)
}

fn string_field(opts: ElleValue, key: &str) -> Option<String> {
    let a = api();
    a.get_string(a.get_struct_field(opts, key))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn optional_engine_field(
    opts: ElleValue,
    key: &str,
) -> Result<Option<EngineAlgorithmId>, ElleResult> {
    match string_field(opts, key) {
        Some(value) => EngineAlgorithmId::parse(&value).map(Some).map_err(|error| {
            api().err(
                "mmdflux-option-error",
                &format!("mmdflux/render-svg: {key}: {error}"),
            )
        }),
        None => Ok(None),
    }
}

fn optional_edge_preset_field(
    opts: ElleValue,
    key: &str,
) -> Result<Option<EdgePreset>, ElleResult> {
    match string_field(opts, key) {
        Some(value) => EdgePreset::parse(&value).map(Some).map_err(|error| {
            api().err(
                "mmdflux-option-error",
                &format!("mmdflux/render-svg: {key}: {error}"),
            )
        }),
        None => Ok(None),
    }
}

fn optional_path_simplification_field(
    opts: ElleValue,
    key: &str,
) -> Result<Option<PathSimplification>, ElleResult> {
    match string_field(opts, key) {
        Some(value) => PathSimplification::parse(&value)
            .map(Some)
            .map_err(|error| {
                api().err(
                    "mmdflux-option-error",
                    &format!("mmdflux/render-svg: {key}: {error}"),
                )
            }),
        None => Ok(None),
    }
}

fn optional_svg_theme_config(opts: ElleValue) -> Result<Option<SvgThemeConfig>, ElleResult> {
    let theme_name = string_field(opts, "theme");
    let theme_mode = optional_svg_theme_mode_field(opts, "theme-mode")?;

    if theme_name.is_none() && theme_mode.is_none() {
        return Ok(None);
    }

    Ok(Some(SvgThemeConfig {
        name: theme_name,
        mode: theme_mode.unwrap_or_default(),
        ..SvgThemeConfig::default()
    }))
}

fn optional_svg_theme_mode_field(
    opts: ElleValue,
    key: &str,
) -> Result<Option<SvgThemeMode>, ElleResult> {
    match string_field(opts, key) {
        Some(value) => match value.to_ascii_lowercase().as_str() {
            "static" => Ok(Some(SvgThemeMode::Static)),
            "dynamic" => Ok(Some(SvgThemeMode::Dynamic)),
            _ => Err(api().err(
                "mmdflux-option-error",
                &format!(
                    "mmdflux/render-svg: {key}: unknown SVG theme mode {value:?} \
                     (expected one of: static, dynamic)"
                ),
            )),
        },
        None => Ok(None),
    }
}

fn render_text_fit(
    source: &str,
    config: RenderConfig,
    max_width: Option<usize>,
    format: OutputFormat,
) -> Result<String, ElleResult> {
    let initial = render_text_with_config(source, config.clone(), "mmdflux/render-ascii-fit", format)?;
    if max_width.is_some_and(|width| ascii_display_width(&initial) > width) {
        if let Some(vertical_source) = force_top_level_flowchart_direction(source, "TD") {
            let vertical =
                render_text_with_config(&vertical_source, config, "mmdflux/render-ascii-fit", format)?;
            if ascii_display_width(&vertical) < ascii_display_width(&initial) {
                return Ok(vertical);
            }
        }
    }
    Ok(initial)
}

fn render_text_with_config(
    source: &str,
    config: RenderConfig,
    primitive: &str,
    format: OutputFormat,
) -> Result<String, ElleResult> {
    render_diagram(source, format, &config)
        .map_err(|error| api().err("mmdflux-error", &format!("{primitive}: {error}")))
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
    let svg = render_diagram(source, OutputFormat::Svg, &config)
        .map_err(|error| api().err("mmdflux-error", &format!("{primitive}: {error}")))?;
    Ok(flatten_svg_markers(&svg))
}

struct MarkerDef {
    id: String,
    ref_x: f64,
    ref_y: f64,
    width: f64,
    height: f64,
    viewbox_w: f64,
    viewbox_h: f64,
    inner_content: String,
}

fn extract_attr(tag: &str, name: &str) -> Option<String> {
    let pattern = format!("{}=\"", name);
    if let Some(pos) = tag.find(&pattern) {
        let start = pos + pattern.len();
        if let Some(end) = tag[start..].find('"') {
            return Some(tag[start..start + end].to_string());
        }
    }
    None
}

fn extract_attr_f64(tag: &str, name: &str) -> Option<f64> {
    extract_attr(tag, name).and_then(|val| val.parse::<f64>().ok())
}

fn extract_url_id(url_attr: &str) -> Option<String> {
    if url_attr.starts_with("url(#") && url_attr.ends_with(')') {
        Some(url_attr["url(#".len()..url_attr.len() - 1].to_string())
    } else if url_attr.starts_with('#') {
        Some(url_attr[1..].to_string())
    } else {
        Some(url_attr.to_string())
    }
}

fn parse_coordinates(d: &str) -> Vec<f64> {
    let mut coords = Vec::new();
    let mut current = String::new();
    for c in d.chars() {
        if c.is_ascii_digit() || c == '.' || c == '-' {
            current.push(c);
        } else {
            if !current.is_empty() {
                if let Ok(val) = current.parse::<f64>() {
                    coords.push(val);
                }
                current.clear();
            }
        }
    }
    if !current.is_empty() {
        if let Ok(val) = current.parse::<f64>() {
            coords.push(val);
        }
    }
    coords
}

fn parse_markers(svg: &str) -> Vec<MarkerDef> {
    let mut markers = Vec::new();
    let mut search_pos = 0;
    while let Some(start_idx) = svg[search_pos..].find("<marker ") {
        let abs_start = search_pos + start_idx;
        if let Some(end_idx) = svg[abs_start..].find("</marker>") {
            let abs_end = abs_start + end_idx + "</marker>".len();
            let marker_tag = &svg[abs_start..abs_end];
            
            let id = extract_attr(marker_tag, "id").unwrap_or_default();
            let ref_x = extract_attr_f64(marker_tag, "refX").unwrap_or(0.0);
            let ref_y = extract_attr_f64(marker_tag, "refY").unwrap_or(0.0);
            let width = extract_attr_f64(marker_tag, "markerWidth").unwrap_or(8.0);
            let height = extract_attr_f64(marker_tag, "markerHeight").unwrap_or(8.0);
            
            let (viewbox_w, viewbox_h) = if let Some(viewbox) = extract_attr(marker_tag, "viewBox") {
                let parts: Vec<&str> = viewbox.split_whitespace().collect();
                if parts.len() == 4 {
                    (parts[2].parse::<f64>().unwrap_or(10.0), parts[3].parse::<f64>().unwrap_or(10.0))
                } else {
                    (10.0, 10.0)
                }
            } else {
                (10.0, 10.0)
            };
            
            if let Some(tag_end_relative) = svg[abs_start..].find('>') {
                let tag_end_abs = abs_start + tag_end_relative + 1;
                let marker_end_content_abs = abs_start + end_idx;
                if marker_end_content_abs > tag_end_abs {
                    let inner_content = svg[tag_end_abs..marker_end_content_abs].trim().to_string();
                    markers.push(MarkerDef {
                        id,
                        ref_x,
                        ref_y,
                        width,
                        height,
                        viewbox_w,
                        viewbox_h,
                        inner_content,
                    });
                }
            }
            search_pos = abs_end;
        } else {
            break;
        }
    }
    markers
}

fn flatten_svg_markers(svg: &str) -> String {
    let markers = parse_markers(svg);
    if markers.is_empty() {
        return svg.to_string();
    }
    
    let mut out = String::with_capacity(svg.len() * 2);
    let mut last_pos = 0;
    
    while let Some(path_start_relative) = svg[last_pos..].find("<path ") {
        let path_start_abs = last_pos + path_start_relative;
        if let Some(path_end_relative) = svg[path_start_abs..].find("/>") {
            let path_end_abs = path_start_abs + path_end_relative + "/>".len();
            let path_tag = &svg[path_start_abs..path_end_abs];
            
            out.push_str(&svg[last_pos..path_start_abs]);
            
            let marker_end_id = extract_attr(path_tag, "marker-end");
            let marker_start_id = extract_attr(path_tag, "marker-start");
            
            if marker_end_id.is_none() && marker_start_id.is_none() {
                out.push_str(path_tag);
            } else {
                let mut cleaned_path = path_tag.to_string();
                if let Some(ref me) = marker_end_id {
                    cleaned_path = cleaned_path.replace(&format!("marker-end=\"{}\"", me), "");
                }
                if let Some(ref ms) = marker_start_id {
                    cleaned_path = cleaned_path.replace(&format!("marker-start=\"{}\"", ms), "");
                }
                cleaned_path = cleaned_path.replace("  ", " ");
                out.push_str(&cleaned_path);
                
                if let Some(d_str) = extract_attr(path_tag, "d") {
                    let coords = parse_coordinates(&d_str);
                    if coords.len() >= 4 {
                        let stroke_color = extract_attr(path_tag, "stroke").unwrap_or_else(|| "#333".to_string());
                        
                        if let Some(me_attr) = marker_end_id {
                            if let Some(marker_id) = extract_url_id(&me_attr) {
                                if let Some(m) = markers.iter().find(|m| m.id == marker_id) {
                                    let len = coords.len();
                                    let p2 = (coords[len - 2], coords[len - 1]);
                                    let p1 = (coords[len - 4], coords[len - 3]);
                                    
                                    let dx = p2.0 - p1.0;
                                    let dy = p2.1 - p1.1;
                                    let dist = (dx*dx + dy*dy).sqrt();
                                    if dist > 0.001 {
                                        let angle_rad = dy.atan2(dx);
                                        let angle_deg = angle_rad.to_degrees();
                                        
                                        let scale_x = m.width / m.viewbox_w;
                                        let scale_y = m.height / m.viewbox_h;
                                        
                                        let mut inner_rendered = m.inner_content.clone();
                                        if !inner_rendered.contains("fill=") {
                                            inner_rendered = inner_rendered.replace("<path ", &format!("<path fill=\"{}\" ", stroke_color));
                                        }
                                        
                                        let inline_group = format!(
                                            "\n      <g transform=\"translate({:.3},{:.3}) rotate({:.3}) scale({:.3},{:.3})\"><g transform=\"translate({:.3},{:.3})\">{}</g></g>",
                                            p2.0, p2.1, angle_deg, scale_x, scale_y, -m.ref_x, -m.ref_y, inner_rendered
                                        );
                                        out.push_str(&inline_group);
                                    }
                                }
                            }
                        }
                        
                        if let Some(ms_attr) = marker_start_id {
                            if let Some(marker_id) = extract_url_id(&ms_attr) {
                                if let Some(m) = markers.iter().find(|m| m.id == marker_id) {
                                    let p1 = (coords[0], coords[1]);
                                    let p2 = (coords[2], coords[3]);
                                    
                                    let dx = p1.0 - p2.0;
                                    let dy = p1.1 - p2.1;
                                    let dist = (dx*dx + dy*dy).sqrt();
                                    if dist > 0.001 {
                                        let angle_rad = dy.atan2(dx);
                                        let angle_deg = angle_rad.to_degrees();
                                        
                                        let scale_x = m.width / m.viewbox_w;
                                        let scale_y = m.height / m.viewbox_h;
                                        
                                        let mut inner_rendered = m.inner_content.clone();
                                        if !inner_rendered.contains("fill=") {
                                            inner_rendered = inner_rendered.replace("<path ", &format!("<path fill=\"{}\" ", stroke_color));
                                        }
                                        
                                        let inline_group = format!(
                                            "\n      <g transform=\"translate({:.3},{:.3}) rotate({:.3}) scale({:.3},{:.3})\"><g transform=\"translate({:.3},{:.3})\">{}</g></g>",
                                            p1.0, p1.1, angle_deg, scale_x, scale_y, -m.ref_x, -m.ref_y, inner_rendered
                                        );
                                        out.push_str(&inline_group);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            last_pos = path_end_abs;
        } else {
            break;
        }
    }
    
    out.push_str(&svg[last_pos..]);
    
    let mut cleaned_out = out;
    for m in markers {
        let pattern = format!("id=\"{}\"", m.id);
        if let Some(pos) = cleaned_out.find(&pattern) {
            if let Some(start_offset) = cleaned_out[..pos].rfind("<marker") {
                if let Some(end_offset) = cleaned_out[pos..].find("</marker>") {
                    let abs_end = pos + end_offset + "</marker>".len();
                    cleaned_out.replace_range(start_offset..abs_end, "");
                }
            }
        }
    }
    
    cleaned_out
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
        2,
        "Render a Mermaid diagram to SVG with options.",
        "mmdflux",
        r#"(mmdflux/render-svg "flowchart LR; A-->B-->C" {:layout-engine "mermaid-layered"})"#,
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
        let fitted = assert_rendered(render_text_fit(WIDE_FLOWCHART, config, Some(80), OutputFormat::Ascii));

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

    #[test]
    fn verify_marker_flattening() {
        let config = RenderConfig::default();
        // Generate SVG via render_svg_with_config (which automatically calls flatten_svg_markers)
        let svg = match render_svg_with_config(
            "flowchart LR\n  A[Collect] -->|some label| B[Render]",
            config,
            "test"
        ) {
            Ok(svg) => svg,
            Err(_) => panic!("Failed to render SVG"),
        };

        // 1. Defs should not contain a <marker> tag anymore
        assert!(!svg.contains("<marker"), "SVG still contains <marker> tags!");
        assert!(!svg.contains("</marker>"), "SVG still contains </marker> tags!");

        // 2. The path tag should not contain marker-end anymore
        assert!(!svg.contains("marker-end="), "SVG path still contains marker-end!");

        // 3. Instead, it should contain a transform tag representing the inlined arrowhead
        assert!(svg.contains("transform=\"translate("), "SVG does not contain translate transform!");
        assert!(svg.contains("rotate("), "SVG does not contain rotate transform!");
    }

    #[test]
    fn verify_unicode_and_ansi_fit() {
        let mut config_ascii = RenderConfig::default();
        config_ascii.text_color_mode = TextColorMode::Plain;
        let ascii = match render_text_fit(
            "flowchart LR\n  A[Collect] --> B[Render]",
            config_ascii,
            None,
            OutputFormat::Ascii,
        ) {
            Ok(s) => s,
            Err(_) => panic!("render failed"),
        };

        let mut config_unicode = RenderConfig::default();
        config_unicode.text_color_mode = TextColorMode::Plain;
        let unicode = match render_text_fit(
            "flowchart LR\n  A[Collect] --> B[Render]",
            config_unicode,
            None,
            OutputFormat::Text,
        ) {
            Ok(s) => s,
            Err(_) => panic!("render failed"),
        };

        // 1. ASCII output should contain '+', '-', '|' characters
        assert!(ascii.contains('+'), "ASCII output should contain '+' corners!");
        
        // 2. Unicode output should contain Unicode box-drawing characters
        assert!(unicode.contains('┌') || unicode.contains('─'), "Unicode output should contain box-drawing characters!");
        assert!(!unicode.contains('+'), "Unicode output should not contain '+' corners!");
    }
}

