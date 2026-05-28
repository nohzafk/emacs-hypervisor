mod embedded {
    include!(concat!(env!("OUT_DIR"), "/embedded_backend.rs"));
    include!(concat!(env!("OUT_DIR"), "/embedded_elisp.rs"));
    include!(concat!(env!("OUT_DIR"), "/embedded_plugins.rs"));
    include!(concat!(env!("OUT_DIR"), "/embedded_hud.rs"));

    pub const EMBEDDED_BOOTSTRAP_ELISP: &str =
        include_str!("../emacs-kernel/emacs-hypervisor-bootstrap.el");
    pub const EMBEDDED_SEXP_RPC_ELISP: &str =
        include_str!("../emacs-kernel/emacs-hypervisor-sexp-rpc.el");
    pub const EMBEDDED_SESSION_STATE_ELISP: &str =
        include_str!("../emacs-kernel/emacs-hypervisor-session-state.el");
    pub const EMBEDDED_EARLY_INIT_ELISP: &str = include_str!("../emacs-kernel/early-init.el");
}

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;

use clap::{Args, Parser, Subcommand};
use elle::config::Config;
use elle::context::{clear_symbol_table, clear_vm_context, set_symbol_table, set_vm_context};
use elle::pipeline::compile_file;
use elle::{init_stdlib, register_primitives, SymbolTable, VM};

const HOME_STARTUP_ELISP: &str = include_str!("../emacs-kernel/home-startup.el");
const HOME_EARLY_INIT_ELISP: &str = embedded::EMBEDDED_EARLY_INIT_ELISP;
const ELLE_PLUGIN_CACHE_ENV: &str = "EMACS_HYPERVISOR_ELLE_PLUGIN_CACHE_DIR";

#[derive(Parser, Debug)]
#[command(name = "emacs-hypervisor")]
#[command(about = "Elle-native Emacs Hypervisor host")]
#[command(version)]
#[command(override_usage = "emacs-hypervisor
       emacs-hypervisor serve
       emacs-hypervisor init [--home DIR] [--upgrade]
       emacs-hypervisor env [--home DIR] [-o FILE]")]
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
    /// Print the generated init.el bootstrap content hash
    #[command(name = "bootstrap-hash", hide = true)]
    BootstrapHash,
}

#[derive(Args, Debug)]
#[command(after_help = "Default `--home`:
- `$XDG_CONFIG_HOME/emacs` when `XDG_CONFIG_HOME` is set
- otherwise `$HOME/.config/emacs`")]
struct InitArgs {
    #[arg(
        long,
        value_name = "DIR",
        help = "Emacs home directory (default: ~/.config/emacs or XDG_CONFIG_HOME/emacs)"
    )]
    home: Option<PathBuf>,

    #[arg(
        long,
        help = "Rewrite generated bootstrap files in an existing Emacs Hypervisor home"
    )]
    upgrade: bool,
}

