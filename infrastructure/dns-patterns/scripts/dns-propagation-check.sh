#!/usr/bin/env bash
#
# dns-propagation-check.sh — DNS Propagation Checker
#
# Checks DNS record propagation across multiple public resolvers:
#   - Google DNS (8.8.8.8, 8.8.4.4)
#   - Cloudflare DNS (1.1.1.1, 1.0.0.1)
#   - Quad9 (9.9.9.9, 149.112.112.112)
#   - OpenDNS (208.67.222.222, 208.67.220.220)
#   - Authoritative nameservers
#
# Usage:
#   ./dns-propagation-check.sh <domain>                  # Check A record
#   ./dns-propagation-check.sh <domain> <type>           # Check specific type
#   ./dns-propagation-check.sh example.com MX            # Check MX records
#   ./dns-propagation-check.sh example.com TXT            # Check TXT records
#   ./dns-propagation-check.sh -e <expected> example.com  # Verify expected value
#   ./dns-propagation-check.sh -w example.com             # Watch mode (repeat every 30s)
#
# Requirements: dig (dnsutils/bind-utils), bash 4+

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

EXPECTED=""
WATCH=0
WATCH_INTERVAL=30

usage() {
    echo "Usage: $0 [-e expected_value] [-w] [-i interval] <domain> [record_type]"
    echo "  -e value     Expected record value to match against"
    echo "  -w           Watch mode (repeat check every interval)"
    echo "  -i seconds   Watch interval (default: 30)"
    exit 1
}

while getopts "e:wi:" opt; do
    case $opt in
        e) EXPECTED="$OPTARG" ;;
        w) WATCH=1 ;;
        i) WATCH_INTERVAL="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

DOMAIN="${1:-}"
RECORD_TYPE="${2:-A}"

[ -z "$DOMAIN" ] && usage

if ! command -v dig &>/dev/null; then
    echo -e "${RED}ERROR: 'dig' not found. Install dnsutils or bind-utils.${NC}"
    exit 2
fi

# Resolvers to check
declare -A RESOLVERS=(
    ["Google-1"]="8.8.8.8"
    ["Google-2"]="8.8.4.4"
    ["Cloudflare-1"]="1.1.1.1"
    ["Cloudflare-2"]="1.0.0.1"
    ["Quad9-1"]="9.9.9.9"
    ["Quad9-2"]="149.112.112.112"
    ["OpenDNS-1"]="208.67.222.222"
    ["OpenDNS-2"]="208.67.220.220"
)

check_propagation() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  DNS Propagation Check${NC}"
    echo -e "${BOLD}║  Domain: ${CYAN}${DOMAIN}${NC}  Type: ${CYAN}${RECORD_TYPE}${NC}"
    echo -e "${BOLD}║  Time:   ${timestamp}${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local consistent=1
    local first_result=""
    local propagated=0
    local total=0

    # Check authoritative nameservers first
    echo -e "${BLUE}── Authoritative Nameservers ──${NC}"
    AUTH_NS=$(dig +short NS "$DOMAIN" 2>/dev/null | head -4)
    if [ -n "$AUTH_NS" ]; then
        while IFS= read -r ns; do
            ns_clean=$(echo "$ns" | sed 's/\.$//')
            result=$(dig @"$ns_clean" +short +time=5 +tries=1 "$DOMAIN" "$RECORD_TYPE" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
            if [ -n "$result" ]; then
                echo -e "  ${GREEN}✓${NC} ${ns_clean}: ${result}"
            else
                echo -e "  ${YELLOW}–${NC} ${ns_clean}: (no response)"
            fi
        done <<< "$AUTH_NS"
    else
        echo -e "  ${YELLOW}Could not determine authoritative nameservers${NC}"
    fi
    echo ""

    # Check public resolvers
    echo -e "${BLUE}── Public Resolvers ──${NC}"
    printf "  %-16s %-16s %s\n" "RESOLVER" "IP" "RESULT"
    printf "  %-16s %-16s %s\n" "────────────" "──────────────" "──────────────────────────"

    for name in $(echo "${!RESOLVERS[@]}" | tr ' ' '\n' | sort); do
        ip="${RESOLVERS[$name]}"
        total=$((total + 1))

        result=$(dig @"$ip" +short +time=5 +tries=1 "$DOMAIN" "$RECORD_TYPE" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')

        if [ -z "$result" ]; then
            printf "  ${YELLOW}%-16s${NC} %-16s %s\n" "$name" "$ip" "(no record / timeout)"
        elif [ -n "$EXPECTED" ]; then
            if echo "$result" | grep -qF "$EXPECTED"; then
                printf "  ${GREEN}%-16s${NC} %-16s %s\n" "$name" "$ip" "$result"
                propagated=$((propagated + 1))
            else
                printf "  ${RED}%-16s${NC} %-16s %s ${RED}(expected: $EXPECTED)${NC}\n" "$name" "$ip" "$result"
                consistent=0
            fi
        else
            printf "  ${GREEN}%-16s${NC} %-16s %s\n" "$name" "$ip" "$result"
            propagated=$((propagated + 1))

            if [ -z "$first_result" ]; then
                first_result="$result"
            elif [ "$result" != "$first_result" ]; then
                consistent=0
            fi
        fi
    done

    echo ""
    echo -e "${BLUE}── Summary ──${NC}"
    echo "  Responding: ${propagated}/${total} resolvers"

    if [ -n "$EXPECTED" ]; then
        if [ "$propagated" -eq "$total" ]; then
            echo -e "  Status: ${GREEN}✓ Fully propagated (expected value found everywhere)${NC}"
        else
            echo -e "  Status: ${YELLOW}⏳ Propagation in progress ($propagated/$total match expected value)${NC}"
        fi
    elif [ "$consistent" -eq 1 ] && [ "$propagated" -eq "$total" ]; then
        echo -e "  Status: ${GREEN}✓ Consistent across all resolvers${NC}"
    elif [ "$consistent" -eq 0 ]; then
        echo -e "  Status: ${YELLOW}⚠ Inconsistent results — propagation in progress${NC}"
    fi

    # Show TTL info from one resolver
    TTL_INFO=$(dig @8.8.8.8 +noall +answer +time=5 "$DOMAIN" "$RECORD_TYPE" 2>/dev/null | head -1 | awk '{print $2}')
    if [ -n "$TTL_INFO" ]; then
        echo "  TTL remaining (Google): ${TTL_INFO}s"
    fi
    echo ""
}

if [ "$WATCH" -eq 1 ]; then
    echo -e "${CYAN}Watch mode enabled. Checking every ${WATCH_INTERVAL}s. Press Ctrl+C to stop.${NC}"
    while true; do
        clear
        check_propagation
        echo -e "${CYAN}Next check in ${WATCH_INTERVAL}s... (Ctrl+C to stop)${NC}"
        sleep "$WATCH_INTERVAL"
    done
else
    check_propagation
fi
