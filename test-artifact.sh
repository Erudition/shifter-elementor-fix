#!/usr/bin/env bash
#
# test-artifact.sh — Elementor CSS Shifter Audit & Priming Tool
#
# Usage:
#   ./test-artifact.sh <site-url> [options]
#
# Fetches the sitemap, discovers all pages, and checks each one for
# known Elementor CSS issues on the Shifter platform.
#
# Options:
#   --sample N          Only test N randomly-sampled pages (+ homepage).
#   --sitemap-from URL  Fetch sitemap from a different origin (e.g. the
#                       live site) and rewrite URLs to <site-url>.
#                       Useful for preview artifacts that lack a sitemap.
#   --prime             Only "prime" the metadata (visit all pages) without
#                       running the full audit checks. Useful for staging.
#
# Checks performed:
#   1. Plugin heartbeat signature present
#   2. All /uploads/elementor/ CSS files use content hashes (no ?ver=)
#   3. Shape dividers have shapes.min.css linked
#   4. Loop grids have widget-loop-common.css linked
#   5. All Elementor stylesheets return HTTP 200
#   6. No non-CDN paths contain Shifter hex IDs
#   7. Consistent Elementor version across all pages
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Usage error or sitemap not found
#
# Terminology:
#   *.static.getshifter.net = Staging (Live WordPress)
#   *.preview.getshifter.io = Artifact (Static snapshot)

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
declare -A ELEMENTOR_VERSIONS=()
declare -a FAILED_PAGES=()

# ── Helpers ──────────────────────────────────────────────────────────
pass()  { PASS_COUNT=$((PASS_COUNT+1)); echo -e "  ${GREEN}✓${RESET} $1"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT+1)); echo -e "  ${RED}✗${RESET} $1"; }
warn()  { WARN_COUNT=$((WARN_COUNT+1)); echo -e "  ${YELLOW}⚠${RESET} $1"; }
info()  { echo -e "  ${CYAN}ℹ${RESET} $1"; }

usage() {
    echo "Usage: $0 <site-url> [--sample N] [--sitemap-from URL] [--prime]"
    echo ""
    echo "  <site-url>          Target site URL (Staging or Artifact)"
    echo "  --sample N          Test only N random pages (+ homepage)"
    echo "  --sitemap-from URL  Pull sitemap from a different origin"
    echo "  --prime             Only visit URLs to rebuild metadata (Staging site only)"
    exit 2
}

# ── Parse Arguments ──────────────────────────────────────────────────
[[ $# -lt 1 ]] && usage

BASE_URL="${1%/}"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sample)
            SAMPLE_SIZE="$2"
            shift 2
            ;;
        --sitemap-from)
            SITEMAP_FROM="${2%/}"
            shift 2
            ;;
        --prime)
            PRIME_ONLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Detect Audit Type
if [[ "$BASE_URL" == *".static.getshifter.net"* ]]; then
    AUDIT_TYPE="Staging (Live)"
elif [[ "$BASE_URL" == *".preview.getshifter.io"* ]]; then
    AUDIT_TYPE="Artifact (Static)"
else
    AUDIT_TYPE="Generic"
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Step 1: Discover Pages via Sitemap ───────────────────────────────
echo -e "\n${BOLD}═══ Elementor CSS Shifter Audit ═══${RESET}"
echo -e "Target Type: ${BOLD}${AUDIT_TYPE}${RESET}"
echo -e "Target URL:  ${CYAN}${BASE_URL}${RESET}"
[[ -n "$SITEMAP_FROM" ]] && echo -e "Sitemap:     ${CYAN}${SITEMAP_FROM}${RESET}"
echo ""

echo -e "${BOLD}── Discovering pages ──${RESET}"

SITEMAP_ORIGIN="${SITEMAP_FROM:-$BASE_URL}"
SITEMAP_URL="${SITEMAP_ORIGIN}/sitemap.xml"

if ! curl -s --head "$SITEMAP_URL" | grep -q '200'; then
    echo -e "${RED}Error: Sitemap not found at ${SITEMAP_URL}${RESET}"
    exit 2
fi

info "Found sitemap: ${SITEMAP_URL}"

