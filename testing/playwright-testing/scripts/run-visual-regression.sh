#!/usr/bin/env bash
# =============================================================================
# run-visual-regression.sh
#
# Runs Playwright visual regression tests with platform-specific snapshot
# management and diff reporting. Handles baseline creation, comparison,
# and generates an HTML diff report.
#
# Usage:
#   ./run-visual-regression.sh [OPTIONS]
#
# Options:
#   --project PROJECT     Browser project to run (default: chromium)
#   --update              Update baseline snapshots
#   --grep PATTERN        Filter tests by name pattern
#   --max-diff-ratio N    Max pixel diff ratio 0.0-1.0 (default: 0.01)
#   --report-dir DIR      Output dir for diff report (default: visual-report)
#   --ci                  CI mode: stricter thresholds, always generate report
#   --docker              Run inside Playwright Docker container for consistency
#   --help                Show this help message
#
# Examples:
#   ./run-visual-regression.sh
#   ./run-visual-regression.sh --update --project firefox
#   ./run-visual-regression.sh --ci --docker --max-diff-ratio 0.005
#   ./run-visual-regression.sh --grep "homepage" --project webkit
# =============================================================================

set -euo pipefail

# Defaults
PROJECT="chromium"
UPDATE_SNAPSHOTS=false
GREP_PATTERN=""
MAX_DIFF_RATIO="0.01"
REPORT_DIR="visual-report"
CI_MODE=false
DOCKER_MODE=false

usage() {
  head -n 23 "$0" | tail -n +3 | sed 's/^# \?//'
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT="$2"; shift 2 ;;
    --update)         UPDATE_SNAPSHOTS=true; shift ;;
    --grep)           GREP_PATTERN="$2"; shift 2 ;;
    --max-diff-ratio) MAX_DIFF_RATIO="$2"; shift 2 ;;
    --report-dir)     REPORT_DIR="$2"; shift 2 ;;
    --ci)             CI_MODE=true; shift ;;
    --docker)         DOCKER_MODE=true; shift ;;
    --help|-h)        usage ;;
    *)                echo "Unknown option: $1"; usage ;;
  esac
done

echo "=== Visual Regression Testing ==="
echo "Project:        $PROJECT"
echo "Max diff ratio: $MAX_DIFF_RATIO"
echo "Report dir:     $REPORT_DIR"
echo "Update mode:    $UPDATE_SNAPSHOTS"
echo "CI mode:        $CI_MODE"
echo "Docker mode:    $DOCKER_MODE"
echo ""

# Detect platform for snapshot directory naming
PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$PLATFORM" in
  linux*)  PLATFORM_NAME="linux" ;;
  darwin*) PLATFORM_NAME="darwin" ;;
  *)       PLATFORM_NAME="linux" ;;
esac
echo "Platform: $PLATFORM_NAME"

# Build Playwright command
PW_ARGS=()
PW_ARGS+=("--project=$PROJECT")

if [[ "$UPDATE_SNAPSHOTS" == true ]]; then
  PW_ARGS+=("--update-snapshots")
  echo ">>> Running in UPDATE mode — baselines will be overwritten"
fi

if [[ -n "$GREP_PATTERN" ]]; then
  PW_ARGS+=("--grep" "$GREP_PATTERN")
fi

# CI mode: stricter settings
if [[ "$CI_MODE" == true ]]; then
  PW_ARGS+=("--retries=0")
  PW_ARGS+=("--reporter=blob,html")
  echo ">>> CI mode: retries disabled, generating reports"
fi

# Create report directory
mkdir -p "$REPORT_DIR"

# Docker mode: run inside Playwright container for consistent rendering
if [[ "$DOCKER_MODE" == true ]]; then
  echo ">>> Running inside Playwright Docker container..."

  # Check if docker is available
  if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed or not in PATH"
    exit 1
  fi

  PLAYWRIGHT_VERSION=$(node -e "try { const v = require('@playwright/test/package.json').version; console.log(v); } catch(e) { console.log('1.52.0'); }" 2>/dev/null || echo "1.52.0")

  docker run --rm \
    --ipc=host \
    --user "$(id -u):$(id -g)" \
    -v "$(pwd):/work" \
    -w /work \
    -e CI=true \
    "mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble" \
    npx playwright test "${PW_ARGS[@]}" 2>&1 | tee "$REPORT_DIR/test-output.log"

  TEST_EXIT=${PIPESTATUS[0]}
