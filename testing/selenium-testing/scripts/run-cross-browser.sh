#!/usr/bin/env bash
# ============================================================================
# run-cross-browser.sh — Run Selenium test suite across browsers in parallel
#
# Executes tests against Chrome, Firefox, and Edge simultaneously using
# Selenium Grid. Supports pytest (Python) and Maven (Java) test runners.
#
# Usage:
#   ./run-cross-browser.sh [OPTIONS]
#
# Options:
#   --grid-url URL       Selenium Grid URL (default: http://localhost:4444)
#   --browsers LIST      Comma-separated browser list (default: chrome,firefox,edge)
#   --test-dir DIR       Test directory (default: tests/)
#   --runner RUNNER      Test runner: pytest or maven (default: pytest)
#   --parallel N         Tests per browser in parallel (default: 2)
#   --markers MARKERS    pytest markers to run (e.g., "smoke")
#   --report-dir DIR     Report output directory (default: reports/)
#   --timeout SECONDS    Per-browser timeout (default: 600)
#   --fail-fast          Stop all on first browser failure
#   --help               Show this help
#
# Examples:
#   ./run-cross-browser.sh --grid-url http://localhost:4444
#   ./run-cross-browser.sh --browsers chrome,firefox --markers smoke
#   ./run-cross-browser.sh --runner maven --test-dir src/test/java
#   ./run-cross-browser.sh --browsers chrome --parallel 4 --fail-fast
#
# Requirements:
#   - Running Selenium Grid (use setup-selenium-grid.sh)
#   - pytest + selenium (Python) or Maven (Java)
# ============================================================================

set -euo pipefail

GRID_URL="http://localhost:4444"
BROWSERS="chrome,firefox,edge"
TEST_DIR="tests/"
RUNNER="pytest"
PARALLEL=2
MARKERS=""
REPORT_DIR="reports"
TIMEOUT=600
FAIL_FAST=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --grid-url)    GRID_URL="$2"; shift 2 ;;
        --browsers)    BROWSERS="$2"; shift 2 ;;
        --test-dir)    TEST_DIR="$2"; shift 2 ;;
        --runner)      RUNNER="$2"; shift 2 ;;
        --parallel)    PARALLEL="$2"; shift 2 ;;
        --markers)     MARKERS="$2"; shift 2 ;;
        --report-dir)  REPORT_DIR="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --fail-fast)   FAIL_FAST=true; shift ;;
        --help)        head -28 "$0" | tail -26; exit 0 ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$REPORT_DIR"

# Check Grid is reachable
echo "Checking Selenium Grid at ${GRID_URL}..."
if ! curl -s "${GRID_URL}/status" | grep -q '"ready":true' 2>/dev/null; then
    echo "Error: Selenium Grid not ready at ${GRID_URL}"
    echo "Start it with: ./setup-selenium-grid.sh hub-node"
    exit 1
fi

# Show Grid info
GRID_INFO=$(curl -s "${GRID_URL}/status")
NODE_COUNT=$(echo "$GRID_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('value',{}).get('nodes',[])))" 2>/dev/null || echo "?")
echo "Grid is ready — ${NODE_COUNT} node(s) available"
echo ""

IFS=',' read -ra BROWSER_LIST <<< "$BROWSERS"
PIDS=()
RESULTS=()
BROWSER_NAMES=()

run_pytest() {
    local browser=$1
    local report_file="${REPORT_DIR}/${browser}-results.xml"
    local log_file="${REPORT_DIR}/${browser}.log"
    local marker_flag=""
    if [[ -n "$MARKERS" ]]; then
        marker_flag="-m ${MARKERS}"
    fi

    echo "[${browser}] Starting pytest..."
    timeout "$TIMEOUT" python3 -m pytest "$TEST_DIR" \
        --browser "$browser" \
        --grid-url "$GRID_URL" \
        -n "$PARALLEL" \
        --junitxml="$report_file" \
        $marker_flag \
        -v \
        2>&1 | tee "$log_file"
    return ${PIPESTATUS[0]}
}

run_maven() {
    local browser=$1
    local log_file="${REPORT_DIR}/${browser}.log"

    echo "[${browser}] Starting Maven tests..."
    timeout "$TIMEOUT" mvn test \
        -Dbrowser="$browser" \
        -DgridUrl="$GRID_URL" \
        -Dparallel=methods \
        -DthreadCount="$PARALLEL" \
        -Dsurefire.reportDirectory="${REPORT_DIR}/${browser}" \
        2>&1 | tee "$log_file"
    return ${PIPESTATUS[0]}
}

echo "============================================"
echo " Cross-Browser Test Execution"
echo "============================================"
echo " Grid:      ${GRID_URL}"
echo " Browsers:  ${BROWSERS}"
echo " Runner:    ${RUNNER}"
echo " Parallel:  ${PARALLEL} per browser"
echo " Reports:   ${REPORT_DIR}/"
echo "============================================"
echo ""

START_TIME=$(date +%s)

for browser in "${BROWSER_LIST[@]}"; do
    browser=$(echo "$browser" | xargs)  # trim whitespace
    BROWSER_NAMES+=("$browser")

    (
        if [[ "$RUNNER" == "pytest" ]]; then
            run_pytest "$browser"
        elif [[ "$RUNNER" == "maven" ]]; then
            run_maven "$browser"
        else
            echo "Error: unsupported runner '${RUNNER}'"
            exit 1
        fi
    ) &
    PIDS+=($!)
    echo "[${browser}] Launched (PID: ${PIDS[-1]})"
done

echo ""
echo "Waiting for all browsers to complete..."
echo ""

OVERALL_EXIT=0

for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    browser="${BROWSER_NAMES[$i]}"

    if wait "$pid"; then
        RESULTS+=("PASS")
        echo "[${browser}] ✅ PASSED"
    else
        RESULTS+=("FAIL")
        echo "[${browser}] ❌ FAILED"
        OVERALL_EXIT=1
        if [[ "$FAIL_FAST" == "true" ]]; then
            echo "Fail-fast: stopping remaining browsers..."
            for remaining_pid in "${PIDS[@]}"; do
                kill "$remaining_pid" 2>/dev/null || true
            done
            break
        fi
    fi
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "============================================"
echo " Results Summary"
echo "============================================"
for i in "${!BROWSER_NAMES[@]}"; do
    result="${RESULTS[$i]:-CANCELLED}"
    icon="❌"
    [[ "$result" == "PASS" ]] && icon="✅"
    echo "  ${icon} ${BROWSER_NAMES[$i]}: ${result}"
done
echo ""
echo "  Duration: ${DURATION}s"
echo "  Reports:  ${REPORT_DIR}/"
echo "============================================"

# Generate summary report
cat > "${REPORT_DIR}/summary.json" << SUMMARY
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "grid_url": "${GRID_URL}",
    "duration_seconds": ${DURATION},
    "browsers": [
$(for i in "${!BROWSER_NAMES[@]}"; do
    result="${RESULTS[$i]:-CANCELLED}"
    echo "        {\"name\": \"${BROWSER_NAMES[$i]}\", \"result\": \"${result}\"}"
    [[ $i -lt $((${#BROWSER_NAMES[@]} - 1)) ]] && echo ","
done)
    ],
    "overall": "$([ $OVERALL_EXIT -eq 0 ] && echo PASS || echo FAIL)"
}
SUMMARY

echo "Summary: ${REPORT_DIR}/summary.json"
exit $OVERALL_EXIT
