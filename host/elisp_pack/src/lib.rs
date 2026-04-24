use std::fs;
use std::path::Path;

use tree_sitter::{Node, Parser};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackedModule {
    pub forms_source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Expr {
    Atom(String),
    Raw(String),
    List(Vec<Expr>),
    Vector(Vec<Expr>),
    Bytecode(Vec<Expr>),
    StringTextProperties { string: Box<Expr>, properties: Vec<Expr> },
    HashTable(Vec<Expr>),
    Quote(Box<Expr>),
    Function(Box<Expr>),
    Quasiquote(Box<Expr>),
    Unquote(Box<Expr>),
    UnquoteSplicing(Box<Expr>),
}

impl Expr {
    fn atom(text: impl Into<String>) -> Self {
        Expr::Atom(text.into())
    }
}

pub fn pack_file(path: &Path) -> Result<PackedModule, String> {
    let source = fs::read_to_string(path)
        .map_err(|error| format!("failed to read {}: {}", path.display(), error))?;
    pack_source(&source, &path.display().to_string())
}

pub fn pack_source(source: &str, path: &str) -> Result<PackedModule, String> {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_elisp::LANGUAGE.into())
        .map_err(|error| format!("{}: failed to load tree-sitter elisp grammar: {}", path, error))?;
    let tree = parser
        .parse(source, None)
        .ok_or_else(|| format!("{}: tree-sitter failed to parse source", path))?;
    let root = tree.root_node();
    if root.has_error() {
        return Err(format_parse_error(path, source, root));
    }

    let mut forms = Vec::new();
    let mut cursor = root.walk();
    for child in root.named_children(&mut cursor) {
        if child.kind() == "comment" {
            continue;
        }
        forms.push(expr_from_node(child, source, path)?);
    }

    let forms = forms
        .into_iter()
        .map(rewrite_elle_incompatible)
        .collect::<Result<Vec<_>, _>>()?;

    let forms_source = forms
        .iter()
        .map(render_expr)
        .collect::<Result<Vec<_>, _>>()?
        .join("\n");
    Ok(PackedModule { forms_source })
}

/// Rewrite Emacs Lisp constructs that elle's reader cannot tokenize. Elle treats
/// digit-prefix tokens like `1+` as `1` followed by `+`, so we rewrite
/// `(1+ x)` into `(+ x 1)` and `(1- x)` into `(- x 1)` at pack time. Any bare
/// appearance of `1+`/`1-` outside of call position is rejected so we notice
/// when a new pattern sneaks in.
fn rewrite_elle_incompatible(expr: Expr) -> Result<Expr, String> {
    match expr {
        Expr::List(mut items) => {
            let head = items.first().and_then(|expr| {
                digit_prefix_op(expr).map(|op| (op, digit_prefix_text(expr).to_string()))
            });
            if let Some((op, label)) = head {
                let rest = items.split_off(1);
                if rest.len() != 1 {
                    return Err(format!(
                        "expected exactly one argument for `{}`, got {}",
                        label,
                        rest.len()
                    ));
                }
                let args = rest
                    .into_iter()
                    .map(rewrite_elle_incompatible)
                    .collect::<Result<Vec<_>, _>>()?;
                let mut rewrite = Vec::with_capacity(3);
                rewrite.push(Expr::Raw(op.to_string()));
                rewrite.extend(args);
                rewrite.push(Expr::Raw("1".to_string()));
                return Ok(Expr::List(rewrite));
            }
            let rewritten = items
                .into_iter()
                .map(rewrite_elle_incompatible)
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Expr::List(rewritten))
        }
        Expr::Vector(items) => Ok(Expr::Vector(
            items
                .into_iter()
                .map(rewrite_elle_incompatible)
                .collect::<Result<Vec<_>, _>>()?,
        )),
        Expr::Bytecode(items) => Ok(Expr::Bytecode(
            items
                .into_iter()
                .map(rewrite_elle_incompatible)
                .collect::<Result<Vec<_>, _>>()?,
        )),
        Expr::HashTable(items) => Ok(Expr::HashTable(
            items
                .into_iter()
                .map(rewrite_elle_incompatible)
                .collect::<Result<Vec<_>, _>>()?,
        )),
        Expr::StringTextProperties { string, properties } => Ok(Expr::StringTextProperties {
            string: Box::new(rewrite_elle_incompatible(*string)?),
            properties: properties
                .into_iter()
                .map(rewrite_elle_incompatible)
                .collect::<Result<Vec<_>, _>>()?,
        }),
        Expr::Quote(inner) => {
            guard_digit_prefix(&inner, "quote")?;
            Ok(Expr::Quote(Box::new(rewrite_elle_incompatible(*inner)?)))
        }
        Expr::Function(inner) => {
            guard_digit_prefix(&inner, "function")?;
            Ok(Expr::Function(Box::new(rewrite_elle_incompatible(*inner)?)))
        }
        Expr::Quasiquote(inner) => Ok(Expr::Quasiquote(Box::new(rewrite_elle_incompatible(
            *inner,
        )?))),
        Expr::Unquote(inner) => Ok(Expr::Unquote(Box::new(rewrite_elle_incompatible(*inner)?))),
        Expr::UnquoteSplicing(inner) => Ok(Expr::UnquoteSplicing(Box::new(
            rewrite_elle_incompatible(*inner)?,
        ))),
        expr @ (Expr::Atom(_) | Expr::Raw(_)) => {
            if let Some(text) = digit_prefix_text_owned(&expr) {
                return Err(format!(
                    "bare `{}` outside call position is not supported by elisp_pack",
                    text
                ));
            }
            Ok(expr)
        }
    }
}

