#!/usr/bin/env bash
#
# test-config.sh — Validate Traefik configuration and routing
#
# Usage:
#   ./test-config.sh [OPTIONS]
#
# Options:
#   --config FILE     Path to traefik.yml (default: ./traefik.yml)
#   --api URL         Traefik API URL (default: http://localhost:8080)
#   --host HOSTNAME   Test routing for a specific hostname
#   --cert DOMAIN     Check TLS certificate for domain
#   --full            Run all checks
#   --help            Show this help
#
# Examples:
#   ./test-config.sh --full
#   ./test-config.sh --config /etc/traefik/traefik.yml
#   ./test-config.sh --host app.example.com --cert app.example.com
#   ./test-config.sh --api http://traefik:8080 --full
#

set -euo pipefail

# Defaults
CONFIG_FILE="./traefik.yml"
API_URL="http://localhost:8080"
TEST_HOST=""
CERT_DOMAIN=""
FULL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass()  { echo -e "  ${GREEN}✓${NC} $*"; ((PASS++)); }
fail()  { echo -e "  ${RED}✗${NC} $*"; ((FAIL++)); }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; ((WARN++)); }
header() { echo -e "\n${BLUE}═══ $* ═══${NC}"; }

usage() {
    sed -n '3,15p' "$0" | sed 's/^# \?//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --api)     API_URL="$2"; shift 2 ;;
            --host)    TEST_HOST="$2"; shift 2 ;;
            --cert)    CERT_DOMAIN="$2"; shift 2 ;;
            --full)    FULL=true; shift ;;
            --help|-h) usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done
}

# ─── Config File Validation ──────────────────────────────────────────────────

check_config_file() {
    header "Configuration File Validation"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        fail "Config file not found: ${CONFIG_FILE}"
        return
    fi
    pass "Config file exists: ${CONFIG_FILE}"

    # Check YAML syntax
    if command -v python3 &>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('${CONFIG_FILE}'))" 2>/dev/null; then
            pass "YAML syntax valid"
        else
            fail "YAML syntax error in ${CONFIG_FILE}"
        fi
    elif command -v yq &>/dev/null; then
        if yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1; then
            pass "YAML syntax valid"
        else
            fail "YAML syntax error in ${CONFIG_FILE}"
        fi
    else
        warn "No YAML validator found (install python3-yaml or yq)"
    fi

    # Check for required sections
    local content
    content=$(cat "$CONFIG_FILE")

    if echo "$content" | grep -q "entryPoints"; then
        pass "entryPoints section found"
    else
        fail "Missing entryPoints section"
    fi

    if echo "$content" | grep -q "providers"; then
        pass "providers section found"
    else
        fail "Missing providers section"
    fi

    # Check for insecure API (security risk)
    if echo "$content" | grep -q "insecure: true"; then
        fail "api.insecure=true detected — SECURITY RISK in production"
    else
        pass "API is not set to insecure mode"
    fi

    # Check for ACME config
    if echo "$content" | grep -q "certificatesResolvers"; then
        pass "Certificate resolver configured"
        if echo "$content" | grep -q "staging"; then
            warn "Using Let's Encrypt STAGING server (certs will not be trusted)"
        fi
    else
        warn "No certificate resolver configured"
    fi

    # Check for HTTP→HTTPS redirect
    if echo "$content" | grep -q "redirections"; then
        pass "HTTP→HTTPS redirection configured"
    else
        warn "No HTTP→HTTPS redirection found"
    fi

    # Check for access logs
    if echo "$content" | grep -q "accessLog"; then
        pass "Access logging enabled"
    else
        warn "Access logging not configured"
    fi

    # Check for metrics
    if echo "$content" | grep -q "metrics"; then
        pass "Metrics configured"
    else
        warn "Metrics not configured"
    fi
}

# ─── ACME / TLS Certificate Checks ──────────────────────────────────────────

check_acme_json() {
    header "ACME Storage"

    # Look for acme.json path in config
    local acme_path
    acme_path=$(grep -oP 'storage:\s*\K\S+' "$CONFIG_FILE" 2>/dev/null | tr -d '"' | head -1)

    if [[ -z "$acme_path" ]]; then
        # Try common locations
        for path in ./acme.json /data/acme.json /etc/traefik/acme.json; do
            if [[ -f "$path" ]]; then
                acme_path="$path"
                break
            fi
        done
    fi

    if [[ -z "$acme_path" || ! -f "$acme_path" ]]; then
        warn "acme.json not found locally (may be in container volume)"
        return
    fi

    pass "acme.json found: ${acme_path}"

    # Check permissions
    local perms
    perms=$(stat -c '%a' "$acme_path" 2>/dev/null || stat -f '%Lp' "$acme_path" 2>/dev/null)
    if [[ "$perms" == "600" ]]; then
        pass "Permissions correct (600)"
    else
        fail "Permissions are ${perms}, should be 600. Fix: chmod 600 ${acme_path}"
    fi

    # Check if it has certificates
    if command -v jq &>/dev/null && [[ -s "$acme_path" ]]; then
        local cert_count
        cert_count=$(jq '[.. | .certificates? // empty | .[]] | length' "$acme_path" 2>/dev/null || echo "0")
        pass "Contains ${cert_count} certificate(s)"
    fi
}

