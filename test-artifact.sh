#!/usr/bin/env bash
#
# test-artifact.sh — Elementor CSS Shifter Audit & API Discovery Tool
#
# Usage:
#   ./test-artifact.sh [site-url] [options]
#   ./test-artifact.sh --api [options]
#   ./test-artifact.sh --bake [options]
#
# Environment Configuration (.env):
#   SHIFTER_ACCESS_TOKEN   Long-lived access token (automatically updated)
#   SHIFTER_USER           (Optional) Username for auto-renewal
#   SHIFTER_PASS           (Optional) Password for auto-renewal

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Globals ──────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
PAGES_CHECKED=0
SAMPLE_SIZE=0
SITEMAP_FROM=""
PRIME_ONLY=false
USE_API=false
DO_BAKE=false
DEEP_AUDIT=false
BAKE_NAME="Full Lifecycle Regression Audit"
SITE_ID=""
ACCESS_TOKEN=""
DEFAULT_SITE_ID="3215b04c-84e4-4a42-8132-902bb6d4b51e" # NCPC
ENV_FILE="$(dirname "$0")/.env"
ARTIFACTS_DIR="$(dirname "$0")/.artifacts"

declare -A ELEMENTOR_VERSIONS=()
declare -a FAILED_PAGES=()

# ── Helpers ──────────────────────────────────────────────────────────
pass()  { PASS_COUNT=$((PASS_COUNT+1)); echo -e "  ${GREEN}✓${RESET} $1"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT+1)); echo -e "  ${RED}✗${RESET} $1"; }
warn()  { WARN_COUNT=$((WARN_COUNT+1)); echo -e "  ${YELLOW}⚠${RESET} $1"; }
info()  { echo -e "  ${CYAN}ℹ${RESET} $1"; }

usage() {
    echo "Usage: $0 [site-url] [options]"
    echo "       $0 --api [--site-id ID] [options]"
    echo "       $0 --bake [--site-id ID] [options]"
    echo ""
    echo "  --api               Automatically find and audit the latest artifact"
    echo "  --bake              Trigger a full build cycle (Stop WP → Bake → Audit → Start WP)"
    echo "  --name TITLE        Title for the new Artifact (Default: Full Lifecycle Regression Audit)"
    echo "  --deep-audit        Perform side-by-side HTML diffing (Artifact vs Staging)"
    echo "  --site-id ID        Shifter Site ID (Default: NationalCPC)"
    echo "  --sample N          Test only N random pages (+ homepage)"
    echo "  --sitemap-from URL  Pull sitemap from a different origin"
    echo "  --prime             Only visit URLs to rebuild metadata (Staging only)"
    echo ""
    echo "Tip: Make sure to 'Sync Plugin' in the WP Pusher dashboard BEFORE running --bake"
    exit 2
}

# ── Env Management ───────────────────────────────────────────────────
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^#.* ]] && continue
            [[ -z "$line" ]] && continue
            if [[ "$line" == *"="* ]]; then
                local key="${line%%=*}"
                local value="${line#*=}"
                # Strip leading/trailing quotes
                value="${value%\"}"; value="${value#\"}"
                value="${value%\'}"; value="${value#\'}"
                export "$key=$value"
            fi
        done < "$ENV_FILE"
    fi
}

save_token_to_env() {
    local token="$1"
    if [[ ! -f "$ENV_FILE" ]]; then
        touch "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi
    if grep -q "SHIFTER_ACCESS_TOKEN" "$ENV_FILE"; then
        sed -i "s/^SHIFTER_ACCESS_TOKEN=.*/SHIFTER_ACCESS_TOKEN=$token/" "$ENV_FILE"
    else
        echo "SHIFTER_ACCESS_TOKEN=$token" >> "$ENV_FILE"
    fi
}

