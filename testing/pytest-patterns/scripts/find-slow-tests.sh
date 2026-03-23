#!/usr/bin/env bash
set -euo pipefail

# Usage: find-slow-tests.sh [OPTIONS] [PYTEST_ARGS...]
#
# Identifies slow tests in a pytest suite by running with --durations=0,
# parsing the output, and highlighting tests that exceed a configurable
# time threshold. Suggests optimizations for common slow-test patterns.
#
# Options:
#   -t, --threshold SECONDS   Duration threshold in seconds (default: 1.0)
#   -n, --top N               Show only the top N slowest tests (default: all)
#   --no-run                  Parse an existing pytest output file instead of
#                             running pytest. Pass the file as the next argument.
#   -h, --help                Show this help message
#
# Examples:
#   find-slow-tests.sh
#   find-slow-tests.sh -t 0.5
#   find-slow-tests.sh -t 2.0 -n 10
#   find-slow-tests.sh --no-run pytest-output.txt
#   find-slow-tests.sh tests/unit/           # pass extra args to pytest

THRESHOLD="1.0"
TOP_N=""
NO_RUN=false
INPUT_FILE=""
PYTEST_EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--threshold)
            THRESHOLD="$2"; shift 2 ;;
        -n|--top)
            TOP_N="$2"; shift 2 ;;
        --no-run)
            NO_RUN=true
            INPUT_FILE="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            PYTEST_EXTRA_ARGS+=("$1"); shift ;;
    esac
done

PYTHON="${PYTHON:-$(command -v python3 || command -v python)}"
if [[ -z "$PYTHON" ]]; then
    echo "Error: Neither python3 nor python found on PATH." >&2
    exit 1
fi

TMPFILE=$(mktemp /tmp/pytest-durations.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

# --- Run pytest or use existing output ---
if [[ "$NO_RUN" == true ]]; then
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: File not found: $INPUT_FILE" >&2
        exit 1
    fi
    cp "$INPUT_FILE" "$TMPFILE"
    echo "Parsing existing pytest output: $INPUT_FILE"
else
    echo "Running pytest with --durations=0 to capture all test timings..."
    echo ""
    # Run pytest, capturing output. Allow non-zero exit (tests may fail).
    set +e
    "$PYTHON" -m pytest --durations=0 -q "${PYTEST_EXTRA_ARGS[@]}" 2>&1 | tee "$TMPFILE"
    PYTEST_EXIT=$?
    set -e
    echo ""

    if [[ $PYTEST_EXIT -eq 5 ]]; then
        echo "Error: No tests were collected. Check your test paths." >&2
        exit 1
    fi
fi

# --- Parse durations from pytest output ---
# pytest outputs lines like: "1.23s call     tests/test_foo.py::TestClass::test_method"
# or in newer versions:      "1.23s call     tests/test_foo.py::test_function"
DURATIONS_SECTION=$(mktemp /tmp/pytest-parsed.XXXXXX)
trap 'rm -f "$TMPFILE" "$DURATIONS_SECTION"' EXIT

# Extract duration lines (format: NNNs call/setup/teardown path::test)
grep -E '^\s*[0-9]+\.[0-9]+s (call|setup|teardown)\s+' "$TMPFILE" \
    | grep -E '^\s*[0-9]+\.[0-9]+s call\s+' \
    | sed 's/^\s*//' \
    | sort -t's' -k1 -rn \
    > "$DURATIONS_SECTION" 2>/dev/null || true

TOTAL_TESTS=$(wc -l < "$DURATIONS_SECTION" | tr -d ' ')

if [[ "$TOTAL_TESTS" -eq 0 ]]; then
    echo "No test duration data found."
    echo "Make sure pytest is installed and tests exist in the project."
    exit 0
fi

# --- Display results ---
echo "=========================================="
echo " Slow Test Report (threshold: ${THRESHOLD}s)"
echo "=========================================="
echo ""

SLOW_COUNT=0
LINE_NUM=0

while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))

    # Apply --top limit
    if [[ -n "$TOP_N" && "$LINE_NUM" -gt "$TOP_N" ]]; then
        break
    fi

    # Extract duration value
    DURATION=$(echo "$line" | grep -oE '^[0-9]+\.[0-9]+')
    TEST_PATH=$(echo "$line" | sed 's/^[0-9.]*s call\s*//')

    # Compare with threshold using awk for float comparison
    IS_SLOW=$(awk "BEGIN { print ($DURATION >= $THRESHOLD) ? 1 : 0 }")

    if [[ "$IS_SLOW" -eq 1 ]]; then
        SLOW_COUNT=$((SLOW_COUNT + 1))
        echo "  🐌 ${DURATION}s  $TEST_PATH"
    else
        echo "     ${DURATION}s  $TEST_PATH"
    fi
