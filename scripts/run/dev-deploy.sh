#!/bin/bash
# Deploy commands. Run via: ./scripts/dev.sh deploy|deploy-parallel|deploy-be|deploy-fe|post-deploy|deploy-staging

RUN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${RUN_SCRIPT_DIR}/../lib.sh"
# shellcheck source=../lib-config.sh
source "${RUN_SCRIPT_DIR}/../lib-config.sh"
# shellcheck source=../initial-setup/sync-infra-config.sh
source "${RUN_SCRIPT_DIR}/../initial-setup/sync-infra-config.sh"
# shellcheck source=../initial-setup/config-prompts.sh
source "${RUN_SCRIPT_DIR}/../initial-setup/config-prompts.sh"

CONFIG_FILE="${PROJECT_ROOT}/context/config.json"
# Prod/staging site domain for this template (not stored in context/config.json).
KRATOS_DEPLOY_DOMAIN_BASE="49x.ai"

# Staging hostname label (S3/CloudFront/Route53) — must match infra/lib/stagingSiteLabel.ts.
# Prod host label: raw subdomainName in config.json, except internal client 49x gets a leading 49x- stripped
# for URLs/buckets (see effective_deploy_subdomain in lib.sh). Staging prefixes staging- at deploy time.
staging_site_label() {
    local sub="$1"
    [ -n "$sub" ] || return 1
    echo "staging-${sub}"
}

# CloudFormation stack: same pattern as prod ({stage}-{sub}-infra), not {stage}-{stagingLabel}-infra
# (would yield staging-staging-{sub}-infra). Must match infra/sst.config.ts stackName.
staging_infra_stack_name() {
    local sub="$1"
    [ -n "$sub" ] || return 1
    echo "staging-${sub}-infra"
}

# Ensure deploy config is filled and infra stack exists; on first deploy, prompt for domain/deploy options and deploy infra.
ensure_infra_ready() {
    ensure_deploy_config
    local sub stack_name
    sub=$(effective_deploy_subdomain "$CONFIG_FILE")
    [ -n "$sub" ] || { log_error "subdomainName missing in context/config.json"; exit 1; }
    stack_name="prod-${sub}-infra"
    if ! aws cloudformation describe-stacks --stack-name "$stack_name" --region eu-central-1 --query "Stacks[0].StackName" --output text &>/dev/null; then
        echo ""
        echo -e "${CYAN}  First-time deploy: infra stack not found. Deploying infra (S3, CloudFront, Route53)${NC}"
        echo ""
        if ! sync_infra_config; then
            log_error "Could not sync infra config from context/config.json. Check infra/ and config.json."
            exit 1
        fi
        log_info "Installing infra dependencies..."
        (cd "${PROJECT_ROOT}/infra" && npm install --no-audit --no-fund) || { log_error "Infra npm install failed."; exit 1; }
        log_info "Deploying infra (stage prod)..."
        if ! (cd "${PROJECT_ROOT}/infra" && npm run deploy -- --stage prod); then
            log_error "Infra deploy failed. Fix the errors above, then run deploy again."
            exit 1
        fi
        log_success "Infra deployed (S3, CloudFront, Route53)"
        echo ""
    fi
}

# Require that the current git branch is the stable branch (main) before deploying.
# Deployments always come from a stable, released state — not from develop.
require_main_branch() {
    if ! git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
        return 0  # not a git repo; skip check
    fi
    local branch
    branch=$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        return 0  # detached HEAD; skip check
    fi
    local stable_branch="main"
    if [ -f "${PROJECT_ROOT}/.kratos/git-policy.json" ]; then
        if command -v jq &>/dev/null; then
            stable_branch=$(jq -r '.stableBranch // "main"' "${PROJECT_ROOT}/.kratos/git-policy.json" 2>/dev/null || echo "main")
        fi
    fi
    if [ "$branch" != "$stable_branch" ]; then
        log_error "Deploy is only allowed from the '${stable_branch}' branch."
        log_error "Current branch: ${branch}"
        echo ""
        log_info "To deploy, release your work first:"
        log_info "  1. Run the 'release-version' command to update CHANGELOG.md + VERSION and open a PR."
        log_info "  2. Merge the release PR into '${stable_branch}'."
        log_info "  3. Switch to '${stable_branch}': git checkout ${stable_branch} && git pull"
        log_info "  4. Then run: ./scripts/dev.sh deploy"
        echo ""
        exit 1
    fi
}

# Set SERVERLESS_DEPLOYMENT_BUCKET and FRONTEND_ORIGIN from config/infra (for backend deploy and CORS).
set_deploy_env() {
    local sub domain_base stack_name bucket
    sub=$(effective_deploy_subdomain "$CONFIG_FILE")
    if [ -z "$sub" ]; then
        log_error "subdomainName missing in context/config.json"
        exit 1
    fi
    domain_base="$KRATOS_DEPLOY_DOMAIN_BASE"
    export FRONTEND_ORIGIN="https://${sub}.${domain_base}"

    stack_name="prod-${sub}-infra"
    bucket=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region eu-central-1 \
        --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text 2>/dev/null) || true
    bucket=$(echo "$bucket" | tr -d '\r')
    if [ -z "$bucket" ]; then
        log_error "Could not get BucketName from infra stack \"$stack_name\"."
        log_info "Run infra deploy first: cd infra && npm run deploy -- --stage prod"
        exit 1
    fi
    export SERVERLESS_DEPLOYMENT_BUCKET="$bucket"
    export APP_VERSION
    APP_VERSION=$(cat "${PROJECT_ROOT}/VERSION" 2>/dev/null | tr -d '\n' || echo 'unknown')
}

