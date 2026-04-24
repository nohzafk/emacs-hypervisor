use std::env;
use std::fs;
use std::path::{Path, PathBuf};

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
        repo_dir.join("elle/source-elisp").display()
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
}
