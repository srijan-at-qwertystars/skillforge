#!/usr/bin/env bash
# class-audit.sh — Audit HTML/JSX/TSX files for Tailwind CSS anti-patterns
#
# Usage:
#   ./class-audit.sh [directory]   # Audit files in directory (default: current dir)
#   ./class-audit.sh src/          # Audit only src/ directory
#
# Checks:
#   1. Overly long class strings (>15 utilities)
#   2. Duplicate utilities on the same element
#   3. Conflicting utilities (e.g., w-full + w-1/2)
#   4. Unused @apply directives in CSS
#   5. Dynamic class name anti-patterns
#
# Requires: grep, awk, sort (standard Unix tools)

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${CYAN}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
header(){ echo -e "\n${BOLD}═══ $1 ═══${NC}"; }

TARGET_DIR="${1:-.}"
THRESHOLD=15
TOTAL_ISSUES=0
TOTAL_WARNINGS=0

if [ ! -d "$TARGET_DIR" ]; then
  error "Directory not found: $TARGET_DIR"
  exit 1
fi

info "Auditing Tailwind classes in: $(cd "$TARGET_DIR" && pwd)"
echo ""

# --- Helper: find template files ---
find_template_files() {
  find "$TARGET_DIR" \
    -type f \( -name "*.html" -o -name "*.jsx" -o -name "*.tsx" -o -name "*.vue" -o -name "*.svelte" -o -name "*.astro" \) \
    ! -path "*/node_modules/*" \
    ! -path "*/.next/*" \
    ! -path "*/dist/*" \
    ! -path "*/build/*" \
    2>/dev/null
}

FILE_COUNT=$(find_template_files | wc -l)
info "Found $FILE_COUNT template files to audit"

# ─── Check 1: Overly long class strings ───
header "Long Class Strings (>${THRESHOLD} utilities)"

LONG_COUNT=0
find_template_files | while IFS= read -r file; do
  # Extract class/className attribute values
  grep -noP '(?:class|className)=["\x27]([^"\x27]+)["\x27]' "$file" 2>/dev/null | while IFS= read -r match; do
    LINE_NUM=$(echo "$match" | cut -d: -f1)
    CLASSES=$(echo "$match" | grep -oP '(?<=["\x27])[^"\x27]+(?=["\x27])' | head -1)
    if [ -n "$CLASSES" ]; then
      COUNT=$(echo "$CLASSES" | tr ' ' '\n' | grep -c '[a-zA-Z]' 2>/dev/null || echo 0)
      if [ "$COUNT" -gt "$THRESHOLD" ]; then
        warn "${file}:${LINE_NUM} — ${COUNT} utilities"
        echo -e "  ${DIM}${CLASSES:0:120}...${NC}"
        echo "  → Consider extracting to a component or @utility"
      fi
    fi
  done
done

# ─── Check 2: Duplicate utilities ───
header "Duplicate Utilities"

find_template_files | while IFS= read -r file; do
  grep -noP '(?:class|className)=["\x27]([^"\x27]+)["\x27]' "$file" 2>/dev/null | while IFS= read -r match; do
    LINE_NUM=$(echo "$match" | cut -d: -f1)
    CLASSES=$(echo "$match" | grep -oP '(?<=["\x27])[^"\x27]+(?=["\x27])' | head -1)
    if [ -n "$CLASSES" ]; then
      DUPES=$(echo "$CLASSES" | tr ' ' '\n' | sort | uniq -d | grep -v '^$' || true)
      if [ -n "$DUPES" ]; then
        warn "${file}:${LINE_NUM} — Duplicate classes:"
        echo "$DUPES" | while read -r d; do
          echo -e "  ${RED}duplicate:${NC} $d"
        done
      fi
    fi
  done
done

# ─── Check 3: Conflicting utilities ───
header "Conflicting Utilities"

# Define conflict groups: patterns where having >1 from the group is a conflict
CONFLICT_GROUPS=(
  "width:w-full:w-1/2:w-1/3:w-1/4:w-2/3:w-3/4:w-screen:w-fit:w-min:w-max:w-auto"
  "height:h-full:h-screen:h-dvh:h-fit:h-min:h-max:h-auto"
  "display:block:inline-block:inline:flex:inline-flex:grid:inline-grid:hidden:table:contents"
  "position:static:fixed:absolute:relative:sticky"
  "text-align:text-left:text-center:text-right:text-justify:text-start:text-end"
  "flex-direction:flex-row:flex-col:flex-row-reverse:flex-col-reverse"
  "flex-wrap:flex-wrap:flex-nowrap:flex-wrap-reverse"
  "overflow:overflow-auto:overflow-hidden:overflow-visible:overflow-scroll:overflow-clip"
  "font-weight:font-thin:font-extralight:font-light:font-normal:font-medium:font-semibold:font-bold:font-extrabold:font-black"
  "justify:justify-start:justify-end:justify-center:justify-between:justify-around:justify-evenly"
  "items:items-start:items-end:items-center:items-baseline:items-stretch"
)

