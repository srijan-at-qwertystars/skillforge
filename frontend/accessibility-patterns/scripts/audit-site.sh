#!/usr/bin/env bash
# ============================================================================
# audit-site.sh — Run accessibility audit on a URL
#
# Usage:
#   ./audit-site.sh <URL> [--format html|json|csv] [--standard WCAG2A|WCAG2AA|WCAG2AAA]
#
# Examples:
#   ./audit-site.sh https://example.com
#   ./audit-site.sh http://localhost:3000 --format json
#   ./audit-site.sh https://example.com --standard WCAG2AAA --format html
#
# Requirements:
#   - Node.js 16+
#   - One of: pa11y (npm install -g pa11y) or @axe-core/cli (npm install -g @axe-core/cli)
#
# Output:
#   Violations grouped by severity with WCAG criteria references.
# ============================================================================

set -euo pipefail

# --- Defaults ---
URL=""
FORMAT="cli"
STANDARD="WCAG2AA"
OUTPUT_FILE=""
TOOL=""

# --- Colors ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Usage ---
usage() {
  echo "Usage: $0 <URL> [--format cli|json|html|csv] [--standard WCAG2A|WCAG2AA|WCAG2AAA] [--output FILE]"
  echo ""
  echo "Options:"
  echo "  --format     Output format (default: cli)"
  echo "  --standard   WCAG conformance level (default: WCAG2AA)"
  echo "  --output     Save report to file"
  echo "  -h, --help   Show this help message"
  exit 1
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)  FORMAT="$2"; shift 2 ;;
    --standard) STANDARD="$2"; shift 2 ;;
    --output)  OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*)        echo "Unknown option: $1"; usage ;;
    *)         URL="$1"; shift ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo -e "${RED}Error: URL is required${NC}"
  usage
fi

# --- Detect tool ---
detect_tool() {
  if command -v pa11y &>/dev/null; then
    TOOL="pa11y"
  elif npx --yes pa11y --version &>/dev/null 2>&1; then
    TOOL="npx-pa11y"
  elif command -v axe &>/dev/null; then
    TOOL="axe"
  else
    echo -e "${YELLOW}No a11y tool found. Installing pa11y...${NC}"
    npm install -g pa11y 2>/dev/null || {
      echo -e "${RED}Failed to install pa11y. Please install manually:${NC}"
      echo "  npm install -g pa11y"
      echo "  # or"
      echo "  npm install -g @axe-core/cli"
      exit 1
    }
    TOOL="pa11y"
  fi
}

detect_tool

echo -e "${BOLD}♿ Accessibility Audit${NC}"
echo -e "  URL:      ${BLUE}${URL}${NC}"
echo -e "  Standard: ${STANDARD}"
echo -e "  Tool:     ${TOOL}"
echo -e "  Format:   ${FORMAT}"
echo ""

