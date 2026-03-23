#!/usr/bin/env bash
set -euo pipefail

# Check certificate status for all configured domains in Traefik.
# Usage: traefik-cert-check.sh [--acme FILE] [--api URL] [--warn-days N]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ACME_FILE=""
TRAEFIK_API=""
WARN_DAYS=30
DOMAINS=()
CHECK_LIVE=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Check certificate status for Traefik-managed domains."
    echo ""
    echo "Options:"
    echo "  --acme FILE       Path to acme.json file"
    echo "  --api URL         Traefik API URL (e.g., http://localhost:8080)"
    echo "  --domain DOMAIN   Check a specific domain (can be repeated)"
    echo "  --live            Also check live certificate via TLS handshake"
    echo "  --warn-days N     Days before expiry to warn (default: 30)"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --acme /letsencrypt/acme.json"
    echo "  $0 --api http://localhost:8080"
    echo "  $0 --domain example.com --domain api.example.com --live"
    echo "  $0 --acme acme.json --warn-days 14"
}

check_cert_from_acme() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo -e "${RED}✗${NC} acme.json not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        echo -e "${RED}✗${NC} Cannot read acme.json (check permissions): $file"
        return 1
    fi

    echo -e "\n${CYAN}=== Certificates from acme.json ===${NC}\n"

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗${NC} jq is required to parse acme.json"
        return 1
    fi

    local resolvers
    resolvers=$(jq -r 'keys[]' "$file" 2>/dev/null || echo "")

    if [[ -z "$resolvers" ]]; then
        echo -e "${YELLOW}⚠${NC} No certificate resolvers found in acme.json"
        return 0
    fi

    for resolver in $resolvers; do
        echo -e "${CYAN}Resolver: ${resolver}${NC}"

        local cert_count
        cert_count=$(jq -r ".\"${resolver}\".Certificates // [] | length" "$file")

        if [[ "$cert_count" == "0" ]]; then
            echo -e "  ${YELLOW}⚠${NC} No certificates stored"
            continue
        fi

        for i in $(seq 0 $((cert_count - 1))); do
            local domain
            domain=$(jq -r ".\"${resolver}\".Certificates[$i].domain.main" "$file")
            local sans
            sans=$(jq -r ".\"${resolver}\".Certificates[$i].domain.sans // [] | join(\", \")" "$file")

            # Extract and decode certificate to check expiry
            local cert_b64
            cert_b64=$(jq -r ".\"${resolver}\".Certificates[$i].certificate" "$file")

            if [[ -n "$cert_b64" && "$cert_b64" != "null" ]]; then
                local cert_pem
                cert_pem=$(echo "$cert_b64" | base64 -d 2>/dev/null || echo "")

                if [[ -n "$cert_pem" ]] && command -v openssl &>/dev/null; then
                    local expiry
                    expiry=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")

                    local expiry_epoch
                    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
                    local now_epoch
                    now_epoch=$(date +%s)
                    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

                    local status_icon
                    if [[ $days_left -lt 0 ]]; then
                        status_icon="${RED}EXPIRED${NC}"
                    elif [[ $days_left -lt $WARN_DAYS ]]; then
                        status_icon="${YELLOW}${days_left}d left${NC}"
                    else
                        status_icon="${GREEN}${days_left}d left${NC}"
                    fi

                    echo -e "  ${GREEN}✓${NC} ${domain} [${status_icon}] expires: ${expiry}"
                    if [[ -n "$sans" ]]; then
                        echo -e "    SANs: ${sans}"
                    fi
                else
                    echo -e "  ${GREEN}✓${NC} ${domain} (certificate present, cannot check expiry)"
                fi
            else
                echo -e "  ${YELLOW}⚠${NC} ${domain} — certificate data missing"
            fi
        done
        echo ""
    done
}

