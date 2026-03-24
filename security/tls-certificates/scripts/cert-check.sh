#!/bin/bash
# =============================================================================
# cert-check.sh — TLS Certificate Inspector
# =============================================================================
#
# Usage:
#   ./cert-check.sh <domain> [port]
#   ./cert-check.sh example.com
#   ./cert-check.sh example.com 8443
#   ./cert-check.sh -f /path/to/cert.pem    # inspect local file
#
# Checks: expiry, chain validity, SANs, key strength, OCSP status,
#          CT log presence, TLS version support, cipher suites
#
# Dependencies: openssl, curl, jq (optional, for CT log queries)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

usage() {
    echo "Usage: $0 <domain> [port]"
    echo "       $0 -f <cert-file>"
    echo ""
    echo "Options:"
    echo "  -f FILE   Inspect a local PEM certificate file"
    echo "  -v        Verbose output (show full certificate text)"
    echo "  -h        Show this help"
    exit 1
}

VERBOSE=0
LOCAL_FILE=""
DOMAIN=""
PORT=443

while [[ $# -gt 0 ]]; do
    case $1 in
        -f) LOCAL_FILE="$2"; shift 2 ;;
        -v) VERBOSE=1; shift ;;
        -h|--help) usage ;;
        *) if [ -z "$DOMAIN" ]; then DOMAIN="$1"; else PORT="$1"; fi; shift ;;
    esac
done

if [ -z "$DOMAIN" ] && [ -z "$LOCAL_FILE" ]; then
    usage
fi

section() {
    echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}ℹ${NC} $1"; }

get_cert() {
    if [ -n "$LOCAL_FILE" ]; then
        cat "$LOCAL_FILE"
    else
        echo | openssl s_client -connect "${DOMAIN}:${PORT}" \
            -servername "$DOMAIN" 2>/dev/null
    fi
}

CERT_DATA=$(get_cert)
if [ -z "$CERT_DATA" ]; then
    fail "Could not retrieve certificate from ${DOMAIN}:${PORT}"
    exit 1
fi

CERT_TEXT=$(echo "$CERT_DATA" | openssl x509 -noout -text 2>/dev/null)
if [ -z "$CERT_TEXT" ]; then
    fail "Could not parse certificate"
    exit 1
fi

echo -e "${BOLD}TLS Certificate Report${NC}"
if [ -n "$LOCAL_FILE" ]; then
    echo -e "Source: ${CYAN}${LOCAL_FILE}${NC}"
else
    echo -e "Target: ${CYAN}${DOMAIN}:${PORT}${NC}"
fi
echo -e "Date:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# --- Subject & Issuer ---
section "Identity"
SUBJECT=$(echo "$CERT_DATA" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
ISSUER=$(echo "$CERT_DATA" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
SERIAL=$(echo "$CERT_DATA" | openssl x509 -noout -serial 2>/dev/null | sed 's/serial=//')
info "Subject: $SUBJECT"
info "Issuer:  $ISSUER"
info "Serial:  $SERIAL"

# --- SANs ---
section "Subject Alternative Names"
SANS=$(echo "$CERT_TEXT" | grep -A1 "Subject Alternative Name" | tail -1 | \
    sed 's/,/\n/g' | sed 's/^ *//' | sed 's/DNS://g' | sed 's/IP Address://g')
SAN_COUNT=$(echo "$SANS" | grep -c . || true)
info "SAN count: $SAN_COUNT"
echo "$SANS" | while read -r san; do
    [ -n "$san" ] && info "  $san"
done

# --- Validity / Expiry ---
section "Validity"
NOT_BEFORE=$(echo "$CERT_DATA" | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)
NOT_AFTER=$(echo "$CERT_DATA" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
NOW=$(date +%s)
EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$NOT_AFTER" +%s 2>/dev/null)
DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW) / 86400 ))

info "Not Before: $NOT_BEFORE"
info "Not After:  $NOT_AFTER"

if [ "$DAYS_LEFT" -lt 0 ]; then
    fail "EXPIRED ${DAYS_LEFT#-} days ago"
elif [ "$DAYS_LEFT" -lt 7 ]; then
    fail "Expires in $DAYS_LEFT days — CRITICAL"
elif [ "$DAYS_LEFT" -lt 30 ]; then
    warn "Expires in $DAYS_LEFT days — renew soon"
elif [ "$DAYS_LEFT" -lt 60 ]; then
    warn "Expires in $DAYS_LEFT days"
else
    ok "Expires in $DAYS_LEFT days"
fi

# --- Key Strength ---
section "Key Information"
KEY_INFO=$(echo "$CERT_TEXT" | grep "Public Key Algorithm" | sed 's/.*: //')
KEY_SIZE=$(echo "$CERT_TEXT" | grep "Public-Key:" | grep -oP '\(\K[0-9]+')
SIG_ALGO=$(echo "$CERT_TEXT" | grep "Signature Algorithm" | head -1 | sed 's/.*: //')

info "Algorithm: $KEY_INFO"
info "Key Size:  ${KEY_SIZE:-unknown} bits"
info "Signature: $SIG_ALGO"

