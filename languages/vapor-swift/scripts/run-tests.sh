#!/usr/bin/env bash
# run-tests.sh — Run Vapor tests with a Docker PostgreSQL instance
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
DB_IMAGE="${DB_IMAGE:-postgres:16-alpine}"
DB_CONTAINER="${DB_CONTAINER:-vapor-test-db}"
DB_PORT="${DB_PORT:-5433}"          # Non-default port to avoid conflicts
DB_USER="${DB_USER:-vapor_test}"
DB_PASS="${DB_PASS:-vapor_test}"
DB_NAME="${DB_NAME:-vapor_test_db}"
SWIFT_TEST_ARGS="${SWIFT_TEST_ARGS:-}"
FILTER="${FILTER:-}"
VERBOSE="${VERBOSE:-false}"
CLEANUP="${CLEANUP:-true}"
TIMEOUT="${TIMEOUT:-300}"           # 5 minute timeout

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --filter)    FILTER="$2"; shift 2 ;;
        --verbose)   VERBOSE="true"; shift ;;
        --no-cleanup) CLEANUP="false"; shift ;;
        --timeout)   TIMEOUT="$2"; shift 2 ;;
        --port)      DB_PORT="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 [options]"
            echo "  --filter PATTERN   Run only tests matching pattern"
            echo "  --verbose          Enable verbose test output"
            echo "  --no-cleanup       Don't remove DB container after tests"
            echo "  --timeout SECS     Test timeout in seconds (default: 300)"
            echo "  --port PORT        PostgreSQL port (default: 5433)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Cleanup Function ───────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [ "${CLEANUP}" = "true" ]; then
        echo ""
        echo "==> Cleaning up test database..."
        docker rm -f "${DB_CONTAINER}" 2>/dev/null || true
    else
        echo "==> Keeping test database container: ${DB_CONTAINER}"
        echo "    Connect: psql -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME}"
    fi
    exit $exit_code
}
trap cleanup EXIT

echo "╔══════════════════════════════════════════════════╗"
echo "║  Vapor Test Runner                              ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── Verify Prerequisites ───────────────────────────────────────
if [ ! -f "Package.swift" ]; then
    echo "❌ Package.swift not found. Run this from the project root."
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "❌ Docker is required but not found."
    exit 1
fi

if ! command -v swift &>/dev/null; then
    echo "❌ Swift is required but not found."
    exit 1
fi

# ─── Start PostgreSQL ───────────────────────────────────────────
echo "==> Starting PostgreSQL (${DB_IMAGE})..."

# Remove existing container if present
docker rm -f "${DB_CONTAINER}" 2>/dev/null || true

docker run -d \
    --name "${DB_CONTAINER}" \
    -e POSTGRES_USER="${DB_USER}" \
    -e POSTGRES_PASSWORD="${DB_PASS}" \
    -e POSTGRES_DB="${DB_NAME}" \
    -p "${DB_PORT}:5432" \
    "${DB_IMAGE}" \
    > /dev/null

# Wait for PostgreSQL to be ready
echo -n "==> Waiting for PostgreSQL"
MAX_WAIT=30
WAITED=0
until docker exec "${DB_CONTAINER}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" &>/dev/null; do
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo ""
        echo "❌ PostgreSQL failed to start within ${MAX_WAIT}s"
        docker logs "${DB_CONTAINER}"
        exit 1
    fi
    echo -n "."
    sleep 1
    WAITED=$((WAITED + 1))
done
echo " ready! (${WAITED}s)"

# ─── Set Environment Variables ───────────────────────────────────
export DB_HOST="localhost"
export DB_PORT="${DB_PORT}"
export DB_USER="${DB_USER}"
export DB_PASS="${DB_PASS}"
export DB_NAME="${DB_NAME}"
export LOG_LEVEL="notice"

# ─── Build Tests ────────────────────────────────────────────────
echo ""
echo "==> Building tests..."
BUILD_START=$(date +%s)

swift build --build-tests 2>&1 | tail -5
BUILD_STATUS=${PIPESTATUS[0]}

if [ $BUILD_STATUS -ne 0 ]; then
    echo "❌ Test build failed"
    exit 1
fi

BUILD_END=$(date +%s)
echo "✅ Build complete ($((BUILD_END - BUILD_START))s)"

# ─── Run Tests ──────────────────────────────────────────────────
echo ""
echo "==> Running tests..."

TEST_CMD="swift test"

if [ -n "${FILTER}" ]; then
    TEST_CMD="${TEST_CMD} --filter ${FILTER}"
fi

if [ "${VERBOSE}" = "true" ]; then
    TEST_CMD="${TEST_CMD} --verbose"
fi

if [ -n "${SWIFT_TEST_ARGS}" ]; then
    TEST_CMD="${TEST_CMD} ${SWIFT_TEST_ARGS}"
fi

echo "   Command: ${TEST_CMD}"
echo ""

TEST_START=$(date +%s)

# Run with timeout
if command -v timeout &>/dev/null; then
    timeout "${TIMEOUT}" ${TEST_CMD}
    TEST_EXIT=$?
else
    ${TEST_CMD}
    TEST_EXIT=$?
fi

TEST_END=$(date +%s)
TEST_DURATION=$((TEST_END - TEST_START))

echo ""
if [ $TEST_EXIT -eq 0 ]; then
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  ✅ All tests passed! (${TEST_DURATION}s)        "
    echo "╚══════════════════════════════════════════════════╝"
else
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  ❌ Tests failed (exit code: ${TEST_EXIT})       "
    echo "╚══════════════════════════════════════════════════╝"
fi

exit $TEST_EXIT
