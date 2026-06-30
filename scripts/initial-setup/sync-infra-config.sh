#!/bin/bash
# Generate infra/config.ts, update infra/sst.config.ts, and backend/serverless.yml service name from context/config.json.
# Sourced by kratos-setup.sh (initial-setup). Requires: CONFIG_FILE, PROJECT_ROOT (from lib.sh).

INFRA_DIR="${PROJECT_ROOT}/infra"
INFRA_CONFIG_TS="${INFRA_DIR}/config.ts"
SST_CONFIG_TS="${INFRA_DIR}/sst.config.ts"
BACKEND_SERVERLESS="${PROJECT_ROOT}/backend/serverless.yml"

# Deploy domain and infra flags are fixed for this template (not read from context/config.json).
DEFAULT_DOMAIN_BASE="49x.ai"
DEFAULT_SUBDOMAIN_DEPLOY=true
DEFAULT_CERTIFICATE_ARN="arn:aws:acm:us-east-1:838328005434:certificate/5d61dc1a-ef58-4321-a172-a8222674aa7d"
DEFAULT_ACCOUNT_ID="838328005434"

sync_infra_config() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -d "$INFRA_DIR" ]; then
        return 1
    fi

    local subdomain_name domain_base subdomain_deploy use_existing_bucket certificate_arn staging_certificate_arn account_id
    local bucket_candidate
    subdomain_name=$(effective_deploy_subdomain "$CONFIG_FILE")
    domain_base="$DEFAULT_DOMAIN_BASE"
    subdomain_deploy=$DEFAULT_SUBDOMAIN_DEPLOY

    bucket_candidate="${subdomain_name}.${domain_base}"
    use_existing_bucket=false
    if command -v aws &>/dev/null && aws s3api head-bucket --bucket "$bucket_candidate" 2>/dev/null; then
        use_existing_bucket=true
        log_info "Infra sync: S3 bucket ${bucket_candidate} already exists — useExistingBucket=true"
    fi
    certificate_arn=$(jq -r '.certificateArn // empty' "$CONFIG_FILE")
    [ -z "$certificate_arn" ] && certificate_arn="$DEFAULT_CERTIFICATE_ARN"
    staging_certificate_arn=$(jq -r '.stagingCertificateArn // empty' "$CONFIG_FILE")
    account_id=$(jq -r '.accountId // empty' "$CONFIG_FILE")
    [ -z "$account_id" ] && account_id="$DEFAULT_ACCOUNT_ID"

    # Escape double-quotes for use inside TS string literals
    subdomain_name="${subdomain_name//\"/\\\"}"
    domain_base="${domain_base//\"/\\\"}"
    certificate_arn="${certificate_arn//\"/\\\"}"
    staging_certificate_arn="${staging_certificate_arn//\"/\\\"}"
    account_id="${account_id//\"/\\\"}"

    cat > "$INFRA_CONFIG_TS" << EOF
export const config = {
  subdomainName: "$subdomain_name",
  domainBase: "$domain_base",
  subdomainDeploy: $subdomain_deploy, // Set to true to create Route53 subdomain + CloudFront custom domain
  useExistingBucket: $use_existing_bucket, // Set to true if bucket already exists, false to create new bucket
  certificateArn: "$certificate_arn",
  stagingCertificateArn: "$staging_certificate_arn", // Legacy; unused — staging uses certificateArn
  accountId: "$account_id"
};
EOF

    # Update SST app name in sst.config.ts to match subdomainName
    if [ -f "$SST_CONFIG_TS" ]; then
        sed -i.bak "s/name: \"[^\"]*\"/name: \"${subdomain_name//\//\\/}\"/" "$SST_CONFIG_TS" 2>/dev/null || true
        [ -f "${SST_CONFIG_TS}.bak" ] && rm -f "${SST_CONFIG_TS}.bak"
    fi

    # Derive Serverless service name from deploy host label (sanitized for Lambda/CloudFormation).
    # Must start with an alphabetic character (Serverless/CloudFormation requirement).
    local raw_sub
    raw_sub=$(effective_deploy_subdomain "$CONFIG_FILE")
    serverless_service_name=$(echo "$raw_sub" | sed 's/[^a-zA-Z0-9-]/-/g' | tr -s '-' | sed 's/^-//;s/-$//' | cut -c1-40)
    [ -z "$serverless_service_name" ] && serverless_service_name="defaultproject-backend"
    if ! echo "$serverless_service_name" | grep -qE '^[a-zA-Z]'; then
        serverless_service_name="app-${serverless_service_name}"
    fi

    # Update backend/serverless.yml service line so deploy and logs-be use this project's Lambdas
    if [ -f "$BACKEND_SERVERLESS" ]; then
        sed -i.bak "s/^service: .*$/service: ${serverless_service_name}/" "$BACKEND_SERVERLESS"
        [ -f "${BACKEND_SERVERLESS}.bak" ] && rm -f "${BACKEND_SERVERLESS}.bak"
    fi

    return 0
}
