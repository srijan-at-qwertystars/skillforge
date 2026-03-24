#!/bin/bash
# race-detector.sh — Run comprehensive race detection across a Go project
#
# Usage:
#   ./race-detector.sh [path]          # default: current directory
#   ./race-detector.sh ./cmd/server
#   ./race-detector.sh ./...           # all packages
#
# Runs go test -race, go vet, and parses output into a summary with
# file locations and suggested fixes.

set -euo pipefail

TARGET="${1:-./...}"
REPORT_FILE="race-report-$(date +%Y%m%d-%H%M%S).txt"
RACE_LOG=$(mktemp)
VET_LOG=$(mktemp)
EXIT_CODE=0

cleanup() {
    rm -f "$RACE_LOG" "$VET_LOG"
}
trap cleanup EXIT

echo "============================================="
echo " Go Race & Vet Analysis"
echo " Target: $TARGET"
echo " Date:   $(date)"
echo "============================================="
echo ""

# --- Step 1: go vet ---
echo "--- [1/3] Running go vet ---"
if go vet "$TARGET" > "$VET_LOG" 2>&1; then
    echo "  ✓ go vet: no issues found"
    VET_ISSUES=0
else
    VET_ISSUES=$(grep -c "^" "$VET_LOG" 2>/dev/null || echo "0")
    echo "  ✗ go vet: $VET_ISSUES issue(s) found"
    EXIT_CODE=1
fi
echo ""

# --- Step 2: go test -race ---
echo "--- [2/3] Running go test -race ---"
GORACE="halt_on_error=0 history_size=3" go test -race -count=1 -timeout=10m "$TARGET" > "$RACE_LOG" 2>&1 || true

RACE_COUNT=$(grep -c "^WARNING: DATA RACE" "$RACE_LOG" 2>/dev/null || echo "0")
TEST_FAILURES=$(grep -c "^--- FAIL:" "$RACE_LOG" 2>/dev/null || echo "0")
TEST_PASSES=$(grep -c "^--- PASS:" "$RACE_LOG" 2>/dev/null || echo "0")
TEST_SKIPS=$(grep -c "^--- SKIP:" "$RACE_LOG" 2>/dev/null || echo "0")

echo "  Tests passed:  $TEST_PASSES"
echo "  Tests failed:  $TEST_FAILURES"
echo "  Tests skipped: $TEST_SKIPS"
echo "  Data races:    $RACE_COUNT"

if [[ "$RACE_COUNT" -gt 0 ]]; then
    EXIT_CODE=1
fi
if [[ "$TEST_FAILURES" -gt 0 ]]; then
    EXIT_CODE=1
fi
echo ""

# --- Step 3: Parse and summarize ---
echo "--- [3/3] Summary ---"
echo ""

# Parse vet issues
if [[ "$VET_ISSUES" -gt 0 ]]; then
    echo "=== go vet Issues ==="
    while IFS= read -r line; do
        FILE=$(echo "$line" | grep -oP '^[^:]+:[0-9]+' || true)
        if [[ -n "$FILE" ]]; then
            echo "  📍 $line"
            # Suggest fix based on common vet warnings
            if echo "$line" | grep -q "copies lock"; then
                echo "     Fix: Use pointer receiver or don't copy the struct containing a Mutex"
            elif echo "$line" | grep -q "unreachable code"; then
                echo "     Fix: Remove code after return/break/continue statement"
            elif echo "$line" | grep -q "printf"; then
                echo "     Fix: Check format string argument count and types"
            fi
        fi
    done < "$VET_LOG"
    echo ""
fi

# Parse race conditions
if [[ "$RACE_COUNT" -gt 0 ]]; then
    echo "=== Data Races ==="
    RACE_NUM=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "^WARNING: DATA RACE"; then
            RACE_NUM=$((RACE_NUM + 1))
            echo ""
            echo "  Race #$RACE_NUM:"
        fi
        # Extract file locations
        FILE_LINE=$(echo "$line" | grep -oP '\S+\.go:[0-9]+' || true)
        if [[ -n "$FILE_LINE" ]]; then
            echo "    📍 $FILE_LINE"
        fi
        # Extract access type
        if echo "$line" | grep -qP "^(Read|Write|Previous (read|write)) at"; then
            echo "    $line"
        fi
    done < "$RACE_LOG"

    echo ""
    echo "  Common fixes for data races:"
    echo "    • Protect shared variables with sync.Mutex or sync.RWMutex"
    echo "    • Use atomic operations (sync/atomic) for simple counters/flags"
    echo "    • Use channels to communicate instead of sharing memory"
    echo "    • Use sync.Map for concurrent map access"
    echo "    • Use errgroup to collect results safely"
    echo ""
fi

# Parse test failures
if [[ "$TEST_FAILURES" -gt 0 ]]; then
    echo "=== Test Failures ==="
    grep -A 5 "^--- FAIL:" "$RACE_LOG" | head -50
    echo ""
fi

# Final status
echo "============================================="
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo " ✅ All clear — no races or vet issues found"
else
    echo " ❌ Issues found — see details above"
    echo ""
    echo " Full race log: $RACE_LOG saved to $REPORT_FILE"
    cp "$RACE_LOG" "$REPORT_FILE"
fi
echo "============================================="

exit $EXIT_CODE
