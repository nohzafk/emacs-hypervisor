set shell := ["bash", "-euo", "pipefail", "-c"]

[group('Default')]
default:
    @just --list

[group('Build')]
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=()
    if ! command -v cargo >/dev/null 2>&1; then
      echo "error: cargo/rustup not found — install Rust first: https://rustup.rs" >&2
      exit 1
    fi
    if ! rustup target list --installed 2>/dev/null | grep -q wasm32-unknown-unknown; then
      echo "Installing Rust target: wasm32-unknown-unknown"
      rustup target add wasm32-unknown-unknown
    else
      echo "✓ Rust target wasm32-unknown-unknown"
    fi
    if ! command -v wasm-pack >/dev/null 2>&1; then
      if [[ "$(uname -s)" == Darwin ]] && command -v brew >/dev/null 2>&1; then
        echo "Installing wasm-pack via Homebrew"
        brew install wasm-pack
      else
        echo "Installing wasm-pack via cargo"
        cargo install wasm-pack
      fi
    else
      echo "✓ wasm-pack"
    fi
    # libgit2 — runtime dependency for std/git (HUD extension)
    if [[ "$(uname -s)" == Darwin ]] && command -v brew >/dev/null 2>&1; then
      if ! brew list libgit2 &>/dev/null; then
        echo "Installing libgit2 via Homebrew"
        brew install libgit2
      else
        echo "✓ libgit2"
      fi
      # Elle ffi/native loads "libgit2.so" — macOS only has .dylib, create symlink
      brew_prefix=$(brew --prefix)
      if [ -f "$brew_prefix/lib/libgit2.dylib" ] && [ ! -f "$brew_prefix/lib/libgit2.so" ]; then
        echo "Creating libgit2.so symlink for Elle FFI"
        ln -sf "$brew_prefix/lib/libgit2.dylib" "$brew_prefix/lib/libgit2.so"
      fi
      echo "✓ libgit2.so symlink"
    fi
    echo "All build dependencies ready."

[group('Build')]
build:
    ./scripts/bootstrap-elle
    ./scripts/build-hypervisor

[group('Build')]
dev:
    ./scripts/bootstrap-elle --mcp-plugins
    ./scripts/build-hypervisor

[group('Build')]
install bin_dir="$HOME/.local/bin": dev
    ./scripts/install-hypervisor "{{bin_dir}}"

[group('Build')]
clean:
    rm -rf \
      target \
      host/target \
      host/elisp_pack/target \
      plugins/mmdflux/target \
      .elle/target \
      .elle/plugins/target \
      .elle/mcp/target \
      .elle-mcp

[group('Elle')]
fmt:
    ./scripts/format-elle

[group('Elle')]
analyze-runtime:
    ./scripts/analyze-runtime-modules

[group('Git')]
install-hooks:
    git config core.hooksPath .githooks

[group('Test')]
test: build
    ABBR_TIPS_PROMPT= cargo test --offline --locked --manifest-path host/elisp_pack/Cargo.toml
    ./.elle/target/release/elle tests/elle/hypervisor-runtime.lisp
    emacs --batch -Q \
      -L host/emacs-kernel \
      -L elle/runtime-forms \
      -L tests/elisp \
      -l tests/elisp/emacs-hypervisor-bootstrap-test.el \
      -f ert-run-tests-batch-and-exit

[group('Emacs')]
emacs-home-e2e: build
    ./scripts/emacs-home-e2e

[group('Emacs')]
emacs-home-e2e-reset: build
    ./scripts/emacs-home-e2e --reset