fn digit_prefix_op(expr: &Expr) -> Option<&'static str> {
    match digit_prefix_text(expr) {
        "1+" => Some("+"),
        "1-" => Some("-"),
        _ => None,
    }
}

fn digit_prefix_text(expr: &Expr) -> &str {
    match expr {
        Expr::Atom(text) | Expr::Raw(text) => text.as_str(),
        _ => "",
    }
}

fn digit_prefix_text_owned(expr: &Expr) -> Option<&str> {
    let text = digit_prefix_text(expr);
    if matches!(text, "1+" | "1-") {
        Some(text)
    } else {
        None
    }
}

fn guard_digit_prefix(inner: &Expr, context: &str) -> Result<(), String> {
    if let Some(text) = digit_prefix_text_owned(inner) {
        return Err(format!(
            "`{}` inside `{}` is not supported by elisp_pack",
            text, context
        ));
    }
    Ok(())
}

fn expr_from_node(node: Node<'_>, source: &str, path: &str) -> Result<Expr, String> {
    match node.kind() {
        "source_file" => Err(node_error(path, source, node, "unexpected source_file node")),
        "symbol" | "integer" | "float" | "char" | "string" | "byte_compiled_file_name" => {
            Ok(Expr::Raw(node_text(node, source, path)?))
        }
        "list" | "special_form" | "function_definition" | "macro_definition" => {
            Ok(Expr::List(compound_items(node, source, path)?))
        }
        "vector" => Ok(Expr::Vector(compound_items(node, source, path)?)),
        "bytecode" => Ok(Expr::Bytecode(compound_items(node, source, path)?)),
        "hash_table" => Ok(Expr::HashTable(compound_items(node, source, path)?)),
        "string_text_properties" => {
            let parts = compound_items(node, source, path)?;
            let (first, rest) = parts
                .split_first()
                .ok_or_else(|| node_error(path, source, node, "string_text_properties missing string"))?;
            Ok(Expr::StringTextProperties {
                string: Box::new(first.clone()),
                properties: rest.to_vec(),
            })
        }
        "quote" => {
            let prefix = first_non_extra_text(node, source, path)?;
            let inner = only_named_child_expr(node, source, path)?;
            match prefix.as_str() {
                "'" => Ok(Expr::Quote(Box::new(inner))),
                "#'" => Ok(Expr::Function(Box::new(inner))),
                "`" => Ok(Expr::Quasiquote(Box::new(inner))),
                _ => Err(node_error(
                    path,
                    source,
                    node,
                    &format!("unsupported quote prefix {:?}", prefix),
                )),
            }
        }
        "unquote" => Ok(Expr::Unquote(Box::new(only_named_child_expr(node, source, path)?))),
        "unquote_splice" => Ok(Expr::UnquoteSplicing(Box::new(only_named_child_expr(
            node, source, path,
        )?))),
        other => Err(node_error(
            path,
            source,
            node,
            &format!("unsupported tree-sitter node kind {:?}", other),
        )),
    }
}

fn compound_items(node: Node<'_>, source: &str, path: &str) -> Result<Vec<Expr>, String> {
    let mut items = Vec::new();
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if child.is_extra() {
            continue;
        }
        if child.is_named() {
            if child.kind() == "comment" {
                continue;
            }
            items.push(expr_from_node(child, source, path)?);
            continue;
        }
        let token = node_text(child, source, path)?;
        match token.as_str() {
            "(" | ")" | "[" | "]" | "#[" | "#(" | "#s(hash-table" => {}
            _ => items.push(Expr::Raw(token)),
        }
    }
    Ok(items)
}

fn only_named_child_expr(node: Node<'_>, source: &str, path: &str) -> Result<Expr, String> {
    let mut cursor = node.walk();
    let mut children = node.named_children(&mut cursor).filter(|child| child.kind() != "comment");
    let child = children
        .next()
        .ok_or_else(|| node_error(path, source, node, "missing child expression"))?;
    if children.next().is_some() {
        return Err(node_error(path, source, node, "expected exactly one child expression"));
    }
    expr_from_node(child, source, path)
}

