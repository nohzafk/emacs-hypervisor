set shell := ["bash", "-euo", "pipefail", "-c"]

test_home := justfile_directory() + "/.test-home"
hypervisor_binary := justfile_directory() + "/target/release/emacs-hypervisor"

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
verify:
    just test
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
test:
    cargo test --offline --locked --manifest-path host/elisp_pack/Cargo.toml
    ./.elle/target/debug/elle tests/elle/hypervisor-runtime.lisp
    emacs --batch -Q \
      -L host/emacs-kernel \
      -L elle/runtime-forms \
      -L tests/elisp \
      -l tests/elisp/emacs-hypervisor-bootstrap-test.el \
      -f ert-run-tests-batch-and-exit

[group('Emacs')]
home-reset path=test_home:
    rm -rf "{{path}}"
    ./target/release/emacs-hypervisor init --home "{{path}}"
    cp early-init.el config.el "{{path}}"

[group('Emacs')]
home-run path=test_home binary=hypervisor_binary:
    EMACS_HYPERVISOR_BIN="{{binary}}" emacs --init-directory="{{path}}"

[group('Emacs')]
home-live-test path=test_home binary=hypervisor_binary:
    just build
    just home-reset "{{path}}"
    just home-run "{{path}}" "{{binary}}"
