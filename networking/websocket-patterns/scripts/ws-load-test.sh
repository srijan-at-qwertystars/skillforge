#!/usr/bin/env bash
# ws-load-test.sh — WebSocket load testing using websocat or wscat
#
# Usage:
#   ./ws-load-test.sh <ws-url> [options]
#
# Options:
#   -c, --connections NUM    Number of concurrent connections (default: 10)
#   -m, --messages NUM       Messages per connection (default: 100)
#   -d, --delay MS           Delay between messages in ms (default: 100)
#   -p, --payload TEXT       Message payload (default: '{"type":"ping"}')
#   -t, --duration SECS      Test duration in seconds (0 = until messages sent, default: 0)
#   -o, --output FILE        Write results to file
#   -h, --help               Show this help
#
# Examples:
#   ./ws-load-test.sh ws://localhost:8080
#   ./ws-load-test.sh wss://api.example.com/ws -c 50 -m 1000
#   ./ws-load-test.sh ws://localhost:8080 -c 100 -d 50 -t 60

set -euo pipefail

# Defaults
URL=""
CONNECTIONS=10
MESSAGES=100
DELAY_MS=100
PAYLOAD='{"type":"ping"}'
DURATION=0
OUTPUT=""
TOOL=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \?//'
    exit 0
}

log() { echo -e "${CYAN}[ws-load-test]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()  { echo -e "${GREEN}[OK]${NC} $*"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--connections) CONNECTIONS="$2"; shift 2 ;;
        -m|--messages)    MESSAGES="$2"; shift 2 ;;
        -d|--delay)       DELAY_MS="$2"; shift 2 ;;
        -p|--payload)     PAYLOAD="$2"; shift 2 ;;
        -t|--duration)    DURATION="$2"; shift 2 ;;
        -o|--output)      OUTPUT="$2"; shift 2 ;;
        -h|--help)        usage ;;
        -*)               err "Unknown option: $1"; usage ;;
        *)                URL="$1"; shift ;;
    esac
done

if [[ -z "$URL" ]]; then
    err "WebSocket URL is required"
    usage
fi

# Detect available tool
detect_tool() {
    if command -v websocat &>/dev/null; then
        TOOL="websocat"
    elif command -v wscat &>/dev/null; then
        TOOL="wscat"
    elif npx --yes wscat --version &>/dev/null 2>&1; then
        TOOL="npx-wscat"
    else
        err "No WebSocket client found. Install one of:"
        err "  cargo install websocat"
        err "  npm install -g wscat"
        exit 1
    fi
    log "Using tool: ${YELLOW}${TOOL}${NC}"
}

# Results tracking
RESULTS_DIR=$(mktemp -d)
trap 'rm -rf "$RESULTS_DIR"' EXIT

# Run a single connection test
run_connection() {
    local conn_id=$1
    local result_file="${RESULTS_DIR}/conn_${conn_id}.log"
    local start_time
    local end_time
    local msgs_sent=0
    local msgs_recv=0

    start_time=$(date +%s%N)

    case $TOOL in
        websocat)
            # Generate messages and pipe to websocat
            (
                for ((i = 1; i <= MESSAGES; i++)); do
                    echo "$PAYLOAD"
                    sleep "$(echo "scale=3; $DELAY_MS/1000" | bc)"
                done
            ) | timeout $((DURATION > 0 ? DURATION : MESSAGES * DELAY_MS / 1000 + 30)) \
                websocat --no-close "$URL" 2>/dev/null | head -n "$MESSAGES" > "${RESULTS_DIR}/recv_${conn_id}.log" &
            local pid=$!
            wait $pid 2>/dev/null || true
            msgs_sent=$MESSAGES
            msgs_recv=$(wc -l < "${RESULTS_DIR}/recv_${conn_id}.log" 2>/dev/null || echo 0)
            ;;
        wscat|npx-wscat)
            local wscat_cmd="wscat"
            [[ "$TOOL" == "npx-wscat" ]] && wscat_cmd="npx --yes wscat"
            (
                for ((i = 1; i <= MESSAGES; i++)); do
                    echo "$PAYLOAD"
                    sleep "$(echo "scale=3; $DELAY_MS/1000" | bc)"
                done
            ) | timeout $((DURATION > 0 ? DURATION : MESSAGES * DELAY_MS / 1000 + 30)) \
                $wscat_cmd -c "$URL" 2>/dev/null | head -n "$MESSAGES" > "${RESULTS_DIR}/recv_${conn_id}.log" &
            local pid=$!
            wait $pid 2>/dev/null || true
            msgs_sent=$MESSAGES
            msgs_recv=$(wc -l < "${RESULTS_DIR}/recv_${conn_id}.log" 2>/dev/null || echo 0)
            ;;
    esac

    end_time=$(date +%s%N)
    local elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "${conn_id},${msgs_sent},${msgs_recv},${elapsed_ms}" >> "$result_file"
    log "Connection ${conn_id}: sent=${msgs_sent} recv=${msgs_recv} time=${elapsed_ms}ms"
}

