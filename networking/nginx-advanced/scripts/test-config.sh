#!/usr/bin/env bash
#
# test-config.sh — Validate nginx configuration and check for common issues
#
# Usage:
#   ./test-config.sh                    Run all checks
#   ./test-config.sh --syntax           Syntax check only (nginx -t)
#   ./test-config.sh --security         Security audit only
#   ./test-config.sh --ssl <domain>     SSL configuration test for a domain
#   ./test-config.sh --upstream         Test upstream connectivity
#   ./test-config.sh --full             Full dump of effective config (nginx -T)
#
# Examples:
#   ./test-config.sh
#   ./test-config.sh --ssl example.com
#   ./test-config.sh --upstream
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

pass() { ((PASS++)); echo -e "  ${GREEN}✓${NC} $*"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗${NC} $*"; }
section() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

NGINX_BIN=$(command -v nginx 2>/dev/null || echo "/usr/sbin/nginx")
NGINX_CONF=$("$NGINX_BIN" -t 2>&1 | grep -oP 'configuration file \K\S+' 2>/dev/null || echo "/etc/nginx/nginx.conf")

########################################
# Syntax Check
########################################
check_syntax() {
    section "Syntax Validation"

    if "$NGINX_BIN" -t 2>&1; then
        pass "nginx configuration syntax is valid"
    else
        fail "nginx configuration has syntax errors"
        "$NGINX_BIN" -t 2>&1 || true
        return 1
    fi
}

########################################
# Security Audit
########################################
check_security() {
    section "Security Audit"

    local config
    config=$("$NGINX_BIN" -T 2>/dev/null) || { fail "Cannot dump config"; return 1; }

    # server_tokens
    if echo "$config" | grep -q "server_tokens off"; then
        pass "server_tokens is off (version hidden)"
    else
        warn "server_tokens not explicitly disabled — nginx version exposed"
    fi

    # SSL protocols
    if echo "$config" | grep -qP "ssl_protocols.*TLSv1(\s|;)" && ! echo "$config" | grep -qP "ssl_protocols.*TLSv1\."; then
        fail "TLSv1.0 is enabled (insecure)"
    elif echo "$config" | grep -qP "ssl_protocols.*TLSv1\.1"; then
        warn "TLSv1.1 is enabled (deprecated)"
    fi

    if echo "$config" | grep -q "ssl_protocols.*TLSv1.2\|ssl_protocols.*TLSv1.3"; then
        pass "Modern TLS protocols configured"
    fi

    # HSTS
    if echo "$config" | grep -qi "Strict-Transport-Security"; then
        pass "HSTS header is configured"
        if echo "$config" | grep -qi "includeSubDomains"; then
            pass "HSTS includes subdomains"
        else
            warn "HSTS does not include subdomains"
        fi
    else
        warn "HSTS header not found"
    fi

    # X-Frame-Options
    if echo "$config" | grep -qi "X-Frame-Options"; then
        pass "X-Frame-Options header configured"
    else
        warn "X-Frame-Options header missing (clickjacking risk)"
    fi

    # X-Content-Type-Options
    if echo "$config" | grep -qi "X-Content-Type-Options"; then
        pass "X-Content-Type-Options header configured"
    else
        warn "X-Content-Type-Options header missing (MIME sniffing risk)"
    fi

    # Content-Security-Policy
    if echo "$config" | grep -qi "Content-Security-Policy"; then
        pass "Content-Security-Policy header configured"
    else
        warn "Content-Security-Policy header missing"
    fi

    # client_max_body_size
    if echo "$config" | grep -q "client_max_body_size"; then
        local size
        size=$(echo "$config" | grep -oP "client_max_body_size\s+\K[^;]+" | head -1)
        pass "client_max_body_size set to ${size}"
    else
        warn "client_max_body_size not set (default 1m may be too small or too large)"
    fi

    # Sensitive file blocking
    if echo "$config" | grep -qP "location.*\\\.(git|env|htaccess)"; then
        pass "Sensitive files (.git, .env, etc.) are blocked"
    else
        warn "No rules blocking access to .git, .env, .htaccess files"
    fi

    # Default server
    if echo "$config" | grep -q "default_server"; then
        pass "Default server block configured"
    else
        warn "No default_server — first server block handles unknown hosts"
    fi

    # SSL session tickets
    if echo "$config" | grep -q "ssl_session_tickets off"; then
        pass "SSL session tickets disabled (forward secrecy preserved)"
    fi

    # autoindex
    if echo "$config" | grep -q "autoindex on"; then
        fail "autoindex is enabled — directory listing exposed"
    else
        pass "autoindex is off (directory listing disabled)"
    fi
}

########################################
# SSL Check
########################################
check_ssl() {
    local domain="${1:?Domain required for SSL check}"

    section "SSL Check: ${domain}"

    if ! command -v openssl &>/dev/null; then
        fail "openssl not installed"
        return 1
    fi

    # Connection test
    local ssl_output
    if ssl_output=$(echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null); then
        pass "SSL connection successful"
    else
        fail "Cannot establish SSL connection to ${domain}:443"
        return 1
    fi

    # Protocol version
    local protocol
    protocol=$(echo "$ssl_output" | grep "Protocol" | awk '{print $NF}')
    if [[ "$protocol" == "TLSv1.3" ]]; then
        pass "Using TLS 1.3"
    elif [[ "$protocol" == "TLSv1.2" ]]; then
        pass "Using TLS 1.2"
    else
        warn "Using ${protocol:-unknown protocol}"
    fi

    # Certificate expiration
    local cert_dates
    cert_dates=$(echo "$ssl_output" | openssl x509 -noout -dates 2>/dev/null)
    if [[ -n "$cert_dates" ]]; then
        local expiry
        expiry=$(echo "$cert_dates" | grep "notAfter" | cut -d= -f2)
        local expiry_epoch now_epoch days_left
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [[ $days_left -lt 0 ]]; then
            fail "Certificate EXPIRED ${days_left#-} days ago"
        elif [[ $days_left -lt 14 ]]; then
            fail "Certificate expires in ${days_left} days (critical)"
        elif [[ $days_left -lt 30 ]]; then
            warn "Certificate expires in ${days_left} days"
        else
            pass "Certificate valid for ${days_left} days"
        fi
    fi

    # Certificate chain
    local verify_result
    verify_result=$(echo "$ssl_output" | grep "Verify return code")
    if echo "$verify_result" | grep -q "0 (ok)"; then
        pass "Certificate chain is valid"
    else
        fail "Certificate chain issue: ${verify_result}"
    fi

    # OCSP stapling
    local ocsp_output
    ocsp_output=$(echo | openssl s_client -connect "${domain}:443" -servername "$domain" -status 2>/dev/null)
    if echo "$ocsp_output" | grep -q "OCSP Response Status: successful"; then
        pass "OCSP stapling is active"
    else
        warn "OCSP stapling not detected"
    fi

    # Check for weak protocols
    for proto in tls1 tls1_1; do
        if echo | openssl s_client -connect "${domain}:443" -"$proto" 2>/dev/null | grep -q "Protocol"; then
            local version
            version=$(echo "$proto" | sed 's/tls1$/TLSv1.0/' | sed 's/tls1_1/TLSv1.1/')
            fail "Weak protocol ${version} is accepted"
        fi
    done
}

########################################
# Upstream Connectivity
########################################
check_upstream() {
    section "Upstream Connectivity"

    local config
    config=$("$NGINX_BIN" -T 2>/dev/null) || { fail "Cannot dump config"; return 1; }

    # Extract upstream servers
    local servers
    servers=$(echo "$config" | grep -P "^\s*server\s+\d" | grep -oP "server\s+\K[^;]+" | awk '{print $1}' | sort -u)

    if [[ -z "$servers" ]]; then
        warn "No upstream servers found in config"
        return 0
    fi

    while IFS= read -r server; do
        # Skip parameters (weight, max_fails, etc.)
        local addr
        addr=$(echo "$server" | awk '{print $1}')

        # Skip unix sockets
        if [[ "$addr" == unix:* ]]; then
            local sock="${addr#unix:}"
            if [[ -S "$sock" ]]; then
                pass "Unix socket ${sock} exists"
            else
                fail "Unix socket ${sock} does not exist"
            fi
            continue
        fi

        # Add default port if missing
        if ! echo "$addr" | grep -q ":"; then
            addr="${addr}:80"
        fi

        local host port
        host=$(echo "$addr" | rev | cut -d: -f2- | rev)
        port=$(echo "$addr" | rev | cut -d: -f1 | rev)

        # TCP connection test (1 second timeout)
        if timeout 2 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
            pass "Upstream ${addr} is reachable"
        else
            fail "Upstream ${addr} is unreachable"
        fi
    done <<< "$servers"
}

########################################
# Full Config Dump
########################################
dump_config() {
    section "Full Effective Configuration"
    "$NGINX_BIN" -T 2>&1
}

########################################
# Summary
########################################
print_summary() {
    section "Summary"
    echo -e "  ${GREEN}Passed: ${PASS}${NC}"
    echo -e "  ${YELLOW}Warnings: ${WARN}${NC}"
    echo -e "  ${RED}Failed: ${FAIL}${NC}"

    if [[ $FAIL -gt 0 ]]; then
        echo -e "\n  ${RED}Configuration has issues that should be addressed.${NC}"
        return 1
    elif [[ $WARN -gt 0 ]]; then
        echo -e "\n  ${YELLOW}Configuration is functional but has recommendations.${NC}"
        return 0
    else
        echo -e "\n  ${GREEN}Configuration looks good!${NC}"
        return 0
    fi
}

########################################
# Main
########################################
if [[ $# -eq 0 ]]; then
    # Run all checks
    echo -e "${BLUE}Nginx Configuration Validator${NC}"
    echo "Config: ${NGINX_CONF}"
    check_syntax
    check_security
    check_upstream
    print_summary
    exit $?
fi

case "$1" in
    --syntax)     check_syntax ;;
    --security)   check_security ;;
    --ssl)        shift; check_ssl "$@" ;;
    --upstream)   check_upstream ;;
    --full)       dump_config ;;
    -h|--help)    sed -n '3,/^$/s/^# \?//p' "$0"; exit 0 ;;
    *)            echo "Unknown option: $1"; exit 1 ;;
esac
