mod embedded {
    include!(concat!(env!("OUT_DIR"), "/embedded_backend.rs"));
    include!(concat!(env!("OUT_DIR"), "/embedded_elisp.rs"));
    include!(concat!(env!("OUT_DIR"), "/embedded_plugins.rs"));

    pub const EMBEDDED_BOOTSTRAP_ELISP: &str =
        include_str!("../emacs-kernel/emacs-hypervisor-bootstrap.el");
    pub const EMBEDDED_SEXP_RPC_ELISP: &str =
        include_str!("../emacs-kernel/emacs-hypervisor-sexp-rpc.el");
    pub const EMBEDDED_EVENTS_ELISP: &str =
        include_str!("../emacs-kernel/emacs-hypervisor-events.el");
    pub const EMBEDDED_SESSION_STATE_ELISP: &str =
        include_str!("../emacs-kernel/emacs-hypervisor-session-state.el");
    pub const EMBEDDED_EARLY_INIT_ELISP: &str = include_str!("../emacs-kernel/early-init.el");
}

mod hash;

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;

use clap::{Args, Parser, Subcommand};
use elle::config::Config;
use elle::pipeline::compile_file;
use elle::runtime::Runtime;
use elle::SymbolTable;

const HOME_STARTUP_ELISP: &str = include_str!("../emacs-kernel/home-startup.el");
const HOME_EARLY_INIT_ELISP: &str = embedded::EMBEDDED_EARLY_INIT_ELISP;
const ELLE_PLUGIN_CACHE_ENV: &str = "EMACS_HYPERVISOR_ELLE_PLUGIN_CACHE_DIR";
const ELLE_HOME_ENV: &str = "EMACS_HYPERVISOR_ELLE_HOME";

const HOME_ARG_HELP: &str =
    "Emacs home directory (default: ~/.config/emacs or XDG_CONFIG_HOME/emacs)";
const HOME_DEFAULT_AFTER_HELP: &str = "Default `--home`:
- `$XDG_CONFIG_HOME/emacs` when `XDG_CONFIG_HOME` is set
- otherwise `$HOME/.config/emacs`";

#[derive(Parser, Debug)]
#[command(name = "emacs-hypervisor")]
#[command(about = "Elle-native Emacs Hypervisor host")]
#[command(version)]
#[command(override_usage = "emacs-hypervisor
       emacs-hypervisor serve
       emacs-hypervisor init [--home DIR] [--upgrade]
       emacs-hypervisor env [--home DIR] [-o FILE]
       emacs-hypervisor check [--home DIR] [--emacs PATH] [--format human|sexp] [--strict]")]
#[command(
    after_help = "When no subcommand is given, `emacs-hypervisor` defaults to `serve`.

Default Emacs home for `init` and `env`:
- `$XDG_CONFIG_HOME/emacs` when `XDG_CONFIG_HOME` is set
- otherwise `$HOME/.config/emacs`

Default Hypervisor config directory:
- `$XDG_CONFIG_HOME/emacs-hypervisor` when `XDG_CONFIG_HOME` is set
- otherwise `$HOME/.config/emacs-hypervisor`"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Start the stdio Hypervisor backend
    Serve,
    /// Write the bundled Emacs bootstrap into an Emacs home
    Init(InitArgs),
    /// Write an env snapshot Lisp file for the Emacs home
    Env(EnvArgs),
    /// Validate the config structurally without executing it
    Check(CheckArgs),
    /// Print the generated init.el bootstrap content hash
    #[command(name = "bootstrap-hash", hide = true)]
    BootstrapHash,
}

#[derive(Args, Debug)]
#[command(after_help = "Runs a plan-only Hypervisor session in batch Emacs: the config is
tangled and loaded, the dependency graph is built, and preflight,
planning, and structural lint findings are reported -- but no package
is installed and no config-unit body is executed.

Exit codes:
  0  no findings (lint warnings allowed unless --strict)
  1  invalid or failed planned items, or any finding under --strict
  2  harness error (Emacs missing, home not initialized, no shutdown)")]
struct CheckArgs {
    #[arg(long, value_name = "DIR", help = HOME_ARG_HELP)]
    home: Option<PathBuf>,

    #[arg(long, value_name = "PATH", help = "Emacs executable (default: emacs on PATH)")]
    emacs: Option<PathBuf>,

    #[arg(
        long,
        value_name = "FORMAT",
        default_value = "human",
        help = "Verdict format: human or sexp"
    )]
    format: String,

    #[arg(long, help = "Treat lint warnings as failures")]
    strict: bool,
}

