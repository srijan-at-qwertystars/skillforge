#!/usr/bin/env bash
#
# wg-status.sh — Enhanced WireGuard status display.
#
# Parses `wg show` output and displays:
#   - Interface status and configuration
#   - Per-peer connectivity status
#   - Last handshake age (human-readable)
#   - Transfer rates and totals
#   - Connection health indicators
#
# Usage:
#   wg-status.sh [interface]    Show status for interface (default: all)
#   wg-status.sh --watch [sec]  Continuous monitoring (default: 2s interval)
#   wg-status.sh --json         Output as JSON
#   wg-status.sh --brief        One-line-per-peer summary

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly HANDSHAKE_WARN=180    # seconds — warn if handshake older than this
readonly HANDSHAKE_CRIT=300    # seconds — critical if older than this

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [INTERFACE]

Enhanced WireGuard status display.

Options:
  --watch [seconds]   Continuous monitoring (default interval: 2s)
  --json              Output as JSON
  --brief             One-line-per-peer summary
  -h, --help          Show this help

Examples:
  ${SCRIPT_NAME}              Show all interfaces
  ${SCRIPT_NAME} wg0          Show wg0 only
  ${SCRIPT_NAME} --watch      Monitor all interfaces every 2s
  ${SCRIPT_NAME} --watch 5    Monitor every 5s
  ${SCRIPT_NAME} --json wg0   JSON output for wg0
  ${SCRIPT_NAME} --brief      Compact summary
EOF
    exit 0
}

die() {
    echo "Error: $*" >&2
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (wg show requires root access)"
    fi
}

human_bytes() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes} B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f KiB\", $bytes/1024}")"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f MiB\", $bytes/1048576}")"
    else
        echo "$(awk "BEGIN {printf \"%.2f GiB\", $bytes/1073741824}")"
    fi
}

human_duration() {
    local seconds=$1
    if [[ $seconds -lt 0 ]]; then
        echo "never"
        return
    elif [[ $seconds -lt 60 ]]; then
        echo "${seconds}s ago"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s ago"
    elif [[ $seconds -lt 86400 ]]; then
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m ago"
    else
        echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h ago"
    fi
}

handshake_status() {
    local age=$1
    if [[ $age -lt 0 ]]; then
        echo -e "${RED}●${NC} no handshake"
    elif [[ $age -le $HANDSHAKE_WARN ]]; then
        echo -e "${GREEN}●${NC} healthy"
    elif [[ $age -le $HANDSHAKE_CRIT ]]; then
        echo -e "${YELLOW}●${NC} stale"
    else
        echo -e "${RED}●${NC} inactive"
    fi
}

get_interfaces() {
    wg show interfaces 2>/dev/null || true
}

show_interface_status() {
    local iface="$1"
    local format="${2:-full}"

    # Get interface dump data
    local dump
    dump=$(wg show "$iface" dump 2>/dev/null) || return 1

    local now
    now=$(date +%s)

    # Parse interface line (first line of dump)
    local iface_line
    iface_line=$(echo "$dump" | head -1)
    local iface_privkey iface_pubkey iface_port iface_fwmark
    IFS=$'\t' read -r iface_privkey iface_pubkey iface_port iface_fwmark <<< "$iface_line"

    # Get interface IP
    local iface_addr
    iface_addr=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' || echo "N/A")
    local iface_addr6
    iface_addr6=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -oP 'inet6 \K[\da-f:./]+' || echo "")

    # Get interface MTU
    local iface_mtu
    iface_mtu=$(ip link show "$iface" 2>/dev/null | grep -oP 'mtu \K\d+' || echo "N/A")

    # Count peers
    local peer_count
    peer_count=$(echo "$dump" | tail -n +2 | wc -l)

    local active_peers=0
    local total_rx=0
    local total_tx=0

    if [[ "$format" == "json" ]]; then
        show_json "$iface" "$dump" "$now"
        return
    fi

    # --- Header ---
    echo -e "${BOLD}${CYAN}interface: ${iface}${NC}"
    echo -e "  ${DIM}address:${NC}    ${iface_addr}${iface_addr6:+ / ${iface_addr6}}"
    echo -e "  ${DIM}port:${NC}       ${iface_port}"
    echo -e "  ${DIM}mtu:${NC}        ${iface_mtu}"
    echo -e "  ${DIM}public key:${NC} ${iface_pubkey:0:20}...${iface_pubkey: -8}"
    [[ "$iface_fwmark" != "off" && "$iface_fwmark" != "0" ]] && \
        echo -e "  ${DIM}fwmark:${NC}     ${iface_fwmark}"
    echo ""

    # --- Peers ---
    if [[ $peer_count -eq 0 ]]; then
        echo -e "  ${DIM}No peers configured.${NC}"
        echo ""
        return
    fi

    if [[ "$format" == "brief" ]]; then
        printf "  ${BOLD}%-20s %-18s %-14s %-12s %-12s %s${NC}\n" \
            "PEER" "ENDPOINT" "HANDSHAKE" "RX" "TX" "STATUS"
    fi

    echo "$dump" | tail -n +2 | while IFS=$'\t' read -r pubkey psk endpoint allowed_ips handshake rx tx keepalive; do
        local handshake_age=-1
        if [[ "$handshake" -gt 0 ]]; then
            handshake_age=$((now - handshake))
            active_peers=$((active_peers + 1))
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        local peer_short="${pubkey:0:16}..."
        local status
        status=$(handshake_status "$handshake_age")

        if [[ "$format" == "brief" ]]; then
            local hs_str
            hs_str=$(human_duration "$handshake_age")
            printf "  %-20s %-18s %-14s %-12s %-12s %b\n" \
                "$peer_short" \
                "${endpoint:-(none)}" \
                "$hs_str" \
                "$(human_bytes "$rx")" \
                "$(human_bytes "$tx")" \
                "$status"
        else
            echo -e "  ${BOLD}peer: ${peer_short}${NC}"
            echo -e "    ${DIM}public key:${NC}  ${pubkey}"
            echo -e "    ${DIM}endpoint:${NC}    ${endpoint:-(none)}"
            echo -e "    ${DIM}allowed ips:${NC} ${allowed_ips}"
            echo -e "    ${DIM}handshake:${NC}   $(human_duration "$handshake_age")"
            echo -e "    ${DIM}status:${NC}      ${status}"
            echo -e "    ${DIM}transfer:${NC}    ↓ $(human_bytes "$rx")  ↑ $(human_bytes "$tx")"
            [[ "$keepalive" != "off" && "$keepalive" != "0" ]] && \
                echo -e "    ${DIM}keepalive:${NC}   every ${keepalive}s"
            [[ "$psk" != "(none)" ]] && \
                echo -e "    ${DIM}preshared:${NC}   ${GREEN}yes${NC}"
            echo ""
        fi
    done

    if [[ "$format" != "brief" ]]; then
        echo -e "  ${DIM}───────────────────────────────────────${NC}"
        echo -e "  ${DIM}peers:${NC} ${peer_count}  ${DIM}|${NC}  ${DIM}total rx:${NC} $(human_bytes "$total_rx")  ${DIM}|${NC}  ${DIM}total tx:${NC} $(human_bytes "$total_tx")"
    fi
    echo ""
}

