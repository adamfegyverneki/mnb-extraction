#!/bin/bash

#############################################################################
# Pull .env values from S3 (encrypted) into backend/.env
#
# Downloads secrets/secrets.env.enc from the kratos-secrets.49x.ai S3 bucket,
# decrypts with AES-256-CBC using KRATOS_SECRETS_KEY (env var or prompt),
# and writes backend/.env.
#
# If backend/.env already exists and has at least one KEY= assignment line, this
# script exits with code 2 (fatal for setup): clear the file or remove those lines,
# then re-run. If the file exists but has no assignments (empty or comments only),
# the pull proceeds and fills the file.
#
# When backend/.env exists without assignments: merges S3 keys into parsed content —
# keys present only in S3 are added; keys in both use S3 unless the key is a
# preserved MongoDB/Atlas name (local values win for those).
#
# Preserves MongoDB and Atlas CLI vars from existing backend/.env if set:
# MONGODB_URI, MONGODB_DB_NAME,
# MONGODB_ATLAS_*_API_KEY, MONGODB_ATLAS_ORG_ID, MONGODB_ATLAS_PROJECT_ID,
# MONGODB_ATLAS_PRODUCTION_PROJECT_ID (and legacy MONGODB_ATLAS_STAGING_PROJECT_ID).
#
# Usage: ./scripts/initial-setup/pull-s3-secrets.sh
#   Or called by ./scripts/dev.sh setup (via initial-setup/kratos-setup.sh).
#
# Exit codes: 0 success, 1 prerequisite/decrypt/S3 failure, 2 backend/.env already
# has variable assignments (remove or empty .env, then re-run).
#
# Prerequisites: aws CLI configured, openssl; python3 for merge when .env exists
#
# KRATOS_SECRETS_KEY lookup (first match wins):
#   1. $KRATOS_SECRETS_KEY env var
#   2. macOS Keychain (service "kratos-secrets-key", account $USER)
#   3. ~/.config/kratos/secrets-key (chmod 600)
#   4. Interactive prompt — offers to save for next time.
# See: ./scripts/initial-setup/secrets-key.sh for managing the local store.
#############################################################################

set -e

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SETUP_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${SETUP_DIR}/../.." && pwd)"
BACKEND_ENV="${PROJECT_ROOT}/backend/.env"

# shellcheck source=../lib.sh
source "${SCRIPTS_DIR}/lib.sh"
# shellcheck source=./lib-secrets-key.sh
source "${SETUP_DIR}/lib-secrets-key.sh"

S3_BUCKET="kratos-secrets.49x.ai"
S3_KEY="secrets/secrets.env.enc"
S3_REGION="eu-central-1"

# True if backend/.env exists and has at least one KEY= line (value may be empty).
backend_env_has_assignment_lines() {
    [ -f "${BACKEND_ENV}" ] && grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "${BACKEND_ENV}" 2>/dev/null
}

# Exit 2 when .env already has assignments so the user can dedupe/merge manually.
require_empty_or_missing_backend_env() {
    if backend_env_has_assignment_lines; then
        log_error "backend/.env already exists and contains variable assignments."
        log_info "Remove or empty that file (delete all KEY= lines or delete the file), then run this script again."
        log_info "After a successful pull, restore any local-only values manually and ensure each key appears only once."
        exit 2
    fi
}

check_prerequisites() {
    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI not found. Install: brew install awscli"
        exit 1
    fi
    if ! command -v openssl &>/dev/null; then
        log_error "openssl not found. Install via your system package manager."
        exit 1
    fi
    if ! aws sts get-caller-identity &>/dev/null 2>&1; then
        log_error "AWS credentials not configured. Run: aws configure"
        exit 1
    fi
}

# Set to 1 by get_encryption_key when the key came from an interactive prompt,
# so pull_secrets can offer to persist it locally after a successful decrypt.
KRATOS_SECRETS_KEY_FROM_PROMPT=0

# Prints the key to stdout; diagnostics / prompts go to stderr so callers
# can safely capture with `key=$(get_encryption_key)`.
get_encryption_key() {
    KRATOS_SECRETS_KEY_FROM_PROMPT=0
    local source
    source="$(kratos_secrets_key_source)"
    case "${source}" in
        env)
            log_info "Using KRATOS_SECRETS_KEY from environment." >&2
            ;;
        keychain)
            log_info "Using KRATOS_SECRETS_KEY from macOS Keychain." >&2
            ;;
        file)
            log_info "Using KRATOS_SECRETS_KEY from ${KRATOS_SECRETS_KEY_FILE}." >&2
            ;;
        "")
            ;;
    esac
    if [ -n "${source}" ]; then
        kratos_secrets_key_lookup
        return
    fi
    if [ ! -t 0 ]; then
        log_error "KRATOS_SECRETS_KEY not set and no TTY for interactive prompt."
        log_info "Options:"
        log_info "  - export KRATOS_SECRETS_KEY=<key> before running"
        log_info "  - or pre-store it once: ./scripts/initial-setup/secrets-key.sh set"
        exit 1
    fi
    local key
    printf "  Enter secrets decryption key: " >&2
    read -r -s key
    echo "" >&2
    if [ -z "$key" ]; then
        log_error "Encryption key cannot be empty."
        exit 1
    fi
    KRATOS_SECRETS_KEY_FROM_PROMPT=1
    printf '%s' "$key"
}

