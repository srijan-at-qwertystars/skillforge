#!/usr/bin/env bash
# =============================================================================
# generate-report.sh
#
# Run Playwright tests and generate an HTML report with trace artifacts.
# Handles test execution, artifact collection, and report serving.
#
# Usage:
#   ./generate-report.sh [OPTIONS]
#
# Options:
#   --project PROJECT     Run specific project (e.g., chromium, firefox)
#   --grep PATTERN        Filter tests by title pattern
#   --shard SHARD         Shard spec (e.g., 1/4)
#   --retries N           Override retry count (default: from config)
#   --workers N           Override worker count
#   --trace MODE          Trace mode: on, off, on-first-retry, retain-on-failure
#   --report-dir DIR      Output directory for report (default: playwright-report)
#   --serve               Open HTML report in browser after tests
#   --ci                  CI mode: blob reporter, no serve, exit code passthrough
#   --help                Show this help message
#
# Examples:
#   ./generate-report.sh                                    # Run all, open report
#   ./generate-report.sh --project chromium --grep "login"  # Filtered run
#   ./generate-report.sh --ci --shard 1/4                   # CI shard run
#   ./generate-report.sh --trace on --serve                 # Full traces + view
# =============================================================================

set -euo pipefail

# Defaults
PROJECT=""
GREP_PATTERN=""
SHARD=""
RETRIES=""
WORKERS=""
TRACE=""
REPORT_DIR="playwright-report"
SERVE=false
CI_MODE=false

usage() {
  head -n 27 "$0" | tail -n +3 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT="$2"; shift 2 ;;
    --grep)       GREP_PATTERN="$2"; shift 2 ;;
    --shard)      SHARD="$2"; shift 2 ;;
    --retries)    RETRIES="$2"; shift 2 ;;
    --workers)    WORKERS="$2"; shift 2 ;;
    --trace)      TRACE="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --serve)      SERVE=true; shift ;;
    --ci)         CI_MODE=true; shift ;;
    --help|-h)    usage ;;
    *)            echo "Unknown option: $1"; usage ;;
  esac
done

echo "=== Playwright Test Runner & Report Generator ==="

# Build command arguments
PW_ARGS=()

if [[ -n "$PROJECT" ]]; then
  PW_ARGS+=("--project=$PROJECT")
  echo "Project:  $PROJECT"
fi

if [[ -n "$GREP_PATTERN" ]]; then
  PW_ARGS+=("--grep" "$GREP_PATTERN")
  echo "Grep:     $GREP_PATTERN"
fi

if [[ -n "$SHARD" ]]; then
  PW_ARGS+=("--shard=$SHARD")
  echo "Shard:    $SHARD"
fi

if [[ -n "$RETRIES" ]]; then
  PW_ARGS+=("--retries=$RETRIES")
  echo "Retries:  $RETRIES"
fi

if [[ -n "$WORKERS" ]]; then
  PW_ARGS+=("--workers=$WORKERS")
  echo "Workers:  $WORKERS"
fi

if [[ -n "$TRACE" ]]; then
  echo "Trace:    $TRACE"
fi

# Set reporter based on mode
if [[ "$CI_MODE" == true ]]; then
  PW_ARGS+=("--reporter=blob,html")
  echo "Mode:     CI (blob + html reporters)"
else
  PW_ARGS+=("--reporter=html")
  echo "Mode:     Local (html reporter)"
fi

echo ""

# Create report directory
mkdir -p "$REPORT_DIR"

# Set trace via environment if overridden
TRACE_ENV=""
if [[ -n "$TRACE" ]]; then
  TRACE_ENV="PLAYWRIGHT_TRACE=$TRACE"
fi

# Run tests
echo ">>> Running Playwright tests..."
echo "Command: npx playwright test ${PW_ARGS[*]}"
echo ""

TEST_EXIT=0
if [[ -n "$TRACE_ENV" ]]; then
  env "$TRACE_ENV" npx playwright test "${PW_ARGS[@]}" || TEST_EXIT=$?
else
  npx playwright test "${PW_ARGS[@]}" || TEST_EXIT=$?
fi

echo ""

# Collect results summary
RESULTS_DIR="test-results"
TRACE_COUNT=0
SCREENSHOT_COUNT=0
VIDEO_COUNT=0

if [[ -d "$RESULTS_DIR" ]]; then
  TRACE_COUNT=$(find "$RESULTS_DIR" -name "trace.zip" 2>/dev/null | wc -l)
  SCREENSHOT_COUNT=$(find "$RESULTS_DIR" -name "*.png" 2>/dev/null | wc -l)
  VIDEO_COUNT=$(find "$RESULTS_DIR" -name "*.webm" 2>/dev/null | wc -l)
fi

echo "=== Results Summary ==="
if [[ "$TEST_EXIT" -eq 0 ]]; then
  echo "Status:       ✅ PASSED"
else
  echo "Status:       ❌ FAILED (exit code: $TEST_EXIT)"
fi
echo "Traces:       $TRACE_COUNT"
echo "Screenshots:  $SCREENSHOT_COUNT"
echo "Videos:       $VIDEO_COUNT"
echo "Report:       $REPORT_DIR/index.html"

# List trace files for easy access
if [[ "$TRACE_COUNT" -gt 0 ]]; then
  echo ""
  echo "Trace files:"
  find "$RESULTS_DIR" -name "trace.zip" 2>/dev/null | while read -r trace; do
    echo "  npx playwright show-trace $trace"
  done
fi

# Serve report if requested (and not CI)
if [[ "$SERVE" == true && "$CI_MODE" == false ]]; then
  echo ""
  echo ">>> Opening HTML report..."
  npx playwright show-report "$REPORT_DIR"
fi

exit "$TEST_EXIT"
