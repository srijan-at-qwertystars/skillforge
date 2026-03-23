#!/usr/bin/env bash
set -euo pipefail

# enable-strict-incremental.sh — Incrementally enable a TypeScript strict flag
#
# Usage:
#   ./enable-strict-incremental.sh <flag> [options]
#
# Arguments:
#   <flag>        Strict flag to enable (e.g., strictNullChecks, noImplicitAny)
#
# Options:
#   --tsconfig    Path to tsconfig.json (default: tsconfig.json)
#   --suppress    Add // @ts-expect-error comments to suppress all new errors
#   --dry-run     Show what would happen but revert tsconfig changes
#   -h, --help    Show this help message
#
# Examples:
#   ./enable-strict-incremental.sh strictNullChecks
#   ./enable-strict-incremental.sh noImplicitAny --dry-run
#   ./enable-strict-incremental.sh strictNullChecks --suppress
#   ./enable-strict-incremental.sh strictFunctionTypes --tsconfig tsconfig.base.json
#
# Supported flags:
#   strictNullChecks, noImplicitAny, strictBindCallApply, strictFunctionTypes,
#   strictPropertyInitialization, noImplicitThis, useUnknownInCatchVariables, alwaysStrict

FLAG=""
TSCONFIG="tsconfig.json"
SUPPRESS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tsconfig)
      TSCONFIG="$2"
      shift 2
      ;;
    --suppress)
      SUPPRESS=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      sed -n '3,22p' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      FLAG="$1"
      shift
      ;;
  esac
done

if [[ -z "$FLAG" ]]; then
  echo "Error: No flag specified." >&2
  echo "Usage: $0 <flag> [--tsconfig path] [--suppress] [--dry-run]" >&2
  exit 1
fi

VALID_FLAGS=(
  strictNullChecks noImplicitAny strictBindCallApply strictFunctionTypes
  strictPropertyInitialization noImplicitThis useUnknownInCatchVariables alwaysStrict
)

FLAG_VALID=false
for vf in "${VALID_FLAGS[@]}"; do
  if [[ "$vf" == "$FLAG" ]]; then
    FLAG_VALID=true
    break
  fi
done

if [[ "$FLAG_VALID" == false ]]; then
  echo "Error: '$FLAG' is not a recognized strict flag." >&2
  echo "Valid flags: ${VALID_FLAGS[*]}" >&2
  exit 1
fi

if [[ ! -f "$TSCONFIG" ]]; then
  echo "Error: '$TSCONFIG' not found." >&2
  exit 1
fi

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo -e "${BOLD}=== Enable Strict Flag: ${CYAN}$FLAG${RESET}${BOLD} ===${RESET}"
echo ""

# --- Back up tsconfig ---
TSCONFIG_BACKUP=$(mktemp)
cp "$TSCONFIG" "$TSCONFIG_BACKUP"

restore_tsconfig() {
  cp "$TSCONFIG_BACKUP" "$TSCONFIG"
  rm -f "$TSCONFIG_BACKUP"
}

# --- Check if flag is already enabled ---
if node -e "
  const fs = require('fs');
  const raw = fs.readFileSync('$TSCONFIG', 'utf8');
  // Strip single-line // comments for JSON parsing
  const stripped = raw.replace(/\/\/.*$/gm, '').replace(/,(\s*[}\]])/g, '\$1');
  const config = JSON.parse(stripped);
  const co = config.compilerOptions || {};
  if (co['$FLAG'] === true || co.strict === true) {
    process.exit(0);
  }
  process.exit(1);
" 2>/dev/null; then
  echo -e "${GREEN}Flag '$FLAG' (or 'strict') is already enabled in $TSCONFIG.${RESET}"
  rm -f "$TSCONFIG_BACKUP"
  exit 0
fi

# --- Enable the flag in tsconfig.json ---
echo -e "Enabling ${CYAN}\"$FLAG\": true${RESET} in $TSCONFIG..."

