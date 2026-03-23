#!/usr/bin/env bash
# vitest-coverage-check.sh — Run Vitest coverage and enforce thresholds.
# Parses JSON coverage summary and exits non-zero if thresholds are not met.
# Usage: ./vitest-coverage-check.sh [--lines N] [--branches N] [--functions N] [--statements N]

set -euo pipefail

# Defaults
THRESHOLD_LINES=80
THRESHOLD_BRANCHES=75
THRESHOLD_FUNCTIONS=80
THRESHOLD_STATEMENTS=80
COVERAGE_DIR="coverage"
JSON_SUMMARY="${COVERAGE_DIR}/coverage-summary.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --lines N        Minimum line coverage percentage (default: 80)
  --branches N     Minimum branch coverage percentage (default: 75)
  --functions N    Minimum function coverage percentage (default: 80)
  --statements N   Minimum statement coverage percentage (default: 80)
  --coverage-dir   Coverage output directory (default: coverage)
  --skip-run       Skip running vitest, use existing coverage data
  -h, --help       Show this help

Examples:
  $(basename "$0")                          # Run with defaults
  $(basename "$0") --lines 90 --branches 85 # Custom thresholds
  $(basename "$0") --skip-run               # Check existing coverage
EOF
  exit 0
}

SKIP_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines)      THRESHOLD_LINES="$2"; shift 2 ;;
    --branches)   THRESHOLD_BRANCHES="$2"; shift 2 ;;
    --functions)  THRESHOLD_FUNCTIONS="$2"; shift 2 ;;
    --statements) THRESHOLD_STATEMENTS="$2"; shift 2 ;;
    --coverage-dir) COVERAGE_DIR="$2"; JSON_SUMMARY="${COVERAGE_DIR}/coverage-summary.json"; shift 2 ;;
    --skip-run)   SKIP_RUN=true; shift ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Run vitest with coverage if not skipping
if [[ "$SKIP_RUN" != true ]]; then
  echo "Running vitest with coverage..."
  npx vitest run --coverage --coverage.reporter=json-summary --coverage.reporter=text 2>&1 || true
fi

# Check for coverage summary
if [[ ! -f "$JSON_SUMMARY" ]]; then
  echo -e "${RED}[error]${NC} Coverage summary not found at ${JSON_SUMMARY}"
  echo "Run with coverage first: npx vitest run --coverage --coverage.reporter=json-summary"
  exit 1
fi

# Parse coverage summary with Node.js
RESULTS=$(node -e "
  const fs = require('fs');
  const summary = JSON.parse(fs.readFileSync('${JSON_SUMMARY}', 'utf8'));
  const total = summary.total;
  console.log(JSON.stringify({
    lines: total.lines.pct,
    branches: total.branches.pct,
    functions: total.functions.pct,
    statements: total.statements.pct,
  }));
")

LINES=$(echo "$RESULTS" | node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync(0,'utf8')).lines))")
BRANCHES=$(echo "$RESULTS" | node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync(0,'utf8')).branches))")
FUNCTIONS=$(echo "$RESULTS" | node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync(0,'utf8')).functions))")
STATEMENTS=$(echo "$RESULTS" | node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync(0,'utf8')).statements))")

echo ""
echo "Coverage Results:"
echo "================================"

FAILED=false

check_threshold() {
  local name="$1"
  local actual="$2"
  local threshold="$3"

  local passed
  passed=$(node -e "process.stdout.write(Number($actual) >= Number($threshold) ? 'true' : 'false')")

  if [[ "$passed" == "true" ]]; then
    printf "  ${GREEN}✓${NC} %-12s %6s%% >= %s%%\n" "$name" "$actual" "$threshold"
  else
    printf "  ${RED}✗${NC} %-12s %6s%% < %s%%\n" "$name" "$actual" "$threshold"
    FAILED=true
  fi
}

check_threshold "Lines"      "$LINES"      "$THRESHOLD_LINES"
check_threshold "Branches"   "$BRANCHES"   "$THRESHOLD_BRANCHES"
check_threshold "Functions"  "$FUNCTIONS"   "$THRESHOLD_FUNCTIONS"
check_threshold "Statements" "$STATEMENTS" "$THRESHOLD_STATEMENTS"

echo "================================"
echo ""

if [[ "$FAILED" == true ]]; then
  echo -e "${RED}Coverage thresholds not met!${NC}"
  exit 1
else
  echo -e "${GREEN}All coverage thresholds passed!${NC}"
  exit 0
fi
