#!/usr/bin/env bash
#
# ci-visual-test.sh — CI script for Storybook visual testing
#
# Usage:
#   ./ci-visual-test.sh                                  # build + test-runner only
#   ./ci-visual-test.sh --chromatic                       # also publish to Chromatic
#   ./ci-visual-test.sh --chromatic --token <TOKEN>       # explicit token
#   ./ci-visual-test.sh --port 6007                       # custom port
#   ./ci-visual-test.sh --test-build                      # use --test flag for faster build
#   ./ci-visual-test.sh --shards 4                        # parallel test shards
#
# Environment variables:
#   CHROMATIC_PROJECT_TOKEN  — Chromatic project token (or use --token)
#   NODE_OPTIONS             — Node.js options (default: --max-old-space-size=8192)
#   STORYBOOK_PORT           — Port for test server (default: 6006)
#
# Exit codes:
#   0 — all tests passed
#   1 — build or test failure
#   2 — chromatic detected visual changes (non-fatal with --exit-zero)
#

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[ci-visual]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ci-visual]${NC} $*"; }
error() { echo -e "${RED}[ci-visual]${NC} $*" >&2; }

# --- Defaults ---
PORT="${STORYBOOK_PORT:-6006}"
USE_CHROMATIC=false
CHROMATIC_TOKEN="${CHROMATIC_PROJECT_TOKEN:-}"
TEST_BUILD=false
SHARDS=1
BUILD_DIR="storybook-static"
EXIT_CODE=0

export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=8192}"

# --- Parse Args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chromatic)   USE_CHROMATIC=true; shift ;;
    --token)       CHROMATIC_TOKEN="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    --test-build)  TEST_BUILD=true; shift ;;
    --shards)      SHARDS="$2"; shift 2 ;;
    --build-dir)   BUILD_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--chromatic] [--token TOKEN] [--port PORT] [--test-build] [--shards N]"
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Timestamp helper ---
elapsed() {
  local start="$1"
  local end
  end=$(date +%s)
  echo "$((end - start))s"
}

# ============================================================
# STEP 1: Build Storybook
# ============================================================
log "Step 1/3: Building Storybook..."
BUILD_START=$(date +%s)

BUILD_CMD="npx storybook build -o ${BUILD_DIR}"
if [[ "$TEST_BUILD" == true ]]; then
  BUILD_CMD+=" --test"
  log "Using --test flag for optimized build (no docs)"
fi

if $BUILD_CMD; then
  log "Build succeeded ($(elapsed $BUILD_START))"
else
  error "Build failed!"
  exit 1
fi

# Verify build output
if [[ ! -f "${BUILD_DIR}/index.html" ]]; then
  error "Build output missing: ${BUILD_DIR}/index.html"
  exit 1
fi

STORY_COUNT=$(find "$BUILD_DIR" -name "*.iframe.bundle.js" 2>/dev/null | wc -l || echo "?")
log "Build output: ${BUILD_DIR}/ (stories: ~${STORY_COUNT})"

# ============================================================
# STEP 2: Run Test Runner
# ============================================================
log "Step 2/3: Running Storybook test runner..."
TEST_START=$(date +%s)

# Check if test-storybook is available
if ! npx test-storybook --help >/dev/null 2>&1; then
  warn "test-storybook not installed. Installing..."
  npm install -D @storybook/test-runner
fi

# Start HTTP server and run tests
cleanup_server() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup_server EXIT

# Start static server
npx http-server "$BUILD_DIR" --port "$PORT" --silent &
SERVER_PID=$!
log "Started test server on port $PORT (PID: $SERVER_PID)"

# Wait for server
if ! npx wait-on "tcp:127.0.0.1:${PORT}" --timeout 30000 2>/dev/null; then
  error "Server failed to start on port $PORT"
  exit 1
fi

# Run tests (with optional sharding)
TEST_RESULTS_FILE="test-results-storybook.json"
TEST_PASSED=true

if [[ "$SHARDS" -gt 1 ]]; then
  log "Running tests with $SHARDS shards..."
  for shard in $(seq 1 "$SHARDS"); do
    log "  Shard ${shard}/${SHARDS}..."
    if ! npx test-storybook \
      --url "http://127.0.0.1:${PORT}" \
      --shard "${shard}/${SHARDS}" \
      --junit 2>&1 | tail -5; then
      TEST_PASSED=false
    fi
  done
else
  if ! npx test-storybook \
    --url "http://127.0.0.1:${PORT}" \
    --junit 2>&1; then
    TEST_PASSED=false
  fi
fi

# Stop server
cleanup_server

if [[ "$TEST_PASSED" == true ]]; then
  log "Tests passed ($(elapsed $TEST_START))"
else
  error "Some tests failed ($(elapsed $TEST_START))"
  EXIT_CODE=1
fi

# ============================================================
# STEP 3: Chromatic (optional)
# ============================================================
if [[ "$USE_CHROMATIC" == true ]]; then
  log "Step 3/3: Publishing to Chromatic..."
  CHROMATIC_START=$(date +%s)

  if [[ -z "$CHROMATIC_TOKEN" ]]; then
    error "Chromatic token not set. Use --token or set CHROMATIC_PROJECT_TOKEN."
    exit 1
  fi

  # Check if chromatic is installed
  if ! npx chromatic --version >/dev/null 2>&1; then
    warn "chromatic not installed. Installing..."
    npm install -D chromatic
  fi

  CHROMATIC_CMD="npx chromatic"
  CHROMATIC_CMD+=" --project-token=${CHROMATIC_TOKEN}"
  CHROMATIC_CMD+=" --storybook-build-dir=${BUILD_DIR}"
  CHROMATIC_CMD+=" --only-changed"           # TurboSnap
  CHROMATIC_CMD+=" --exit-zero-on-changes"   # don't fail on visual changes
  CHROMATIC_CMD+=" --exit-once-uploaded"      # don't wait for review

  if $CHROMATIC_CMD 2>&1 | tail -20; then
    log "Chromatic publish succeeded ($(elapsed $CHROMATIC_START))"
  else
    warn "Chromatic reported changes or errors ($(elapsed $CHROMATIC_START))"
    [[ $EXIT_CODE -eq 0 ]] && EXIT_CODE=2
  fi
else
  log "Step 3/3: Chromatic skipped (use --chromatic to enable)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
if [[ $EXIT_CODE -eq 0 ]]; then
  echo -e "${GREEN} ✓ All visual tests passed${NC}"
elif [[ $EXIT_CODE -eq 2 ]]; then
  echo -e "${YELLOW} ⚠ Visual changes detected — review in Chromatic${NC}"
else
  echo -e "${RED} ✗ Test failures detected${NC}"
fi
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Build:     ${BUILD_DIR}/"
echo -e "  Tests:     $(if [[ "$TEST_PASSED" == true ]]; then echo -e "${GREEN}passed${NC}"; else echo -e "${RED}failed${NC}"; fi)"
if [[ "$USE_CHROMATIC" == true ]]; then
  echo -e "  Chromatic: published"
fi
echo ""

exit $EXIT_CODE
