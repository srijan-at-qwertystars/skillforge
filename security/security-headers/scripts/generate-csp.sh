#!/usr/bin/env bash
#
# generate-csp.sh — Interactive CSP header generator
#
# Usage:
#   ./generate-csp.sh              # Interactive mode
#   ./generate-csp.sh --strict     # Generate strict baseline CSP
#   ./generate-csp.sh --permissive # Generate permissive starter CSP
#
# Asks about your application requirements and generates an appropriate
# Content-Security-Policy header value with comments.
#

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Quick modes ---
if [[ "${1:-}" == "--strict" ]]; then
  echo -e "${BOLD}Strict Nonce-Based CSP:${NC}"
  echo ""
  echo "Content-Security-Policy: default-src 'self'; script-src 'nonce-{RANDOM}' 'strict-dynamic'; style-src 'self' 'nonce-{RANDOM}'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests"
  echo ""
  echo -e "${YELLOW}Replace {RANDOM} with a cryptographically random value generated per-request.${NC}"
  exit 0
fi

if [[ "${1:-}" == "--permissive" ]]; then
  echo -e "${BOLD}Permissive Starter CSP (Report-Only):${NC}"
  echo ""
  echo "Content-Security-Policy-Report-Only: default-src 'self' https:; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: https:; font-src 'self' https:; connect-src 'self' https:; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
  echo ""
  echo -e "${YELLOW}Deploy as report-only first, then tighten based on violation reports.${NC}"
  exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0 [--strict|--permissive]"
  echo ""
  echo "Interactive CSP generator. Run without arguments for interactive mode."
  echo ""
  echo "Options:"
  echo "  --strict      Generate a strict nonce-based CSP"
  echo "  --permissive  Generate a permissive report-only CSP"
  echo "  -h, --help    Show this help message"
  exit 0
fi