# Main
detect_tool

echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "WebSocket Load Test"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "URL:            ${YELLOW}${URL}${NC}"
log "Connections:    ${YELLOW}${CONNECTIONS}${NC}"
log "Msgs/conn:      ${YELLOW}${MESSAGES}${NC}"
log "Delay:          ${YELLOW}${DELAY_MS}ms${NC}"
log "Total messages: ${YELLOW}$((CONNECTIONS * MESSAGES))${NC}"
[[ $DURATION -gt 0 ]] && log "Duration:       ${YELLOW}${DURATION}s${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

GLOBAL_START=$(date +%s%N)

# Launch connections in parallel
pids=()
for ((i = 1; i <= CONNECTIONS; i++)); do
    run_connection "$i" &
    pids+=($!)

    # Stagger connections slightly to avoid thundering herd
    if (( i % 10 == 0 )); then
        sleep 0.1
    fi
done

# Wait for all connections
for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

GLOBAL_END=$(date +%s%N)
TOTAL_MS=$(( (GLOBAL_END - GLOBAL_START) / 1000000 ))

# Aggregate results
total_sent=0
total_recv=0
total_time=0
conn_count=0

for f in "${RESULTS_DIR}"/conn_*.log; do
    [[ -f "$f" ]] || continue
    while IFS=',' read -r id sent recv elapsed; do
        total_sent=$((total_sent + sent))
        total_recv=$((total_recv + recv))
        total_time=$((total_time + elapsed))
        conn_count=$((conn_count + 1))
    done < "$f"
done

avg_time=0
if [[ $conn_count -gt 0 ]]; then
    avg_time=$((total_time / conn_count))
fi

throughput=0
if [[ $TOTAL_MS -gt 0 ]]; then
    throughput=$(echo "scale=2; $total_sent * 1000 / $TOTAL_MS" | bc)
fi

echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "${GREEN}Results${NC}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Connections:    ${conn_count}"
log "Messages sent:  ${total_sent}"
log "Messages recv:  ${total_recv}"
log "Total time:     ${TOTAL_MS}ms"
log "Avg conn time:  ${avg_time}ms"
log "Throughput:     ${throughput} msg/sec"
log "Loss rate:      $(echo "scale=2; ($total_sent - $total_recv) * 100 / ($total_sent + 1)" | bc)%"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Write output file if requested
if [[ -n "$OUTPUT" ]]; then
    {
        echo "# WebSocket Load Test Results"
        echo "# URL: ${URL}"
        echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Connections: ${CONNECTIONS}, Messages/conn: ${MESSAGES}, Delay: ${DELAY_MS}ms"
        echo ""
        echo "connections,${conn_count}"
        echo "messages_sent,${total_sent}"
        echo "messages_received,${total_recv}"
        echo "total_time_ms,${TOTAL_MS}"
        echo "avg_conn_time_ms,${avg_time}"
        echo "throughput_msg_per_sec,${throughput}"
    } > "$OUTPUT"
    ok "Results written to ${OUTPUT}"
fi
