#!/usr/bin/env bash
# migrate-to-signals.sh — Find @Input/@Output/@ViewChild decorators and suggest signal equivalents
#
# Usage:
#   ./migrate-to-signals.sh [directory]
#   ./migrate-to-signals.sh src/app
#   ./migrate-to-signals.sh              # defaults to current directory
#
# Scans TypeScript files for legacy decorator patterns and prints suggested
# signal-based replacements. Does NOT modify files — output is advisory only.

set -euo pipefail

TARGET="${1:-.}"
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

input_count=0
output_count=0
viewchild_count=0
viewchildren_count=0
contentchild_count=0
contentchildren_count=0

echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Angular Signal Migration Scanner               ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Scanning: $TARGET"
echo ""

# Find all TypeScript files (skip node_modules, dist, .angular)
files=$(find "$TARGET" -type f -name '*.ts' \
  ! -path '*/node_modules/*' \
  ! -path '*/dist/*' \
  ! -path '*/.angular/*' \
  ! -path '*.spec.ts' \
  ! -path '*.d.ts' 2>/dev/null || true)

if [ -z "$files" ]; then
  echo -e "${RED}No TypeScript files found in $TARGET${NC}"
  exit 1
fi

process_file() {
  local file="$1"
  local found=false
  local line_num=0

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # @Input() patterns
    if echo "$line" | grep -qE '@Input\s*\('; then
      if [ "$found" = false ]; then
        echo -e "\n${BLUE}━━━ $file ━━━${NC}"
        found=true
      fi
      if echo "$line" | grep -qE 'required\s*:\s*true'; then
        echo -e "  ${YELLOW}L${line_num}:${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
        # Extract property name
        prop=$(echo "$line" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*[!:]' | head -1 | sed 's/[!: ]//g')
        type=$(echo "$line" | grep -oE ':\s*[A-Za-z<>\[\]|& ]+' | tail -1 | sed 's/^:\s*//')
        echo -e "    ${GREEN}→ ${prop} = input.required<${type:-T}>();${NC}"
        input_count=$((input_count + 1))
      else
        echo -e "  ${YELLOW}L${line_num}:${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
        prop=$(echo "$line" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*[=!:]' | head -1 | sed 's/[=!: ]//g')
        default=$(echo "$line" | grep -oE '=\s*[^;]+' | head -1 | sed 's/^=\s*//')
        if [ -n "$default" ]; then
          echo -e "    ${GREEN}→ ${prop} = input(${default});${NC}"
        else
          type=$(echo "$line" | grep -oE ':\s*[A-Za-z<>\[\]|& ]+' | tail -1 | sed 's/^:\s*//')
          echo -e "    ${GREEN}→ ${prop} = input<${type:-T}>();${NC}"
        fi
        input_count=$((input_count + 1))
      fi
    fi

    # @Output() patterns
    if echo "$line" | grep -qE '@Output\s*\('; then
      if [ "$found" = false ]; then
        echo -e "\n${BLUE}━━━ $file ━━━${NC}"
        found=true
      fi
      echo -e "  ${YELLOW}L${line_num}:${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
      prop=$(echo "$line" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*=' | head -1 | sed 's/[= ]//g')
      type=$(echo "$line" | grep -oE 'EventEmitter<[^>]*>' | head -1 | sed 's/EventEmitter<//;s/>//')
      echo -e "    ${GREEN}→ ${prop} = output<${type:-void}>();${NC}"
      output_count=$((output_count + 1))
    fi

    # @ViewChild() patterns
    if echo "$line" | grep -qE '@ViewChild\s*\('; then
      if [ "$found" = false ]; then
        echo -e "\n${BLUE}━━━ $file ━━━${NC}"
        found=true
      fi
      echo -e "  ${YELLOW}L${line_num}:${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
      selector=$(echo "$line" | grep -oE "@ViewChild\([^)]*\)" | sed "s/@ViewChild(//;s/)//;s/'//g;s/\"//g" | cut -d',' -f1 | xargs)
      prop=$(echo "$line" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*[!:]' | head -1 | sed 's/[!: ]//g')
      if echo "$line" | grep -qE 'static\s*:\s*true'; then
        echo -e "    ${RED}⚠ { static: true } has no signal equivalent — keep decorator${NC}"
      else
        echo -e "    ${GREEN}→ ${prop} = viewChild(${selector});${NC}"
      fi
      viewchild_count=$((viewchild_count + 1))
    fi

    # @ViewChildren() patterns
    if echo "$line" | grep -qE '@ViewChildren\s*\('; then
      if [ "$found" = false ]; then
        echo -e "\n${BLUE}━━━ $file ━━━${NC}"
        found=true
      fi
      echo -e "  ${YELLOW}L${line_num}:${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
      selector=$(echo "$line" | grep -oE "@ViewChildren\([^)]*\)" | sed "s/@ViewChildren(//;s/)//;s/'//g;s/\"//g" | xargs)
      prop=$(echo "$line" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*[!:]' | head -1 | sed 's/[!: ]//g')
      echo -e "    ${GREEN}→ ${prop} = viewChildren(${selector});${NC}"
      viewchildren_count=$((viewchildren_count + 1))
    fi

    # @ContentChild() patterns
    if echo "$line" | grep -qE '@ContentChild\s*\('; then
      if [ "$found" = false ]; then
        echo -e "\n${BLUE}━━━ $file ━━━${NC}"
        found=true
      fi
      echo -e "  ${YELLOW}L${line_num}:${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
      selector=$(echo "$line" | grep -oE "@ContentChild\([^)]*\)" | sed "s/@ContentChild(//;s/)//;s/'//g;s/\"//g" | cut -d',' -f1 | xargs)
      prop=$(echo "$line" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*[!:]' | head -1 | sed 's/[!: ]//g')
      echo -e "    ${GREEN}→ ${prop} = contentChild(${selector});${NC}"
      contentchild_count=$((contentchild_count + 1))
    fi

    # @ContentChildren() patterns
    if echo "$line" | grep -qE '@ContentChildren\s*\('; then
      if [ "$found" = false ]; then
        echo -e "\n${BLUE}━━━ $file ━━━${NC}"
        found=true
      fi
      echo -e "  ${YELLOW}L${line_num}:${NC} $(echo "$line" | sed 's/^[[:space:]]*//')"
      selector=$(echo "$line" | grep -oE "@ContentChildren\([^)]*\)" | sed "s/@ContentChildren(//;s/)//;s/'//g;s/\"//g" | xargs)
      prop=$(echo "$line" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\s*[!:]' | head -1 | sed 's/[!: ]//g')
      echo -e "    ${GREEN}→ ${prop} = contentChildren(${selector});${NC}"
      contentchildren_count=$((contentchildren_count + 1))
    fi
  done < "$file"
}

while IFS= read -r f; do
  process_file "$f"
done <<< "$files"

total=$((input_count + output_count + viewchild_count + viewchildren_count + contentchild_count + contentchildren_count))

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "  @Input()          → input()          : ${YELLOW}${input_count}${NC}"
echo -e "  @Output()         → output()         : ${YELLOW}${output_count}${NC}"
echo -e "  @ViewChild()      → viewChild()      : ${YELLOW}${viewchild_count}${NC}"
echo -e "  @ViewChildren()   → viewChildren()   : ${YELLOW}${viewchildren_count}${NC}"
echo -e "  @ContentChild()   → contentChild()   : ${YELLOW}${contentchild_count}${NC}"
echo -e "  @ContentChildren()→ contentChildren() : ${YELLOW}${contentchildren_count}${NC}"
echo -e "  ${GREEN}Total decorators to migrate: ${total}${NC}"
echo ""
if [ "$total" -gt 0 ]; then
  echo -e "${YELLOW}Tip: Run Angular migration schematics for automated conversion:${NC}"
  echo "  ng generate @angular/core:signal-input-migration"
  echo "  ng generate @angular/core:signal-queries-migration"
  echo "  ng generate @angular/core:output-migration"
fi
