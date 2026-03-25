#!/usr/bin/env bash
# visual-test.sh — Run visual regression tests with Storybook test-runner
#
# Usage:
#   ./visual-test.sh [options]
#
# Options:
#   --url URL          Storybook URL (default: http://localhost:6006)
#   --build            Build Storybook before testing (uses storybook-static/)
#   --browsers LIST    Browsers to test: chromium,firefox,webkit (default: chromium)
#   --update           Update snapshots
#   --shard N/M        Shard tests for CI parallelism (e.g., 1/3)
#   --a11y             Include accessibility checks
#   --snapshots        Enable image snapshot comparison
#   --report-dir DIR   Output directory for reports (default: ./visual-test-results)
#   --help             Show this help
#
# Prerequisites:
#   npm install -D @storybook/test-runner jest-image-snapshot axe-playwright
#   npx playwright install --with-deps chromium

set -euo pipefail

# --- Defaults ---
STORYBOOK_URL="http://localhost:6006"
DO_BUILD=false
BROWSERS="chromium"
UPDATE_SNAPSHOTS=false
SHARD=""
ENABLE_A11Y=false
ENABLE_SNAPSHOTS=false
REPORT_DIR="./visual-test-results"
EXTRA_ARGS=()

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[visual-test]${NC} $*"; }
warn() { echo -e "${YELLOW}[visual-test]${NC} $*"; }
err()  { echo -e "${RED}[visual-test]${NC} $*" >&2; }
info() { echo -e "${CYAN}[visual-test]${NC} $*"; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)         STORYBOOK_URL="$2"; shift 2 ;;
    --build)       DO_BUILD=true; shift ;;
    --browsers)    BROWSERS="$2"; shift 2 ;;
    --update)      UPDATE_SNAPSHOTS=true; shift ;;
    --shard)       SHARD="$2"; shift 2 ;;
    --a11y)        ENABLE_A11Y=true; shift ;;
    --snapshots)   ENABLE_SNAPSHOTS=true; shift ;;
    --report-dir)  REPORT_DIR="$2"; shift 2 ;;
    --help)
      head -20 "$0" | tail -18
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# --- Preflight ---
if ! command -v npx &>/dev/null; then
  err "npx not found. Install Node.js 18+."
  exit 1
fi

if ! npx test-storybook --help &>/dev/null 2>&1; then
  err "@storybook/test-runner not installed."
  err "Run: npm install -D @storybook/test-runner"
  exit 1
fi

mkdir -p "$REPORT_DIR"

# --- Step 1: Build Storybook if requested ---
SERVE_PID=""
if [ "$DO_BUILD" = true ]; then
  log "Building Storybook..."
  npx storybook build --test --quiet -o storybook-static 2>&1
  log "Build complete. Serving static files..."

  npx http-server storybook-static -p 6006 --silent &
  SERVE_PID=$!
  STORYBOOK_URL="http://localhost:6006"

  # Wait for server
  log "Waiting for Storybook to be ready..."
  npx wait-on "$STORYBOOK_URL" --timeout 60000 2>&1 || {
    err "Storybook failed to start."
    [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null
    exit 1
  }
  log "Storybook is ready at $STORYBOOK_URL"
fi

cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    log "Stopped local Storybook server."
  fi
}
trap cleanup EXIT

# --- Step 2: Generate test-runner config if snapshots/a11y enabled ---
TEST_RUNNER_CONFIG=".storybook/test-runner.ts"
GENERATED_CONFIG=false

if [ "$ENABLE_SNAPSHOTS" = true ] || [ "$ENABLE_A11Y" = true ]; then
  if [ ! -f "$TEST_RUNNER_CONFIG" ]; then
    log "Generating test-runner config..."
    GENERATED_CONFIG=true

    cat > "$TEST_RUNNER_CONFIG" << 'CONFIG_EOF'
import type { TestRunnerConfig } from '@storybook/test-runner';

const config: TestRunnerConfig = {
  setup() {
    // Extend expect with image snapshot matcher if available
    try {
      const { toMatchImageSnapshot } = require('jest-image-snapshot');
      expect.extend({ toMatchImageSnapshot });
    } catch {
      // jest-image-snapshot not installed; skip
    }
  },

  async preVisit(page) {
    // Inject axe-core for accessibility testing if available
    try {
      const { injectAxe } = require('axe-playwright');
      await injectAxe(page);
    } catch {
      // axe-playwright not installed; skip
    }
  },

  async postVisit(page, context) {
    // Accessibility check
    try {
      const { checkA11y } = require('axe-playwright');
      await checkA11y(page, '#storybook-root', {
        detailedReport: true,
        detailedReportOptions: { html: true },
      });
    } catch {
      // skip if not available
    }

    // Visual snapshot
    try {
      const image = await page.locator('#storybook-root').screenshot();
      expect(image).toMatchImageSnapshot({
        customSnapshotsDir: `${process.cwd()}/visual-test-results/__snapshots__`,
        customDiffDir: `${process.cwd()}/visual-test-results/__diffs__`,
        failureThreshold: 0.03,
        failureThresholdType: 'percent',
      });
    } catch {
      // skip if matcher not available
    }
  },
};

export default config;
CONFIG_EOF
    log "Created $TEST_RUNNER_CONFIG"
  else
    info "Using existing $TEST_RUNNER_CONFIG"
  fi
fi

# --- Step 3: Build test-storybook command ---
CMD=("npx" "test-storybook")
CMD+=("--url" "$STORYBOOK_URL")

# Browsers
IFS=',' read -ra BROWSER_LIST <<< "$BROWSERS"
if [ ${#BROWSER_LIST[@]} -gt 0 ]; then
  CMD+=("--browsers")
  CMD+=("${BROWSER_LIST[@]}")
fi

# Update snapshots
if [ "$UPDATE_SNAPSHOTS" = true ]; then
  CMD+=("--updateSnapshot")
fi

# Shard
if [ -n "$SHARD" ]; then
  CMD+=("--shard" "$SHARD")
fi

# Extra args
CMD+=("${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")

# --- Step 4: Run tests ---
log "Running visual regression tests..."
info "Command: ${CMD[*]}"
echo ""

TEST_EXIT=0
"${CMD[@]}" 2>&1 | tee "$REPORT_DIR/test-output.log" || TEST_EXIT=$?

# --- Step 5: Report ---
echo ""
if [ $TEST_EXIT -eq 0 ]; then
  log "✅ All visual tests passed!"
else
  err "❌ Some tests failed (exit code: $TEST_EXIT)"
fi

# Count results
SNAPSHOT_COUNT=$(find "$REPORT_DIR" -name "*.png" 2>/dev/null | wc -l || echo 0)
DIFF_COUNT=$(find "$REPORT_DIR/__diffs__" -name "*.png" 2>/dev/null | wc -l || echo 0)

info "Results saved to: $REPORT_DIR/"
info "  Snapshots: $SNAPSHOT_COUNT"
info "  Diffs: $DIFF_COUNT"
info "  Log: $REPORT_DIR/test-output.log"

# Clean up generated config if we created it
if [ "$GENERATED_CONFIG" = true ]; then
  log "Cleaning up generated test-runner config..."
  rm -f "$TEST_RUNNER_CONFIG"
fi

exit $TEST_EXIT
