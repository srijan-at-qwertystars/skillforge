#!/usr/bin/env bash
set -euo pipefail

# find-any-types.sh — Find explicit and implicit `any` usage in a TypeScript project
#
# Usage:
#   ./find-any-types.sh [src-dir] [options]
#
# Options:
#   --include-tests    Include test files (*.test.ts, *.spec.ts, __tests__/)
#   --json             Output results as JSON
#   -h, --help         Show this help message
#
# Examples:
#   ./find-any-types.sh                  # Scan current directory
#   ./find-any-types.sh src              # Scan src/ directory
#   ./find-any-types.sh --include-tests  # Include test files
#
# What it does:
#   1. Finds explicit `any` annotations (: any, as any, <any>)
#   2. Reports locations with file:line
#   3. Categorizes: explicit any, type assertion any, function parameter any
#   4. Counts per file and total
#   5. Excludes test files and node_modules by default
#   6. Suggests typed alternatives for common patterns

SRC_DIR="."
INCLUDE_TESTS=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-tests)
      INCLUDE_TESTS=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    -h|--help)
      sed -n '3,18p' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
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
DIM='\033[2m'
RESET='\033[0m'

# --- Build exclusion patterns ---
EXCLUDE_ARGS=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build --exclude='*.d.ts')

if [[ "$INCLUDE_TESTS" == false ]]; then
  EXCLUDE_ARGS+=(
    --exclude-dir=__tests__
    --exclude-dir=__mocks__
    --exclude='*.test.ts'
    --exclude='*.test.tsx'
    --exclude='*.spec.ts'
    --exclude='*.spec.tsx'
  )
fi

# --- Collect all matches into a temp file ---
MATCHES_FILE=$(mktemp)
trap 'rm -f "$MATCHES_FILE"' EXIT

# Grep for patterns containing `any` as a type
# We use word-boundary-aware patterns to avoid matching "many", "company", etc.
grep -rnE '(:\s*any\b|<any>|as\s+any\b|\bany\s*[,\)\]>|])' \
  "${EXCLUDE_ARGS[@]}" \
  --include='*.ts' --include='*.tsx' \
  "$SRC_DIR" 2>/dev/null \
  | grep -vE '//.*\bany\b.*$' \
  > "$MATCHES_FILE" || true

# Re-run without filtering comments to get all matches, then we'll categorize
# Actually, let's get everything and categorize properly
> "$MATCHES_FILE"

# Pattern 1: Explicit type annotation `: any`
grep -rnE ':\s*any\b' \
  "${EXCLUDE_ARGS[@]}" \
  --include='*.ts' --include='*.tsx' \
  "$SRC_DIR" 2>/dev/null \
  | while IFS= read -r line; do
    echo "EXPLICIT_ANY|$line"
  done >> "$MATCHES_FILE" || true

# Pattern 2: Type assertion `as any`
grep -rnE '\bas\s+any\b' \
  "${EXCLUDE_ARGS[@]}" \
  --include='*.ts' --include='*.tsx' \
  "$SRC_DIR" 2>/dev/null \
  | while IFS= read -r line; do
    echo "ASSERTION_ANY|$line"
  done >> "$MATCHES_FILE" || true

# Pattern 3: Generic type parameter `<any>`
grep -rnE '<any>' \
  "${EXCLUDE_ARGS[@]}" \
  --include='*.ts' --include='*.tsx' \
  "$SRC_DIR" 2>/dev/null \
  | while IFS= read -r line; do
    echo "GENERIC_ANY|$line"
  done >> "$MATCHES_FILE" || true

# Deduplicate (a line can match multiple patterns; keep all categories)
TOTAL_MATCHES=$(wc -l < "$MATCHES_FILE")

