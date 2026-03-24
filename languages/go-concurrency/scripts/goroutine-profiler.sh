#!/bin/bash
# goroutine-profiler.sh — Profile goroutine usage in a Go application
#
# Usage:
#   ./goroutine-profiler.sh <binary|package> [duration_seconds] [pprof_port]
#
# Examples:
#   ./goroutine-profiler.sh ./cmd/server 30          # profile for 30s
#   ./goroutine-profiler.sh ./cmd/server 60 6060      # custom port
#   ./goroutine-profiler.sh ./bin/myapp 10            # pre-built binary
#
# What it does:
#   1. Builds the binary with pprof enabled (if given a package path)
#   2. Runs the program
#   3. Captures goroutine profiles at intervals
#   4. Generates a goroutine count report
#   5. Identifies potential goroutine leaks
#   6. Produces a CPU profile flamegraph (if go tool pprof available)

set -euo pipefail

TARGET="${1:?Usage: $0 <binary|package> [duration_seconds] [pprof_port]}"
DURATION="${2:-30}"
PPROF_PORT="${3:-6060}"
PPROF_URL="http://localhost:${PPROF_PORT}"
OUTPUT_DIR="goroutine-profile-$(date +%Y%m%d-%H%M%S)"
BINARY=""
PID=""

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        echo "==> Stopping profiled process (PID $PID)..."
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
echo "============================================="
echo " Goroutine Profiler"
echo " Target:   $TARGET"
echo " Duration: ${DURATION}s"
echo " Output:   $OUTPUT_DIR/"
echo "============================================="
echo ""

