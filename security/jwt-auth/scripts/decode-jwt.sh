#!/usr/bin/env bash
#
# decode-jwt.sh — Decode and pretty-print a JWT token
#
# Usage:
#   ./decode-jwt.sh <token>                     # Decode from argument
#   echo "<token>" | ./decode-jwt.sh            # Decode from stdin
#   ./decode-jwt.sh <token> --verify <key-file> # Decode and verify signature
#
# Output:
#   - Decoded header (JSON, pretty-printed)
#   - Decoded payload (JSON, pretty-printed)
#   - Signature info (algorithm, base64url-encoded)
#   - Expiry status (expired / valid / time remaining)
#
# Requirements: base64, python3 or jq (for pretty-printing)
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Read token from argument or stdin
TOKEN=""
VERIFY_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify|-v)
            VERIFY_KEY="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 <token> [--verify <key-file>]"
            echo ""
            echo "Options:"
            echo "  --verify, -v <file>   Verify signature using PEM key file"
            echo "  --help, -h            Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 eyJhbGciOi..."
            echo "  echo 'eyJhbGciOi...' | $0"
            echo "  $0 eyJhbGciOi... --verify public.pem"
            exit 0
            ;;
        *)
            TOKEN="$1"
            shift
            ;;
    esac
done

if [[ -z "$TOKEN" ]]; then
    if [[ -t 0 ]]; then
        echo "Error: No token provided. Use: $0 <token> or pipe via stdin" >&2
        exit 1
    fi
    TOKEN=$(cat | tr -d '[:space:]')
fi

# Strip "Bearer " prefix if present
TOKEN="${TOKEN#Bearer }"

# Validate basic JWT structure (3 dot-separated parts)
IFS='.' read -r HEADER_B64 PAYLOAD_B64 SIGNATURE_B64 <<< "$TOKEN"

if [[ -z "$HEADER_B64" || -z "$PAYLOAD_B64" ]]; then
    echo "Error: Invalid JWT format. Expected 3 dot-separated Base64URL parts." >&2
    exit 1
fi

