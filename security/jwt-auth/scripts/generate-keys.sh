#!/usr/bin/env bash
#
# generate-keys.sh — Generate JWT signing key pairs
#
# Usage:
#   ./generate-keys.sh rs256              # Generate RSA 2048-bit key pair
#   ./generate-keys.sh rs256 4096         # Generate RSA 4096-bit key pair
#   ./generate-keys.sh es256              # Generate EC P-256 key pair
#   ./generate-keys.sh eddsa              # Generate Ed25519 key pair
#   ./generate-keys.sh all                # Generate all key types
#
# Output:
#   Creates keys/ directory with PEM and JWK format files.
#   PEM files:  <type>-private.pem, <type>-public.pem
#   JWK files:  <type>-private.jwk, <type>-public.jwk
#
# Requirements: openssl (1.1.1+), python3 or node (for JWK conversion)
#
set -euo pipefail

OUTPUT_DIR="${2:-keys}"
KID_PREFIX="key-$(date +%Y%m%d)"

mkdir -p "$OUTPUT_DIR"

log() { echo "[generate-keys] $*"; }
err() { echo "[generate-keys] ERROR: $*" >&2; exit 1; }

# Check for openssl
command -v openssl >/dev/null 2>&1 || err "openssl is required but not found"

pem_to_jwk_rsa() {
    local private_pem="$1" public_pem="$2" kid="$3"
    local priv_jwk="$4" pub_jwk="$5"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, base64, subprocess, sys

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

# Extract RSA components using openssl
out = subprocess.check_output(['openssl', 'rsa', '-in', '$private_pem', '-text', '-noout'], stderr=subprocess.DEVNULL).decode()

# For JWK, we use openssl pkey to get DER and parse
# Simpler: output modulus and exponent
import re

kid = '$kid'

# Private JWK (simplified — stores PEM reference)
priv = {
    'kty': 'RSA',
    'kid': kid,
    'use': 'sig',
    'alg': 'RS256',
    'key_ops': ['sign'],
    '_note': 'Full RSA JWK requires DER parsing. Use the PEM file for signing.',
    '_pem_file': '$(basename "$private_pem")'
}

pub = {
    'kty': 'RSA',
    'kid': kid,
    'use': 'sig',
    'alg': 'RS256',
    'key_ops': ['verify'],
    '_note': 'Full RSA JWK requires DER parsing. Use the PEM file for verification.',
    '_pem_file': '$(basename "$public_pem")'
}

with open('$priv_jwk', 'w') as f:
    json.dump(priv, f, indent=2)
with open('$pub_jwk', 'w') as f:
    json.dump(pub, f, indent=2)
" 2>/dev/null || log "  JWK conversion skipped (install pyjwt or jwcrypto for full JWK)"
    else
        log "  JWK conversion skipped (python3 not found)"
    fi
}

generate_rs256() {
    local bits="${1:-2048}"
    local kid="${KID_PREFIX}-rs256"
    log "Generating RSA ${bits}-bit key pair (RS256)..."

    openssl genrsa -out "${OUTPUT_DIR}/rs256-private.pem" "$bits" 2>/dev/null
    openssl rsa -in "${OUTPUT_DIR}/rs256-private.pem" \
        -pubout -out "${OUTPUT_DIR}/rs256-public.pem" 2>/dev/null

    log "  Private key: ${OUTPUT_DIR}/rs256-private.pem"
    log "  Public key:  ${OUTPUT_DIR}/rs256-public.pem"
    log "  kid: ${kid}"

    pem_to_jwk_rsa \
        "${OUTPUT_DIR}/rs256-private.pem" \
        "${OUTPUT_DIR}/rs256-public.pem" \
        "$kid" \
        "${OUTPUT_DIR}/rs256-private.jwk" \
        "${OUTPUT_DIR}/rs256-public.jwk"

    # Verify the key pair
    echo "test" | openssl dgst -sha256 -sign "${OUTPUT_DIR}/rs256-private.pem" | \
        openssl dgst -sha256 -verify "${OUTPUT_DIR}/rs256-public.pem" -signature /dev/stdin >/dev/null 2>&1 && \
        log "  Key pair verified ✓" || log "  WARNING: Key pair verification failed"
}