# Offer to persist a prompt-supplied key after we know it decrypted correctly.
maybe_save_prompted_key() {
    local key="$1"
    [ "${KRATOS_SECRETS_KEY_FROM_PROMPT}" = "1" ] || return 0
    [ -t 0 ] || return 0
    local label
    label="$(kratos_secrets_key_backend_label)"
    local answer=""
    printf "  Save this key to %s for next time? [Y/n] " "${label}" >&2
    read -r answer || true
    case "${answer}" in
        n|N|no|NO)
            log_info "Skipped — you'll be asked again next run." ;;
        *)
            if kratos_secrets_key_store "${key}" >/dev/null; then
                log_success "Saved key to ${label}."
            else
                log_warning "Could not save key to ${label}."
            fi
            ;;
    esac
}

# Merge existing .env with decrypted S3 dotenv: S3 keys fill gaps and override
# except preserved Mongo/Atlas keys already set locally.
merge_env_with_s3() {
    local existing_path="$1"
    local s3_plain_path="$2"
    local out_path="$3"
    if [ ! -f "$existing_path" ]; then
        cp "$s3_plain_path" "$out_path"
        return 0
    fi
    if ! command -v python3 &>/dev/null; then
        log_warning "python3 not found — writing S3 secrets only (no merge with existing backend/.env)."
        cp "$s3_plain_path" "$out_path"
        return 0
    fi
    python3 - "$existing_path" "$s3_plain_path" "$out_path" <<'PY'
import os
import re
import sys

PRESERVED = {
    "MONGODB_URI",
    "MONGODB_DB_NAME",
    "MONGODB_ATLAS_PUBLIC_API_KEY",
    "MONGODB_ATLAS_PRIVATE_API_KEY",
    "MONGODB_ATLAS_ORG_ID",
    "MONGODB_ATLAS_PROJECT_ID",
    "MONGODB_ATLAS_PRODUCTION_PROJECT_ID",
    "MONGODB_ATLAS_STAGING_PROJECT_ID",
}


def parse_env(path):
    out = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.rstrip("\n\r")
            t = s.strip()
            if not t or t.startswith("#"):
                continue
            if "=" not in s:
                continue
            key, _, _ = s.partition("=")
            key = key.strip()
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                out[key] = s
    return out


def main():
    existing_path, s3_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    existing = parse_env(existing_path)
    s3 = parse_env(s3_path)
    merged = dict(existing)
    for key, line in s3.items():
        if key in PRESERVED and key in existing:
            continue
        merged[key] = line
    with open(out_path, "w", encoding="utf-8", newline="\n") as out:
        for key in sorted(merged.keys()):
            out.write(merged[key] + "\n")


if __name__ == "__main__":
    main()
PY
}

# Org S3 bundle may use RELAY_REGISTRATION_SECRET; runtime expects REGISTRATION_SECRET.
normalize_relay_env_aliases() {
    if ! [ -f "${BACKEND_ENV}" ]; then
        return 0
    fi
    if grep -qE '^REGISTRATION_SECRET=' "${BACKEND_ENV}" 2>/dev/null; then
        return 0
    fi
    local relay_reg
    relay_reg=$(grep -E '^RELAY_REGISTRATION_SECRET=' "${BACKEND_ENV}" 2>/dev/null | head -1) || true
    if [ -z "${relay_reg}" ]; then
        return 0
    fi
    printf '%s\n' "${relay_reg}" | sed 's/^RELAY_REGISTRATION_SECRET=/REGISTRATION_SECRET=/' >> "${BACKEND_ENV}"
    log_info "Set REGISTRATION_SECRET from RELAY_REGISTRATION_SECRET (Relay route/send API)"
}