fn run_check(args: CheckArgs) -> Result<i32, String> {
    let home = match args.home {
        Some(home) => home,
        None => default_config_root()?,
    };
    let init_file = home.join("init.el");
    if !init_file.is_file() {
        return Err(format!(
            "no init.el in {}; run `emacs-hypervisor init --home {}` first",
            home.display(),
            home.display()
        ));
    }
    if !matches!(args.format.as_str(), "human" | "sexp") {
        return Err(format!("unsupported --format: {}", args.format));
    }
    let emacs_bin = args.emacs.unwrap_or_else(|| PathBuf::from("emacs"));
    let current_exe = env::current_exe()
        .map_err(|error| format!("could not resolve current executable: {}", error))?;
    let status = process::Command::new(&emacs_bin)
        .arg("--batch")
        .arg("--load")
        .arg(&init_file)
        .env("EMACS_HYPERVISOR_CHECK", "1")
        .env("EMACS_HYPERVISOR_CHECK_FORMAT", &args.format)
        .env(
            "EMACS_HYPERVISOR_CHECK_STRICT",
            if args.strict { "1" } else { "0" },
        )
        .env("EMACS_HYPERVISOR_BIN", &current_exe)
        .status()
        .map_err(|error| format!("failed to launch {}: {}", emacs_bin.display(), error))?;
    Ok(status.code().unwrap_or(2))
}

#[derive(Args, Debug)]
#[command(after_help = HOME_DEFAULT_AFTER_HELP)]
struct InitArgs {
    #[arg(long, value_name = "DIR", help = HOME_ARG_HELP)]
    home: Option<PathBuf>,

    #[arg(
        long,
        help = "Rewrite generated bootstrap files in an existing Emacs Hypervisor home"
    )]
    upgrade: bool,
}

#[derive(Args, Debug)]
#[command(after_help = HOME_DEFAULT_AFTER_HELP)]
struct EnvArgs {
    #[arg(long, value_name = "DIR", help = HOME_ARG_HELP)]
    home: Option<PathBuf>,

    #[arg(
        short = 'o',
        long = "output",
        value_name = "FILE",
        help = "Write the env snapshot to FILE instead of HOME/env"
    )]
    output: Option<PathBuf>,

    #[arg(
        long = "include",
        value_name = "NAME",
        help = "Include an env var that the secret-name filter would skip (repeatable)"
    )]
    include: Vec<String>,
}

fn default_config_root() -> Result<PathBuf, String> {
    if let Some(xdg_config_home) = xdg_config_home() {
        return Ok(xdg_config_home.join("emacs"));
    }
    let home = env::var_os("HOME")
        .ok_or_else(|| "could not detect HOME for default Emacs home".to_string())?;
    Ok(PathBuf::from(home).join(".config").join("emacs"))
}

fn default_hypervisor_config_root() -> Result<PathBuf, String> {
    if let Some(xdg_config_home) = xdg_config_home() {
        return Ok(xdg_config_home.join("emacs-hypervisor"));
    }
    let home = env::var_os("HOME").ok_or_else(|| {
        "could not detect HOME for default Hypervisor config directory".to_string()
    })?;
    Ok(PathBuf::from(home).join(".config").join("emacs-hypervisor"))
}

fn xdg_config_home() -> Option<PathBuf> {
    env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.as_os_str().is_empty())
        .map(PathBuf::from)
}

/// The repository root captured at compile time.  Only meaningful on the
/// build machine; never assume it exists at runtime.  (Distinct from the
/// `repo_root()` helper in build.rs, which runs during the build.)
fn build_time_repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// Resolve the Elle home (module resolution root) at runtime.
///
/// Order: explicit Elle config (`ELLE_HOME`, handled by `Config::default`),
/// then `EMACS_HYPERVISOR_ELLE_HOME`, then the compile-time repo checkout
/// when it still exists.  A copied/installed binary on another machine must
/// get a clear error instead of a phantom build-machine path.
fn resolve_elle_home() -> Result<PathBuf, String> {
    if let Some(value) = env::var_os(ELLE_HOME_ENV).filter(|value| !value.is_empty()) {
        let path = PathBuf::from(value);
        if path.is_dir() {
            return Ok(path);
        }
        return Err(format!(
            "{} points at a missing directory: {}",
            ELLE_HOME_ENV,
            path.display()
        ));
    }
    let build_time = build_time_repo_root().join(".elle");
    if build_time.is_dir() {
        return Ok(build_time);
    }
    Err(format!(
        "could not resolve the Elle home: ELLE_HOME and {} are unset and the \
         build-time checkout {} does not exist on this machine",
        ELLE_HOME_ENV,
        build_time.display()
    ))
}

fn install_elisp_modules() -> Result<(), String> {
    env::set_var("EMACS_HYPERVISOR_EMBEDDED_INIT_HASH", generated_init_hash());
    env::set_var(
        "EMACS_HYPERVISOR_EMBEDDED_RUNTIME_MODULES",
        embedded::EMBEDDED_ELISP_MODULE_MANIFEST,
    );
    for module in embedded::EMBEDDED_ELISP_MODULES {
        env::set_var(module.env_name, module.embedded_source);
    }
    Ok(())
}

