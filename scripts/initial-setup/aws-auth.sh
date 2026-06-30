#!/bin/bash
# One-time AWS auth for Kratos setup (S3 secrets + deploy). Opens browser via `aws login`.
set -e

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${SETUP_DIR}/../lib.sh"

mkdir -p "${HOME}/.aws"
if [ ! -f "${HOME}/.aws/config" ] || ! grep -qE '^\[default\]' "${HOME}/.aws/config" 2>/dev/null; then
  cat > "${HOME}/.aws/config" <<'EOF'
[default]
region = eu-central-1
output = json
EOF
  log_success "Wrote ~/.aws/config (region eu-central-1)"
fi

log_info "Opening AWS browser login (complete sign-in, then re-run setup)..."
aws login

if aws sts get-caller-identity >/dev/null 2>&1; then
  save_aws_credentials
  log_success "AWS authenticated"
else
  log_error "AWS login did not complete. Run this script again from an interactive terminal."
  exit 1
fi
