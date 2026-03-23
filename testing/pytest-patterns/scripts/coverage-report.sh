#!/usr/bin/env bash
set -euo pipefail

# Usage: coverage-report.sh [OPTIONS] [PYTEST_ARGS...]
#
# Runs pytest with coverage (branch coverage enabled) and generates terminal,
# HTML, and XML reports. Enforces a configurable minimum coverage threshold.
#
# Options:
#   -m, --min-coverage PCT    Minimum coverage percentage (default: 80)
#   -s, --source DIR          Source directory to measure (default: auto-detect)
#   -o, --output-dir DIR      Directory for HTML/XML reports (default: htmlcov)
#   --open                    Open HTML report in browser after generation
#   --xml-only                Generate only XML report (for CI pipelines)
#   --no-fail                 Don't exit with error if coverage is below threshold
#   -h, --help                Show this help message
#
# Examples:
#   coverage-report.sh
#   coverage-report.sh -m 90 --open
#   coverage-report.sh -s src/myapp -m 85
#   coverage-report.sh --xml-only tests/unit/
#   coverage-report.sh --no-fail -m 95

MIN_COVERAGE=80
SOURCE_DIR=""
OUTPUT_DIR="htmlcov"
OPEN_REPORT=false
XML_ONLY=false
NO_FAIL=false
PYTHON="${PYTHON:-$(command -v python3 || command -v python)}"
if [[ -z "$PYTHON" ]]; then
    echo "Error: Neither python3 nor python found on PATH." >&2
    exit 1
fi

PYTEST_EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--min-coverage)
            MIN_COVERAGE="$2"; shift 2 ;;
        -s|--source)
            SOURCE_DIR="$2"; shift 2 ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --open)
            OPEN_REPORT=true; shift ;;
        --xml-only)
            XML_ONLY=true; shift ;;
        --no-fail)
            NO_FAIL=true; shift ;;
        -h|--help)
            sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            exit 1
            ;;
        *)
            PYTEST_EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# --- Verify dependencies ---
if ! "$PYTHON" -m pytest --version &>/dev/null; then
    echo "Error: pytest is not installed." >&2
    echo "  pip install pytest pytest-cov" >&2
    exit 1
fi

if ! "$PYTHON" -c "import pytest_cov" &>/dev/null; then
    echo "Error: pytest-cov is not installed." >&2
    echo "  pip install pytest-cov" >&2
    exit 1
fi

# --- Auto-detect source directory ---
if [[ -z "$SOURCE_DIR" ]]; then
    if [[ -d "src" ]]; then
        SOURCE_DIR="src"
    elif [[ -f "setup.py" || -f "pyproject.toml" || -f "setup.cfg" ]]; then
        # Try to find the main package directory
        for candidate in app lib core api main; do
            if [[ -d "$candidate" && -f "$candidate/__init__.py" ]]; then
                SOURCE_DIR="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$SOURCE_DIR" ]]; then
        SOURCE_DIR="."
        echo "⚠  Could not auto-detect source directory; using '.' (current dir)."
        echo "   Use -s/--source to specify explicitly."
        echo ""
    fi
fi

echo "=========================================="
echo " Coverage Report"
echo "=========================================="
echo " Source:           $SOURCE_DIR"
echo " Min coverage:    ${MIN_COVERAGE}%"
echo " Output dir:      $OUTPUT_DIR"
echo "=========================================="
echo ""

# --- Build pytest-cov arguments ---
COV_ARGS=(
    "--cov=$SOURCE_DIR"
    "--cov-branch"
    "--cov-report=term-missing"
)

if [[ "$XML_ONLY" != true ]]; then
    COV_ARGS+=("--cov-report=html:$OUTPUT_DIR")
fi

COV_ARGS+=("--cov-report=xml:${OUTPUT_DIR}/coverage.xml")
COV_ARGS+=("--cov-fail-under=0")  # We handle threshold ourselves for better messaging