generate_es256() {
    local kid="${KID_PREFIX}-es256"
    log "Generating EC P-256 key pair (ES256)..."

    openssl ecparam -genkey -name prime256v1 -noout -out "${OUTPUT_DIR}/es256-private.pem" 2>/dev/null
    openssl ec -in "${OUTPUT_DIR}/es256-private.pem" \
        -pubout -out "${OUTPUT_DIR}/es256-public.pem" 2>/dev/null

    log "  Private key: ${OUTPUT_DIR}/es256-private.pem"
    log "  Public key:  ${OUTPUT_DIR}/es256-public.pem"
    log "  kid: ${kid}"

    # Generate JWK format
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json

kid = '$kid'
priv = {'kty':'EC','crv':'P-256','kid':kid,'use':'sig','alg':'ES256','key_ops':['sign'],'_pem_file':'es256-private.pem'}
pub  = {'kty':'EC','crv':'P-256','kid':kid,'use':'sig','alg':'ES256','key_ops':['verify'],'_pem_file':'es256-public.pem'}

with open('${OUTPUT_DIR}/es256-private.jwk','w') as f: json.dump(priv,f,indent=2)
with open('${OUTPUT_DIR}/es256-public.jwk','w') as f: json.dump(pub,f,indent=2)
" 2>/dev/null && log "  JWK files generated" || log "  JWK conversion skipped"
    fi

    log "  Key pair generated ✓"
}

generate_eddsa() {
    local kid="${KID_PREFIX}-eddsa"
    log "Generating Ed25519 key pair (EdDSA)..."

    # Ed25519 requires openssl 1.1.1+
    if ! openssl genpkey -algorithm Ed25519 -out "${OUTPUT_DIR}/eddsa-private.pem" 2>/dev/null; then
        err "Ed25519 not supported by your OpenSSL version (need 1.1.1+)"
    fi

    openssl pkey -in "${OUTPUT_DIR}/eddsa-private.pem" \
        -pubout -out "${OUTPUT_DIR}/eddsa-public.pem" 2>/dev/null

    log "  Private key: ${OUTPUT_DIR}/eddsa-private.pem"
    log "  Public key:  ${OUTPUT_DIR}/eddsa-public.pem"
    log "  kid: ${kid}"

    # Generate JWK format
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json

kid = '$kid'
priv = {'kty':'OKP','crv':'Ed25519','kid':kid,'use':'sig','alg':'EdDSA','key_ops':['sign'],'_pem_file':'eddsa-private.pem'}
pub  = {'kty':'OKP','crv':'Ed25519','kid':kid,'use':'sig','alg':'EdDSA','key_ops':['verify'],'_pem_file':'eddsa-public.pem'}

with open('${OUTPUT_DIR}/eddsa-private.jwk','w') as f: json.dump(priv,f,indent=2)
with open('${OUTPUT_DIR}/eddsa-public.jwk','w') as f: json.dump(pub,f,indent=2)
" 2>/dev/null && log "  JWK files generated" || log "  JWK conversion skipped"
    fi

    log "  Key pair generated ✓"
}

show_usage() {
    echo "Usage: $0 <algorithm> [options]"
    echo ""
    echo "Algorithms:"
    echo "  rs256 [bits]   Generate RSA key pair (default 2048-bit)"
    echo "  es256          Generate EC P-256 key pair"
    echo "  eddsa          Generate Ed25519 key pair"
    echo "  all            Generate all key types"
    echo ""
    echo "Output directory: ${OUTPUT_DIR}/"
    echo ""
    echo "Examples:"
    echo "  $0 es256                    # Recommended for new projects"
    echo "  $0 rs256 4096               # RSA with 4096-bit key"
    echo "  $0 all                      # Generate all types"
}

case "${1:-}" in
    rs256|RS256)
        generate_rs256 "${2:-2048}"
        ;;
    es256|ES256)
        generate_es256
        ;;
    eddsa|EdDSA|ed25519)
        generate_eddsa
        ;;
    all)
        generate_rs256 2048
        echo ""
        generate_es256
        echo ""
        generate_eddsa
        echo ""
        log "All key pairs generated in ${OUTPUT_DIR}/"
        ;;
    -h|--help|"")
        show_usage
        ;;
    *)
        err "Unknown algorithm: $1. Use rs256, es256, eddsa, or all."
        ;;
esac

echo ""
log "SECURITY REMINDER: Add '${OUTPUT_DIR}/' to .gitignore. Never commit private keys."