# ── JWT Validation ───────────────────────────────────────────────────
jwt_is_valid() {
    local token="$1"
    [[ -z "$token" || "$token" == "null" ]] && return 1
    local payload=$(echo "$token" | cut -d'.' -f2 || echo "")
    [[ -z "$payload" ]] && return 1
    local len=$(( ${#payload} % 4 ))
    if [ $len -eq 2 ]; then payload="${payload}=="; elif [ $len -eq 3 ]; then payload="${payload}="; fi
    local decoded=$(echo "$payload" | base64 -d 2>/dev/null || echo "{}")
    local exp=$(echo "$decoded" | jq -r '.exp // 0')
    local now=$(date +%s)
    [[ "$exp" -ne 0 && "$now" -lt "$exp" ]] && return 0
    return 1
}

# ── Shifter API Logic ───────────────────────────────────────────────
shifter_login() {
    load_env
    ACCESS_TOKEN="${SHIFTER_ACCESS_TOKEN:-}"
    if jwt_is_valid "$ACCESS_TOKEN"; then return 0; fi
    echo -e "${BOLD}── Shifter API Authentication ──${RESET}" >&2
    local user="${SHIFTER_USER:-}"
    local pass="${SHIFTER_PASS:-}"
    if [[ -z "$user" || -z "$pass" ]]; then
        info "Access token expired or not found. Please provide credentials:"
        echo -ne "  Username: " >&2; read -r user
        echo -ne "  Password: " >&2; read -rs pass; echo "" >&2
    fi
    local response=$(curl -s https://api.getshifter.io/latest/login -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$user\", \"password\":\"$pass\"}")
    ACCESS_TOKEN=$(echo "$response" | jq -r '.AccessToken // empty')
    if [[ -z "$ACCESS_TOKEN" ]]; then echo -e "${RED}Error: Shifter API Login failed.${RESET}" >&2; exit 1; fi
    save_token_to_env "$ACCESS_TOKEN"
    echo -e "  ${GREEN}✓${RESET} Authenticated successfully" >&2
}

shifter_get_latest_artifact() {
    local site_id="$1"
    info "Fetching latest artifact info..." >&2
    local artifact_data=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r 'sort_by(.created_at) | last')
    if [[ -z "$artifact_data" || "$artifact_data" == "null" ]]; then echo -e "${RED}Error: No artifacts found for site ${site_id}${RESET}" >&2; exit 1; fi
    local id=$(echo "$artifact_data" | jq -r '.artifact_id')
    local status=$(echo "$artifact_data" | jq -r '.status')
    echo -e "  Latest:   ${CYAN}${id}${RESET}" >&2
    echo -e "  Status:   ${BOLD}${status}${RESET}" >&2
    if [[ "$status" == "increation" ]]; then
        shifter_wait_for_bake "$site_id" "$id"
        # Refresh status after wait
        artifact_data=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r ".[] | select(.artifact_id==\"$id\")")
        status=$(echo "$artifact_data" | jq -r '.status')
    fi
    [[ "$status" == "ready" || "$status" == "published-shifter" ]] && { echo -e "  ${GREEN}✓${RESET} Artifact is ready" >&2; echo "$id"; } || { echo -e "${RED}Error: Artifact failed.${RESET}" >&2; exit 1; }
}

shifter_stop_wordpress() {
    local site_id="$1"
    info "Stopping WordPress instance..." >&2
    local status=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.stock_state')
    
    if [[ "$status" != "inservice" && "$status" != "starting" && "$status" != "stopping" ]]; then
        echo -e "  ${GREEN}✓${RESET} WordPress is not in-service (${status})" >&2
        return 0
    fi

    curl -s "https://api.getshifter.io/latest/sites/${site_id}/wordpress_site/stop" -X POST -H "Authorization: ${ACCESS_TOKEN}" >/dev/null
    while [[ "$status" == "inservice" || "$status" == "stopping" ]]; do
        echo -ne "  ${YELLOW}⌛ Transitioning to stopped... (Current: ${status})\r${RESET}" >&2
        sleep 5
        status=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.stock_state')
    done
    echo -e "\n  ${GREEN}✓${RESET} WordPress stopped" >&2
}

shifter_start_wordpress() {
    local site_id="$1"
    info "Starting WordPress instance..." >&2
    curl -s "https://api.getshifter.io/latest/sites/${site_id}/wordpress_site/start" -X POST -H "Authorization: ${ACCESS_TOKEN}" >/dev/null
    local status="stopped"
    while [[ "$status" != "inservice" ]]; do
        echo -ne "  ${YELLOW}⌛ Waiting for WordPress to be in-service...\r${RESET}" >&2
        status=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.stock_state')
        [[ "$status" != "inservice" ]] && sleep 10
    done
    echo -e "\n  ${GREEN}✓${RESET} WordPress instance is live" >&2
}

shifter_start_bake() {
    local site_id="$1"
    local title="${2:-$BAKE_NAME}"
    info "Starting new Bake: ${BOLD}${title}${RESET} (Generating Artifact)..." >&2
    
    # 1. Start the Bake
    local aid=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}/artifacts" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.artifact_id')
        
    [[ -z "$aid" || "$aid" == "null" ]] && { echo -e "${RED}Error: Failed to start bake.${RESET}" >&2; exit 1; }
    
    # 2. Set the Artifact Name (Two-step process required by Shifter API)
    local body=$(jq -n --arg t "$title" '{"artifact_name": $t}')
    curl -s -X PUT "https://api.getshifter.io/latest/sites/${site_id}/artifacts/${aid}/artifact_name" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${ACCESS_TOKEN}" \
        -d "$body" >/dev/null

    echo "$aid"
}

shifter_wait_for_bake() {
    local site_id="$1"
    local aid="$2"
    local start_t=$(date +%s)
    local status="increation"
    while [[ "$status" == "increation" ]]; do
        local progress=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}/check_generator_process" -H "Authorization: ${ACCESS_TOKEN}")
        local percent=$(echo "$progress" | jq -r '.percent // 0')
        local current=$(echo "$progress" | jq -r '.created_url // 0')
        local total=$(echo "$progress" | jq -r '.sum_url // 0')
        local step=$(echo "$progress" | jq -r '.step // "Starting"')
        echo -ne "  ${YELLOW}⌛ Bake Progress: ${percent}% (${current}/${total} pages) - ${step}...\r${RESET}" >&2
        
        # Poll artifact status directly
        local artifact_data=$(curl -s "https://api.getshifter.io/latest/sites/${site_id}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r ".[] | select(.artifact_id==\"$aid\")")
        status=$(echo "$artifact_data" | jq -r '.status')
        [[ "$status" == "error" ]] && { echo -e "\n${RED}Error: Bake failed.${RESET}" >&2; exit 1; }
        [[ "$status" == "ready" || "$status" == "published-shifter" ]] && break
        sleep 10
    done
    local end_t=$(date +%s); local dur=$((end_t - start_t))
    echo -e "\n  ${GREEN}✓${RESET} Bake completed in ${BOLD}$((dur/60))m $((dur%60))s${RESET}" >&2
}

shifter_launch_preview() {
    local site_id="$1"
    local aid="$2"
    info "Activating Preview for Artifact: ${aid}" >&2
    curl -s "https://api.getshifter.io/latest/sites/${site_id}/artifacts/${aid}/preview" -X POST -H "Authorization: ${ACCESS_TOKEN}" >/dev/null
    echo -ne "  ${YELLOW}⌛ Provisioning static environment... Waiting 20s...\r${RESET}" >&2; sleep 20
    echo -e "\n  ${GREEN}✓${RESET} Preview environment provisioned" >&2
}

# ── Regression Engine Logic ──────────────────────────────────────────
page_deep_audit() {
    local slug="$1"; local artifact_base="$2"; local staging_base="$3"; local aid="$4"
    # Enforce trailing slash
    [[ "$slug" != */ ]] && slug="${slug}/"
    local safe_s="${slug%/}"; safe_s="${safe_s#/}"
    [[ -z "$safe_s" ]] && safe_s="homepage"
    local folder="$ARTIFACTS_DIR/$aid/$safe_s"; mkdir -p "$folder"
    # Fetch with Referer header to bypass CloudFront hotlink protection
    curl -s -L -H "Authorization: ${ACCESS_TOKEN}" -H "Referer: ${artifact_base}/" -o "$folder/artifact.html" "${artifact_base}${slug}"
    curl -s -L -H "Referer: ${staging_base}/" -o "$folder/staging.html" "${staging_base}${slug}"
    
    # Audit logic
    if diff -u "$folder/artifact.html" "$folder/staging.html" > "$folder/diff.txt" 2>&1; then 
        rm -rf "$folder"; 
    else 
        echo -e "  ${RED}✗${RESET} Differences found in ${BOLD}${slug}${RESET}"
    fi
}

# ── Arguments & Orchestration ─────────────────────────────────────────
BASE_URL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api) USE_API=true; shift ;;
        --bake) DO_BAKE=true; USE_API=true; shift ;;
        --name) BAKE_NAME="$2"; shift 2 ;;
        --deep-audit) DEEP_AUDIT=true; shift ;;
        --site-id) SITE_ID="$2"; shift 2 ;;
        --sample) SAMPLE_SIZE="$2"; shift 2 ;;
        --sitemap-from) SITEMAP_FROM="${2%/}"; shift 2 ;;
        --prime) PRIME_ONLY=true; shift ;;
        *) BASE_URL="${1%/}"; shift ;;
    esac