fn first_non_extra_text(node: Node<'_>, source: &str, path: &str) -> Result<String, String> {
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if child.is_extra() {
            continue;
        }
        return node_text(child, source, path);
    }
    Err(node_error(path, source, node, "missing prefix token"))
}

fn node_text(node: Node<'_>, source: &str, path: &str) -> Result<String, String> {
    node.utf8_text(source.as_bytes())
        .map(|text| text.to_string())
        .map_err(|error| {
            format!(
                "{}:{}:{}: failed to read node text: {}",
                path,
                node.start_position().row + 1,
                node.start_position().column + 1,
                error
            )
        })
}

fn node_error(path: &str, source: &str, node: Node<'_>, message: &str) -> String {
    format!(
        "{}:{}:{}: {} near {:?}",
        path,
        node.start_position().row + 1,
        node.start_position().column + 1,
        message,
        node.utf8_text(source.as_bytes()).unwrap_or("<invalid utf8>")
    )
}

fn format_parse_error(path: &str, source: &str, root: Node<'_>) -> String {
    if let Some(node) = first_error_node(root) {
        let position = node.start_position();
        return format!(
            "{}:{}:{}: tree-sitter parse error near {:?}",
            path,
            position.row + 1,
            position.column + 1,
            node.utf8_text(source.as_bytes()).unwrap_or("<invalid utf8>")
        );
    }
    format!("{}: tree-sitter parse error", path)
}