fn embedded_plugin_cache_root() -> PathBuf {
    env::var_os(ELLE_PLUGIN_CACHE_ENV)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| env::temp_dir().join("emacs-hypervisor-elle-plugins"))
}

fn plugin_cache_digest_dir() -> String {
    embedded::EMBEDDED_ELLE_PLUGIN_SET_DIGEST.replace(':', "-")
}

fn plugin_file_matches(path: &Path, bytes: &[u8]) -> bool {
    fs::read(path)
        .map(|existing| existing == bytes)
        .unwrap_or(false)
}

fn write_embedded_plugin_file(
    cache_dir: &Path,
    plugin: &embedded::EmbeddedEllePlugin,
) -> Result<PathBuf, String> {
    let target = cache_dir.join(plugin.file_name);
    if plugin_file_matches(&target, plugin.bytes) {
        return Ok(target);
    }

    let temp_name = format!(
        ".{}.{}.{}.tmp",
        plugin.file_name,
        plugin.digest.replace(':', "-"),
        process::id()
    );
    let temp = cache_dir.join(temp_name);
    fs::write(&temp, plugin.bytes)
        .map_err(|error| format!("failed to write {}: {}", temp.display(), error))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o755))
            .map_err(|error| format!("failed to chmod {}: {}", temp.display(), error))?;
    }

    fs::rename(&temp, &target).map_err(|error| {
        let _ = fs::remove_file(&temp);
        format!(
            "failed to install embedded Elle plugin {} at {}: {}",
            plugin.name,
            target.display(),
            error
        )
    })?;

    Ok(target)
}

fn embedded_plugin_path_env_name(plugin_name: &str) -> String {
    let mut output = String::from("EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_");
    for ch in plugin_name.chars() {
        if ch.is_ascii_alphanumeric() {
            output.push(ch.to_ascii_uppercase());
        } else {
            output.push('_');
        }
    }
    output.push_str("_PATH");
    output
}

fn install_embedded_elle_plugins() -> Result<Option<PathBuf>, String> {
    if embedded::EMBEDDED_ELLE_PLUGINS.is_empty() {
        return Ok(None);
    }

    let cache_dir = embedded_plugin_cache_root().join(plugin_cache_digest_dir());
    fs::create_dir_all(&cache_dir)
        .map_err(|error| format!("failed to create {}: {}", cache_dir.display(), error))?;

    for plugin in embedded::EMBEDDED_ELLE_PLUGINS {
        let plugin_path = write_embedded_plugin_file(&cache_dir, plugin)?;
        env::set_var(embedded_plugin_path_env_name(plugin.name), plugin_path);
    }

    Ok(Some(cache_dir))
}

fn prepend_elle_path(path: Option<String>, dir: &Path) -> String {
    let dir = dir.to_string_lossy().into_owned();
    match path {
        Some(existing) if existing.split(':').any(|entry| entry == dir) => existing,
        Some(existing) if !existing.is_empty() => format!("{}:{}", dir, existing),
        _ => dir,
    }
}

fn format_runtime_error(error: &str, symbols: &SymbolTable) -> String {
    if let Some(start) = error.find("SymbolId(") {
        if let Some(end) = error[start..].find(')') {
            let id_str = &error[start + 9..start + end];
            if let Ok(id) = id_str.parse::<u32>() {
                let name = symbols
                    .name(elle::value::SymbolId(id))
                    .unwrap_or("<unknown>");
                let before = &error[..start];
                let after = &error[start + end + 1..];
                return format!("{}'{}'{}", before, name, after);
            }
        }
    }
    error.to_string()
}

fn fail(message: impl AsRef<str>) -> ! {
    eprintln!("{}", message.as_ref());
    process::exit(1)
}

fn run_serve() {
    let backend_display = "elle/hypervisor.lisp";
    install_elisp_modules().unwrap_or_else(|error| fail(error));
    let embedded_plugin_dir = install_embedded_elle_plugins().unwrap_or_else(|error| fail(error));

    let mut config = Config::default();
    if config.home.is_none() {
        let elle_home = resolve_elle_home().unwrap_or_else(|error| fail(error));
        config.home = Some(elle_home.display().to_string());
    }
    if let Some(plugin_dir) = embedded_plugin_dir {
        config.path = Some(prepend_elle_path(config.path.take(), &plugin_dir));
    }
    elle::config::init(config);

    // One `Runtime` (elle 2.0) owns the VM, the symbol table and the compile
    // context together, registers primitives itself and loads the stdlib; its
    // `Drop` runs the region-teardown sweep. Nothing here to set up or tear down
    // by hand.
    let mut rt = Runtime::new();
    let (vm, symbols, cctx) = rt.parts();

    let compiled = compile_file(
        embedded::EMBEDDED_BACKEND_SOURCE,
        symbols,
        cctx,
        backend_display,
    )
    .unwrap_or_else(|error| fail(error.to_string()));

    if let Err(error) = vm.execute_scheduled(&compiled.bytecode, symbols, cctx) {
        fail(format_runtime_error(&error, symbols));
    }
}