check_tls_cert() {
    local domain="$1"
    header "TLS Certificate: ${domain}"

    if ! command -v openssl &>/dev/null; then
        warn "openssl not found, skipping TLS checks"
        return
    fi

    local cert_info
    cert_info=$(echo | openssl s_client -connect "${domain}:443" -servername "${domain}" 2>/dev/null)

    if [[ -z "$cert_info" ]]; then
        fail "Could not connect to ${domain}:443"
        return
    fi

    # Check certificate validity
    local not_after
    not_after=$(echo "$cert_info" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n "$not_after" ]]; then
        local expiry_epoch
        expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null)
        local now_epoch
        now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [[ $days_left -lt 0 ]]; then
            fail "Certificate EXPIRED ${days_left#-} days ago"
        elif [[ $days_left -lt 7 ]]; then
            fail "Certificate expires in ${days_left} days — CRITICAL"
        elif [[ $days_left -lt 30 ]]; then
            warn "Certificate expires in ${days_left} days"
        else
            pass "Certificate valid for ${days_left} days (expires: ${not_after})"
        fi
    fi

    # Check certificate subject
    local subject
    subject=$(echo "$cert_info" | openssl x509 -noout -subject 2>/dev/null)
    if [[ -n "$subject" ]]; then
        pass "Subject: ${subject#*=}"
    fi

    # Check issuer
    local issuer
    issuer=$(echo "$cert_info" | openssl x509 -noout -issuer 2>/dev/null)
    if echo "$issuer" | grep -qi "fake\|staging\|invalid"; then
        warn "Certificate from staging/test CA: ${issuer#*=}"
    elif [[ -n "$issuer" ]]; then
        pass "Issuer: ${issuer#*=}"
    fi

    # Check TLS version
    local protocol
    protocol=$(echo "$cert_info" | grep "Protocol" | awk '{print $NF}')
    if [[ "$protocol" == "TLSv1.3" ]]; then
        pass "TLS version: ${protocol}"
    elif [[ "$protocol" == "TLSv1.2" ]]; then
        pass "TLS version: ${protocol}"
    elif [[ -n "$protocol" ]]; then
        fail "Outdated TLS version: ${protocol}"
    fi
}

# ─── API Checks ──────────────────────────────────────────────────────────────

check_api() {
    header "Traefik API"

    # Test API connectivity
    if ! curl -sf "${API_URL}/api/overview" >/dev/null 2>&1; then
        fail "Cannot connect to Traefik API at ${API_URL}"
        warn "Enable API: api.dashboard=true, and ensure port 8080 is accessible"
        return
    fi
    pass "API accessible at ${API_URL}"

    # Overview
    local overview
    overview=$(curl -sf "${API_URL}/api/overview" 2>/dev/null)
    if [[ -n "$overview" ]] && command -v jq &>/dev/null; then
        local http_routers http_services http_middlewares
        http_routers=$(echo "$overview" | jq '.http.routers.total // 0')
        http_services=$(echo "$overview" | jq '.http.services.total // 0')
        http_middlewares=$(echo "$overview" | jq '.http.middlewares.total // 0')
        pass "HTTP routers: ${http_routers}, services: ${http_services}, middlewares: ${http_middlewares}"

        # Check for warnings
        local router_warnings
        router_warnings=$(echo "$overview" | jq '.http.routers.warnings // 0')
        if [[ "$router_warnings" -gt 0 ]]; then
            warn "${router_warnings} router warning(s) detected"
        fi

        local service_errors
        service_errors=$(echo "$overview" | jq '.http.services.errors // 0')
        if [[ "$service_errors" -gt 0 ]]; then
            fail "${service_errors} service error(s) detected"
        fi
    fi
}

check_routers() {
    header "Router Validation"

    local routers
    routers=$(curl -sf "${API_URL}/api/http/routers" 2>/dev/null)
    if [[ -z "$routers" ]]; then
        fail "Could not fetch routers"
        return
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq not found, skipping detailed router analysis"
        return
    fi

    local count
    count=$(echo "$routers" | jq 'length')
    pass "Found ${count} HTTP router(s)"

    # Check each router
    echo "$routers" | jq -r '.[] | "\(.name)|\(.status)|\(.rule)|\(.service)"' 2>/dev/null | while IFS='|' read -r name status rule service; do
        if [[ "$status" == "enabled" ]]; then
            pass "Router '${name}': enabled → ${service}"
        else
            fail "Router '${name}': ${status} (rule: ${rule})"
        fi
    done
}

check_services() {
    header "Service Health"

    local services
    services=$(curl -sf "${API_URL}/api/http/services" 2>/dev/null)
    if [[ -z "$services" ]]; then
        fail "Could not fetch services"
        return
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq not found, skipping detailed service analysis"
        return
    fi

    echo "$services" | jq -r '.[] | "\(.name)|\(.status)|\(.type)"' 2>/dev/null | while IFS='|' read -r name status stype; do
        if [[ "$status" == "enabled" ]]; then
            pass "Service '${name}' (${stype}): healthy"
        else
            fail "Service '${name}' (${stype}): ${status}"
        fi
    done
}