# --- Step 1: Build if needed ---
if [[ "$TARGET" == ./* ]] && [[ ! -f "$TARGET" ]]; then
    echo "==> Building $TARGET with pprof support..."
    BINARY="$OUTPUT_DIR/profiled-binary"
    go build -o "$BINARY" "$TARGET"
    echo "    Built: $BINARY"
else
    BINARY="$TARGET"
fi

# --- Step 2: Check if pprof endpoint is available ---
echo "==> Checking for pprof endpoint at $PPROF_URL..."

# Try connecting to see if something is already running
if curl -s --connect-timeout 2 "$PPROF_URL/debug/pprof/" > /dev/null 2>&1; then
    echo "    Found running pprof endpoint"
    ALREADY_RUNNING=true
else
    echo "    Starting binary..."
    $BINARY &
    PID=$!
    ALREADY_RUNNING=false
    sleep 2

    if ! kill -0 "$PID" 2>/dev/null; then
        echo "    Error: binary exited immediately"
        exit 1
    fi

    # Wait for pprof to be available
    RETRIES=10
    while ! curl -s --connect-timeout 1 "$PPROF_URL/debug/pprof/" > /dev/null 2>&1; do
        RETRIES=$((RETRIES - 1))
        if [[ $RETRIES -le 0 ]]; then
            echo "    Error: pprof endpoint not available at $PPROF_URL"
            echo "    Ensure your app imports _ \"net/http/pprof\" and serves on port $PPROF_PORT"
            exit 1
        fi
        sleep 1
    done
    echo "    pprof endpoint ready (PID $PID)"
fi
echo ""

# --- Step 3: Capture goroutine profiles over time ---
echo "==> Capturing goroutine profiles over ${DURATION}s..."
INTERVAL=5
SAMPLES=$((DURATION / INTERVAL))
if [[ $SAMPLES -lt 1 ]]; then SAMPLES=1; fi

COUNTS_FILE="$OUTPUT_DIR/goroutine-counts.csv"
echo "timestamp,goroutine_count" > "$COUNTS_FILE"

for i in $(seq 1 "$SAMPLES"); do
    TIMESTAMP=$(date +%H:%M:%S)

    # Get goroutine count
    GOROUTINE_DATA=$(curl -s "$PPROF_URL/debug/pprof/goroutine?debug=1" 2>/dev/null || echo "")
    COUNT=$(echo "$GOROUTINE_DATA" | head -1 | grep -oP 'total \K[0-9]+' || echo "0")

    echo "$TIMESTAMP,$COUNT" >> "$COUNTS_FILE"
    printf "  [%s] goroutines: %s\n" "$TIMESTAMP" "$COUNT"

    # Save full goroutine dump at first and last sample
    if [[ $i -eq 1 ]] || [[ $i -eq "$SAMPLES" ]]; then
        echo "$GOROUTINE_DATA" > "$OUTPUT_DIR/goroutine-dump-sample-${i}.txt"
    fi

    if [[ $i -lt "$SAMPLES" ]]; then
        sleep "$INTERVAL"
    fi
done
echo ""

# --- Step 4: Capture final profiles ---
echo "==> Capturing detailed profiles..."

# Goroutine profile (binary)
curl -s -o "$OUTPUT_DIR/goroutine.pb.gz" "$PPROF_URL/debug/pprof/goroutine" 2>/dev/null || true
echo "    Goroutine profile: $OUTPUT_DIR/goroutine.pb.gz"

# CPU profile (short)
CPU_DURATION=$((DURATION < 10 ? DURATION : 10))
curl -s -o "$OUTPUT_DIR/cpu.pb.gz" "$PPROF_URL/debug/pprof/profile?seconds=${CPU_DURATION}" 2>/dev/null || true
echo "    CPU profile (${CPU_DURATION}s): $OUTPUT_DIR/cpu.pb.gz"

# Heap profile
curl -s -o "$OUTPUT_DIR/heap.pb.gz" "$PPROF_URL/debug/pprof/heap" 2>/dev/null || true
echo "    Heap profile: $OUTPUT_DIR/heap.pb.gz"

# Block profile
curl -s -o "$OUTPUT_DIR/block.pb.gz" "$PPROF_URL/debug/pprof/block" 2>/dev/null || true
echo "    Block profile: $OUTPUT_DIR/block.pb.gz"

echo ""

# --- Step 5: Analyze for potential leaks ---
echo "==> Analyzing for potential goroutine leaks..."

FIRST_COUNT=$(head -2 "$COUNTS_FILE" | tail -1 | cut -d',' -f2)
LAST_COUNT=$(tail -1 "$COUNTS_FILE" | cut -d',' -f2)
GROWTH=$((LAST_COUNT - FIRST_COUNT))

REPORT_FILE="$OUTPUT_DIR/report.txt"
{
    echo "Goroutine Profile Report"
    echo "========================"
    echo "Date:     $(date)"
    echo "Target:   $TARGET"
    echo "Duration: ${DURATION}s"
    echo ""
    echo "Goroutine Count:"
    echo "  Start:  $FIRST_COUNT"
    echo "  End:    $LAST_COUNT"
    echo "  Growth: $GROWTH"
    echo ""

    if [[ $GROWTH -gt 10 ]]; then
        echo "⚠️  WARNING: Goroutine count grew by $GROWTH during profiling."
        echo "   This may indicate a goroutine leak."
        echo ""
        echo "   Common causes:"
        echo "   - Goroutines blocked on channel operations without cancellation"
        echo "   - HTTP client calls without context timeout"
        echo "   - time.After in loops creating uncollected timers"
        echo "   - Background goroutines started without shutdown mechanism"
        echo ""
        echo "   Investigate with:"
        echo "   go tool pprof -http=:8080 $OUTPUT_DIR/goroutine.pb.gz"
    elif [[ $GROWTH -gt 0 ]]; then
        echo "ℹ️  Minor goroutine growth ($GROWTH). Likely normal."
    else
        echo "✅ Goroutine count stable. No leak detected."
    fi

    echo ""
    echo "Top goroutine stacks (from final dump):"
    echo "----------------------------------------"
    if [[ -f "$OUTPUT_DIR/goroutine-dump-sample-${SAMPLES}.txt" ]]; then
        # Extract and count unique goroutine creation points
        grep -oP 'created by .+' "$OUTPUT_DIR/goroutine-dump-sample-${SAMPLES}.txt" 2>/dev/null \
            | sort | uniq -c | sort -rn | head -20
    fi
} > "$REPORT_FILE"

cat "$REPORT_FILE"
echo ""

# --- Step 6: Generate flamegraph commands ---
echo "============================================="
echo " Profile files saved to: $OUTPUT_DIR/"
echo ""
echo " View profiles:"
echo "   go tool pprof -http=:8080 $OUTPUT_DIR/goroutine.pb.gz"
echo "   go tool pprof -http=:8080 $OUTPUT_DIR/cpu.pb.gz"
echo "   go tool pprof -http=:8080 $OUTPUT_DIR/heap.pb.gz"
echo ""
echo " Goroutine count over time:"
echo "   cat $COUNTS_FILE"
echo "============================================="