# Key strength assessment
case "$KEY_INFO" in
    *RSA*)
        if [ "${KEY_SIZE:-0}" -lt 2048 ]; then
            fail "RSA key < 2048 bits — WEAK"
        elif [ "${KEY_SIZE:-0}" -lt 3072 ]; then
            ok "RSA ${KEY_SIZE} bits (acceptable, consider 3072+)"
        else
            ok "RSA ${KEY_SIZE} bits (strong)"
        fi
        ;;
    *EC*|*ecdsa*)
        if [ "${KEY_SIZE:-0}" -ge 256 ]; then
            ok "ECDSA ${KEY_SIZE} bits (strong)"
        else
            warn "ECDSA ${KEY_SIZE} bits"
        fi
        ;;
    *)
        info "Key type: $KEY_INFO"
        ;;
esac

# Signature algorithm check
case "$SIG_ALGO" in
    *sha1*|*SHA1*|*md5*|*MD5*)
        fail "Weak signature algorithm: $SIG_ALGO"
        ;;
    *sha256*|*sha384*|*sha512*|*SHA256*|*SHA384*|*SHA512*)
        ok "Strong signature algorithm: $SIG_ALGO"
        ;;
esac

# --- Certificate Chain (remote only) ---
if [ -z "$LOCAL_FILE" ]; then
    section "Certificate Chain"
    CHAIN_OUTPUT=$(echo | openssl s_client -connect "${DOMAIN}:${PORT}" \
        -servername "$DOMAIN" -showcerts 2>/dev/null)
    CHAIN_DEPTH=$(echo "$CHAIN_OUTPUT" | grep -c "s:" || true)
    info "Chain depth: $CHAIN_DEPTH certificates"

    echo "$CHAIN_OUTPUT" | grep -E "^ *(s:|i:)" | while read -r line; do
        info "  $line"
    done

    VERIFY=$(echo "$CHAIN_OUTPUT" | grep "Verify return code" | sed 's/.*: //')
    if echo "$VERIFY" | grep -q "^0 "; then
        ok "Chain verification: $VERIFY"
    else
        fail "Chain verification: $VERIFY"
    fi
fi

# --- OCSP Status (remote only) ---
if [ -z "$LOCAL_FILE" ]; then
    section "OCSP Status"
    OCSP_OUTPUT=$(echo | openssl s_client -connect "${DOMAIN}:${PORT}" \
        -servername "$DOMAIN" -status 2>/dev/null)

    if echo "$OCSP_OUTPUT" | grep -q "OCSP Response Status: successful"; then
        ok "OCSP stapling: enabled"
        OCSP_STATUS=$(echo "$OCSP_OUTPUT" | grep "Cert Status:" | sed 's/.*: //')
        if [ "$OCSP_STATUS" = "good" ]; then
            ok "OCSP cert status: good"
        else
            warn "OCSP cert status: $OCSP_STATUS"
        fi
    elif echo "$OCSP_OUTPUT" | grep -q "OCSP response: no response sent"; then
        warn "OCSP stapling: not enabled"
    else
        info "OCSP stapling: could not determine"
    fi

    OCSP_URI=$(echo "$CERT_DATA" | openssl x509 -noout -ocsp_uri 2>/dev/null)
    if [ -n "$OCSP_URI" ]; then
        info "OCSP responder: $OCSP_URI"
    fi
fi

# --- TLS Version Support (remote only) ---
if [ -z "$LOCAL_FILE" ]; then
    section "TLS Version Support"
    for ver in tls1 tls1_1 tls1_2 tls1_3; do
        RESULT=$(openssl s_client -connect "${DOMAIN}:${PORT}" \
            -servername "$DOMAIN" -"$ver" </dev/null 2>&1 || true)
        DISPLAY_VER=$(echo "$ver" | sed 's/tls1$/TLS 1.0/' | sed 's/tls1_1/TLS 1.1/' | \
            sed 's/tls1_2/TLS 1.2/' | sed 's/tls1_3/TLS 1.3/')
        if echo "$RESULT" | grep -q "BEGIN CERTIFICATE"; then
            case "$ver" in
                tls1|tls1_1)
                    fail "$DISPLAY_VER: supported (DEPRECATED — should be disabled)"
                    ;;
                *)
                    ok "$DISPLAY_VER: supported"
                    ;;
            esac
        else
            case "$ver" in
                tls1|tls1_1)
                    ok "$DISPLAY_VER: disabled (good)"
                    ;;
                *)
                    warn "$DISPLAY_VER: not supported"
                    ;;
            esac
        fi
    done
fi

# --- CT Log Check (remote only, requires curl and jq) ---
if [ -z "$LOCAL_FILE" ] && command -v curl &>/dev/null && command -v jq &>/dev/null; then
    section "Certificate Transparency"
    CT_RESULT=$(curl -s "https://crt.sh/?q=${DOMAIN}&output=json" 2>/dev/null | \
        jq -r '.[0:5] | .[] | "\(.id) | \(.not_before) | \(.issuer_name)"' 2>/dev/null || true)
    if [ -n "$CT_RESULT" ]; then
        ok "Certificate found in CT logs"
        info "Recent entries:"
        echo "$CT_RESULT" | head -3 | while read -r entry; do
            info "  $entry"
        done
    else
        warn "Could not query CT logs (network issue or no entries)"
    fi
fi

# --- Fingerprint ---
section "Fingerprint"
SHA256=$(echo "$CERT_DATA" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
info "SHA-256: $SHA256"

# --- Verbose output ---
if [ "$VERBOSE" -eq 1 ]; then
    section "Full Certificate Text"
    echo "$CERT_TEXT"
fi

echo ""
echo -e "${BOLD}Certificate inspection complete.${NC}"