node -e "
  const fs = require('fs');
  const raw = fs.readFileSync('$TSCONFIG', 'utf8');

  // Try to insert the flag into compilerOptions
  // Strategy: find '\"compilerOptions\"' block and add the flag
  if (raw.includes('\"compilerOptions\"')) {
    // Check if flag already exists (even as false or commented)
    const flagRegex = new RegExp('\"$FLAG\"\\s*:\\s*(true|false)');
    let updated;
    if (flagRegex.test(raw)) {
      // Replace existing value
      updated = raw.replace(flagRegex, '\"$FLAG\": true');
    } else {
      // Insert after compilerOptions opening brace
      updated = raw.replace(
        /(\"compilerOptions\"\s*:\s*\{)/,
        '\$1\n    \"$FLAG\": true,'
      );
    }
    fs.writeFileSync('$TSCONFIG', updated);
  } else {
    console.error('Could not find compilerOptions in $TSCONFIG');
    process.exit(1);
  }
"

echo -e "${GREEN}Flag enabled.${RESET}"
echo ""

# --- Run tsc --noEmit to capture errors ---
echo -e "${BOLD}Running tsc --noEmit...${RESET}"
echo ""

TSC_OUTPUT_FILE=$(mktemp)
trap 'rm -f "$TSC_OUTPUT_FILE" "$TSCONFIG_BACKUP"' EXIT

TSC_EXIT=0
npx tsc --noEmit --project "$TSCONFIG" 2>&1 > "$TSC_OUTPUT_FILE" || TSC_EXIT=$?

if [[ "$TSC_EXIT" -eq 0 ]]; then
  echo -e "${GREEN}No errors! Flag '$FLAG' can be enabled cleanly. 🎉${RESET}"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}--dry-run: Reverting tsconfig changes.${RESET}"
    restore_tsconfig
  fi
  exit 0
fi

TOTAL_ERRORS=$(grep -cE '^.+\([0-9]+,[0-9]+\): error TS[0-9]+' "$TSC_OUTPUT_FILE" || true)
echo -e "${RED}Total errors with '$FLAG' enabled: $TOTAL_ERRORS${RESET}"
echo ""

# --- Report error count per file ---
echo -e "${BOLD}Errors per file:${RESET}"
grep -oE '^[^(]+' "$TSC_OUTPUT_FILE" \
  | grep -E '\.(ts|tsx)$' \
  | sort | uniq -c | sort -rn \
  | while read -r count file; do
    printf "  %5d  %s\n" "$count" "$file"
  done

echo ""

# --- Error categories ---
echo -e "${BOLD}Error categories:${RESET}"
grep -oE 'error TS[0-9]+' "$TSC_OUTPUT_FILE" \
  | sort | uniq -c | sort -rn \
  | while read -r count code; do
    printf "  %5d  %s\n" "$count" "$code"
  done

echo ""

# --- Suppress errors with @ts-expect-error ---
if [[ "$SUPPRESS" == true && "$DRY_RUN" == false ]]; then
  echo -e "${BOLD}Adding // @ts-expect-error suppressions...${RESET}"

  # Parse error locations: file(line,col): error TSxxxx: message
  SUPPRESS_COUNT=0

  # Collect all file:line pairs, process in reverse order per file to avoid line shifts
  grep -E '^.+\([0-9]+,[0-9]+\): error TS[0-9]+' "$TSC_OUTPUT_FILE" \
    | sed -E 's/^(.+)\(([0-9]+),[0-9]+\): (error TS[0-9]+: .*)$/\1:\2:\3/' \
    | sort -t: -k1,1 -k2,2rn \
    | while IFS=: read -r filepath lineno rest; do
      if [[ ! -f "$filepath" ]]; then
        continue
      fi
      error_code=$(echo "$rest" | grep -oE 'TS[0-9]+' | head -1)
      # Get the indentation of the error line
      target_line=$(sed -n "${lineno}p" "$filepath" 2>/dev/null || true)
      indent=$(echo "$target_line" | sed -E 's/^( *).*/\1/')
      # Insert @ts-expect-error above the line
      sed -i "${lineno}i\\${indent}// @ts-expect-error $error_code - strict migration" "$filepath"
      SUPPRESS_COUNT=$((SUPPRESS_COUNT + 1))
    done

  echo -e "${GREEN}Added $SUPPRESS_COUNT // @ts-expect-error suppressions.${RESET}"
  echo -e "${YELLOW}Review and fix these suppressions incrementally.${RESET}"
  echo ""
elif [[ "$SUPPRESS" == true && "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}--dry-run: Would add // @ts-expect-error to $TOTAL_ERRORS error locations.${RESET}"
  echo ""
fi

# --- Dry-run: revert tsconfig ---
if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}--dry-run: Reverting tsconfig changes.${RESET}"
  restore_tsconfig
  echo -e "${GREEN}$TSCONFIG restored to original state.${RESET}"
else
  echo -e "${CYAN}$TSCONFIG has been updated with \"$FLAG\": true.${RESET}"
  echo -e "Fix the errors above, or re-run with --suppress for gradual adoption."
fi

rm -f "$TSCONFIG_BACKUP"
