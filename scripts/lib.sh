#!/bin/bash
# Shared utilities for dev scripts. Source from other scripts.

[[ -n "${_LIB_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_LIB_SH_LOADED=1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=local-tools-path.sh
source "${SCRIPT_DIR}/local-tools-path.sh"
PIDS_DIR="${PROJECT_ROOT}/.pids"
LOGS_DIR="${PROJECT_ROOT}/.logs"
BACKEND_DIR="${PROJECT_ROOT}/backend"
FRONTEND_DIR="${PROJECT_ROOT}/frontend"

BACKEND_PID="${PIDS_DIR}/backend.pid"
FRONTEND_PID="${PIDS_DIR}/frontend.pid"
BACKEND_LOG="${LOGS_DIR}/backend.log"
FRONTEND_LOG="${LOGS_DIR}/frontend.log"
CONFIG_FILE="${PROJECT_ROOT}/context/config.json"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
# Company purple (tailwind purple.500 #5630e8) for setup message highlights
PURPLE=$'\033[38;2;86;48;232m'
NC=$'\033[0m'

log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

init_directories() { mkdir -p "${PIDS_DIR}" "${LOGS_DIR}"; }

# Dev ports state file (gitignored via .pids/)
DEV_PORTS_FILE="${PIDS_DIR}/dev-ports"

# Atlas CLI: `atlas projects list` can hang on network/proxy issues; cap wait during setup.
ATLAS_CLI_VERIFY_TIMEOUT_SEC="${ATLAS_CLI_VERIFY_TIMEOUT_SEC:-60}"

# MongoDB Atlas Administration API: cluster name max length (CreateCluster).
# Setup uses names like "${slug}-prod-cluster" (13 chars) — slug must stay within the limit.
ATLAS_CLUSTER_NAME_MAX_LEN=64
# Longest cluster suffix appended to SLUG_LOWER in scripts/initial-setup/mongodb-atlas.sh
ATLAS_CLUSTER_SUFFIX_MAX_LEN=13

# Echo max length for SLUG_LOWER (after slugify) so Atlas cluster names stay ≤ ATLAS_CLUSTER_NAME_MAX_LEN.
atlas_max_slug_len() {
    echo $((ATLAS_CLUSTER_NAME_MAX_LEN - ATLAS_CLUSTER_SUFFIX_MAX_LEN))
}

# Suggested shorter slug for user messaging only (never applied automatically).
atlas_suggest_slug_trim() {
    local slug="$1"
    local max_len trimmed
    max_len=$(atlas_max_slug_len)
    trimmed=$(printf '%s' "$slug" | cut -c1-"$max_len")
    trimmed=$(echo "$trimmed" | sed 's/-\+$//')
    echo "$trimmed"
}

# Returns 0 if port is free, 1 if in use.
is_port_free() {
    local port="$1"
    ! lsof -ti:"$port" &>/dev/null
}

# Find first available port starting from start_port (inclusive). Echo the port.
find_available_port() {
    local start_port="${1:-5000}"
    local port="$start_port"
    while ! is_port_free "$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

# Kill processes on port (macOS/Linux). Only use for *this project's* saved ports on stop.
kill_port() {
    local port="$1"
    local pids
    pids=$(lsof -ti:"$port" 2>/dev/null) || true
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
        return 0
    fi
    return 1
}

# Load saved dev ports into env. No-op if file missing. Returns 0 if file exists.
load_dev_ports() {
    if [ -f "${DEV_PORTS_FILE}" ]; then
        set -a
        # shellcheck source=/dev/null
        source "${DEV_PORTS_FILE}"
        set +a
        return 0
    fi
    return 1
}

# Echo saved port for key (FRONTEND_PORT, BACKEND_HTTP_PORT, BACKEND_LAMBDA_PORT) or empty.
get_saved_port() {
    local key="$1"
    if [ -f "${DEV_PORTS_FILE}" ]; then
        grep "^${key}=" "${DEV_PORTS_FILE}" 2>/dev/null | cut -d= -f2-
    fi
}

# Save dev ports to state file. Call after resolving ports on start.
save_dev_ports() {
    local frontend_port="${1:?}"
    local backend_http_port="${2:?}"
    local backend_lambda_port="${3:?}"
    init_directories
    cat > "${DEV_PORTS_FILE}" << EOF
FRONTEND_PORT=${frontend_port}
BACKEND_HTTP_PORT=${backend_http_port}
BACKEND_LAMBDA_PORT=${backend_lambda_port}
EOF
}

# -----------------------------------------------------------------------------
# Homebrew: install once at start of setup if missing (macOS only)
# -----------------------------------------------------------------------------
ensure_brew() {
    command -v brew &>/dev/null && return 0
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [[ "$os" != "darwin"* ]]; then
        return 0
    fi
    log_info "Homebrew not found. Installing Homebrew..."
    if NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        if command -v brew &>/dev/null; then
            log_success "Homebrew installed"
            return 0
        fi
    fi
    log_error "Homebrew installation failed. Install manually: https://brew.sh"
    exit 1
}

# -----------------------------------------------------------------------------
# Dependency resolution with auto-install (macOS/Linux)
# -----------------------------------------------------------------------------

_get_pkg_for_cmd() {
    local cmd="$1" os="$2"
    case "$cmd" in
        jq)        echo "jq" ;;
        git)       echo "git" ;;
        gh)        echo "gh" ;;
        node)      [ "$os" = "linux" ] && echo "nodejs" || echo "node" ;;
        aws)       echo "awscli" ;;
        atlas)     [[ "$os" == "darwin"* ]] && echo "mongodb-atlas-cli" || echo "" ;;
        docker)    [[ "$os" == "darwin"* ]] && echo "cask/docker" || echo "docker.io" ;;
        *)         echo "$cmd" ;;
    esac
}

