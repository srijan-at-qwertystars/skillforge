#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# generate-keys.sh — Generate JWT signing key pairs and JWKS output
#
# Usage:
#   ./generate-keys.sh [OPTIONS]
#
# Options:
#   --algorithm ALG    Signing algorithm: RS256, RS384, RS512,
#                      ES256, ES384, ES512, HS256 (default: RS256)
#   --key-size BITS    RSA key size in bits (default: 2048, min: 2048)
#   --output-dir DIR   Directory for generated key files (default: ./keys)
#   --kid ID           Key ID for JWKS output (default: auto-generated)
#   -h, --help         Show this help message
#
# Output files by algorithm:
#   RSA  (RS256/RS384/RS512):  private.pem, public.pem, jwks.json
#   ECDSA (ES256/ES384/ES512): ec-private.pem, ec-public.pem, jwks.json
#   HMAC (HS256):              hmac-secret.txt, jwks.json
#
# Examples:
#   ./generate-keys.sh                               # RS256, 2048-bit
#   ./generate-keys.sh --algorithm ES256              # ECDSA P-256
#   ./generate-keys.sh --algorithm RS512 --key-size 4096
#   ./generate-keys.sh --algorithm HS256 --output-dir /tmp/jwt-keys
##############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

ALGORITHM="RS256"
KEY_SIZE=2048
OUTPUT_DIR="./keys"
KID=""

usage() {
  sed -n '/^##*$/,/^##*$/{ /^##*$/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
}

err() {
  echo -e "${RED}ERROR: $*${RESET}" >&2
  exit 1
}

info() {
  echo -e "${GREEN}✓${RESET} $*"
}

# ── Parse Arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --algorithm)
      ALGORITHM="${2:-}"
      [[ -z "$ALGORITHM" ]] && err "--algorithm requires a value"
      shift 2
      ;;
    --key-size)
      KEY_SIZE="${2:-}"
      [[ -z "$KEY_SIZE" ]] && err "--key-size requires a value"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      [[ -z "$OUTPUT_DIR" ]] && err "--output-dir requires a value"
      shift 2
      ;;
    --kid)
      KID="${2:-}"
      [[ -z "$KID" ]] && err "--kid requires a value"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

# Normalize algorithm to uppercase
ALGORITHM="${ALGORITHM^^}"

# Validate algorithm
case "$ALGORITHM" in
  RS256|RS384|RS512|ES256|ES384|ES512|HS256) ;;
  *) err "Unsupported algorithm: $ALGORITHM. Supported: RS256, RS384, RS512, ES256, ES384, ES512, HS256" ;;
esac

# Validate key size for RSA
if [[ "$ALGORITHM" == RS* ]] && (( KEY_SIZE < 2048 )); then
  err "RSA key size must be at least 2048 bits (got ${KEY_SIZE}). Keys smaller than 2048 are insecure."
fi

# Check for openssl
if ! command -v openssl &>/dev/null; then
  err "openssl is required but not found in PATH."
fi

# Generate KID if not provided
if [[ -z "$KID" ]]; then
  KID="$(openssl rand -hex 8)"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║       JWT Key Pair Generator             ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Algorithm:  ${BOLD}${ALGORITHM}${RESET}"
echo -e "  Output dir: ${BOLD}${OUTPUT_DIR}${RESET}"
echo -e "  Key ID:     ${BOLD}${KID}${RESET}"
echo ""

# Base64url encode helper (no padding)
base64url_encode() {
  openssl base64 -A | tr '+' '-' | tr '/' '_' | tr -d '='
}

# ── RSA Key Generation ───────────────────────────────────────────────────────

generate_rsa() {
  local priv_key="$OUTPUT_DIR/private.pem"
  local pub_key="$OUTPUT_DIR/public.pem"
  local jwks_file="$OUTPUT_DIR/jwks.json"

  echo -e "  Key size:   ${BOLD}${KEY_SIZE} bits${RESET}"
  echo ""

  # Generate private key
  openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${KEY_SIZE}" \
    -out "$priv_key" 2>/dev/null
  chmod 600 "$priv_key"
  info "Private key: ${priv_key}"

  # Extract public key
  openssl rsa -in "$priv_key" -pubout -out "$pub_key" 2>/dev/null
  chmod 644 "$pub_key"
  info "Public key:  ${pub_key}"

  # Extract modulus and exponent for JWKS
  local n e
  n="$(openssl rsa -in "$priv_key" -modulus -noout 2>/dev/null \
    | sed 's/Modulus=//' \
    | xxd -r -p \
    | base64url_encode)"
  e="$(printf '%06x' "$(openssl rsa -in "$priv_key" -text -noout 2>/dev/null \
    | grep -A1 'publicExponent' \
    | head -1 \
    | grep -oP '\(0x[0-9a-fA-F]+\)' \
    | tr -d '()' \
    | sed 's/0x//')" \
    | xxd -r -p \
    | base64url_encode)"

  # Write JWKS
  cat > "$jwks_file" <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "use": "sig",
      "alg": "${ALGORITHM}",
      "kid": "${KID}",
      "n": "${n}",
      "e": "${e}"
    }
  ]
}
EOF
  chmod 644 "$jwks_file"
  info "JWKS:        ${jwks_file}"
}

