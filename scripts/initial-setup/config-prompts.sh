#!/bin/bash
# Ensure context/config.json exists and prompt for clientName, projectName, subdomainName if needed.
# Sourced by kratos-setup.sh (initial-setup) and dev-deploy.sh. Sets: SLUG_LOWER, DB_NAME, GIT_REPO, DISPLAY_NAME, SUBDOMAIN_NAME (and CONFIG_FILE from lib).
# Optional first arg: "setup_only" — only prompt clientName, projectName; set subdomainName to slug; leave deploy-related keys as placeholders for first deploy.

# Replace spaces with "-" in config values (context/config.json must not contain spaces).
sanitize_config_value() {
    local v="$1"
    echo "${v// /-}"
}

# Sanitize slug for GitHub, MongoDB, DNS: alphanumeric and hyphen only.
# Strips non-ASCII and special chars to avoid mismatches (e.g. "ű49x" -> "49x").
slugify_safe() {
    local s="$1"
    s=$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-')
    # Collapse multiple hyphens, trim leading/trailing
    s=$(echo "$s" | sed 's/-\+/-/g; s/^-//; s/-$//')
    echo "$s"
}

# Replace spaces with "-" in config values (context/config.json must not contain spaces).
sanitize_config_value() {
    local v="$1"
    echo "${v// /-}"
}

# Sanitize slug for GitHub, MongoDB, DNS: alphanumeric and hyphen only.
# Strips non-ASCII and special chars to avoid mismatches (e.g. "ű49x" -> "49x").
slugify_safe() {
    local s="$1"
    s=$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-')
    # Collapse multiple hyphens, trim leading/trailing
    s=$(echo "$s" | sed 's/-\+/-/g; s/^-//; s/-$//')
    echo "$s"
}

# Write a key in context/config.json and verify. Exits on failure so updates are never silent.
# Values are sanitized: spaces are replaced with "-".
write_config_key() {
    local key="$1" value="$2" tmpfile
    value=$(sanitize_config_value "$value")
    tmpfile="${CONFIG_FILE}.tmp.$$"
    if ! jq --arg v "$value" --arg k "$key" '.[$k] = $v' "$CONFIG_FILE" > "$tmpfile" 2>/dev/null; then
        log_error "Failed to update context/config.json (key=$key). Check that the file is valid JSON."
        [ -f "$tmpfile" ] && rm -f "$tmpfile"
        exit 1
    fi
    if ! jq -e . "$tmpfile" >/dev/null 2>&1; then
        log_error "jq produced invalid JSON when updating context/config.json (key=$key)."
        rm -f "$tmpfile"
        exit 1
    fi
    mv "$tmpfile" "$CONFIG_FILE"
    local read_back
    read_back=$(jq -r --arg k "$key" '.[$k]' "$CONFIG_FILE")
    if [[ "$read_back" != "$value" ]]; then
        log_error "context/config.json was not updated correctly for key=$key (expected '$value', got '$read_back')."
        exit 1
    fi
}

