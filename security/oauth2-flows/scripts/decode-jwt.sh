#!/usr/bin/env bash
#
# decode-jwt.sh — Decode and pretty-print a JWT token
#
# Usage:
#   ./decode-jwt.sh <token>               # Decode from argument
#   echo "<token>" | ./decode-jwt.sh      # Decode from stdin
#   ./decode-jwt.sh --header <token>      # Show header only
#   ./decode-jwt.sh --payload <token>     # Show payload only
#   ./decode-jwt.sh --verify <token>      # Show all parts + signature info
#
# Requirements: base64 (coreutils), jq (optional, for pretty-printing)
#
# Example:
#   $ ./decode-jwt.sh eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature
#   === HEADER ===
#   {
#     "alg": "RS256",
#     "typ": "JWT"
#   }
#   === PAYLOAD ===
#   {
#     "sub": "1234567890"
#   }
#
# ⚠️  This script decodes but does NOT verify signatures.
#     For signature verification, use a proper JWT library.

set -euo pipefail

# Parse flags
SHOW_PART="all"
TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --header)  SHOW_PART="header"; shift ;;
    --payload) SHOW_PART="payload"; shift ;;
    --verify)  SHOW_PART="verify"; shift ;;
    -h|--help)
      head -20 "$0" | tail -16
      exit 0
      ;;
    *)
      TOKEN="$1"; shift ;;
  esac
done

# Read from stdin if no token argument
if [[ -z "$TOKEN" ]]; then
  if [[ -t 0 ]]; then
    echo "Error: No token provided. Pass as argument or pipe via stdin." >&2
    echo "Usage: $0 [--header|--payload|--verify] <jwt-token>" >&2
    exit 1
  fi
  TOKEN=$(cat | tr -d '[:space:]')
fi

# Strip "Bearer " prefix if present
TOKEN="${TOKEN#Bearer }"

# Validate basic JWT structure (3 dot-separated parts)
IFS='.' read -ra PARTS <<< "$TOKEN"
if [[ ${#PARTS[@]} -lt 2 ]]; then
  echo "Error: Invalid JWT format. Expected at least 2 dot-separated parts." >&2
  exit 1
fi

# base64url decode with padding fix
b64url_decode() {
  local data="$1"
  # Add padding
  local pad=$(( 4 - ${#data} % 4 ))
  if [[ $pad -ne 4 ]]; then
    data="${data}$(printf '%*s' "$pad" '' | tr ' ' '=')"
  fi
  # Convert base64url to base64 and decode
  echo "$data" | tr '_-' '/+' | base64 -d 2>/dev/null
}

# Pretty-print JSON (use jq if available, fallback to python, then raw)
pretty_json() {
  if command -v jq &>/dev/null; then
    jq . 2>/dev/null || cat
  elif command -v python3 &>/dev/null; then
    python3 -m json.tool 2>/dev/null || cat
  else
    cat
  fi
}

HEADER=$(b64url_decode "${PARTS[0]}" | pretty_json)
PAYLOAD=$(b64url_decode "${PARTS[1]}" | pretty_json)

case "$SHOW_PART" in
  header)
    echo "$HEADER"
    ;;
  payload)
    echo "$PAYLOAD"
    ;;
  verify)
    echo "=== HEADER ==="
    echo "$HEADER"
    echo ""
    echo "=== PAYLOAD ==="
    echo "$PAYLOAD"
    echo ""
    echo "=== SIGNATURE ==="
    if [[ ${#PARTS[@]} -ge 3 && -n "${PARTS[2]}" ]]; then
      echo "Present (${#PARTS[2]} chars, base64url-encoded)"
      # Extract algorithm for context
      ALG=$(echo "$HEADER" | grep -o '"alg"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
      echo "Algorithm: ${ALG:-unknown}"
    else
      echo "Not present (unsigned JWT)"
    fi
    echo ""
    echo "=== TOKEN INFO ==="
    # Check expiry
    if command -v jq &>/dev/null; then
      EXP=$(echo "$PAYLOAD" | jq -r '.exp // empty' 2>/dev/null)
      IAT=$(echo "$PAYLOAD" | jq -r '.iat // empty' 2>/dev/null)
      NOW=$(date +%s)
      if [[ -n "$EXP" ]]; then
        EXP_DATE=$(date -d "@$EXP" 2>/dev/null || date -r "$EXP" 2>/dev/null || echo "unknown")
        if [[ "$NOW" -gt "$EXP" ]]; then
          echo "Status:  EXPIRED (expired at $EXP_DATE)"
        else
          REMAINING=$(( EXP - NOW ))
          echo "Status:  Valid (expires at $EXP_DATE, ${REMAINING}s remaining)"
        fi
      fi
      if [[ -n "$IAT" ]]; then
        IAT_DATE=$(date -d "@$IAT" 2>/dev/null || date -r "$IAT" 2>/dev/null || echo "unknown")
        echo "Issued:  $IAT_DATE"
      fi
    fi
    ;;
  all)
    echo "=== HEADER ==="
    echo "$HEADER"
    echo ""
    echo "=== PAYLOAD ==="
    echo "$PAYLOAD"
    ;;
esac