done < "$DURATIONS_SECTION"

echo ""
echo "------------------------------------------"
echo " Total tests with timings: $TOTAL_TESTS"
echo " Tests over threshold:     $SLOW_COUNT"
if [[ -n "$TOP_N" ]]; then
    echo " Showing top:             $TOP_N"
fi
echo "------------------------------------------"

# --- Suggest optimizations if slow tests found ---
if [[ "$SLOW_COUNT" -gt 0 ]]; then
    echo ""
    echo "💡 Optimization suggestions:"
    echo ""

    # Check for common slow-test patterns in the slow test files
    SLOW_FILES=$(awk "BEGIN{t=$THRESHOLD} {
        split(\$1, a, \"s\");
        if (a[1]+0 >= t) {
            sub(/^[0-9.]*s call[[:space:]]*/, \"\");
            sub(/::.*/, \"\");
            print
        }
    }" "$DURATIONS_SECTION" | sort -u)

    HAS_SLEEP=false
    HAS_NETWORK=false
    HAS_DB=false
    HAS_FIXTURE_SETUP=false

    for f in $SLOW_FILES; do
        if [[ -f "$f" ]]; then
            if grep -qE 'time\.sleep|asyncio\.sleep' "$f" 2>/dev/null; then
                HAS_SLEEP=true
            fi
            if grep -qE 'requests\.|httpx\.|urllib|aiohttp' "$f" 2>/dev/null; then
                HAS_NETWORK=true
            fi
            if grep -qE 'session\.execute|\.query\(|cursor\.' "$f" 2>/dev/null; then
                HAS_DB=true
            fi
        fi
    done

    # Check conftest.py for heavy fixtures
    if [[ -f "tests/conftest.py" ]]; then
        if grep -qE 'scope=["\x27]function' "tests/conftest.py" 2>/dev/null; then
            HAS_FIXTURE_SETUP=true
        fi
    fi

    if [[ "$HAS_SLEEP" == true ]]; then
        echo "  ⏱  Found time.sleep() calls in slow tests."
        echo "     → Use unittest.mock.patch('time.sleep') or freezegun to avoid real waits."
        echo ""
    fi

    if [[ "$HAS_NETWORK" == true ]]; then
        echo "  🌐 Found network library imports in slow tests."
        echo "     → Mock HTTP calls with responses, respx, or pytest-httpx."
        echo "     → Use VCR.py to record/replay HTTP interactions."
        echo ""
    fi

    if [[ "$HAS_DB" == true ]]; then
        echo "  🗄  Found database operations in slow tests."
        echo "     → Use an in-memory SQLite database for unit tests."
        echo "     → Scope DB fixtures to 'session' or 'module' instead of 'function'."
        echo "     → Use factory_boy for efficient test data creation."
        echo ""
    fi

    if [[ "$HAS_FIXTURE_SETUP" == true ]]; then
        echo "  🔧 Found function-scoped fixtures that might be expensive."
        echo "     → Consider using scope='module' or scope='session' for costly setup."
        echo ""
    fi

    echo "  General tips:"
    echo "  → Run slow tests separately: pytest -m slow"
    echo "  → Parallelize with: pytest -n auto (requires pytest-xdist)"
    echo "  → Profile with: pytest --profile (requires pytest-profiling)"
    echo "  → Mark slow tests: @pytest.mark.slow"
fi