/// Entries that do not make a directory "non-empty" for `init`:
/// Finder droppings and a fresh dotfiles-repo `.git` are both fine to
/// initialize around.
const HOME_NOISE_ENTRIES: &[&str] = &[".DS_Store", ".git", ".gitignore"];

fn ensure_home_is_empty(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    if !path.is_dir() {
        return Err(format!(
            "target Emacs home is not a directory: {}",
            path.display()
        ));
    }
    let entries = fs::read_dir(path)
        .map_err(|error| format!("failed to read {}: {}", path.display(), error))?;
    let mut blocking = Vec::new();
    for entry in entries {
        let entry =
            entry.map_err(|error| format!("failed to read {}: {}", path.display(), error))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !HOME_NOISE_ENTRIES.contains(&name.as_str()) {
            blocking.push(name);
        }
    }
    if !blocking.is_empty() {
        blocking.sort();
        return Err(format!(
            "refusing to initialize non-empty Emacs home: {} (found: {}; ignored entries would be: {})",
            path.display(),
            blocking.join(", "),
            HOME_NOISE_ENTRIES.join(", ")
        ));
    }
    Ok(())
}

fn write_file(path: &Path, contents: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create {}: {}", parent.display(), error))?;
    }
    fs::write(path, contents)
        .map_err(|error| format!("failed to write {}: {}", path.display(), error))
}

fn read_file_if_exists(path: &Path) -> Result<Option<String>, String> {
    if !path.exists() {
        return Ok(None);
    }
    fs::read_to_string(path)
        .map(Some)
        .map_err(|error| format!("failed to read {}: {}", path.display(), error))
}

fn append_bundled_elisp_section(output: &mut String, name: &str, contents: &str) {
    output.push_str(
        ";; ---------------------------------------------------------------------------\n",
    );
    output.push_str(";; Bundled from ");
    output.push_str(name);
    output.push_str("\n\n");
    output.push_str(contents);
    if !contents.ends_with('\n') {
        output.push('\n');
    }
    output.push('\n');
}

fn stable_content_hash(contents: &str) -> String {
    hash::fnv1a64_digest(contents.as_bytes())
}

fn generated_init_body() -> String {
    let mut output = String::new();
    append_bundled_elisp_section(
        &mut output,
        "host/emacs-kernel/emacs-hypervisor-session-state.el",
        embedded::EMBEDDED_SESSION_STATE_ELISP,
    );
    append_bundled_elisp_section(
        &mut output,
        "host/emacs-kernel/emacs-hypervisor-events.el",
        embedded::EMBEDDED_EVENTS_ELISP,
    );
    append_bundled_elisp_section(
        &mut output,
        "host/emacs-kernel/emacs-hypervisor-sexp-rpc.el",
        embedded::EMBEDDED_SEXP_RPC_ELISP,
    );
    append_bundled_elisp_section(
        &mut output,
        "host/emacs-kernel/emacs-hypervisor-bootstrap.el",
        embedded::EMBEDDED_BOOTSTRAP_ELISP,
    );
    append_bundled_elisp_section(
        &mut output,
        "host/emacs-kernel/home-startup.el",
        HOME_STARTUP_ELISP,
    );
    output
}

fn generated_init_elisp() -> String {
    let body = generated_init_body();
    let mut output = String::new();
    output.push_str(
        ";;; init.el --- Generated Emacs Hypervisor bootstrap -*- lexical-binding: t; -*-\n",
    );
    output.push_str(";; emacs-hypervisor-generated: t\n");
    output.push_str(";; emacs-hypervisor-content-hash: ");
    output.push_str(&generated_init_hash());
    output.push('\n');
    output.push_str(
        ";; This file was generated by `emacs-hypervisor init'. Edit Hypervisor config files instead.\n\n",
    );
    output.push_str(&body);
    output
}

fn generated_init_hash() -> String {
    stable_content_hash(&generated_init_body())
}

fn generated_early_init_elisp() -> String {
    let mut output = String::new();
    output.push_str(HOME_EARLY_INIT_ELISP);
    if !output.ends_with('\n') {
        output.push('\n');
    }
    output
}

fn generated_init_file_p(contents: &str) -> bool {
    contents
        .lines()
        .any(|line| line == ";; emacs-hypervisor-generated: t")
}

fn generated_early_init_file_p(contents: &str) -> bool {
    generated_init_file_p(contents)
        || contents.contains("Generated Emacs Hypervisor early init")
        || contents.contains("This file was generated by `emacs-hypervisor init'.")
}

