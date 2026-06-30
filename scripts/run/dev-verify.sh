#!/bin/bash
# Verification entry points. Run via: ./scripts/dev.sh verify [frontend|backend|all]

RUN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${RUN_SCRIPT_DIR}/../lib.sh"

run_frontend_verify() {
    if [ ! -f "${FRONTEND_DIR}/package.json" ]; then
        log_info "Skipping frontend verify (no frontend/package.json — backend-only project)"
        return 0
    fi
    log_info "Running frontend verify..."
    (cd "${FRONTEND_DIR}" && npm run verify)
}

run_backend_verify() {
    if [ ! -f "${BACKEND_DIR}/package.json" ]; then
        log_error "backend/package.json not found"
        return 1
    fi
    log_info "Running backend verify..."
    (cd "${BACKEND_DIR}" && npm run verify)
}

run_backend_verify_merge() {
    if [ ! -f "${BACKEND_DIR}/package.json" ]; then
        log_error "backend/package.json not found"
        return 1
    fi
    if ! node -e "const p=require('${BACKEND_DIR}/package.json'); process.exit(p.scripts && p.scripts['verify:merge'] ? 0 : 1)" 2>/dev/null; then
        log_warning "backend has no verify:merge script; falling back to npm run verify"
        run_backend_verify
        return $?
    fi
    log_info "Running backend verify:merge (no serverless package — spec-kit merge gate)..."
    (cd "${BACKEND_DIR}" && npm run verify:merge)
}

cmd_verify() {
    case "${1:-all}" in
        frontend) run_frontend_verify ;;
        backend) run_backend_verify ;;
        merge)
            run_backend_verify_merge
            run_frontend_verify
            ;;
        all)
            run_backend_verify
            run_frontend_verify
            ;;
        *)
            log_error "Usage: $0 verify [frontend|backend|merge|all]"
            return 1
            ;;
    esac
}

cmd_verify "$1"
