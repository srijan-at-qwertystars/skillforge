#!/usr/bin/env bash
# analyze-sass.sh — Analyze a Sass/SCSS project for quality issues
#
# Usage:
#   ./analyze-sass.sh [directory]       # Default: current directory
#   ./analyze-sass.sh src/styles
#   ./analyze-sass.sh --json            # Output as JSON
#
# Reports:
#   - Unused variables and mixins
#   - Deep nesting (>3 levels)
#   - File complexity metrics
#   - @import usage (should be @use)
#   - Large files that should be split
#   - Selector specificity concerns
#
# Prerequisites: grep, awk, find (standard Unix tools)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

TARGET="${1:-.}"
JSON_MODE=false
[[ "${1:-}" == "--json" ]] && { JSON_MODE=true; TARGET="${2:-.}"; }
[[ "${2:-}" == "--json" ]] && JSON_MODE=true

[[ -d "$TARGET" ]] || { echo "Directory not found: $TARGET" >&2; exit 1; }

header()  { $JSON_MODE || echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }
metric()  { $JSON_MODE || echo -e "  ${BLUE}$1:${NC} $2"; }
warning() { $JSON_MODE || echo -e "  ${YELLOW}⚠${NC}  $*"; }
good()    { $JSON_MODE || echo -e "  ${GREEN}✓${NC}  $*"; }

# --- Collect all SCSS/Sass files ---
SCSS_FILES=()
while IFS= read -r -d '' f; do
  SCSS_FILES+=("$f")
done < <(find "$TARGET" -type f \( -name '*.scss' -o -name '*.sass' \) -not -path '*/node_modules/*' -not -path '*/vendor/*' -print0 2>/dev/null)