fn existing_init_hash(contents: &str) -> Option<&str> {
    contents
        .lines()
        .find_map(|line| line.strip_prefix(";; emacs-hypervisor-content-hash: "))
}

fn run_init(home: PathBuf, upgrade: bool) -> Result<(), String> {
    if upgrade {
        return run_init_upgrade(home);
    }

    ensure_home_is_empty(&home)?;
    let config_root = default_hypervisor_config_root()?;
    write_file(&home.join("init.el"), &generated_init_elisp())?;
    write_file(&home.join("early-init.el"), &generated_early_init_elisp())?;

    println!("Initialized Emacs Hypervisor home at {}", home.display());
    println!("Next steps:");
    println!(
        "- create {} (recommended)",
        config_root.join("config.org").display()
    );
    println!("- or create {}", config_root.join("config.el").display());
    println!(
        "- optionally create {}",
        config_root.join("early-init.el").display()
    );
    println!("- run `emacs` with this directory as your Emacs home");
    Ok(())
}

fn run_init_upgrade(home: PathBuf) -> Result<(), String> {
    if !home.is_dir() {
        return Err(format!(
            "cannot upgrade missing Emacs home: {}; run `emacs-hypervisor init --home {}` first",
            home.display(),
            home.display()
        ));
    }

    let init_path = home.join("init.el");
    let early_init_path = home.join("early-init.el");
    let current_init = read_file_if_exists(&init_path)?.ok_or_else(|| {
        format!(
            "cannot upgrade missing generated file: {}",
            init_path.display()
        )
    })?;
    let current_early_init = read_file_if_exists(&early_init_path)?;

    if !generated_init_file_p(&current_init) {
        return Err(format!(
            "refusing to overwrite unmanaged init.el at {}",
            init_path.display()
        ));
    }
    if let Some(contents) = &current_early_init {
        if !generated_early_init_file_p(contents) {
            return Err(format!(
                "refusing to overwrite unmanaged early-init.el at {}",
                early_init_path.display()
            ));
        }
    }

    let old_hash = existing_init_hash(&current_init).unwrap_or("<missing>");
    let new_hash = generated_init_hash();
    let new_init = generated_init_elisp();
    let new_early_init = generated_early_init_elisp();
    let init_changed = current_init != new_init;
    let early_init_changed = current_early_init
        .as_ref()
        .map(|contents| contents != &new_early_init)
        .unwrap_or(true);

    // Stage both files first, then rename into place, so a failure between
    // the two writes cannot leave init.el and early-init.el inconsistent
    // with the previous contents already destroyed.
    let init_temp = home.join(format!(".init.el.{}.tmp", process::id()));
    let early_init_temp = home.join(format!(".early-init.el.{}.tmp", process::id()));
    let staged = write_file(&init_temp, &new_init)
        .and_then(|()| write_file(&early_init_temp, &new_early_init));
    if let Err(error) = staged {
        let _ = fs::remove_file(&init_temp);
        let _ = fs::remove_file(&early_init_temp);
        return Err(error);
    }
    fs::rename(&init_temp, &init_path).map_err(|error| {
        let _ = fs::remove_file(&init_temp);
        let _ = fs::remove_file(&early_init_temp);
        format!("failed to install {}: {}", init_path.display(), error)
    })?;
    fs::rename(&early_init_temp, &early_init_path).map_err(|error| {
        let _ = fs::remove_file(&early_init_temp);
        format!(
            "failed to install {}: {}",
            early_init_path.display(),
            error
        )
    })?;

    println!("Upgraded Emacs Hypervisor home at {}", home.display());
    println!("- init.el hash: {} -> {}", old_hash, new_hash);
    println!(
        "- init.el: {}",
        if init_changed { "updated" } else { "unchanged" }
    );
    println!(
        "- early-init.el: {}",
        if early_init_changed {
            "updated"
        } else {
            "unchanged"
        }
    );
    Ok(())
}

fn valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() || first == '_' => {}
        _ => return false,
    }
    chars.all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
}

fn escape_lisp_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Name patterns whose values are almost certainly credentials.  The env
/// snapshot is a plain file in the Emacs home; secrets stay out of it
/// unless re-included deliberately with `--include NAME`.
const SECRET_NAME_SUFFIXES: &[&str] =
    &["_TOKEN", "_KEY", "_SECRET", "_PASSWORD", "_CREDENTIALS"];
const SECRET_NAME_PREFIXES: &[&str] = &["AWS_"];

fn secret_env_name(name: &str) -> bool {
    SECRET_NAME_SUFFIXES
        .iter()
        .any(|suffix| name.ends_with(suffix))
        || SECRET_NAME_PREFIXES
            .iter()
            .any(|prefix| name.starts_with(prefix))
}

