#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# decode-jwt.sh — Decode and inspect JSON Web Tokens (JWTs)
#
# Usage:
#   ./decode-jwt.sh <token>
#   echo "<token>" | ./decode-jwt.sh
#   ./decode-jwt.sh -h | --help
#
# Features:
#   - Decodes header and payload from base64url encoding
#   - Pretty-prints JSON (uses jq if available, falls back to python)
#   - Shows claimed signing algorithm
#   - Shows expiration status, remaining time, or time since expiry
#   - Validates JWT structure (3 dot-separated parts, valid base64url)
#   - Does NOT verify cryptographic signatures (requires keys)
#
# Examples:
#   ./decode-jwt.sh eyJhbGciOiJIUzI1NiIs...
#   pbpaste | ./decode-jwt.sh
#   cat token.txt | ./decode-jwt.sh
##############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

usage() {
  sed -n '/^##*$/,/^##*$/{ /^##*$/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
}

err() {
  echo -e "${RED}ERROR: $*${RESET}" >&2
  exit 1
}

# Pretty-print JSON: prefer jq, fall back to python
pretty_json() {
  if command -v jq &>/dev/null; then
    jq . 2>/dev/null || cat
  elif command -v python3 &>/dev/null; then
    python3 -m json.tool 2>/dev/null || cat
  elif command -v python &>/dev/null; then
    python -m json.tool 2>/dev/null || cat
  else
    cat
  fi
}

