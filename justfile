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
      -L host/templates/lisp \
      -L elle/runtime-forms \
      -L tests/elisp \
      -l tests/elisp/emacs-hypervisor-bootstrap-test.el \
      -f ert-run-tests-batch-and-exit

[group('Emacs')]
home action="live" path="/tmp/test3" binary=(justfile_directory() + "/target/release/emacs-hypervisor"):
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{action}}" in
      clean)
        rm -rf "{{path}}"
        ;;
      init)
        ./target/release/emacs-hypervisor init --home "{{path}}"
        ;;
      env)
        ./target/release/emacs-hypervisor env --home "{{path}}"
        ;;
      reset)
        rm -rf "{{path}}"
        ./target/release/emacs-hypervisor init --home "{{path}}"
        ;;
      run)
        EMACS_HYPERVISOR_BIN="{{binary}}" emacs --init-directory="{{path}}"
        ;;
      live)
        just build
        rm -rf "{{path}}"
        ./target/release/emacs-hypervisor init --home "{{path}}"
        cp early-init.el config.el "{{path}}"
        EMACS_HYPERVISOR_BIN="{{binary}}" emacs --init-directory="{{path}}"
        ;;
      *)
        printf 'unknown home action: %s\n' "{{action}}" >&2
        printf 'expected one of: clean, init, env, reset, run, live\n' >&2
        exit 64
        ;;
    esac