done

if [[ "$USE_API" == true ]]; then
    shifter_login; SITE_ID="${SITE_ID:-$DEFAULT_SITE_ID}"
    STAGING_URL="https://${SITE_ID}.static.getshifter.net"
if [[ "$DO_BAKE" == true ]]; then
        # Check if a bake is already in progress to latch onto it
        LATEST_DATA=$(curl -s "https://api.getshifter.io/latest/sites/${SITE_ID}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r 'sort_by(.created_at) | last')
        LATEST_STATUS=$(echo "$LATEST_DATA" | jq -r '.status')
        if [[ "$LATEST_STATUS" == "increation" ]]; then
            AID=$(echo "$LATEST_DATA" | jq -r '.artifact_id')
            info "Latching onto existing bake: ${CYAN}${AID}${RESET}..." >&2
        else
            shifter_stop_wordpress "$SITE_ID"
            AID=$(shifter_start_bake "$SITE_ID" "$BAKE_NAME")
        fi
        shifter_wait_for_bake "$SITE_ID" "$AID"
        shifter_launch_preview "$SITE_ID" "$AID"
        shifter_start_wordpress "$SITE_ID"
    else
        AID=$(shifter_get_latest_artifact "$SITE_ID")
    fi
    BASE_URL="https://${AID}.preview.getshifter.io"
fi

[[ -z "$BASE_URL" ]] && usage
SITEMAP_URL="${SITEMAP_FROM:-$STAGING_URL}/sitemap.xml"

# Wait for Staging Readiness
if [[ -n "${STAGING_URL:-}" ]]; then
    info "Waiting for Staging to be responsive at ${SITEMAP_URL}..." >&2
    s_status=0; retry=0
    while [[ "$s_status" != "200" && "$retry" -lt 30 ]]; do
        s_status=$(curl -s -L -H "Referer: ${STAGING_URL:-$BASE_URL}/" -o /dev/null -w "%{http_code}" "$SITEMAP_URL" || echo "000")
        [[ "$s_status" != "200" ]] && { echo -ne "  ${YELLOW}⌛ Waiting for HTTP 200... (Current: ${s_status})\r${RESET}" >&2; sleep 10; retry=$((retry+1)); }
    done
    [[ "$s_status" != "200" ]] && { echo -e "\n${RED}Error: Staging sitemap unreachable.${RESET}" >&2; exit 1; }
    echo -e "\n  ${GREEN}✓${RESET} Staging is responsive. Settling 5s..." >&2; sleep 5
fi
TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
curl -s -H "Referer: ${STAGING_URL:-$BASE_URL}/" "$SITEMAP_URL" | grep -oP '<loc>\K[^<]+' | sed "s|https://[^/]*||g" > "$TMPDIR/all_slugs.txt"
[[ "$SAMPLE_SIZE" -gt 0 ]] && shuf -n "$SAMPLE_SIZE" "$TMPDIR/all_slugs.txt" > "$TMPDIR/audit.txt" || cp "$TMPDIR/all_slugs.txt" "$TMPDIR/audit.txt"

# ── Execution ──
if [[ "$DEEP_AUDIT" == true ]]; then
    echo -e "\n${BOLD}── Regression Audit (Deep Audit Mode) ──${RESET}"
    info "Comparing Artifact vs Staging (.artifacts/$AID/)..."
    JOBS=0; MAX=8
    while IFS= read -r slug; do
        page_deep_audit "$slug" "$BASE_URL" "$STAGING_URL" "$AID" &
        JOBS=$((JOBS+1)); [[ "$JOBS" -ge "$MAX" ]] && { wait -n; JOBS=$((JOBS-1)); }
    done < "$TMPDIR/audit.txt"; wait
    [[ -d "$ARTIFACTS_DIR/$AID" && -n "$(ls -A "$ARTIFACTS_DIR/$AID" 2>/dev/null)" ]] && fail "Regression conflicts found" || pass "No HTML regressions found"
fi

echo -e "\n${BOLD}── Elementor Asset Audit (Fidelity Check) ──${RESET}"
while IFS= read -r slug; do
    url="${BASE_URL}${slug}"; path="${slug:-/}"
    echo -e "\n${BOLD}${path}${RESET}"
    html="$TMPDIR/page.html"; curl -s -L -H "Authorization: ${ACCESS_TOKEN}" -H "Referer: ${BASE_URL}/" -o "$html" "$url"
    
    # Fidelity Checks
    grep -q "Shifter Elementor CSS Fix" "$html" && pass "Plugin heartbeat" || fail "Heartbeat MISSING"
    grep -oP "href='[^']*elementor/css/post-[^']*\'" "$html" | grep -v "\.[a-f0-9]\{10\}\.css" | grep -q "?ver=" && fail "CSS hashing MISSING" || pass "CSS hashing active"
    
    if grep -q "elementor-shape" "$html"; then
        grep -q "shapes.min.css" "$html" && pass "Shape divider linked" || fail "Shape divider link MISSING"
    fi
    
    css_urls=$(grep -oP "href='[^']*elementor[^']*\.css[^']*'" "$html" | sed "s/href='//;s/'$//" | grep -v '/wp-content/plugins/' || true)
    while IFS= read -r css; do 
        [[ -z "$css" ]] && continue
        [[ "$css" == /* ]] && css="${BASE_URL}${css}"
        [[ "$(curl -s -o /dev/null -H "Authorization: ${ACCESS_TOKEN}" -H "Referer: ${BASE_URL}/" -w "%{http_code}" "$css")" == "200" ]] || fail "CSS 404: $css"
    done <<< "$css_urls"
done < "$TMPDIR/audit.txt"
