#!/usr/bin/env bash
# =============================================================================
# net-diagnostics.sh — Comprehensive Linux Network Diagnostic Tool
# =============================================================================
# Usage: sudo ./net-diagnostics.sh [--full | --quick | --section <name>]
#
# Sections: interfaces, routes, dns, ports, connections, firewall, latency
#
# Examples:
#   sudo ./net-diagnostics.sh                  # full diagnostic
#   sudo ./net-diagnostics.sh --quick          # brief summary only
#   sudo ./net-diagnostics.sh --section dns    # DNS checks only
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}ℹ${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        warn "Running without root — some checks may be incomplete. Use sudo for full results."
    fi
}

cmd_exists() {
    command -v "$1" &>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Sections
# ─────────────────────────────────────────────────────────────────────────────

diag_interfaces() {
    section "NETWORK INTERFACES"

    echo -e "\n  ${BOLD}Interface Status:${NC}"
    ip -br link show | while read -r iface state rest; do
        if [[ "$state" == "UP" ]]; then
            ok "$iface — $state $rest"
        elif [[ "$state" == "DOWN" ]]; then
            fail "$iface — $state"
        else
            warn "$iface — $state"
        fi
    done

    echo -e "\n  ${BOLD}IP Addresses:${NC}"
    ip -br addr show | while read -r line; do
        info "$line"
    done

    echo -e "\n  ${BOLD}Interface Statistics (errors/drops):${NC}"
    for iface in $(ip -br link show | awk '{print $1}'); do
        local stats
        stats=$(ip -s link show dev "$iface" 2>/dev/null | grep -A1 "RX:" | tail -1)
        local rx_errors rx_dropped
        rx_errors=$(echo "$stats" | awk '{print $3}')
        rx_dropped=$(echo "$stats" | awk '{print $4}')
        if [[ "$rx_errors" -gt 0 || "$rx_dropped" -gt 0 ]] 2>/dev/null; then
            warn "$iface: RX errors=$rx_errors dropped=$rx_dropped"
        fi
    done

    if cmd_exists ethtool; then
        echo -e "\n  ${BOLD}Link Speed:${NC}"
        for iface in $(ip -br link show | awk '$2=="UP" {print $1}'); do
            local speed
            speed=$(ethtool "$iface" 2>/dev/null | grep "Speed:" | awk '{print $2}')
            if [[ -n "$speed" && "$speed" != "Unknown!" ]]; then
                info "$iface: $speed"
            fi
        done
    fi
}

diag_routes() {
    section "ROUTING"

    echo -e "\n  ${BOLD}Default Gateway:${NC}"
    local gw
    gw=$(ip route show default 2>/dev/null | head -1)
    if [[ -n "$gw" ]]; then
        ok "$gw"
    else
        fail "No default gateway configured!"
    fi

    echo -e "\n  ${BOLD}Routing Table:${NC}"
    ip route show | while read -r line; do
        info "$line"
    done

    echo -e "\n  ${BOLD}Policy Rules:${NC}"
    local rule_count
    rule_count=$(ip rule show | wc -l)
    if [[ $rule_count -gt 3 ]]; then
        warn "Non-default policy rules detected ($rule_count rules)"
        ip rule show | while read -r line; do
            info "$line"
        done
    else
        ok "Standard routing policy ($rule_count rules)"
    fi
}

diag_dns() {
    section "DNS RESOLUTION"

    echo -e "\n  ${BOLD}DNS Configuration:${NC}"
    if [[ -L /etc/resolv.conf ]]; then
        info "resolv.conf is a symlink → $(readlink -f /etc/resolv.conf)"
    else
        info "resolv.conf is a regular file"
    fi
    grep -E "^nameserver" /etc/resolv.conf 2>/dev/null | while read -r line; do
        info "$line"
    done

    if cmd_exists resolvectl; then
        echo -e "\n  ${BOLD}systemd-resolved Status:${NC}"
        resolvectl status 2>/dev/null | grep -E "DNS Server|DNS Domain|DNSSEC" | head -10 | while read -r line; do
            info "$line"
        done
    fi

    echo -e "\n  ${BOLD}DNS Resolution Tests:${NC}"
    for domain in google.com github.com; do
        if cmd_exists dig; then
            local result
            result=$(dig +short +time=3 +tries=1 "$domain" 2>/dev/null | head -1)
            if [[ -n "$result" ]]; then
                ok "$domain → $result"
            else
                fail "$domain — resolution failed"
            fi
        elif cmd_exists nslookup; then
            if nslookup "$domain" &>/dev/null; then
                ok "$domain — resolves OK"
            else
                fail "$domain — resolution failed"
            fi
        else
            warn "Neither dig nor nslookup available"
            break
        fi
    done

    echo -e "\n  ${BOLD}Port 53 Status:${NC}"
    if ss -ulnp 2>/dev/null | grep -q ":53 "; then
        info "Local DNS service listening on port 53"
    else
        info "No local DNS service on port 53"
    fi
}

diag_ports() {
    section "OPEN PORTS & LISTENING SERVICES"

    echo -e "\n  ${BOLD}TCP Listening:${NC}"
    ss -tlnp 2>/dev/null | tail -n +2 | while read -r state recv send local peer process; do
        info "$local  $process"
    done

    echo -e "\n  ${BOLD}UDP Listening:${NC}"
    ss -ulnp 2>/dev/null | tail -n +2 | while read -r state recv send local peer process; do
        info "$local  $process"
    done
}

diag_connections() {
    section "ACTIVE CONNECTIONS"

    echo -e "\n  ${BOLD}Connection Summary:${NC}"
    ss -s 2>/dev/null | head -10 | while read -r line; do
        info "$line"
    done

    echo -e "\n  ${BOLD}TCP State Distribution:${NC}"
    ss -tan 2>/dev/null | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn | while read -r count state; do
        if [[ "$state" == "TIME-WAIT" && $count -gt 1000 ]]; then
            warn "$count $state (high — consider tuning tcp_tw_reuse)"
        elif [[ "$state" == "SYN-RECV" && $count -gt 50 ]]; then
            warn "$count $state (possible SYN flood)"
        else
            info "$count $state"
        fi
    done

    echo -e "\n  ${BOLD}Top 5 Remote Hosts (by connection count):${NC}"
    ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -5 | while read -r count ip; do
        info "$count connections from $ip"
    done
}

diag_firewall() {
    section "FIREWALL STATUS"

    if cmd_exists ufw; then
        echo -e "\n  ${BOLD}UFW:${NC}"
        ufw status 2>/dev/null | head -20 | while read -r line; do
            info "$line"
        done
    fi

    if cmd_exists iptables; then
        echo -e "\n  ${BOLD}iptables (filter):${NC}"
        local rule_count
        rule_count=$(iptables -L -n 2>/dev/null | grep -cE "^(ACCEPT|DROP|REJECT|LOG)" || true)
        info "$rule_count rules in filter table"
        if [[ $rule_count -gt 0 ]]; then
            iptables -L -n --line-numbers 2>/dev/null | head -30 | while read -r line; do
                info "$line"
            done
        fi

        echo -e "\n  ${BOLD}iptables (nat):${NC}"
        local nat_count
        nat_count=$(iptables -t nat -L -n 2>/dev/null | grep -cE "^(MASQ|SNAT|DNAT|REDIRECT)" || true)
        info "$nat_count NAT rules"
    fi

    if cmd_exists nft; then
        echo -e "\n  ${BOLD}nftables:${NC}"
        local nft_tables
        nft_tables=$(nft list tables 2>/dev/null | wc -l)
        info "$nft_tables tables defined"
        if [[ $nft_tables -gt 0 ]]; then
            nft list tables 2>/dev/null | while read -r line; do
                info "$line"
            done
        fi
    fi
}

diag_latency() {
    section "LATENCY & CONNECTIVITY TESTS"

    local gateway
    gateway=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)

    echo -e "\n  ${BOLD}Gateway Ping:${NC}"
    if [[ -n "$gateway" ]]; then
        local gw_ping
        gw_ping=$(ping -c 3 -W 2 "$gateway" 2>/dev/null | tail -1)
        if [[ -n "$gw_ping" ]]; then
            ok "Gateway $gateway — $gw_ping"
        else
            fail "Gateway $gateway — unreachable"
        fi
    else
        fail "No default gateway"
    fi

    echo -e "\n  ${BOLD}External Connectivity:${NC}"
    for target in 8.8.8.8 1.1.1.1; do
        local result
        result=$(ping -c 3 -W 3 "$target" 2>/dev/null | tail -1)
        if [[ -n "$result" ]]; then
            ok "$target — $result"
        else
            fail "$target — unreachable"
        fi
    done

    echo -e "\n  ${BOLD}DNS Latency:${NC}"
    if cmd_exists dig; then
        for ns in 8.8.8.8 1.1.1.1; do
            local time_ms
            time_ms=$(dig @"$ns" google.com +time=3 +tries=1 2>/dev/null | grep "Query time" | awk '{print $4}')
            if [[ -n "$time_ms" ]]; then
                info "DNS $ns: ${time_ms}ms"
            else
                warn "DNS $ns: timeout"
            fi
        done
    fi

    if cmd_exists curl; then
        echo -e "\n  ${BOLD}HTTP Latency:${NC}"
        local http_time
        http_time=$(curl -o /dev/null -s -w "DNS:%{time_namelookup}s Connect:%{time_connect}s TLS:%{time_appconnect}s Total:%{time_total}s" \
            --max-time 10 https://www.google.com 2>/dev/null)
        if [[ -n "$http_time" ]]; then
            info "google.com — $http_time"
        else
            warn "HTTPS test failed"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║           Linux Network Diagnostics Report                  ║"
    echo "  ║           $(date '+%Y-%m-%d %H:%M:%S %Z')                          ║"
    echo "  ║           Hostname: $(hostname)                             ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root

    local mode="${1:---full}"
    local target_section="${2:-}"

    case "$mode" in
        --quick)
            diag_interfaces
            diag_routes
            diag_dns
            ;;
        --section)
            if [[ -z "$target_section" ]]; then
                echo "Usage: $0 --section <interfaces|routes|dns|ports|connections|firewall|latency>"
                exit 1
            fi
            case "$target_section" in
                interfaces)  diag_interfaces ;;
                routes)      diag_routes ;;
                dns)         diag_dns ;;
                ports)       diag_ports ;;
                connections) diag_connections ;;
                firewall)    diag_firewall ;;
                latency)     diag_latency ;;
                *)
                    echo "Unknown section: $target_section"
                    echo "Available: interfaces, routes, dns, ports, connections, firewall, latency"
                    exit 1
                    ;;
            esac
            ;;
        --full|*)
            diag_interfaces
            diag_routes
            diag_dns
            diag_ports
            diag_connections
            diag_firewall
            diag_latency
            ;;
    esac

    echo ""
    echo -e "${BOLD}${GREEN}  Diagnostic complete.${NC}"
    echo ""
}

main "$@"
