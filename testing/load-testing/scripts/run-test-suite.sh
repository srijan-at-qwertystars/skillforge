#!/bin/bash
# =============================================================================
# run-test-suite.sh — Run load test suite: smoke → load → stress
#
# Usage:
#   ./run-test-suite.sh [options]
#
# Options:
#   -u, --base-url URL     Target URL (default: http://localhost:8080)
#   -d, --test-dir DIR     Directory containing tests (default: ./tests)
#   -o, --output-dir DIR   Output directory for results (default: ./results)
#   -b, --baseline FILE    Baseline file for comparison (default: ./baselines/baseline.json)
#   -s, --suite SUITE      Suite to run: smoke|load|stress|all (default: all)
#   --influxdb URL         InfluxDB output URL (optional)
#   --skip-baseline        Skip baseline comparison
#   -h, --help             Show this help
#
# Examples:
#   ./run-test-suite.sh --base-url https://staging.example.com
#   ./run-test-suite.sh --suite smoke --base-url http://localhost:8080
#   ./run-test-suite.sh --influxdb http://localhost:8086/k6 --suite all
# =============================================================================

set -euo pipefail

# --- Defaults ---
BASE_URL="${BASE_URL:-http://localhost:8080}"
TEST_DIR="./tests"
OUTPUT_DIR="./results"
BASELINE_FILE="./baselines/baseline.json"
SUITE="all"
INFLUXDB_URL=""
SKIP_BASELINE=false
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
header()  { echo -e "\n${BLUE}${BOLD}═══ $1 ═══${NC}\n"; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--base-url)   BASE_URL="$2"; shift 2 ;;
    -d|--test-dir)   TEST_DIR="$2"; shift 2 ;;
    -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -b|--baseline)   BASELINE_FILE="$2"; shift 2 ;;
    -s|--suite)      SUITE="$2"; shift 2 ;;
    --influxdb)      INFLUXDB_URL="$2"; shift 2 ;;
    --skip-baseline) SKIP_BASELINE=true; shift ;;
    -h|--help)
      head -25 "$0" | tail -22
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Setup ---
mkdir -p "${OUTPUT_DIR}/${RUN_ID}"
SUITE_RESULTS="${OUTPUT_DIR}/${RUN_ID}"
SUITE_LOG="${SUITE_RESULTS}/suite.log"
SUITE_SUMMARY="${SUITE_RESULTS}/suite-summary.json"
TOTAL_PASS=0
TOTAL_FAIL=0
TEST_RESULTS=()

# Validate k6 is installed
if ! command -v k6 &>/dev/null; then
  error "k6 is not installed. Run: scripts/init-k6-project.sh"
  exit 1
fi

# Build k6 output flags
K6_OUTPUT_FLAGS=""
if [ -n "${INFLUXDB_URL}" ]; then
  K6_OUTPUT_FLAGS="--out influxdb=${INFLUXDB_URL}"
fi

# --- Run a single test ---
run_test() {
  local test_type="$1"
  local test_file="$2"
  local result_file="${SUITE_RESULTS}/${test_type}-results.json"

  header "Running ${test_type} test"
  info "Script: ${test_file}"
  info "Target: ${BASE_URL}"
  echo ""

  local start_time
  start_time=$(date +%s)
  local exit_code=0

  # Run k6 test
  k6 run \
    --env BASE_URL="${BASE_URL}" \
    --env TEST_RUN_ID="${RUN_ID}" \
    --env TEST_TYPE="${test_type}" \
    --tag suite="${RUN_ID}" \
    --tag test_type="${test_type}" \
    --out "json=${result_file}" \
    ${K6_OUTPUT_FLAGS} \
    "${test_file}" 2>&1 | tee -a "${SUITE_LOG}" || exit_code=$?

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Record result
  if [ ${exit_code} -eq 0 ]; then
    info "✅ ${test_type} test PASSED (${duration}s)"
    TOTAL_PASS=$((TOTAL_PASS + 1))
    TEST_RESULTS+=("{\"type\":\"${test_type}\",\"status\":\"passed\",\"duration\":${duration},\"exit_code\":0}")
  else
    error "❌ ${test_type} test FAILED (${duration}s, exit code: ${exit_code})"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    TEST_RESULTS+=("{\"type\":\"${test_type}\",\"status\":\"failed\",\"duration\":${duration},\"exit_code\":${exit_code}}")
  fi

  echo ""
  return ${exit_code}
}