if [[ "$TOTAL_MATCHES" -eq 0 ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    echo '{"total": 0, "categories": {}, "files": {}, "matches": []}'
  else
    echo -e "${GREEN}No explicit 'any' usage found! 🎉${RESET}"
  fi
  exit 0
fi

# --- Categorize and count ---
EXPLICIT_COUNT=$(grep -c '^EXPLICIT_ANY|' "$MATCHES_FILE" || true)
ASSERTION_COUNT=$(grep -c '^ASSERTION_ANY|' "$MATCHES_FILE" || true)
GENERIC_COUNT=$(grep -c '^GENERIC_ANY|' "$MATCHES_FILE" || true)

# Deduplicate by file:line to get unique locations
UNIQUE_LOCATIONS=$(sed 's/^[^|]*|//' "$MATCHES_FILE" | cut -d: -f1-2 | sort -u | wc -l)

# --- Identify function parameter any (subset of explicit any) ---
PARAM_ANY_FILE=$(mktemp)
trap 'rm -f "$MATCHES_FILE" "$PARAM_ANY_FILE"' EXIT

grep '^EXPLICIT_ANY|' "$MATCHES_FILE" \
  | sed 's/^EXPLICIT_ANY|//' \
  | grep -E '(function\s|=>|\().*:\s*any' \
  > "$PARAM_ANY_FILE" || true
PARAM_ANY_COUNT=$(wc -l < "$PARAM_ANY_FILE")

if [[ "$JSON_OUTPUT" == true ]]; then
  # --- JSON output ---
  echo "{"
  echo "  \"total_matches\": $TOTAL_MATCHES,"
  echo "  \"unique_locations\": $UNIQUE_LOCATIONS,"
  echo "  \"categories\": {"
  echo "    \"explicit_any\": $EXPLICIT_COUNT,"
  echo "    \"assertion_any\": $ASSERTION_COUNT,"
  echo "    \"generic_any\": $GENERIC_COUNT,"
  echo "    \"function_parameter_any\": $PARAM_ANY_COUNT"
  echo "  },"
  echo "  \"files\": {"
  FIRST=true
  sed 's/^[^|]*|//' "$MATCHES_FILE" \
    | cut -d: -f1 | sort | uniq -c | sort -rn \
    | while read -r count file; do
      if [[ "$FIRST" == true ]]; then
        FIRST=false
      else
        echo ","
      fi
      printf "    \"%s\": %d" "$file" "$count"
    done
  echo ""
  echo "  }"
  echo "}"
  exit 0
fi

# --- Pretty output ---
echo -e "${BOLD}=== TypeScript \`any\` Type Usage Report ===${RESET}"
echo ""
echo -e "${BOLD}Summary:${RESET}"
echo -e "  Total matches:      ${RED}$TOTAL_MATCHES${RESET}"
echo -e "  Unique locations:   $UNIQUE_LOCATIONS"
echo ""

echo -e "${BOLD}By category:${RESET}"
echo -e "  ${YELLOW}Explicit any${RESET}  (: any)         $EXPLICIT_COUNT"
echo -e "  ${YELLOW}Type assertion${RESET} (as any)       $ASSERTION_COUNT"
echo -e "  ${YELLOW}Generic any${RESET}    (<any>)        $GENERIC_COUNT"
echo -e "  ${YELLOW}Function param${RESET} (fn(x: any))   $PARAM_ANY_COUNT"
echo ""

# --- Per file counts ---
echo -e "${BOLD}Counts per file (top 20):${RESET}"
sed 's/^[^|]*|//' "$MATCHES_FILE" \
  | cut -d: -f1 | sort | uniq -c | sort -rn \
  | head -20 \
  | while read -r count file; do
    printf "  %5d  %s\n" "$count" "$file"
  done
echo ""

# --- Show actual matches grouped by category ---
echo -e "${BOLD}=== Explicit \`any\` annotations (: any) ===${RESET}"
grep '^EXPLICIT_ANY|' "$MATCHES_FILE" \
  | sed 's/^EXPLICIT_ANY|//' \
  | head -30 \
  | while IFS= read -r line; do
    file_line=$(echo "$line" | cut -d: -f1-2)
    content=$(echo "$line" | cut -d: -f3-)
    echo -e "  ${CYAN}${file_line}${RESET}:${content}"
  done
if [[ "$EXPLICIT_COUNT" -gt 30 ]]; then
  echo -e "  ${DIM}... and $((EXPLICIT_COUNT - 30)) more${RESET}"
fi
echo ""

echo -e "${BOLD}=== Type assertions (as any) ===${RESET}"
grep '^ASSERTION_ANY|' "$MATCHES_FILE" \
  | sed 's/^ASSERTION_ANY|//' \
  | head -30 \
  | while IFS= read -r line; do
    file_line=$(echo "$line" | cut -d: -f1-2)
    content=$(echo "$line" | cut -d: -f3-)
    echo -e "  ${CYAN}${file_line}${RESET}:${content}"
  done
if [[ "$ASSERTION_COUNT" -gt 30 ]]; then
  echo -e "  ${DIM}... and $((ASSERTION_COUNT - 30)) more${RESET}"
fi
echo ""

if [[ "$GENERIC_COUNT" -gt 0 ]]; then
  echo -e "${BOLD}=== Generic any (<any>) ===${RESET}"
  grep '^GENERIC_ANY|' "$MATCHES_FILE" \
    | sed 's/^GENERIC_ANY|//' \
    | head -20 \
    | while IFS= read -r line; do
      file_line=$(echo "$line" | cut -d: -f1-2)
      content=$(echo "$line" | cut -d: -f3-)
      echo -e "  ${CYAN}${file_line}${RESET}:${content}"
    done
  if [[ "$GENERIC_COUNT" -gt 20 ]]; then
    echo -e "  ${DIM}... and $((GENERIC_COUNT - 20)) more${RESET}"
  fi
  echo ""
fi

# --- Suggest typed alternatives ---
echo -e "${BOLD}=== Suggested Alternatives ===${RESET}"
echo ""
echo -e "  ${YELLOW}Pattern${RESET}                         ${GREEN}Alternative${RESET}"
echo -e "  ──────────────────────────────  ────────────────────────────────────"
echo -e "  : any                          Use the actual type, or \`unknown\`"
echo -e "  as any                         Use \`as SpecificType\` or type guard"
echo -e "  <any>                          Use \`<SpecificType>\` generic parameter"
echo -e "  (data: any) => ...             Type the parameter: \`(data: MyType)\`"
echo -e "  catch (err: any)               Use \`unknown\` + instanceof narrowing"
echo -e "  JSON.parse(...) as any         Use \`as unknown as MyType\` or Zod"
echo -e "  Record<string, any>            Use \`Record<string, unknown>\`"
echo -e "  Array<any>                     Use \`Array<SpecificType>\` or \`unknown[]\`"
echo -e "  Promise<any>                   Use \`Promise<SpecificType>\`"
echo -e "  event: any                     Use DOM types: \`MouseEvent\`, \`KeyboardEvent\`"
echo ""
echo -e "${DIM}Tip: Replace \`any\` with \`unknown\` for type-safe dynamic values.${RESET}"
echo -e "${DIM}     \`unknown\` forces you to narrow the type before use.${RESET}"