fn first_error_node(node: Node<'_>) -> Option<Node<'_>> {
    if node.is_error() || node.is_missing() {
        return Some(node);
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if let Some(found) = first_error_node(child) {
            return Some(found);
        }
    }
    None
}

fn render_expr(expr: &Expr) -> Result<String, String> {
    match expr {
        Expr::Atom(text) | Expr::Raw(text) => Ok(text.clone()),
        Expr::List(items) => {
            let rendered = items
                .iter()
                .map(render_expr)
                .collect::<Result<Vec<_>, _>>()?
                .join(" ");
            Ok(format!("({})", rendered))
        }
        Expr::Vector(items) => {
            let rendered = items
                .iter()
                .map(render_expr)
                .collect::<Result<Vec<_>, _>>()?
                .join(" ");
            Ok(format!("[{}]", rendered))
        }
        Expr::Bytecode(items) => {
            let rendered = items
                .iter()
                .map(render_expr)
                .collect::<Result<Vec<_>, _>>()?
                .join(" ");
            Ok(format!("#[{}]", rendered))
        }
        Expr::StringTextProperties { string, properties } => {
            let mut parts = Vec::with_capacity(properties.len() + 1);
            parts.push(render_expr(string)?);
            parts.extend(
                properties
                    .iter()
                    .map(render_expr)
                    .collect::<Result<Vec<_>, _>>()?,
            );
            Ok(format!("#({})", parts.join(" ")))
        }
        Expr::HashTable(items) => {
            let rendered = items
                .iter()
                .map(render_expr)
                .collect::<Result<Vec<_>, _>>()?
                .join(" ");
            if rendered.is_empty() {
                Ok("#s(hash-table)".to_string())
            } else {
                Ok(format!("#s(hash-table {})", rendered))
            }
        }
        Expr::Quote(inner) => Ok(format!("(quote {})", render_expr(inner)?)),
        Expr::Function(inner) => Ok(format!("(function {})", render_expr(inner)?)),
        Expr::Quasiquote(inner) => render_expr(&lower_quasiquote(inner)?),
        Expr::Unquote(_) => Err("unquote outside quasiquote is not supported".to_string()),
        Expr::UnquoteSplicing(_) => {
            Err("unquote-splicing outside quasiquote is not supported".to_string())
        }
    }
}

fn lower_quasiquote(expr: &Expr) -> Result<Expr, String> {
    match expr {
        Expr::Unquote(inner) => Ok(canonicalize(inner)?),
        Expr::UnquoteSplicing(_) => Err("unquote-splicing requires list context".to_string()),
        Expr::Quote(inner) => Ok(Expr::List(vec![
            Expr::atom("list"),
            Expr::List(vec![Expr::atom("quote"), Expr::atom("quote")]),
            lower_quasiquote(inner)?,
        ])),
        Expr::Function(inner) => Ok(Expr::List(vec![
            Expr::atom("list"),
            Expr::List(vec![Expr::atom("quote"), Expr::atom("function")]),
            lower_quasiquote(inner)?,
        ])),
        Expr::List(items) => lower_quasiquote_list(items),
        Expr::Quasiquote(_) => Err("nested quasiquote is not supported by elisp_pack yet".to_string()),
        _ => Ok(Expr::List(vec![Expr::atom("quote"), canonicalize(expr)?])),
    }
}

fn lower_quasiquote_list(items: &[Expr]) -> Result<Expr, String> {
    let mut pieces = Vec::new();
    for item in items {
        match item {
            Expr::UnquoteSplicing(inner) => pieces.push(canonicalize(inner)?),
            _ => pieces.push(Expr::List(vec![Expr::atom("list"), lower_quasiquote(item)?])),
        }
    }

    if pieces.is_empty() {
        return Ok(Expr::List(vec![
            Expr::atom("quote"),
            Expr::List(Vec::new()),
        ]));
    }

    if pieces.len() == 1 {
        return Ok(pieces.remove(0));
    }

    let mut forms = Vec::with_capacity(pieces.len() + 1);
    forms.push(Expr::atom("append"));
    forms.extend(pieces);
    Ok(Expr::List(forms))
}

fn canonicalize(expr: &Expr) -> Result<Expr, String> {
    match expr {
        Expr::Atom(text) => Ok(Expr::Atom(text.clone())),
        Expr::Raw(text) => Ok(Expr::Raw(text.clone())),
        Expr::List(items) => Ok(Expr::List(
            items.iter().map(canonicalize).collect::<Result<Vec<_>, _>>()?,
        )),
        Expr::Vector(items) => Ok(Expr::Vector(
            items.iter().map(canonicalize).collect::<Result<Vec<_>, _>>()?,
        )),
        Expr::Bytecode(items) => Ok(Expr::Bytecode(
            items.iter().map(canonicalize).collect::<Result<Vec<_>, _>>()?,
        )),
        Expr::StringTextProperties { string, properties } => Ok(Expr::StringTextProperties {
            string: Box::new(canonicalize(string)?),
            properties: properties
                .iter()
                .map(canonicalize)
                .collect::<Result<Vec<_>, _>>()?,
        }),
        Expr::HashTable(items) => Ok(Expr::HashTable(
            items.iter().map(canonicalize).collect::<Result<Vec<_>, _>>()?,
        )),
        Expr::Quote(inner) => Ok(Expr::List(vec![Expr::atom("quote"), canonicalize(inner)?])),
        Expr::Function(inner) => Ok(Expr::List(vec![
            Expr::atom("function"),
            canonicalize(inner)?,
        ])),
        Expr::Quasiquote(inner) => lower_quasiquote(inner),
        Expr::Unquote(_) => Err("unquote outside quasiquote is not supported".to_string()),
        Expr::UnquoteSplicing(_) => {
            Err("unquote-splicing outside quasiquote is not supported".to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{pack_file, pack_source};
    use std::path::PathBuf;

    #[test]
    fn packs_function_quote_and_comments() {
        let packed = pack_source(";;; test\n(defun demo () #'identity)\n", "<test>")
            .expect("pack should succeed");
        assert_eq!(packed.forms_source, "(defun demo () (function identity))");
    }

    #[test]
    fn lowers_simple_quasiquote() {
        let packed = pack_source("(defmacro demo (x xs) `(list ,x ,@xs))\n", "<test>")
            .expect("pack should succeed");
        assert_eq!(
            packed.forms_source,
            "(defmacro demo (x xs) (append (list (quote list)) (list x) xs))"
        );
    }

    #[test]
    fn preserves_vectors() {
        let packed = pack_source("[foo 1 'bar]", "<test>")
            .expect("pack should succeed");
        assert_eq!(packed.forms_source, "[foo 1 (quote bar)]");
    }

    #[test]
    fn rewrites_digit_prefix_ops() {
        let packed = pack_source("(seq-subseq args (1+ i)) (max 0 (1- n))", "<test>")
            .expect("pack should succeed");
        assert_eq!(
            packed.forms_source,
            "(seq-subseq args (+ i 1))\n(max 0 (- n 1))"
        );
    }

    #[test]
    fn rejects_bare_digit_prefix_symbol() {
        let error = pack_source("(mapcar #'1+ xs)", "<test>")
            .expect_err("bare #'1+ should error");
        assert!(error.contains("1+"));
    }

    #[test]
    fn packs_current_static_modules() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let files = [
            "elle/runtime-forms/emacs-hypervisor-report-core.el",
            "elle/runtime-forms/emacs-hypervisor-report.el",
            "elle/runtime-forms/emacs-hypervisor-declarations.el",
            "elle/runtime-forms/emacs-hypervisor-compose.el",
            "elle/runtime-forms/emacs-hypervisor-session-base.el",
            "elle/runtime-forms/emacs-hypervisor-elpaca-bridge.el",
            "elle/runtime-forms/emacs-hypervisor-package-runtime.el",
            "elle/runtime-forms/emacs-hypervisor-unit-runtime.el",
        ];

        for file in files {
            pack_file(&repo_root.join(file)).unwrap_or_else(|error| panic!("{}", error));
        }
    }
}
