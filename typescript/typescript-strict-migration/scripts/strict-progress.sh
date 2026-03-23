#!/usr/bin/env bash
set -euo pipefail

# strict-progress.sh — Track TypeScript strict migration progress
#
# Usage:
#   ./strict-progress.sh [src-dir] [--tsconfig path/to/tsconfig.json]
#
# Examples:
#   ./strict-progress.sh                     # Scan current directory
#   ./strict-progress.sh src                 # Scan src/ directory
#   ./strict-progress.sh src --tsconfig tsconfig.strict.json
#
# What it does:
#   1. Counts total .ts/.tsx files
#   2. Counts files with @ts-strict-check or @ts-strict-ignore directives
#   3. Shows percentage of files migrated to strict
#   4. Runs tsc --noEmit and parses errors by file and category
#   5. Groups errors by error code (TS2322, TS2345, TS7006, etc.)
#   6. Suggests which files to tackle next (fewest errors first)

SRC_DIR="."
TSCONFIG="tsconfig.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tsconfig)
      TSCONFIG="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '3,14p' "$0"
      exit 0
      ;;
    *)
      SRC_DIR="$1"
      shift
      ;;
  esac
done

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: Directory '$SRC_DIR' does not exist." >&2
  exit 1
fi

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo -e "${BOLD}=== TypeScript Strict Migration Progress ===${RESET}"
echo ""

