set shell := ["bash", "-euo", "pipefail", "-c"]

hypervisor_binary := justfile_directory() + "/target/release/emacs-hypervisor"
e2e_emacs_home := "/tmp/emacs-hypervisor-e2e-home"
e2e_config_home := "/tmp/emacs-hypervisor-e2e-config"
emacs_binary := env_var_or_default("EMACS", "emacs")

[group('Default')]
default:
    @just --list

[group('Build')]
build:
    ./scripts/bootstrap-elle
    ./scripts/build-hypervisor

[group('Build')]
install bin_dir="$HOME/.local/bin": build
    just build
    mkdir -p "{{bin_dir}}"
    rm -f "{{bin_dir}}/emacs-hypervisor"
    cp "{{hypervisor_binary}}" "{{bin_dir}}/emacs-hypervisor"
    if [ "$(uname)" = "Darwin" ]; then \
      codesign --force --sign - "{{bin_dir}}/emacs-hypervisor"; \
    fi

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
    ./scripts/bootstrap-elle --plugins

[group('Elle')]
start-elle-mcp:
    ./scripts/start-elle-mcp

[group('Elle')]
analyze-runtime:
    ./scripts/analyze-runtime-modules

[group('Test')]
test:
    cargo test --offline --locked --manifest-path host/elisp_pack/Cargo.toml
    ./.elle/target/release/elle tests/elle/hypervisor-runtime.lisp
    emacs --batch -Q \
      -L host/emacs-kernel \
      -L elle/runtime-forms \
      -L tests/elisp \
      -l tests/elisp/emacs-hypervisor-bootstrap-test.el \
      -f ert-run-tests-batch-and-exit

[group('Emacs')]
emacs-home-e2e path=e2e_emacs_home config_home=e2e_config_home binary=hypervisor_binary emacs_bin=emacs_binary timeout="120" config_source="": build
    if [ -n "{{config_source}}" ]; then \
      ./scripts/emacs-home-e2e \
        --home "{{path}}" \
        --config-home "{{config_home}}" \
        --binary "{{binary}}" \
        --emacs "{{emacs_bin}}" \
        --timeout "{{timeout}}" \
        --config-source "{{config_source}}"; \
    else \
      ./scripts/emacs-home-e2e \
        --home "{{path}}" \
        --config-home "{{config_home}}" \
        --binary "{{binary}}" \
        --emacs "{{emacs_bin}}" \
        --timeout "{{timeout}}"; \
    fi

[group('Emacs')]
emacs-home-e2e-reset path=e2e_emacs_home config_home=e2e_config_home binary=hypervisor_binary emacs_bin=emacs_binary timeout="120" config_source="": build
    if [ -n "{{config_source}}" ]; then \
      ./scripts/emacs-home-e2e \
        --reset \
        --home "{{path}}" \
        --config-home "{{config_home}}" \
        --binary "{{binary}}" \
        --emacs "{{emacs_bin}}" \
        --timeout "{{timeout}}" \
        --config-source "{{config_source}}"; \
    else \
      ./scripts/emacs-home-e2e \
        --reset \
        --home "{{path}}" \
        --config-home "{{config_home}}" \
        --binary "{{binary}}" \
        --emacs "{{emacs_bin}}" \
        --timeout "{{timeout}}"; \
    fi
