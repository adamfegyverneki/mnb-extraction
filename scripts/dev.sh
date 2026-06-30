#!/bin/bash

#############################################################################
# Development Management Script (Orchestrator)
#
# Manages backend (Node.js) and frontend (React).
# Usage: ./scripts/dev.sh [command] [component]
#
# If you get "Permission denied": run   chmod +x scripts/dev.sh
# or use bash instead:                   bash scripts/dev.sh setup
#
# Commands:
#   setup       First-time setup (config.json, .env; S3 secrets pull — see docs/kratos/s3-secrets-setup.md)
#   start       Start backend + frontend (or specific component)
#   stop        Stop components
#   restart     Restart components
#   status      Check status
#   logs             View logs (requires: backend|frontend)
#   logs-be          Tail CloudWatch logs for deployed serverless backend (all Lambdas)
#   docker-logs      Tail CloudWatch logs for deployed Docker worker Lambda (optional: list|help)
#   docker-logs-local Tail logs of locally running Docker container (optional: name e.g. scraper)
#   db          Database management (MongoDB Atlas)
#   verify      Run verification gates (frontend|backend|all)
#   deploy          Full deploy: verify, then either fast (backend+frontend build in parallel) or 3-step sequential when not ready
#   deploy-status   Preview whether deploy will use fast or sequential path
#   deploy-parallel Same as fast path only; error if VITE_API_URL is missing from frontend/.env_prod
#   deploy-staging  Staging deploy (main or develop branch)
#   deploy-be       Deploy backend (serverless: npm run deploy)
#   deploy-fe       Build frontend + upload to S3
#   post-deploy     Capture API Gateway URL after backend deploy
#   posthog-register Create/update PostHog project env + default analytics dashboard
#   relay-setup     Apply export/relay-email/backend/.env + register route (one shot)
#   relay-register  Provision Relay route (outbound-ready; no deploy required)
#   relay-status    Verify Relay route exists for RELAY_PROJECT_NAME
#   docker-deploy Build/push Docker image to ECR, create/update worker Lambda (optional: command, path)
#   dash          Start kratOS developer dashboard (UI: localhost:6002)
#   help          Show help
#############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