# Decode base64url to raw bytes. Adds padding as needed.
base64url_decode() {
  local input="$1"
  # Replace URL-safe characters with standard base64
  local b64="${input//-/+}"
  b64="${b64//_//}"
  # Add padding
  local pad=$(( 4 - ${#b64} % 4 ))
  if (( pad != 4 )); then
    b64="${b64}$(printf '%0.s=' $(seq 1 "$pad"))"
  fi
  echo "$b64" | base64 -d 2>/dev/null || echo "$b64" | base64 -D 2>/dev/null
}

# Validate that a string is valid base64url
is_valid_base64url() {
  local input="$1"
  if [[ "$input" =~ ^[A-Za-z0-9_-]+$ ]]; then
    return 0
  fi
  return 1
}

# Format a duration in seconds to human-readable
format_duration() {
  local total_seconds="$1"
  local sign=""
  if (( total_seconds < 0 )); then
    total_seconds=$(( -total_seconds ))
    sign="-"
  fi
  local days=$(( total_seconds / 86400 ))
  local hours=$(( (total_seconds % 86400) / 3600 ))
  local minutes=$(( (total_seconds % 3600) / 60 ))
  local seconds=$(( total_seconds % 60 ))

  local parts=()
  (( days > 0 )) && parts+=("${days}d")
  (( hours > 0 )) && parts+=("${hours}h")
  (( minutes > 0 )) && parts+=("${minutes}m")
  parts+=("${seconds}s")

  echo "${sign}${parts[*]}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

# Handle help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

# Read JWT from argument or stdin
if [[ $# -ge 1 ]]; then
  JWT="$1"
else
  if [[ -t 0 ]]; then
    err "No JWT provided. Pass as argument or pipe to stdin.\n  Usage: $0 <token>"
  fi
  JWT="$(cat)"
fi

# Trim whitespace
JWT="$(echo "$JWT" | tr -d '[:space:]')"

if [[ -z "$JWT" ]]; then
  err "Empty token provided."
fi

# ── Structural Validation ────────────────────────────────────────────────────

IFS='.' read -ra PARTS <<< "$JWT"

if [[ ${#PARTS[@]} -ne 3 ]]; then
  err "Invalid JWT structure: expected 3 dot-separated parts, got ${#PARTS[@]}."
fi

HEADER_B64="${PARTS[0]}"
PAYLOAD_B64="${PARTS[1]}"
SIGNATURE_B64="${PARTS[2]}"

for i in 0 1 2; do
  label=("header" "payload" "signature")
  if ! is_valid_base64url "${PARTS[$i]}"; then
    err "Invalid base64url in ${label[$i]} part."
  fi
done

# ── Decode ───────────────────────────────────────────────────────────────────

HEADER_JSON="$(base64url_decode "$HEADER_B64")"
PAYLOAD_JSON="$(base64url_decode "$PAYLOAD_B64")"

# Verify decoded values are valid JSON
if ! echo "$HEADER_JSON" | pretty_json > /dev/null 2>&1; then
  err "Header does not contain valid JSON."
fi
if ! echo "$PAYLOAD_JSON" | pretty_json > /dev/null 2>&1; then
  err "Payload does not contain valid JSON."
fi

# ── Display ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║          JWT Token Inspector             ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"

echo ""
echo -e "${BOLD}${BLUE}── Header ──────────────────────────────────${RESET}"
echo "$HEADER_JSON" | pretty_json

# Extract algorithm
ALG="(unknown)"
if command -v jq &>/dev/null; then
  ALG="$(echo "$HEADER_JSON" | jq -r '.alg // "(unknown)"' 2>/dev/null)"
  TYP="$(echo "$HEADER_JSON" | jq -r '.typ // "(not set)"' 2>/dev/null)"
  KID="$(echo "$HEADER_JSON" | jq -r '.kid // empty' 2>/dev/null)"
elif command -v python3 &>/dev/null; then
  ALG="$(echo "$HEADER_JSON" | python3 -c "import sys,json; h=json.load(sys.stdin); print(h.get('alg','(unknown)'))" 2>/dev/null)" || true
  TYP="$(echo "$HEADER_JSON" | python3 -c "import sys,json; h=json.load(sys.stdin); print(h.get('typ','(not set)'))" 2>/dev/null)" || true
  KID="$(echo "$HEADER_JSON" | python3 -c "import sys,json; h=json.load(sys.stdin); print(h.get('kid',''))" 2>/dev/null)" || true
fi

echo ""
echo -e "${BOLD}${BLUE}── Payload ─────────────────────────────────${RESET}"
echo "$PAYLOAD_JSON" | pretty_json

echo ""
echo -e "${BOLD}${BLUE}── Signature ───────────────────────────────${RESET}"
echo -e "  ${YELLOW}(base64url, ${#SIGNATURE_B64} chars)${RESET}"
echo "  ${SIGNATURE_B64:0:64}..."

echo ""
echo -e "${BOLD}${BLUE}── Token Info ──────────────────────────────${RESET}"
echo -e "  Algorithm: ${BOLD}${ALG}${RESET}"
echo -e "  Type:      ${TYP:-JWT}"
if [[ -n "${KID:-}" ]]; then
  echo -e "  Key ID:    ${KID}"
fi

# ── Expiration Analysis ──────────────────────────────────────────────────────

extract_claim() {
  local json="$1" claim="$2"
  if command -v jq &>/dev/null; then
    echo "$json" | jq -r ".$claim // empty" 2>/dev/null
  elif command -v python3 &>/dev/null; then
    echo "$json" | python3 -c "import sys,json; p=json.load(sys.stdin); v=p.get('$claim'); print(v if v is not None else '')" 2>/dev/null
  fi
}

NOW="$(date +%s)"

EXP="$(extract_claim "$PAYLOAD_JSON" "exp")"
IAT="$(extract_claim "$PAYLOAD_JSON" "iat")"
NBF="$(extract_claim "$PAYLOAD_JSON" "nbf")"

echo ""
echo -e "${BOLD}${BLUE}── Time Analysis ───────────────────────────${RESET}"

if [[ -n "$IAT" && "$IAT" =~ ^[0-9]+$ ]]; then
  IAT_DATE="$(date -d "@$IAT" 2>/dev/null || date -r "$IAT" 2>/dev/null || echo "unknown")"
  echo -e "  Issued at (iat):     ${IAT_DATE}  (${IAT})"
fi

if [[ -n "$NBF" && "$NBF" =~ ^[0-9]+$ ]]; then
  NBF_DATE="$(date -d "@$NBF" 2>/dev/null || date -r "$NBF" 2>/dev/null || echo "unknown")"
  if (( NOW < NBF )); then
    UNTIL_VALID=$(( NBF - NOW ))
    echo -e "  Not before (nbf):    ${NBF_DATE}  (${NBF})"
    echo -e "  ${YELLOW}⚠  Token is not yet valid! Valid in $(format_duration $UNTIL_VALID)${RESET}"
  else
    echo -e "  Not before (nbf):    ${NBF_DATE}  (${NBF})"
  fi
fi

if [[ -n "$EXP" && "$EXP" =~ ^[0-9]+$ ]]; then
  EXP_DATE="$(date -d "@$EXP" 2>/dev/null || date -r "$EXP" 2>/dev/null || echo "unknown")"
  DIFF=$(( EXP - NOW ))
  echo -e "  Expires at (exp):    ${EXP_DATE}  (${EXP})"
  if (( DIFF > 0 )); then
    echo -e "  ${GREEN}✓  Token is VALID — expires in $(format_duration $DIFF)${RESET}"
  else
    echo -e "  ${RED}✗  Token is EXPIRED — expired $(format_duration $(( -DIFF ))) ago${RESET}"
  fi
  if [[ -n "$IAT" && "$IAT" =~ ^[0-9]+$ ]]; then
    LIFETIME=$(( EXP - IAT ))
    echo -e "  Total lifetime:      $(format_duration $LIFETIME)"
  fi
else
  echo -e "  ${YELLOW}⚠  No expiration claim (exp) — token never expires${RESET}"
fi

echo ""
echo -e "${YELLOW}NOTE: Signature is NOT verified (requires signing key).${RESET}"
echo -e "${YELLOW}      Algorithm '${ALG}' is claimed but not authenticated.${RESET}"
echo ""