# --- 1. Count total .ts/.tsx files (excluding node_modules, .d.ts) ---
TOTAL_FILES=$(find "$SRC_DIR" -type f \( -name '*.ts' -o -name '*.tsx' \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -name '*.d.ts' | wc -l)

echo -e "${BOLD}Total .ts/.tsx files:${RESET} $TOTAL_FILES"

if [[ "$TOTAL_FILES" -eq 0 ]]; then
  echo "No TypeScript files found in '$SRC_DIR'."
  exit 0
fi

# --- 2. Count files with strict directives ---
STRICT_CHECK_FILES=$(grep -rl '@ts-strict-check\|// @ts-strict$\|//@ts-strict$' "$SRC_DIR" \
  --include='*.ts' --include='*.tsx' \
  --exclude-dir=node_modules --exclude-dir=.git 2>/dev/null | wc -l || true)

STRICT_IGNORE_FILES=$(grep -rl '@ts-strict-ignore' "$SRC_DIR" \
  --include='*.ts' --include='*.tsx' \
  --exclude-dir=node_modules --exclude-dir=.git 2>/dev/null | wc -l || true)

echo -e "${GREEN}Files with @ts-strict-check / @ts-strict:${RESET} $STRICT_CHECK_FILES"
echo -e "${YELLOW}Files with @ts-strict-ignore:${RESET} $STRICT_IGNORE_FILES"

# Files without any directive are considered not yet opted in
NO_DIRECTIVE_FILES=$((TOTAL_FILES - STRICT_CHECK_FILES - STRICT_IGNORE_FILES))
echo -e "Files without directive: $NO_DIRECTIVE_FILES"

# --- 3. Migration percentage ---
# Files that are strict = files with @ts-strict-check (opted in)
# If using typescript-strict-plugin, files WITHOUT @ts-strict-ignore are strict
# We show both interpretations
if [[ "$STRICT_CHECK_FILES" -gt 0 || "$STRICT_IGNORE_FILES" -gt 0 ]]; then
  echo ""
  echo -e "${BOLD}Migration percentage:${RESET}"

  if [[ "$STRICT_CHECK_FILES" -gt 0 ]]; then
    PCT_OPTIN=$(( STRICT_CHECK_FILES * 100 / TOTAL_FILES ))
    echo -e "  Opt-in model  (@ts-strict-check present): ${CYAN}${PCT_OPTIN}%${RESET} ($STRICT_CHECK_FILES / $TOTAL_FILES)"
  fi

  if [[ "$STRICT_IGNORE_FILES" -gt 0 ]]; then
    MIGRATED=$((TOTAL_FILES - STRICT_IGNORE_FILES))
    PCT_OPTOUT=$(( MIGRATED * 100 / TOTAL_FILES ))
    echo -e "  Opt-out model (no @ts-strict-ignore):     ${CYAN}${PCT_OPTOUT}%${RESET} ($MIGRATED / $TOTAL_FILES)"
  fi
else
  echo ""
  echo -e "${YELLOW}No strict directives found. Migration tracking via directives not active.${RESET}"
fi

# --- 4. Run tsc and parse errors ---
echo ""
echo -e "${BOLD}=== Type Errors (tsc --noEmit) ===${RESET}"
echo ""

TSC_CMD="npx tsc --noEmit"
if [[ -f "$TSCONFIG" ]]; then
  TSC_CMD="npx tsc --noEmit --project $TSCONFIG"
fi

TSC_OUTPUT_FILE=$(mktemp)
trap 'rm -f "$TSC_OUTPUT_FILE"' EXIT

if $TSC_CMD 2>&1 > "$TSC_OUTPUT_FILE"; then
  echo -e "${GREEN}No type errors found! 🎉${RESET}"
  exit 0
fi

TOTAL_ERRORS=$(grep -cE '^.+\([0-9]+,[0-9]+\): error TS[0-9]+' "$TSC_OUTPUT_FILE" || true)
echo -e "${RED}Total type errors: $TOTAL_ERRORS${RESET}"
echo ""

# --- 5. Group errors by category ---
echo -e "${BOLD}Errors by category:${RESET}"
grep -oE 'error TS[0-9]+' "$TSC_OUTPUT_FILE" \
  | sort | uniq -c | sort -rn \
  | while read -r count code; do
    desc=""
    case "$code" in
      "error TS2322") desc="Type is not assignable" ;;
      "error TS2345") desc="Argument type mismatch" ;;
      "error TS2532") desc="Object is possibly undefined" ;;
      "error TS2531") desc="Object is possibly null" ;;
      "error TS7006") desc="Parameter implicitly has 'any' type" ;;
      "error TS7005") desc="Variable implicitly has 'any' type" ;;
      "error TS2564") desc="Property has no initializer" ;;
      "error TS2769") desc="No overload matches this call" ;;
      "error TS18048") desc="Value is possibly undefined" ;;
      "error TS18047") desc="Value is possibly null" ;;
      "error TS2554") desc="Wrong number of arguments" ;;
      "error TS2339") desc="Property does not exist on type" ;;
      "error TS2353") desc="Object literal may only specify known properties" ;;
      "error TS7031") desc="Binding element implicitly has 'any' type" ;;
      "error TS2741") desc="Property is missing in type" ;;
      *) desc="" ;;
    esac
    if [[ -n "$desc" ]]; then
      printf "  %5d  %s  (%s)\n" "$count" "$code" "$desc"
    else
      printf "  %5d  %s\n" "$count" "$code"
    fi
  done

# --- Errors per file ---
echo ""
echo -e "${BOLD}Errors per file (top 20):${RESET}"
grep -oE '^[^(]+' "$TSC_OUTPUT_FILE" \
  | grep -E '\.(ts|tsx)$' \
  | sort | uniq -c | sort -rn \
  | head -20 \
  | while read -r count file; do
    printf "  %5d  %s\n" "$count" "$file"
  done

# --- 6. Suggest files to tackle next (fewest errors first) ---
echo ""
echo -e "${BOLD}=== Suggested Next Files (fewest errors first) ===${RESET}"
echo -e "Tackle these files first for quick wins:"
echo ""
grep -oE '^[^(]+' "$TSC_OUTPUT_FILE" \
  | grep -E '\.(ts|tsx)$' \
  | sort | uniq -c | sort -n \
  | head -10 \
  | while read -r count file; do
    printf "  %5d errors  %s\n" "$count" "$file"
  done

echo ""
echo -e "${BOLD}Done.${RESET} Fix the suggested files, then re-run to track progress."