show_json() {
    local iface="$1"
    local dump="$2"
    local now="$3"

    local iface_line
    iface_line=$(echo "$dump" | head -1)
    local iface_privkey iface_pubkey iface_port iface_fwmark
    IFS=$'\t' read -r iface_privkey iface_pubkey iface_port iface_fwmark <<< "$iface_line"

    local iface_addr
    iface_addr=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' || echo "")

    echo "{"
    echo "  \"interface\": \"${iface}\","
    echo "  \"public_key\": \"${iface_pubkey}\","
    echo "  \"listen_port\": ${iface_port},"
    echo "  \"address\": \"${iface_addr}\","
    echo "  \"peers\": ["

    local first=true
    echo "$dump" | tail -n +2 | while IFS=$'\t' read -r pubkey psk endpoint allowed_ips handshake rx tx keepalive; do
        local handshake_age=-1
        [[ "$handshake" -gt 0 ]] && handshake_age=$((now - handshake))

        local health="inactive"
        if [[ $handshake_age -ge 0 && $handshake_age -le $HANDSHAKE_WARN ]]; then
            health="healthy"
        elif [[ $handshake_age -gt $HANDSHAKE_WARN && $handshake_age -le $HANDSHAKE_CRIT ]]; then
            health="stale"
        fi

        $first || echo ","
        first=false

        cat <<PEER_JSON
    {
      "public_key": "${pubkey}",
      "endpoint": "${endpoint}",
      "allowed_ips": "${allowed_ips}",
      "latest_handshake": ${handshake},
      "handshake_age_seconds": ${handshake_age},
      "health": "${health}",
      "transfer_rx": ${rx},
      "transfer_tx": ${tx},
      "persistent_keepalive": "${keepalive}",
      "has_preshared_key": $([ "$psk" != "(none)" ] && echo "true" || echo "false")
    }
PEER_JSON
    done

    echo ""
    echo "  ]"
    echo "}"
}

# --- Parse arguments ---
FORMAT="full"
WATCH_MODE=false
WATCH_INTERVAL=2
TARGET_IFACE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch)
            WATCH_MODE=true
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                WATCH_INTERVAL="$2"
                shift
            fi
            shift
            ;;
        --json)     FORMAT="json"; shift ;;
        --brief)    FORMAT="brief"; shift ;;
        -h|--help)  usage ;;
        -*)         die "Unknown option: $1" ;;
        *)          TARGET_IFACE="$1"; shift ;;
    esac
done

check_root

# --- Main ---
show_all() {
    if [[ -n "$TARGET_IFACE" ]]; then
        show_interface_status "$TARGET_IFACE" "$FORMAT"
    else
        local interfaces
        interfaces=$(get_interfaces)
        if [[ -z "$interfaces" ]]; then
            echo "No WireGuard interfaces found."
            exit 0
        fi
        for iface in $interfaces; do
            show_interface_status "$iface" "$FORMAT"
        done
    fi
}

if $WATCH_MODE; then
    while true; do
        clear
        echo -e "${DIM}WireGuard Status — $(date '+%Y-%m-%d %H:%M:%S') — refresh: ${WATCH_INTERVAL}s${NC}"
        echo ""
        show_all
        sleep "$WATCH_INTERVAL"
    done
else
    show_all
fi
