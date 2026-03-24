#!/usr/bin/env bash
# analyze-htmx.sh — Analyze an HTML project for htmx usage patterns and potential issues.
#
# Usage:
#   ./analyze-htmx.sh [directory]
#
# Default directory: current directory
#
# Examples:
#   ./analyze-htmx.sh ./templates
#   ./analyze-htmx.sh /path/to/project
#   ./analyze-htmx.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TARGET_DIR="${1:-.}"

[[ -d "$TARGET_DIR" ]] || { echo -e "${RED}[error]${NC} Directory '$TARGET_DIR' not found." >&2; exit 1; }

section() { echo -e "\n${BOLD}${BLUE}═══ $1 ═══${NC}"; }
info()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
issue()   { echo -e "  ${RED}✗${NC} $*"; }
stat()    { printf "  ${CYAN}%-30s${NC} %s\n" "$1" "$2"; }

HTML_FILES=$(find "$TARGET_DIR" -type f \( -name "*.html" -o -name "*.htm" -o -name "*.ejs" -o -name "*.jinja2" -o -name "*.j2" -o -name "*.njk" \) 2>/dev/null)
HTML_COUNT=$(echo "$HTML_FILES" | grep -c '.' 2>/dev/null || echo 0)

echo -e "${BOLD}htmx Project Analyzer${NC}"
echo -e "Scanning: ${CYAN}$TARGET_DIR${NC}"
echo -e "HTML files found: ${CYAN}$HTML_COUNT${NC}"

if [[ "$HTML_COUNT" -eq 0 ]]; then
  echo -e "${YELLOW}No HTML files found. Nothing to analyze.${NC}"
  exit 0
fi

# ─── Usage Statistics ───────────────────────────────────────────────
section "htmx Usage Statistics"

count_attr() {
  local attr="$1"
  echo "$HTML_FILES" | xargs grep -l "$attr" 2>/dev/null | wc -l
}

count_occurrences() {
  local pattern="$1"
  echo "$HTML_FILES" | xargs grep -oh "$pattern" 2>/dev/null | wc -l
}

stat "hx-get"        "$(count_occurrences 'hx-get') usages in $(count_attr 'hx-get') files"
stat "hx-post"       "$(count_occurrences 'hx-post') usages in $(count_attr 'hx-post') files"
stat "hx-put"        "$(count_occurrences 'hx-put') usages in $(count_attr 'hx-put') files"
stat "hx-patch"      "$(count_occurrences 'hx-patch') usages in $(count_attr 'hx-patch') files"
stat "hx-delete"     "$(count_occurrences 'hx-delete') usages in $(count_attr 'hx-delete') files"
stat "hx-target"     "$(count_occurrences 'hx-target') usages"
stat "hx-swap"       "$(count_occurrences 'hx-swap') usages"
stat "hx-trigger"    "$(count_occurrences 'hx-trigger') usages"
stat "hx-swap-oob"   "$(count_occurrences 'hx-swap-oob') usages"
stat "hx-boost"      "$(count_occurrences 'hx-boost') usages"
stat "hx-push-url"   "$(count_occurrences 'hx-push-url') usages"
stat "hx-indicator"  "$(count_occurrences 'hx-indicator') usages"
stat "hx-include"    "$(count_occurrences 'hx-include') usages"
stat "hx-confirm"    "$(count_occurrences 'hx-confirm') usages"
stat "hx-ext"        "$(count_occurrences 'hx-ext') usages"
stat "hx-on:"        "$(count_occurrences 'hx-on:' ) usages"
stat "hx-validate"   "$(count_occurrences 'hx-validate') usages"
stat "hx-encoding"   "$(count_occurrences 'hx-encoding') usages"

# ─── Extensions ─────────────────────────────────────────────────────
section "Extensions Detected"

for ext in sse ws json-enc multi-swap morph head-support preload response-targets; do
  ext_count=$(count_occurrences "$ext" 2>/dev/null)
  if [[ "$ext_count" -gt 0 ]]; then
    info "$ext ($ext_count references)"
  fi
done

# ─── Swap Strategies ────────────────────────────────────────────────
section "Swap Strategies Used"

for strategy in innerHTML outerHTML beforebegin afterbegin beforeend afterend delete none; do
  s_count=$(echo "$HTML_FILES" | xargs grep -oh "hx-swap=\"$strategy" 2>/dev/null | wc -l)
  if [[ "$s_count" -gt 0 ]]; then
    stat "$strategy" "$s_count usages"
  fi
done

# ─── Potential Issues ────────────────────────────────────────────────
section "Potential Issues"

ISSUES=0