append_preserved_mongo_atlas_block() {
    local atlas_tmp="$1"
    if [ -z "${atlas_tmp:-}" ] || [ ! -s "${atlas_tmp}" ]; then
        return 0
    fi
    local remove_re="" k line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        k="${line%%=*}"
        [ -z "$k" ] && continue
        k=$(printf '%s\n' "$k" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
        remove_re="${remove_re}${remove_re:+|}^${k}="
    done < "${atlas_tmp}"
    if [ -n "$remove_re" ]; then
        grep -v -E "$remove_re" "${BACKEND_ENV}" 2>/dev/null > "${BACKEND_ENV}.tmp" || true
    else
        cp "${BACKEND_ENV}" "${BACKEND_ENV}.tmp"
    fi
    [ -s "${BACKEND_ENV}.tmp" ] && printf '\n' >> "${BACKEND_ENV}.tmp"
    cat "${atlas_tmp}" >> "${BACKEND_ENV}.tmp"
    mv "${BACKEND_ENV}.tmp" "${BACKEND_ENV}"
    log_info "Kept MongoDB Atlas connection/API key settings (not overwritten by S3 secrets)"
}

pull_secrets() {
    local enc_tmp dec_tmp atlas_tmp=""

    log_info "Downloading encrypted secrets from S3 (s3://${S3_BUCKET}/${S3_KEY})..."

    enc_tmp=$(mktemp)
    dec_tmp=$(mktemp)

    if ! aws s3api get-object \
        --bucket "${S3_BUCKET}" \
        --key "${S3_KEY}" \
        --region "${S3_REGION}" \
        "${enc_tmp}" &>/dev/null; then
        rm -f "${enc_tmp}" "${dec_tmp}"
        log_error "Failed to download secrets from S3."
        log_info "Check AWS credentials and s3:GetObject on s3://${S3_BUCKET}/${S3_KEY} (this org bucket is not created by developers)."
        log_info "See: docs/kratos/s3-secrets-setup.md"
        exit 1
    fi

    local key decrypt_ok dec_attempt=1 max_dec_attempts=3
    while [ "${dec_attempt}" -le "${max_dec_attempts}" ]; do
        key=$(get_encryption_key)

        log_info "Decrypting secrets..."
        if openssl enc -d -aes-256-cbc -pbkdf2 \
            -in "${enc_tmp}" \
            -out "${dec_tmp}" \
            -pass "pass:${key}" 2>/dev/null; then
            decrypt_ok=1
            break
        fi
        if [ -t 0 ] && [ "${dec_attempt}" -lt "${max_dec_attempts}" ]; then
            log_error "Decryption failed — wrong key, or corrupted download."
            log_info "Clearing any saved key; enter the correct KRATOS_SECRETS_KEY from your team."
            unset KRATOS_SECRETS_KEY
            kratos_secrets_key_forget || true
        else
            break
        fi
        dec_attempt=$((dec_attempt + 1))
    done

    if [ "${decrypt_ok:-0}" != "1" ]; then
        rm -f "${enc_tmp}" "${dec_tmp}"
        log_error "Decryption failed after ${max_dec_attempts} attempt(s) — wrong key or corrupted file."
        log_info "Ask your team for the correct KRATOS_SECRETS_KEY, then run: ./scripts/initial-setup/secrets-key.sh set"
        exit 1
    fi
    rm -f "${enc_tmp}"

    maybe_save_prompted_key "${key}"

    mkdir -p "$(dirname "${BACKEND_ENV}")"

    if [ -f "${BACKEND_ENV}" ]; then
        atlas_tmp=$(mktemp)
        {
            grep '^MONGODB_URI=' "${BACKEND_ENV}" 2>/dev/null | head -1
            grep '^MONGODB_DB_NAME=' "${BACKEND_ENV}" 2>/dev/null | head -1
            grep '^MONGODB_ATLAS_PUBLIC_API_KEY=' "${BACKEND_ENV}" 2>/dev/null | head -1
            grep '^MONGODB_ATLAS_PRIVATE_API_KEY=' "${BACKEND_ENV}" 2>/dev/null | head -1
            grep '^MONGODB_ATLAS_ORG_ID=' "${BACKEND_ENV}" 2>/dev/null | head -1
            grep '^MONGODB_ATLAS_PROJECT_ID=' "${BACKEND_ENV}" 2>/dev/null | head -1
            grep '^MONGODB_ATLAS_PRODUCTION_PROJECT_ID=' "${BACKEND_ENV}" 2>/dev/null | head -1
            grep '^MONGODB_ATLAS_STAGING_PROJECT_ID=' "${BACKEND_ENV}" 2>/dev/null | head -1
        } > "${atlas_tmp}" 2>/dev/null || true
    fi

    local merged_tmp
    merged_tmp=$(mktemp)
    merge_env_with_s3 "${BACKEND_ENV}" "${dec_tmp}" "${merged_tmp}"
    rm -f "${dec_tmp}"
    mv "${merged_tmp}" "${BACKEND_ENV}"

    if [ -n "${atlas_tmp:-}" ] && [ -s "${atlas_tmp}" ]; then
        append_preserved_mongo_atlas_block "${atlas_tmp}"
        rm -f "${atlas_tmp}"
    fi

    normalize_relay_env_aliases

    log_success "Secrets written to backend/.env"
}

main() {
    echo ""
    log_info "Pulling .env values from S3 (encrypted)..."
    echo ""

    if backend_env_has_assignment_lines; then
        log_info "backend/.env exists — merging S3 secrets (local MONGODB_* / MONGODB_ATLAS_* preserved)."
    fi
    check_prerequisites
    pull_secrets

    echo ""
    log_success "Done. Run './scripts/dev.sh setup' or './scripts/dev.sh start' to use backend/.env"
    echo ""
}

main "$@"