ensure_config_and_prompts() {
    local setup_only="${1:-}"
    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "Creating $CONFIG_FILE with placeholders (you will be prompted to fill them)"
        mkdir -p "${PROJECT_ROOT}/context"
        echo '{"clientName":"free text (e.g. 49x)","projectName":"free text (e.g. myapp)","subdomainName":"free text (recommended: clientName-projectName)"}' > "$CONFIG_FILE"
    fi

    local CLIENT_NAME PROJECT_NAME SUBDOMAIN_NAME
    CLIENT_NAME=$(jq -r '.clientName' "$CONFIG_FILE")
    PROJECT_NAME=$(jq -r '.projectName' "$CONFIG_FILE")
    SUBDOMAIN_NAME=$(jq -r '.subdomainName // empty' "$CONFIG_FILE")

    local needs_prompt=false
    [[ "$CLIENT_NAME" == "free text"* || "$CLIENT_NAME" == *"e.g."* || -z "$CLIENT_NAME" ]] && needs_prompt=true
    [[ "$PROJECT_NAME" == "free text"* || "$PROJECT_NAME" == *"e.g."* || -z "$PROJECT_NAME" ]] && needs_prompt=true
    if [[ "$setup_only" != "setup_only" ]]; then
        [[ "$SUBDOMAIN_NAME" == "free text"* || "$SUBDOMAIN_NAME" == *"recommended"* || -z "$SUBDOMAIN_NAME" ]] && needs_prompt=true
    fi
    if [[ "$needs_prompt" == true && ! -t 0 ]]; then
        log_error "context/config.json has placeholder values but this terminal is not interactive (no TTY)."
        log_info "Run ./scripts/dev.sh setup from a terminal to fill values, or edit context/config.json manually."
        exit 1
    fi

    # Treat placeholder text or empty as "needs input" (covers repo template variants)
    if [[ "$CLIENT_NAME" == "free text"* || "$CLIENT_NAME" == *"e.g."* || -z "$CLIENT_NAME" ]]; then
        echo ""
        echo -e "${PURPLE}────────────────────────────────────────────────────────────${NC}"
        echo -e "${PURPLE}  Name your realm. The Ghost of Sparta needs to know who you serve.${NC}"
        echo -e "${PURPLE}────────────────────────────────────────────────────────────${NC}"
        echo ""
        read -r -p "Boy! clientName (e.g. 49x for internal projects): " CLIENT_NAME
        CLIENT_NAME=$(echo "$CLIENT_NAME" | xargs)
        if [[ -z "$CLIENT_NAME" ]]; then
            log_error "clientName is required."
            exit 1
        fi
        write_config_key "clientName" "$CLIENT_NAME"
        log_success "Set clientName to: $CLIENT_NAME"
    fi
    if [[ "$PROJECT_NAME" == "free text"* || "$PROJECT_NAME" == *"e.g."* || -z "$PROJECT_NAME" ]]; then
        echo ""
        echo -e "${PURPLE}────────────────────────────────────────────────────────────${NC}"
        echo -e "${PURPLE}  What do you call this battle?${NC}"
        echo -e "${PURPLE}────────────────────────────────────────────────────────────${NC}"
        echo ""
        read -r -p "Boy! projectName (e.g. myapp): " PROJECT_NAME
        PROJECT_NAME=$(echo "$PROJECT_NAME" | xargs)
        if [[ -z "$PROJECT_NAME" ]]; then
            log_error "projectName is required."
            exit 1
        fi
        write_config_key "projectName" "$PROJECT_NAME"
        log_success "Set projectName to: $PROJECT_NAME"
    fi

    CLIENT_NAME=$(jq -r '.clientName' "$CONFIG_FILE")
    PROJECT_NAME=$(jq -r '.projectName' "$CONFIG_FILE")
    SUBDOMAIN_NAME=$(jq -r '.subdomainName // empty' "$CONFIG_FILE")

    # MongoDB Atlas limits cluster names (64 chars). Scripts use {slug}-prod-cluster — reject overlong slugs early.
    while true; do
        local _slug_raw _slug_check _suggest
        _slug_raw="${CLIENT_NAME}-${PROJECT_NAME}"
        _slug_check=$(slugify_safe "$_slug_raw")
        if [[ -z "$_slug_check" ]]; then
            log_error "clientName and projectName produced an empty slug after sanitization. Use only letters, numbers, and hyphens."
            exit 1
        fi
        if [[ ${#_slug_check} -le $(atlas_max_slug_len) ]]; then
            break
        fi
        _suggest=$(atlas_suggest_slug_trim "$_slug_check")
        log_error "That clientName + projectName is too long for MongoDB Atlas (cluster names are limited to ${ATLAS_CLUSTER_NAME_MAX_LEN} characters; your combined slug is ${_slug_check} characters, max $(atlas_max_slug_len) for names like …-prod-cluster)."
        log_info "Shorten clientName and/or projectName. Example slug ≤$(atlas_max_slug_len) characters: ${_suggest}"
        if [[ ! -t 0 ]]; then
            log_error "Non-interactive: edit context/config.json with shorter clientName/projectName, then re-run."
            exit 1
        fi
        echo ""
        read -r -p "Boy! clientName (e.g. 49x for internal projects): " CLIENT_NAME
        CLIENT_NAME=$(echo "$CLIENT_NAME" | xargs)
        read -r -p "Boy! projectName (e.g. myapp): " PROJECT_NAME
        PROJECT_NAME=$(echo "$PROJECT_NAME" | xargs)
        if [[ -z "$CLIENT_NAME" || -z "$PROJECT_NAME" ]]; then
            log_error "clientName and projectName are required."
            exit 1
        fi
        write_config_key "clientName" "$CLIENT_NAME"
        write_config_key "projectName" "$PROJECT_NAME"
    done

    if [[ "$setup_only" == "setup_only" ]]; then
        # Setup-only: set subdomainName for deploy; do not prompt for deploy-related keys (done on first deploy).
        local SLUG_RAW SUGGESTED_SUBDOMAIN
        SLUG_RAW="${CLIENT_NAME}-${PROJECT_NAME}"
        if [[ "$(echo "$CLIENT_NAME" | tr '[:upper:]' '[:lower:]')" == "49x" ]]; then
            SUGGESTED_SUBDOMAIN=$(slugify_safe "$PROJECT_NAME")
        else
            SUGGESTED_SUBDOMAIN=$(slugify_safe "$SLUG_RAW")
        fi
        if [[ "$SUBDOMAIN_NAME" == "free text"* || "$SUBDOMAIN_NAME" == *"recommended"* || "$SUBDOMAIN_NAME" == *"e.g."* || -z "$SUBDOMAIN_NAME" ]]; then
            [[ -z "$SUGGESTED_SUBDOMAIN" ]] && SUGGESTED_SUBDOMAIN="default"
            write_config_key "subdomainName" "$SUGGESTED_SUBDOMAIN"
            log_success "Set subdomainName to: $SUGGESTED_SUBDOMAIN (default deploy hostname)"
        fi
    else
        if [[ "$SUBDOMAIN_NAME" == "free text"* || "$SUBDOMAIN_NAME" == *"recommended"* || "$SUBDOMAIN_NAME" == *"e.g."* || -z "$SUBDOMAIN_NAME" ]]; then
            local SUGGESTED_SUBDOMAIN
            # When client is 49x, suggest only projectName so domain is e.g. test.49x.ai instead of 49x-test.49x.ai
            if [[ "$(echo "$CLIENT_NAME" | tr '[:upper:]' '[:lower:]')" == "49x" ]]; then
                SUGGESTED_SUBDOMAIN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-')
            else
                SUGGESTED_SUBDOMAIN=$(echo "${CLIENT_NAME}-${PROJECT_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-')
            fi
            echo ""
            log_info "subdomainName is used for deployment (recommended: clientName-projectName, e.g. $SUGGESTED_SUBDOMAIN)."
            read -r -p "Enter subdomainName [default: $SUGGESTED_SUBDOMAIN]: " SUBDOMAIN_NAME
            SUBDOMAIN_NAME=$(echo "$SUBDOMAIN_NAME" | xargs)
            [[ -z "$SUBDOMAIN_NAME" ]] && SUBDOMAIN_NAME="$SUGGESTED_SUBDOMAIN"
            write_config_key "subdomainName" "$SUBDOMAIN_NAME"
            log_success "Set subdomainName to: $SUBDOMAIN_NAME"
        fi
    fi

    CLIENT_NAME=$(jq -r '.clientName' "$CONFIG_FILE")
    PROJECT_NAME=$(jq -r '.projectName' "$CONFIG_FILE")
    SUBDOMAIN_NAME=$(jq -r '.subdomainName // empty' "$CONFIG_FILE")

    local SLUG SLUG_RAW
    SLUG_RAW="${CLIENT_NAME}-${PROJECT_NAME}"
    SLUG_LOWER=$(slugify_safe "$SLUG_RAW")
    if [[ -z "$SLUG_LOWER" ]]; then
        log_error "clientName and projectName produced an empty slug after sanitization. Use only letters, numbers, and hyphens."
        exit 1
    fi
    if [[ "$(echo "$SLUG_RAW" | tr '[:upper:]' '[:lower:]')" != "$SLUG_LOWER" ]]; then
        log_info "Sanitized slug to valid chars (GitHub/DNS): $SLUG_LOWER"
    fi
    if [[ -z "$SUBDOMAIN_NAME" || "$SUBDOMAIN_NAME" == "free text"* ]]; then
        if [[ "$(echo "$CLIENT_NAME" | tr '[:upper:]' '[:lower:]')" == "49x" ]]; then
            SUBDOMAIN_NAME=$(slugify_safe "$PROJECT_NAME")
            [[ -z "$SUBDOMAIN_NAME" ]] && SUBDOMAIN_NAME="$SLUG_LOWER"
        else
            SUBDOMAIN_NAME="$SLUG_LOWER"
        fi
    fi

    DB_NAME="$SLUG_LOWER"
    GIT_REPO="49x-ai/${SLUG_LOWER}"
    DISPLAY_NAME="$PROJECT_NAME"
}

# Ensure deploy-related config (subdomainName only). domainBase, subdomainDeploy, and useExistingBucket
# are fixed or derived in sync_infra_config.sh / dev-deploy.sh (49x.ai template).
# Call from dev-deploy.sh when infra may be deployed. Exits if placeholders and non-interactive.
ensure_deploy_config() {
    [ -f "$CONFIG_FILE" ] || return 1
    local CLIENT_NAME PROJECT_NAME SUBDOMAIN_NAME
    CLIENT_NAME=$(jq -r '.clientName' "$CONFIG_FILE")
    PROJECT_NAME=$(jq -r '.projectName' "$CONFIG_FILE")
    SUBDOMAIN_NAME=$(jq -r '.subdomainName // empty' "$CONFIG_FILE")

    local needs_prompt=false
    [[ "$SUBDOMAIN_NAME" == "free text"* || "$SUBDOMAIN_NAME" == *"recommended"* || "$SUBDOMAIN_NAME" == *"e.g."* || -z "$SUBDOMAIN_NAME" ]] && needs_prompt=true
    if [[ "$needs_prompt" != true ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "Deploy config has placeholder values but this terminal is not interactive (no TTY)."
        log_info "Run deploy from an interactive terminal to set subdomainName, or edit context/config.json."
        exit 1
    fi

    if [[ "$SUBDOMAIN_NAME" == "free text"* || "$SUBDOMAIN_NAME" == *"recommended"* || "$SUBDOMAIN_NAME" == *"e.g."* || -z "$SUBDOMAIN_NAME" ]]; then
        local SUGGESTED_SUBDOMAIN
        if [[ "$(echo "$CLIENT_NAME" | tr '[:upper:]' '[:lower:]')" == "49x" ]]; then
            SUGGESTED_SUBDOMAIN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-')
        else
            SUGGESTED_SUBDOMAIN=$(echo "${CLIENT_NAME}-${PROJECT_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-zA-Z0-9-')
        fi
        [[ -z "$SUGGESTED_SUBDOMAIN" ]] && SUGGESTED_SUBDOMAIN="default"
        echo ""
        log_info "Subdomain for deployment (e.g. ${SUGGESTED_SUBDOMAIN}.49x.ai)."
        read -r -p "Enter subdomainName [default: $SUGGESTED_SUBDOMAIN]: " SUBDOMAIN_NAME
        SUBDOMAIN_NAME=$(echo "$SUBDOMAIN_NAME" | xargs)
        [[ -z "$SUBDOMAIN_NAME" ]] && SUBDOMAIN_NAME="$SUGGESTED_SUBDOMAIN"
        write_config_key "subdomainName" "$SUBDOMAIN_NAME"
        log_success "Set subdomainName to: $SUBDOMAIN_NAME"
    fi
}
