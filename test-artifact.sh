#!/usr/bin/env bash
#
# test-artifact.sh — Elementor CSS Shifter Audit & API Discovery Tool
#
set -euo pipefail

curl() { command curl --doh-url https://1.1.1.1/dns-query "$@"; }

# ── Dependencies ──────────────────────────────────────────────────────
check_dependencies() {
    local missing=()
    for cmd in jq curl xmldiff base64 perl tidy; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "\033[0;31mError: Missing required dependencies: ${missing[*]}\033[0m" >&2
        echo "Please run inside the guix shell as documented in TESTING.md." >&2
        exit 1
    fi
}
check_dependencies

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
SAMPLE_SIZE=0
SITEMAP_FROM=""
USE_API=false
DO_BAKE=false
DEEP_AUDIT=false
BAKE_NAME="Full Lifecycle Regression Audit"
SITE_ID="${SITE_ID:-}"
ACCESS_TOKEN=""
DEFAULT_SITE_ID="3215b04c-84e4-4a42-8132-902bb6d4b51e"
ENV_FILE="$(dirname "$0")/.env"
ARTIFACTS_DIR="$(dirname "$0")/artifacts"

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
    echo "  --bake              Trigger or latch onto a build cycle"
    echo "  --deep-audit        Perform side-by-side HTML diffing"
    echo "  --site-id ID        Shifter Site ID"
    echo "  --pages Slugs       Comma-separated slugs"
    echo "  --sample N          Test only N random pages"
    exit 2
}

# ── API Logic ───────────────────────────────────────────────────────
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^#.* ]] && continue
            [[ "$line" == *"="* ]] && { k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"; export "$k=$v"; }
        done < "$ENV_FILE"
    fi
}

