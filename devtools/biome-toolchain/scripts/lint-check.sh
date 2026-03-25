#!/usr/bin/env bash
# lint-check.sh — Run Biome checks with different modes and output summary
#
# Usage:
#   ./lint-check.sh [MODE] [PATH]
#
# Modes:
#   check       Full check: lint + format + imports (default)
#   lint        Lint only (no formatting)
#   format      Format check only (no linting)
#   fix         Full check with auto-fix (safe fixes only)
#   fix-all     Full check with all fixes (including unsafe)
#   ci          CI mode (strict, read-only)
#   changed     Check only changed files (vs default branch)
#   staged      Check only git-staged files
#
# Options (via environment variables):
#   BIOME_MAX_DIAG=50         Max diagnostics to show
#   BIOME_REPORTER=default    Reporter: default|json|github|gitlab|junit
#   BIOME_STRICT=1            Fail on warnings too
#
# Examples:
#   ./lint-check.sh check src/
#   ./lint-check.sh lint
#   ./lint-check.sh fix .
#   ./lint-check.sh ci
#   BIOME_REPORTER=github ./lint-check.sh ci
#   ./lint-check.sh changed
#   ./lint-check.sh staged

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Defaults ---
MODE="${1:-check}"
TARGET="${2:-.}"
MAX_DIAG="${BIOME_MAX_DIAG:-}"
REPORTER="${BIOME_REPORTER:-}"
STRICT="${BIOME_STRICT:-}"

# --- Resolve Biome binary ---
if command -v biome &>/dev/null; then
  BIOME="biome"
elif [ -f "node_modules/.bin/biome" ]; then
  BIOME="node_modules/.bin/biome"
elif command -v npx &>/dev/null; then
  BIOME="npx biome"
else
  echo -e "${RED}✗ Biome not found. Install with: npm install --save-dev @biomejs/biome${NC}" >&2
  exit 2
fi

# --- Build flags ---
FLAGS=()

if [ -n "$MAX_DIAG" ]; then
  FLAGS+=("--max-diagnostics=${MAX_DIAG}")
fi

if [ -n "$REPORTER" ]; then
  FLAGS+=("--reporter=${REPORTER}")
fi

if [ -n "$STRICT" ]; then
  FLAGS+=("--error-on-warnings")
fi

# --- Header ---
echo -e "${BOLD}━━━ Biome ${MODE} ━━━${NC}"
echo -e "${BLUE}Target:${NC} ${TARGET}"
echo -e "${BLUE}Biome:${NC}  $(${BIOME} --version 2>/dev/null || echo 'unknown')"
echo ""

# --- Run based on mode ---
START_TIME=$(date +%s%N 2>/dev/null || date +%s)
EXIT_CODE=0

case "$MODE" in
  check)
    echo -e "${BLUE}Running full check (lint + format + imports)...${NC}"
    $BIOME check "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  lint)
    echo -e "${BLUE}Running lint only...${NC}"
    $BIOME lint "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  format)
    echo -e "${BLUE}Running format check only...${NC}"
    $BIOME format "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  fix)
    echo -e "${BLUE}Applying safe fixes...${NC}"
    $BIOME check --write --no-errors-on-unmatched "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  fix-all)
    echo -e "${YELLOW}Applying ALL fixes (including unsafe)...${NC}"
    $BIOME check --write --unsafe --no-errors-on-unmatched "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  ci)
    echo -e "${BLUE}Running CI check (strict, read-only)...${NC}"
    $BIOME ci "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  changed)
    echo -e "${BLUE}Checking changed files only...${NC}"
    $BIOME check --changed "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  staged)
    echo -e "${BLUE}Checking staged files only...${NC}"
    $BIOME check --staged --no-errors-on-unmatched "${FLAGS[@]}" "$TARGET" || EXIT_CODE=$?
    ;;

  *)
    echo -e "${RED}Unknown mode: ${MODE}${NC}" >&2
    echo "Valid modes: check, lint, format, fix, fix-all, ci, changed, staged"
    exit 2
    ;;
esac

# --- Elapsed time ---
END_TIME=$(date +%s%N 2>/dev/null || date +%s)
if [ ${#START_TIME} -gt 10 ] && [ ${#END_TIME} -gt 10 ]; then
  ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
  if [ "$ELAPSED_MS" -lt 1000 ]; then
    ELAPSED="${ELAPSED_MS}ms"
  else
    ELAPSED="$(( ELAPSED_MS / 1000 )).$(( (ELAPSED_MS % 1000) / 100 ))s"
  fi
else
  ELAPSED="$(( END_TIME - START_TIME ))s"
fi

# --- Summary ---
echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo -e "${BLUE}Mode:${NC}    ${MODE}"
echo -e "${BLUE}Time:${NC}    ${ELAPSED}"

if [ "$EXIT_CODE" -eq 0 ]; then
  echo -e "${GREEN}Result:  ✓ All checks passed${NC}"
elif [ "$EXIT_CODE" -eq 1 ]; then
  echo -e "${RED}Result:  ✗ Issues found (see above)${NC}"
elif [ "$EXIT_CODE" -eq 2 ]; then
  echo -e "${RED}Result:  ✗ Configuration or CLI error${NC}"
else
  echo -e "${RED}Result:  ✗ Exited with code ${EXIT_CODE}${NC}"
fi

exit "$EXIT_CODE"
