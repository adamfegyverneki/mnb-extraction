#!/bin/bash
# Live-tail CloudWatch logs for all Lambda functions of the deployed serverless backend.
# Uses AWS CloudWatch Logs Live Tail for near-instant log delivery (no 1–2 min delay).
# Usage: ./scripts/run/serverless-logs.sh
#   Optional: STAGE=dev ./scripts/run/serverless-logs.sh  (default stage: prod)
#   Optional: DEBUG=1 ./scripts/run/serverless-logs.sh     (fallback: classic tail on first log group only)
#   Optional: LOGS_SINCE=5m  Show recent logs from this window before live tail (default: 5m). Use 0 or empty to skip.
# Press Ctrl+C to stop. Requires AWS CLI v2 and logs:StartLiveTail permission.
#
# Service name comes from backend/serverless.yml; log groups from /aws/lambda/<service>-<stage>-* (universal per project).

set -e
RUN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${RUN_SCRIPT_DIR}/../lib.sh"

BACKEND_SERVERLESS="${BACKEND_DIR}/serverless.yml"
REGION="${AWS_REGION:-eu-central-1}"
STAGE="${STAGE:-prod}"
# How much recent history to fetch when starting (e.g. 5m, 1h). Use LOGS_SINCE=0 to skip.
LOGS_SINCE="${LOGS_SINCE:-5m}"

command -v aws &>/dev/null || { log_error "AWS CLI required. Install: brew install awscli"; exit 1; }
[ -f "$BACKEND_SERVERLESS" ] || { log_error "backend/serverless.yml not found."; exit 1; }

# Service name from serverless.yml (e.g. defaultproject-backend)
SERVICE="$(grep -E '^service:' "$BACKEND_SERVERLESS" | sed 's/service: *//; s/^["'\'']*//; s/["'\'']*$//' | tr -d ' \r')"
[ -n "$SERVICE" ] || { log_error "Could not read service name from backend/serverless.yml"; exit 1; }

PREFIX="/aws/lambda/${SERVICE}-${STAGE}-"
# Do not let AWS failures exit silently (set -e): capture and surface errors.
set +e
LOG_GROUPS="$(aws logs describe-log-groups --log-group-name-prefix "$PREFIX" --region "$REGION" --query "logGroups[].logGroupName" --output text 2>&1 | tr '\t' '\n' | grep -v '^$')"
DESCRIBE_EXIT=$?
set -e

if [ -z "$LOG_GROUPS" ] || [ $DESCRIBE_EXIT -ne 0 ]; then
  log_error "No Lambda log groups found with prefix: ${PREFIX}"
  if [ $DESCRIBE_EXIT -ne 0 ]; then
    echo "  AWS CLI error (exit $DESCRIBE_EXIT). Check credentials and region ($REGION):" >&2
    [ -n "$LOG_GROUPS" ] && echo "$LOG_GROUPS" | head -10
    aws logs describe-log-groups --log-group-name-prefix "$PREFIX" --region "$REGION" 2>&1 | head -15 || true
  else
    echo "  Deploy the backend first: ./scripts/dev.sh deploy-be" >&2
    echo "  Or use a different stage: STAGE=dev ./scripts/run/serverless-logs.sh" >&2
  fi
  exit 1
fi

# Verify targets: list deployed Lambdas for this service/stage and ensure we're tailing their log groups.
LAMBDA_PREFIX="${SERVICE}-${STAGE}-"
set +e
DEPLOYED_FUNCS="$(aws lambda list-functions --region "$REGION" --query "Functions[?starts_with(FunctionName, '${LAMBDA_PREFIX}')].FunctionName" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$')"
set -e
MISSING=""
if [ -n "$DEPLOYED_FUNCS" ]; then
  while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    expected_log_group="/aws/lambda/${fn}"
    if ! echo "$LOG_GROUPS" | grep -q "^${expected_log_group}$"; then
      MISSING="${MISSING} ${fn}"
    fi
  done <<< "$DEPLOYED_FUNCS"
fi

# Short name for each log group = function name (e.g. defaultproject-backend-prod-health -> health)
short_name() {
  echo "$1" | sed "s|^${PREFIX}||"
}

