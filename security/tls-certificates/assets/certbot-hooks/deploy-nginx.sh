#!/bin/bash
# =============================================================================
# Certbot deploy hook for Nginx
# =============================================================================
# Place in: /etc/letsencrypt/renewal-hooks/deploy/nginx.sh
# Or use:   certbot renew --deploy-hook /path/to/this/script
#
# Runs after successful certificate renewal to reload Nginx.
# Available env vars: RENEWED_LINEAGE, RENEWED_DOMAINS
# =============================================================================

set -euo pipefail

LOG_TAG="certbot-deploy-nginx"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Certificate renewed for: ${RENEWED_DOMAINS:-unknown}"
log "Certificate path: ${RENEWED_LINEAGE:-unknown}"

# Test nginx configuration before reloading
if nginx -t 2>/dev/null; then
    log "Nginx config test passed"
else
    log "ERROR: Nginx config test failed — skipping reload"
    exit 1
fi

# Reload nginx (graceful — no dropped connections)
if systemctl reload nginx; then
    log "Nginx reloaded successfully"
else
    log "ERROR: Nginx reload failed"
    exit 1
fi

# Optional: verify the new certificate is being served
if [ -n "${RENEWED_DOMAINS:-}" ]; then
    FIRST_DOMAIN=$(echo "$RENEWED_DOMAINS" | awk '{print $1}')
    sleep 2
    SERVED_EXPIRY=$(echo | timeout 5 openssl s_client \
        -connect "${FIRST_DOMAIN}:443" \
        -servername "$FIRST_DOMAIN" 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    if [ -n "$SERVED_EXPIRY" ]; then
        log "New certificate served, expires: $SERVED_EXPIRY"
    fi
fi

log "Deploy hook completed"