_install_via_brew() {
    local pkg="$1"
    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    fi
    if [[ "$pkg" == cask/* ]]; then
        brew install --cask "${pkg#cask/}" || return 1
    else
        brew install "$pkg" || return 1
    fi
}

_install_via_apt() {
    local pkg="$1"
    sudo apt-get update -qq && sudo apt-get install -y "$pkg" || return 1
}

_do_ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}" exit_on_fail="${3:-1}"
    command -v "$cmd" &>/dev/null && return 0

    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    pkg=$(_get_pkg_for_cmd "$cmd" "$os")

    if [ -z "$pkg" ]; then
        log_error "No automatic install for $cmd on this OS"
        [ "$cmd" = "atlas" ] && log_info "On Linux see: docs/mongodb-atlas-setup.md"
        [ "$exit_on_fail" = "1" ] && exit 1
        return 1
    fi

    log_info "Installing $cmd via package manager..."
    if [[ "$os" == "darwin"* ]]; then
        _install_via_brew "$pkg" || true
    elif [[ "$os" == "linux"* ]]; then
        _install_via_apt "$pkg" || true
    else
        log_error "Unsupported OS: $os. Install manually: $cmd"
        [ "$exit_on_fail" = "1" ] && exit 1 || return 1
    fi

    if command -v "$cmd" &>/dev/null; then
        log_success "Installed $cmd"
        [ "$cmd" = "docker" ] && [[ "$os" == "darwin"* ]] && log_info "If 'docker' is not in PATH yet, open Docker Desktop from Applications and retry."
        return 0
    fi

    log_error "Failed to install $cmd"
    if [[ "$os" == "darwin"* ]]; then
        log_info "Try: brew install $pkg"
    elif [[ "$os" == "linux"* ]]; then
        log_info "Try: sudo apt install $pkg"
    fi
    [ "$cmd" = "docker" ] && [[ "$os" == "darwin"* ]] && log_info "If Docker Desktop was installed, open it from Applications so the docker CLI is available."
    [ "$cmd" = "gh" ] && log_info "Or run: ./scripts/install-gh.sh"
    [ "$cmd" = "gh" ] && log_info "See: https://cli.github.com"
    [ "$cmd" = "atlas" ] && log_info "See: docs/mongodb-atlas-setup.md"
    [ "$exit_on_fail" = "1" ] && exit 1 || return 1
}

ensure_cmd() {
    _do_ensure_cmd "${1:?}" "${2:-$1}" 1
}

try_ensure_cmd() {
    _do_ensure_cmd "${1:?}" "${2:-$1}" 0
}

# -----------------------------------------------------------------------------
# JSON helper: jq when available, else Node.js (so deploy/setup works on Windows without jq)
# Usage: json_get <file> <path> [default]
#   path: dot path e.g. .projectName or .subdomainName
#   default: optional; if value is missing/null/empty, output this (like jq // "default")
# On Windows install jq via: winget install jqlang.jq
# -----------------------------------------------------------------------------
json_get() {
    local file="${1:?}" path="${2:?}" default="${3:-}"
    if command -v jq &>/dev/null; then
        if [ -n "$default" ]; then
            jq -r --arg d "$default" "${path} // \$d" "$file" 2>/dev/null || echo "$default"
        else
            jq -r "${path} // empty" "$file" 2>/dev/null || true
        fi
        return
    fi
    node -e "
    var fs = require('fs');
    var file = process.argv[1];
    var path = process.argv[2].replace(/^\\./, '').split('.');
    var def = process.argv[3];
    var o;
    try { o = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { process.exit(1); }
    var v = o;
    for (var i = 0; i < path.length; i++) { v = v && v[path[i]]; }
    if (v === undefined || v === null) v = def;
    if (v === undefined || v === null) v = '';
    console.log(String(v));
    " "$file" "$path" "$default" 2>/dev/null || echo "$default"
}

# Host label for S3 / CloudFront / deploy URLs: when clientName is 49x (internal), strip one leading
# "49x-" from subdomainName (case-insensitive) so the site is e.g. kratos-test.49x.ai not 49x-kratos-test.49x.ai.
effective_deploy_subdomain_from_values() {
    local client sub sub_lower
    client=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')
    sub="${2:-}"
    [ -z "$sub" ] && return 0
    sub_lower=$(echo "$sub" | tr '[:upper:]' '[:lower:]')
    if [ "$client" = "49x" ] && [ "$sub_lower" != "${sub_lower#49x-}" ]; then
        echo "${sub:4}"
    else
        echo "$sub"
    fi
}

# Reads context/config.json; empty subdomain becomes "default" before applying internal-client strip.
effective_deploy_subdomain() {
    local config_file="${1:?}"
    local client sub
    client=$(json_get "$config_file" ".clientName" "")
    sub=$(json_get "$config_file" ".subdomainName" "")
    [ -z "$sub" ] && sub="default"
    effective_deploy_subdomain_from_values "$client" "$sub"
}

# -----------------------------------------------------------------------------
# Device-level credentials: script saves after first login, restores on later runs
# so developers don't re-login when the repo is moved/deleted/recreated.
# Path is outside the repo: macOS, Windows, or Linux (XDG) app config location.
# -----------------------------------------------------------------------------

# Echo the device config directory (no trailing slash). Use for Atlas, AWS CLI backups, etc.
get_device_config_dir() {
    if [[ -n "${APPDATA:-}" ]]; then
        # Windows (Git Bash, Cygwin, or WSL with APPDATA set)
        echo "${APPDATA}/kratos"
    else
        local os
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        if [[ "$os" == "darwin"* ]]; then
            echo "${HOME}/Library/Application Support/kratos"
        else
            echo "${XDG_CONFIG_HOME:-${HOME}/.config}/kratos"
        fi
    fi
}

# Echo the Atlas CLI config directory for this platform (no trailing slash).
get_atlas_config_dir() {
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [[ "$os" == "darwin"* ]]; then
        echo "${HOME}/Library/Application Support/atlascli"
    else
        echo "${XDG_CONFIG_HOME:-${HOME}/.config}/atlascli"
    fi
}

# Restore previously saved Atlas credentials so Atlas CLI sees them. No-op if nothing saved.
# If atlas_api_keys.env exists in device config, export MONGODB_ATLAS_*_API_KEY so the CLI
# uses API key auth (no interactive login, no session expiry).
# If MONGODB_ATLAS_PUBLIC_API_KEY and MONGODB_ATLAS_PRIVATE_API_KEY are already set
# (e.g. from backend/.env after S3 decrypt), skip loading from device config.
restore_atlas_saved_credentials() {
    local atlas_dir saved_dir
    atlas_dir=$(get_atlas_config_dir)
    saved_dir="$(get_device_config_dir)/atlascli"
    # API keys allow automatic auth without interactive login or session expiry
    # Skip device config if keys already set (e.g. from backend/.env)
    if [ -z "${MONGODB_ATLAS_PUBLIC_API_KEY:-}" ] || [ -z "${MONGODB_ATLAS_PRIVATE_API_KEY:-}" ]; then
        if [ -f "${saved_dir}/atlas_api_keys.env" ] && [ -r "${saved_dir}/atlas_api_keys.env" ]; then
            set -a
            # shellcheck source=/dev/null
            source "${saved_dir}/atlas_api_keys.env"
            set +a
            if [ -n "${MONGODB_ATLAS_PUBLIC_API_KEY:-}" ] && [ -n "${MONGODB_ATLAS_PRIVATE_API_KEY:-}" ]; then
                log_success "Loaded Atlas API keys (automatic auth, no login required)"
            fi
        fi
    fi
    # When API keys are set (e.g. from backend/.env / S3 secrets), do NOT copy config.toml or session files.
    # The saved config may have auth_type='user_account' with an expired session, which causes
    # "unauthorized" before the CLI falls back to env vars. Clear any existing config so the CLI uses env vars only.
    if [ -n "${MONGODB_ATLAS_PUBLIC_API_KEY:-}" ] && [ -n "${MONGODB_ATLAS_PRIVATE_API_KEY:-}" ]; then
        if [ -f "${atlas_dir}/config.toml" ]; then
            rm -f "${atlas_dir}/config.toml" "${atlas_dir}/rstate.yaml" "${atlas_dir}/brew.yaml" 2>/dev/null || true
        fi
        return 0
    fi
    if [ -f "${saved_dir}/config.toml" ] && [ -r "${saved_dir}/config.toml" ]; then
        mkdir -p "${atlas_dir}"
        cp -f "${saved_dir}/config.toml" "${atlas_dir}/config.toml" 2>/dev/null || true
        # Copy any other files (e.g. token cache) if present; skip atlas_api_keys.env
        for f in "${saved_dir}"/*; do
            [ -e "$f" ] && [ -f "$f" ] && [ "$(basename "$f")" != "config.toml" ] && [ "$(basename "$f")" != "atlas_api_keys.env" ] && cp -f "$f" "${atlas_dir}/" 2>/dev/null || true
        done
        log_success "Loaded saved Atlas credentials (no login required)"
    fi
}

# Save current Atlas CLI credentials so future runs (e.g. new projects) can restore them.
save_atlas_credentials() {
    local atlas_dir saved_dir
    atlas_dir=$(get_atlas_config_dir)
    saved_dir="$(get_device_config_dir)/atlascli"
    if [ -f "${atlas_dir}/config.toml" ] && [ -r "${atlas_dir}/config.toml" ]; then
        mkdir -p "${saved_dir}"
        cp -f "${atlas_dir}/config.toml" "${saved_dir}/config.toml" 2>/dev/null || true
        for f in "${atlas_dir}"/*; do
            [ -e "$f" ] && [ -f "$f" ] && [ "$(basename "$f")" != "config.toml" ] && cp -f "$f" "${saved_dir}/" 2>/dev/null || true
        done
        log_success "Saved Atlas credentials for future projects"
    fi
}

# Validate Atlas session with a real API call (whoami can pass with expired token).
# Prefer API key auth (restore_atlas_saved_credentials); if that fails or no keys, fall back to interactive
# login when a TTY is available. Only exit without login when non-interactive and no TTY.
ensure_atlas_session() {
    local err_file atlas_rc=0
    err_file=$(mktemp)
    run_with_timeout "${ATLAS_CLI_VERIFY_TIMEOUT_SEC}" atlas projects list -o json >/dev/null 2>"$err_file" || atlas_rc=$?
    if [ "$atlas_rc" -eq 0 ]; then
        rm -f "$err_file"
        return 0
    fi
    local err_content
    err_content=$(cat "$err_file" 2>/dev/null)
    rm -f "$err_file"
    if [ "$atlas_rc" -eq 124 ]; then
        log_error "MongoDB Atlas CLI timed out after ${ATLAS_CLI_VERIFY_TIMEOUT_SEC}s while listing projects (network, proxy, or VPN?)."
        log_info "Try when online: atlas projects list -o json   Then re-run: ./scripts/dev.sh setup"
        exit 1
    fi
    if [ "${MONGODB_ATLAS_NONINTERACTIVE:-0}" = "1" ] && [ ! -t 0 ]; then
        log_error "Atlas authentication failed (setup is non-interactive; cannot run atlas auth login)."
        [ -n "$err_content" ] && echo "$err_content" | sed 's/^/  /' >&2
        log_info "Use Atlas API keys so setup can authenticate without prompts:"
        log_info "  1. Create API keys in Atlas: Organization → Access Manager → API Keys (with Organization Project Creator or Project Read/Write)."
        log_info "  2. Add to: $(get_device_config_dir)/atlascli/atlas_api_keys.env"
        log_info "     MONGODB_ATLAS_PUBLIC_API_KEY=... and MONGODB_ATLAS_PRIVATE_API_KEY=..."
        log_info "  See: docs/kratos/mongodb-atlas-setup.md"
        exit 1
    fi
    # With a TTY: run interactive login on auth failure. Only fall back when API keys are absent or invalid.
    if [ -t 0 ]; then
        if [ "${MONGODB_ATLAS_NONINTERACTIVE:-0}" = "1" ]; then
            if [ -n "${MONGODB_ATLAS_PUBLIC_API_KEY:-}" ] && [ -n "${MONGODB_ATLAS_PRIVATE_API_KEY:-}" ]; then
                log_info "Atlas API keys from backend/.env or device config are invalid or expired; falling back to interactive login."
            else
                log_info "Atlas API keys not available (add to backend/.env or device config); falling back to interactive login."
            fi
        fi
        if echo "$err_content" | grep -qi "session expired"; then
            log_warning "Atlas session expired. You need to sign in again."
        else
            log_warning "Not authenticated to Atlas (no API keys or invalid session). Sign in to continue."
            [ -n "$err_content" ] && echo "$err_content" | sed 's/^/  /' >&2
        fi
        log_info "Running: atlas auth login"
        log_info "Tip: To avoid future logins and the kratos prompt, use Atlas API keys in $(get_device_config_dir)/atlascli/atlas_api_keys.env"
        echo ""
        if ! atlas auth login; then
            log_error "Login failed or was cancelled"
            exit 1
        fi
        log_success "Logged in. Saving credentials for future runs..."
        save_atlas_credentials
        echo ""
        # Verify session after login
        local verify_rc=0
        run_with_timeout "${ATLAS_CLI_VERIFY_TIMEOUT_SEC}" atlas projects list -o json >/dev/null 2>/dev/null || verify_rc=$?
        if [ "$verify_rc" -eq 0 ]; then
            return 0
        fi
        if [ "$verify_rc" -eq 124 ]; then
            log_error "Atlas projects list timed out after login (${ATLAS_CLI_VERIFY_TIMEOUT_SEC}s). Check network and re-run: ./scripts/dev.sh setup"
            return 1
        fi
        log_error "Atlas login succeeded but projects list still failed. Re-run setup or check your Atlas access."
        return 1
    fi
    log_error "Not interactive (no TTY). Run: atlas auth login"
    log_info "Or set MONGODB_ATLAS_PUBLIC_API_KEY and MONGODB_ATLAS_PRIVATE_API_KEY (see docs/kratos/mongodb-atlas-setup.md)"
    [ -n "$err_content" ] && echo "$err_content" | sed 's/^/  /' >&2
    exit 1
}

# Restore saved AWS CLI credentials from device so setup doesn't prompt if we have a backup.
# AWS uses ~/.aws/credentials and ~/.aws/config; we copy those from device storage when present.
restore_aws_saved_credentials() {
    local aws_home saved_dir
    aws_home="${HOME}/.aws"
    saved_dir="$(get_device_config_dir)/aws"
    if [ -d "$saved_dir" ] && [ -f "${saved_dir}/credentials" ] && [ -r "${saved_dir}/credentials" ]; then
        mkdir -p "$aws_home"
        cp -f "${saved_dir}/credentials" "${aws_home}/credentials" 2>/dev/null || true
        [ -f "${saved_dir}/config" ] && [ -r "${saved_dir}/config" ] && cp -f "${saved_dir}/config" "${aws_home}/config" 2>/dev/null || true
        log_success "Loaded saved AWS credentials (no login required)"
    fi
}

# Save current AWS CLI credentials so future runs (e.g. new projects or after expiry) can restore them.
save_aws_credentials() {
    local aws_home saved_dir
    aws_home="${HOME}/.aws"
    saved_dir="$(get_device_config_dir)/aws"
    if [ -f "${aws_home}/credentials" ] && [ -r "${aws_home}/credentials" ]; then
        mkdir -p "$saved_dir"
        cp -f "${aws_home}/credentials" "${saved_dir}/credentials" 2>/dev/null || true
        [ -f "${aws_home}/config" ] && [ -r "${aws_home}/config" ] && cp -f "${aws_home}/config" "${saved_dir}/config" 2>/dev/null || true
        log_success "Saved AWS credentials for future projects"
    fi
}

# Restore saved credentials before running Atlas/AWS steps. Call at start of setup.
load_device_credentials() {
    restore_atlas_saved_credentials
    restore_aws_saved_credentials
}

# Run a command with a timeout (avoids hang on stuck CLI / network calls).
# Uses timeout(1) or gtimeout(1) when available; otherwise a sleep+kill watchdog (macOS has no timeout by default).
run_with_timeout() {
    local seconds="$1"
    shift
    if command -v gtimeout &>/dev/null; then
        gtimeout "$seconds" "$@"
        return $?
    fi
    if command -v timeout &>/dev/null; then
        timeout "$seconds" "$@"
        return $?
    fi
    (
        set +m
        "$@" &
        _rwt_child_pid=$!
        (
            sleep "$seconds"
            kill -TERM "$_rwt_child_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$_rwt_child_pid" 2>/dev/null || true
        ) &
        _rwt_watchdog_pid=$!
        _rwt_wait_status=0
        wait "$_rwt_child_pid" || _rwt_wait_status=$?
        kill -TERM "$_rwt_watchdog_pid" 2>/dev/null || true
        wait "$_rwt_watchdog_pid" 2>/dev/null || true
        # GNU timeout uses 124; SIGTERM/SIGKILL wait statuses mean the watchdog stopped a hung child
        if [ "$_rwt_wait_status" -eq 143 ] || [ "$_rwt_wait_status" -eq 137 ]; then
            exit 124
        fi
        exit "$_rwt_wait_status"
    )
    return $?
}
