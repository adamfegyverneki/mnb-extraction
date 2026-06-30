#!/bin/bash
#############################################################################
# Manage the local KRATOS_SECRETS_KEY used by pull-s3-secrets.sh.
#
# On macOS the key is stored in the login Keychain (service
# "kratos-secrets-key"); on other platforms in ~/.config/kratos/secrets-key
# (chmod 600). The value is NEVER committed to this repository.
#
# Usage:
#   ./scripts/initial-setup/secrets-key.sh set [<key>]    # store (prompts if omitted)
#   ./scripts/initial-setup/secrets-key.sh get            # print stored key to stdout
#   ./scripts/initial-setup/secrets-key.sh forget         # remove key from this machine
#   ./scripts/initial-setup/secrets-key.sh where          # show backend used on this machine
#   ./scripts/initial-setup/secrets-key.sh status         # show whether a key is stored (no value)
#############################################################################

set -e

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SETUP_DIR}/.." && pwd)"

# shellcheck source=../lib.sh
source "${SCRIPTS_DIR}/lib.sh"
# shellcheck source=./lib-secrets-key.sh
source "${SETUP_DIR}/lib-secrets-key.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  set [<key>]   Store the KRATOS_SECRETS_KEY (prompts for hidden input if omitted)
  get           Print the stored key to stdout (exit 1 if none)
  forget        Remove the stored key from this machine
  where         Show which backend is used on this machine
  status        Show whether a key is stored (does not print the value)
EOF
}

cmd_set() {
    local key="${1:-}"
    if [ -z "${key}" ]; then
        if [ ! -t 0 ]; then
            log_error "No key argument given and stdin is not a TTY."
            exit 1
        fi
        printf "  Enter secrets decryption key: " >&2
        read -r -s key
        echo "" >&2
    fi
    if [ -z "${key}" ]; then
        log_error "Key cannot be empty."
        exit 1
    fi
    local backend
    if ! backend="$(kratos_secrets_key_store "${key}")"; then
        log_error "Failed to store key."
        exit 1
    fi
    log_success "Saved KRATOS_SECRETS_KEY to ${backend}"
}

cmd_get() {
    local key
    key="$(kratos_secrets_key_lookup)"
    if [ -z "${key}" ]; then
        log_warning "No KRATOS_SECRETS_KEY stored on this machine." >&2
        exit 1
    fi
    printf '%s\n' "${key}"
}

cmd_forget() {
    if kratos_secrets_key_forget; then
        log_success "Removed stored KRATOS_SECRETS_KEY from this machine."
    else
        log_info "No stored KRATOS_SECRETS_KEY to remove."
    fi
}

cmd_where() {
    kratos_secrets_key_backend_label
}

cmd_status() {
    local src
    src="$(kratos_secrets_key_source)"
    case "${src}" in
        env)      log_info "KRATOS_SECRETS_KEY found in current shell environment." ;;
        keychain) log_success "KRATOS_SECRETS_KEY found in macOS Keychain." ;;
        file)     log_success "KRATOS_SECRETS_KEY found in ${KRATOS_SECRETS_KEY_FILE}." ;;
        "")       log_warning "No KRATOS_SECRETS_KEY available on this machine."; exit 1 ;;
    esac
}

main() {
    local cmd="${1:-}"
    shift || true
    case "${cmd}" in
        set)          cmd_set "$@" ;;
        get)          cmd_get "$@" ;;
        forget)       cmd_forget "$@" ;;
        where)        cmd_where "$@" ;;
        status)       cmd_status "$@" ;;
        ""|-h|--help) usage ;;
        *)            usage; exit 2 ;;
    esac
}

main "$@"