# ── ECDSA Key Generation ────────────────────────────────────────────────────

generate_ecdsa() {
  local priv_key="$OUTPUT_DIR/ec-private.pem"
  local pub_key="$OUTPUT_DIR/ec-public.pem"
  local jwks_file="$OUTPUT_DIR/jwks.json"
  local curve crv coord_size

  case "$ALGORITHM" in
    ES256) curve="prime256v1"; crv="P-256"; coord_size=32 ;;
    ES384) curve="secp384r1";  crv="P-384"; coord_size=48 ;;
    ES512) curve="secp521r1";  crv="P-521"; coord_size=66 ;;
  esac

  echo -e "  Curve:      ${BOLD}${crv} (${curve})${RESET}"
  echo ""

  # Generate private key
  openssl ecparam -genkey -name "$curve" -noout -out "$priv_key" 2>/dev/null
  chmod 600 "$priv_key"
  info "Private key: ${priv_key}"

  # Extract public key
  openssl ec -in "$priv_key" -pubout -out "$pub_key" 2>/dev/null
  chmod 644 "$pub_key"
  info "Public key:  ${pub_key}"

  # Extract x and y coordinates for JWKS using python
  local x_b64 y_b64
  if command -v python3 &>/dev/null; then
    read -r x_b64 y_b64 < <(python3 -c "
import subprocess, base64, struct

pub_hex = subprocess.check_output(
    ['openssl', 'ec', '-in', '${priv_key}', '-text', '-noout'],
    stderr=subprocess.DEVNULL
).decode()

# Extract the public key hex bytes
import re
lines = pub_hex.split('pub:')[1].split('ASN1')[0] if 'ASN1' in pub_hex else pub_hex.split('pub:')[1]
hex_str = re.sub(r'[\s:]', '', lines).strip()
# Remove leading 04 (uncompressed point indicator)
if hex_str.startswith('04'):
    hex_str = hex_str[2:]
coord_len = ${coord_size}
x_bytes = bytes.fromhex(hex_str[:coord_len*2])
y_bytes = bytes.fromhex(hex_str[coord_len*2:coord_len*4])

def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()

print(b64url(x_bytes), b64url(y_bytes))
" 2>/dev/null)
  else
    x_b64="(python3 required for coordinate extraction)"
    y_b64=""
  fi

  # Write JWKS
  cat > "$jwks_file" <<EOF
{
  "keys": [
    {
      "kty": "EC",
      "use": "sig",
      "alg": "${ALGORITHM}",
      "kid": "${KID}",
      "crv": "${crv}",
      "x": "${x_b64}",
      "y": "${y_b64}"
    }
  ]
}
EOF
  chmod 644 "$jwks_file"
  info "JWKS:        ${jwks_file}"
}

# ── HMAC Secret Generation ──────────────────────────────────────────────────

generate_hmac() {
  local secret_file="$OUTPUT_DIR/hmac-secret.txt"
  local jwks_file="$OUTPUT_DIR/jwks.json"
  local secret_length

  case "$ALGORITHM" in
    HS256) secret_length=32 ;;  # 256 bits
    HS384) secret_length=48 ;;  # 384 bits
    HS512) secret_length=64 ;;  # 512 bits
    *)     secret_length=32 ;;
  esac

  echo -e "  Secret len: ${BOLD}${secret_length} bytes ($(( secret_length * 8 )) bits)${RESET}"
  echo ""

  # Generate random secret
  local secret
  secret="$(openssl rand -base64 "$secret_length")"

  # Write secret file
  echo -n "$secret" > "$secret_file"
  chmod 600 "$secret_file"
  info "Secret:      ${secret_file}"

  cat > "$jwks_file" <<EOF
{
  "keys": [
    {
      "kty": "oct",
      "use": "sig",
      "alg": "${ALGORITHM}",
      "kid": "${KID}",
      "k": "$(echo -n "$secret" | base64url_encode)"
    }
  ]
}
EOF
  chmod 644 "$jwks_file"
  info "JWKS:        ${jwks_file}"

  echo ""
  echo -e "  ${YELLOW}⚠  Keep the secret safe! Do not commit to source control.${RESET}"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$ALGORITHM" in
  RS*) generate_rsa ;;
  ES*) generate_ecdsa ;;
  HS*) generate_hmac ;;
esac

echo ""
echo -e "${GREEN}${BOLD}Key generation complete.${RESET}"
echo ""
echo -e "${YELLOW}Security reminders:${RESET}"
echo -e "  • Private keys should have 600 permissions (owner read/write only)"
echo -e "  • Never commit private keys or HMAC secrets to version control"
echo -e "  • Add key files to .gitignore"
echo -e "  • Rotate keys periodically"
echo ""
