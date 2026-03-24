#!/usr/bin/env bash
# nginx-config-test.sh — Comprehensive nginx configuration validator
#
# Usage:
#   ./nginx-config-test.sh                    # Test default nginx config
#   ./nginx-config-test.sh /etc/nginx         # Test specific config directory
#   ./nginx-config-test.sh --verbose          # Verbose output
#   ./nginx-config-test.sh --fix-suggestions  # Include fix suggestions
#
# Checks performed:
#   - Nginx config syntax validation
#   - SSL certificate validity and expiration
#   - Common security misconfigurations
#   - Performance settings review
#   - Common mistake detection
#   - File permission checks

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0
VERBOSE=false
FIX_SUGGESTIONS=false
NGINX_CONF_DIR="/etc/nginx"

pass()  { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { WARN=$((WARN + 1)); echo -e "  ${YELLOW}⚠${NC} $*"; }
fail()  { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $*"; }
info()  { echo -e "  ${BLUE}ℹ${NC} $*"; }
header(){ echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)          VERBOSE=true; shift ;;
        --fix-suggestions|-f)  FIX_SUGGESTIONS=true; shift ;;
        -h|--help)
            echo "Usage: $0 [nginx-conf-dir] [--verbose] [--fix-suggestions]"
            exit 0
            ;;
        -*)  echo "Unknown option: $1"; exit 1 ;;
        *)   NGINX_CONF_DIR="$1"; shift ;;
    esac
done

NGINX_CONF="${NGINX_CONF_DIR}/nginx.conf"

echo -e "${BLUE}Nginx Configuration Validator${NC}"
echo "Config directory: ${NGINX_CONF_DIR}"
echo ""

# ================================================================
header "1. Syntax Validation"
# ================================================================

if command -v nginx &>/dev/null; then
    if nginx -t 2>&1 | grep -q "syntax is ok"; then
        pass "Nginx config syntax is valid"
    else
        fail "Nginx config syntax errors detected"
        nginx -t 2>&1 | sed 's/^/    /'
    fi

    # Check for deprecated directives
    FULL_CONFIG=$(nginx -T 2>/dev/null || true)
    if [[ -n "$FULL_CONFIG" ]]; then
        if echo "$FULL_CONFIG" | grep -q "ssl on;"; then
            fail "'ssl on;' is deprecated — use 'listen 443 ssl;' instead"
        fi
        if echo "$FULL_CONFIG" | grep -q "listen.*spdy"; then
            fail "SPDY is deprecated — use HTTP/2 (listen ... http2)"
        fi
        pass "No deprecated directives found"
    fi
else
    warn "nginx binary not found — skipping syntax validation"
fi

# ================================================================
header "2. SSL Certificate Validation"
# ================================================================

check_cert() {
    local cert_file="$1"
    local domain="$2"

    if [[ ! -f "$cert_file" ]]; then
        fail "Certificate not found: $cert_file"
        return
    fi

    # Check expiration
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_left -le 0 ]]; then
        fail "Certificate EXPIRED: $cert_file (expired $expiry)"
    elif [[ $days_left -le 7 ]]; then
        fail "Certificate expires in $days_left days: $cert_file"
    elif [[ $days_left -le 30 ]]; then
        warn "Certificate expires in $days_left days: $cert_file"
    else
        pass "Certificate valid for $days_left days: $cert_file"
    fi

    # Check key strength
    local key_bits
    key_bits=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep "Public-Key:" | grep -oP '\d+')
    if [[ -n "$key_bits" ]]; then
        if [[ "$key_bits" -lt 2048 ]]; then
            fail "Weak key ($key_bits bit): $cert_file — use at least 2048-bit RSA or 256-bit EC"
        else
            pass "Key strength: $key_bits bit"
        fi
    fi
}

# Find all SSL certificates in config
if [[ -n "${FULL_CONFIG:-}" ]]; then
    while IFS= read -r cert_line; do
        cert_path=$(echo "$cert_line" | awk '{print $2}' | tr -d ';')
        if [[ -f "$cert_path" ]]; then
            check_cert "$cert_path" ""
        fi
    done < <(echo "$FULL_CONFIG" | grep -E "^\s*ssl_certificate\s" | grep -v "_key" | sort -u)
else
    # Fallback: search for cert files in common locations
    for cert_dir in /etc/letsencrypt/live /etc/ssl/certs /etc/nginx/ssl; do
        if [[ -d "$cert_dir" ]]; then
            find "$cert_dir" -name "*.pem" -o -name "*.crt" 2>/dev/null | while read -r cert; do
                check_cert "$cert" ""
            done
        fi
    done
fi

