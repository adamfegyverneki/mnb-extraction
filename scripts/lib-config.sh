#!/bin/bash
# Config utilities for dev scripts. Depends on lib.sh.
# All env/config lives in backend/.env.

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BACKEND_ENV="${BACKEND_DIR}/.env"

load_backend_env() {
    if [ ! -f "${BACKEND_ENV}" ]; then
        log_error "Backend env not found: ${BACKEND_ENV}"
        log_info "Run: ./scripts/dev.sh setup"
        return 1
    fi
    set -a; source "${BACKEND_ENV}"; set +a
}

get_mode() { grep "^${1}=" "${BACKEND_ENV}" 2>/dev/null | cut -d= -f2-; }

# True when create-plan wrote context/config.json → relay (email in spec scope).
project_relay_configured() {
    local v
    [ -f "${CONFIG_FILE}" ] || return 1
    for v in \
        "$(json_get "${CONFIG_FILE}" ".relay.mailboxPrefix" "")" \
        "$(json_get "${CONFIG_FILE}" ".relay.projectName" "")" \
        "$(json_get "${CONFIG_FILE}" ".relay.inboundEmail" "")"; do
        v=$(printf '%s' "$v" | tr -d '\r' | xargs)
        [ -n "$v" ] && [ "$v" != "null" ] && return 0
    done
    return 1
}

# Read a single key from backend/.env (first occurrence, value after first =). Safe for special chars.
_get_backend_env() { grep "^${1}=" "${BACKEND_ENV}" 2>/dev/null | head -1 | cut -d= -f2-; }

# Default 49x central auth origin (browser; OAuth init/me/logout on same host as deployed). Override with VITE_AUTH_API_BASE in backend/.env.
DEFAULT_CENTRAL_AUTH_API_BASE="https://auth.49x.ai"

# Escape a value for use inside double quotes in a .env line.
escape_for_double_quoted_env_value() {
    printf '%s' "$1" | sed 's/\r//g' | sed 's/\\/\\\\/g;s/"/\\"/g;s/\$/\\$/g'
}