struct EnvEntries {
    entries: Vec<String>,
    skipped_secrets: Vec<String>,
}

fn build_env_entries(
    vars: impl IntoIterator<Item = (String, String)>,
    include: &[String],
) -> EnvEntries {
    let mut entries = Vec::new();
    let mut skipped_secrets = Vec::new();
    for (name, value) in vars {
        if !valid_env_name(&name) || name == "SHELL" {
            continue;
        }
        if secret_env_name(&name) && !include.iter().any(|included| included == &name) {
            skipped_secrets.push(name);
            continue;
        }
        entries.push(format!("{}={}", name, value));
    }

    entries.sort();
    skipped_secrets.sort();
    EnvEntries {
        entries,
        skipped_secrets,
    }
}

fn build_env_file_contents(entries: &[String]) -> String {
    let mut contents = String::from(";; -*- mode: lisp-interaction; coding: utf-8-unix; -*-\n");
    contents.push_str(
        ";; ---------------------------------------------------------------------------\n",
    );
    contents.push_str(
        ";; This file was auto-generated by `emacs-hypervisor env'. It contains a list of\n",
    );
    contents.push_str(";; environment variables scraped from the current shell process.\n");
    contents.push_str(";;\n;; Emacs Hypervisor loads this file before user config.\n\n(\n");
    for entry in entries {
        contents.push_str(" \"");
        contents.push_str(&escape_lisp_string(entry));
        contents.push_str("\"\n");
    }
    contents.push_str(")\n");
    contents
}