check_cert_from_api() {
    local api_url="$1"

    echo -e "\n${CYAN}=== Certificates from Traefik API ===${NC}\n"

    if ! command -v curl &>/dev/null; then
        echo -e "${RED}✗${NC} curl is required to query Traefik API"
        return 1
    fi

    # Check API is reachable
    if ! curl -sf "${api_url}/api/overview" >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} Cannot reach Traefik API at ${api_url}"
        echo "  Ensure the API is enabled and accessible."
        return 1
    fi

    # Get routers with TLS
    local routers
    routers=$(curl -sf "${api_url}/api/http/routers" 2>/dev/null || echo "[]")

    echo "$routers" | jq -r '.[] | select(.tls != null) | "\(.name) | \(.rule) | \(.tls.certResolver // "manual")"' 2>/dev/null | while IFS='|' read -r name rule resolver; do
        name=$(echo "$name" | xargs)
        rule=$(echo "$rule" | xargs)
        resolver=$(echo "$resolver" | xargs)

        # Extract domain from rule
        local domain
        domain=$(echo "$rule" | grep -oP "Host\(\`\K[^\`]+" | head -1 || echo "unknown")

        echo -e "  ${GREEN}✓${NC} Router: ${name}"
        echo -e "    Domain: ${domain}"
        echo -e "    Resolver: ${resolver}"
    done

    # Get TLS certificates info from entrypoints
    echo ""
    echo -e "${CYAN}Services status:${NC}"
    local services
    services=$(curl -sf "${api_url}/api/http/services" 2>/dev/null || echo "[]")
    echo "$services" | jq -r '.[] | "\(.name) \(.status // "unknown") \(.type // "unknown")"' 2>/dev/null | while read -r sname sstatus stype; do
        local icon="${GREEN}●${NC}"
        [[ "$sstatus" == "enabled" ]] || icon="${RED}●${NC}"
        echo -e "  ${icon} ${sname} (${stype}): ${sstatus}"
    done
}

check_live_cert() {
    local domain="$1"
    local port="${2:-443}"

    if ! command -v openssl &>/dev/null; then
        echo -e "  ${RED}✗${NC} openssl required for live certificate check"
        return 1
    fi

    local cert_info
    cert_info=$(echo | openssl s_client -servername "$domain" -connect "${domain}:${port}" 2>/dev/null | openssl x509 -noout -subject -enddate -issuer 2>/dev/null || echo "")

    if [[ -z "$cert_info" ]]; then
        echo -e "  ${RED}✗${NC} ${domain}:${port} — cannot retrieve certificate"
        return 1
    fi

    local subject issuer expiry
    subject=$(echo "$cert_info" | grep "subject=" | sed 's/subject=//')
    issuer=$(echo "$cert_info" | grep "issuer=" | sed 's/issuer=//')
    expiry=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2)

    local expiry_epoch now_epoch days_left
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    local status_icon
    if [[ $days_left -lt 0 ]]; then
        status_icon="${RED}EXPIRED${NC}"
    elif [[ $days_left -lt $WARN_DAYS ]]; then
        status_icon="${YELLOW}${days_left}d left${NC}"
    else
        status_icon="${GREEN}${days_left}d left${NC}"
    fi

    echo -e "  ${GREEN}✓${NC} ${domain} [${status_icon}]"
    echo -e "    Subject: ${subject}"
    echo -e "    Issuer:  ${issuer}"
    echo -e "    Expires: ${expiry}"
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --acme) ACME_FILE="$2"; shift 2 ;;
        --api) TRAEFIK_API="$2"; shift 2 ;;
        --domain) DOMAINS+=("$2"); shift 2 ;;
        --live) CHECK_LIVE=true; shift ;;
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

echo "╔═══════════════════════════════════════╗"
echo "║    Traefik Certificate Status Check   ║"
echo "╚═══════════════════════════════════════╝"

# Check acme.json
if [[ -n "$ACME_FILE" ]]; then
    check_cert_from_acme "$ACME_FILE"
fi

# Check via API
if [[ -n "$TRAEFIK_API" ]]; then
    check_cert_from_api "$TRAEFIK_API"
fi

# Check specific domains
if [[ ${#DOMAINS[@]} -gt 0 ]]; then
    echo -e "\n${CYAN}=== Live Certificate Check ===${NC}\n"
    for domain in "${DOMAINS[@]}"; do
        check_live_cert "$domain"
        echo ""
    done
fi

# Live check for acme domains
if [[ "$CHECK_LIVE" == "true" && -n "$ACME_FILE" && -f "$ACME_FILE" ]]; then
    echo -e "\n${CYAN}=== Live TLS Verification ===${NC}\n"
    if command -v jq &>/dev/null; then
        jq -r '.[].Certificates[]?.domain.main // empty' "$ACME_FILE" 2>/dev/null | while read -r domain; do
            check_live_cert "$domain"
            echo ""
        done
    fi
fi

echo -e "\n${GREEN}Check complete.${NC} Warning threshold: ${WARN_DAYS} days."