TOTAL_FILES=${#SCSS_FILES[@]}
[[ $TOTAL_FILES -eq 0 ]] && { echo "No SCSS/Sass files found in $TARGET"; exit 0; }

TOTAL_LINES=0
for f in "${SCSS_FILES[@]}"; do
  lines=$(wc -l < "$f")
  TOTAL_LINES=$((TOTAL_LINES + lines))
done

# ============================================
# 1. PROJECT OVERVIEW
# ============================================
header "Project Overview"
metric "Directory" "$TARGET"
metric "SCSS files" "$TOTAL_FILES"
metric "Total lines" "$TOTAL_LINES"
metric "Avg lines/file" "$((TOTAL_LINES / TOTAL_FILES))"

PARTIAL_COUNT=0
ENTRY_COUNT=0
for f in "${SCSS_FILES[@]}"; do
  base=$(basename "$f")
  [[ "$base" == _* ]] && ((PARTIAL_COUNT++)) || ((ENTRY_COUNT++))
done
metric "Partials (_*.scss)" "$PARTIAL_COUNT"
metric "Entry files" "$ENTRY_COUNT"

# ============================================
# 2. @import USAGE (deprecated)
# ============================================
header "Deprecated @import Usage"
IMPORT_FILES=()
for f in "${SCSS_FILES[@]}"; do
  if grep -qE '^\s*@import\b' "$f" 2>/dev/null; then
    IMPORT_FILES+=("$f")
  fi
done

if [[ ${#IMPORT_FILES[@]} -gt 0 ]]; then
  warning "${#IMPORT_FILES[@]} file(s) still using @import (deprecated in Dart Sass, removed in 3.0):"
  for f in "${IMPORT_FILES[@]}"; do
    count=$(grep -cE '^\s*@import\b' "$f" 2>/dev/null || true)
    echo -e "    ${RED}$f${NC} ($count imports)"
  done
else
  good "No @import usage found — all files use @use/@forward"
fi

# ============================================
# 3. DEEP NESTING
# ============================================
header "Nesting Depth Analysis"
DEEP_NESTING_FILES=()
for f in "${SCSS_FILES[@]}"; do
  # Approximate nesting by counting max consecutive indentation
  max_depth=0
  while IFS= read -r line; do
    # Count leading spaces/tabs, estimate depth
    stripped="${line#"${line%%[! ]*}"}"
    spaces=$(( ${#line} - ${#stripped} ))
    # Assume 2-space indent; also handle tabs
    tabs=$(echo "$line" | grep -oP '^\t*' | tr -cd '\t' | wc -c 2>/dev/null || echo 0)
    depth=$(( spaces / 2 + tabs ))
    (( depth > max_depth )) && max_depth=$depth
  done < "$f"

  if (( max_depth > 3 )); then
    DEEP_NESTING_FILES+=("$f:$max_depth")
  fi
done

if [[ ${#DEEP_NESTING_FILES[@]} -gt 0 ]]; then
  warning "${#DEEP_NESTING_FILES[@]} file(s) exceed 3-level nesting limit:"
  for entry in "${DEEP_NESTING_FILES[@]}"; do
    file="${entry%:*}"
    depth="${entry##*:}"
    echo -e "    ${YELLOW}$file${NC} (max depth: ~$depth)"
  done
else
  good "All files within 3-level nesting limit"
fi

# ============================================
# 4. UNUSED VARIABLES
# ============================================
header "Potentially Unused Variables"
# Find variable definitions and check if they're used elsewhere
UNUSED_VARS=()
ALL_CONTENT=""
for f in "${SCSS_FILES[@]}"; do
  ALL_CONTENT+=$(cat "$f")
  ALL_CONTENT+=$'\n'
done

DEFINED_VARS=()
while IFS= read -r line; do
  # Extract variable name from definitions like "$name: value;"
  var=$(echo "$line" | grep -oP '\$[a-zA-Z_][\w-]*(?=\s*:)' | head -1)
  [[ -n "$var" ]] && DEFINED_VARS+=("$var")
done < <(grep -rhP '^\s*\$[a-zA-Z_][\w-]*\s*:' "${SCSS_FILES[@]}" 2>/dev/null || true)

# Deduplicate
UNIQUE_VARS=($(printf '%s\n' "${DEFINED_VARS[@]}" 2>/dev/null | sort -u))

for var in "${UNIQUE_VARS[@]}"; do
  escaped_var=$(echo "$var" | sed 's/[$]/\\$/g')
  # Count usages (excluding the definition line itself)
  usage_count=$(echo "$ALL_CONTENT" | grep -oF "$var" 2>/dev/null | wc -l || echo 0)
  if (( usage_count <= 1 )); then
    UNUSED_VARS+=("$var")
  fi
done

if [[ ${#UNUSED_VARS[@]} -gt 0 ]]; then
  warning "${#UNUSED_VARS[@]} potentially unused variable(s):"
  for var in "${UNUSED_VARS[@]:0:20}"; do
    file=$(grep -rlP "\\${var}\s*:" "${SCSS_FILES[@]}" 2>/dev/null | head -1 || echo "unknown")
    echo -e "    ${YELLOW}$var${NC}  in $file"
  done
  [[ ${#UNUSED_VARS[@]} -gt 20 ]] && echo "    ... and $((${#UNUSED_VARS[@]} - 20)) more"
else
  good "No obviously unused variables detected"
fi

# ============================================
# 5. UNUSED MIXINS
# ============================================
header "Potentially Unused Mixins"
DEFINED_MIXINS=()
while IFS= read -r mixin_name; do
  DEFINED_MIXINS+=("$mixin_name")
done < <(grep -rhPoE '@mixin\s+[\w-]+' "${SCSS_FILES[@]}" 2>/dev/null | sed 's/@mixin\s*//' | sort -u)

UNUSED_MIXINS=()
for mixin in "${DEFINED_MIXINS[@]}"; do
  include_count=$(echo "$ALL_CONTENT" | grep -cE "@include\s+(\w+\.)?${mixin}(\s|\(|;|$)" 2>/dev/null || echo 0)
  if (( include_count == 0 )); then
    UNUSED_MIXINS+=("$mixin")
  fi
done

if [[ ${#UNUSED_MIXINS[@]} -gt 0 ]]; then
  warning "${#UNUSED_MIXINS[@]} potentially unused mixin(s):"
  for mixin in "${UNUSED_MIXINS[@]:0:15}"; do
    echo -e "    ${YELLOW}@mixin $mixin${NC}"
  done
  [[ ${#UNUSED_MIXINS[@]} -gt 15 ]] && echo "    ... and $((${#UNUSED_MIXINS[@]} - 15)) more"
else
  good "No obviously unused mixins detected"
fi

# ============================================
# 6. LARGE FILES
# ============================================
header "File Size Analysis"
LARGE_FILES=()
for f in "${SCSS_FILES[@]}"; do
  lines=$(wc -l < "$f")
  if (( lines > 300 )); then
    LARGE_FILES+=("$f:$lines")
  fi
done

if [[ ${#LARGE_FILES[@]} -gt 0 ]]; then
  warning "${#LARGE_FILES[@]} file(s) over 300 lines (consider splitting):"
  for entry in "${LARGE_FILES[@]}"; do
    file="${entry%:*}"
    lines="${entry##*:}"
    echo -e "    ${YELLOW}$file${NC} ($lines lines)"
  done
else
  good "All files under 300 lines"
fi

# ============================================
# 7. COMPLEXITY METRICS
# ============================================
header "Complexity Metrics"

EXTEND_COUNT=$(echo "$ALL_CONTENT" | grep -cE '@extend\b' 2>/dev/null || echo 0)
MIXIN_DEF_COUNT=${#DEFINED_MIXINS[@]}
INCLUDE_COUNT=$(echo "$ALL_CONTENT" | grep -cE '@include\b' 2>/dev/null || echo 0)
FUNCTION_COUNT=$(echo "$ALL_CONTENT" | grep -cE '@function\b' 2>/dev/null || echo 0)
IMPORTANT_COUNT=$(echo "$ALL_CONTENT" | grep -ciE '!important' 2>/dev/null || echo 0)
MEDIA_COUNT=$(echo "$ALL_CONTENT" | grep -cE '@media\b' 2>/dev/null || echo 0)

metric "@mixin definitions" "$MIXIN_DEF_COUNT"
metric "@include usages" "$INCLUDE_COUNT"
metric "@function definitions" "$FUNCTION_COUNT"
metric "@extend usages" "$EXTEND_COUNT"
metric "@media queries" "$MEDIA_COUNT"
metric "!important usages" "$IMPORTANT_COUNT"

[[ $IMPORTANT_COUNT -gt 5 ]] && warning "High !important count ($IMPORTANT_COUNT) — review for specificity issues"
[[ $EXTEND_COUNT -gt 20 ]] && warning "High @extend count ($EXTEND_COUNT) — may cause selector bloat"

# ============================================
# SUMMARY
# ============================================
header "Summary"
ISSUES=0
[[ ${#IMPORT_FILES[@]} -gt 0 ]] && ((ISSUES += ${#IMPORT_FILES[@]}))
[[ ${#DEEP_NESTING_FILES[@]} -gt 0 ]] && ((ISSUES += ${#DEEP_NESTING_FILES[@]}))
[[ ${#UNUSED_VARS[@]} -gt 0 ]] && ((ISSUES += ${#UNUSED_VARS[@]}))
[[ ${#UNUSED_MIXINS[@]} -gt 0 ]] && ((ISSUES += ${#UNUSED_MIXINS[@]}))
[[ ${#LARGE_FILES[@]} -gt 0 ]] && ((ISSUES += ${#LARGE_FILES[@]}))

if [[ $ISSUES -eq 0 ]]; then
  good "No issues found! Your Sass project looks clean."
else
  echo -e "  Found ${YELLOW}$ISSUES${NC} potential issue(s) to review."
fi
echo ""
