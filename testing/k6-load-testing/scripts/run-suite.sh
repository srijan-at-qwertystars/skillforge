#!/usr/bin/env bash
#
# run-suite.sh — Run k6 test suites with environment selection, threshold
#                validation, and report generation.
#
# Usage:
#   ./run-suite.sh [options]
#
# Options:
#   -s, --scenario FILE    Specific scenario file (default: all in scenarios/)
#   -e, --env ENV          Environment: local|staging|production (default: staging)
#   -o, --output DIR       Results output directory (default: results/)
#   -t, --tag KEY=VALUE    Additional tag (repeatable)
#   --json                 Enable JSON output
#   --influxdb URL         Send results to InfluxDB
#   --cloud                Run with Grafana Cloud k6
#   --dry-run              Validate scripts without executing
#   --summary-only         Only show end-of-test summary (suppress progress)
#   -h, --help             Show this help
#
# Examples:
#   ./run-suite.sh                                    # all scenarios, staging
#   ./run-suite.sh -s scenarios/smoke.js -e local     # single scenario, local
#   ./run-suite.sh -e production --json               # all scenarios, JSON output
#   ./run-suite.sh --influxdb http://localhost:8086/k6 # pipe to InfluxDB
#   ./run-suite.sh --dry-run                          # validate scripts only
#
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
SCENARIO=""
ENV_NAME="staging"
OUTPUT_DIR="results"
TAGS=()
JSON_OUTPUT=false
INFLUXDB_URL=""
CLOUD_MODE=false
DRY_RUN=false
SUMMARY_ONLY=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}"; }

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--scenario)   SCENARIO="$2"; shift 2 ;;
    -e|--env)        ENV_NAME="$2"; shift 2 ;;
    -o|--output)     OUTPUT_DIR="$2"; shift 2 ;;
    -t|--tag)        TAGS+=("$2"); shift 2 ;;
    --json)          JSON_OUTPUT=true; shift ;;
    --influxdb)      INFLUXDB_URL="$2"; shift 2 ;;
    --cloud)         CLOUD_MODE=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --summary-only)  SUMMARY_ONLY=true; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validate prerequisites ──────────────────────────────────────────────────
if ! command -v k6 &>/dev/null; then
  error "k6 is not installed. Run setup-k6.sh first."
  exit 1
fi

# ── Collect scenario files ──────────────────────────────────────────────────
if [[ -n "$SCENARIO" ]]; then
  if [[ ! -f "$SCENARIO" ]]; then
    error "Scenario file not found: $SCENARIO"
    exit 1
  fi
  SCENARIOS=("$SCENARIO")
else
  if [[ ! -d "scenarios" ]]; then
    error "No scenarios/ directory found. Run from project root."
    exit 1
  fi
  mapfile -t SCENARIOS < <(find scenarios/ -name '*.js' -type f | sort)
  if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
    error "No .js files found in scenarios/"
    exit 1
  fi
fi

# ── Prepare output directory ────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="${OUTPUT_DIR}/${TIMESTAMP}"
mkdir -p "$RUN_DIR"

# ── Build k6 flags ──────────────────────────────────────────────────────────
build_k6_flags() {
  local script="$1"
  local flags=()

  flags+=(-e "ENV=${ENV_NAME}")

  for tag in "${TAGS[@]}"; do
    flags+=(--tag "$tag")
  done

  # Output backends
  local basename
  basename=$(basename "$script" .js)

  if [[ "$JSON_OUTPUT" == true ]]; then
    flags+=(--out "json=${RUN_DIR}/${basename}.json")
  fi

  if [[ -n "$INFLUXDB_URL" ]]; then
    flags+=(--out "influxdb=${INFLUXDB_URL}")
  fi

  if [[ "$SUMMARY_ONLY" == true ]]; then
    flags+=(--quiet)
  fi

  echo "${flags[@]}"
}

# ── Run a single scenario ───────────────────────────────────────────────────
run_scenario() {
  local script="$1"
  local basename
  basename=$(basename "$script" .js)

  header "Running: $basename ($ENV_NAME)"
  info "Script: $script"
  info "Output: $RUN_DIR/"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would execute: k6 run $(build_k6_flags "$script") $script"
    return 0
  fi

  local flags
  flags=$(build_k6_flags "$script")

  local exit_code=0
  local summary_file="${RUN_DIR}/${basename}-summary.txt"

  if [[ "$CLOUD_MODE" == true ]]; then
    # shellcheck disable=SC2086
    k6 cloud run $flags "$script" 2>&1 | tee "$summary_file" || exit_code=$?
  else
    # shellcheck disable=SC2086
    k6 run $flags "$script" 2>&1 | tee "$summary_file" || exit_code=$?
  fi

  return $exit_code
}

# ── Main execution ──────────────────────────────────────────────────────────
main() {
  header "k6 Test Suite Runner"
  info "Environment: $ENV_NAME"
  info "Scenarios:   ${#SCENARIOS[@]} file(s)"
  info "Output:      $RUN_DIR/"
  info "k6 version:  $(k6 version 2>/dev/null || echo 'unknown')"

  local total=${#SCENARIOS[@]}
  local passed=0
  local failed=0
  local failures=()

  for script in "${SCENARIOS[@]}"; do
    if run_scenario "$script"; then
      ((passed++))
      info "✅ $(basename "$script" .js) — PASSED"
    else
      local code=$?
      ((failed++))
      failures+=("$(basename "$script" .js) (exit $code)")
      warn "❌ $(basename "$script" .js) — FAILED (exit $code)"
    fi
    echo
  done

  # ── Summary report ──
  header "Suite Results"
  echo -e "  Total:  $total"
  echo -e "  Passed: ${GREEN}${passed}${NC}"
  echo -e "  Failed: ${RED}${failed}${NC}"

  if [[ ${#failures[@]} -gt 0 ]]; then
    echo -e "\n  ${RED}Failed scenarios:${NC}"
    for f in "${failures[@]}"; do
      echo -e "    ✗ $f"
    done
  fi

  echo -e "\n  Results saved to: $RUN_DIR/"

  # ── Generate summary report file ──
  cat > "${RUN_DIR}/suite-report.txt" << EOF
k6 Test Suite Report
====================
Date:        $(date -Iseconds)
Environment: $ENV_NAME
k6 Version:  $(k6 version 2>/dev/null || echo 'unknown')

Results: $passed/$total passed, $failed failed
$(printf '%s\n' "${failures[@]}" | sed 's/^/FAILED: /')
EOF

  info "Report: ${RUN_DIR}/suite-report.txt"

  if [[ $failed -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
