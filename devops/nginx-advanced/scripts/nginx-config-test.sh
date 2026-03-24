#!/usr/bin/env bash
# nginx-config-test.sh — Test nginx configuration and check for common misconfigurations
#
# Usage:
#   ./nginx-config-test.sh [--config /path/to/nginx.conf] [--fix-suggestions] [--verbose]
#
# Options:
#   --config          Path to nginx config file (default: auto-detect)
#   --fix-suggestions Show fix suggestions for each issue found
#   --verbose         Show all checks, not just failures
#   --json            Output results as JSON
#
# Examples:
#   ./nginx-config-test.sh
#   ./nginx-config-test.sh --config /etc/nginx/nginx.conf --fix-suggestions
#   ./nginx-config-test.sh --verbose

set -euo pipefail

CONFIG_FILE=""
FIX_SUGGESTIONS=false
VERBOSE=false
JSON_OUTPUT=false
PASS=0
WARN=0
FAIL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)          CONFIG_FILE="$2";    shift 2 ;;
        --fix-suggestions) FIX_SUGGESTIONS=true; shift ;;
        --verbose)         VERBOSE=true;         shift ;;
        --json)            JSON_OUTPUT=true;     shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() {
    PASS=$((PASS + 1))
    if $VERBOSE; then
        echo -e "  ${GREEN}✓ PASS${NC}: $1"
    fi
}

warn() {
    WARN=$((WARN + 1))
    echo -e "  ${YELLOW}⚠ WARN${NC}: $1"
    if $FIX_SUGGESTIONS && [[ -n "${2:-}" ]]; then
        echo -e "    ${BLUE}Fix${NC}: $2"
    fi
}

fail() {
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗ FAIL${NC}: $1"
    if $FIX_SUGGESTIONS && [[ -n "${2:-}" ]]; then
        echo -e "    ${BLUE}Fix${NC}: $2"
    fi
}

info() {
    echo -e "  ${BLUE}ℹ INFO${NC}: $1"
}

# Auto-detect nginx and config
NGINX_BIN=$(command -v nginx 2>/dev/null || echo "")
if [[ -z "$NGINX_BIN" ]]; then
    echo -e "${RED}Error: nginx not found in PATH${NC}"
    echo "Install nginx or ensure it's in your PATH"
    exit 1
fi

if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE=$($NGINX_BIN -t 2>&1 | grep -oP 'configuration file \K[^ ]+' | head -1 || echo "/etc/nginx/nginx.conf")
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