# --- Run pa11y ---
run_pa11y() {
  local cmd="pa11y"
  if [[ "$TOOL" == "npx-pa11y" ]]; then
    cmd="npx --yes pa11y"
  fi

  local tmp_file
  tmp_file=$(mktemp /tmp/a11y-audit-XXXXXX.json)
  trap "rm -f '$tmp_file'" EXIT

  echo -e "${BOLD}Running pa11y audit...${NC}"
  echo ""

  # Run with JSON output for processing
  if ! $cmd "$URL" --standard "$STANDARD" --reporter json > "$tmp_file" 2>/dev/null; then
    # pa11y returns non-zero when violations found — that's expected
    true
  fi

  # Check if file has content
  if [[ ! -s "$tmp_file" ]]; then
    echo -e "${GREEN}✅ No accessibility violations found!${NC}"
    return 0
  fi

  if [[ "$FORMAT" == "json" ]]; then
    if [[ -n "$OUTPUT_FILE" ]]; then
      cp "$tmp_file" "$OUTPUT_FILE"
      echo -e "Report saved to ${BLUE}${OUTPUT_FILE}${NC}"
    else
      cat "$tmp_file"
    fi
    return 0
  fi

  # Parse and display grouped by severity
  local critical=0 serious=0 moderate=0 minor=0

  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${RED}${BOLD}  CRITICAL / ERROR${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  while IFS= read -r line; do
    local type code msg selector context
    type=$(echo "$line" | jq -r '.type // "error"')
    code=$(echo "$line" | jq -r '.code // "unknown"')
    msg=$(echo "$line" | jq -r '.message // "No message"')
    selector=$(echo "$line" | jq -r '.selector // ""')
    context=$(echo "$line" | jq -r '.context // ""' | head -c 120)

    # Map pa11y codes to WCAG criteria
    local wcag_ref=""
    case "$code" in
      *1_1_1*) wcag_ref="WCAG 1.1.1 Non-text Content" ;;
      *1_3_1*) wcag_ref="WCAG 1.3.1 Info and Relationships" ;;
      *1_4_3*) wcag_ref="WCAG 1.4.3 Contrast (Minimum)" ;;
      *1_4_11*) wcag_ref="WCAG 1.4.11 Non-text Contrast" ;;
      *2_1_1*) wcag_ref="WCAG 2.1.1 Keyboard" ;;
      *2_4_1*) wcag_ref="WCAG 2.4.1 Bypass Blocks" ;;
      *2_4_4*) wcag_ref="WCAG 2.4.4 Link Purpose" ;;
      *2_4_7*) wcag_ref="WCAG 2.4.7 Focus Visible" ;;
      *3_1_1*) wcag_ref="WCAG 3.1.1 Language of Page" ;;
      *3_3_2*) wcag_ref="WCAG 3.3.2 Labels or Instructions" ;;
      *4_1_1*) wcag_ref="WCAG 4.1.1 Parsing" ;;
      *4_1_2*) wcag_ref="WCAG 4.1.2 Name, Role, Value" ;;
      *) wcag_ref="$code" ;;
    esac

    if [[ "$type" == "error" ]]; then
      ((critical++)) || true
      echo -e "  ${RED}✖${NC} ${msg}"
      echo -e "    ${BLUE}Ref:${NC}      ${wcag_ref}"
      [[ -n "$selector" ]] && echo -e "    ${BLUE}Selector:${NC} ${selector}"
      [[ -n "$context" ]] && echo -e "    ${BLUE}Context:${NC}  ${context}"
      echo ""
    elif [[ "$type" == "warning" ]]; then
      ((serious++)) || true
    else
      ((moderate++)) || true
    fi
  done < <(jq -c '.[]' "$tmp_file" 2>/dev/null || echo "")

  if [[ $critical -eq 0 ]]; then
    echo -e "  ${GREEN}None found${NC}"
    echo ""
  fi

  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}${BOLD}  WARNINGS${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  while IFS= read -r line; do
    local type msg code selector
    type=$(echo "$line" | jq -r '.type // "error"')
    if [[ "$type" == "warning" ]]; then
      msg=$(echo "$line" | jq -r '.message // "No message"')
      code=$(echo "$line" | jq -r '.code // "unknown"')
      selector=$(echo "$line" | jq -r '.selector // ""')
      echo -e "  ${YELLOW}⚠${NC} ${msg}"
      echo -e "    ${BLUE}Code:${NC} ${code}"
      [[ -n "$selector" ]] && echo -e "    ${BLUE}Selector:${NC} ${selector}"
      echo ""
    fi
  done < <(jq -c '.[]' "$tmp_file" 2>/dev/null || echo "")

  if [[ $serious -eq 0 ]]; then
    echo -e "  ${GREEN}None found${NC}"
    echo ""
  fi

  # Summary
  local total=$((critical + serious + moderate + minor))
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  SUMMARY${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Total issues: ${BOLD}${total}${NC}"
  echo -e "  🔴 Errors:   ${critical}"
  echo -e "  🟡 Warnings: ${serious}"
  echo -e "  🔵 Notices:  ${moderate}"
  echo ""

  if [[ $critical -gt 0 ]]; then
    echo -e "${RED}${BOLD}  ❌ FAIL — ${critical} error(s) must be fixed for ${STANDARD} compliance${NC}"
    return 1
  else
    echo -e "${GREEN}${BOLD}  ✅ PASS — No errors (${serious} warning(s) to review)${NC}"
    return 0
  fi
}

# --- Run axe ---
run_axe() {
  echo -e "${BOLD}Running axe audit...${NC}"
  echo ""

  local tags
  case "$STANDARD" in
    WCAG2A)   tags="wcag2a" ;;
    WCAG2AA)  tags="wcag2a,wcag2aa,wcag22aa" ;;
    WCAG2AAA) tags="wcag2a,wcag2aa,wcag2aaa" ;;
    *)        tags="wcag2a,wcag2aa" ;;
  esac

  if [[ -n "$OUTPUT_FILE" ]]; then
    axe "$URL" --tags "$tags" --save "$OUTPUT_FILE"
    echo -e "Report saved to ${BLUE}${OUTPUT_FILE}${NC}"
  else
    axe "$URL" --tags "$tags"
  fi
}

# --- Main ---
case "$TOOL" in
  pa11y|npx-pa11y) run_pa11y ;;
  axe)             run_axe ;;
esac
