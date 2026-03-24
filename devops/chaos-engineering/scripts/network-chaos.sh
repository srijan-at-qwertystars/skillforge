#!/usr/bin/env bash
# ============================================================================
# network-chaos.sh — Inject network latency, packet loss, and partitions
# using tc (traffic control) and iptables.
#
# Usage:
#   ./network-chaos.sh latency <interface> <delay_ms> [jitter_ms] [duration_s]
#   ./network-chaos.sh loss <interface> <percent> [duration_s]
#   ./network-chaos.sh corrupt <interface> <percent> [duration_s]
#   ./network-chaos.sh partition <target_ip_or_cidr> [duration_s]
#   ./network-chaos.sh dns-block [duration_s]
#   ./network-chaos.sh cleanup <interface>
#
# Examples:
#   ./network-chaos.sh latency eth0 200 50 60     # 200ms ±50ms jitter for 60s
#   ./network-chaos.sh loss eth0 10 30             # 10% packet loss for 30s
#   ./network-chaos.sh partition 10.0.2.0/24 60    # Block subnet for 60s
#   ./network-chaos.sh dns-block 30                # Block DNS for 30s
#   ./network-chaos.sh cleanup eth0                # Remove all tc rules
#
# Requirements: root/sudo, iproute2 (tc), iptables
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_deps() {
    for cmd in tc iptables; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
}

cleanup_tc() {
    local iface="${1:?Interface required}"
    tc qdisc del dev "$iface" root 2>/dev/null || true
    log_info "Cleaned up tc rules on $iface"
}

cleanup_iptables_partition() {
    local target="${1:?Target required}"
    iptables -D OUTPUT -d "$target" -j DROP 2>/dev/null || true
    iptables -D INPUT -s "$target" -j DROP 2>/dev/null || true
    log_info "Cleaned up iptables rules for $target"
}

cleanup_iptables_dns() {
    iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true
    log_info "Cleaned up DNS block rules"
}

wait_and_revert() {
    local duration="$1"
    local revert_fn="$2"
    shift 2
    log_info "Chaos active for ${duration}s — will auto-revert"
    sleep "$duration"
    "$revert_fn" "$@"
    log_info "Chaos reverted after ${duration}s"
}

cmd_latency() {
    local iface="${1:?Usage: latency <interface> <delay_ms> [jitter_ms] [duration_s]}"
    local delay="${2:?Delay in ms required}"
    local jitter="${3:-0}"
    local duration="${4:-0}"

    cleanup_tc "$iface"

    if [[ "$jitter" -gt 0 ]]; then
        tc qdisc add dev "$iface" root netem delay "${delay}ms" "${jitter}ms" distribution normal
        log_info "Injected ${delay}ms ±${jitter}ms latency on $iface"
    else
        tc qdisc add dev "$iface" root netem delay "${delay}ms"
        log_info "Injected ${delay}ms latency on $iface"
    fi

    if [[ "$duration" -gt 0 ]]; then
        trap "cleanup_tc '$iface'" EXIT INT TERM
        wait_and_revert "$duration" cleanup_tc "$iface"
    else
        log_warn "No duration set — run './network-chaos.sh cleanup $iface' to revert"
    fi
}

cmd_loss() {
    local iface="${1:?Usage: loss <interface> <percent> [duration_s]}"
    local percent="${2:?Loss percentage required}"
    local duration="${3:-0}"

    cleanup_tc "$iface"
    tc qdisc add dev "$iface" root netem loss "${percent}%"
    log_info "Injected ${percent}% packet loss on $iface"

    if [[ "$duration" -gt 0 ]]; then
        trap "cleanup_tc '$iface'" EXIT INT TERM
        wait_and_revert "$duration" cleanup_tc "$iface"
    else
        log_warn "No duration set — run './network-chaos.sh cleanup $iface' to revert"
    fi
}

cmd_corrupt() {
    local iface="${1:?Usage: corrupt <interface> <percent> [duration_s]}"
    local percent="${2:?Corruption percentage required}"
    local duration="${3:-0}"

    cleanup_tc "$iface"
    tc qdisc add dev "$iface" root netem corrupt "${percent}%"
    log_info "Injected ${percent}% packet corruption on $iface"

    if [[ "$duration" -gt 0 ]]; then
        trap "cleanup_tc '$iface'" EXIT INT TERM
        wait_and_revert "$duration" cleanup_tc "$iface"
    else
        log_warn "No duration set — run './network-chaos.sh cleanup $iface' to revert"
    fi
}

cmd_partition() {
    local target="${1:?Usage: partition <target_ip_or_cidr> [duration_s]}"
    local duration="${2:-0}"

    iptables -A OUTPUT -d "$target" -j DROP
    iptables -A INPUT -s "$target" -j DROP
    log_info "Network partition active: blocked $target (inbound + outbound)"

    if [[ "$duration" -gt 0 ]]; then
        trap "cleanup_iptables_partition '$target'" EXIT INT TERM
        wait_and_revert "$duration" cleanup_iptables_partition "$target"
    else
        log_warn "No duration set — revert manually with: iptables -D OUTPUT/INPUT -d/-s $target -j DROP"
    fi
}

cmd_dns_block() {
    local duration="${1:-0}"

    iptables -A OUTPUT -p udp --dport 53 -j DROP
    iptables -A OUTPUT -p tcp --dport 53 -j DROP
    log_info "DNS blocked (UDP + TCP port 53)"

    if [[ "$duration" -gt 0 ]]; then
        trap cleanup_iptables_dns EXIT INT TERM
        wait_and_revert "$duration" cleanup_iptables_dns
    else
        log_warn "No duration set — run './network-chaos.sh cleanup-dns' to revert"
    fi
}

cmd_cleanup() {
    local iface="${1:-eth0}"
    cleanup_tc "$iface"
    cleanup_iptables_dns
    log_info "All network chaos cleaned up on $iface"
}

usage() {
    cat <<'EOF'
Usage: network-chaos.sh <command> [args...]

Commands:
  latency <iface> <ms> [jitter_ms] [duration_s]   Add network latency
  loss <iface> <percent> [duration_s]              Add packet loss
  corrupt <iface> <percent> [duration_s]           Add packet corruption
  partition <ip_or_cidr> [duration_s]              Block traffic to/from target
  dns-block [duration_s]                           Block all DNS resolution
  cleanup <iface>                                  Remove all injected faults

All commands auto-revert after duration_s if specified.
Requires root/sudo.
EOF
    exit 1
}

# --- Main ---
check_root
check_deps

case "${1:-}" in
    latency)    shift; cmd_latency "$@" ;;
    loss)       shift; cmd_loss "$@" ;;
    corrupt)    shift; cmd_corrupt "$@" ;;
    partition)  shift; cmd_partition "$@" ;;
    dns-block)  shift; cmd_dns_block "$@" ;;
    cleanup)    shift; cmd_cleanup "$@" ;;
    *)          usage ;;
esac
