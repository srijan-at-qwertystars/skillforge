#!/usr/bin/env bash
# generate-pkce.sh — Generate a PKCE code verifier and challenge pair for testing OAuth flows.
#
# Usage:
#   ./generate-pkce.sh              # Generate a random verifier and its S256 challenge
#   ./generate-pkce.sh <verifier>   # Compute the S256 challenge for a given verifier
#
# Output format:
#   CODE_VERIFIER=<verifier>
#   CODE_CHALLENGE=<challenge>
#   CODE_CHALLENGE_METHOD=S256
#
# Requirements: openssl, xxd (or od)

set -euo pipefail

base64url_encode() {
  # Base64URL encode stdin: replace +/ with -_, strip = padding
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

generate_verifier() {
  # Generate a 32-byte (43-character base64url) cryptographic random string
  openssl rand 32 | base64url_encode
}

compute_challenge() {
  local verifier="$1"
  # SHA-256 hash the verifier, then base64url encode the raw digest
  printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64url_encode
}

validate_verifier() {
  local verifier="$1"
  local len=${#verifier}
  if [ "$len" -lt 43 ] || [ "$len" -gt 128 ]; then
    echo "ERROR: Code verifier must be 43-128 characters (got $len)" >&2
    exit 1
  fi
  # Check for valid base64url characters
  if ! echo "$verifier" | grep -qE '^[A-Za-z0-9_-]+$'; then
    echo "ERROR: Code verifier contains invalid characters (must be [A-Za-z0-9_-])" >&2
    exit 1
  fi
}

main() {
  local verifier

  if [ $# -ge 1 ]; then
    verifier="$1"
    validate_verifier "$verifier"
  else
    verifier=$(generate_verifier)
  fi

  local challenge
  challenge=$(compute_challenge "$verifier")

  echo "CODE_VERIFIER=$verifier"
  echo "CODE_CHALLENGE=$challenge"
  echo "CODE_CHALLENGE_METHOD=S256"
}

main "$@"