# Check cert/key matching
if [[ -n "${FULL_CONFIG:-}" ]]; then
    while IFS= read -r server_block; do
        cert=$(echo "$server_block" | grep -oP 'ssl_certificate\s+\K[^;]+' | head -1)
        key=$(echo "$server_block" | grep -oP 'ssl_certificate_key\s+\K[^;]+' | head -1)
        if [[ -n "$cert" ]] && [[ -n "$key" ]] && [[ -f "$cert" ]] && [[ -f "$key" ]]; then
            cert_md5=$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5)
            key_md5=$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5)
            if [[ "$cert_md5" == "$key_md5" ]]; then
                pass "Certificate and key match: $cert"
            else
                fail "Certificate and key MISMATCH: $cert vs $key"
            fi
        fi
    done < <(echo "$FULL_CONFIG" | awk '/server\s*\{/{p=1} p{print} /\}/{if(p) p=0}')
fi

# ================================================================
header "3. Security Configuration"
# ================================================================

if [[ -n "${FULL_CONFIG:-}" ]]; then
    # server_tokens
    if echo "$FULL_CONFIG" | grep -q "server_tokens off"; then
        pass "server_tokens off (version hidden)"
    else
        warn "server_tokens not disabled — Nginx version exposed"
        $FIX_SUGGESTIONS && info "Fix: Add 'server_tokens off;' to http block"
    fi

    # SSL protocols
    if echo "$FULL_CONFIG" | grep -qE "ssl_protocols.*TLSv1[^.]"; then
        fail "TLS 1.0 is enabled — insecure protocol"
        $FIX_SUGGESTIONS && info "Fix: ssl_protocols TLSv1.2 TLSv1.3;"
    elif echo "$FULL_CONFIG" | grep -qE "ssl_protocols.*TLSv1\.1"; then
        fail "TLS 1.1 is enabled — insecure protocol"
        $FIX_SUGGESTIONS && info "Fix: ssl_protocols TLSv1.2 TLSv1.3;"
    elif echo "$FULL_CONFIG" | grep -q "ssl_protocols"; then
        pass "Secure TLS protocols configured"
    fi

    # HSTS
    if echo "$FULL_CONFIG" | grep -qi "strict-transport-security"; then
        if echo "$FULL_CONFIG" | grep -qi "includesubdomains"; then
            pass "HSTS enabled with includeSubDomains"
        else
            warn "HSTS enabled but missing includeSubDomains"
        fi
    else
        warn "HSTS not configured"
        $FIX_SUGGESTIONS && info "Fix: add_header Strict-Transport-Security \"max-age=63072000; includeSubDomains; preload\" always;"
    fi

    # X-Frame-Options
    if echo "$FULL_CONFIG" | grep -qi "x-frame-options"; then
        pass "X-Frame-Options header set"
    else
        warn "X-Frame-Options header missing"
    fi

    # X-Content-Type-Options
    if echo "$FULL_CONFIG" | grep -qi "x-content-type-options"; then
        pass "X-Content-Type-Options header set"
    else
        warn "X-Content-Type-Options header missing"
    fi

    # Content-Security-Policy
    if echo "$FULL_CONFIG" | grep -qi "content-security-policy"; then
        pass "Content-Security-Policy header set"
    else
        warn "Content-Security-Policy header missing"
    fi

    # HTTP to HTTPS redirect
    if echo "$FULL_CONFIG" | grep -qE "listen\s+80" && echo "$FULL_CONFIG" | grep -qE "return\s+301\s+https"; then
        pass "HTTP → HTTPS redirect configured"
    elif echo "$FULL_CONFIG" | grep -qE "listen\s+80"; then
        warn "Port 80 listener found without HTTPS redirect"
    fi

    # Default server catch-all
    if echo "$FULL_CONFIG" | grep -q "default_server"; then
        pass "Default server (catch-all) configured"
    else
        warn "No default_server — unknown hostnames may hit a random server block"
    fi

    # Rate limiting
    if echo "$FULL_CONFIG" | grep -q "limit_req_zone"; then
        pass "Rate limiting configured"
    else
        warn "No rate limiting configured"
    fi

    # Dotfile access
    if echo "$FULL_CONFIG" | grep -qE 'location.*~/\\.'; then
        pass "Hidden files (dotfiles) access restricted"
    else
        warn "No explicit dotfile access restriction"
        $FIX_SUGGESTIONS && info "Fix: location ~ /\\. { deny all; }"
    fi
fi

# ================================================================
header "4. Performance Settings"
# ================================================================

if [[ -n "${FULL_CONFIG:-}" ]]; then
    # worker_processes
    CPU_CORES=$(nproc 2>/dev/null || echo "unknown")
    if echo "$FULL_CONFIG" | grep -q "worker_processes auto"; then
        pass "worker_processes auto (CPU cores: $CPU_CORES)"
    elif echo "$FULL_CONFIG" | grep -qP "worker_processes\s+\d+"; then
        WORKERS=$(echo "$FULL_CONFIG" | grep -oP "worker_processes\s+\K\d+")
        if [[ "$CPU_CORES" != "unknown" ]] && [[ "$WORKERS" -ne "$CPU_CORES" ]]; then
            warn "worker_processes=$WORKERS but CPU cores=$CPU_CORES (consider 'auto')"
        else
            pass "worker_processes=$WORKERS"
        fi
    fi

    # Gzip
    if echo "$FULL_CONFIG" | grep -q "gzip on"; then
        pass "Gzip compression enabled"
    else
        warn "Gzip compression not enabled"
    fi

    # Keepalive
    if echo "$FULL_CONFIG" | grep -q "keepalive_timeout"; then
        KEEPALIVE=$(echo "$FULL_CONFIG" | grep -oP "keepalive_timeout\s+\K\d+" | head -1)
        if [[ -n "$KEEPALIVE" ]] && [[ "$KEEPALIVE" -gt 65 ]]; then
            warn "keepalive_timeout=$KEEPALIVE is high (recommend 15-30s)"
        else
            pass "keepalive_timeout=$KEEPALIVE"
        fi
    fi

    # Sendfile
    if echo "$FULL_CONFIG" | grep -q "sendfile on"; then
        pass "sendfile enabled"
    else
        warn "sendfile not enabled (slower static file serving)"
    fi
