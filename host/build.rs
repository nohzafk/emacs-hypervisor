use std::env;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
struct RuntimeModule {
    const_name: String,
    path: String,
    ready_marker: String,
}

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

fn is_epoch_declaration(line: &str) -> bool {
    line.trim_start().starts_with("(elle/epoch ")
}

fn expand_source(path: &Path, stack: &mut Vec<PathBuf>, root: bool) -> Result<String, String> {
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
            expanded.push_str(&expand_source(&include_path, stack, false)?);
            if !expanded.ends_with('\n') {
                expanded.push('\n');
            }
        } else if !root && is_epoch_declaration(line) {
            continue;
        } else {
            expanded.push_str(line);
            expanded.push('\n');
        }
    }

    stack.pop();
    Ok(expanded)
}

fn runtime_modules_manifest_path(repo_dir: &Path) -> PathBuf {
    repo_dir.join("elle/runtime-forms/modules.manifest")
}

fn parse_runtime_module_manifest(repo_dir: &Path) -> Result<Vec<RuntimeModule>, String> {
    let manifest_path = runtime_modules_manifest_path(repo_dir);
    let source = fs::read_to_string(&manifest_path)
        .map_err(|error| format!("failed to read {}: {}", manifest_path.display(), error))?;
    let mut modules = Vec::new();

    for (index, line) in source.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let fields = trimmed.split('|').collect::<Vec<_>>();
        if fields.len() != 3 {
            return Err(format!(
                "{}:{}: expected CONST|PATH|READY_MARKER",
                manifest_path.display(),
                index + 1
            ));
        }

        modules.push(RuntimeModule {
            const_name: fields[0].to_string(),
            path: fields[1].to_string(),
            ready_marker: fields[2].to_string(),
        });
    }

    Ok(modules)
}

fn runtime_module_env_name(const_name: &str) -> String {
    format!("EMACS_HYPERVISOR_EMBEDDED_{}_SOURCE", const_name)
}

fn runtime_module_manifest_source(modules: &[RuntimeModule]) -> String {
    let mut output = String::from("(");
    for module in modules {
        output.push_str("\n (");
        output.push_str(":name ");
        output.push_str(&format!("{:?}", module.const_name));
        output.push_str(" :env-name ");
        output.push_str(&format!("{:?}", runtime_module_env_name(&module.const_name)));
        output.push_str(" :path ");
        output.push_str(&format!("{:?}", module.path));
        output.push_str(" :ready-marker ");
        output.push_str(&module.ready_marker);
        output.push(')');
    }
    output.push_str("\n)");
    output
}

fn main() {
    let repo_dir = repo_root();
    let backend_path = repo_dir.join("elle").join("hypervisor.lisp");
    let expanded_backend =
        expand_source(&backend_path, &mut Vec::new(), true)
            .expect("backend expansion should succeed");
    let runtime_modules =
        parse_runtime_module_manifest(&repo_dir).expect("runtime module manifest should parse");

    println!("cargo:rerun-if-changed={}", backend_path.display());
    println!(
        "cargo:rerun-if-changed={}",
        runtime_modules_manifest_path(&repo_dir).display()
    );
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

    let mut elisp_output = String::new();
    let mut module_map_output = String::new();
    module_map_output.push_str(&format!(
        "pub const EMBEDDED_ELISP_MODULE_MANIFEST: &str = {:?};\n\n",
        runtime_module_manifest_source(&runtime_modules)
    ));
    module_map_output.push_str(
        "pub struct EmbeddedRuntimeModule {\n    pub env_name: &'static str,\n    pub embedded_source: &'static str,\n}\n\n",
    );
    module_map_output.push_str("pub const EMBEDDED_ELISP_MODULES: &[EmbeddedRuntimeModule] = &[\n");

    for module in &runtime_modules {
        let rel_path = &module.path;
        let path = repo_dir.join(rel_path);
        let source = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("failed to read {}: {}", rel_path, error));
        elisp_output.push_str(&format!(
            "pub const EMBEDDED_{}_SOURCE: &str = {:?};\n",
            module.const_name, source
        ));
        module_map_output.push_str(&format!(
            "    EmbeddedRuntimeModule {{ env_name: {:?}, embedded_source: EMBEDDED_{}_SOURCE }},\n",
            runtime_module_env_name(&module.const_name),
            module.const_name
        ));
    }
    module_map_output.push_str("];\n");
    elisp_output.push('\n');
    elisp_output.push_str(&module_map_output);

    fs::write(out_dir.join("embedded_elisp.rs"), elisp_output)
        .expect("should write embedded elisp");
}
