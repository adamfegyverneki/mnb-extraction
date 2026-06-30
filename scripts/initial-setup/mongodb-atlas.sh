#!/bin/bash

#############################################################################
# MongoDB Atlas Cluster Setup
#
# Typical layout: one dev cluster (project "{slug}-dev", cluster "{slug}-dev-cluster") used for local, staging,
# and prod Lambdas (different database names from context/config.json). Optional: --production creates a
# separate prod cluster and prints its URI (set MONGODB_URI manually if you adopt it).
#
# Default (setup): provisions dev and writes MONGODB_URI + MONGODB_DB_NAME (`{slug}-dev`). Staging/prod Lambdas use
# the same URI with database names `{slug}-staging` / `{slug}-prod` derived from context/config.json at deploy time.
#
#   ./scripts/initial-setup/mongodb-atlas.sh [--yes]
#   Called by kratos-setup.sh with MONGODB_ATLAS_NONINTERACTIVE=1 --yes
#
#   ./scripts/initial-setup/mongodb-atlas.sh --production [--yes]
#   Provisions a dedicated prod Atlas cluster; does not write backend/.env (print URI — use MONGODB_URI if you adopt that cluster).
#
# Optional env:
#   MONGODB_ATLAS_PROJECT_ID            — existing Atlas project ID for **dev** mode
#   MONGODB_ATLAS_PRODUCTION_PROJECT_ID — existing Atlas project ID for **--production**
#   MONGODB_ATLAS_ORG_ID                — org when creating a project
#############################################################################

set -e

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SETUP_DIR}/.." && pwd)"
# shellcheck source=../lib.sh
source "${SCRIPTS_DIR}/lib.sh"
CONFIG_FILE="${PROJECT_ROOT}/context/config.json"
BACKEND_ENV="${BACKEND_DIR}/.env"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

gen_password() {
  LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 24
}

fallback_to_user_auth_once() {
  unset MONGODB_ATLAS_PUBLIC_API_KEY
  unset MONGODB_ATLAS_PRIVATE_API_KEY
  unset MONGODB_ATLAS_ORG_ID

  if ! atlas auth login; then
    return 1
  fi
  save_atlas_credentials
  atlas projects list -o json >/dev/null 2>/dev/null
}

restart_after_interactive_auth() {
  local reason="${1:-interactive Atlas login}"
  shift || true

  if [ "${ATLAS_AUTH_RESTARTED_ONCE:-0}" = "1" ]; then
    log_info "Already restarted once after $reason; continuing in current run."
    return 0
  fi

  log_success "Atlas auth completed ($reason). Restarting MongoDB setup once to continue cleanly..."
  echo ""
  export ATLAS_AUTH_RESTARTED_ONCE=1
  exec bash "$0" "$@"
}

# First matching project name in list_json; prints id or empty.
project_id_by_name() {
  local list_json="$1"
  local want="$2"
  echo "$list_json" | jq -r --arg name "$want" '.results[] | select(.name == $name) | .id' | head -1
}