# Extract URLs
curl -s "$SITEMAP_URL" | grep -oP '<loc>\K[^<]+' > "$TMPDIR/all_urls.txt"

# If sitemap origin is different, rewrite URLs
if [[ -n "$SITEMAP_FROM" ]]; then
    sed -i "s|${SITEMAP_FROM}|${BASE_URL}|g" "$TMPDIR/all_urls.txt"
    info "Rewrote sitemap URLs from ${SITEMAP_FROM} → ${BASE_URL}"
fi

TOTAL_PAGES=$(wc -l < "$TMPDIR/all_urls.txt")
info "Found ${TOTAL_PAGES} pages in sitemap"

HOMEPAGE="${BASE_URL}/"

# Apply sampling
if [[ "$SAMPLE_SIZE" -gt 0 && "$SAMPLE_SIZE" -lt "$TOTAL_PAGES" ]]; then
    { grep -vxF "$HOMEPAGE" "$TMPDIR/all_urls.txt" || true; } | shuf -n "$SAMPLE_SIZE" > "$TMPDIR/sampled.txt"
    echo "$HOMEPAGE" >> "$TMPDIR/sampled.txt"
    mv "$TMPDIR/sampled.txt" "$TMPDIR/all_urls.txt"
    info "Sampled ${SAMPLE_SIZE} pages (+ homepage)"
fi

# ── Step 2: Prime or Audit ───────────────────────────────────────────
if [ "$PRIME_ONLY" = true ]; then
    echo -e "\n${BOLD}── Priming metadata on ${TOTAL_PAGES} pages ──${RESET}"
    count=0
    while IFS= read -r url; do
        count=$((count+1))
        echo -ne "  Priming ($count/$TOTAL_PAGES): $url\r"
        curl -s -o /dev/null "$url"
    done < "$TMPDIR/all_urls.txt"
    echo -e "\n${GREEN}✓ Done: All pages visited. Metadata should be primed.${RESET}"
    exit 0
fi

echo -e "\n${BOLD}── Checking $(wc -l < "$TMPDIR/all_urls.txt") pages ──${RESET}"

