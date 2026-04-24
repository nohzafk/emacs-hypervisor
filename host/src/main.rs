mod embedded {
    include!(concat!(env!("OUT_DIR"), "/embedded_backend.rs"));
    include!(concat!(env!("OUT_DIR"), "/embedded_elisp.rs"));

    pub const EMBEDDED_REPORT_CORE_SOURCE: &str =
        include_str!("../../elle/runtime-forms/emacs-hypervisor-report-core.el");
    pub const EMBEDDED_REPORT_SOURCE: &str =
        include_str!("../../elle/runtime-forms/emacs-hypervisor-report.el");
    pub const EMBEDDED_DECLARATIONS_SOURCE: &str =
        include_str!("../../elle/runtime-forms/emacs-hypervisor-declarations.el");
    pub const EMBEDDED_COMPOSE_SOURCE: &str =
        include_str!("../../elle/runtime-forms/emacs-hypervisor-compose.el");
    pub const EMBEDDED_ELPACA_BRIDGE_SOURCE: &str =
        include_str!("../../elle/runtime-forms/emacs-hypervisor-elpaca-bridge.el");
    pub const EMBEDDED_PACKAGE_RUNTIME_SOURCE: &str =
        include_str!("../../elle/runtime-forms/emacs-hypervisor-package-runtime.el");
    pub const EMBEDDED_UNIT_RUNTIME_SOURCE: &str =
        include_str!("../../elle/runtime-forms/emacs-hypervisor-unit-runtime.el");
    pub const EMBEDDED_BOOTSTRAP_ELISP: &str =
        include_str!("../../lisp/emacs-hypervisor-bootstrap.el");
    pub const EMBEDDED_SEXP_RPC_ELISP: &str =
        include_str!("../../lisp/emacs-hypervisor-sexp-rpc.el");
    pub const EMBEDDED_SESSION_STATE_ELISP: &str =
        include_str!("../../lisp/emacs-hypervisor-session-state.el");
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

const GENERATED_INIT_ELISP: &str = r#";;; init.el --- Minimal Emacs Hypervisor bootstrap -*- lexical-binding: t; -*-

(defvar emacs-hypervisor-home-directory
  (file-name-directory
   (or load-file-name buffer-file-name user-init-file user-emacs-directory)))

(defvar emacs-hypervisor-config-file
  (expand-file-name "config.el" emacs-hypervisor-home-directory))

(defvar emacs-hypervisor-env-file
  (expand-file-name
   (or (getenv "EMACS_HYPERVISOR_ENV_FILE") "env")
   emacs-hypervisor-home-directory))

(defvar emacs-hypervisor-binary-name
  (or (getenv "EMACS_HYPERVISOR_BIN") "emacs-hypervisor"))

(defvar emacs-hypervisor-binary nil)
(defvar emacs-hypervisor-open-buffer-on-abnormal-exit t)

(setq default-directory emacs-hypervisor-home-directory)
(setq user-emacs-directory
      (file-name-as-directory emacs-hypervisor-home-directory))

(add-to-list 'load-path
             (file-name-as-directory
              (expand-file-name "lisp" emacs-hypervisor-home-directory)))

(require 'emacs-hypervisor-bootstrap)

;; Bootstrap binary resolution rule:
;; 1. Prefer EMACS_HYPERVISOR_BIN when already set.
;; 2. Otherwise try PATH from the original Emacs launch environment.
;; 3. Load the optional env file.
;; 4. If still unresolved, try EMACS_HYPERVISOR_BIN / PATH again.
;; 5. Cache the absolute path before starting the subprocess.
;; This means the env file can help, but is not required for bootstrap.

(defun emacs-hypervisor-resolve-binary-now ()
  "Resolve `emacs-hypervisor' from the current process environment."
  (or (getenv "EMACS_HYPERVISOR_BIN")
      (executable-find emacs-hypervisor-binary-name)))

(defun emacs-hypervisor-resolve-binary ()
  "Resolve and cache the installed `emacs-hypervisor' binary."
  (or emacs-hypervisor-binary
      (setq emacs-hypervisor-binary
            (or (emacs-hypervisor-resolve-binary-now)
                (user-error
                 (concat "Could not find `emacs-hypervisor' via "
                         "EMACS_HYPERVISOR_BIN or PATH"))))))

(defun emacs-hypervisor-empty-session-data (&optional fields)
  "Return an explicit empty session-data payload."
  (let ((requested (or fields '(:packages :units :env)))
        payload)
    (when (memq :packages requested)
      (setq payload (append payload (list :packages ()))))
    (when (memq :units requested)
      (setq payload (append payload (list :units ()))))
    (when (memq :env requested)
      (setq payload (append payload (list :env ()))))
    payload))

(defun emacs-hypervisor-start-home-session ()
  "Start a Hypervisor session for the current Emacs home."
  (when (emacs-hypervisor-live-p)
    (user-error "Hypervisor session is still running"))
  (setq emacs-hypervisor-binary
        (or emacs-hypervisor-binary
            (emacs-hypervisor-resolve-binary-now)))
  (emacs-hypervisor-reset)
  (emacs-hypervisor-load-envvars-file emacs-hypervisor-env-file t)
  (emacs-hypervisor-resolve-binary)
  (setq emacs-hypervisor-context-function
        (lambda ()
          (list
           :session-name "user-home-init"
           :config-file emacs-hypervisor-config-file
           :ui (if noninteractive 'batch 'interactive)
           :transport 's-expression
           :benchmark-enabled nil
           :repo-dir emacs-hypervisor-home-directory)))
  (setq emacs-hypervisor-session-data-function
        (lambda (&optional fields)
          (or (and (fboundp 'emacs-hypervisor-export-session-data)
                   (emacs-hypervisor-export-session-data fields))
              (emacs-hypervisor-empty-session-data fields))))
  (setq emacs-hypervisor-process-sentinel-function
        (lambda (_proc _event)
          (unless noninteractive
            (let ((status (emacs-hypervisor-status)))
              (if (eq (plist-get status :state) :failed)
                  (progn
                    (message "[Hypervisor] session failed: %s"
                             (or (plist-get status :last-process-event)
                                 (plist-get status :shutdown)))
                    (when emacs-hypervisor-open-buffer-on-abnormal-exit
                      (emacs-hypervisor-open-process-buffer)))
                (message "[Hypervisor] session complete: %s"
                         (or (plist-get status :shutdown) :ok)))))))
  (emacs-hypervisor-start
   (list (emacs-hypervisor-resolve-binary) "serve")
   "emacs-hypervisor-init"))

(if (file-exists-p emacs-hypervisor-config-file)
    (progn
      (emacs-hypervisor-start-home-session)
      (unless noninteractive
        (message "[Hypervisor] starting session %s" "user-home-init")))
  (message "[Hypervisor] no config.el found at %s" emacs-hypervisor-config-file))
"#;

#[derive(Parser, Debug)]
#[command(name = "emacs-hypervisor")]
#[command(about = "Elle-native Emacs Hypervisor host")]
#[command(version)]
#[command(override_usage = "emacs-hypervisor
       emacs-hypervisor serve
       emacs-hypervisor init [--home DIR]
       emacs-hypervisor env [--home DIR] [-o FILE]")]
#[command(after_help = "When no subcommand is given, `emacs-hypervisor` defaults to `serve`.

Default Emacs home for `init` and `env`:
- `$XDG_CONFIG_HOME/emacs` when `XDG_CONFIG_HOME` is set
- otherwise `$HOME/.config/emacs`")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Start the stdio Hypervisor backend
    Serve,
    /// Write the minimal Emacs bootstrap into an Emacs home
    Init(InitArgs),
    /// Write an env snapshot Lisp file for the Emacs home
    Env(EnvArgs),
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
    if let Some(xdg_config_home) = env::var_os("XDG_CONFIG_HOME") {
        return Ok(PathBuf::from(xdg_config_home).join("emacs"));
    }
    let home = env::var_os("HOME")
        .ok_or_else(|| "could not detect HOME for default Emacs home".to_string())?;
    Ok(PathBuf::from(home).join(".config").join("emacs"))
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn default_elle_home_path() -> PathBuf {
    repo_root().join(".elle")
}

struct SourceElispModule {
    env_name: &'static str,
    embedded_source: &'static str,
}

struct PackedElispModule {
    env_name: &'static str,
    embedded_forms: &'static str,
}

const SOURCE_ELISP_MODULES: &[SourceElispModule] = &[
    SourceElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_REPORT_CORE_SOURCE",
        embedded_source: embedded::EMBEDDED_REPORT_CORE_SOURCE,
    },
    SourceElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_REPORT_SOURCE",
        embedded_source: embedded::EMBEDDED_REPORT_SOURCE,
    },
    SourceElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_DECLARATIONS_SOURCE",
        embedded_source: embedded::EMBEDDED_DECLARATIONS_SOURCE,
    },
    SourceElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_COMPOSE_SOURCE",
        embedded_source: embedded::EMBEDDED_COMPOSE_SOURCE,
    },
    SourceElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_ELPACA_BRIDGE_SOURCE",
        embedded_source: embedded::EMBEDDED_ELPACA_BRIDGE_SOURCE,
    },
    SourceElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_PACKAGE_RUNTIME_SOURCE",
        embedded_source: embedded::EMBEDDED_PACKAGE_RUNTIME_SOURCE,
    },
    SourceElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_UNIT_RUNTIME_SOURCE",
        embedded_source: embedded::EMBEDDED_UNIT_RUNTIME_SOURCE,
    },
];