# Find first existing project from candidate names.
find_first_project_id() {
  local list_json="$1"
  shift
  local n pid
  for n in "$@"; do
    pid=$(project_id_by_name "$list_json" "$n")
    if [ -n "$pid" ]; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

main() {
  local PRODUCTION_MODE=false
  local YES_FLAG=false
  for arg in "$@"; do
    [[ "$arg" == "--production" ]] && PRODUCTION_MODE=true
    [[ "$arg" == "--yes" || "$arg" == "-y" ]] && YES_FLAG=true
  done

  echo ""
  echo -e "${PURPLE}═══════════════════════════════════════${NC}"
  if [ "$PRODUCTION_MODE" = true ]; then
    echo -e "${PURPLE}  MongoDB Atlas Cluster Setup (Production)${NC}"
  else
    echo -e "${PURPLE}  MongoDB Atlas Cluster Setup (Dev — local + staging)${NC}"
  fi
  echo -e "${PURPLE}═══════════════════════════════════════${NC}"
  echo ""

  load_device_credentials

  if ! command -v atlas &>/dev/null; then
    log_error "Atlas CLI not found"
    log_info "Install: brew install mongodb-atlas-cli"
    log_info "Docs: https://www.mongodb.com/docs/atlas/cli/"
    exit 1
  fi

  ensure_atlas_session

  if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config not found: $CONFIG_FILE"
    exit 1
  fi
  local CLIENT_NAME=$(jq -r '.clientName' "$CONFIG_FILE")
  local PROJECT_NAME=$(jq -r '.projectName' "$CONFIG_FILE")
  if [[ "$CLIENT_NAME" == "free text"* || -z "$CLIENT_NAME" ]]; then
    log_error "Set clientName in context/config.json"
    exit 1
  fi
  if [[ "$PROJECT_NAME" == "free text"* || -z "$PROJECT_NAME" ]]; then
    log_error "Set projectName in context/config.json"
    exit 1
  fi

  local SLUG="${CLIENT_NAME}-${PROJECT_NAME}"
  local SLUG_LOWER
  SLUG_LOWER=$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-')

  if [[ ${#SLUG_LOWER} -gt $(atlas_max_slug_len) ]]; then
    log_error "Combined slug is too long for MongoDB Atlas (cluster names are limited to ${ATLAS_CLUSTER_NAME_MAX_LEN} characters; slug is ${#SLUG_LOWER} characters, max $(atlas_max_slug_len) for names like …-prod-cluster)."
    log_info "Shorten clientName and/or projectName in context/config.json. Example ≤$(atlas_max_slug_len) chars: $(atlas_suggest_slug_trim "$SLUG_LOWER")"
    exit 1
  fi

  local CLUSTER_NAME DB_NAME DB_USER
  local NEW_PROJECT_NAME
  local PROJECT_ID=""

  if [ "$PRODUCTION_MODE" = true ]; then
    NEW_PROJECT_NAME="${SLUG_LOWER}-prod"
    CLUSTER_NAME="${SLUG_LOWER}-prod-cluster"
    DB_NAME="${SLUG_LOWER}-prod"
    DB_USER="${SLUG_LOWER}-prod-user"
    PROJECT_ID="${MONGODB_ATLAS_PRODUCTION_PROJECT_ID:-}"
  else
    NEW_PROJECT_NAME="${SLUG_LOWER}-dev"
    CLUSTER_NAME="${SLUG_LOWER}-dev-cluster"
    DB_NAME="${SLUG_LOWER}-dev"
    DB_USER="${SLUG_LOWER}-dev-user"
    PROJECT_ID="${MONGODB_ATLAS_PROJECT_ID:-}"
  fi

  if [ -z "$PROJECT_ID" ]; then
    local ATLAS_RETRY=0
    local ATLAS_AUTH_FALLBACK_RETRY=0
    local CREATE_ERR LIST_ERR ORGS_ERR
    CREATE_ERR=$(mktemp)
    LIST_ERR=$(mktemp)
    ORGS_ERR=$(mktemp)
    trap "rm -f '$CREATE_ERR' '$LIST_ERR' '$ORGS_ERR'" EXIT

    while true; do
      local LIST_JSON HAS_PROJECTS=false
      if [ -n "${MONGODB_ATLAS_ORG_ID:-}" ]; then
        LIST_JSON=$(atlas projects list --orgId "$MONGODB_ATLAS_ORG_ID" -o json 2>"$LIST_ERR") || LIST_JSON=""
      else
        LIST_JSON=$(atlas projects list -o json 2>"$LIST_ERR") || LIST_JSON=""
      fi

      if [ -n "$LIST_JSON" ] && echo "$LIST_JSON" | jq -e '.results | length > 0' &>/dev/null; then
        HAS_PROJECTS=true
      fi

      if [ "$PRODUCTION_MODE" = true ]; then
        PROJECT_ID=$(project_id_by_name "$LIST_JSON" "$NEW_PROJECT_NAME")
      else
        PROJECT_ID=""
        local found_pid
        found_pid=$(find_first_project_id "$LIST_JSON" \
          "${SLUG_LOWER}-dev" \
          "${SLUG_LOWER}-local" \
          "${SLUG_LOWER}-staging" \
          "${SLUG_LOWER}") && PROJECT_ID="$found_pid"
      fi

      if [ -n "$PROJECT_ID" ]; then
        log_info "Using existing Atlas project (ID: $PROJECT_ID)"
        break
      fi

      log_info "No matching Atlas project found; creating '$NEW_PROJECT_NAME'..."
      local PROJ_JSON ORG_ID_FOR_CREATE=""
      ORG_ID_FOR_CREATE="${MONGODB_ATLAS_ORG_ID:-}"
      if [ -z "$ORG_ID_FOR_CREATE" ]; then
        local ORGS_JSON
        ORGS_JSON=$(atlas organizations list -o json 2>"$ORGS_ERR") || ORGS_JSON=""
        ORG_ID_FOR_CREATE=$(echo "$ORGS_JSON" | jq -r '.results[0].id // empty' 2>/dev/null)
        if [ -n "$ORG_ID_FOR_CREATE" ]; then
          log_info "Using organization ID: $ORG_ID_FOR_CREATE"
        fi
      fi

      if [ -n "$ORG_ID_FOR_CREATE" ]; then
        PROJ_JSON=$(atlas projects create "$NEW_PROJECT_NAME" --orgId "$ORG_ID_FOR_CREATE" -o json 2>"$CREATE_ERR") || PROJ_JSON=""
      else
        PROJ_JSON=$(atlas projects create "$NEW_PROJECT_NAME" -o json 2>"$CREATE_ERR") || PROJ_JSON=""
      fi

      if [ -n "$PROJ_JSON" ]; then
        PROJECT_ID=$(echo "$PROJ_JSON" | jq -r '.id // empty')
        if [ -z "$PROJECT_ID" ]; then
          log_error "Could not get project ID from create response"
          exit 1
        fi
        log_success "Created project: $PROJECT_ID"
        break
      fi

      local SESSION_EXPIRED=false
      [ -s "$CREATE_ERR" ] && grep -qi "session expired" "$CREATE_ERR" 2>/dev/null && SESSION_EXPIRED=true
      [ "$SESSION_EXPIRED" = false ] && [ -s "$LIST_ERR" ] && grep -qi "session expired" "$LIST_ERR" 2>/dev/null && SESSION_EXPIRED=true
      [ "$SESSION_EXPIRED" = false ] && [ -s "$ORGS_ERR" ] && grep -qi "session expired" "$ORGS_ERR" 2>/dev/null && SESSION_EXPIRED=true
      if [ "$SESSION_EXPIRED" = true ] && [ "$ATLAS_RETRY" -eq 0 ]; then
        if [ "${MONGODB_ATLAS_NONINTERACTIVE:-0}" = "1" ] && [ ! -t 0 ]; then
          log_error "Atlas session expired. Setup is non-interactive; use API keys (see docs/kratos/mongodb-atlas-setup.md)."
          exit 1
        fi
        echo ""
        log_warning "Atlas session expired. You need to sign in again."
        log_info "Running: atlas auth login"
        echo ""
        if [ -t 0 ] && atlas auth login; then
          save_atlas_credentials
          restart_after_interactive_auth "session refresh login" "$@" || true
          log_success "Logged in. Retrying project setup..."
          echo ""
          ATLAS_RETRY=1
          continue
        fi
        log_error "Login failed or was cancelled (run 'atlas auth login' and re-run setup)"
        exit 1
      fi

      local CREATE_UNAUTHORIZED=false
      [ -s "$CREATE_ERR" ] && grep -qiE "unauthorized|forbidden|not authorized" "$CREATE_ERR" 2>/dev/null && CREATE_UNAUTHORIZED=true

      if [ "$CREATE_UNAUTHORIZED" = true ]; then
        log_warning "Atlas API auth works, but this key cannot create projects."
        if [ "$ATLAS_AUTH_FALLBACK_RETRY" -eq 0 ] && [ -t 0 ]; then
          echo ""
          log_info "Falling back to Atlas user login for this run..."
          log_info "Running: atlas auth login"
          echo ""
          if fallback_to_user_auth_once; then
            restart_after_interactive_auth "fallback user auth" "$@" || true
            log_success "User auth active. Retrying project setup..."
            echo ""
            ATLAS_AUTH_FALLBACK_RETRY=1
            continue
          fi
          log_error "Atlas user login failed or was cancelled."
        fi
        log_info "Grant this API key an Atlas org role with project-create capability (for example: Organization Project Creator),"
        if [ "$PRODUCTION_MODE" = true ]; then
          log_info "or set MONGODB_ATLAS_PRODUCTION_PROJECT_ID and re-run."
        else
          log_info "or set MONGODB_ATLAS_PROJECT_ID and re-run setup."
        fi
      else
        log_warning "Could not create project and no existing project named '$NEW_PROJECT_NAME' (or dev legacy names) was found."
      fi

      if [ -s "$CREATE_ERR" ]; then
        echo ""
        echo -e "${YELLOW}Atlas create error:${NC}"
        sed 's/^/  /' "$CREATE_ERR"
        echo ""
      fi

      if [ "$HAS_PROJECTS" = true ]; then
        log_info "Listing your Atlas projects:"
        echo ""
        echo "$LIST_JSON" | jq -r '.results[] | "  \(.name)  →  \(.id)"'
        echo ""
        if [ -t 0 ]; then
          log_info "Enter a Project ID from the list above (or create one at https://cloud.mongodb.com)"
          read -r -p "Enter Project ID to use for this codebase (or press Enter to exit): " PROJECT_ID
          PROJECT_ID=$(echo "$PROJECT_ID" | xargs)
          if [ -n "$PROJECT_ID" ]; then
            log_success "Using project: $PROJECT_ID"
            break
          fi
        fi
      fi

      if [ "$PRODUCTION_MODE" = true ]; then
        log_info "Set MONGODB_ATLAS_PRODUCTION_PROJECT_ID (and optionally MONGODB_ATLAS_ORG_ID) and re-run, or create a project in Atlas UI: https://cloud.mongodb.com"
      else
        log_info "Set MONGODB_ATLAS_PROJECT_ID (and optionally MONGODB_ATLAS_ORG_ID) and re-run, or create a project in Atlas UI: https://cloud.mongodb.com"
      fi
      exit 1
    done
  else
    log_info "Using existing project: $PROJECT_ID"
  fi

  # Reuse legacy cluster hostnames in the resolved project (avoid a second M0 in the same project).
  if [ "$PRODUCTION_MODE" != true ]; then
    local try_cluster found_cluster=""
    for try_cluster in \
      "${SLUG_LOWER}-dev-cluster" \
      "${SLUG_LOWER}-local-cluster" \
      "${SLUG_LOWER}-staging-cluster" \
      "${SLUG_LOWER}-cluster"; do
      if atlas clusters describe "$try_cluster" --projectId "$PROJECT_ID" &>/dev/null; then
        found_cluster="$try_cluster"
        break
      fi
    done
    if [ -n "$found_cluster" ] && [ "$found_cluster" != "$CLUSTER_NAME" ]; then
      log_info "Reusing existing cluster '$found_cluster' (new installs use '${SLUG_LOWER}-dev-cluster' in project '${SLUG_LOWER}-dev')"
      CLUSTER_NAME="$found_cluster"
    fi
    # DB + user always follow dev naming; credentials are created/updated on whichever cluster host we reuse.
  fi

  local REUSE_EXISTING=false
  if atlas clusters describe "$CLUSTER_NAME" --projectId "$PROJECT_ID" &>/dev/null; then
    if [[ "${MONGODB_ATLAS_NONINTERACTIVE:-}" == "1" || "$YES_FLAG" == true ]]; then
      REUSE_EXISTING=true
      log_info "Cluster '$CLUSTER_NAME' already exists; reusing and updating credentials"
    else
      log_warning "Cluster '$CLUSTER_NAME' already exists"
      read -p "Reuse it and create/update credentials? (y/N) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Exiting. Delete the cluster in Atlas UI if you want to recreate."
        exit 0
      fi
      REUSE_EXISTING=true
    fi
  fi

  if [ "$REUSE_EXISTING" = false ]; then
    log_info "Creating M0 cluster in EU_CENTRAL_1 (eu-central-1)..."
    local CREATE_OUT CREATE_ERR CREATE_EXIT
    CREATE_OUT=$(mktemp)
    CREATE_ERR=$(mktemp)
    set +e
    atlas clusters create "$CLUSTER_NAME" \
      --projectId "$PROJECT_ID" \
      --provider AWS \
      --region EU_CENTRAL_1 \
      --tier M0 \
      -o json >"$CREATE_OUT" 2>"$CREATE_ERR"
    CREATE_EXIT=$?
    set -e
    if [ "$CREATE_EXIT" -ne 0 ]; then
      log_error "Failed to create cluster"
      if [ -s "$CREATE_ERR" ]; then
        echo ""
        echo -e "${RED}Atlas CLI error:${NC}"
        sed 's/^/  /' "$CREATE_ERR"
        echo ""
      fi
      log_info "Common causes: free-tier limit (one M0 per project/account), billing not enabled, or region restrictions. Check https://cloud.mongodb.com"
      rm -f "$CREATE_OUT" "$CREATE_ERR"
      exit 1
    fi
    rm -f "$CREATE_OUT" "$CREATE_ERR"
    log_success "Cluster creation started"

    log_info "Waiting for cluster to become available (may take 3–5 min)..."
    if ! atlas clusters watch "$CLUSTER_NAME" --projectId "$PROJECT_ID" 2>/dev/null; then
      log_error "Cluster watch failed or timed out"
      exit 1
    fi
    log_success "Cluster available"
  fi

  local DB_PASSWORD
  DB_PASSWORD=$(gen_password)
  local CREDS_VALID=true
  if ! atlas dbusers describe "$DB_USER" --projectId "$PROJECT_ID" &>/dev/null; then
    log_info "Creating database user: $DB_USER"
    if ! atlas dbusers create readWriteAnyDatabase \
      --username "$DB_USER" \
      --password "$DB_PASSWORD" \
      --projectId "$PROJECT_ID" 2>/dev/null; then
      log_error "Failed to create database user"
      exit 1
    fi
    log_success "Database user created"
  else
    log_info "Database user '$DB_USER' exists; updating password"
    if ! atlas dbusers update "$DB_USER" \
      --password "$DB_PASSWORD" \
      --projectId "$PROJECT_ID" 2>/dev/null; then
      log_warning "Could not update password; skipping backend/.env update"
      CREDS_VALID=false
    else
      log_success "Password updated"
    fi
  fi

  if [ "$CREDS_VALID" = false ]; then exit 0; fi

  local access_comment="Allow all - dev setup"
  [ "$PRODUCTION_MODE" = true ] && access_comment="Allow all - prod setup (tighten in Atlas for production)"
  log_info "Adding 0.0.0.0/0 to IP access list"
  if atlas accessLists create "0.0.0.0/0" \
    --type cidrBlock \
    --projectId "$PROJECT_ID" \
    --comment "$access_comment" 2>/dev/null; then
    log_success "IP access list updated"
  else
    log_warning "0.0.0.0/0 may already exist (continuing)"
  fi

  local SRV_RAW
  SRV_RAW=$(atlas clusters connectionStrings describe "$CLUSTER_NAME" --projectId "$PROJECT_ID" -o json | jq -r '.standardSrv // .connectionStrings.standardSrv // empty')
  if [ -z "$SRV_RAW" ]; then
    log_error "Could not get connection string"
    exit 1
  fi

  local rest="${SRV_RAW#mongodb+srv://}"
  local HOST="${rest%%/*}"
  HOST="${HOST%%\?*}"
  local PARAMS="${rest#*\?}"
  if [ "$PARAMS" = "$rest" ]; then PARAMS="retryWrites=true&w=majority"; fi
  local MONGODB_URI_VAL="mongodb+srv://${DB_USER}:${DB_PASSWORD}@${HOST}/?${PARAMS}"

  mkdir -p "${BACKEND_DIR}"

  if [ "$PRODUCTION_MODE" = true ]; then
    log_success "Production Atlas cluster ready (backend/.env unchanged — single-URI workflows keep MONGODB_URI from dev setup)."
    log_info "To point deploys at this dedicated cluster, set MONGODB_URI to:"
    echo "  MONGODB_URI=${MONGODB_URI_VAL}"
    log_info "Deploy scripts derive staging/prod DB names from context/config.json (${SLUG_LOWER}-staging / ${SLUG_LOWER}-prod)."
  else
    local keys_re='^MONGODB_URI=|^MONGODB_DB_NAME=|^MONGODB_URI_STAGING=|^MONGODB_DB_NAME_STAGING=|^MONGODB_URI_PRODUCTION=|^MONGODB_DB_NAME_PRODUCTION='
    if [ -f "${BACKEND_ENV}" ]; then
      grep -v -E "$keys_re" "${BACKEND_ENV}" 2>/dev/null > "${BACKEND_ENV}.bak" || true
      if [ -s "${BACKEND_ENV}.bak" ]; then printf '\n' >> "${BACKEND_ENV}.bak"; fi
      {
        printf '%s=%s\n' "MONGODB_URI" "$MONGODB_URI_VAL"
        printf '%s=%s\n' "MONGODB_DB_NAME" "$DB_NAME"
      } >> "${BACKEND_ENV}.bak"
      mv "${BACKEND_ENV}.bak" "${BACKEND_ENV}"
    else
      {
        printf '%s=%s\n' "MONGODB_URI" "$MONGODB_URI_VAL"
        printf '%s=%s\n' "MONGODB_DB_NAME" "$DB_NAME"
      } > "${BACKEND_ENV}"
    fi
    log_success "Updated backend/.env (staging/prod use same URI; DB names ${SLUG_LOWER}-staging / ${SLUG_LOWER}-prod come from context/config.json at deploy)"
  fi

  echo ""
  echo "  Cluster:  $CLUSTER_NAME (M0, EU_CENTRAL_1)"
  echo "  DB name:  $DB_NAME"
  echo "  User:     $DB_USER"
  echo ""
  if [ "$PRODUCTION_MODE" != true ]; then
    log_info "Next: ./scripts/dev.sh setup  (or ./scripts/dev.sh start)"
    log_info "Optional dedicated prod cluster: ./scripts/initial-setup/mongodb-atlas.sh --production --yes"
  fi
  echo ""
}

main "$@"