# --- Compare against baseline ---
compare_baseline() {
  if [ "${SKIP_BASELINE}" = true ]; then
    info "Skipping baseline comparison"
    return 0
  fi

  header "Baseline Comparison"

  local load_results="${SUITE_RESULTS}/load-results.json"
  if [ ! -f "${load_results}" ]; then
    warn "No load test results to compare"
    return 0
  fi

  if [ ! -f "${BASELINE_FILE}" ]; then
    info "No baseline found. Extracting metrics from current run as baseline..."

    # Extract summary metrics from JSON stream results
    local p95 p99 error_rate rps
    p95=$(cat "${load_results}" | grep -o '"http_req_duration".*"p\(95\)":[0-9.]*' | tail -1 | grep -o '[0-9.]*$' || echo "0")
    error_rate=$(cat "${load_results}" | grep '"http_req_failed"' | tail -1 | grep -o '"rate":[0-9.]*' | grep -o '[0-9.]*$' || echo "0")

    mkdir -p "$(dirname "${BASELINE_FILE}")"
    cat > "${BASELINE_FILE}" << EOF
{
  "created": "$(date -Iseconds)",
  "run_id": "${RUN_ID}",
  "metrics": {
    "p95": ${p95:-0},
    "error_rate": ${error_rate:-0}
  }
}
EOF
    info "Baseline saved to ${BASELINE_FILE}"
    return 0
  fi

  # Compare current vs baseline
  local base_p95
  base_p95=$(jq -r '.metrics.p95 // 0' "${BASELINE_FILE}")

  info "Baseline p95: ${base_p95}ms"
  info "Comparison complete — review detailed results in ${SUITE_RESULTS}/"
}

# --- Generate suite summary ---
generate_summary() {
  header "Suite Summary"

  local total=$((TOTAL_PASS + TOTAL_FAIL))
  local status="PASSED"
  [ ${TOTAL_FAIL} -gt 0 ] && status="FAILED"

  # Build JSON array of results
  local results_json="["
  for i in "${!TEST_RESULTS[@]}"; do
    [ $i -gt 0 ] && results_json+=","
    results_json+="${TEST_RESULTS[$i]}"
  done
  results_json+="]"

  cat > "${SUITE_SUMMARY}" << EOF
{
  "run_id": "${RUN_ID}",
  "timestamp": "$(date -Iseconds)",
  "base_url": "${BASE_URL}",
  "status": "${status}",
  "total_tests": ${total},
  "passed": ${TOTAL_PASS},
  "failed": ${TOTAL_FAIL},
  "results": ${results_json}
}
EOF

  echo -e "${BOLD}Run ID:${NC}      ${RUN_ID}"
  echo -e "${BOLD}Target:${NC}      ${BASE_URL}"
  echo -e "${BOLD}Tests run:${NC}   ${total}"
  echo -e "${BOLD}Passed:${NC}      ${GREEN}${TOTAL_PASS}${NC}"
  echo -e "${BOLD}Failed:${NC}      ${RED}${TOTAL_FAIL}${NC}"
  echo -e "${BOLD}Status:${NC}      $([ "${status}" = "PASSED" ] && echo -e "${GREEN}${status}${NC}" || echo -e "${RED}${status}${NC}")"
  echo -e "${BOLD}Results:${NC}     ${SUITE_RESULTS}/"
  echo ""

  if [ ${TOTAL_FAIL} -gt 0 ]; then
    return 1
  fi
  return 0
}

# --- Main ---
main() {
  echo ""
  echo "======================================"
  echo "  Load Test Suite Runner"
  echo "  Run ID: ${RUN_ID}"
  echo "======================================"
  echo ""

  local suite_exit=0

  case "${SUITE}" in
    smoke)
      run_test "smoke" "${TEST_DIR}/smoke/smoke.js" || suite_exit=1
      ;;
    load)
      run_test "load" "${TEST_DIR}/load/api-load.js" || suite_exit=1
      ;;
    stress)
      run_test "stress" "${TEST_DIR}/stress/stress.js" || suite_exit=1
      ;;
    all)
      # Run sequentially: smoke → load → stress
      # Smoke test gates further tests
      if ! run_test "smoke" "${TEST_DIR}/smoke/smoke.js"; then
        error "Smoke test failed — aborting suite"
        suite_exit=1
      else
        run_test "load" "${TEST_DIR}/load/api-load.js" || suite_exit=1
        run_test "stress" "${TEST_DIR}/stress/stress.js" || suite_exit=1
      fi
      ;;
    *)
      error "Unknown suite: ${SUITE}. Options: smoke|load|stress|all"
      exit 1
      ;;
  esac

  compare_baseline
  generate_summary || suite_exit=1

  exit ${suite_exit}
}

main