fi

# ================================================================
header "5. Common Mistakes"
# ================================================================

if [[ -n "${FULL_CONFIG:-}" ]]; then
    # if inside location with proxy_pass (known antipattern)
    if echo "$FULL_CONFIG" | grep -B5 "proxy_pass" | grep -q "if ("; then
        warn "Found 'if' inside location with proxy_pass — 'if is evil' in Nginx"
        $FIX_SUGGESTIONS && info "Fix: Use 'map' directive for conditional logic instead"
    else
        pass "No 'if' inside proxy locations detected"
    fi

    # Missing proxy_http_version for websocket or keepalive
    if echo "$FULL_CONFIG" | grep -q "Upgrade" && ! echo "$FULL_CONFIG" | grep -q "proxy_http_version 1.1"; then
        warn "WebSocket upgrade headers found but proxy_http_version 1.1 not set"
    fi

    # worker_rlimit_nofile check
    if echo "$FULL_CONFIG" | grep -q "worker_rlimit_nofile"; then
        RLIMIT=$(echo "$FULL_CONFIG" | grep -oP "worker_rlimit_nofile\s+\K\d+")
        CONNECTIONS=$(echo "$FULL_CONFIG" | grep -oP "worker_connections\s+\K\d+" | head -1)
        if [[ -n "$RLIMIT" ]] && [[ -n "$CONNECTIONS" ]]; then
            if [[ "$RLIMIT" -lt $((CONNECTIONS * 2)) ]]; then
                warn "worker_rlimit_nofile ($RLIMIT) should be ≥ 2x worker_connections ($CONNECTIONS)"
            else
                pass "worker_rlimit_nofile ($RLIMIT) ≥ 2x worker_connections ($CONNECTIONS)"
            fi
        fi
    else
        warn "worker_rlimit_nofile not set — may hit file descriptor limits under load"
    fi

    # add_header in nested blocks (potential inheritance issue)
    HEADER_LOCATIONS=$(echo "$FULL_CONFIG" | grep -c "add_header" 2>/dev/null || echo 0)
    if [[ "$HEADER_LOCATIONS" -gt 0 ]]; then
        info "Found $HEADER_LOCATIONS add_header directives — verify headers aren't silently dropped in child blocks"
    fi
fi

# ================================================================
header "6. File Permissions"
# ================================================================

if [[ -d "$NGINX_CONF_DIR" ]]; then
    # Config directory permissions
    CONF_PERMS=$(stat -c "%a" "$NGINX_CONF_DIR" 2>/dev/null || echo "unknown")
    if [[ "$CONF_PERMS" == "755" ]] || [[ "$CONF_PERMS" == "750" ]]; then
        pass "Config directory permissions: $CONF_PERMS"
    else
        warn "Config directory permissions: $CONF_PERMS (recommended: 755 or 750)"
    fi

    # Check for world-readable private keys
    find "$NGINX_CONF_DIR" -name "*.key" -perm /o=r 2>/dev/null | while read -r key_file; do
        fail "Private key is world-readable: $key_file"
        $FIX_SUGGESTIONS && info "Fix: chmod 600 $key_file"
    done

    # Check SSL key permissions in letsencrypt
    if [[ -d /etc/letsencrypt ]]; then
        LE_PERMS=$(stat -c "%a" /etc/letsencrypt/archive 2>/dev/null || echo "unknown")
        if [[ "$LE_PERMS" == "700" ]] || [[ "$LE_PERMS" == "750" ]]; then
            pass "Let's Encrypt archive permissions: $LE_PERMS"
        elif [[ "$LE_PERMS" != "unknown" ]]; then
            warn "Let's Encrypt archive permissions: $LE_PERMS (recommended: 700)"
        fi
    fi
fi

# ================================================================
# Summary
# ================================================================

echo ""
echo -e "${BLUE}━━━ Summary ━━━${NC}"
echo -e "  ${GREEN}Passed: $PASS${NC}"
echo -e "  ${YELLOW}Warnings: $WARN${NC}"
echo -e "  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Configuration has $FAIL failure(s) that should be addressed.${NC}"
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo -e "${YELLOW}Configuration is functional but has $WARN warning(s).${NC}"
    exit 0
else
    echo -e "${GREEN}Configuration looks good!${NC}"
    exit 0
fi
