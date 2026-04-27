use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use elisp_pack::pack_file;

fn repo_root() -> PathBuf {
    PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR should be set"))
        .join("..")
}

fn parse_include_file(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    trimmed
        .strip_prefix("(include-file \"")
        .and_then(|rest| rest.strip_suffix("\")"))
}

fn expand_source(path: &Path, stack: &mut Vec<PathBuf>) -> Result<String, String> {
    if stack.iter().any(|entry| entry == path) {
        let cycle = stack
            .iter()
            .chain(std::iter::once(&path.to_path_buf()))
            .map(|entry| entry.display().to_string())
            .collect::<Vec<_>>()
            .join(" -> ");
        return Err(format!("circular include-file dependency: {}", cycle));
    }

    stack.push(path.to_path_buf());
    let source = fs::read_to_string(path)
        .map_err(|error| format!("failed to read {}: {}", path.display(), error))?;
    let mut expanded = String::new();

    for line in source.lines() {
        if let Some(spec) = parse_include_file(line) {
            let include_path = path
                .parent()
                .expect("source file should have a parent directory")
                .join(spec);
            expanded.push_str(&expand_source(&include_path, stack)?);
            if !expanded.ends_with('\n') {
                expanded.push('\n');
            }
        } else {
            expanded.push_str(line);
            expanded.push('\n');
        }
    }

    stack.pop();
    Ok(expanded)
}

fn main() {
    let repo_dir = repo_root();
    let backend_path = repo_dir.join("elle").join("hypervisor.lisp");
    let expanded_backend =
        expand_source(&backend_path, &mut Vec::new()).expect("backend expansion should succeed");

    println!("cargo:rerun-if-changed={}", backend_path.display());
    println!("cargo:rerun-if-changed={}", repo_dir.join("elle").display());
    println!(
        "cargo:rerun-if-changed={}",
        repo_dir.join("elle/runtime-forms").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_dir.join("host/emacs-kernel").display()
    );

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR should be set"));
    let output_path = out_dir.join("embedded_backend.rs");
    fs::write(
        &output_path,
        format!(
            "pub const EMBEDDED_BACKEND_SOURCE: &str = {:?};\n",
            expanded_backend
        ),
    )
    .expect("should write embedded backend source");

    let mut packed_output = String::new();
    for (const_name, rel_path) in PACKED_RUNTIME_FORMS {
        let path = repo_dir.join(rel_path);
        let packed = pack_file(&path)
            .unwrap_or_else(|error| panic!("failed to pack {}: {}", rel_path, error));
        packed_output.push_str(&format!(
            "pub const EMBEDDED_{}_FORMS: &str = {:?};\n",
            const_name, packed.forms_source
        ));
    }
    fs::write(out_dir.join("embedded_elisp.rs"), packed_output)
        .expect("should write embedded packed elisp");
}

const PACKED_RUNTIME_FORMS: &[(&str, &str)] = &[
    (
        "REPORT_CORE",
        "elle/runtime-forms/emacs-hypervisor-report-core.el",
    ),
    ("REPORT", "elle/runtime-forms/emacs-hypervisor-report.el"),
    (
        "DECLARATIONS",
        "elle/runtime-forms/emacs-hypervisor-declarations.el",
    ),
    (
        "EFFECT_REGISTRY",
        "elle/runtime-forms/emacs-hypervisor-effect-registry.el",
    ),
    (
        "EFFECT_AWARE_RELOAD",
        "elle/runtime-forms/emacs-hypervisor-effect-aware-reload.el",
    ),
    (
        "EFFECT_KIND_HOOK",
        "elle/runtime-forms/emacs-hypervisor-effect-kind-hook.el",
    ),
    (
        "EFFECT_KIND_ADVICE",
        "elle/runtime-forms/emacs-hypervisor-effect-kind-advice.el",
    ),
    (
        "SELECTIVE_RELOAD",
        "elle/runtime-forms/emacs-hypervisor-selective-reload.el",
    ),
    ("COMPOSE", "elle/runtime-forms/emacs-hypervisor-compose.el"),
    (
        "SESSION_BASE",
        "elle/runtime-forms/emacs-hypervisor-session-base.el",
    ),
    (
        "ELPACA_BRIDGE",
        "elle/runtime-forms/emacs-hypervisor-elpaca-bridge.el",
    ),
    (
        "PACKAGE_RUNTIME",
        "elle/runtime-forms/emacs-hypervisor-package-runtime.el",
    ),
    (
        "UNIT_RUNTIME",
        "elle/runtime-forms/emacs-hypervisor-unit-runtime.el",
    ),
];