while IFS= read -r url; do
    page_failures=0
    path="${url#$BASE_URL}"
    [[ -z "$path" ]] && path="/"
    
    echo -e "\n${BOLD}${path}${RESET}"
    
    html_file="$TMPDIR/page.html"
    curl -s -L "$url" > "$html_file"

    # ── Check 1: Plugin Heartbeat ────────────────────────────────────
    if grep -q "Shifter Elementor CSS Fix" "$html_file"; then
        hb_version=$(grep -oP "Shifter Elementor CSS Fix v\K[0-9.]+" "$html_file" | head -1)
        pass "Plugin heartbeat (v${hb_version})"
    else
        fail "Plugin heartbeat MISSING"
        page_failures=$((page_failures+1))
    fi

    # ── Check 2: Content Hash Versioning (Uploads only) ──────────────
    unhashed=$(grep -oP "href='[^']*elementor/css/post-[^']*\'" "$html_file" | grep "\?ver=" || true)
    if [[ -n "$unhashed" ]]; then
        local count
        count=$(echo "$unhashed" | wc -l)
        fail "${count} upload CSS file(s) still use ?ver= instead of content hash"
        page_failures=$((page_failures+1))
    else
        pass "All upload CSS files use content hashes"
    fi

    # ── Check 3: Shape Divider Presence ──────────────────────────────
    if grep -q "elementor-shape" "$html_file"; then
        if grep -q "shapes.min.css" "$html_file"; then
            pass "Shape divider → shapes.min.css linked"
        else
            fail "Shape divider present but shapes.min.css NOT linked (run Regenerate?)"
            page_failures=$((page_failures+1))
        fi
    fi

    # ── Check 4: Loop Grid Presence ──────────────────────────────────
    if grep -q "elementor-widget-loop" "$html_file"; then
        if grep -q "widget-loop-common.css" "$html_file"; then
            pass "Loop grid → widget-loop-common.css linked"
        else
            fail "Loop grid present but widget-loop-common.css NOT linked"
            page_failures=$((page_failures+1))
        fi
    fi

    # ── Check 5: Elementor Version consistency ───────────────────────
    el_version=$(grep -oP "elementor-v\K[0-9.]+" "$html_file" | head -1 || true)
    if [[ -n "$el_version" ]]; then
        ELEMENTOR_VERSIONS["$el_version"]=1
        info "Elementor ${el_version}"
    fi

    # ── Check 6: Elementor CSS reachability (uploads/CDN only) ────
    # Plugin/theme CSS is served by the production origin, not the artifact.
    # Only check CSS from /uploads/ (CDN-managed) for reachability.
    local css_urls
    css_urls=$(grep -oP "href='[^']*elementor[^']*\.css[^']*'" "$html_file" \
             | sed "s/href='//;s/'$//" 2>/dev/null \
             | grep -v '/wp-content/plugins/' \
             | grep -v '/wp-content/themes/' || true)

    if [[ -n "$css_urls" ]]; then
        local total_css=0
        local failed_css=0
        while IFS= read -r css_url; do
            total_css=$((total_css+1))
            # Resolve relative URLs
            if [[ "$css_url" == /* ]]; then
                css_url="${BASE_URL}${css_url}"
            fi
            local css_status
            css_status=$(curl -s -o /dev/null -w "%{http_code}" "$css_url")
            if [[ "$css_status" != "200" ]]; then
                local short_css="${css_url#$BASE_URL}"
                [[ "$short_css" == "$css_url" ]] && short_css=$(echo "$css_url" | sed 's|https\?://[^/]*/|/|')
                fail "CSS HTTP ${css_status}: ${short_css}"
                failed_css=$((failed_css+1))
                page_failures=$((page_failures+1))
            fi
        done <<< "$css_urls"
        if [[ "$failed_css" -eq 0 ]]; then
            pass "All ${total_css} CDN/upload Elementor stylesheets reachable"
        fi
    fi

    # ── Check 7: Shifter Hex ID leaks ────────────────────────────────
    # Check for paths like /b30641.../ which should be stripped in artifacts
    # excluding CDN host discovery.
    hex_ids=$(grep -oP "/[0-9a-f]{40}/" "$html_file" \
            | grep -v 'cdn.getshifter.co' 2>/dev/null || true)
    if [[ -n "$hex_ids" ]]; then
        fail "Non-CDN path contains Shifter hex ID (will 404 in production)"
        page_failures=$((page_failures+1))
    fi

    rm -f "$html_file"
    
    PAGES_CHECKED=$((PAGES_CHECKED+1))
    if [[ "$page_failures" -gt 0 ]]; then
        FAILED_PAGES+=("$path")
    fi
done < "$TMPDIR/all_urls.txt"

# ── Final Summary ────────────────────────────────────────────────────
echo -e "\n${BOLD}── Cross-page checks ──${RESET}"
VERSIONS=("${!ELEMENTOR_VERSIONS[@]}")
if [[ ${#VERSIONS[@]} -gt 1 ]]; then
    fail "Inconsistent Elementor versions: ${VERSIONS[*]}"
    info "This usually means the homepage is cached from an older bake"
elif [[ ${#VERSIONS[@]} -eq 1 ]]; then
    pass "Consistent Elementor version: ${VERSIONS[0]}"
fi

echo -e "\n${BOLD}═══ Summary ═══${RESET}"
echo "Pages checked: ${PAGES_CHECKED}"
echo "Passed:        ${PASS_COUNT}"
echo "Warnings:      ${WARN_COUNT}"
echo "Failed:        ${FAIL_COUNT}"

if [[ ${#FAILED_PAGES[@]} -gt 0 ]]; then
    echo -e "\n${RED}Pages with failures:${RESET}"
    for p in "${FAILED_PAGES[@]}"; do
        echo -e "  ${RED}✗${RESET} $p"
    done
    echo -e "\n${RED}${BOLD}AUDIT FAILED${RESET} — ${FAIL_COUNT} issue(s) found."
    exit 1
else
    echo -e "\n${GREEN}${BOLD}AUDIT PASSED${RESET}"
    exit 0
fi
