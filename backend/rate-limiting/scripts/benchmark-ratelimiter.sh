#!/usr/bin/env bash
# benchmark-ratelimiter.sh — Load test a rate-limited endpoint using wrk or hey.
#
# Usage:
#   ./benchmark-ratelimiter.sh [OPTIONS]
#
# Options:
#   -u, --url URL          Target URL (default: http://localhost:3000/api/test)
#   -c, --connections N    Number of concurrent connections (default: 50)
#   -d, --duration SECS    Test duration in seconds (default: 30)
#   -r, --rate N           Target request rate per second (hey only, default: 200)
#   -t, --tool TOOL        Load testing tool: wrk or hey (default: auto-detect)
#   -o, --output FILE      Write raw results to file
#   -h, --help             Show this help message

set -euo pipefail

# Defaults
URL="http://localhost:3000/api/test"
CONNECTIONS=50
DURATION=30
RATE=200
TOOL=""
OUTPUT=""

usage() {
    sed -n '3,13p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url) URL="$2"; shift 2 ;;
        -c|--connections) CONNECTIONS="$2"; shift 2 ;;
        -d|--duration) DURATION="$2"; shift 2 ;;
        -r|--rate) RATE="$2"; shift 2 ;;
        -t|--tool) TOOL="$2"; shift 2 ;;
        -o|--output) OUTPUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Auto-detect tool
if [[ -z "$TOOL" ]]; then
    if command -v wrk &>/dev/null; then
        TOOL="wrk"
    elif command -v hey &>/dev/null; then
        TOOL="hey"
    else
        echo "ERROR: Neither 'wrk' nor 'hey' found. Install one:"
        echo "  wrk:  apt install wrk  /  brew install wrk"
        echo "  hey:  go install github.com/rakyll/hey@latest"
        exit 1
    fi
fi

echo "============================================"
echo "  Rate Limiter Benchmark"
echo "============================================"
echo "  Tool:        $TOOL"
echo "  URL:         $URL"
echo "  Connections: $CONNECTIONS"
echo "  Duration:    ${DURATION}s"
[[ "$TOOL" == "hey" ]] && echo "  Target Rate: ${RATE} req/s"
echo "============================================"
echo ""

# Verify the target is reachable
if ! curl -sf -o /dev/null --connect-timeout 5 "$URL" 2>/dev/null; then
    echo "WARNING: Target $URL is not reachable or returned an error."
    echo "Proceeding anyway..."
    echo ""
fi

run_wrk() {
    local wrk_script
    wrk_script=$(mktemp /tmp/wrk_ratelimit_XXXXXX.lua)

    cat > "$wrk_script" <<'LUASCRIPT'
-- Track response status codes
local status_counts = {}
local total_requests = 0

function response(status, headers, body)
    total_requests = total_requests + 1
    status_counts[status] = (status_counts[status] or 0) + 1
end

function done(summary, latency, requests)
    io.write("\n--- Rate Limit Analysis ---\n")
    io.write(string.format("Total Requests:  %d\n", total_requests))
    io.write(string.format("Avg Latency:     %.2f ms\n", latency.mean / 1000))
    io.write(string.format("P50 Latency:     %.2f ms\n", latency:percentile(50) / 1000))
    io.write(string.format("P99 Latency:     %.2f ms\n", latency:percentile(99) / 1000))
    io.write(string.format("Max Latency:     %.2f ms\n", latency.max / 1000))
    io.write("\nStatus Code Distribution:\n")

    local codes = {}
    for code, _ in pairs(status_counts) do
        table.insert(codes, code)
    end
    table.sort(codes)

    for _, code in ipairs(codes) do
        local count = status_counts[code]
        local pct = (count / total_requests) * 100
        io.write(string.format("  %d: %d (%.1f%%)\n", code, count, pct))
    end

    local rejected = status_counts[429] or 0
    local success = total_requests - rejected
    io.write(string.format("\nAllowed:  %d (%.1f%%)\n", success, (success/total_requests)*100))
    io.write(string.format("Rejected: %d (%.1f%%)\n", rejected, (rejected/total_requests)*100))
end
LUASCRIPT

    echo "Running: wrk -t4 -c${CONNECTIONS} -d${DURATION}s -s $wrk_script $URL"
    echo ""

    if [[ -n "$OUTPUT" ]]; then
        wrk -t4 -c"${CONNECTIONS}" -d"${DURATION}s" -s "$wrk_script" "$URL" 2>&1 | tee "$OUTPUT"
    else
        wrk -t4 -c"${CONNECTIONS}" -d"${DURATION}s" -s "$wrk_script" "$URL"
    fi

    rm -f "$wrk_script"
}

run_hey() {
    echo "Running: hey -c ${CONNECTIONS} -z ${DURATION}s -q ${RATE} $URL"
    echo ""

    local tmpfile
    tmpfile=$(mktemp /tmp/hey_results_XXXXXX.txt)

    hey -c "${CONNECTIONS}" -z "${DURATION}s" -q "${RATE}" "$URL" > "$tmpfile" 2>&1

    cat "$tmpfile"

    echo ""
    echo "--- Rate Limit Analysis ---"

    local total ok rejected
    total=$(grep -c "^" "$tmpfile" 2>/dev/null || echo "0")
    ok=$(grep -oP '\[200\]\s+\K\d+' "$tmpfile" 2>/dev/null || echo "0")
    rejected=$(grep -oP '\[429\]\s+\K\d+' "$tmpfile" 2>/dev/null || echo "0")

    if grep -q "Status code distribution" "$tmpfile"; then
        echo "Status codes extracted from hey output above."
        if [[ "$rejected" -gt 0 ]]; then
            echo "429 responses detected — rate limiter is active."
        else
            echo "No 429 responses — rate limiter may not be triggered at this rate."
        fi
    fi

    if [[ -n "$OUTPUT" ]]; then
        cp "$tmpfile" "$OUTPUT"
    fi

    rm -f "$tmpfile"
}

# Run the benchmark
case "$TOOL" in
    wrk) run_wrk ;;
    hey) run_hey ;;
    *) echo "Unknown tool: $TOOL"; exit 1 ;;
esac

echo ""
echo "============================================"
echo "  Benchmark Complete"
echo "============================================"