# Base64URL decode function
b64url_decode() {
    local input="$1"
    # Replace URL-safe characters with standard base64
    local std_b64="${input//-/+}"
    std_b64="${std_b64//_//}"
    # Add padding
    local pad=$(( 4 - ${#std_b64} % 4 ))
    if [[ $pad -ne 4 ]]; then
        std_b64="${std_b64}$(printf '=%.0s' $(seq 1 "$pad"))"
    fi
    echo "$std_b64" | base64 -d 2>/dev/null
}

# Pretty-print JSON
pretty_json() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool 2>/dev/null || echo "$1"
    elif command -v jq >/dev/null 2>&1; then
        echo "$1" | jq . 2>/dev/null || echo "$1"
    else
        echo "$1"
    fi
}

# Decode header
HEADER_JSON=$(b64url_decode "$HEADER_B64")
# Decode payload
PAYLOAD_JSON=$(b64url_decode "$PAYLOAD_B64")

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}          JWT Token Decoder            ${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"

# --- Header ---
echo ""
echo -e "${BOLD}${YELLOW}▸ HEADER${NC}"
echo "$HEADER_JSON" | pretty_json

# Extract algorithm from header
ALG=$(echo "$HEADER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('alg','unknown'))" 2>/dev/null || echo "unknown")
KID=$(echo "$HEADER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kid','none'))" 2>/dev/null || echo "none")
TYP=$(echo "$HEADER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('typ','none'))" 2>/dev/null || echo "none")

# --- Payload ---
echo ""
echo -e "${BOLD}${YELLOW}▸ PAYLOAD${NC}"
echo "$PAYLOAD_JSON" | pretty_json

# --- Analyze Claims ---
echo ""
echo -e "${BOLD}${YELLOW}▸ ANALYSIS${NC}"

if command -v python3 >/dev/null 2>&1; then
    python3 << 'PYEOF'
import json, sys
from datetime import datetime, timezone

try:
    payload = json.loads('''PAYLOAD_PLACEHOLDER''')
except:
    sys.exit(0)

now = datetime.now(timezone.utc).timestamp()

# Check expiry
if 'exp' in payload:
    exp = payload['exp']
    exp_dt = datetime.fromtimestamp(exp, tz=timezone.utc)
    if exp < now:
        delta = now - exp
        if delta < 3600:
            print(f"  ⏰ Expired: {delta:.0f} seconds ago")
        elif delta < 86400:
            print(f"  ⏰ Expired: {delta/3600:.1f} hours ago")
        else:
            print(f"  ⏰ Expired: {delta/86400:.1f} days ago")
        print(f"     exp: {exp_dt.isoformat()}")
    else:
        remaining = exp - now
        if remaining < 3600:
            print(f"  ✅ Valid: {remaining:.0f} seconds remaining")
        elif remaining < 86400:
            print(f"  ✅ Valid: {remaining/3600:.1f} hours remaining")
        else:
            print(f"  ✅ Valid: {remaining/86400:.1f} days remaining")
        print(f"     exp: {exp_dt.isoformat()}")
else:
    print("  ⚠️  No exp claim — token never expires!")

# Check iat
if 'iat' in payload:
    iat = payload['iat']
    iat_dt = datetime.fromtimestamp(iat, tz=timezone.utc)
    age = now - iat
    if age < 3600:
        print(f"  📅 Issued: {age:.0f} seconds ago ({iat_dt.isoformat()})")
    elif age < 86400:
        print(f"  📅 Issued: {age/3600:.1f} hours ago ({iat_dt.isoformat()})")
    else:
        print(f"  📅 Issued: {age/86400:.1f} days ago ({iat_dt.isoformat()})")

# Check nbf
if 'nbf' in payload:
    nbf = payload['nbf']
    if nbf > now:
        print(f"  ⏳ Not valid yet: valid from {datetime.fromtimestamp(nbf, tz=timezone.utc).isoformat()}")
    else:
        print(f"  ✅ nbf: valid (since {datetime.fromtimestamp(nbf, tz=timezone.utc).isoformat()})")

# Standard claims
if 'iss' in payload: print(f"  🏢 Issuer: {payload['iss']}")
if 'sub' in payload: print(f"  👤 Subject: {payload['sub']}")
if 'aud' in payload: print(f"  🎯 Audience: {payload['aud']}")
if 'jti' in payload: print(f"  🆔 Token ID: {payload['jti']}")

# Size info
token_size = len('''TOKEN_PLACEHOLDER''')
payload_size = len(json.dumps(payload))
if token_size > 4096:
    print(f"  ⚠️  Token size: {token_size} bytes (exceeds 4KB — may hit header limits)")
elif token_size > 2048:
    print(f"  ⚡ Token size: {token_size} bytes (large — consider reducing claims)")
else:
    print(f"  📏 Token size: {token_size} bytes")
PYEOF
fi 2>/dev/null | sed "s|PAYLOAD_PLACEHOLDER|${PAYLOAD_JSON//|/\\|}|g" | sed "s|TOKEN_PLACEHOLDER|${TOKEN}|g" | python3 2>/dev/null || true

# --- Signature ---
echo ""
echo -e "${BOLD}${YELLOW}▸ SIGNATURE${NC}"
echo "  Algorithm: ${ALG}"
echo "  Key ID:    ${KID}"
SIG_LEN=${#SIGNATURE_B64}
echo "  Signature: ${SIGNATURE_B64:0:32}... (${SIG_LEN} chars)"

if [[ -z "$SIGNATURE_B64" || "$SIGNATURE_B64" == "" ]]; then
    echo -e "  ${RED}⚠️  WARNING: No signature! This token is unsigned (alg:none).${NC}"
fi

# --- Verify signature if key provided ---
if [[ -n "$VERIFY_KEY" ]]; then
    echo ""
    echo -e "${BOLD}${YELLOW}▸ SIGNATURE VERIFICATION${NC}"
    if [[ ! -f "$VERIFY_KEY" ]]; then
        echo -e "  ${RED}Error: Key file not found: ${VERIFY_KEY}${NC}"
        exit 1
    fi

    SIGNING_INPUT="${HEADER_B64}.${PAYLOAD_B64}"

    case "$ALG" in
        RS256|RS384|RS512)
            DGST_ALG="${ALG:2}"  # 256, 384, 512
            DGST_ALG="sha${DGST_ALG}"
            SIG_BYTES=$(b64url_decode "$SIGNATURE_B64")
            RESULT=$(echo -n "$SIGNING_INPUT" | \
                openssl dgst "-${DGST_ALG}" -verify "$VERIFY_KEY" -signature <(echo -n "$SIG_BYTES") 2>&1) || true
            if echo "$RESULT" | grep -qi "verified ok"; then
                echo -e "  ${GREEN}✅ Signature verified successfully${NC}"
            else
                echo -e "  ${RED}❌ Signature verification failed${NC}"
            fi
            ;;
        ES256|ES384|ES512)
            echo "  ECDSA verification requires library support."
            echo "  Use: python3 -c \"import jwt; jwt.decode(token, key, algorithms=['${ALG}'])\""
            ;;
        HS256|HS384|HS512)
            echo "  HMAC verification requires the shared secret (not a PEM file)."
            echo "  Use: python3 -c \"import jwt; jwt.decode(token, secret, algorithms=['${ALG}'])\""
            ;;
        *)
            echo "  Unsupported algorithm for verification: ${ALG}"
            ;;
    esac
fi

echo ""
echo -e "${CYAN}───────────────────────────────────────${NC}"