# Production Lambdas use a dedicated DB name (and usually a dedicated cluster URI), same pattern as staging.
# Prefer MONGODB_URI_PRODUCTION + MONGODB_DB_NAME_PRODUCTION from backend/.env; export MONGODB_* for Serverless
# and write .env.prod (Serverless useDotenv loads .env.[stage] for stage prod).
load_production_mongo_env() {
    local dev_uri prod_uri prod_db default_prod_db
    dev_uri=$(grep -E '^MONGODB_URI=' "${BACKEND_DIR}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r')
    prod_uri=$(grep -E '^MONGODB_URI_PRODUCTION=' "${BACKEND_DIR}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r')
    prod_db=$(grep -E '^MONGODB_DB_NAME_PRODUCTION=' "${BACKEND_DIR}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r')

    default_prod_db="$(json_get "$CONFIG_FILE" ".clientName" "app")-$(json_get "$CONFIG_FILE" ".projectName" "app")-prod"

    if [ -z "$prod_uri" ]; then
        prod_uri="$dev_uri"
        if [ -n "$prod_uri" ]; then
            log_warning "MONGODB_URI_PRODUCTION not set — using MONGODB_URI for prod deploy (same host as dev; set MONGODB_URI_PRODUCTION for a dedicated prod cluster)"
        fi
    fi

    if [ -z "$prod_uri" ]; then
        log_error "No MongoDB URI for production: set MONGODB_URI_PRODUCTION or MONGODB_URI in backend/.env"
        exit 1
    fi

    export MONGODB_URI="$prod_uri"
    export MONGODB_DB_NAME="${prod_db:-$default_prod_db}"

    {
        echo "MONGODB_URI=${MONGODB_URI}"
        echo "MONGODB_DB_NAME=${MONGODB_DB_NAME}"
    } > "${BACKEND_DIR}/.env.prod"
}

run_deploy_prechecks() {
    local require_aws_jq="${1:-false}"
    if [ ! -f "${BACKEND_DIR}/.env" ]; then
        log_error "backend/.env not found. Run ./scripts/dev.sh setup first."
        exit 1
    fi
    if ! grep -q '^MONGODB_URI=.\+' "${BACKEND_DIR}/.env" 2>/dev/null \
        && ! grep -q '^MONGODB_URI_PRODUCTION=.\+' "${BACKEND_DIR}/.env" 2>/dev/null; then
        log_error "Need MONGODB_URI (dev) or MONGODB_URI_PRODUCTION in backend/.env. Run ./scripts/dev.sh setup first."
        exit 1
    fi
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "context/config.json not found. Run ./scripts/dev.sh setup first."
        exit 1
    fi
    if [ "$require_aws_jq" = "true" ]; then
        command -v aws &>/dev/null || { log_error "AWS CLI not installed. Install: brew install awscli (or winget install Amazon.AWSCLI on Windows)"; exit 1; }
        command -v node &>/dev/null || { log_error "Node.js required for config (or install jq: brew install jq / winget install jqlang.jq)"; exit 1; }
    fi
}

# Commit and push all changes to GitHub (assumes user is deploying a stable state).
run_git_commit_push() {
    if ! (cd "${PROJECT_ROOT}" && git rev-parse --is-inside-work-tree &>/dev/null); then
        log_warning "Not a git repository; skipping commit and push."
        return 0
    fi
    local branch
    branch=$(cd "${PROJECT_ROOT}" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
    if [ -z "$branch" ]; then
        log_warning "Could not detect git branch; skipping commit and push."
        return 0
    fi
    echo ""
    echo -e "${CYAN}  Git: commit and push all changes${NC}"
    echo ""
    (cd "${PROJECT_ROOT}" && git add -A)
    if (cd "${PROJECT_ROOT}" && git diff --staged --quiet 2>/dev/null); then
        log_info "No local changes to commit."
    else
        local msg="Deploy: $(date +%Y-%m-%d\ %H:%M)"
        if ! (cd "${PROJECT_ROOT}" && git commit -m "$msg"); then
            log_error "Git commit failed."
            exit 1
        fi
        log_success "Committed: $msg"
    fi
    if ! (cd "${PROJECT_ROOT}" && git push -u origin HEAD 2>/dev/null); then
        log_error "Git push failed. Fix remote/auth and re-run deploy."
        exit 1
    fi
    log_success "Pushed to origin/${branch}"
    echo ""
}

# Print prompt for Cursor AI Agent / developer when build fails.
print_build_fix_prompt() {
    echo ""
    echo -e "${YELLOW}---${NC}"
    echo -e "${YELLOW}Cursor AI / Developer: Fix the build errors above. Then run builds until they succeed:${NC}"
    echo "  cd backend && npm run build && cd ../frontend && npm run build"
    echo -e "${YELLOW}When both succeed, run deploy again:${NC}"
    echo "  ./scripts/dev.sh deploy"
    echo -e "${YELLOW}---${NC}"
    echo ""
}

# Run repo verification gates before deploy. Scope: backend|frontend|all.
run_verify_preflight() {
    local scope="${1:-all}"
    echo ""
    echo -e "${CYAN}  Verify preflight: ${scope}${NC}"
    echo ""
    if (cd "${PROJECT_ROOT}" && bash ./scripts/dev.sh verify "${scope}"); then
        log_success "Verify preflight OK (${scope})"
    else
        log_error "Verify preflight failed. Deploy aborted."
        echo ""
        echo -e "${YELLOW}Fix verification failures, then run deploy again:${NC}"
        echo "  ./scripts/dev.sh verify ${scope}"
        echo "  ./scripts/dev.sh deploy"
        echo ""
        exit 1
    fi
    echo ""
}

# CloudWatch log group prefix for Serverless Lambdas: /aws/lambda/<service>-<stage>-
# Matches scripts/run/serverless-logs.sh (stage prod for production deploy).
get_serverless_log_group_prefix() {
    local sls="${BACKEND_DIR}/serverless.yml"
    local SERVICE STAGE
    STAGE="prod"
    [ -f "$sls" ] || return 1
    SERVICE="$(grep -E '^service:' "$sls" | sed 's/service: *//; s/^["'\'']*//; s/["'\'']*$//' | tr -d ' \r')"
    [ -n "$SERVICE" ] || return 1
    echo "/aws/lambda/${SERVICE}-${STAGE}-"
}
# Get current backend API Gateway URL (prod, or dev fallback). Outputs URL with /prod suffix or empty.
get_backend_api_url() {
    local SERVICE_INFO
    if ! SERVICE_INFO=$(cd "${BACKEND_DIR}" && npx serverless info --stage prod --region eu-central-1 2>/dev/null); then
        SERVICE_INFO=$(cd "${BACKEND_DIR}" && npx serverless info --stage dev --region eu-central-1 2>/dev/null) || true
    fi
    local base
    base=$(echo "$SERVICE_INFO" | grep -oE 'https://[a-zA-Z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com' | head -1)
    [ -n "$base" ] && echo "${base}/prod"
}

# Read a key from frontend/.env_prod with shell-style quote trimming.
get_frontend_env_prod_value() {
    local key="$1"
    if [ ! -f "${FRONTEND_DIR}/.env_prod" ]; then
        return 1
    fi
    grep -E "^${key}=" "${FRONTEND_DIR}/.env_prod" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed 's/^["'\'']//;s/["'\'']$//' | tr -d '\r'
}

is_usable_production_api_url() {
    local url="$1"
    [ -n "$url" ] || return 1
    [[ "$url" == https://* ]] || return 1
    # Serverless REST API URLs need a stage path (/prod). A bare execute-api host
    # is usually a legacy API_URL marker and would build the frontend against 404s.
    case "$url" in
        https://*.execute-api.*.amazonaws.com) return 1 ;;
        *) return 0 ;;
    esac
}

write_frontend_env_prod_vite_api_url() {
    local api_url="$1"
    local env_file="${FRONTEND_DIR}/.env_prod"
    local tmp_file="${env_file}.tmp.$$"
    mkdir -p "${FRONTEND_DIR}"
    touch "$env_file"
    if grep -qE '^VITE_API_URL=' "$env_file" 2>/dev/null; then
        awk -v replacement="VITE_API_URL=\"${api_url}\"" '
            BEGIN { replaced = 0 }
            /^VITE_API_URL=/ {
                if (!replaced) {
                    print replacement
                    replaced = 1
                }
                next
            }
            { print }
        ' "$env_file" > "$tmp_file" && mv "$tmp_file" "$env_file"
    else
        {
            [ -s "$env_file" ] && echo ""
            echo "VITE_API_URL=\"${api_url}\""
        } >> "$env_file"
    fi
}

# Overwrite frontend/.env_prod with the canonical merged production Vite env (see scripts/lib-config.sh
# write_merged_frontend_env): VITE_API_URL, optional VITE_STREAM_API_URL, VITE_AUTH_API_BASE, VITE_APP_NAME,
# optional PostHog keys from backend/.env, etc.
# Prefers a live API URL from serverless info; if unavailable, uses an existing usable VITE_API_URL in .env_prod.
# Returns 0 on success; 1 when no usable production API base URL can be resolved.
merge_frontend_env_prod_file() {
    local API_URL STREAM_URL=""
    if [ -f "${RUN_SCRIPT_DIR}/post-deploy-stream.sh" ]; then
        eval "$(bash "${RUN_SCRIPT_DIR}/post-deploy-stream.sh" --eval 2>/dev/null)" || true
    fi

    API_URL=$(get_backend_api_url || true)
    if [ -z "$API_URL" ] || ! is_usable_production_api_url "$API_URL"; then
        API_URL=$(get_frontend_env_prod_value "VITE_API_URL" || true)
    fi
    if ! is_usable_production_api_url "$API_URL"; then
        return 1
    fi

    mkdir -p "${FRONTEND_DIR}"
    write_merged_frontend_env "${FRONTEND_DIR}/.env_prod" "$API_URL" "${STREAM_URL:-}"
    return 0
}

# True when frontend/.env_prod already has a production API base URL.
# If true after infra exists, deploy can run backend Serverless and frontend static build in parallel, then S3 upload.
env_prod_has_production_api_url() {
    local current_val
    current_val=$(get_frontend_env_prod_value "VITE_API_URL")
    is_usable_production_api_url "$current_val"
}

# Some older/testing projects wrote API_URL instead of VITE_API_URL. Normalize that
# before choosing a deploy path so repeat deploys do not stay on the sequential fallback.
ensure_env_prod_fast_path_marker() {
    local vite_val legacy_val api_url
    if env_prod_has_production_api_url; then
        return 0
    fi

    vite_val=$(get_frontend_env_prod_value "VITE_API_URL")
    if [ -n "$vite_val" ]; then
        log_warning "frontend/.env_prod has VITE_API_URL, but it is not a usable production URL: ${vite_val}"
    fi

    legacy_val=$(get_frontend_env_prod_value "API_URL")
    if is_usable_production_api_url "$legacy_val"; then
        write_frontend_env_prod_vite_api_url "$legacy_val"
        log_warning "Detected legacy API_URL in frontend/.env_prod; wrote VITE_API_URL so deploy can use the fast path."
        return 0
    fi

    if [ -n "$legacy_val" ]; then
        api_url=$(get_backend_api_url || true)
        if is_usable_production_api_url "$api_url"; then
            write_frontend_env_prod_vite_api_url "$api_url"
            log_warning "Legacy API_URL was not usable for Vite; refreshed VITE_API_URL from the deployed backend."
            return 0
        fi
        log_warning "frontend/.env_prod has legacy API_URL but no usable VITE_API_URL; deploy will refresh it via the sequential post-deploy step."
    fi

    return 1
}

# KRATOS_DEPLOY_SEQUENTIAL=1|true|yes forces the classic 3-step deploy (backend → post-deploy → frontend) even when .env_prod is ready.
kratos_production_sequential_forced() {
    case "$(echo "${KRATOS_DEPLOY_SEQUENTIAL:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Post-deploy: merge canonical production Vite env into frontend/.env_prod (always runs write_merged_frontend_env
# from lib-config.sh so VITE_APP_NAME, VITE_AUTH_API_BASE, PostHog keys, etc. are present — not only VITE_API_URL).
cmd_post_deploy() {
    echo ""
    echo -e "${CYAN}  Post-Deploy: Merge production Vite env into frontend/.env_prod${NC}"
    echo ""

    if merge_frontend_env_prod_file; then
        log_success "Updated frontend/.env_prod (merged API URL, auth base, app name, optional stream & PostHog)"
        echo "  VITE_API_URL=$(get_frontend_env_prod_value "VITE_API_URL")"
        local k val
        for k in VITE_STREAM_API_URL VITE_AUTH_API_BASE VITE_APP_NAME; do
            val=$(get_frontend_env_prod_value "$k" 2>/dev/null) || true
            [ -n "$val" ] && echo "  ${k}=${val}"
        done
        echo ""
        log_info "Next: ./scripts/dev.sh deploy-fe  # Build and upload frontend to S3"
        echo ""
        return 0
    fi

    log_error "Could not resolve a usable production VITE_API_URL for frontend/.env_prod."
    log_error "Deploy backend first: cd backend && npm run deploy"
    log_info "Or set manually in frontend/.env_prod: VITE_API_URL=\"https://.../prod\""
    exit 1
}

cmd_deploy_backend() {
    echo ""
    echo -e "${CYAN}  Deploy Backend (Serverless)${NC}"
    echo ""
    require_main_branch
    run_deploy_prechecks true
    ensure_infra_ready
    run_verify_preflight backend
    sync_infra_config || true
    set_deploy_env
    load_production_mongo_env
    log_info "Deploying backend (bucket: ${SERVERLESS_DEPLOYMENT_BUCKET}, CORS origin: ${FRONTEND_ORIGIN})..."
    log_info "MongoDB for prod Lambdas: DB_NAME=${MONGODB_DB_NAME} (from MONGODB_DB_NAME_PRODUCTION or default)"
    if (cd "${BACKEND_DIR}" && npm run deploy); then
        local api_url
        api_url=$(get_backend_api_url)
        log_success "Backend deployed"
        [ -n "$api_url" ] && echo -e "  ${GREEN}✓${NC} Backend URL: ${api_url}"
        log_info "Next: ./scripts/dev.sh post-deploy  # Capture API URL for frontend"
    else
        log_error "Deploy failed"
        return 1
    fi
    echo ""
}

cmd_deploy_frontend() {
    echo ""
    echo -e "${CYAN}  Deploy Frontend to S3${NC}"
    echo ""
    require_main_branch
    run_deploy_prechecks true
    ensure_infra_ready
    run_verify_preflight frontend

    local upload_script="${RUN_SCRIPT_DIR}/upload-to-s3.sh"
    if [ ! -f "$upload_script" ]; then
        log_error "Upload script not found: $upload_script"
        return 1
    fi

    bash "$upload_script"
}

# Register this project in the Zeus fleet monitor dashboard.
# Reads ZEUS_MONITOR_MONGODB_URI and HEALTH_TOKEN from backend/.env via DOTENV_CONFIG_PATH.
# Fleet DB: ZEUS_MONITOR_MONGODB_DATABASE, else URI path, else default 49x-zeus-prod (see resolve-monitor-db-name.js).
# Skip registration (website-only deploy): SKIP_ZEUS_MONITOR_REGISTRATION=1|true|yes
register_to_monitor() {
    local skip_raw skip_lc
    skip_raw="${SKIP_ZEUS_MONITOR_REGISTRATION:-}"
    skip_lc=$(echo "$skip_raw" | tr '[:upper:]' '[:lower:]')
    if [ "$skip_lc" = "1" ] || [ "$skip_lc" = "true" ] || [ "$skip_lc" = "yes" ]; then
        log_info "Zeus monitor registration skipped (SKIP_ZEUS_MONITOR_REGISTRATION=$skip_raw)"
        return 0
    fi

    local monitor_uri api_url health_url
    monitor_uri=$(grep -E '^ZEUS_MONITOR_MONGODB_URI=' "${BACKEND_DIR}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r')
    if [ -z "$monitor_uri" ]; then
        echo ""
        log_error "Zeus monitor registration failed: ZEUS_MONITOR_MONGODB_URI is not set or empty in backend/.env"
        log_error "Troubleshoot: add ZEUS_MONITOR_MONGODB_URI to the S3 secrets bundle (docs/kratos/s3-secrets-setup.md) and run scripts/initial-setup/pull-s3-secrets.sh, or add it to backend/.env"
        log_error "To deploy the site only (no fleet dashboard): SKIP_ZEUS_MONITOR_REGISTRATION=1 ./scripts/dev.sh deploy"
        return 1
    fi

    api_url=$(get_frontend_env_prod_value "VITE_API_URL")
    if [ -z "$api_url" ]; then
        echo ""
        log_error "Zeus monitor registration failed: VITE_API_URL missing in frontend/.env_prod (run post-deploy after backend deploy)"
        log_error "To deploy without registering: SKIP_ZEUS_MONITOR_REGISTRATION=1 ./scripts/dev.sh deploy"
        return 1
    fi
    health_url="${api_url}/api/health"

    local log_group_prefix
    if ! log_group_prefix=$(get_serverless_log_group_prefix); then
        echo ""
        log_error "Zeus monitor registration failed: could not read service name from backend/serverless.yml"
        return 1
    fi

    local REGION="${AWS_REGION:-eu-central-1}"
    if command -v aws &>/dev/null; then
        local count_raw count
        count_raw=$(aws logs describe-log-groups --log-group-name-prefix "$log_group_prefix" --region "$REGION" \
            --query 'length(logGroups)' --output text 2>/dev/null | tr -d '\r' || true)
        count="${count_raw:-0}"
        if [ "$count" = "None" ] || [ -z "$count" ]; then
            count=0
        fi
        if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
            log_info "Zeus monitor: CloudWatch prefix matches ${count} log group(s) under ${log_group_prefix}"
        else
            log_warning "Zeus monitor: no log groups found for prefix ${log_group_prefix} (still registering; expected right after first backend deploy)"
        fi
    else
        log_warning "Zeus monitor: AWS CLI not found; skipping CloudWatch prefix verification"
    fi

    echo ""
    echo -e "${CYAN}  Zeus monitor: registering project in fleet dashboard${NC}"
    if ! HEALTH_URL="$health_url" \
        LOG_GROUP_PREFIX="$log_group_prefix" \
        DOTENV_CONFIG_PATH="${BACKEND_DIR}/.env" \
        NODE_PATH="${BACKEND_DIR}/node_modules" \
        node "${PROJECT_ROOT}/scripts/monitor/register-project.js"; then
        echo ""
        log_error "Zeus monitor registration failed (MongoDB upsert or connection error)"
        log_error "Troubleshoot: verify ZEUS_MONITOR_MONGODB_URI, network, HEALTH_TOKEN; fleet DB is 49x-zeus-prod unless URI path or ZEUS_MONITOR_MONGODB_DATABASE says otherwise"
        log_error "To deploy without registering: SKIP_ZEUS_MONITOR_REGISTRATION=1 ./scripts/dev.sh deploy"
        return 1
    fi
    return 0
}

# Sync Relay inbound webhook URL and verify route exists (outbound + inbound registry).
# Requires REGISTRATION_SECRET + RELAY_API_BASE_URL in backend/.env; context/config.json relay block recommended.
# Skip: SKIP_RELAY_ROUTE_REGISTRATION=1|true|yes
register_relay_route() {
    local skip_raw skip_lc api_url webhook_url
    skip_raw="${SKIP_RELAY_ROUTE_REGISTRATION:-}"
    skip_lc=$(echo "$skip_raw" | tr '[:upper:]' '[:lower:]')
    if [ "$skip_lc" = "1" ] || [ "$skip_lc" = "true" ] || [ "$skip_lc" = "yes" ]; then
        log_info "Relay route registration skipped (SKIP_RELAY_ROUTE_REGISTRATION=$skip_raw)"
        return 0
    fi
    if ! project_relay_configured; then
        return 0
    fi
    if ! grep -qE '^[[:space:]]*inboundEmail:' "${BACKEND_DIR}/serverless.yml" 2>/dev/null; then
        return 0
    fi
    if ! grep -qE '^REGISTRATION_SECRET=|^RELAY_REGISTRATION_SECRET=' "${BACKEND_DIR}/.env" 2>/dev/null; then
        echo ""
        log_error "Relay route sync failed: REGISTRATION_SECRET is not set in backend/.env"
        log_error "Troubleshoot: run scripts/initial-setup/pull-s3-secrets.sh or add org Relay secrets"
        log_error "Provision route only (no deploy gate): ./scripts/dev.sh relay-register"
        log_error "To deploy without Relay gate: SKIP_RELAY_ROUTE_REGISTRATION=1 ./scripts/dev.sh deploy"
        return 1
    fi

    api_url=$(get_frontend_env_prod_value "VITE_API_URL" || true)
    if [ -z "$api_url" ]; then
        api_url=$(get_backend_api_url || true)
    fi
    if [ -z "$api_url" ]; then
        echo ""
        log_error "Relay route sync failed: VITE_API_URL missing (run post-deploy after backend deploy)"
        log_error "Run: ./scripts/dev.sh relay-register  then redeploy, or SKIP_RELAY_ROUTE_REGISTRATION=1"
        return 1
    fi
    webhook_url="${api_url%/}/api/inbound-email"

    echo ""
    echo -e "${CYAN}  Relay: syncing webhook URL and verifying route${NC}"
    if ! VITE_API_URL="$api_url" WEBHOOK_URL="$webhook_url" \
        DOTENV_CONFIG_PATH="${BACKEND_DIR}/.env" \
        NODE_PATH="${BACKEND_DIR}/node_modules" \
        node "${PROJECT_ROOT}/scripts/relay/register-or-verify-route.js" --sync-webhook --verify; then
        echo ""
        log_error "Relay route registration failed for this project."
        log_error "Run: ./scripts/dev.sh relay-register"
        log_error "See: docs/kratos/relay-email-integration.md and context/config.json → relay"
        log_error "To deploy without Relay gate: SKIP_RELAY_ROUTE_REGISTRATION=1 ./scripts/dev.sh deploy"
        return 1
    fi
    return 0
}

# Fast production deploy: backend Serverless and frontend Vite build run in parallel, then Zeus + S3 upload.
# Use when VITE_API_URL is already in frontend/.env_prod (at least one full or manual post-deploy has run).
# Set KRATOS_DEPLOY_SEQUENTIAL=1 to keep using the three-step (backend → post-deploy/capture → frontend) flow instead.
_run_production_deploy_parallel() {
    local api_url
    run_verify_preflight all

    sync_infra_config || true
    set_deploy_env
    load_production_mongo_env
    echo ""
    echo -e "${CYAN}  Fast production deploy: backend and frontend build in parallel → Zeus → S3${NC}"
    if ! merge_frontend_env_prod_file; then
        log_error "Could not merge frontend/.env_prod before parallel build (no usable VITE_API_URL)."
        log_info "Run: ./scripts/dev.sh deploy-be && ./scripts/dev.sh post-deploy"
        exit 1
    fi
    log_success "Merged frontend/.env_prod (VITE_APP_NAME, VITE_AUTH_API_BASE, stream, PostHog as applicable) before parallel build"
    log_info "Force sequential capture instead: KRATOS_DEPLOY_SEQUENTIAL=1 ./scripts/dev.sh deploy"
    echo ""
    log_info "Parallel: (1) backend npm run deploy  (2) frontend npm run build  (bucket: ${SERVERLESS_DEPLOYMENT_BUCKET}, CORS: ${FRONTEND_ORIGIN})"
    log_info "MongoDB for prod Lambdas: DB_NAME=${MONGODB_DB_NAME}"
    local pid_be pid_fe be_ok=0 fe_ok=0
    (cd "${BACKEND_DIR}" && npm run deploy) &
    pid_be=$!
    (cd "${FRONTEND_DIR}" && npm run build) &
    pid_fe=$!
    wait "$pid_be" || be_ok=$?
    wait "$pid_fe" || fe_ok=$?
    if [ "$be_ok" -ne 0 ]; then
        log_error "Backend deploy failed (parallel path)"
        exit 1
    fi
    if [ "$fe_ok" -ne 0 ]; then
        log_error "Frontend build failed (parallel path)"
        print_build_fix_prompt
        exit 1
    fi
    api_url=$(get_backend_api_url)
    log_success "Parallel phase complete: backend and frontend build succeeded"
    [ -n "$api_url" ] && echo -e "  ${GREEN}✓${NC} Backend URL: ${api_url}"
    echo ""
    if ! register_to_monitor; then
        exit 1
    fi
    if ! register_relay_route; then
        exit 1
    fi
    log_info "Uploading dist to S3 and invalidating CloudFront..."
    local upload_script="${RUN_SCRIPT_DIR}/upload-to-s3.sh"
    if [ ! -f "$upload_script" ]; then
        log_error "Upload script not found: $upload_script"
        exit 1
    fi
    bash "$upload_script"
    echo ""
    log_success "Fast production deploy complete."
    echo ""
}

# Explicit fast deploy: same as auto fast path, but fails with instructions if .env_prod is not ready.
cmd_deploy_parallel_only() {
    echo ""
    echo -e "${CYAN}  Fast deploy (parallel) — only when VITE_API_URL is already in frontend/.env_prod${NC}"
    echo ""
    require_main_branch
    run_deploy_prechecks true
    log_success "Pre-checks passed"
    ensure_infra_ready
    if ! ensure_env_prod_fast_path_marker; then
        log_error "frontend/.env_prod does not have a valid VITE_API_URL yet (https://...)."
        log_info "Run a full production deploy first:  ./scripts/dev.sh deploy"
        log_info "Or: ./scripts/dev.sh deploy-be  &&  ./scripts/dev.sh post-deploy  (then you can use deploy-parallel or deploy again)"
        exit 1
    fi
    _run_production_deploy_parallel
}

cmd_deploy_all() {
    echo ""
    require_main_branch
    run_deploy_prechecks true
    log_success "Pre-checks passed"
    ensure_infra_ready
    ensure_env_prod_fast_path_marker || true
    if ! kratos_production_sequential_forced && env_prod_has_production_api_url; then
        _run_production_deploy_parallel
        return
    fi
    echo -e "${CYAN}  Full deploy (sequential): verify → backend → post-deploy → frontend build + S3${NC}"
    echo -e "${CYAN}  (Set KRATOS_DEPLOY_SEQUENTIAL=1 to use this even when VITE_API_URL is already in .env_prod)${NC}"
    echo ""
    run_verify_preflight all

    sync_infra_config || true
    set_deploy_env
    load_production_mongo_env
    log_info "Step 1/3: Deploying backend (bucket: ${SERVERLESS_DEPLOYMENT_BUCKET}, CORS: ${FRONTEND_ORIGIN})..."
    log_info "MongoDB for prod Lambdas: DB_NAME=${MONGODB_DB_NAME}"
    if (cd "${BACKEND_DIR}" && npm run deploy); then
        local api_url
        api_url=$(get_backend_api_url)
        log_success "Step 1/3 complete: Backend deployed"
        [ -n "$api_url" ] && echo -e "  ${GREEN}✓${NC} Backend URL: ${api_url}"
    else
        log_error "Backend deploy failed"
        exit 1
    fi
    echo ""

    log_info "Step 2/3: Capturing API Gateway URL..."
    cmd_post_deploy
    # cmd_post_deploy prints its own "Next" message; we continue to step 3

    if ! register_to_monitor; then
        exit 1
    fi
    if ! register_relay_route; then
        exit 1
    fi

    log_info "Step 3/3: Rebuilding frontend with production env and uploading..."
    if ! (cd "${FRONTEND_DIR}" && npm run build); then
        log_error "Frontend build failed"
        print_build_fix_prompt
        exit 1
    fi
    log_success "Frontend production build complete"
    local upload_script="${RUN_SCRIPT_DIR}/upload-to-s3.sh"
    if [ ! -f "$upload_script" ]; then
        log_error "Upload script not found: $upload_script"
        exit 1
    fi
    bash "$upload_script"
    echo ""
    log_success "Full deploy complete."
    echo ""
}

cmd_deploy_status() {
    echo ""
    echo -e "${CYAN}  Deploy decision preview (no deploy will run)${NC}"
    echo ""

    local branch stable_branch sub stack_name vite_val legacy_val api_url decision reason
    stable_branch="main"
    if [ -f "${PROJECT_ROOT}/.kratos/git-policy.json" ] && command -v jq &>/dev/null; then
        stable_branch=$(jq -r '.stableBranch // "main"' "${PROJECT_ROOT}/.kratos/git-policy.json" 2>/dev/null || echo "main")
    fi
    branch=$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "  Branch: ${branch} (deploy branch: ${stable_branch})"

    if [ -f "$CONFIG_FILE" ]; then
        sub=$(effective_deploy_subdomain "$CONFIG_FILE")
        stack_name="prod-${sub}-infra"
        echo "  Infra stack: ${stack_name}"
        if command -v aws &>/dev/null && aws cloudformation describe-stacks --stack-name "$stack_name" --region eu-central-1 --query "Stacks[0].StackName" --output text &>/dev/null; then
            echo "    status: exists"
        elif command -v aws &>/dev/null; then
            echo "    status: missing or not visible with current AWS account/profile/region"
        else
            echo "    status: unknown (AWS CLI not installed)"
        fi
    else
        echo "  Infra stack: unknown (context/config.json missing)"
    fi

    vite_val=$(get_frontend_env_prod_value "VITE_API_URL")
    legacy_val=$(get_frontend_env_prod_value "API_URL")
    echo "  frontend/.env_prod:"
    if is_usable_production_api_url "$vite_val"; then
        echo "    VITE_API_URL: ready"
    elif [ -n "$vite_val" ]; then
        echo "    VITE_API_URL: present but invalid for production fast path (${vite_val})"
    else
        echo "    VITE_API_URL: missing"
    fi
    if [ -n "$legacy_val" ]; then
        echo "    API_URL: legacy marker present (${legacy_val})"
    fi

    if kratos_production_sequential_forced; then
        decision="sequential 3-step"
        reason="KRATOS_DEPLOY_SEQUENTIAL=${KRATOS_DEPLOY_SEQUENTIAL}"
    elif is_usable_production_api_url "$vite_val"; then
        decision="fast parallel"
        reason="VITE_API_URL is ready"
    elif is_usable_production_api_url "$legacy_val"; then
        decision="fast parallel after auto-normalizing .env_prod"
        reason="legacy API_URL can be copied to VITE_API_URL"
    else
        api_url=$(get_backend_api_url || true)
        if [ -n "$legacy_val" ] && is_usable_production_api_url "$api_url"; then
            decision="fast parallel after refreshing .env_prod from deployed backend"
            reason="backend API can be discovered without redeploying"
        else
            decision="sequential 3-step"
            reason="no usable VITE_API_URL fast-path marker yet"
        fi
    fi

    echo ""
    echo "  Decision: ${decision}"
    echo "  Reason: ${reason}"
    echo "  Command: ./scripts/dev.sh deploy"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Staging deploy helpers
# ─────────────────────────────────────────────────────────────────────────────

# Require that the current branch is main or develop before staging deploy.
require_staging_branch() {
    if ! git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
        return 0
    fi
    local branch
    branch=$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        return 0
    fi
    if [ "$branch" != "main" ] && [ "$branch" != "develop" ]; then
        log_error "Staging deploy is only allowed from 'main' or 'develop' branch."
        log_error "Current branch: ${branch}"
        echo ""
        log_info "Switch to develop:  git checkout develop"
        echo ""
        exit 1
    fi
}

# Set staging-specific env vars: FRONTEND_ORIGIN (staging URL) and SERVERLESS_DEPLOYMENT_BUCKET.
set_staging_deploy_env() {
    local sub domain_base stack_name bucket
    sub=$(effective_deploy_subdomain "$CONFIG_FILE")
    if [ -z "$sub" ]; then
        log_error "subdomainName missing in context/config.json"
        exit 1
    fi
    domain_base="$KRATOS_DEPLOY_DOMAIN_BASE"
    export STAGING_SUBDOMAIN
    STAGING_SUBDOMAIN=$(staging_site_label "$sub")
    export FRONTEND_ORIGIN="https://${STAGING_SUBDOMAIN}.${domain_base}"
    export STAGING_URL="https://${STAGING_SUBDOMAIN}.${domain_base}"

    stack_name=$(staging_infra_stack_name "$sub")
    bucket=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region eu-central-1 \
        --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text 2>/dev/null) || true
    bucket=$(echo "$bucket" | tr -d '\r')
    if [ -z "$bucket" ]; then
        log_error "Could not get BucketName from staging infra stack \"$stack_name\"."
        log_info "Run staging infra deploy first (it runs automatically on first deploy-staging)."
        exit 1
    fi
    export SERVERLESS_DEPLOYMENT_BUCKET="$bucket"
    export APP_VERSION
    APP_VERSION=$(cat "${PROJECT_ROOT}/VERSION" 2>/dev/null | tr -d '\n' || echo 'unknown')
}

# Ensure staging ACM cert exists and staging infra stack is deployed.
ensure_staging_infra_ready() {
    local sub stack_name
    sub=$(effective_deploy_subdomain "$CONFIG_FILE")
    [ -n "$sub" ] || { log_error "subdomainName missing in context/config.json"; exit 1; }
    stack_name=$(staging_infra_stack_name "$sub")

    if ! aws cloudformation describe-stacks --stack-name "$stack_name" --region eu-central-1 \
        --query "Stacks[0].StackName" --output text &>/dev/null; then
        echo ""
        echo -e "${CYAN}  First-time staging deploy: deploying staging infra stack${NC}"
        echo ""
        log_info "Staging uses the same ACM certificate as production; ensure certificateArn covers this hostname (e.g. *.domain)."
        echo ""

        if ! sync_infra_config; then
            log_error "Could not sync infra config. Check infra/ and context/config.json."
            exit 1
        fi

        log_info "Installing infra dependencies..."
        (cd "${PROJECT_ROOT}/infra" && npm install --no-audit --no-fund) || { log_error "Infra npm install failed."; exit 1; }

        log_info "Deploying staging infra (S3, CloudFront, Route53)..."
        if ! (cd "${PROJECT_ROOT}/infra" && npm run deploy -- --stage staging); then
            log_error "Staging infra deploy failed. Fix the errors above, then run deploy-staging again."
            exit 1
        fi
        log_success "Staging infra deployed"
        echo ""
    fi
}

# Load staging MongoDB URI/DB from backend/.env into shell env for Serverless deploy.
# Staging uses the same Atlas cluster as local dev; URI matches MONGODB_URI unless overridden.
load_staging_mongo_env() {
    local dev_uri staging_uri staging_db
    dev_uri=$(grep -E '^MONGODB_URI=' "${BACKEND_DIR}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r')
    staging_uri=$(grep -E '^MONGODB_URI_STAGING=' "${BACKEND_DIR}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r')
    staging_db=$(grep -E '^MONGODB_DB_NAME_STAGING=' "${BACKEND_DIR}/.env" 2>/dev/null \
        | head -1 | cut -d= -f2- | sed "s/^[\"']//;s/[\"']$//" | tr -d '\r')

    if [ -z "$dev_uri" ]; then
        log_error "MONGODB_URI not set in backend/.env — run ./scripts/dev.sh setup first"
        exit 1
    fi

    if [ -z "$staging_uri" ]; then
        staging_uri="$dev_uri"
    fi

    export MONGODB_URI="$staging_uri"
    export MONGODB_DB_NAME="${staging_db:-$(json_get "$CONFIG_FILE" ".clientName" "app")-$(json_get "$CONFIG_FILE" ".projectName" "app")-staging}"

    # Write .env.staging so Serverless Framework auto-loads it for stage=staging
    {
        echo "MONGODB_URI=${MONGODB_URI}"
        echo "MONGODB_DB_NAME=${MONGODB_DB_NAME}"
    } > "${BACKEND_DIR}/.env.staging"
}

# Get the staging backend API Gateway URL.
get_staging_backend_api_url() {
    local SERVICE_INFO
    if ! SERVICE_INFO=$(cd "${BACKEND_DIR}" && npx serverless info --stage staging --region eu-central-1 2>/dev/null); then
        return 1
    fi
    local base
    base=$(echo "$SERVICE_INFO" | grep -oE 'https://[a-zA-Z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com' | head -1)
    [ -n "$base" ] && echo "${base}/staging"
}

# Full staging deploy: Dev Atlas (shared with local) → MongoDB sync → infra → backend → frontend
cmd_deploy_staging() {
    echo ""
    echo -e "${CYAN}  Staging Deploy: MongoDB → Infra → Backend → Frontend${NC}"
    echo ""
    require_staging_branch
    run_deploy_prechecks true
    log_success "Pre-checks passed"

    # Step 1: Ensure dev Atlas cluster exists (local + staging Lambdas share this cluster; separate DB name for staging)
    echo ""
    echo -e "${CYAN}  Step 1/5: Ensuring dev MongoDB cluster (shared with staging)${NC}"
    echo ""
    bash "${RUN_SCRIPT_DIR}/../initial-setup/mongodb-atlas.sh" --yes || {
        log_error "Dev MongoDB Atlas setup failed"
        exit 1
    }

    # Step 2: Sync MongoDB data prod → staging
    echo ""
    echo -e "${CYAN}  Step 2/5: Syncing MongoDB data to staging${NC}"
    echo ""
    local sync_script="${RUN_SCRIPT_DIR}/mongodb-sync.sh"
    if [ -f "$sync_script" ]; then
        bash "$sync_script" || {
            log_warning "MongoDB sync failed — staging will use existing data (or empty DB)"
        }
    else
        log_warning "mongodb-sync.sh not found; skipping data sync"
    fi

    # Step 3: Ensure staging infra (CloudFront stack; same ACM as prod)
    echo ""
    echo -e "${CYAN}  Step 3/5: Ensuring staging infra stack exists${NC}"
    echo ""
    ensure_staging_infra_ready
    sync_infra_config || true
    load_staging_mongo_env
    set_staging_deploy_env

    # Step 4: Deploy backend to staging
    echo ""
    echo -e "${CYAN}  Step 4/5: Deploying backend (stage: staging)${NC}"
    echo ""
    run_test_preflight
    log_info "Building backend..."
    if ! (cd "${BACKEND_DIR}" && npm run build); then
        log_error "Backend build failed."
        print_build_fix_prompt
        exit 1
    fi
    log_success "Backend build OK"
    echo ""
    log_info "Deploying backend (bucket: ${SERVERLESS_DEPLOYMENT_BUCKET}, CORS: ${FRONTEND_ORIGIN})..."
    if ! (cd "${BACKEND_DIR}" && npm run deploy:staging); then
        log_error "Staging backend deploy failed"
        exit 1
    fi
    log_success "Backend deployed to staging"

    # Capture staging API URL
    local staging_api_url
    staging_api_url=$(get_staging_backend_api_url || true)
    [ -n "$staging_api_url" ] && echo -e "  ${GREEN}✓${NC} Staging API URL: ${staging_api_url}"

    if [ -n "$staging_api_url" ]; then
        {
            echo "VITE_API_URL=\"$staging_api_url\""
        } > "${FRONTEND_DIR}/.env.staging"
        log_success "Written frontend/.env.staging (VITE_API_URL)"
    else
        log_warning "Could not get staging API URL — frontend/.env.staging may be stale"
    fi

    # Step 5: Build and upload frontend
    echo ""
    echo -e "${CYAN}  Step 5/5: Building and uploading frontend to staging S3${NC}"
    echo ""
    log_info "Building frontend..."
    if ! (cd "${FRONTEND_DIR}" && VITE_API_URL="$staging_api_url" npm run build); then
        log_error "Frontend build failed"
        print_build_fix_prompt
        exit 1
    fi
    log_success "Frontend build OK"

    local sub domain_base staging_bucket staging_cf_id staging_label
    sub=$(effective_deploy_subdomain "$CONFIG_FILE")
    domain_base="$KRATOS_DEPLOY_DOMAIN_BASE"
    staging_label=$(staging_site_label "$sub")
    staging_bucket="${staging_label}.${domain_base}"

    log_info "Uploading frontend to s3://${staging_bucket} ..."
    aws s3 sync "${FRONTEND_DIR}/dist" "s3://${staging_bucket}"
    log_success "Uploaded to s3://${staging_bucket}"

    # CloudFront invalidation
    staging_cf_id=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?Aliases.Items[?contains(@,'${staging_bucket}')]].Id | [0]" \
        --output text 2>/dev/null || true)
    [ "$staging_cf_id" = "None" ] && staging_cf_id=""
    if [ -n "$staging_cf_id" ]; then
        log_info "Invalidating staging CloudFront (${staging_cf_id})..."
        aws cloudfront create-invalidation --distribution-id "$staging_cf_id" --paths "/*" > /dev/null
        log_success "CloudFront invalidation created"
    fi

    echo ""
    log_success "Staging deploy complete: ${STAGING_URL}"
    echo ""
}

case "${1:-}" in
    deploy)          cmd_deploy_all ;;
    deploy-status)   cmd_deploy_status ;;
    deploy-parallel) cmd_deploy_parallel_only ;;
    post-deploy)     cmd_post_deploy ;;
    deploy-be)       cmd_deploy_backend ;;
    deploy-fe)       cmd_deploy_frontend ;;
    deploy-staging)  cmd_deploy_staging ;;
    *)
        log_error "Usage: $0 deploy|deploy-status|deploy-parallel|post-deploy|deploy-be|deploy-fe|deploy-staging"
        exit 1
        ;;
esac
