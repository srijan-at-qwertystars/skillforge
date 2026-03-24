#!/bin/bash
# =============================================================================
# Certbot deploy hook for Apache
# =============================================================================
# Place in: /etc/letsencrypt/renewal-hooks/deploy/apache.sh
# Or use:   certbot renew --deploy-hook /path/to/this/script
#
# Runs after successful certificate renewal to reload Apache.
# Available env vars: RENEWED_LINEAGE, RENEWED_DOMAINS
# =============================================================================

set -euo pipefail

LOG_TAG="certbot-deploy-apache"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Certificate renewed for: ${RENEWED_DOMAINS:-unknown}"
log "Certificate path: ${RENEWED_LINEAGE:-unknown}"

# Detect apache service name (apache2 on Debian, httpd on RHEL)
if systemctl is-active --quiet apache2 2>/dev/null; then
    APACHE_SVC="apache2"
elif systemctl is-active --quiet httpd 2>/dev/null; then
    APACHE_SVC="httpd"
else
    log "ERROR: Neither apache2 nor httpd service found running"
    exit 1
fi

# Test Apache configuration
if "$APACHE_SVC"ctl configtest 2>/dev/null || apachectl configtest 2>/dev/null; then
    log "Apache config test passed"
else
    log "ERROR: Apache config test failed — skipping reload"
    exit 1
fi

# Graceful reload (no dropped connections)
if systemctl reload "$APACHE_SVC"; then
    log "Apache ($APACHE_SVC) reloaded successfully"
else
    log "ERROR: Apache reload failed"
    exit 1
fi

log "Deploy hook completed"
