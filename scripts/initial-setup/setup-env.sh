#!/bin/bash
# One-time environment setup for mnb-extraction microservice.
# Mirrors kratos-main scripts/initial-setup/kratos-setup.sh (secrets + Atlas only).
# Run from project root after AWS CLI is configured (aws configure or aws sso login).

set -e

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SETUP_DIR}/../.." && pwd)"

# shellcheck source=../lib.sh
source "${SETUP_DIR}/../lib.sh"
# shellcheck source=../local-tools-path.sh
source "${SETUP_DIR}/../local-tools-path.sh"
# shellcheck source=./lib-secrets-key.sh
source "${SETUP_DIR}/lib-secrets-key.sh"

export MONGODB_ATLAS_NONINTERACTIVE=1

echo ""
echo -e "${CYAN}  MNB Extraction — environment setup${NC}"
echo ""

# Do not seed backend/.env from .env.example — pull-s3-secrets.sh requires no KEY= lines yet.

if [ -z "$(kratos_secrets_key_lookup)" ]; then
  if [ -t 0 ]; then
    log_info "Store the Kratos secrets decryption key (one time per machine):"
    bash "${SETUP_DIR}/secrets-key.sh" set
  else
    log_error "KRATOS_SECRETS_KEY not set. Export it or run: ./scripts/initial-setup/secrets-key.sh set"
    exit 1
  fi
else
  log_success "KRATOS_SECRETS_KEY available on this device"
fi

load_device_credentials

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  if [ -t 0 ]; then
    log_info "AWS not authenticated — starting browser login..."
    bash "${SETUP_DIR}/aws-auth.sh"
  else
    log_error "AWS not authenticated. From your terminal run:"
    log_info "  cd ${PROJECT_ROOT} && source scripts/local-tools-path.sh && ./scripts/initial-setup/aws-auth.sh"
    exit 1
  fi
fi

log_info "Pulling org secrets from S3 into backend/.env..."
if ! bash "${SETUP_DIR}/pull-s3-secrets.sh"; then
  log_error "S3 secrets pull failed. Configure AWS (aws configure / aws sso login) and re-run setup."
  exit 1
fi

# Atlas API keys from S3 bundle (kratos-main pattern — no interactive atlas auth login)
if [ -f "${BACKEND_DIR}/.env" ]; then
  atlas_pub=$(grep '^MONGODB_ATLAS_PUBLIC_API_KEY=' "${BACKEND_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]$//")
  atlas_priv=$(grep '^MONGODB_ATLAS_PRIVATE_API_KEY=' "${BACKEND_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]$//")
  atlas_org=$(grep '^MONGODB_ATLAS_ORG_ID=' "${BACKEND_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]$//")
  if [ -n "$atlas_pub" ] && [ -n "$atlas_priv" ]; then
    export MONGODB_ATLAS_PUBLIC_API_KEY="$atlas_pub"
    export MONGODB_ATLAS_PRIVATE_API_KEY="$atlas_priv"
    log_info "Using MongoDB Atlas API keys from backend/.env"
  fi
  if [ -n "$atlas_org" ]; then
    export MONGODB_ATLAS_ORG_ID="$atlas_org"
  fi
fi

if ! command -v atlas &>/dev/null; then
  log_error "Atlas CLI not found. Install: brew install mongodb-atlas-cli"
  exit 1
fi

ensure_atlas_session

log_info "Creating or updating MongoDB Atlas dev cluster..."
bash "${SETUP_DIR}/mongodb-atlas.sh" --yes

log_info "Installing npm dependencies..."
npm install --no-audit --no-fund
(cd "${BACKEND_DIR}" && npm install --no-audit --no-fund)

echo ""
log_success "Environment setup complete."
log_info "Review backend/.env, then deploy:"
log_info "  git checkout main"
log_info "  ./scripts/dev.sh verify backend"
log_info "  ./scripts/dev.sh deploy-be"
log_info "  ./scripts/dev.sh post-deploy"
echo ""