cleanup() {
  [ -n "$TAIL_PIDS" ] && kill $TAIL_PIDS 2>/dev/null
  exit 0
}
trap cleanup SIGINT SIGTERM

# Resolve deployed API base URL (no path beyond /stage) so user can verify the frontend calls this backend.
API_BASE=""
if [ -f "${BACKEND_DIR}/package.json" ]; then
  set +e
  INFO_OUT="$(cd "${BACKEND_DIR}" && npx serverless info --stage "$STAGE" --region "$REGION" 2>/dev/null)"
  set -e
  # Extract base only: https://xxx.execute-api.region.amazonaws.com/<stage>
  API_BASE="$(echo "$INFO_OUT" | grep -oE "https://[a-zA-Z0-9]+\\.execute-api\\.[a-z0-9-]+\\.amazonaws\\.com/${STAGE}" | head -1)"
fi

# Parse serverless.yml for HTTP routes (method, path, function name). Universal for any project.
# Outputs one line per route: "METHOD\tpath\tfuncName" (e.g. "GET\t/api/health\thealth").
get_routes_from_serverless() {
  [ -f "$BACKEND_SERVERLESS" ] || return 0
  awk '
    /^functions:/ { in_functions = 1; next }
    in_functions && /^  [a-zA-Z0-9]+:/ {
      if (fn != "" && path != "" && method != "") print method "\t" path "\t" fn
      fn = $1; gsub(/:$/, "", fn); path = ""; method = ""
      next
    }
    in_functions && /path:/ {
      sub(/^.*path:[[:space:]]*/, ""); gsub(/^["'\'']|["'\'']$/, ""); path = $0
      next
    }
    in_functions && /method:/ {
      method = toupper($2); gsub(/^["'\'']|["'\'']$/, "", method)
      next
    }
    in_functions && /^[a-z]/ { if (fn != "" && path != "" && method != "") print method "\t" path "\t" fn; exit }
  ' "$BACKEND_SERVERLESS"
}

echo ""
log_info "Live Tailing serverless backend logs (stage=${STAGE}, region=${REGION}). Ctrl+C to stop."
if [ -n "$API_BASE" ]; then
  echo "  Backend API base (frontend should use this as VITE_API_URL): $API_BASE"
  echo "  Routes → Lambda (log group):"
  ROUTES="$(get_routes_from_serverless)"
  if [ -n "$ROUTES" ]; then
    echo "$ROUTES" | while IFS=$'\t' read -r method path funcName; do
      [ -z "$method" ] || [ -z "$path" ] || [ -z "$funcName" ] && continue
      printf "    %-4s %s%s → %s\n" "$method" "${API_BASE}" "$path" "$funcName"
    done
  else
    echo "    (parse serverless.yml for routes; log groups below)"
  fi
  echo "  To verify: curl an endpoint above and look for [functionName] in the log stream below. Lambda logs START/END/REPORT per invocation."
fi
if [ -n "$DEPLOYED_FUNCS" ]; then
  if [ -n "$MISSING" ]; then
    log_warning "Some deployed Lambdas have no log group in this list:${MISSING}"
  else
    log_success "Listening to log groups for deployed Lambdas (prefix ${LAMBDA_PREFIX})"
  fi
fi
echo "  Log groups (CloudWatch):"
echo "$LOG_GROUPS" | while read -r lg; do [ -n "$lg" ] && echo "    $lg"; done
echo ""

# Live Tail supports up to 10 log groups. Take first 10.
LOG_GROUP_LIST="$(echo "$LOG_GROUPS" | head -10)"
LOG_GROUP_COUNT="$(echo "$LOG_GROUP_LIST" | grep -c . || echo 0)"

# Get AWS account ID for log group ARNs (required by start-live-tail).
set +e
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null | tr -d '\r')"
set -e
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
  log_error "Could not get AWS account ID (sts get-caller-identity). Check credentials."
  exit 1
fi

# Build ARNs: arn:aws:logs:REGION:ACCOUNT_ID:log-group:LOG_GROUP_NAME
LIVE_TAIL_ARNS=()
while IFS= read -r LG; do
  [ -z "$LG" ] && continue
  LIVE_TAIL_ARNS+=( "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LG}" )
done <<< "$LOG_GROUP_LIST"