# Check: hx-delete/hx-post/hx-put without hx-confirm
DELETE_NO_CONFIRM=$(echo "$HTML_FILES" | xargs grep -n 'hx-delete' 2>/dev/null | grep -v 'hx-confirm' | head -10)
if [[ -n "$DELETE_NO_CONFIRM" ]]; then
  issue "DELETE without hx-confirm (destructive action unconfirmed):"
  echo "$DELETE_NO_CONFIRM" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
fi

# Check: hx-get/hx-post without hx-target on non-form elements
NO_TARGET=$(echo "$HTML_FILES" | xargs grep -n 'hx-\(get\|post\|put\|patch\|delete\)' 2>/dev/null \
  | grep -v 'hx-target' | grep -v '<form' | grep -v 'hx-swap="none"' | head -10)
if [[ -n "$NO_TARGET" ]]; then
  warn "Request attributes without hx-target (will replace triggering element):"
  echo "$NO_TARGET" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
fi

# Check: old hx-on syntax (without colon, htmx 1.x style)
OLD_ON=$(echo "$HTML_FILES" | xargs grep -Pn 'hx-on="' 2>/dev/null | head -10)
if [[ -n "$OLD_ON" ]]; then
  issue "Old hx-on syntax detected (htmx 2.x requires hx-on:<event> colon syntax):"
  echo "$OLD_ON" | head -5 | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
fi

# Check: htmx 1.x CDN references
OLD_CDN=$(echo "$HTML_FILES" | xargs grep -n 'htmx.org@1\|htmx.org/1' 2>/dev/null | head -5)
if [[ -n "$OLD_CDN" ]]; then
  issue "htmx 1.x CDN reference found (consider upgrading to 2.x):"
  echo "$OLD_CDN" | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
fi

# Check: hx-swap-oob without id
OOB_NO_ID=$(echo "$HTML_FILES" | xargs grep -Pn 'hx-swap-oob' 2>/dev/null | grep -v ' id=' | head -5)
if [[ -n "$OOB_NO_ID" ]]; then
  issue "hx-swap-oob without id attribute (OOB elements require matching id):"
  echo "$OOB_NO_ID" | sed 's/^/    /'
  ISSUES=$((ISSUES + 1))
fi

# Check: htmx-indicator class without CSS
INDICATOR_USED=$(echo "$HTML_FILES" | xargs grep -l 'htmx-indicator' 2>/dev/null | wc -l)
INDICATOR_CSS=$(find "$TARGET_DIR" -name "*.css" -exec grep -l 'htmx-indicator' {} \; 2>/dev/null | wc -l)
INDICATOR_STYLE=$(echo "$HTML_FILES" | xargs grep -l 'htmx-indicator' 2>/dev/null | xargs grep -l '\.htmx-indicator' 2>/dev/null | wc -l)
if [[ "$INDICATOR_USED" -gt 0 && "$INDICATOR_CSS" -eq 0 && "$INDICATOR_STYLE" -eq 0 ]]; then
  warn "htmx-indicator class used but no CSS rules found (indicators won't hide/show)"
  ISSUES=$((ISSUES + 1))
fi

# Check: polling without throttle/rate consideration
POLLING=$(echo "$HTML_FILES" | xargs grep -n 'every [0-9]' 2>/dev/null | head -5)
if [[ -n "$POLLING" ]]; then
  warn "Polling detected — ensure server can handle the request rate:"
  echo "$POLLING" | sed 's/^/    /'
fi

# Check: missing CSRF setup
CSRF=$(echo "$HTML_FILES" | xargs grep -l 'csrf\|CSRF\|csrfmiddlewaretoken\|_csrf\|X-CSRFToken' 2>/dev/null | wc -l)
POST_COUNT=$(count_occurrences 'hx-post\|hx-put\|hx-patch\|hx-delete')
if [[ "$POST_COUNT" -gt 0 && "$CSRF" -eq 0 ]]; then
  warn "Mutation requests found but no CSRF token setup detected"
  ISSUES=$((ISSUES + 1))
fi

# ─── Summary ─────────────────────────────────────────────────────────
section "Summary"

TOTAL_HX=$(count_occurrences 'hx-')
stat "Total htmx attributes"   "$TOTAL_HX"
stat "Files with htmx"         "$(echo "$HTML_FILES" | xargs grep -l 'hx-' 2>/dev/null | wc -l) / $HTML_COUNT"
stat "Potential issues"         "$ISSUES"

if [[ "$ISSUES" -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}No issues detected. Looking good!${NC}"
else
  echo -e "\n${YELLOW}${BOLD}$ISSUES issue(s) found. Review the warnings above.${NC}"
fi