check_middlewares() {
    header "Middleware Chain"

    local middlewares
    middlewares=$(curl -sf "${API_URL}/api/http/middlewares" 2>/dev/null)
    if [[ -z "$middlewares" ]]; then
        fail "Could not fetch middlewares"
        return
    fi

    if ! command -v jq &>/dev/null; then
        warn "jq not found"
        return
    fi

    echo "$middlewares" | jq -r '.[] | "\(.name)|\(.status)|\(.type)"' 2>/dev/null | while IFS='|' read -r name status mtype; do
        if [[ "$status" == "enabled" ]]; then
            pass "Middleware '${name}' (${mtype}): OK"
        else
            fail "Middleware '${name}' (${mtype}): ${status}"
        fi
    done
}

# ─── Route Testing ───────────────────────────────────────────────────────────

check_routing() {
    local host="$1"
    header "Route Test: ${host}"

    # Test HTTP → HTTPS redirect
    local http_code
    http_code=$(curl -so /dev/null -w '%{http_code}' -m 10 "http://${host}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "301" || "$http_code" == "308" ]]; then
        pass "HTTP→HTTPS redirect: ${http_code}"
    elif [[ "$http_code" == "000" ]]; then
        fail "Cannot connect to http://${host}"
    else
        warn "HTTP response: ${http_code} (expected 301/308 redirect)"
    fi

    # Test HTTPS
    http_code=$(curl -so /dev/null -w '%{http_code}' -m 10 "https://${host}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" || "$http_code" == "302" || "$http_code" == "301" ]]; then
        pass "HTTPS response: ${http_code}"
    elif [[ "$http_code" == "404" ]]; then
        fail "HTTPS returned 404 — router rule may not match"
    elif [[ "$http_code" == "502" ]]; then
        fail "HTTPS returned 502 — backend unreachable (check port)"
    elif [[ "$http_code" == "000" ]]; then
        fail "Cannot connect to https://${host}"
    else
        warn "HTTPS response: ${http_code}"
    fi

    # Check response headers
    local headers
    headers=$(curl -sI -m 10 "https://${host}/" 2>/dev/null)

    if echo "$headers" | grep -qi "Strict-Transport-Security"; then
        pass "HSTS header present"
    else
        warn "HSTS header missing"
    fi

    if echo "$headers" | grep -qi "X-Content-Type-Options"; then
        pass "X-Content-Type-Options header present"
    else
        warn "X-Content-Type-Options header missing"
    fi
}

# ─── Docker Checks ───────────────────────────────────────────────────────────

check_docker() {
    header "Docker Environment"

    if ! command -v docker &>/dev/null; then
        warn "Docker not found, skipping Docker checks"
        return
    fi

    # Check if Traefik container is running
    local traefik_id
    traefik_id=$(docker ps -qf "ancestor=traefik" 2>/dev/null | head -1)
    if [[ -z "$traefik_id" ]]; then
        traefik_id=$(docker ps -qf "name=traefik" 2>/dev/null | head -1)
    fi

    if [[ -n "$traefik_id" ]]; then
        pass "Traefik container running: ${traefik_id:0:12}"

        # Check container health
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$traefik_id" 2>/dev/null || echo "no-healthcheck")
        if [[ "$health" == "healthy" ]]; then
            pass "Container health: healthy"
        elif [[ "$health" == "unhealthy" ]]; then
            fail "Container health: unhealthy"
        else
            warn "No healthcheck configured"
        fi

        # Check docker socket mount
        if docker inspect "$traefik_id" 2>/dev/null | grep -q "docker.sock"; then
            local ro
            ro=$(docker inspect "$traefik_id" 2>/dev/null | grep -A2 "docker.sock" | grep -c "ro" || true)
            if [[ "$ro" -gt 0 ]]; then
                pass "Docker socket mounted read-only"
            else
                warn "Docker socket mounted read-write — consider :ro"
            fi
        fi
    else
        warn "No Traefik container found"
    fi

    # Check proxy network
    if docker network inspect proxy &>/dev/null; then
        local connected
        connected=$(docker network inspect proxy 2>/dev/null | jq '[.[] | .Containers | length] | add // 0')
        pass "Proxy network exists (${connected} container(s) connected)"
    else
        warn "Docker network 'proxy' not found"
    fi
}

# ─── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "  ${GREEN}Passed: ${PASS}${NC}  ${RED}Failed: ${FAIL}${NC}  ${YELLOW}Warnings: ${WARN}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"

    if [[ $FAIL -gt 0 ]]; then
        exit 1
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

parse_args "$@"

check_config_file

if [[ "$FULL" == true ]]; then
    check_acme_json
    check_api
    check_routers
    check_services
    check_middlewares
    check_docker
fi

if [[ -n "$TEST_HOST" ]]; then
    check_routing "$TEST_HOST"
fi

if [[ -n "$CERT_DOMAIN" ]]; then
    check_tls_cert "$CERT_DOMAIN"
fi

print_summary