const PACKED_ELISP_MODULES: &[PackedElispModule] = &[
    PackedElispModule {
        env_name: "EMACS_HYPERVISOR_EMBEDDED_SESSION_BASE_FORMS",
        embedded_forms: embedded::EMBEDDED_SESSION_BASE_FORMS,
    },
];

fn install_elisp_modules() -> Result<(), String> {
    for module in SOURCE_ELISP_MODULES {
        env::set_var(module.env_name, module.embedded_source);
    }
    for module in PACKED_ELISP_MODULES {
        env::set_var(module.env_name, module.embedded_forms);
    }
    Ok(())
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

    let mut config = Config::default();
    if config.home.is_none() {
        config.home = Some(default_elle_home_path().display().to_string());
    }
    elle::config::init(config);

    let mut vm = VM::new();
    let mut symbols = SymbolTable::new();
    let _signals = register_primitives(&mut vm, &mut symbols);

    set_vm_context(&mut vm as *mut VM);
    set_symbol_table(&mut symbols as *mut SymbolTable);
    init_stdlib(&mut vm, &mut symbols);

    let compiled = compile_file(embedded::EMBEDDED_BACKEND_SOURCE, &mut symbols, backend_display)
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

fn run_init(home: PathBuf) -> Result<(), String> {
    ensure_home_is_empty(&home)?;
    fs::create_dir_all(home.join("lisp"))
        .map_err(|error| format!("failed to create Emacs home {}: {}", home.display(), error))?;

    write_file(&home.join("init.el"), GENERATED_INIT_ELISP)?;
    write_file(
        &home.join("lisp/emacs-hypervisor-bootstrap.el"),
        embedded::EMBEDDED_BOOTSTRAP_ELISP,
    )?;
    write_file(
        &home.join("lisp/emacs-hypervisor-sexp-rpc.el"),
        embedded::EMBEDDED_SEXP_RPC_ELISP,
    )?;
    write_file(
        &home.join("lisp/emacs-hypervisor-session-state.el"),
        embedded::EMBEDDED_SESSION_STATE_ELISP,
    )?;

    println!("Initialized Emacs Hypervisor home at {}", home.display());
    println!("Next steps:");
    println!("- create {}", home.join("config.el").display());
    println!(
        "- optionally create {}",
        home.join("early-init.el").display()
    );
    println!("- run `emacs` with this directory as your Emacs home");
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

fn build_env_file_contents() -> String {
    let mut entries = env::vars()
        .filter(|(name, _)| valid_env_name(name))
        .map(|(name, value)| format!("{}={}", name, value))
        .collect::<Vec<_>>();
    entries.sort();

    let mut contents = String::from(";; -*- mode: lisp-interaction; coding: utf-8-unix; -*-\n");
    contents.push_str(
        ";; ---------------------------------------------------------------------------\n",
    );
    contents.push_str(
        ";; This file was auto-generated by `emacs-hypervisor env'. It contains a list of\n",
    );
    contents.push_str(";; environment variables scraped from the current shell process.\n");
    contents.push_str(";;\n;; Emacs Hypervisor loads this file before `config.el`.\n\n(\n");
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
            if let Err(error) = run_init(home) {
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
        None => run_serve(),
    }
}
