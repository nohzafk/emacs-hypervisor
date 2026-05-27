set shell := ["bash", "-euo", "pipefail", "-c"]

[group('Default')]
default:
    @just --list

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
    rm -rf target host/target host/elisp_pack/target

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
    cargo test --offline --locked --manifest-path host/elisp_pack/Cargo.toml
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
