#!/usr/bin/env bash
# =============================================================================
# bandwidth-test.sh — Bandwidth Testing Tool using iperf3
# =============================================================================
# Usage:
#   ./bandwidth-test.sh server [--port 5201] [--bind 0.0.0.0]
#   ./bandwidth-test.sh client <server-ip> [options]
#
# Client options:
#   --port    PORT     Server port (default: 5201)
#   --time    SECS     Test duration (default: 10)
#   --streams N        Parallel streams (default: 1)
#   --udp              UDP mode (default: TCP)
#   --bandwidth RATE   Target bandwidth for UDP (default: 1G)
#   --reverse          Reverse mode (server sends to client)
#   --bidir            Bidirectional test
#   --report   FILE    Save results to file
#   --multi            Run progressive multi-stream test (1,2,4,8 streams)
#
# Examples:
#   ./bandwidth-test.sh server                              # start server
#   ./bandwidth-test.sh client 10.0.0.1                     # basic TCP test
#   ./bandwidth-test.sh client 10.0.0.1 --streams 4 --time 30
#   ./bandwidth-test.sh client 10.0.0.1 --udp --bandwidth 500M
#   ./bandwidth-test.sh client 10.0.0.1 --multi --report results.txt
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Defaults
PORT=5201
BIND="0.0.0.0"
TIME=10
STREAMS=1
UDP=false
BANDWIDTH="1G"
REVERSE=false
BIDIR=false
REPORT_FILE=""
MULTI=false

msg()  { echo -e "${CYAN}→${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1" >&2; }
die()  { err "$1"; exit 1; }

check_iperf3() {
    if ! command -v iperf3 &>/dev/null; then
        die "iperf3 not found. Install with: apt install iperf3 / dnf install iperf3"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Server mode
# ─────────────────────────────────────────────────────────────────────────────

run_server() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║              iperf3 Bandwidth Test Server                    ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    msg "Starting iperf3 server on ${BIND}:${PORT}..."
    msg "Press Ctrl+C to stop"
    echo ""
    iperf3 -s -p "$PORT" -B "$BIND"
}

# ─────────────────────────────────────────────────────────────────────────────
# Client mode
# ─────────────────────────────────────────────────────────────────────────────

run_single_test() {
    local server="$1"
    local streams="$2"
    local label="$3"

    local args=(-c "$server" -p "$PORT" -t "$TIME" -P "$streams")

    if $UDP; then
        args+=(-u -b "$BANDWIDTH")
    fi

    if $REVERSE; then
        args+=(-R)
    fi

    if $BIDIR; then
        args+=(--bidir)
    fi

    echo -e "\n${BOLD}${CYAN}── $label ──${NC}"
    echo -e "  Server: $server:$PORT | Duration: ${TIME}s | Streams: $streams | Protocol: $($UDP && echo UDP || echo TCP)"
    echo ""

    local output
    output=$(iperf3 "${args[@]}" 2>&1) || {
        err "Test failed. Server not reachable or iperf3 error."
        echo "$output"
        return 1
    }

    echo "$output"

    # Extract summary line
    local summary
    summary=$(echo "$output" | grep -E "^\[.*(SUM|0)\].*sender" | tail -1)
    if [[ -n "$summary" ]]; then
        echo ""
        ok "Result: $(echo "$summary" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i; print ""}')"
    fi

    # Append to report if specified
    if [[ -n "$REPORT_FILE" ]]; then
        {
            echo "=== $label ==="
            echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Server: $server:$PORT | Streams: $streams | Protocol: $($UDP && echo UDP || echo TCP)"
            echo "$output"
            echo ""
        } >> "$REPORT_FILE"
    fi
}

run_client() {
    local server="$1"

    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║              iperf3 Bandwidth Test Client                    ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Pre-flight check
    msg "Testing connectivity to $server:$PORT..."
    if ! timeout 5 bash -c "echo >/dev/tcp/$server/$PORT" 2>/dev/null; then
        die "Cannot connect to $server:$PORT — is the iperf3 server running?"
    fi
    ok "Server reachable"

    if [[ -n "$REPORT_FILE" ]]; then
        msg "Results will be saved to: $REPORT_FILE"
        {
            echo "Bandwidth Test Report"
            echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "Host: $(hostname)"
            echo "Server: $server"
            echo "================================"
            echo ""
        } > "$REPORT_FILE"
    fi

    if $MULTI; then
        # Progressive multi-stream test
        msg "Running progressive multi-stream test..."
        for streams in 1 2 4 8; do
            run_single_test "$server" "$streams" "TCP ${streams}-stream test"
            # Brief pause between tests
            [[ $streams -lt 8 ]] && sleep 2
        done

        if ! $UDP; then
            # Also run a UDP test
            UDP=true
            run_single_test "$server" 1 "UDP 1-stream test"
            UDP=false
        fi

        echo ""
        echo -e "${BOLD}${GREEN}━━━ Multi-stream test complete ━━━${NC}"
    else
        local proto=$($UDP && echo "UDP" || echo "TCP")
        run_single_test "$server" "$STREAMS" "${proto} ${STREAMS}-stream test"
    fi

    if [[ -n "$REPORT_FILE" ]]; then
        echo ""
        ok "Full report saved to: $REPORT_FILE"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    head -24 "$0" | tail -23
    exit 0
}

main() {
    check_iperf3

    [[ $# -lt 1 ]] && usage

    local mode="$1"
    shift

    case "$mode" in
        server)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port) PORT="$2"; shift 2 ;;
                    --bind) BIND="$2"; shift 2 ;;
                    -h|--help) usage ;;
                    *) die "Unknown server option: $1" ;;
                esac
            done
            run_server
            ;;
        client)
            [[ $# -lt 1 ]] && die "Client mode requires server IP. Usage: $0 client <server-ip>"
            local server="$1"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)      PORT="$2"; shift 2 ;;
                    --time)      TIME="$2"; shift 2 ;;
                    --streams)   STREAMS="$2"; shift 2 ;;
                    --udp)       UDP=true; shift ;;
                    --bandwidth) BANDWIDTH="$2"; shift 2 ;;
                    --reverse)   REVERSE=true; shift ;;
                    --bidir)     BIDIR=true; shift ;;
                    --report)    REPORT_FILE="$2"; shift 2 ;;
                    --multi)     MULTI=true; shift ;;
                    -h|--help)   usage ;;
                    *) die "Unknown client option: $1" ;;
                esac
            done
            run_client "$server"
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown mode: $mode. Use 'server' or 'client'."
            ;;
    esac
}

main "$@"