fn restrict_file_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("failed to chmod {}: {}", path.display(), error))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn run_env(home: PathBuf, output: Option<PathBuf>, include: Vec<String>) -> Result<(), String> {
    let output = output.unwrap_or_else(|| home.join("env"));
    let env_entries = build_env_entries(env::vars(), &include);
    write_file(&output, &build_env_file_contents(&env_entries.entries))?;
    restrict_file_permissions(&output)?;
    println!("Generated environment file: {}", output.display());
    if !env_entries.skipped_secrets.is_empty() {
        println!(
            "Skipped {} secret-like entr{} ({}); use --include NAME to re-include one deliberately.",
            env_entries.skipped_secrets.len(),
            if env_entries.skipped_secrets.len() == 1 {
                "y"
            } else {
                "ies"
            },
            env_entries.skipped_secrets.join(", ")
        );
    }
    Ok(())
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Serve) => run_serve(),
        Some(Commands::Init(args)) => {
            let home = args
                .home
                .unwrap_or_else(|| default_config_root().unwrap_or_else(|error| fail(error)));
            if let Err(error) = run_init(home, args.upgrade) {
                eprintln!("emacs-hypervisor init: {}", error);
                process::exit(1);
            }
        }
        Some(Commands::Env(args)) => {
            let home = args
                .home
                .unwrap_or_else(|| default_config_root().unwrap_or_else(|error| fail(error)));
            if let Err(error) = run_env(home, args.output, args.include) {
                eprintln!("emacs-hypervisor env: {}", error);
                process::exit(1);
            }
        }
        Some(Commands::Check(args)) => match run_check(args) {
            Ok(code) => process::exit(code),
            Err(error) => {
                eprintln!("emacs-hypervisor check: {}", error);
                process::exit(2);
            }
        },
        Some(Commands::BootstrapHash) => {
            println!("{}", generated_init_hash());
        }
        None => run_serve(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEST_HOME_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_test_home() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after UNIX_EPOCH")
            .as_nanos();
        let counter = TEST_HOME_COUNTER.fetch_add(1, Ordering::Relaxed);
        env::temp_dir().join(format!(
            "emacs-hypervisor-init-test-{}-{}-{}",
            process::id(),
            nonce,
            counter
        ))
    }

    #[test]
    fn prepend_elle_path_adds_embedded_plugin_dir_first() {
        let plugin_dir = PathBuf::from("/tmp/emacs-hypervisor-elle-plugins/test");

        assert_eq!(
            prepend_elle_path(None, &plugin_dir),
            "/tmp/emacs-hypervisor-elle-plugins/test"
        );
        assert_eq!(
            prepend_elle_path(Some("/existing/path".to_string()), &plugin_dir),
            "/tmp/emacs-hypervisor-elle-plugins/test:/existing/path"
        );
        assert_eq!(
            prepend_elle_path(
                Some("/tmp/emacs-hypervisor-elle-plugins/test:/existing/path".to_string()),
                &plugin_dir
            ),
            "/tmp/emacs-hypervisor-elle-plugins/test:/existing/path"
        );
    }

    #[test]
    fn embedded_plugin_path_env_name_is_stable() {
        assert_eq!(
            embedded_plugin_path_env_name("mmdflux"),
            "EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_MMDFLUX_PATH"
        );
        assert_eq!(
            embedded_plugin_path_env_name("foo-bar"),
            "EMACS_HYPERVISOR_EMBEDDED_ELLE_PLUGIN_FOO_BAR_PATH"
        );
    }

    #[test]
    fn write_embedded_plugin_file_materializes_bytes() {
        let dir = unique_test_home();
        fs::create_dir_all(&dir).expect("test should create plugin cache");
        let plugin = embedded::EmbeddedEllePlugin {
            name: "unit",
            file_name: "libelle_unit.dylib",
            digest: "fnv1a64:test",
            bytes: b"plugin-bytes",
        };
        let target = dir.join(plugin.file_name);

        write_embedded_plugin_file(&dir, &plugin).expect("plugin write should succeed");
        assert_eq!(
            fs::read(&target).expect("plugin file should be readable"),
            plugin.bytes
        );

        fs::write(&target, b"stale").expect("test should write stale plugin");
        write_embedded_plugin_file(&dir, &plugin).expect("plugin rewrite should succeed");
        assert_eq!(
            fs::read(&target).expect("plugin file should be readable"),
            plugin.bytes
        );

        fs::remove_dir_all(&dir).expect("test plugin cache cleanup should succeed");
    }

    #[test]
    fn init_writes_generated_bootstrap_files() {
        let home = unique_test_home();
        let result = run_init(home.clone(), false);
        assert!(result.is_ok(), "init failed: {:?}", result);

        let init_path = home.join("init.el");
        let init = fs::read_to_string(&init_path).expect("generated init.el should be readable");
        let early_init_path = home.join("early-init.el");
        let early_init = fs::read_to_string(&early_init_path)
            .expect("generated early-init.el should be readable");
        assert!(init.contains(";; emacs-hypervisor-generated: t"));
        assert!(init.contains(";; emacs-hypervisor-content-hash: fnv1a64:"));
        assert!(init.contains("Bundled from host/emacs-kernel/emacs-hypervisor-session-state.el"));
        assert!(init.contains("Bundled from host/emacs-kernel/emacs-hypervisor-events.el"));
        assert!(init.contains("Bundled from host/emacs-kernel/emacs-hypervisor-sexp-rpc.el"));
        assert!(init.contains("Bundled from host/emacs-kernel/emacs-hypervisor-bootstrap.el"));
        assert!(init.contains("Bundled from host/emacs-kernel/home-startup.el"));
        assert!(early_init.contains("Generated Emacs Hypervisor early init"));
        assert!(early_init.contains("emacs-hypervisor"));
        assert!(early_init.contains(
            "(setq package-user-dir (expand-file-name \"packages/\" user-emacs-directory))"
        ));
        assert!(!home.join("lisp").exists());

        fs::remove_dir_all(&home).expect("test home cleanup should succeed");
    }

    #[test]
    fn init_upgrade_rewrites_generated_bootstrap_files() {
        let home = unique_test_home();
        run_init(home.clone(), false).expect("initial init should succeed");

        let init_path = home.join("init.el");
        let early_init_path = home.join("early-init.el");
        let mut stale_init =
            fs::read_to_string(&init_path).expect("generated init.el should be readable");
        stale_init = stale_init.replace(
            ";; emacs-hypervisor-content-hash: ",
            ";; emacs-hypervisor-content-hash: old-",
        );
        stale_init.push_str("\n;; stale local edit\n");
        fs::write(&init_path, stale_init).expect("test should write stale init");
        fs::write(
            &early_init_path,
            ";;; early-init.el --- Generated Emacs Hypervisor early init\n",
        )
        .expect("test should write stale early-init");

        run_init(home.clone(), true).expect("upgrade should succeed");

        let upgraded_init =
            fs::read_to_string(&init_path).expect("upgraded init.el should be readable");
        let upgraded_early_init = fs::read_to_string(&early_init_path)
            .expect("upgraded early-init.el should be readable");
        assert_eq!(upgraded_init, generated_init_elisp());
        assert_eq!(upgraded_early_init, generated_early_init_elisp());

        fs::remove_dir_all(&home).expect("test home cleanup should succeed");
    }

    #[test]
    fn init_upgrade_refuses_unmanaged_init_file() {
        let home = unique_test_home();
        fs::create_dir_all(&home).expect("test should create home");
        fs::write(home.join("init.el"), ";; user init\n").expect("test should write custom init");

        let result = run_init(home.clone(), true);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("refusing to overwrite unmanaged init.el"));

        fs::remove_dir_all(&home).expect("test home cleanup should succeed");
    }

    #[test]
    fn generated_init_hash_matches_header() {
        let init = generated_init_elisp();
        assert!(init.contains(&format!(
            ";; emacs-hypervisor-content-hash: {}",
            generated_init_hash()
        )));
    }

    #[test]
    fn env_entries_skip_shell() {
        let env_entries = build_env_entries(
            vec![
                ("PATH".to_string(), "/usr/bin:/bin".to_string()),
                ("SHELL".to_string(), "/bin/zsh".to_string()),
                ("USER".to_string(), "randall".to_string()),
            ],
            &[],
        );

        assert!(!env_entries
            .entries
            .contains(&"SHELL=/bin/zsh".to_string()));
        assert!(env_entries.entries.contains(&"USER=randall".to_string()));
        assert!(env_entries.skipped_secrets.is_empty());
    }

    #[test]
    fn env_entries_skip_secret_names() {
        let env_entries = build_env_entries(
            vec![
                ("ANTHROPIC_API_KEY".to_string(), "sk-secret".to_string()),
                ("AWS_SECRET_ACCESS_KEY".to_string(), "aws-secret".to_string()),
                ("GITHUB_TOKEN".to_string(), "gh-secret".to_string()),
                ("DB_PASSWORD".to_string(), "hunter2".to_string()),
                ("GOOGLE_CREDENTIALS".to_string(), "blob".to_string()),
                ("CLIENT_SECRET".to_string(), "shh".to_string()),
                ("PATH".to_string(), "/usr/bin".to_string()),
            ],
            &[],
        );

        assert_eq!(env_entries.entries, vec!["PATH=/usr/bin".to_string()]);
        assert_eq!(
            env_entries.skipped_secrets,
            vec![
                "ANTHROPIC_API_KEY",
                "AWS_SECRET_ACCESS_KEY",
                "CLIENT_SECRET",
                "DB_PASSWORD",
                "GITHUB_TOKEN",
                "GOOGLE_CREDENTIALS",
            ]
        );
    }

    #[test]
    fn env_entries_include_reinstates_named_secret() {
        let env_entries = build_env_entries(
            vec![
                ("GITHUB_TOKEN".to_string(), "gh-secret".to_string()),
                ("ANTHROPIC_API_KEY".to_string(), "sk-secret".to_string()),
            ],
            &["GITHUB_TOKEN".to_string()],
        );

        assert_eq!(
            env_entries.entries,
            vec!["GITHUB_TOKEN=gh-secret".to_string()]
        );
        assert_eq!(env_entries.skipped_secrets, vec!["ANTHROPIC_API_KEY"]);
    }

    #[cfg(unix)]
    #[test]
    fn run_env_writes_owner_only_file_without_secrets() {
        use std::os::unix::fs::PermissionsExt;

        let home = unique_test_home();
        fs::create_dir_all(&home).expect("test should create home");
        env::set_var("EMACS_HYPERVISOR_TEST_FAKE_TOKEN", "fake-secret");

        run_env(home.clone(), None, Vec::new()).expect("env snapshot should succeed");

        let output = home.join("env");
        let contents = fs::read_to_string(&output).expect("env file should be readable");
        assert!(!contents.contains("fake-secret"));
        let mode = fs::metadata(&output)
            .expect("env file metadata should be readable")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);

        env::remove_var("EMACS_HYPERVISOR_TEST_FAKE_TOKEN");
        fs::remove_dir_all(&home).expect("test home cleanup should succeed");
    }

    #[test]
    fn ensure_home_is_empty_ignores_noise_entries() {
        let home = unique_test_home();
        fs::create_dir_all(home.join(".git")).expect("test should create .git");
        fs::write(home.join(".DS_Store"), b"finder noise").expect("test should write .DS_Store");

        assert!(ensure_home_is_empty(&home).is_ok());

        fs::write(home.join("init.el"), ";; existing\n").expect("test should write init");
        let error = ensure_home_is_empty(&home).expect_err("real entries must still refuse");
        assert!(error.contains("init.el"));
        assert!(error.contains(".DS_Store"));

        fs::remove_dir_all(&home).expect("test home cleanup should succeed");
    }

    #[test]
    fn init_accepts_home_with_only_noise_entries() {
        let home = unique_test_home();
        fs::create_dir_all(&home).expect("test should create home");
        fs::write(home.join(".DS_Store"), b"finder noise").expect("test should write .DS_Store");

        run_init(home.clone(), false).expect("init should ignore noise entries");
        assert!(home.join("init.el").is_file());

        fs::remove_dir_all(&home).expect("test home cleanup should succeed");
    }

    #[test]
    fn init_upgrade_leaves_no_temp_files() {
        let home = unique_test_home();
        run_init(home.clone(), false).expect("initial init should succeed");
        run_init(home.clone(), true).expect("upgrade should succeed");

        let leftovers = fs::read_dir(&home)
            .expect("home should be readable")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.ends_with(".tmp"))
            .collect::<Vec<_>>();
        assert!(leftovers.is_empty(), "leftover temp files: {:?}", leftovers);

        fs::remove_dir_all(&home).expect("test home cleanup should succeed");
    }
}
