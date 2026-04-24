set shell := ["bash", "-euo", "pipefail", "-c"]

[group('Meta')]
default:
    @just --list

[group('Build')]
build:
    ./scripts/build-hypervisor

[group('Build')]
build-debug:
    ./scripts/build-hypervisor --debug

[group('Build')]
clean:
    rm -rf target host/target host/elisp_pack/target

[group('Build')]
rebuild:
    just clean
    just build

[group('Build')]
test-pack:
    cargo test --offline --locked --manifest-path host/elisp_pack/Cargo.toml

[group('Build')]
verify:
    just test-pack
    just build

[group('Elle')]
bootstrap-elle:
    ./scripts/bootstrap-elle

[group('Elle')]
start-elle-mcp:
    ./scripts/start-elle-mcp

[group('Elle')]
analyze-runtime:
    ./scripts/analyze-runtime-modules

[group('Elle')]
analyze-runtime-verbose:
    ./scripts/analyze-runtime-modules --verbose

[group('Test')]
clean-home home="/tmp/test3":
    rm -rf {{home}}

[group('Test')]
init-home home="/tmp/test3":
    ./target/release/emacs-hypervisor init --home {{home}}

[group('Test')]
env-home home="/tmp/test3":
    ./target/release/emacs-hypervisor env --home {{home}}

[group('Test')]
reset-home home="/tmp/test3":
    just clean-home {{home}}
    just init-home {{home}}

[group('Test')]
run-emacs home="/tmp/test3" binary=(justfile_directory() + "/target/release/emacs-hypervisor"):
    EMACS_HYPERVISOR_BIN={{binary}} emacs --init-directory={{home}}

[group('Test')]
live-test home="/tmp/test3":
    just build
    just reset-home {{home}}
    cp early-init.el config.el {{home}}
    just run-emacs {{home}}