# --- Interactive mode ---
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Content-Security-Policy Generator${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

ask() {
  local prompt="$1"
  local default="$2"
  local response
  echo -en "${CYAN}$prompt${NC} [${default}]: "
  read -r response
  echo "${response:-$default}"
}

ask_yn() {
  local prompt="$1"
  local default="$2"
  local response
  response=$(ask "$prompt (y/n)" "$default")
  [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

# --- Collect requirements ---
echo -e "${BOLD}Application Type:${NC}"
USE_NONCES=false
USE_HASHES=false
IS_SPA=false

if ask_yn "Do you have a server that renders HTML (SSR)?" "y"; then
  USE_NONCES=true
  echo -e "  ${GREEN}→ Will use nonce-based CSP (recommended)${NC}"
else
  if ask_yn "Is this a static site (no server)?" "y"; then
    USE_HASHES=true
    echo -e "  ${GREEN}→ Will use hash-based CSP${NC}"
  fi
fi

if ask_yn "Is this a Single-Page Application (SPA)?" "n"; then
  IS_SPA=true
fi

echo ""
echo -e "${BOLD}Inline Code:${NC}"
HAS_INLINE_SCRIPTS=false
HAS_INLINE_STYLES=false

if ask_yn "Does your app use inline <script> tags?" "n"; then
  HAS_INLINE_SCRIPTS=true
fi

if ask_yn "Does your app use inline styles (style attributes or <style> tags)?" "n"; then
  HAS_INLINE_STYLES=true
fi

HAS_EVAL=false
if ask_yn "Does your app use eval(), new Function(), or setTimeout with strings?" "n"; then
  HAS_EVAL=true
fi

echo ""
echo -e "${BOLD}External Sources:${NC}"

API_DOMAINS=""
if ask_yn "Does your app make API calls to external domains?" "n"; then
  API_DOMAINS=$(ask "Enter API domains (space-separated, e.g., api.example.com api2.example.com)" "")
fi

CDN_DOMAINS=""
if ask_yn "Do you load scripts/styles from CDNs?" "n"; then
  CDN_DOMAINS=$(ask "Enter CDN domains (space-separated, e.g., cdn.jsdelivr.net)" "")
fi

IMAGE_DOMAINS=""
if ask_yn "Do you load images from external domains?" "n"; then
  IMAGE_DOMAINS=$(ask "Enter image domains (space-separated, e.g., images.example.com)" "")
fi

FONT_DOMAINS=""
if ask_yn "Do you load fonts from external sources (e.g., Google Fonts)?" "n"; then
  FONT_DOMAINS=$(ask "Enter font domains (space-separated, e.g., fonts.googleapis.com fonts.gstatic.com)" "fonts.googleapis.com fonts.gstatic.com")
fi

echo ""
echo -e "${BOLD}Embedding:${NC}"
ALLOW_IFRAMES=false
IFRAME_SOURCES=""
if ask_yn "Does your app embed iframes (YouTube, maps, etc.)?" "n"; then
  ALLOW_IFRAMES=true
  IFRAME_SOURCES=$(ask "Enter iframe source domains (space-separated)" "")
fi

ALLOW_FRAMING=false
FRAMING_SOURCES=""
if ask_yn "Should other sites be allowed to frame YOUR page?" "n"; then
  ALLOW_FRAMING=true
  FRAMING_SOURCES=$(ask "Enter allowed framing origins (space-separated, or 'self')" "self")
fi

echo ""
echo -e "${BOLD}Features:${NC}"
HAS_WEBSOCKET=false
if ask_yn "Does your app use WebSockets?" "n"; then
  HAS_WEBSOCKET=true
fi

HAS_WASM=false
if ask_yn "Does your app use WebAssembly?" "n"; then
  HAS_WASM=true
fi

USE_REPORT_ONLY=false
if ask_yn "Deploy as report-only first (recommended for new CSP)?" "y"; then
  USE_REPORT_ONLY=true
fi

REPORT_URI=""
if ask_yn "Set up violation reporting?" "n"; then
  REPORT_URI=$(ask "Enter report endpoint URL" "/csp-report")
fi

# --- Build CSP ---
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Generated CSP${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

# default-src
DEFAULT_SRC="'self'"

# script-src
SCRIPT_SRC="'self'"
SCRIPT_COMMENTS=""
if [[ "$USE_NONCES" == true ]]; then
  SCRIPT_SRC="'self' 'nonce-{RANDOM}' 'strict-dynamic'"
  SCRIPT_COMMENTS="# Replace {RANDOM} with a per-request cryptographic nonce"
  if [[ "$HAS_INLINE_SCRIPTS" == true ]]; then
    # strict-dynamic + nonce covers inline scripts
    SCRIPT_SRC="$SCRIPT_SRC https: 'unsafe-inline'"
    SCRIPT_COMMENTS="$SCRIPT_COMMENTS\n# https: and 'unsafe-inline' are fallbacks for browsers without strict-dynamic support"
  fi
elif [[ "$USE_HASHES" == true ]]; then
  SCRIPT_SRC="'self' 'strict-dynamic'"
  SCRIPT_COMMENTS="# Add 'sha256-{HASH}' for each inline script"
fi

if [[ -n "$CDN_DOMAINS" && "$USE_NONCES" != true ]]; then
  SCRIPT_SRC="$SCRIPT_SRC $CDN_DOMAINS"
fi

if [[ "$HAS_EVAL" == true ]]; then
  SCRIPT_SRC="$SCRIPT_SRC 'unsafe-eval'"
  SCRIPT_COMMENTS="${SCRIPT_COMMENTS}\n# WARNING: 'unsafe-eval' weakens CSP — refactor eval() usage if possible"
fi

if [[ "$HAS_WASM" == true ]]; then
  SCRIPT_SRC="$SCRIPT_SRC 'wasm-unsafe-eval'"
fi

# style-src
STYLE_SRC="'self'"
if [[ "$USE_NONCES" == true ]]; then
  STYLE_SRC="'self' 'nonce-{RANDOM}'"
elif [[ "$HAS_INLINE_STYLES" == true ]]; then
  STYLE_SRC="'self' 'unsafe-inline'"
fi
if [[ -n "$CDN_DOMAINS" ]]; then
  STYLE_SRC="$STYLE_SRC $CDN_DOMAINS"
fi
if [[ -n "$FONT_DOMAINS" ]]; then
  for domain in $FONT_DOMAINS; do
    if echo "$domain" | grep -q "googleapis"; then
      STYLE_SRC="$STYLE_SRC https://$domain"
    fi
  done
fi

# img-src
IMG_SRC="'self' data:"
if [[ -n "$IMAGE_DOMAINS" ]]; then
  for domain in $IMAGE_DOMAINS; do
    IMG_SRC="$IMG_SRC https://$domain"
  done
fi

# font-src
FONT_SRC="'self'"
if [[ -n "$FONT_DOMAINS" ]]; then
  for domain in $FONT_DOMAINS; do
    FONT_SRC="$FONT_SRC https://$domain"
  done
fi

# connect-src
CONNECT_SRC="'self'"
if [[ -n "$API_DOMAINS" ]]; then
  for domain in $API_DOMAINS; do
    CONNECT_SRC="$CONNECT_SRC https://$domain"
  done
fi
if [[ "$HAS_WEBSOCKET" == true ]]; then
  CONNECT_SRC="$CONNECT_SRC wss:"
fi

# frame-src
FRAME_SRC="'none'"
if [[ "$ALLOW_IFRAMES" == true && -n "$IFRAME_SOURCES" ]]; then
  FRAME_SRC=""
  for domain in $IFRAME_SOURCES; do
    FRAME_SRC="$FRAME_SRC https://$domain"
  done
  FRAME_SRC=$(echo "$FRAME_SRC" | xargs)
fi

# frame-ancestors
FRAME_ANCESTORS="'none'"
if [[ "$ALLOW_FRAMING" == true && -n "$FRAMING_SOURCES" ]]; then
  FRAME_ANCESTORS=""
  for source in $FRAMING_SOURCES; do
    if [[ "$source" == "self" ]]; then
      FRAME_ANCESTORS="$FRAME_ANCESTORS 'self'"
    else
      FRAME_ANCESTORS="$FRAME_ANCESTORS https://$source"
    fi
  done
  FRAME_ANCESTORS=$(echo "$FRAME_ANCESTORS" | xargs)
fi

# worker-src
WORKER_SRC="'self'"
if [[ "$IS_SPA" == true ]]; then
  WORKER_SRC="'self' blob:"
fi

# Build the CSP string
HEADER_NAME="Content-Security-Policy"
if [[ "$USE_REPORT_ONLY" == true ]]; then
  HEADER_NAME="Content-Security-Policy-Report-Only"
fi

CSP_PARTS=(
  "default-src ${DEFAULT_SRC}"
  "script-src ${SCRIPT_SRC}"
  "style-src ${STYLE_SRC}"
  "img-src ${IMG_SRC}"
  "font-src ${FONT_SRC}"
  "connect-src ${CONNECT_SRC}"
  "media-src 'self'"
  "object-src 'none'"
  "frame-src ${FRAME_SRC}"
  "worker-src ${WORKER_SRC}"
  "frame-ancestors ${FRAME_ANCESTORS}"
  "form-action 'self'"
  "base-uri 'none'"
  "upgrade-insecure-requests"
)

if [[ -n "$REPORT_URI" ]]; then
  CSP_PARTS+=("report-uri ${REPORT_URI}")
fi

# Output
if [[ -n "$SCRIPT_COMMENTS" ]]; then
  echo -e "${YELLOW}${SCRIPT_COMMENTS}${NC}"
  echo ""
fi

echo -e "${BOLD}${HEADER_NAME}:${NC}"
echo -n "  "
FIRST=true
for part in "${CSP_PARTS[@]}"; do
  if [[ "$FIRST" == true ]]; then
    echo -n "$part"
    FIRST=false
  else
    echo -n "; $part"
  fi
done
echo ""

# Single-line version
echo ""
echo -e "${BOLD}Single-line header value:${NC}"
echo ""
CSP_ONELINE=""
FIRST=true
for part in "${CSP_PARTS[@]}"; do
  if [[ "$FIRST" == true ]]; then
    CSP_ONELINE="$part"
    FIRST=false
  else
    CSP_ONELINE="$CSP_ONELINE; $part"
  fi
done
echo "${HEADER_NAME}: ${CSP_ONELINE}"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"

if [[ "$USE_REPORT_ONLY" == true ]]; then
  echo -e "${YELLOW}Deployed as Report-Only — violations are reported but not blocked.${NC}"
  echo -e "${YELLOW}Switch to Content-Security-Policy (without -Report-Only) after testing.${NC}"
fi

if [[ "$USE_NONCES" == true ]]; then
  echo -e "${CYAN}Remember: Generate a unique nonce per HTTP response using:${NC}"
  echo -e "${CYAN}  Node.js:  crypto.randomBytes(16).toString('base64')${NC}"
  echo -e "${CYAN}  Python:   base64.b64encode(secrets.token_bytes(16)).decode()${NC}"
fi

echo ""
echo -e "${GREEN}Test your CSP: https://csp-evaluator.withgoogle.com${NC}"