save_token_to_env() {
    local t="$1"
    [[ ! -f "$ENV_FILE" ]] && { touch "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
    grep -q "SHIFTER_ACCESS_TOKEN" "$ENV_FILE" && sed -i "s/^SHIFTER_ACCESS_TOKEN=.*/SHIFTER_ACCESS_TOKEN=$t/" "$ENV_FILE" || echo "SHIFTER_ACCESS_TOKEN=$t" >> "$ENV_FILE"
}

jwt_is_valid() {
    local t="$1"
    [[ -z "$t" || "$t" == "null" ]] && return 1
    local p=$(echo "$t" | cut -d'.' -f2 || echo "")
    [[ -z "$p" ]] && return 1
    local exp=$(echo "$p" | base64 -d 2>/dev/null | jq -r '.exp // 0')
    [[ "$exp" -ne 0 && $(date +%s) -lt "$exp" ]] && return 0 || return 1
}

shifter_login() {
    load_env; ACCESS_TOKEN="${SHIFTER_ACCESS_TOKEN:-}"
    jwt_is_valid "$ACCESS_TOKEN" && return 0
    echo -e "${BOLD}── Shifter API Authentication ──${RESET}" >&2
    local user="${SHIFTER_USER:-}"; local pass="${SHIFTER_PASS:-}"
    if [[ -z "$user" ]]; then
        info "Credentials required:"
        echo -ne "  Username: " >&2; read -r user
        echo -ne "  Password: " >&2; read -rs pass; echo "" >&2
    fi
    local r=$(curl -s https://api.getshifter.io/latest/login -X POST -H "Content-Type: application/json" -d "{\"username\":\"$user\", \"password\":\"$pass\"}")
    ACCESS_TOKEN=$(echo "$r" | jq -r '.AccessToken // empty')
    [[ -z "$ACCESS_TOKEN" ]] && { echo -e "${RED}Error: Login failed.${RESET}" >&2; exit 1; }
    save_token_to_env "$ACCESS_TOKEN"
}

shifter_get_latest_artifact() {
    local s="$1"; info "Fetching latest artifact info..." >&2
    local d=$(curl -s --connect-timeout 5 "https://api.getshifter.io/latest/sites/${s}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r 'sort_by(.created_at) | last')
    [[ -z "$d" || "$d" == "null" ]] && { echo -e "${RED}Error: No artifacts found.${RESET}" >&2; exit 1; }
    echo "$d" | jq -r '.artifact_id'
}

shifter_stop_wordpress() {
    local s="$1"; info "Stopping WordPress..." >&2
    local st=$(curl -s --connect-timeout 5 "https://api.getshifter.io/latest/sites/${s}" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.stock_state')
    [[ "$st" != "inservice" ]] && return 0
    curl -s "https://api.getshifter.io/latest/sites/${s}/wordpress_site/stop" -X POST -H "Authorization: ${ACCESS_TOKEN}" >/dev/null
    while [[ "$st" == "inservice" ]]; do echo -ne "."; sleep 5; st=$(curl -s "https://api.getshifter.io/latest/sites/${s}" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.stock_state'); done; echo ""
}

shifter_start_wordpress() {
    local s="$1"; info "Starting WordPress..." >&2
    curl -s "https://api.getshifter.io/latest/sites/${s}/wordpress_site/start" -X POST -H "Authorization: ${ACCESS_TOKEN}" >/dev/null
    local st="stopped"
    while [[ "$st" != "inservice" ]]; do sleep 10; st=$(curl -s "https://api.getshifter.io/latest/sites/${s}" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.stock_state'); done
}

shifter_start_bake() {
    local s="$1"; local t="$2"
    info "Starting Bake: $t..." >&2
    local aid=$(curl -s "https://api.getshifter.io/latest/sites/${s}/artifacts" -X POST -H "Content-Type: application/json" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.artifact_id')
    curl -s -X PUT "https://api.getshifter.io/latest/sites/${s}/artifacts/${aid}/artifact_name" -H "Content-Type: application/json" -H "Authorization: ${ACCESS_TOKEN}" -d "{\"artifact_name\":\"$t\"}" >/dev/null || true
    echo "$aid"
}

shifter_wait_for_bake() {
    local s="$1"; local aid="$2"; local st="increation"
    while [[ "$st" == "increation" ]]; do
        local p=$(curl -s "https://api.getshifter.io/latest/sites/${s}/check_generator_process" -H "Authorization: ${ACCESS_TOKEN}")
        echo -ne "  ${YELLOW}⌛ Progress: $(echo "$p" | jq -r '.percent // 0')% \r${RESET}" >&2
        local d=$(curl -s "https://api.getshifter.io/latest/sites/${s}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r ".[] | select(.artifact_id==\"$aid\")")
        st=$(echo "$d" | jq -r '.status'); [[ "$st" == "ready" ]] && break; sleep 10
    done; echo -e "\n  ${GREEN}✓${RESET} Bake complete" >&2
}

shifter_launch_preview() {
    local s="$1"; local aid="$2"; info "Launching Preview for Artifact: ${aid}..." >&2
    curl -s "https://api.getshifter.io/latest/sites/${s}/artifacts/${aid}/preview" -X POST -H "Authorization: ${ACCESS_TOKEN}" >/dev/null; sleep 20
}

# ── Integrity Logic ─────────────────────────────────────────────────
check_asset_integrity() {
    local link="$1"; local ua="$2"; local art_base="$3"; local stg_base="${4:-}"
    local tmp=$(mktemp)
    local code=$(curl -s -L -H "User-Agent: $ua" -o "$tmp" -w "%{http_code}" "$link")
    if [[ "$code" == "200" ]]; then
        local size=$(stat -c%s "$tmp")
        if [[ "$size" -gt 0 ]]; then
            local o=$(grep -o "{" "$tmp" | wc -l); local c=$(grep -o "}" "$tmp" | wc -l)
            if [[ "$o" -ne "$c" ]]; then fail "Brace Mismatch: $link"
            elif grep -v "^$" "$tmp" | grep -q "{{WRAPPER}}"; then fail "Canary: $link" # Using grep -v to ignore blank lines in canary check
            else
                if [[ -n "$stg_base" && "$link" == *"/uploads/elementor/"* ]]; then
                    local base=$(echo "$link" | grep -oP "post-\d+\.css|custom-[^.]+\.css" | head -1)
                    if [[ -n "$base" ]]; then
                        local stg_link="${stg_base}/wp-content/uploads/elementor/css/${base}"
                        local stg_size=$(curl -s -L -o /dev/null -w "%{size_download}" "$stg_link")
                        if [[ "$stg_size" -gt 0 ]]; then
                             local min=$(( stg_size * 80 / 100 )); [[ "$size" -lt "$min" ]] && fail "Parity Fail: $link ($size vs $stg_size)" || pass "Asset: $(basename "$link")"
                        else pass "Asset: $(basename "$link")"
                        fi
                    else pass "Asset: $(basename "$link")"
                    fi
                else pass "Asset: $(basename "$link")"
                fi
            fi
        else fail "Empty Content: $link"
        fi
    else fail "Missing Asset ($code): $link"
    fi; rm -f "$tmp"
}

page_deep_audit() {
    local slug="$1"; local art_base="$2"; local stg_base="$3"; local aid="$4"
    [[ "$slug" != */ ]] && slug="${slug}/"
    local folder="$ARTIFACTS_DIR/$aid$slug"; mkdir -p "$folder"
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    curl -s -L -f -o "$folder/artifact.html" "${art_base}${slug}" || { echo -e "  ${YELLOW}⚠${RESET} Failed to fetch ${art_base}${slug}"; return 0; }
    curl -s -L -f -o "$folder/staging.html" "${stg_base}${slug}" || { echo -e "  ${YELLOW}⚠${RESET} Failed to fetch ${stg_base}${slug}"; return 0; }
    
    local art_dom=$(echo "$art_base" | sed -E 's|^https?://([^/]+).*|\1|')
    local stg_dom=$(echo "$stg_base" | sed -E 's|^https?://([^/]+).*|\1|')

    for f in "$folder/artifact.html" "$folder/staging.html"; do
        perl -0777 -pi -e 's/<!--.*?-->//gs' "$f"
        sed -i -E "s,(https?|webcal|//)?[:\\\\/%2F]+${art_dom},,g" "$f"
        sed -i -E "s,(https?|webcal|//)?[:\\\\/%2F]+${stg_dom},,g" "$f"
        sed -i 's|\\/|/|g' "$f"
        sed -i -E 's/elementor-element-[0-9a-fA-F]+/MASKED-ID/g' "$f"
        local t=$(mktemp); tidy -config tidy.config "$f" > "$t" 2>/dev/null || true
        if [[ ! -s "$t" ]]; then
            echo -e "  ${RED}✗${RESET} Deep Audit failed: tidy produced empty output for $f"
            rm -f "$t"
            return 1
        fi
        mv "$t" "$f"
    done

    local diff_output
    if ! diff_output=$(xmldiff "$folder/artifact.html" "$folder/staging.html" 2>&1); then
        echo -e "  ${RED}✗${RESET} Deep Audit failed: xmldiff error on ${slug}"
        return 1
    fi
    local structural=$(echo "$diff_output" | grep -E -v "\[move|^$" | tr -d '[:space:]' || true)
    if [[ -z "$structural" ]]; then # rm -rf "$folder"
        [[ "$DEEP_AUDIT" == true ]] && echo -e "  ${GREEN}✓${RESET} No regressions: ${slug}"
    else 
        echo -e "  ${RED}✗${RESET} Regression found: ${slug}"
        echo "$structural" | head -n 5 | sed 's/^/    /'
    fi
}

# ── Main Orchestration ─────────────────────────────────────────────
SUBPAGES=(); BASE_URL=""; load_env
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api) USE_API=true; shift ;;
        --bake) DO_BAKE=true; USE_API=true; shift ;;
        --deep-audit) DEEP_AUDIT=true; shift ;;
        --site-id) SITE_ID="$2"; shift 2 ;;
        --pages) IFS=',' read -r -a SUBPAGES <<< "$2"; shift 2 ;;
        --sample) SAMPLE_SIZE="$2"; shift 2 ;;
        *) [[ -z "$BASE_URL" ]] && BASE_URL="${1%/}" || SUBPAGES+=("${1%/}"); shift ;;
    esac
done

TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT

if [[ "$USE_API" == true ]]; then
    shifter_login; SITE_ID="${SITE_ID:-$DEFAULT_SITE_ID}"
    if [[ "$DO_BAKE" == true ]]; then
        info "Checking for existing bake..." >&2
        LATEST_DATA=$(curl -s "https://api.getshifter.io/latest/sites/${SITE_ID}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r 'sort_by(.created_at) | last')
        LATEST_STATUS=$(echo "$LATEST_DATA" | jq -r '.status')
        if [[ "$LATEST_STATUS" == "increation" ]]; then
            AID=$(echo "$LATEST_DATA" | jq -r '.artifact_id')
            info "Latching onto active bake: ${CYAN}${AID}${RESET}..." >&2
        else
            shifter_stop_wordpress "$SITE_ID"
            AID=$(shifter_start_bake "$SITE_ID" "$BAKE_NAME")
        fi
        shifter_wait_for_bake "$SITE_ID" "$AID"; shifter_launch_preview "$SITE_ID" "$AID"; shifter_start_wordpress "$SITE_ID"
        BASE_URL="https://${AID}.preview.getshifter.io"
    else
        AID=$(shifter_get_latest_artifact "$SITE_ID")
        LATEST_STATUS=$(curl -s "https://api.getshifter.io/latest/sites/${SITE_ID}/artifacts" -H "Authorization: ${ACCESS_TOKEN}" | jq -r ".[] | select(.artifact_id==\"$AID\") | .status")
        if [[ "$LATEST_STATUS" == "published-shifter" || "$LATEST_STATUS" == "published" || "$LATEST_STATUS" == "deployed" ]]; then
            DOMAIN=$(curl -s "https://api.getshifter.io/latest/sites/${SITE_ID}" -H "Authorization: ${ACCESS_TOKEN}" | jq -r '.domain')
            if [[ -n "$DOMAIN" && "$DOMAIN" != "null" && "$DOMAIN" != "" ]]; then
                BASE_URL="https://${DOMAIN}"
            else
                BASE_URL="https://${SITE_ID}.static.getshifter.net"
            fi
            info "Artifact is already live. Using ${BASE_URL} as preview." >&2
        else
            shifter_launch_preview "$SITE_ID" "$AID"
            BASE_URL="https://${AID}.preview.getshifter.io"
        fi
    fi
    STAGING_URL="https://${SITE_ID}.static.getshifter.net"
    shifter_start_wordpress "$SITE_ID"
else [[ -z "$BASE_URL" ]] && usage; AID="manual"; STAGING_URL=""
fi

if [[ ${#SUBPAGES[@]} -gt 0 ]]; then printf "%s\n" "${SUBPAGES[@]}" > "$TMPDIR/audit.txt"
else curl -s "https://${SITE_ID:-manual}.static.getshifter.net/sitemap.xml" | sed -n 's/.*<loc>\(.*\)<\/loc>.*/\1/p' | sed -E 's|^https?://[^/]+||' > "$TMPDIR/audit.txt"
     [[ "$SAMPLE_SIZE" -gt 0 ]] && { shuf -n "$SAMPLE_SIZE" "$TMPDIR/audit.txt" > "$TMPDIR/s.txt"; mv "$TMPDIR/s.txt" "$TMPDIR/audit.txt"; }
fi

JOBS=0; MAX=8; echo -e "\n${BOLD}── Executing Audit for AID: ${AID} ──${RESET}"
while IFS= read -r slug; do
    (
        path="${slug:-/}"
        [[ "$DEEP_AUDIT" == true && -n "${STAGING_URL:-}" ]] && page_deep_audit "$slug" "$BASE_URL" "$STAGING_URL" "$AID"
        html=$(mktemp); ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        curl -s -L -H "User-Agent: $ua" -o "$html" "${BASE_URL}${slug}"
        echo -e "\n${BOLD}${path}${RESET}"
        while IFS= read -r link; do
            [[ -z "$link" ]] && continue
            [[ "$link" == /* ]] && link="${BASE_URL}${link}"
            check_asset_integrity "$link" "$ua" "$BASE_URL" "${STAGING_URL:-}"
        done <<< "$(grep -oP "(href|src)=['\"][^'\"]*elementor[^'\"]*\.css[^'\"]*['\"]" "$html" | sed -E "s/(href|src)=['\"]//;s/['\"]$//" || true)"
        
        if [[ -n "${STAGING_URL:-}" ]]; then
            stg_html=$(mktemp)
            if curl -s -L -H "User-Agent: $ua" -o "$stg_html" "${STAGING_URL}${slug}"; then
                art_css=$(grep -oP "(href|src)=['\"][^'\"]*\.css[^'\"]*['\"]" "$html" | sed -E "s/(href|src)=['\"]//;s/['\"]$//" | awk -F'/' '{print $NF}' | cut -d'?' -f1 | sort -u || true)
                stg_css=$(grep -oP "(href|src)=['\"][^'\"]*\.css[^'\"]*['\"]" "$stg_html" | sed -E "s/(href|src)=['\"]//;s/['\"]$//" | awk -F'/' '{print $NF}' | cut -d'?' -f1 | sort -u || true)
                for css in $stg_css; do
                    if ! echo "$art_css" | grep -q "^${css}$"; then
                        fail "Missing Stylesheet: $css is in staging but missing from artifact"
                    fi
                done
            fi
            rm -f "$stg_html"
        fi
        summary=$(grep -oP '<!-- shifter-css-fix-summary: \K[^-]+(?=\s*-->)' "$html" | tr -d '\n' || echo "none")
        [[ "$summary" != "none" ]] && echo "$path $summary" >> "$TMPDIR/summaries.log"
        rm -f "$html"
    ) &
    JOBS=$((JOBS+1)); [[ "$JOBS" -ge "$MAX" ]] && { wait -n || true; JOBS=$((JOBS-1)); }
done < "$TMPDIR/audit.txt"; wait

echo -e "\n${BOLD}── Analytics ──${RESET}"
if [[ -f "$TMPDIR/summaries.log" ]]; then
    echo "Breadcrumb Consistency Counts:"
    awk '{print $2}' "$TMPDIR/summaries.log" | sort | uniq -c
else echo "No breadcrumbs found. This is expected if plugin v4.0 is not yet active."
fi
info "Audit Process Complete."
