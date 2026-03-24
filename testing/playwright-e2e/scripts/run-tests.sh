#!/usr/bin/env bash
# ============================================================================
# run-tests.sh — Smart Playwright test runner
#
# Usage:
#   ./run-tests.sh [OPTIONS] [-- extra-playwright-args]
#
# Provides convenient shortcuts for common test run configurations including
# retry, sharding, filtering, and report generation.
# ============================================================================

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[test]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
info()  { echo -e "${CYAN}[info]${NC} $*"; }

# Defaults
RETRIES=""
SHARD=""
PROJECT=""
GREP=""
GREP_INVERT=""
WORKERS=""
REPORTER=""
UPDATE_SNAPSHOTS=false
TRACE=""
HEADED=false
DEBUG=false
UI=false
LAST_FAILED=false
LIST=false
REPEAT=1
EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- extra-playwright-args]

Smart Playwright test runner with retry, sharding, and report options.

Options:
  --retries <n>         Number of retries for failed tests (default: config value)
  --shard <i/n>         Run shard i of n (e.g., 1/4)
  --project <name>      Run specific project (chromium, firefox, webkit)
  --grep <pattern>      Filter tests by title pattern or tag
  --grep-invert <pat>   Exclude tests matching pattern
  --workers <n|%>       Number of workers (e.g., 4, 50%)
  --reporter <type>     Reporter: list, html, json, junit, blob
  --update-snapshots    Update screenshot/snapshot baselines
  --trace <mode>        Trace mode: on, off, on-first-retry, retain-on-failure
  --headed              Run in headed (visible) browser mode
  --debug               Run with Playwright inspector
  --ui                  Open interactive UI mode
  --last-failed         Re-run only previously failed tests
  --list                List all tests without running them
  --repeat <n>          Repeat each test n times (flaky detection)
  --smoke               Shortcut: run @smoke tagged tests only
  --full                Shortcut: all projects, retries=2, html report
  --ci                  Shortcut: CI-optimized (2 workers, retries=2, blob+github reporter)
  -h, --help            Show this help message

Examples:
  $(basename "$0")                              # run all tests with config defaults
  $(basename "$0") --smoke                      # run smoke tests only
  $(basename "$0") --project chromium --headed   # chromium in headed mode
  $(basename "$0") --shard 1/4 --ci             # CI shard run
  $(basename "$0") --repeat 5 --grep "login"    # flaky detection for login tests
  $(basename "$0") -- tests/checkout.spec.ts     # run specific test file
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --retries)          RETRIES="$2"; shift 2 ;;
    --shard)            SHARD="$2"; shift 2 ;;
    --project)          PROJECT="$2"; shift 2 ;;
    --grep)             GREP="$2"; shift 2 ;;
    --grep-invert)      GREP_INVERT="$2"; shift 2 ;;
    --workers)          WORKERS="$2"; shift 2 ;;
    --reporter)         REPORTER="$2"; shift 2 ;;
    --update-snapshots) UPDATE_SNAPSHOTS=true; shift ;;
    --trace)            TRACE="$2"; shift 2 ;;
    --headed)           HEADED=true; shift ;;
    --debug)            DEBUG=true; shift ;;
    --ui)               UI=true; shift ;;
    --last-failed)      LAST_FAILED=true; shift ;;
    --list)             LIST=true; shift ;;
    --repeat)           REPEAT="$2"; shift 2 ;;
    --smoke)            GREP="@smoke"; shift ;;
    --full)
      RETRIES=2
      REPORTER="html"
      shift ;;
    --ci)
      WORKERS=2
      RETRIES=2
      REPORTER="blob"
      shift ;;
    -h|--help)          usage ;;
    --)                 shift; EXTRA_ARGS+=("$@"); break ;;
    -*)                 error "Unknown option: $1. Use --help for usage." ;;
    *)                  EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# Build command
CMD=(npx playwright test)

[[ -n "$RETRIES" ]]       && CMD+=(--retries "$RETRIES")
[[ -n "$SHARD" ]]         && CMD+=(--shard "$SHARD")
[[ -n "$PROJECT" ]]       && CMD+=(--project "$PROJECT")
[[ -n "$GREP" ]]          && CMD+=(--grep "$GREP")
[[ -n "$GREP_INVERT" ]]   && CMD+=(--grep-invert "$GREP_INVERT")
[[ -n "$WORKERS" ]]       && CMD+=(--workers "$WORKERS")
[[ -n "$REPORTER" ]]      && CMD+=(--reporter "$REPORTER")
[[ -n "$TRACE" ]]         && CMD+=(--trace "$TRACE")
[[ "$UPDATE_SNAPSHOTS" == true ]] && CMD+=(--update-snapshots)
[[ "$HEADED" == true ]]   && CMD+=(--headed)
[[ "$DEBUG" == true ]]    && CMD+=(--debug)
[[ "$UI" == true ]]       && CMD+=(--ui)
[[ "$LAST_FAILED" == true ]] && CMD+=(--last-failed)
[[ "$LIST" == true ]]     && CMD+=(--list)
[[ "$REPEAT" -gt 1 ]]    && CMD+=(--repeat-each "$REPEAT")

# Append extra args (test files, etc.)
CMD+=("${EXTRA_ARGS[@]}")

# Print command
info "Running: ${CMD[*]}"
echo ""

# Track timing
START_TIME=$(date +%s)

# Run tests
set +e
"${CMD[@]}"
EXIT_CODE=$?
set -e

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  log "All tests passed! (${MINUTES}m ${SECONDS}s)"
else
  warn "Tests finished with failures. (${MINUTES}m ${SECONDS}s)"
  echo ""

  # Suggest next steps on failure
  info "Next steps:"
  echo "  • View report:   npx playwright show-report"
  echo "  • Re-run failed:  $(basename "$0") --last-failed"
  echo "  • Debug:          $(basename "$0") --debug -- <test-file>"
  echo "  • View trace:     npx playwright show-trace test-results/*/trace.zip"
fi

exit $EXIT_CODE
