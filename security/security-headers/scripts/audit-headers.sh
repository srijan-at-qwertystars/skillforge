#!/usr/bin/env bash
#
# audit-headers.sh — Audit security headers for a URL
#
# Usage:
#   ./audit-headers.sh <url>
#   ./audit-headers.sh https://example.com
#   ./audit-headers.sh -v https://example.com    # verbose output
#
# Checks for recommended security headers, scores A-F,
# reports missing/misconfigured headers with fix suggestions.
#

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Parse args ---
VERBOSE=false
URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [-v|--verbose] <url>"
      echo ""
      echo "Audits HTTP security headers for the given URL."
      echo "Checks for all recommended security headers and scores A-F."
      echo ""
      echo "Options:"
      echo "  -v, --verbose   Show header values and detailed analysis"
      echo "  -h, --help      Show this help message"
      exit 0
      ;;
    *) URL="$1"; shift ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "Error: URL required"
  echo "Usage: $0 [-v] <url>"
  exit 1
fi

# Ensure URL has scheme
if [[ ! "$URL" =~ ^https?:// ]]; then
  URL="https://$URL"
fi

echo -e "${BOLD}Security Header Audit: ${CYAN}$URL${NC}"
echo "════════════════════════════════════════════════════════════════"

# --- Fetch headers ---
HEADERS=$(curl -sI -L --max-time 15 --max-redirs 5 "$URL" 2>/dev/null) || {
  echo -e "${RED}Error: Failed to fetch headers from $URL${NC}"
  exit 1
}

# Lowercase headers for case-insensitive matching
HEADERS_LOWER=$(echo "$HEADERS" | tr '[:upper:]' '[:lower:]')

SCORE=0
MAX_SCORE=0
MISSING=()
WARNINGS=()

# --- Helper functions ---
header_exists() {
  echo "$HEADERS_LOWER" | grep -q "^$1:" 2>/dev/null
}

get_header_value() {
  echo "$HEADERS" | grep -i "^$1:" | head -1 | sed "s/^[^:]*: *//" | tr -d '\r'
}

check_header() {
  local header_name="$1"
  local weight="$2"
  local fix_suggestion="$3"
  local header_lower
  header_lower=$(echo "$header_name" | tr '[:upper:]' '[:lower:]')

  MAX_SCORE=$((MAX_SCORE + weight))

  if header_exists "$header_lower"; then
    local value
    value=$(get_header_value "$header_name")
    echo -e "  ${GREEN}✓${NC} ${BOLD}$header_name${NC}"
    if [[ "$VERBOSE" == true ]]; then
      echo -e "    Value: ${CYAN}$value${NC}"
    fi
    SCORE=$((SCORE + weight))
    return 0
  else
    echo -e "  ${RED}✗${NC} ${BOLD}$header_name${NC} — ${RED}MISSING${NC}"
    if [[ "$VERBOSE" == true ]]; then
      echo -e "    Fix: ${YELLOW}$fix_suggestion${NC}"
    fi
    MISSING+=("$header_name")
    return 1
  fi
}

# --- Check each header ---
echo ""
echo -e "${BOLD}Header Check:${NC}"
echo "────────────────────────────────────────────────────────────────"

# Content-Security-Policy (weight: 25)
check_header "Content-Security-Policy" 25 \
  "Add CSP header: Content-Security-Policy: default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'" || true

# Validate CSP directives if present
if header_exists "content-security-policy"; then
  CSP_VALUE=$(get_header_value "Content-Security-Policy")
  if echo "$CSP_VALUE" | grep -q "unsafe-inline" && ! echo "$CSP_VALUE" | grep -q "nonce-\|strict-dynamic"; then
    WARNINGS+=("CSP contains 'unsafe-inline' without nonce/strict-dynamic — XSS protection weakened")
    echo -e "    ${YELLOW}⚠ 'unsafe-inline' without nonce or strict-dynamic${NC}"
  fi
  if echo "$CSP_VALUE" | grep -q "unsafe-eval"; then
    WARNINGS+=("CSP contains 'unsafe-eval' — eval() and similar are allowed")
    echo -e "    ${YELLOW}⚠ 'unsafe-eval' allows eval() — consider removing${NC}"
  fi
  if ! echo "$CSP_VALUE" | grep -q "object-src"; then
    WARNINGS+=("CSP missing object-src directive — add object-src 'none'")
    echo -e "    ${YELLOW}⚠ Missing object-src directive — add object-src 'none'${NC}"
  fi
  if ! echo "$CSP_VALUE" | grep -q "base-uri"; then
    WARNINGS+=("CSP missing base-uri directive — add base-uri 'none'")
    echo -e "    ${YELLOW}⚠ Missing base-uri directive — add base-uri 'none'${NC}"
  fi
  if echo "$CSP_VALUE" | grep -q "\*\." || echo "$CSP_VALUE" | grep -qE "https?://\*"; then
    WARNINGS+=("CSP uses wildcard domains — consider using nonce + strict-dynamic instead")
    echo -e "    ${YELLOW}⚠ Wildcard domains detected — prefer nonce + strict-dynamic${NC}"
  fi
fi

# Strict-Transport-Security (weight: 20)
check_header "Strict-Transport-Security" 20 \
  "Add: Strict-Transport-Security: max-age=31536000; includeSubDomains; preload" || true

# Validate HSTS
if header_exists "strict-transport-security"; then
  HSTS_VALUE=$(get_header_value "Strict-Transport-Security")
  MAX_AGE=$(echo "$HSTS_VALUE" | grep -oP 'max-age=\K[0-9]+' || echo "0")
  if [[ "$MAX_AGE" -lt 31536000 ]]; then
    WARNINGS+=("HSTS max-age is less than 1 year ($MAX_AGE seconds) — increase to 31536000")
    echo -e "    ${YELLOW}⚠ max-age=$MAX_AGE is less than recommended 31536000 (1 year)${NC}"
  fi
  if ! echo "$HSTS_VALUE" | grep -qi "includesubdomains"; then
    WARNINGS+=("HSTS missing includeSubDomains")
    echo -e "    ${YELLOW}⚠ Missing includeSubDomains${NC}"
  fi
fi

# X-Content-Type-Options (weight: 10)
check_header "X-Content-Type-Options" 10 \
  "Add: X-Content-Type-Options: nosniff" || true

if header_exists "x-content-type-options"; then
  XCTO_VALUE=$(get_header_value "X-Content-Type-Options")
  if [[ "${XCTO_VALUE,,}" != "nosniff" ]]; then
    WARNINGS+=("X-Content-Type-Options should be 'nosniff', got '$XCTO_VALUE'")
    echo -e "    ${YELLOW}⚠ Value should be 'nosniff', got '$XCTO_VALUE'${NC}"
  fi
fi

# X-Frame-Options (weight: 10)
check_header "X-Frame-Options" 10 \
  "Add: X-Frame-Options: DENY (or use CSP frame-ancestors)" || true

# Referrer-Policy (weight: 10)
check_header "Referrer-Policy" 10 \
  "Add: Referrer-Policy: strict-origin-when-cross-origin" || true

# Permissions-Policy (weight: 10)
check_header "Permissions-Policy" 10 \
  "Add: Permissions-Policy: camera=(), microphone=(), geolocation=()" || true

# Cross-Origin-Opener-Policy (weight: 5)
check_header "Cross-Origin-Opener-Policy" 5 \
  "Add: Cross-Origin-Opener-Policy: same-origin" || true

# Cross-Origin-Resource-Policy (weight: 5)
check_header "Cross-Origin-Resource-Policy" 5 \
  "Add: Cross-Origin-Resource-Policy: same-origin" || true

# Cross-Origin-Embedder-Policy (weight: 5)
check_header "Cross-Origin-Embedder-Policy" 5 \
  "Add: Cross-Origin-Embedder-Policy: require-corp (or credentialless)" || true

# --- Bonus checks (informational) ---
echo ""
echo -e "${BOLD}Additional Checks:${NC}"
echo "────────────────────────────────────────────────────────────────"

# Check for leaky headers
if header_exists "server"; then
  SERVER_VALUE=$(get_header_value "Server")
  echo -e "  ${YELLOW}⚠${NC} ${BOLD}Server${NC} header present: ${CYAN}$SERVER_VALUE${NC}"
  echo -e "    Consider removing or minimizing server version disclosure"
fi

if header_exists "x-powered-by"; then
  XPB_VALUE=$(get_header_value "X-Powered-By")
  echo -e "  ${YELLOW}⚠${NC} ${BOLD}X-Powered-By${NC} header present: ${CYAN}$XPB_VALUE${NC}"
  echo -e "    Remove this header — it reveals your technology stack"
fi

# Check for deprecated X-XSS-Protection
if header_exists "x-xss-protection"; then
  echo -e "  ${YELLOW}ℹ${NC}  ${BOLD}X-XSS-Protection${NC} is set but deprecated in modern browsers"
  echo -e "    CSP is the recommended XSS protection mechanism"
fi

# Check frame-ancestors in CSP
if header_exists "content-security-policy"; then
  CSP_VALUE=$(get_header_value "Content-Security-Policy")
  if echo "$CSP_VALUE" | grep -q "frame-ancestors"; then
    echo -e "  ${GREEN}✓${NC} CSP includes ${BOLD}frame-ancestors${NC} directive"
  else
    echo -e "  ${YELLOW}⚠${NC} CSP missing ${BOLD}frame-ancestors${NC} — add frame-ancestors 'none' for clickjacking protection"
  fi
fi

# --- Calculate grade ---
echo ""
echo "════════════════════════════════════════════════════════════════"

if [[ $MAX_SCORE -eq 0 ]]; then
  PERCENTAGE=0
else
  PERCENTAGE=$((SCORE * 100 / MAX_SCORE))
fi

if [[ $PERCENTAGE -ge 95 ]]; then
  GRADE="A+"
  GRADE_COLOR=$GREEN
elif [[ $PERCENTAGE -ge 85 ]]; then
  GRADE="A"
  GRADE_COLOR=$GREEN
elif [[ $PERCENTAGE -ge 75 ]]; then
  GRADE="B"
  GRADE_COLOR=$YELLOW
elif [[ $PERCENTAGE -ge 60 ]]; then
  GRADE="C"
  GRADE_COLOR=$YELLOW
elif [[ $PERCENTAGE -ge 40 ]]; then
  GRADE="D"
  GRADE_COLOR=$RED
else
  GRADE="F"
  GRADE_COLOR=$RED
fi

echo -e "${BOLD}Score: ${SCORE}/${MAX_SCORE} (${PERCENTAGE}%)${NC}"
echo -e "${BOLD}Grade: ${GRADE_COLOR}${GRADE}${NC}"
echo ""

# --- Summary ---
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo -e "${BOLD}Missing Headers (${#MISSING[@]}):${NC}"
  for h in "${MISSING[@]}"; do
    echo -e "  ${RED}•${NC} $h"
  done
  echo ""
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo -e "${BOLD}Warnings (${#WARNINGS[@]}):${NC}"
  for w in "${WARNINGS[@]}"; do
    echo -e "  ${YELLOW}•${NC} $w"
  done
  echo ""
fi

if [[ ${#MISSING[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All recommended security headers are properly configured!${NC}"
fi

echo -e "${BLUE}Tip: Run with -v for detailed header values and fix suggestions${NC}"
echo -e "${BLUE}Also try: https://securityheaders.com and https://observatory.mozilla.org${NC}"
