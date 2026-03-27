#!/usr/bin/env bash
#
# test-artifact.sh — Elementor CSS Audit for Shifter Static Artifacts
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
declare -A ELEMENTOR_VERSIONS=()
declare -a FAILED_PAGES=()

# ── Helpers ──────────────────────────────────────────────────────────
pass()  { PASS_COUNT=$((PASS_COUNT+1)); echo -e "  ${GREEN}✓${RESET} $1"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT+1)); echo -e "  ${RED}✗${RESET} $1"; }
warn()  { WARN_COUNT=$((WARN_COUNT+1)); echo -e "  ${YELLOW}⚠${RESET} $1"; }
info()  { echo -e "  ${CYAN}ℹ${RESET} $1"; }

usage() {
    echo "Usage: $0 <site-url> [--sample N] [--sitemap-from URL]"
    echo ""
    echo "  <site-url>          Target artifact URL"
    echo "  --sample N          Test only N random pages (+ homepage)"
    echo "  --sitemap-from URL  Pull sitemap from a different origin"
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
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Step 1: Discover Pages via Sitemap ───────────────────────────────
echo -e "\n${BOLD}═══ Elementor CSS Artifact Audit ═══${RESET}"
echo -e "Target: ${CYAN}${BASE_URL}${RESET}"
[[ -n "$SITEMAP_FROM" ]] && echo -e "Sitemap: ${CYAN}${SITEMAP_FROM}${RESET}"
echo ""

echo -e "${BOLD}── Discovering pages ──${RESET}"

SITEMAP_ORIGIN="${SITEMAP_FROM:-$BASE_URL}"

# Try common sitemap paths
SITEMAP_URL=""
for candidate in "/sitemap_index.xml" "/sitemap.xml" "/wp-sitemap.xml"; do
    status=$(curl -s -o /dev/null -w "%{http_code}" "${SITEMAP_ORIGIN}${candidate}")
    if [[ "$status" == "200" ]]; then
        SITEMAP_URL="${SITEMAP_ORIGIN}${candidate}"
        break
    fi
done

if [[ -z "$SITEMAP_URL" ]]; then
    echo -e "${RED}Could not find sitemap. Tried sitemap_index.xml, sitemap.xml, wp-sitemap.xml${RESET}"
    exit 2
fi

info "Found sitemap: ${SITEMAP_URL}"

# Download the sitemap
curl -s "$SITEMAP_URL" > "$TMPDIR/sitemap_root.xml"

# Check if it's a sitemap index or a plain sitemap
if grep -q "<sitemap>" "$TMPDIR/sitemap_root.xml"; then
    # Sitemap index — fetch all child sitemaps
    grep -oP '<loc>\K[^<]+' "$TMPDIR/sitemap_root.xml" > "$TMPDIR/child_sitemaps.txt"
    > "$TMPDIR/all_urls.txt"
    while IFS= read -r child_url; do
        curl -s "$child_url" | grep -oP '<loc>\K[^<]+' >> "$TMPDIR/all_urls.txt"
    done < "$TMPDIR/child_sitemaps.txt"
else
    grep -oP '<loc>\K[^<]+' "$TMPDIR/sitemap_root.xml" > "$TMPDIR/all_urls.txt"
fi

# Rewrite URLs if using --sitemap-from
if [[ -n "$SITEMAP_FROM" ]]; then
    sed -i "s|${SITEMAP_FROM}|${BASE_URL}|g" "$TMPDIR/all_urls.txt"
    info "Rewrote sitemap URLs from ${SITEMAP_FROM} → ${BASE_URL}"
fi

TOTAL_PAGES=$(wc -l < "$TMPDIR/all_urls.txt")
info "Found ${TOTAL_PAGES} pages in sitemap"

# Ensure homepage is always included
HOMEPAGE="${BASE_URL}/"
if ! grep -qF "$HOMEPAGE" "$TMPDIR/all_urls.txt"; then
    echo "$HOMEPAGE" >> "$TMPDIR/all_urls.txt"
fi

# Apply sampling
if [[ "$SAMPLE_SIZE" -gt 0 && "$SAMPLE_SIZE" -lt "$TOTAL_PAGES" ]]; then
    { grep -vxF "$HOMEPAGE" "$TMPDIR/all_urls.txt" || true; } | shuf -n "$SAMPLE_SIZE" > "$TMPDIR/sampled.txt"
    echo "$HOMEPAGE" >> "$TMPDIR/sampled.txt"
    mv "$TMPDIR/sampled.txt" "$TMPDIR/all_urls.txt"
    info "Sampled ${SAMPLE_SIZE} pages (+ homepage)"
fi

PAGES_TO_CHECK=$(wc -l < "$TMPDIR/all_urls.txt")

# ── Step 2: Per-Page Checks ─────────────────────────────────────────
echo -e "\n${BOLD}── Checking ${PAGES_TO_CHECK} pages ──${RESET}\n"

check_page() {
    local url="$1"
    local html_file="$TMPDIR/page_$$.html"
    local page_failures=0

    # Fetch the page
    local http_code
    http_code=$(curl -s -o "$html_file" -w "%{http_code}" "$url")

    local short_path="${url#$BASE_URL}"
    [[ -z "$short_path" ]] && short_path="/"

    if [[ "$http_code" != "200" ]]; then
        echo -e "${BOLD}${short_path}${RESET}"
        fail "HTTP ${http_code}"
        echo ""
        return 1
    fi

    echo -e "${BOLD}${short_path}${RESET}"

    # ── Check 1: Plugin Heartbeat ────────────────────────────────
    if grep -q "Shifter Elementor CSS Fix" "$html_file"; then
        local version
        version=$(grep -oP 'Shifter Elementor CSS Fix v\K[0-9.]+' "$html_file" || echo "?")
        pass "Plugin heartbeat (v${version})"
    else
        fail "Plugin heartbeat MISSING"
        page_failures=$((page_failures+1))
    fi

    # ── Check 2: Upload CSS uses hashes (no ?ver=) ───────────────
    local unhashed
    unhashed=$(grep -oP "href='[^']*?/uploads/elementor/[^']*\.css\?ver=[^']*'" "$html_file" 2>/dev/null || true)
    if [[ -n "$unhashed" ]]; then
        local count
        count=$(echo "$unhashed" | wc -l)
        fail "${count} upload CSS file(s) still use ?ver= instead of content hash"
        page_failures=$((page_failures+1))
    else
        pass "All upload CSS files use content hashes"
    fi

    # ── Check 3: Shape divider → shapes.min.css ──────────────────
    if grep -q 'elementor-shape' "$html_file"; then
        if grep -q 'shapes.min.css' "$html_file"; then
            pass "Shape divider → shapes.min.css linked"
        else
            fail "Shape divider present but shapes.min.css NOT linked (run Regenerate?)"
            page_failures=$((page_failures+1))
        fi
    fi

    # ── Check 4: Loop grid → widget-loop-common.css ──────────────
    if grep -q 'elementor-widget-loop-grid\|elementor-loop-container' "$html_file"; then
        if grep -q 'widget-loop-common' "$html_file"; then
            pass "Loop grid → widget-loop-common.css linked"
        else
            fail "Loop grid present but widget-loop-common.css NOT linked"
            page_failures=$((page_failures+1))
        fi
    fi

    # ── Check 5: Elementor version ───────────────────────────────
    local el_version
    el_version=$(grep -oP 'content="Elementor \K[0-9.]+' "$html_file" 2>/dev/null || echo "none")
    if [[ "$el_version" != "none" ]]; then
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

    # ── Check 7: Hex ID in non-CDN paths ─────────────────────────
    local hex_ids
    hex_ids=$(grep -oP "href='[^']*?/[a-f0-9]{40}/uploads/[^']*'" "$html_file" \
            | grep -v 'cdn.getshifter.co' 2>/dev/null || true)
    if [[ -n "$hex_ids" ]]; then
        fail "Non-CDN path contains Shifter hex ID (will 404 in production)"
        page_failures=$((page_failures+1))
    fi

    rm -f "$html_file"

    if [[ "$page_failures" -gt 0 ]]; then
        FAILED_PAGES+=("$short_path")
    fi

    echo ""
    return 0
}

while IFS= read -r page_url; do
    check_page "$page_url" || true
    PAGES_CHECKED=$((PAGES_CHECKED+1))
done < "$TMPDIR/all_urls.txt"

# ── Step 3: Cross-Page Checks ────────────────────────────────────────
echo -e "${BOLD}── Cross-page checks ──${RESET}"

if [[ ${#ELEMENTOR_VERSIONS[@]} -gt 1 ]]; then
    fail "Inconsistent Elementor versions: ${!ELEMENTOR_VERSIONS[*]}"
    info "This usually means the homepage is cached from an older bake"
else
    pass "Consistent Elementor version: ${!ELEMENTOR_VERSIONS[*]}"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo -e "\n${BOLD}═══ Summary ═══${RESET}"
echo -e "Pages checked: ${PAGES_CHECKED}"
echo -e "Passed:        ${GREEN}${PASS_COUNT}${RESET}"
echo -e "Warnings:      ${YELLOW}${WARN_COUNT}${RESET}"
echo -e "Failed:        ${RED}${FAIL_COUNT}${RESET}"

if [[ ${#FAILED_PAGES[@]} -gt 0 ]]; then
    echo -e "\n${RED}Pages with failures:${RESET}"
    for p in "${FAILED_PAGES[@]}"; do
        echo -e "  ${RED}✗${RESET} ${p}"
    done
fi

echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo -e "${RED}${BOLD}AUDIT FAILED${RESET} — ${FAIL_COUNT} issue(s) found."
    exit 1
else
    echo -e "${GREEN}${BOLD}AUDIT PASSED${RESET} — No issues detected."
    exit 0
fi
