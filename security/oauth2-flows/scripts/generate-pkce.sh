#!/usr/bin/env bash
#
# generate-pkce.sh — Generate PKCE code_verifier and code_challenge (S256)
#
# Usage:
#   ./generate-pkce.sh              # Generate and print both values
#   ./generate-pkce.sh --json       # Output as JSON
#   ./generate-pkce.sh --env        # Output as shell export statements
#
# Requirements: openssl, base64 (coreutils)
#
# The code_verifier is a cryptographically random string (43-128 chars, RFC 7636).
# The code_challenge is the base64url-encoded SHA-256 hash of the verifier.
#
# Example:
#   $ ./generate-pkce.sh
#   code_verifier:  dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk...
#   code_challenge: E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
#   method:         S256

set -euo pipefail

# Generate 32 random bytes → base64url encode → trim to 43-128 chars
code_verifier=$(openssl rand -base64 96 | tr -d '\n' | tr '+/' '-_' | tr -d '=' | head -c 128)

# SHA-256 hash → base64url encode (no padding)
code_challenge=$(printf '%s' "$code_verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')

case "${1:-}" in
  --json)
    cat <<EOF
{
  "code_verifier": "$code_verifier",
  "code_challenge": "$code_challenge",
  "code_challenge_method": "S256"
}
EOF
    ;;
  --env)
    echo "export CODE_VERIFIER='$code_verifier'"
    echo "export CODE_CHALLENGE='$code_challenge'"
    echo "export CODE_CHALLENGE_METHOD='S256'"
    ;;
  *)
    echo "code_verifier:  $code_verifier"
    echo "code_challenge: $code_challenge"
    echo "method:         S256"
    ;;
esac