# --- Run pytest with coverage ---
TMPFILE=$(mktemp /tmp/coverage-output.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

set +e
"$PYTHON" -m pytest "${COV_ARGS[@]}" "${PYTEST_EXTRA_ARGS[@]}" 2>&1 | tee "$TMPFILE"
PYTEST_EXIT=$?
set -e

echo ""

if [[ $PYTEST_EXIT -eq 5 ]]; then
    echo "Error: No tests were collected." >&2
    exit 1
fi

# --- Parse coverage percentage ---
# Look for the TOTAL line in coverage output: "TOTAL    1234    123    45    12    90%"
COVERAGE_PCT=$(grep -E '^TOTAL\s' "$TMPFILE" | awk '{print $NF}' | tr -d '%' || echo "")

if [[ -z "$COVERAGE_PCT" ]]; then
    echo "⚠  Could not parse coverage percentage from output."
    COVERAGE_PCT="0"
fi

echo "=========================================="
echo " Coverage Summary"
echo "=========================================="
echo ""
echo "  Total coverage:    ${COVERAGE_PCT}%"
echo "  Minimum required:  ${MIN_COVERAGE}%"
echo ""

# --- Show uncovered files ---
echo "Files with missing coverage:"
echo ""
# Extract lines from the coverage table that show missing lines
# Format: "src/module.py    100    10    90%    5-12, 45"
grep -E '^\S+\.py\s+' "$TMPFILE" \
    | awk -v min="$MIN_COVERAGE" '
    {
        # Last field is either percentage or missing lines
        # Find the percentage field (contains %)
        for (i = 1; i <= NF; i++) {
            if ($i ~ /%$/) {
                pct = $i + 0
                file = $1
                # Collect everything after the percentage as missing lines
                missing = ""
                for (j = i+1; j <= NF; j++) {
                    missing = missing (missing ? " " : "") $j
                }
                if (pct < 100 && missing != "") {
                    printf "  %-50s %4s%%  Missing: %s\n", file, pct, missing
                } else if (pct < min) {
                    printf "  %-50s %4s%%\n", file, pct
                }
                break
            }
        }
    }' || true

echo ""

# --- Report locations ---
if [[ "$XML_ONLY" != true && -d "$OUTPUT_DIR" ]]; then
    echo "📁 Reports generated:"
    echo "   HTML: $OUTPUT_DIR/index.html"
fi
if [[ -f "${OUTPUT_DIR}/coverage.xml" ]]; then
    echo "   XML:  ${OUTPUT_DIR}/coverage.xml"
fi
echo ""

# --- Check threshold ---
THRESHOLD_MET=$(awk "BEGIN { print ($COVERAGE_PCT >= $MIN_COVERAGE) ? 1 : 0 }")

if [[ "$THRESHOLD_MET" -eq 1 ]]; then
    echo "✅ Coverage ${COVERAGE_PCT}% meets minimum threshold of ${MIN_COVERAGE}%"
else
    DEFICIT=$(awk "BEGIN { printf \"%.1f\", $MIN_COVERAGE - $COVERAGE_PCT }")
    echo "❌ Coverage ${COVERAGE_PCT}% is below minimum threshold of ${MIN_COVERAGE}%"
    echo "   Need ${DEFICIT}% more coverage to meet the requirement."
    echo ""
    echo "   Tips to increase coverage:"
    echo "   → Run: coverage-report.sh --open  (to see uncovered lines in browser)"
    echo "   → Focus on files with lowest coverage percentages first"
    echo "   → Add tests for error/edge-case branches"
    echo "   → Use # pragma: no cover for intentionally uncovered code"

    if [[ "$NO_FAIL" != true ]]; then
        exit 1
    fi
fi

# --- Open HTML report if requested ---
if [[ "$OPEN_REPORT" == true && "$XML_ONLY" != true && -f "$OUTPUT_DIR/index.html" ]]; then
    echo ""
    echo "Opening HTML report in browser..."
    if command -v xdg-open &>/dev/null; then
        xdg-open "$OUTPUT_DIR/index.html" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "$OUTPUT_DIR/index.html"
    elif command -v start &>/dev/null; then
        start "$OUTPUT_DIR/index.html"
    else
        echo "Could not detect a browser opener. Open manually:"
        echo "  $OUTPUT_DIR/index.html"
    fi
fi
