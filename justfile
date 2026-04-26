set shell := ["bash", "-euo", "pipefail", "-c"]

test_home := justfile_directory() + "/.test-home"
test_config_home := justfile_directory() + "/.test-config-home"
hypervisor_binary := justfile_directory() + "/target/release/emacs-hypervisor"

[group('Default')]
default:
    @just --list

[group('Build')]
build:
    ./scripts/build-hypervisor

[group('Build')]
install bin_dir="$HOME/.local/bin":
    just build
    mkdir -p "{{bin_dir}}"
    cp "{{hypervisor_binary}}" "{{bin_dir}}/emacs-hypervisor"

[group('Build')]
build-debug:
    ./scripts/build-hypervisor --debug

[group('Build')]
clean:
    rm -rf target host/target host/elisp_pack/target

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
emacs-home-reset path=test_home config_home=test_config_home:
    rm -rf "{{path}}" "{{config_home}}"
    XDG_CONFIG_HOME="{{config_home}}" ./target/release/emacs-hypervisor init --home "{{path}}"
    mkdir -p "{{config_home}}/emacs-hypervisor"
    cp early-init.el config.org "{{config_home}}/emacs-hypervisor"
    cp -r config/ "{{config_home}}/emacs-hypervisor"

[group('Emacs')]
emacs-home-run path=test_home binary=hypervisor_binary config_home=test_config_home:
    XDG_CONFIG_HOME="{{config_home}}" EMACS_HYPERVISOR_BIN="{{binary}}" emacs --init-directory="{{path}}"

[group('Emacs')]
emacs-home-live-test path=test_home binary=hypervisor_binary:
    just build
    just emacs-home-reset "{{path}}"
    just emacs-home-run "{{path}}" "{{binary}}"
