#!/bin/bash
# Locate / store the KRATOS_SECRETS_KEY used to decrypt the S3 secrets bundle.
#
# Lookup order (first match wins):
#   1. $KRATOS_SECRETS_KEY (env var)                 — CI / explicit override
#   2. macOS Keychain                                 — preferred on Darwin
#      service: kratos-secrets-key / account: $USER
#   3. ~/.config/kratos/secrets-key (chmod 600)       — fallback (Linux / WSL / Git Bash)
#
# Sourced by pull-s3-secrets.sh and secrets-key.sh. All user-visible log output
# goes to stderr so callers can safely do: key="$(kratos_secrets_key_lookup)".

[[ -n "${_LIB_SECRETS_KEY_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_LIB_SECRETS_KEY_SH_LOADED=1

KRATOS_SECRETS_KEYCHAIN_SERVICE="kratos-secrets-key"
KRATOS_SECRETS_KEY_FILE="${KRATOS_SECRETS_KEY_FILE:-${HOME}/.config/kratos/secrets-key}"

_kratos_keychain_available() {
    [[ "$(uname -s)" == "Darwin" ]] && command -v security >/dev/null 2>&1
}

# Human-readable name of the backend this machine would use to store a key.
kratos_secrets_key_backend_label() {
    if _kratos_keychain_available; then
        echo "macOS Keychain (service: ${KRATOS_SECRETS_KEYCHAIN_SERVICE}, account: ${USER})"
    else
        echo "${KRATOS_SECRETS_KEY_FILE}"
    fi
}

# Where the lookup actually found a key (after a successful lookup).
# Prints one of: "env", "keychain", "file", or "" when not found.
kratos_secrets_key_source() {
    if [ -n "${KRATOS_SECRETS_KEY:-}" ]; then
        echo "env"; return 0
    fi
    if _kratos_keychain_available \
        && security find-generic-password \
            -a "${USER}" -s "${KRATOS_SECRETS_KEYCHAIN_SERVICE}" -w >/dev/null 2>&1; then
        echo "keychain"; return 0
    fi
    if [ -r "${KRATOS_SECRETS_KEY_FILE}" ]; then
        echo "file"; return 0
    fi
    echo ""
}

# Prints the key to stdout (empty if not found). Never exits non-zero.
kratos_secrets_key_lookup() {
    if [ -n "${KRATOS_SECRETS_KEY:-}" ]; then
        printf '%s' "${KRATOS_SECRETS_KEY}"
        return 0
    fi
    if _kratos_keychain_available; then
        local v
        if v=$(security find-generic-password \
                -a "${USER}" \
                -s "${KRATOS_SECRETS_KEYCHAIN_SERVICE}" \
                -w 2>/dev/null); then
            printf '%s' "${v}"
            return 0
        fi
    fi
    if [ -r "${KRATOS_SECRETS_KEY_FILE}" ]; then
        head -n 1 "${KRATOS_SECRETS_KEY_FILE}" 2>/dev/null | tr -d '\r\n'
        return 0
    fi
    return 0
}

# Store a key in the best local backend. Prints the backend label on success.
kratos_secrets_key_store() {
    local key="$1"
    [ -z "${key}" ] && return 1
    if _kratos_keychain_available; then
        if security add-generic-password \
                -a "${USER}" \
                -s "${KRATOS_SECRETS_KEYCHAIN_SERVICE}" \
                -w "${key}" \
                -U >/dev/null 2>&1; then
            kratos_secrets_key_backend_label
            return 0
        fi
        return 1
    fi
    local dir
    dir="$(dirname "${KRATOS_SECRETS_KEY_FILE}")"
    mkdir -p "${dir}"
    ( umask 077 && printf '%s\n' "${key}" > "${KRATOS_SECRETS_KEY_FILE}" )
    chmod 600 "${KRATOS_SECRETS_KEY_FILE}" 2>/dev/null || true
    kratos_secrets_key_backend_label
}

# Remove the stored key from every local backend. Returns 0 if anything removed.
kratos_secrets_key_forget() {
    local cleaned=0
    if _kratos_keychain_available; then
        if security delete-generic-password \
                -a "${USER}" \
                -s "${KRATOS_SECRETS_KEYCHAIN_SERVICE}" >/dev/null 2>&1; then
            cleaned=1
        fi
    fi
    if [ -f "${KRATOS_SECRETS_KEY_FILE}" ]; then
        rm -f "${KRATOS_SECRETS_KEY_FILE}"
        cleaned=1
    fi
    [ "${cleaned}" -eq 1 ]
}

# Returns 0 if a key is already available, or the user was prompted and it was
# stored successfully. Returns 1 if stdin/stdout is not a TTY (use env or CI) or
# the user bailed. Intended to be called from kratos-setup after scripts/lib.sh
# is loaded (uses log_info / log_success / log_error / log_warning on stderr).
kratos_secrets_ensure_key_interactive() {
    if [ -n "$(kratos_secrets_key_lookup)" ]; then
        return 0
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return 1
    fi
    log_info "No Kratos S3 secrets encryption key was found on this device (env, Keychain, or ${KRATOS_SECRETS_KEY_FILE})."
    log_info "Get KRATOS_SECRETS_KEY from your team, then enter it once — it will be saved for future setup runs and other clones on this machine."
    local key attempt label
    local max_attempts=3
    label=$(kratos_secrets_key_backend_label)
    for ((attempt=1; attempt <= max_attempts; attempt++)); do
        printf "  Enter KRATOS_SECRETS_KEY (hidden): " >&2
        read -r -s key
        echo "" >&2
        if [ -n "${key}" ]; then
            if kratos_secrets_key_store "${key}" >/dev/null; then
                log_success "Saved Kratos secrets key to ${label}."
                return 0
            fi
            log_error "Could not store the key (Keychain or ${KRATOS_SECRETS_KEY_FILE})."
            return 1
        fi
        if [ "$attempt" -lt "${max_attempts}" ]; then
            log_warning "Key was empty. Try again (${attempt}/${max_attempts}) or press Ctrl+C to exit."
        fi
    done
    log_error "No key entered — the S3 pull will prompt again, or set KRATOS_SECRETS_KEY in the environment."
    return 1
}
