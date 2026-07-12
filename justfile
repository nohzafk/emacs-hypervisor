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
test: build check-docs
    ABBR_TIPS_PROMPT= cargo test --offline --locked --manifest-path host/elisp_pack/Cargo.toml
    ./.elle/target/release/elle tests/elle/hypervisor-runtime.lisp
    emacs --batch -Q \
      --eval '(setq native-comp-enable-subr-trampolines nil)' \
      -L host/emacs-kernel \
      -L elle/runtime-forms \
      -L tests/elisp \
      -l tests/elisp/emacs-hypervisor-bootstrap-test.el \
      -f ert-run-tests-batch-and-exit

# Fail when machine-specific absolute paths appear in tracked markdown.
[group('Test')]
check-docs:
    #!/usr/bin/env bash
    set -euo pipefail
    # .agent-shell/.agents hold untracked local transcripts.
    if grep -rn --include='*.md' '/Users/' . \
        --exclude-dir=.git \
        --exclude-dir=.elle \
        --exclude-dir=.elle-mcp \
        --exclude-dir=.agent-shell \
        --exclude-dir=.agents \
        --exclude-dir=target; then
      echo "error: machine-specific /Users/ paths found in markdown" >&2
      exit 1
    fi
    echo "check-docs: ok"

[group('Emacs')]
emacs-home-e2e: build
    ./scripts/emacs-home-e2e

[group('Emacs')]
emacs-home-e2e-reset: build
    ./scripts/emacs-home-e2e --reset