#[derive(Args, Debug)]
#[command(after_help = "Default `--home`:
- `$XDG_CONFIG_HOME/emacs` when `XDG_CONFIG_HOME` is set
- otherwise `$HOME/.config/emacs`")]
struct EnvArgs {
    #[arg(
        long,
        value_name = "DIR",
        help = "Emacs home directory (default: ~/.config/emacs or XDG_CONFIG_HOME/emacs)"
    )]
    home: Option<PathBuf>,

    #[arg(
        short = 'o',
        long = "output",
        value_name = "FILE",
        help = "Write the env snapshot to FILE instead of HOME/env"
    )]
    output: Option<PathBuf>,
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

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn default_elle_home_path() -> PathBuf {
    repo_root().join(".elle")
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

fn start_hud_server() -> Result<u16, String> {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|error| format!("failed to bind HUD server: {}", error))?;
    let port = listener.local_addr().unwrap().port();
    
    thread::spawn(move || {
        for stream in listener.incoming() {
            if let Ok(mut stream) = stream {
                thread::spawn(move || {
                    let mut buffer = [0; 1024];
                    if let Ok(_) = stream.read(&mut buffer) {
                        let req = String::from_utf8_lossy(&buffer);
                        let mut response = Vec::new();
                        
                        if req.contains("GET /index.html") || req.contains("GET / HTTP") {
                            response.extend_from_slice(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
                            response.extend_from_slice(embedded::HUD_INDEX_HTML_BYTES);
                        } else if req.contains("GET /pkg/hud_wasm.js") {
                            response.extend_from_slice(b"HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
                            response.extend_from_slice(embedded::HUD_WASM_JS_BYTES);
                        } else if req.contains("GET /pkg/hud_wasm_bg.wasm") {
                            response.extend_from_slice(b"HTTP/1.1 200 OK\r\nContent-Type: application/wasm\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
                            response.extend_from_slice(embedded::HUD_WASM_BG_BYTES);
                        } else {
                            response.extend_from_slice(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
                        }
                        
                        let _ = stream.write_all(&response);
                        let _ = stream.flush();
                    }
                });
            }
        }
    });
    
    Ok(port)
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
    clear_vm_context();
    clear_symbol_table();
    process::exit(1)
}

fn run_serve() {
    let backend_display = "elle/hypervisor.lisp";
    install_elisp_modules().unwrap_or_else(|error| fail(error));
    let hud_port = start_hud_server().unwrap_or_else(|error| fail(error));
    env::set_var(
        "EMACS_HYPERVISOR_EMBEDDED_HUD_URL",
        format!("http://127.0.0.1:{}/index.html", hud_port),
    );
    let embedded_plugin_dir = install_embedded_elle_plugins().unwrap_or_else(|error| fail(error));

    let mut config = Config::default();
    if config.home.is_none() {
        config.home = Some(default_elle_home_path().display().to_string());
    }
    if let Some(plugin_dir) = embedded_plugin_dir {
        config.path = Some(prepend_elle_path(config.path.take(), &plugin_dir));
    }
    elle::config::init(config);

    let mut vm = VM::new();
    let mut symbols = SymbolTable::new();
    let _signals = register_primitives(&mut vm, &mut symbols);

    set_vm_context(&mut vm as *mut VM);
    set_symbol_table(&mut symbols as *mut SymbolTable);
    init_stdlib(&mut vm, &mut symbols);

    let compiled = compile_file(
        embedded::EMBEDDED_BACKEND_SOURCE,
        &mut symbols,
        backend_display,
    )
    .unwrap_or_else(|error| fail(error.to_string()));

    if let Err(error) = vm.execute_scheduled(&compiled.bytecode, &symbols) {
        fail(format_runtime_error(&error, &symbols));
    }

    clear_vm_context();
    clear_symbol_table();
}

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
    let mut entries = fs::read_dir(path)
        .map_err(|error| format!("failed to read {}: {}", path.display(), error))?;
    if entries.next().is_some() {
        return Err(format!(
            "refusing to initialize non-empty Emacs home: {}",
            path.display()
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
    let mut hash = 0xcbf29ce484222325u64;
    for byte in contents.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("fnv1a64:{:016x}", hash)
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

    write_file(&init_path, &new_init)?;
    write_file(&early_init_path, &new_early_init)?;

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

fn build_env_entries(vars: impl IntoIterator<Item = (String, String)>) -> Vec<String> {
    let mut entries = vars
        .into_iter()
        .filter(|(name, _)| valid_env_name(name))
        .filter(|(name, _)| name != "SHELL")
        .map(|(name, value)| format!("{}={}", name, value))
        .collect::<Vec<_>>();

    entries.sort();
    entries
}

fn build_env_file_contents() -> String {
    let entries = build_env_entries(env::vars());

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
        contents.push_str(&escape_lisp_string(&entry));
        contents.push_str("\"\n");
    }
    contents.push_str(")\n");
    contents
}

fn run_env(home: PathBuf, output: Option<PathBuf>) -> Result<(), String> {
    let output = output.unwrap_or_else(|| home.join("env"));
    write_file(&output, &build_env_file_contents())?;
    println!("Generated environment file: {}", output.display());
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
            if let Err(error) = run_env(home, args.output) {
                eprintln!("emacs-hypervisor env: {}", error);
                process::exit(1);
            }
        }
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
        let entries = build_env_entries(vec![
            ("PATH".to_string(), "/usr/bin:/bin".to_string()),
            ("SHELL".to_string(), "/bin/zsh".to_string()),
            ("USER".to_string(), "randall".to_string()),
        ]);

        assert!(!entries.contains(&"SHELL=/bin/zsh".to_string()));
        assert!(entries.contains(&"USER=randall".to_string()));
    }
}