find_template_files | while IFS= read -r file; do
  grep -noP '(?:class|className)=["\x27]([^"\x27]+)["\x27]' "$file" 2>/dev/null | while IFS= read -r match; do
    LINE_NUM=$(echo "$match" | cut -d: -f1)
    CLASSES=$(echo "$match" | grep -oP '(?<=["\x27])[^"\x27]+(?=["\x27])' | head -1)
    if [ -z "$CLASSES" ]; then continue; fi

    for group in "${CONFLICT_GROUPS[@]}"; do
      GROUP_NAME="${group%%:*}"
      GROUP_ITEMS="${group#*:}"

      FOUND=()
      IFS=: read -ra ITEMS <<< "$GROUP_ITEMS"
      for item in "${ITEMS[@]}"; do
        # Match the utility without variant prefix (allow sm:, md:, hover:, etc.)
        if echo " $CLASSES " | grep -qP "(?<= )(?:[a-z-]+:)*${item}(?= )"; then
          # Only flag if no variant prefix (bare conflict)
          if echo " $CLASSES " | grep -qP "(?<= )${item}(?= )"; then
            FOUND+=("$item")
          fi
        fi
      done

      if [ "${#FOUND[@]}" -gt 1 ]; then
        warn "${file}:${LINE_NUM} — Conflicting ${GROUP_NAME}: ${FOUND[*]}"
      fi
    done
  done
done

# ─── Check 4: Unused @apply in CSS ───
header "@apply Usage in CSS"

CSS_FILES=$(find "$TARGET_DIR" -type f -name "*.css" ! -path "*/node_modules/*" ! -path "*/dist/*" 2>/dev/null)
APPLY_TOTAL=0

if [ -n "$CSS_FILES" ]; then
  while IFS= read -r file; do
    APPLY_COUNT=$(grep -c "@apply" "$file" 2>/dev/null || echo 0)
    if [ "$APPLY_COUNT" -gt 0 ]; then
      APPLY_TOTAL=$((APPLY_TOTAL + APPLY_COUNT))
      if [ "$APPLY_COUNT" -gt 10 ]; then
        warn "$file — $APPLY_COUNT @apply directives (consider component abstractions)"
      else
        info "$file — $APPLY_COUNT @apply directives"
      fi
    fi
  done <<< "$CSS_FILES"
fi

if [ "$APPLY_TOTAL" -eq 0 ]; then
  ok "No @apply usage found"
elif [ "$APPLY_TOTAL" -gt 30 ]; then
  warn "Heavy @apply usage ($APPLY_TOTAL total) — defeats utility-first approach"
fi

# ─── Check 5: Dynamic class anti-patterns ───
header "Dynamic Class Anti-patterns"

# Check for string interpolation in class names
DYNAMIC_ISSUES=$(grep -rn 'class\(Name\)\?=.*`.*\${.*}' --include="*.jsx" --include="*.tsx" --include="*.js" --include="*.ts" "$TARGET_DIR" 2>/dev/null \
  | grep -v "node_modules" | grep -v "dist/" | head -20 || true)

if [ -n "$DYNAMIC_ISSUES" ]; then
  warn "Potential dynamic class construction (Tailwind can't detect these):"
  echo "$DYNAMIC_ISSUES" | while read -r line; do
    echo -e "  ${DIM}$line${NC}"
  done
  echo ""
  echo "  → Use complete class name lookup objects instead of interpolation"
  echo "  → Or add classes to @source inline(\"...\") in CSS"
else
  ok "No dynamic class interpolation detected"
fi

# Check for conditional concat patterns
CONCAT_ISSUES=$(grep -rn "className.*+.*['\"]" --include="*.jsx" --include="*.tsx" "$TARGET_DIR" 2>/dev/null \
  | grep -v "node_modules" | grep -v "clsx\|classnames\|cn(" | head -10 || true)

if [ -n "$CONCAT_ISSUES" ]; then
  info "String concatenation in className (review for dynamic patterns):"
  echo "$CONCAT_ISSUES" | head -5 | while read -r line; do
    echo -e "  ${DIM}$line${NC}"
  done
fi

# ─── Summary ───
header "Audit Summary"

echo ""
info "Files scanned: $FILE_COUNT"
info "@apply directives: $APPLY_TOTAL"

echo ""
info "Tips for cleaner Tailwind:"
echo "  • Extract repeated long class strings into components"
echo "  • Use @utility for shared multi-utility patterns"
echo "  • Never construct class names with string interpolation"
echo "  • Use clsx/cn for conditional classes with full class names"
echo "  • Check class order with prettier-plugin-tailwindcss"