cmd_help() {
    cat << EOF

${BLUE}Development Script${NC} - Backend + Frontend

${YELLOW}USAGE:${NC}  ./scripts/dev.sh [command] [component]
  (If Permission denied:  chmod +x scripts/dev.sh   or use  bash scripts/dev.sh <command>)

${YELLOW}COMMANDS:${NC}
  setup         First-time setup (config.json, .env; S3 secrets decrypt into backend/.env; infra on first deploy)
  start [all]   Start backend + frontend (or backend|frontend)
  stop [all]    Stop components
  restart       Restart
  status        Show status
  logs <comp>        Tail logs (backend|frontend)
  logs-be            Tail CloudWatch logs for deployed backend (all Lambdas). Ctrl+C to stop.
  docker-logs [service] [cmd]  Tail CloudWatch logs for deployed Docker Lambda (service: scraper; cmd: list|help)
  docker-logs-local [name]  Tail logs of locally running Docker container (name e.g. scraper)
  db            MongoDB (test|seed|status)
  verify [all]  Run verification gates (frontend|backend|merge|all)
  deploy          Production deploy: verify, then auto fast path (backend + frontend build in parallel) or full 3-step; see .cursor/rules/deploy.mdc
  deploy-status   Preview deploy path and first-time infra detection without deploying
  deploy-parallel Fast path only: fails if VITE_API_URL is not in frontend/.env_prod; otherwise same as the parallel phase of deploy
  deploy-staging  Staging deploy (main or develop → Atlas staging → data sync → backend/frontend)
  deploy-be       Deploy backend (serverless)
  deploy-fe       Build frontend + upload to S3
  post-deploy     Capture API Gateway URL after backend deploy
  posthog-register Create/update PostHog project env + default analytics dashboard
  relay-setup     Apply export/relay-email/backend/.env + provision route (no deploy required)
  relay-register  Provision Relay route via management API (see docs/kratos/relay-email-integration.md)
  relay-status    Verify active Relay route for RELAY_PROJECT_NAME
  docker-deploy [cmd] [name]  Docker: build/push to ECR, create/update worker Lambda (default: deploy, name e.g. scraper). See scripts/docker/README.md
  dash          Start kratOS developer dashboard (UI: http://localhost:6002)
  help          This help

${YELLOW}WORKFLOW:${NC}
  1. Get MongoDB Atlas invite and KRATOS_SECRETS_KEY (see docs/kratos/s3-secrets-setup.md). Atlas API keys in the S3 bundle land in backend/.env during setup (or run atlas auth login).
  2. ./scripts/dev.sh setup          # Pulls S3 secrets, creates Atlas cluster, npm install, git (infra created on first deploy)
  3. ./scripts/dev.sh start          # Start both (uses first free ports; stores them in .pids/dev-ports)
  4. Open the URL from: ./scripts/dev.sh status   # e.g. http://localhost:5000

${YELLOW}DEPLOY:${NC}
  ./scripts/dev.sh verify all        # Run repo verification gates
  ./scripts/dev.sh deploy-status     # Preview fast vs sequential deploy decision
  ./scripts/dev.sh deploy            # See docs/kratos/deployment.md (auto fast when .env_prod is ready)
  Or step by step: deploy-be → post-deploy → deploy-fe
  ./scripts/dev.sh deploy-parallel   # Only when you already have VITE_API_URL in frontend/.env_prod

EOF
}

main() {
    case "${1:-help}" in
        setup)
            bash "${SCRIPT_DIR}/initial-setup/kratos-setup.sh"
            ;;
        start)       bash "${SCRIPT_DIR}/run/dev-process.sh" start "$2" ;;
        stop)        bash "${SCRIPT_DIR}/run/dev-process.sh" stop "$2" ;;
        restart)     bash "${SCRIPT_DIR}/run/dev-process.sh" restart "$2" ;;
        status)      bash "${SCRIPT_DIR}/run/dev-process.sh" status ;;
        logs)        bash "${SCRIPT_DIR}/run/dev-process.sh" logs "$2" ;;
        logs-be)     bash "${SCRIPT_DIR}/run/serverless-logs.sh" ;;
        docker-logs) bash "${SCRIPT_DIR}/docker/docker-logs.sh" "$2" ;;
        docker-logs-local) bash "${SCRIPT_DIR}/docker/docker-logs-local.sh" "$2" ;;
        db)          bash "${SCRIPT_DIR}/run/dev-db.sh" "$2" ;;
        verify)      bash "${SCRIPT_DIR}/run/dev-verify.sh" "${2:-all}" ;;
        deploy)   bash "${SCRIPT_DIR}/run/dev-deploy.sh" deploy ;;
        deploy-status) bash "${SCRIPT_DIR}/run/dev-deploy.sh" deploy-status ;;
        deploy-parallel) bash "${SCRIPT_DIR}/run/dev-deploy.sh" deploy-parallel ;;
        deploy-be|deploy-backend) bash "${SCRIPT_DIR}/run/dev-deploy.sh" deploy-be ;;
        deploy-fe|deploy-frontend) bash "${SCRIPT_DIR}/run/dev-deploy.sh" deploy-fe ;;
        post-deploy) bash "${SCRIPT_DIR}/run/dev-deploy.sh" post-deploy ;;
        posthog-register) node "${SCRIPT_DIR}/posthog/register-project.js" ;;
        relay-setup)
            bash "${PROJECT_ROOT}/export/relay-email/scripts/setup-relay.sh" "$@"
            ;;
        relay-register)
            DOTENV_CONFIG_PATH="${PROJECT_ROOT}/backend/.env" \
            NODE_PATH="${PROJECT_ROOT}/backend/node_modules" \
            node "${SCRIPT_DIR}/relay/register-or-verify-route.js" --provision --verify
            ;;
        relay-status)
            DOTENV_CONFIG_PATH="${PROJECT_ROOT}/backend/.env" \
            NODE_PATH="${PROJECT_ROOT}/backend/node_modules" \
            node "${SCRIPT_DIR}/relay/register-or-verify-route.js" --verify
            ;;
        deploy-staging) bash "${SCRIPT_DIR}/run/dev-deploy.sh" deploy-staging ;;
        docker-deploy) bash "${SCRIPT_DIR}/docker/docker-deploy.sh" "$2" "$3" ;;
        dash)        bash "${SCRIPT_DIR}/run/dev-dash.sh" ;;
        help|--help|-h) cmd_help ;;
        *)
            log_error "Unknown command: $1"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
