#!/bin/bash
# =============================================================================
# Certbot deploy hook for HAProxy
# =============================================================================
# Place in: /etc/letsencrypt/renewal-hooks/deploy/haproxy.sh
# Or use:   certbot renew --deploy-hook /path/to/this/script
#
# HAProxy requires a combined PEM file (cert + chain + key).
# This script concatenates the Let's Encrypt files and reloads HAProxy.
#
# Available env vars: RENEWED_LINEAGE, RENEWED_DOMAINS
# =============================================================================

set -euo pipefail

LOG_TAG="certbot-deploy-haproxy"
HAPROXY_CERT_DIR="/etc/haproxy/certs"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Certificate renewed for: ${RENEWED_DOMAINS:-unknown}"
log "Certificate path: ${RENEWED_LINEAGE:-unknown}"

if [ -z "${RENEWED_LINEAGE:-}" ]; then
    log "ERROR: RENEWED_LINEAGE not set"
    exit 1
fi

# Create HAProxy cert directory if it doesn't exist
mkdir -p "$HAPROXY_CERT_DIR"

# Extract domain name from lineage path
CERT_NAME=$(basename "$RENEWED_LINEAGE")

# HAProxy needs: fullchain + private key in a single PEM file
COMBINED="${HAPROXY_CERT_DIR}/${CERT_NAME}.pem"

cat "${RENEWED_LINEAGE}/fullchain.pem" \
    "${RENEWED_LINEAGE}/privkey.pem" > "$COMBINED"

chmod 600 "$COMBINED"
log "Combined PEM written to: $COMBINED"

# Test HAProxy configuration
if haproxy -c -f /etc/haproxy/haproxy.cfg 2>/dev/null; then
    log "HAProxy config test passed"
else
    log "ERROR: HAProxy config test failed — skipping reload"
    exit 1
fi

# Reload HAProxy
# Method 1: systemctl reload (graceful, HAProxy 2.x)
if systemctl reload haproxy 2>/dev/null; then
    log "HAProxy reloaded successfully"
# Method 2: runtime API for hitless reload (HAProxy 2.4+)
elif command -v socat &>/dev/null && [ -S /var/run/haproxy/admin.sock ]; then
    echo "set ssl cert ${COMBINED} <<\n$(cat "$COMBINED")\n" | \
        socat stdio /var/run/haproxy/admin.sock
    echo "commit ssl cert ${COMBINED}" | \
        socat stdio /var/run/haproxy/admin.sock
    log "HAProxy certificate updated via runtime API"
else
    log "WARNING: Could not reload HAProxy — manual restart may be needed"
    systemctl restart haproxy || true
fi

log "Deploy hook completed"