# Prints origin to use for VITE_AUTH_API_BASE. Exit 1 = omit variable (explicit empty in backend/.env).
emit_vite_auth_api_base_value() {
    local envf="${BACKEND_ENV}"
    local line val
    if [ ! -f "$envf" ]; then
        echo "$DEFAULT_CENTRAL_AUTH_API_BASE"
        return 0
    fi
    line=$(grep -E '^[[:space:]]*VITE_AUTH_API_BASE=' "$envf" 2>/dev/null | head -1) || true
    if [ -z "$line" ]; then
        echo "$DEFAULT_CENTRAL_AUTH_API_BASE"
        return 0
    fi
    val="${line#*=}"
    val=$(printf '%s' "$val" | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r' | xargs)
    if [ -z "$val" ]; then
        return 1
    fi
    printf '%s' "$val"
    return 0
}

# PostHog browser SDK (optional). Exit 1 if key missing or empty.
emit_vite_posthog_key_value() {
    local val
    val="$(_get_backend_env VITE_POSTHOG_KEY)"
    val=$(printf '%s' "$val" | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r' | xargs)
    [ -z "$val" ] && return 1
    printf '%s' "$val"
    return 0
}

# Optional ingest host. Exit 1 if missing or empty (US default applied in frontend when unset).
emit_vite_posthog_host_value() {
    local val
    val="$(_get_backend_env VITE_POSTHOG_HOST)"
    val=$(printf '%s' "$val" | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r' | xargs)
    [ -z "$val" ] && return 1
    printf '%s' "$val"
    return 0
}

emit_vite_posthog_flag_value() {
    local key="$1"
    local val
    val="$(_get_backend_env "$key")"
    val=$(printf '%s' "$val" | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r' | xargs)
    [ -z "$val" ] && return 1
    printf '%s' "$val"
    return 0
}

# Prints projectName for VITE_APP_NAME. Exit 1 if missing or unusable.
emit_vite_app_name_value() {
    local pn
    [ -f "${CONFIG_FILE}" ] || return 1
    pn=$(jq -r '.projectName // ""' "${CONFIG_FILE}" 2>/dev/null) || return 1
    pn=$(printf '%s' "$pn" | tr -d '\r' | xargs)
    [ -z "$pn" ] || [ "$pn" = "null" ] && return 1
    printf '%s' "$pn"
    return 0
}

# Overwrite outfile with VITE_API_URL, optional VITE_STREAM_API_URL, VITE_AUTH_API_BASE (unless opted out), optional VITE_FULL_PAGE_CENTRAL_LOGOUT, VITE_APP_NAME, optional PostHog VITE_*.
write_merged_frontend_env() {
    local outfile="$1"
    local api_url="$2"
    local stream_url="${3:-}"
    local esc auth_val app_val ph_key ph_host ph_autocapture ph_replay
    {
        esc=$(escape_for_double_quoted_env_value "$api_url")
        echo "VITE_API_URL=\"$esc\""
        if [ -n "$stream_url" ]; then
            esc=$(escape_for_double_quoted_env_value "$stream_url")
            echo "VITE_STREAM_API_URL=\"$esc\""
        fi
        if auth_val=$(emit_vite_auth_api_base_value); then
            esc=$(escape_for_double_quoted_env_value "$auth_val")
            echo "VITE_AUTH_API_BASE=\"$esc\""
        fi
        if fp_val=$(emit_vite_posthog_flag_value VITE_FULL_PAGE_CENTRAL_LOGOUT); then
            esc=$(escape_for_double_quoted_env_value "$fp_val")
            echo "VITE_FULL_PAGE_CENTRAL_LOGOUT=\"$esc\""
        fi
        if app_val=$(emit_vite_app_name_value); then
            esc=$(escape_for_double_quoted_env_value "$app_val")
            echo "VITE_APP_NAME=\"$esc\""
        fi
        if ph_key=$(emit_vite_posthog_key_value); then
            esc=$(escape_for_double_quoted_env_value "$ph_key")
            echo "VITE_POSTHOG_KEY=\"$esc\""
            if ph_host=$(emit_vite_posthog_host_value); then
                esc=$(escape_for_double_quoted_env_value "$ph_host")
                echo "VITE_POSTHOG_HOST=\"$esc\""
            fi
            if ph_autocapture=$(emit_vite_posthog_flag_value VITE_POSTHOG_AUTOCAPTURE); then
                esc=$(escape_for_double_quoted_env_value "$ph_autocapture")
                echo "VITE_POSTHOG_AUTOCAPTURE=\"$esc\""
            fi
            if ph_replay=$(emit_vite_posthog_flag_value VITE_POSTHOG_SESSION_REPLAY); then
                esc=$(escape_for_double_quoted_env_value "$ph_replay")
                echo "VITE_POSTHOG_SESSION_REPLAY=\"$esc\""
            fi
        fi
    } > "$outfile"
}

generate_frontend_env() {
    local mode="${1:-local}"
    local api_url
    if [ "$mode" = "prod" ]; then
        api_url="$(_get_backend_env PROD_BACKEND_URL)"
        [ -z "$api_url" ] && api_url="http://localhost:4000"
    else
        # Prefer current dev port (set by dev-process after resolve_and_save_ports)
        if [ -n "${BACKEND_HTTP_PORT:-}" ]; then
            api_url="http://localhost:${BACKEND_HTTP_PORT}"
        else
            api_url="$(_get_backend_env LOCAL_BACKEND_URL)"
            [ -z "$api_url" ] && api_url="http://localhost:4000"
        fi
    fi
    mkdir -p "${FRONTEND_DIR}"
    write_merged_frontend_env "${FRONTEND_DIR}/.env.tmp" "$api_url" ""
    {
        echo "# Generated by dev.sh - Run ./scripts/dev.sh setup to update"
        echo "# Mode: ${mode}"
        cat "${FRONTEND_DIR}/.env.tmp"
    } > "${FRONTEND_DIR}/.env"
    rm -f "${FRONTEND_DIR}/.env.tmp"
}

show_config_dashboard() {
    if [ ! -f "${BACKEND_ENV}" ]; then
        log_error "Backend .env not found"
        return 1
    fi
    load_dev_ports 2>/dev/null || true
    local mongodb_host be_port fe_port
    mongodb_host=$(grep "^MONGODB_URI=" "${BACKEND_ENV}" 2>/dev/null | sed 's/.*@\([^/]*\).*/\1/' | cut -d'?' -f1)
    be_port="${BACKEND_HTTP_PORT:-4000}"
    fe_port="${FRONTEND_PORT:-5000}"
    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║           Configuration                  ║"
    echo "╠═══════════════════════════════════════════╣"
    echo -e "║  MongoDB  │ ${mongodb_host:-MongoDB Atlas}"
    echo -e "║  Backend  │ ${GREEN}http://localhost:${be_port}${NC}"
    echo -e "║  Frontend │ ${GREEN}http://localhost:${fe_port}${NC}"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
}