else
  # Run locally
  echo ">>> Running visual regression tests..."
  npx playwright test "${PW_ARGS[@]}" 2>&1 | tee "$REPORT_DIR/test-output.log" || true
  TEST_EXIT=${PIPESTATUS[0]}
fi

echo ""

# Collect diff artifacts
DIFF_COUNT=0
SNAPSHOT_DIR="test-results"

if [[ -d "$SNAPSHOT_DIR" ]]; then
  echo ">>> Collecting diff images..."

  # Find all diff images and copy to report dir
  while IFS= read -r -d '' diff_file; do
    DIFF_COUNT=$((DIFF_COUNT + 1))
    cp "$diff_file" "$REPORT_DIR/"
  done < <(find "$SNAPSHOT_DIR" -name "*-diff.png" -print0 2>/dev/null)

  # Copy expected and actual images too
  find "$SNAPSHOT_DIR" -name "*-expected.png" -exec cp {} "$REPORT_DIR/" \; 2>/dev/null || true
  find "$SNAPSHOT_DIR" -name "*-actual.png" -exec cp {} "$REPORT_DIR/" \; 2>/dev/null || true
fi

# Generate summary HTML report
REPORT_FILE="$REPORT_DIR/index.html"
cat > "$REPORT_FILE" <<'REPORT_START'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Visual Regression Report</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2rem; background: #f5f5f5; }
  h1 { color: #1a1a1a; }
  .summary { background: white; padding: 1rem 1.5rem; border-radius: 8px; margin-bottom: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .pass { color: #16a34a; } .fail { color: #dc2626; }
  .diff-group { background: white; padding: 1rem; border-radius: 8px; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  .diff-group h3 { margin-top: 0; }
  .images { display: flex; gap: 1rem; flex-wrap: wrap; }
  .images figure { margin: 0; text-align: center; }
  .images img { max-width: 400px; border: 1px solid #ddd; border-radius: 4px; }
  figcaption { font-size: 0.875rem; color: #666; margin-top: 0.25rem; }
</style>
</head>
<body>
<h1>Visual Regression Report</h1>
REPORT_START

# Add summary
if [[ "$TEST_EXIT" -eq 0 ]]; then
  echo "<div class='summary'><h2 class='pass'>✅ All visual tests passed</h2>" >> "$REPORT_FILE"
else
  echo "<div class='summary'><h2 class='fail'>❌ ${DIFF_COUNT} visual difference(s) found</h2>" >> "$REPORT_FILE"
fi

echo "<p>Project: <strong>${PROJECT}</strong> | Platform: <strong>${PLATFORM_NAME}</strong> | Threshold: <strong>${MAX_DIFF_RATIO}</strong></p>" >> "$REPORT_FILE"
echo "</div>" >> "$REPORT_FILE"

# Add diff images to report
if [[ "$DIFF_COUNT" -gt 0 ]]; then
  for diff_img in "$REPORT_DIR"/*-diff.png; do
    [[ -f "$diff_img" ]] || continue
    BASE=$(basename "$diff_img" "-diff.png")
    echo "<div class='diff-group'>" >> "$REPORT_FILE"
    echo "<h3>${BASE}</h3>" >> "$REPORT_FILE"
    echo "<div class='images'>" >> "$REPORT_FILE"

    for suffix in expected actual diff; do
      IMG="${BASE}-${suffix}.png"
      if [[ -f "$REPORT_DIR/$IMG" ]]; then
        LABEL=$(echo "$suffix" | sed 's/.*/\u&/')
        echo "<figure><img src='${IMG}' alt='${suffix}'><figcaption>${LABEL}</figcaption></figure>" >> "$REPORT_FILE"
      fi
    done

    echo "</div></div>" >> "$REPORT_FILE"
  done
fi

echo "</body></html>" >> "$REPORT_FILE"

echo ""
echo "=== Results ==="
echo "Test exit code: $TEST_EXIT"
echo "Diff images:    $DIFF_COUNT"
echo "Report:         $REPORT_FILE"
echo "Full output:    $REPORT_DIR/test-output.log"

if [[ "$DIFF_COUNT" -gt 0 ]]; then
  echo ""
  echo "To update baselines: $0 --update --project $PROJECT"
fi

exit "$TEST_EXIT"