NGINX_VERSION=$($NGINX_BIN -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
CONFIG_DIR=$(dirname "$CONFIG_FILE")

echo "=========================================="
echo " Nginx Configuration Checker"
echo "=========================================="
echo " Nginx version: $NGINX_VERSION"
echo " Config file:   $CONFIG_FILE"
echo " Config dir:    $CONFIG_DIR"
echo "=========================================="
echo ""

# Gather full config (with includes resolved)
FULL_CONFIG=$($NGINX_BIN -T 2>/dev/null || cat "$CONFIG_FILE")

# ── 1. Syntax Check ──
echo "[1/9] Syntax Validation"
if $NGINX_BIN -t 2>&1 | grep -q "syntax is ok"; then
    pass "nginx configuration syntax is valid"
else
    fail "nginx configuration has syntax errors" "Run: nginx -t"
    $NGINX_BIN -t 2>&1 | tail -5
fi
echo ""

# ── 2. Security Checks ──
echo "[2/9] Security"

if echo "$FULL_CONFIG" | grep -qP '^\s*server_tokens\s+off'; then
    pass "server_tokens is off"
else
    warn "server_tokens is not explicitly set to off" "Add 'server_tokens off;' in http block"
fi

if echo "$FULL_CONFIG" | grep -qP 'ssl_protocols.*TLSv1[^.]'; then
    fail "TLS 1.0 or 1.1 is enabled (insecure)" "Use: ssl_protocols TLSv1.2 TLSv1.3;"
elif echo "$FULL_CONFIG" | grep -qP 'ssl_protocols.*SSLv'; then
    fail "SSLv2 or SSLv3 is enabled (insecure)" "Use: ssl_protocols TLSv1.2 TLSv1.3;"
elif echo "$FULL_CONFIG" | grep -qP 'ssl_protocols'; then
    pass "SSL protocols are secure"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*ssl_session_tickets\s+off'; then
    pass "SSL session tickets are disabled"
else
    if echo "$FULL_CONFIG" | grep -qP 'ssl_'; then
        warn "SSL session tickets not explicitly disabled" "Add: ssl_session_tickets off;"
    fi
fi

if echo "$FULL_CONFIG" | grep -qP 'Strict-Transport-Security'; then
    pass "HSTS header is set"
else
    if echo "$FULL_CONFIG" | grep -qP 'listen.*443.*ssl'; then
        warn "HSTS header not found" "Add: add_header Strict-Transport-Security \"max-age=63072000; includeSubDomains\" always;"
    fi
fi

if echo "$FULL_CONFIG" | grep -qP 'X-Frame-Options'; then
    pass "X-Frame-Options header is set"
else
    warn "X-Frame-Options header not set" "Add: add_header X-Frame-Options \"SAMEORIGIN\" always;"
fi

if echo "$FULL_CONFIG" | grep -qP 'X-Content-Type-Options'; then
    pass "X-Content-Type-Options header is set"
else
    warn "X-Content-Type-Options header not set" "Add: add_header X-Content-Type-Options \"nosniff\" always;"
fi

if echo "$FULL_CONFIG" | grep -qP 'autoindex\s+on'; then
    fail "Directory autoindex is enabled" "Set: autoindex off;"
else
    pass "Directory autoindex is not enabled"
fi
echo ""

# ── 3. Performance Checks ──
echo "[3/9] Performance"

if echo "$FULL_CONFIG" | grep -qP '^\s*worker_processes\s+auto'; then
    pass "worker_processes set to auto"
elif echo "$FULL_CONFIG" | grep -qP '^\s*worker_processes\s+[0-9]+'; then
    WP=$(echo "$FULL_CONFIG" | grep -oP '^\s*worker_processes\s+\K[0-9]+' | head -1)
    CPU_COUNT=$(nproc 2>/dev/null || echo "unknown")
    if [[ "$CPU_COUNT" != "unknown" && "$WP" -lt "$CPU_COUNT" ]]; then
        warn "worker_processes ($WP) is less than CPU cores ($CPU_COUNT)" "Set: worker_processes auto;"
    else
        pass "worker_processes is set to $WP"
    fi
else
    warn "worker_processes not configured" "Add: worker_processes auto;"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*sendfile\s+on'; then
    pass "sendfile is enabled"
else
    warn "sendfile is not enabled" "Add: sendfile on;"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*gzip\s+on'; then
    pass "gzip compression is enabled"
else
    warn "gzip compression is not enabled" "Add: gzip on; with appropriate gzip_types"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*keepalive\s+\d+'; then
    pass "Upstream keepalive is configured"
else
    if echo "$FULL_CONFIG" | grep -qP 'upstream\s+\w+'; then
        warn "No upstream keepalive configured" "Add 'keepalive 32;' inside upstream blocks"
    fi
fi

if echo "$FULL_CONFIG" | grep -qP 'proxy_http_version\s+1\.1'; then
    pass "proxy_http_version 1.1 is set"
else
    if echo "$FULL_CONFIG" | grep -qP 'proxy_pass'; then
        warn "proxy_http_version not set to 1.1" "Add: proxy_http_version 1.1; for keepalive support"
    fi
fi
echo ""

# ── 4. SSL/TLS Checks ──
echo "[4/9] SSL/TLS"

if echo "$FULL_CONFIG" | grep -qP 'listen.*443.*ssl'; then
    if echo "$FULL_CONFIG" | grep -qP '^\s*ssl_stapling\s+on'; then
        pass "OCSP stapling is enabled"
    else
        warn "OCSP stapling not enabled" "Add: ssl_stapling on; ssl_stapling_verify on;"
    fi

    if echo "$FULL_CONFIG" | grep -qP '^\s*ssl_session_cache\s+shared'; then
        pass "SSL session cache is configured"
    else
        warn "SSL session cache not configured" "Add: ssl_session_cache shared:SSL:10m;"
    fi

    if echo "$FULL_CONFIG" | grep -qP '^\s*ssl_dhparam'; then
        pass "DH parameters file is configured"
    else
        if echo "$FULL_CONFIG" | grep -qP 'ssl_protocols.*TLSv1\.2'; then
            warn "DH parameters not configured (needed for DHE ciphers)" "Generate: openssl dhparam -out /etc/nginx/dhparam.pem 2048"
        fi
    fi

    # Check for HTTP to HTTPS redirect
    if echo "$FULL_CONFIG" | grep -qP 'listen\s+80\b' && echo "$FULL_CONFIG" | grep -qP 'return\s+301\s+https'; then
        pass "HTTP to HTTPS redirect is configured"
    else
        if echo "$FULL_CONFIG" | grep -qP 'listen\s+80\b'; then
            warn "No HTTP to HTTPS redirect found" "Add server block: listen 80; return 301 https://\$host\$request_uri;"
        fi
    fi
else
    info "No SSL/TLS listeners found — skipping SSL checks"
fi
echo ""

# ── 5. Proxy Configuration ──
echo "[5/9] Proxy Configuration"

if echo "$FULL_CONFIG" | grep -qP 'proxy_set_header\s+Host\s+\$host'; then
    pass "proxy_set_header Host is configured"
else
    if echo "$FULL_CONFIG" | grep -qP 'proxy_pass'; then
        warn "Host header not forwarded to upstream" "Add: proxy_set_header Host \$host;"
    fi
fi

if echo "$FULL_CONFIG" | grep -qP 'proxy_set_header\s+X-Real-IP'; then
    pass "X-Real-IP header is forwarded"
else
    if echo "$FULL_CONFIG" | grep -qP 'proxy_pass'; then
        warn "X-Real-IP not forwarded" "Add: proxy_set_header X-Real-IP \$remote_addr;"
    fi
fi

if echo "$FULL_CONFIG" | grep -qP 'proxy_set_header\s+X-Forwarded-For'; then
    pass "X-Forwarded-For header is forwarded"
else
    if echo "$FULL_CONFIG" | grep -qP 'proxy_pass'; then
        warn "X-Forwarded-For not forwarded" "Add: proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    fi
fi

if echo "$FULL_CONFIG" | grep -qP 'proxy_set_header\s+X-Forwarded-Proto'; then
    pass "X-Forwarded-Proto is forwarded"
else
    if echo "$FULL_CONFIG" | grep -qP 'proxy_pass'; then
        warn "X-Forwarded-Proto not forwarded" "Add: proxy_set_header X-Forwarded-Proto \$scheme;"
    fi
fi

# Check for trailing slash pitfall
if echo "$FULL_CONFIG" | grep -oP 'proxy_pass\s+https?://[^/\s]+/[^/\s;]*[^/;\s]' | grep -vP '[\$}]' | head -1 | grep -q .; then
    warn "proxy_pass URI may be missing trailing slash — can cause path concatenation issues" \
         "Ensure proxy_pass URIs end with / when stripping location prefix"
fi
echo ""

# ── 6. Logging ──
echo "[6/9] Logging"

if echo "$FULL_CONFIG" | grep -qP '^\s*access_log\s+'; then
    pass "Access logging is configured"
else
    warn "Access log not explicitly configured"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*error_log\s+'; then
    pass "Error logging is configured"
    if echo "$FULL_CONFIG" | grep -qP 'error_log.*\s+debug'; then
        warn "Debug-level error logging is enabled (high disk I/O)" "Set to 'warn' or 'error' in production"
    fi
else
    warn "Error log not explicitly configured"
fi
echo ""

# ── 7. Rate Limiting ──
echo "[7/9] Rate Limiting"

if echo "$FULL_CONFIG" | grep -qP '^\s*limit_req_zone'; then
    pass "Request rate limiting is configured"
else
    warn "No request rate limiting configured" "Add: limit_req_zone \$binary_remote_addr zone=general:10m rate=10r/s;"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*limit_conn_zone'; then
    pass "Connection limiting is configured"
else
    warn "No connection limiting configured" "Add: limit_conn_zone \$binary_remote_addr zone=addr:10m;"
fi
echo ""

# ── 8. Timeout Configuration ──
echo "[8/9] Timeouts"

if echo "$FULL_CONFIG" | grep -qP '^\s*client_body_timeout'; then
    pass "client_body_timeout is configured"
else
    warn "client_body_timeout not set (default 60s)" "Add: client_body_timeout 10s; to mitigate slowloris"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*client_header_timeout'; then
    pass "client_header_timeout is configured"
else
    warn "client_header_timeout not set (default 60s)" "Add: client_header_timeout 10s;"
fi

if echo "$FULL_CONFIG" | grep -qP '^\s*client_max_body_size'; then
    pass "client_max_body_size is configured"
else
    warn "client_max_body_size not set (default 1m)" "Set appropriate value: client_max_body_size 10m;"
fi
echo ""

# ── 9. File Permissions ──
echo "[9/9] File Permissions"

if [[ -r "$CONFIG_FILE" ]]; then
    PERMS=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    if [[ "$PERMS" != "unknown" ]]; then
        if [[ "$PERMS" =~ ^[67][0-4][04]$ ]]; then
            pass "Config file permissions are restrictive ($PERMS)"
        else
            warn "Config file permissions may be too open ($PERMS)" "chmod 644 $CONFIG_FILE"
        fi
    fi
fi

# Check for exposed .git or .env in served directories
if echo "$FULL_CONFIG" | grep -qP 'location.*\.(git|env|htpasswd|htaccess)'; then
    pass "Sensitive file locations are handled"
else
    warn "No explicit block for .git/.env/.htpasswd files" \
         "Add: location ~ /\\. { deny all; return 404; }"
fi
echo ""

# ── Summary ──
echo "=========================================="
echo " Results Summary"
echo "=========================================="
echo -e "  ${GREEN}Passed${NC}:   $PASS"
echo -e "  ${YELLOW}Warnings${NC}: $WARN"
echo -e "  ${RED}Failed${NC}:   $FAIL"
echo "=========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 2
elif [[ $WARN -gt 0 ]]; then
    exit 1
else
    exit 0
fi