if [ "${DEBUG:-0}" = "1" ]; then
  FIRST_GROUP="$(echo "$LOG_GROUP_LIST" | head -1)"
  log_info "DEBUG: classic tail on first log group only. Ctrl+C to stop."
  exec aws logs tail "$FIRST_GROUP" --region "$REGION" --follow --since 5m --format short
fi

# Live Tail requires AWS CLI v2.33.25+ (start-live-tail). Detection: with modern CLI,
# "aws logs start-live-tail" without args returns error "the following arguments are required"
# (command exists). Older CLI returns "Invalid choice" / "invalid choice". --help exits 252
# when required args are missing, so we must not rely on exit code of --help.
live_tail_available() {
  local err
  err="$(aws logs start-live-tail 2>&1)" || true
  if echo "$err" | grep -q "the following arguments are required"; then
    return 0
  fi
  # Optional: allow by version (AWS CLI v2.33.25+)
  local ver
  ver="$(aws --version 2>/dev/null | sed -n 's/.*aws-cli\/\([0-9.]*\).*/\1/p')"
  if [ -n "$ver" ]; then
    local major minor patch rest
    major="${ver%%.*}"
    rest="${ver#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    patch="${patch%%.*}"
    [ -z "$patch" ] && patch=0
    if [ "$major" -eq 2 ] && { [ "$minor" -gt 33 ] || { [ "$minor" -eq 33 ] && [ "$patch" -ge 25 ]; }; }; then
      return 0
    fi
  fi
  return 1
}

if ! live_tail_available; then
  log_info "Live Tail not found (requires AWS CLI v2.33.25+). Checking current CLI..."
  aws --version 2>/dev/null || true
  log_info "To get Live Tail: brew upgrade awscli   (macOS) or install AWS CLI v2.33.25+."
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" == "darwin"* ]]; then
    brew upgrade awscli 2>/dev/null || brew install awscli 2>/dev/null || true
  elif [[ "$os" == "linux"* ]] && command -v pip3 &>/dev/null; then
    pip3 install --upgrade awscli 2>/dev/null || true
  fi
fi

if live_tail_available; then
  # Fetch recent logs so we see what happened before we attached (e.g. last 5 minutes).
  if [ -n "$LOGS_SINCE" ] && [ "$LOGS_SINCE" != "0" ]; then
    log_info "Recent logs (last ${LOGS_SINCE}):"
    echo ""
    while IFS= read -r LOG_GROUP; do
      [ -z "$LOG_GROUP" ] && continue
      TAG="$(short_name "$LOG_GROUP")"
      set +e
      aws logs tail "$LOG_GROUP" --region "$REGION" --since "$LOGS_SINCE" --format short 2>/dev/null | \
        awk -v tag="$TAG" '{ print "[" tag "] " $0; fflush() }'
      set -e
    done <<< "$LOG_GROUP_LIST"
    echo ""
    log_info "Live tail (new events):"
    echo ""
  else
    log_info "Starting Live Tail for ${LOG_GROUP_COUNT} log group(s). Ctrl+C to stop."
    echo ""
  fi
  # Live tail: strip blank lines. (CLI stream with --output json is not reliably parseable by jq.)
  aws logs start-live-tail \
    --log-group-identifiers "${LIVE_TAIL_ARNS[@]}" \
    --region "$REGION" \
    --mode print-only \
    --no-cli-pager 2>&1 | grep -v '^$'
fi

# Fallback: classic tail (staggered to avoid throttling). Logs may be delayed 1–2 min.
log_info "Using classic tail for ${LOG_GROUP_COUNT} log group(s) (logs may be delayed 1–2 min). Ctrl+C to stop."
echo ""
TAIL_PIDS=""
while IFS= read -r LOG_GROUP; do
  [ -z "$LOG_GROUP" ] && continue
  TAG="$(short_name "$LOG_GROUP")"
  ( aws logs tail "$LOG_GROUP" --region "$REGION" --follow --since "${LOGS_SINCE:-5m}" --format short 2>&1 | awk -v tag="$TAG" '{ print "[" tag "] " $0; fflush() }' ) &
  TAIL_PIDS="${TAIL_PIDS} $!"
  sleep 2
done <<< "$LOG_GROUP_LIST"
wait
