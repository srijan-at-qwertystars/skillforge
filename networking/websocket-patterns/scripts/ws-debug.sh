#!/usr/bin/env bash
# ws-debug.sh — WebSocket debugging tool that logs all frames with timestamps
#
# Usage:
#   ./ws-debug.sh <ws-url> [options]
#
# Options:
#   -H, --header KEY:VAL     Add custom header (can be repeated)
#   -s, --send TEXT           Send a message after connecting
#   -f, --file PATH          Send messages from file (one per line)
#   -i, --interactive        Interactive mode (type messages to send)
#   -b, --binary             Expect binary frames (show hex dump)
#   -j, --json               Pretty-print JSON messages
#   -q, --quiet              Suppress connection info, show only frames
#   -l, --log FILE           Log all frames to file
#   -t, --timeout SECS       Disconnect after N seconds (default: 0 = never)
#   -p, --ping SECS          Send ping every N seconds
#   -h, --help               Show this help
#
# Examples:
#   ./ws-debug.sh wss://api.example.com/ws
#   ./ws-debug.sh ws://localhost:8080 -j -s '{"type":"subscribe","channel":"updates"}'
#   ./ws-debug.sh wss://api.example.com/ws -H "Authorization:Bearer tok123" -j
#   ./ws-debug.sh ws://localhost:8080 -i -j -l debug.log

set -euo pipefail

# Defaults
URL=""
HEADERS=()
SEND_MSGS=()
SEND_FILE=""
INTERACTIVE=false
BINARY=false
JSON_PRETTY=false
QUIET=false
LOG_FILE=""
TIMEOUT=0
PING_INTERVAL=0
TOOL=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
NC='\033[0m'

usage() {
    sed -n '3,18p' "$0" | sed 's/^# \?//'
    exit 0
}

timestamp() {
    date '+%H:%M:%S.%3N'
}

log_frame() {
    local direction=$1
    local data=$2
    local ts
    ts=$(timestamp)

    local arrow color
    if [[ "$direction" == "recv" ]]; then
        arrow="↓ RECV"
        color=$GREEN
    else
        arrow="↑ SEND"
        color=$MAGENTA
    fi

    local formatted="$data"
    if $JSON_PRETTY; then
        # Try to pretty-print JSON, fall back to raw
        formatted=$(echo "$data" | python3 -m json.tool 2>/dev/null || echo "$data")
    fi

    if $BINARY; then
        formatted=$(echo -n "$data" | xxd -l 256)
    fi

    echo -e "${DIM}${ts}${NC} ${color}${arrow}${NC} ${formatted}"

    if [[ -n "$LOG_FILE" ]]; then
        echo "[${ts}] ${direction}: ${data}" >> "$LOG_FILE"
    fi
}

info() {
    if ! $QUIET; then
        echo -e "${CYAN}[ws-debug]${NC} $*"
    fi
}

err() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -H|--header)      HEADERS+=("$2"); shift 2 ;;
        -s|--send)        SEND_MSGS+=("$2"); shift 2 ;;
        -f|--file)        SEND_FILE="$2"; shift 2 ;;
        -i|--interactive) INTERACTIVE=true; shift ;;
        -b|--binary)      BINARY=true; shift ;;
        -j|--json)        JSON_PRETTY=true; shift ;;
        -q|--quiet)       QUIET=true; shift ;;
        -l|--log)         LOG_FILE="$2"; shift 2 ;;
        -t|--timeout)     TIMEOUT="$2"; shift 2 ;;
        -p|--ping)        PING_INTERVAL="$2"; shift 2 ;;
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

info "Using tool: ${YELLOW}${TOOL}${NC}"
info "Connecting to: ${YELLOW}${URL}${NC}"
[[ ${#HEADERS[@]} -gt 0 ]] && info "Headers: ${HEADERS[*]}"
echo ""

# Initialize log file
if [[ -n "$LOG_FILE" ]]; then
    {
        echo "# WebSocket Debug Log"
        echo "# URL: ${URL}"
        echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Tool: ${TOOL}"
        echo ""
    } > "$LOG_FILE"
    info "Logging to: ${LOG_FILE}"
fi

# Build tool command
build_websocat_cmd() {
    local cmd="websocat"
    for h in "${HEADERS[@]+"${HEADERS[@]}"}"; do
        cmd+=" --header \"${h}\""
    done
    cmd+=" \"${URL}\""
    echo "$cmd"
}

build_wscat_cmd() {
    local cmd="wscat"
    [[ "$TOOL" == "npx-wscat" ]] && cmd="npx --yes wscat"
    for h in "${HEADERS[@]+"${HEADERS[@]}"}"; do
        cmd+=" --header \"${h}\""
    done
    cmd+=" -c \"${URL}\""
    echo "$cmd"
}

# Create a named pipe for sending messages
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap 'rm -f "$FIFO"' EXIT

# Prepare input
prepare_input() {
    # Send initial messages
    for msg in "${SEND_MSGS[@]+"${SEND_MSGS[@]}"}"; do
        echo "$msg"
        log_frame "send" "$msg"
        sleep 0.1
    done

    # Send messages from file
    if [[ -n "$SEND_FILE" && -f "$SEND_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            echo "$line"
            log_frame "send" "$line"
            sleep 0.1
        done < "$SEND_FILE"
    fi

    # Periodic ping
    if [[ $PING_INTERVAL -gt 0 ]]; then
        while true; do
            sleep "$PING_INTERVAL"
            local ping_msg='{"type":"ping","t":'$(date +%s%N)'}'
            echo "$ping_msg"
            log_frame "send" "$ping_msg"
        done &
        PING_PID=$!
    fi

    # Interactive mode
    if $INTERACTIVE; then
        info "Interactive mode — type messages and press Enter to send. Ctrl+C to quit."
        echo ""
        while IFS= read -r line; do
            echo "$line"
            log_frame "send" "$line"
        done
    else
        # Keep the pipe open if not interactive
        if [[ $TIMEOUT -gt 0 ]]; then
            sleep "$TIMEOUT"
        else
            # Block until interrupted
            while true; do sleep 3600; done
        fi
    fi
}

# Start the connection
connect_and_log() {
    local cmd
    case $TOOL in
        websocat)   cmd=$(build_websocat_cmd) ;;
        wscat|npx-wscat) cmd=$(build_wscat_cmd) ;;
    esac

    info "Connected ✓"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ -n "$LOG_FILE" ]] && echo "" >> "$LOG_FILE"

    # Read from FIFO, pipe to ws tool, process output
    eval "$cmd" < "$FIFO" 2>/dev/null | while IFS= read -r line; do
        log_frame "recv" "$line"
    done

    info ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Connection closed"
    [[ -n "$LOG_FILE" ]] && echo "# Connection closed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG_FILE"
}

# Handle Ctrl+C gracefully
cleanup() {
    echo ""
    info "Disconnecting..."
    [[ -n "${PING_PID:-}" ]] && kill "$PING_PID" 2>/dev/null || true
    rm -f "$FIFO"
    exit 0
}
trap cleanup INT TERM

# Run
prepare_input > "$FIFO" &
INPUT_PID=$!

connect_and_log

# Cleanup
kill "$INPUT_PID" 2>/dev/null || true
[[ -n "${PING_PID:-}" ]] && kill "$PING_PID" 2>/dev/null || true
