#!/usr/bin/env bash
# coverage-check.sh — Run Vitest coverage and check against thresholds
#
# Usage:
#   ./coverage-check.sh [threshold]
#
# Arguments:
#   threshold  Minimum coverage % for all categories (default: 80)
#
# Examples:
#   ./coverage-check.sh          # Check with 80% threshold
#   ./coverage-check.sh 90       # Check with 90% threshold
#
# Outputs a summary table and exits non-zero if any threshold is not met.
# Expects Vitest and @vitest/coverage-v8 (or istanbul) to be installed.

set -euo pipefail

THRESHOLD="${1:-80}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
fail()  { echo -e "${RED}✖${NC} $*"; }

# ── Detect package manager ──────────────────────────────────────────
detect_pm() {
  if [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then echo "bun"
  elif [ -f "pnpm-lock.yaml" ]; then echo "pnpm"
  elif [ -f "yarn.lock" ]; then echo "yarn"
  else echo "npm"
  fi
}

PM=$(detect_pm)

# ── Validate prerequisites ──────────────────────────────────────────
[ -f "package.json" ] || { fail "No package.json found"; exit 1; }

# ── Run coverage ────────────────────────────────────────────────────
COVERAGE_DIR="coverage"
COVERAGE_JSON="$COVERAGE_DIR/coverage-summary.json"

info "Running Vitest with coverage (threshold: ${THRESHOLD}%)..."
echo ""

# Run vitest with JSON summary reporter to get machine-readable output
npx vitest run --coverage --coverage.reporter=json-summary --coverage.reporter=text 2>&1 || true

echo ""

# ── Parse coverage results ──────────────────────────────────────────
if [ ! -f "$COVERAGE_JSON" ]; then
  fail "Coverage summary not found at $COVERAGE_JSON"
  echo "  Ensure @vitest/coverage-v8 or @vitest/coverage-istanbul is installed."
  exit 1
fi

# Extract totals using node (avoids jq dependency)
read -r LINES BRANCHES FUNCTIONS STATEMENTS < <(node -e "
  const data = require('./$COVERAGE_JSON');
  const t = data.total;
  console.log(
    t.lines.pct,
    t.branches.pct,
    t.functions.pct,
    t.statements.pct
  );
")

# ── Check thresholds ────────────────────────────────────────────────
PASS=true

check_threshold() {
  local name="$1"
  local value="$2"
  local threshold="$3"
  local status

  if (( $(echo "$value >= $threshold" | bc -l) )); then
    status="${GREEN}PASS${NC}"
  else
    status="${RED}FAIL${NC}"
    PASS=false
  fi

  printf "  %-12s %6.1f%%   threshold: %s%%   [%b]\n" "$name" "$value" "$threshold" "$status"
}

echo -e "${BOLD}━━━ Coverage Summary ━━━${NC}"
echo ""

check_threshold "Lines"      "$LINES"      "$THRESHOLD"
check_threshold "Branches"   "$BRANCHES"   "$THRESHOLD"
check_threshold "Functions"  "$FUNCTIONS"  "$THRESHOLD"
check_threshold "Statements" "$STATEMENTS" "$THRESHOLD"

echo ""

# ── Per-file failures (files below threshold) ───────────────────────
LOW_FILES=$(node -e "
  const data = require('./$COVERAGE_JSON');
  const threshold = $THRESHOLD;
  const low = [];
  for (const [file, metrics] of Object.entries(data)) {
    if (file === 'total') continue;
    const minPct = Math.min(
      metrics.lines.pct,
      metrics.branches.pct,
      metrics.functions.pct,
      metrics.statements.pct
    );
    if (minPct < threshold) {
      low.push({ file: file.replace(process.cwd() + '/', ''), pct: minPct.toFixed(1) });
    }
  }
  if (low.length > 0) {
    console.log('FILES_BELOW_THRESHOLD');
    low.sort((a, b) => a.pct - b.pct).slice(0, 15).forEach(f => {
      console.log('  ' + f.pct + '%  ' + f.file);
    });
  }
" 2>/dev/null || true)

if echo "$LOW_FILES" | grep -q "FILES_BELOW_THRESHOLD"; then
  echo -e "${YELLOW}Files below ${THRESHOLD}% threshold:${NC}"
  echo "$LOW_FILES" | tail -n +2
  echo ""
fi

# ── Final result ────────────────────────────────────────────────────
if [ "$PASS" = true ]; then
  ok "All coverage thresholds met (≥${THRESHOLD}%)"
  exit 0
else
  fail "Coverage below threshold (${THRESHOLD}%)"
  exit 1
fi
