#!/usr/bin/env bash
# signal-audit.sh — Audit signal usage patterns, find effect() without cleanup, detect anti-patterns
#
# Usage:
#   ./signal-audit.sh [directory]
#   ./signal-audit.sh src/app
#   ./signal-audit.sh              # defaults to current directory
#
# Analyzes TypeScript files for signal anti-patterns and provides actionable feedback.

set -euo pipefail

TARGET="${1:-.}"
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

errors=0
warnings=0
info_count=0

echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Angular Signal Usage Auditor                   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Scanning: $TARGET"
echo ""

ts_files=$(find "$TARGET" -type f -name '*.ts' \
  ! -path '*/node_modules/*' ! -path '*/dist/*' ! -path '*/.angular/*' \
  ! -name '*.spec.ts' ! -name '*.d.ts' 2>/dev/null || true)

if [ -z "$ts_files" ]; then
  echo -e "${RED}No TypeScript files found in $TARGET${NC}"
  exit 1
fi

error_msg() {
  echo -e "  ${RED}✗ ERROR:${NC} $1"
  echo -e "    ${CYAN}$2${NC}"
  [ -n "${3:-}" ] && echo -e "    ${YELLOW}→ $3${NC}"
  errors=$((errors + 1))
}

warn_msg() {
  echo -e "  ${YELLOW}⚠ WARN:${NC} $1"
  echo -e "    ${CYAN}$2${NC}"
  [ -n "${3:-}" ] && echo -e "    ${YELLOW}→ $3${NC}"
  warnings=$((warnings + 1))
}

info_msg() {
  echo -e "  ${GREEN}ℹ INFO:${NC} $1"
  info_count=$((info_count + 1))
}

# ── Signal usage stats ──
echo -e "${BLUE}[1/6] Collecting signal usage statistics...${NC}"
signal_count=$(grep -rch '\bsignal(' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')
computed_count=$(grep -rch '\bcomputed(' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')
effect_count=$(grep -rch '\beffect(' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')
input_sig=$(grep -rch '\binput(' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')
input_req=$(grep -rch '\binput\.required' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')
output_sig=$(grep -rch '\boutput(' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')
linked_count=$(grep -rch '\blinkedSignal(' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')
resource_count=$(grep -rch '\bresource(' $TARGET --include='*.ts' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.angular 2>/dev/null | awk '{s+=$1}END{print s+0}')

echo -e "  signal():        ${GREEN}$signal_count${NC}"
echo -e "  computed():      ${GREEN}$computed_count${NC}"
echo -e "  effect():        ${GREEN}$effect_count${NC}"
echo -e "  input():         ${GREEN}$input_sig${NC}"
echo -e "  input.required():${GREEN}$input_req${NC}"
echo -e "  output():        ${GREEN}$output_sig${NC}"
echo -e "  linkedSignal():  ${GREEN}$linked_count${NC}"
echo -e "  resource():      ${GREEN}$resource_count${NC}"
echo ""

# ── Check for effects without cleanup ──
echo -e "${BLUE}[2/6] Checking for effect() without onCleanup...${NC}"
while IFS= read -r file; do
  # Find effect() calls and check if they have onCleanup
  line_num=0
  in_effect=false
  brace_depth=0
  has_cleanup=false
  has_timer=false
  has_subscribe=false
  effect_line=0

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    if echo "$line" | grep -qE '\beffect\s*\('; then
      in_effect=true
      brace_depth=0
      has_cleanup=false
      has_timer=false
      has_subscribe=false
      effect_line=$line_num
    fi

    if [ "$in_effect" = true ]; then
      # Count braces
      opens=$(echo "$line" | tr -cd '{' | wc -c)
      closes=$(echo "$line" | tr -cd '}' | wc -c)
      brace_depth=$((brace_depth + opens - closes))

      echo "$line" | grep -qE 'onCleanup' && has_cleanup=true
      echo "$line" | grep -qE 'setInterval|setTimeout' && has_timer=true
      echo "$line" | grep -qE '\.subscribe\(' && has_subscribe=true

      if [ "$brace_depth" -le 0 ] && [ "$effect_line" -ne "$line_num" -o "$opens" -gt 0 ]; then
        if [ "$has_timer" = true ] || [ "$has_subscribe" = true ]; then
          if [ "$has_cleanup" = false ]; then
            error_msg "$file:$effect_line — effect() with timer/subscription but no onCleanup" \
              "Add onCleanup callback to prevent memory leaks" \
              "effect((onCleanup) => { ... onCleanup(() => clearInterval(id)); });"
          fi
        fi
        in_effect=false
      fi
    fi
  done < "$file"
done <<< "$ts_files"
echo ""

# ── Check for signal writes inside computed() ──
echo -e "${BLUE}[3/6] Checking for signal writes inside computed()...${NC}"
while IFS= read -r file; do
  line_num=0
  in_computed=false
  brace_depth=0
  computed_line=0

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    if echo "$line" | grep -qE '\bcomputed\s*\('; then
      in_computed=true
      brace_depth=0
      computed_line=$line_num
    fi

    if [ "$in_computed" = true ]; then
      opens=$(echo "$line" | tr -cd '{' | wc -c)
      closes=$(echo "$line" | tr -cd '}' | wc -c)
      brace_depth=$((brace_depth + opens - closes))

      if echo "$line" | grep -qE '\.set\(|\.update\('; then
        error_msg "$file:$line_num — Signal write (.set/.update) inside computed()" \
          "computed() must be pure — no side effects or signal writes" \
          "Use linkedSignal() for writable derived state"
      fi

      if [ "$brace_depth" -le 0 ] && [ "$computed_line" -ne "$line_num" -o "$opens" -gt 0 ]; then
        in_computed=false
      fi
    fi
  done < "$file"
done <<< "$ts_files"
echo ""

# ── Check for effect() used to sync signals ──
echo -e "${BLUE}[4/6] Checking for effect() used to sync signals (anti-pattern)...${NC}"
while IFS= read -r file; do
  line_num=0
  in_effect=false
  brace_depth=0
  effect_line=0
  reads_signal=false
  writes_signal=false

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    if echo "$line" | grep -qE '\beffect\s*\('; then
      in_effect=true
      brace_depth=0
      effect_line=$line_num
      reads_signal=false
      writes_signal=false
    fi

    if [ "$in_effect" = true ]; then
      opens=$(echo "$line" | tr -cd '{' | wc -c)
      closes=$(echo "$line" | tr -cd '}' | wc -c)
      brace_depth=$((brace_depth + opens - closes))

      # Heuristic: detect pattern like "this.x.set(this.y())" in effect
      if echo "$line" | grep -qE 'this\.[a-zA-Z]+\(\)'; then
        reads_signal=true
      fi
      if echo "$line" | grep -qE 'this\.[a-zA-Z]+\.set\('; then
        writes_signal=true
      fi

      if [ "$brace_depth" -le 0 ] && [ "$effect_line" -ne "$line_num" -o "$opens" -gt 0 ]; then
        if [ "$reads_signal" = true ] && [ "$writes_signal" = true ]; then
          warn_msg "$file:$effect_line — effect() reads and writes signals (possible sync anti-pattern)" \
            "Prefer computed() or linkedSignal() for derived state" \
            "effect() should be for external side effects (DOM, logging, localStorage)"
        fi
        in_effect=false
      fi
    fi
  done < "$file"
done <<< "$ts_files"
echo ""

# ── Check for in-place mutations ──
echo -e "${BLUE}[5/6] Checking for potential in-place signal mutations...${NC}"
while IFS= read -r file; do
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    # Pattern: someSignal().push( or someSignal().splice( — array mutation
    if echo "$line" | grep -qE '\(\)\.push\(|\(\)\.splice\(|\(\)\.pop\(|\(\)\.shift\(|\(\)\.unshift\('; then
      warn_msg "$file:$line_num — Possible in-place array mutation on signal value" \
        "$(echo "$line" | sed 's/^[[:space:]]*//')" \
        "Use .update(arr => [...arr, item]) instead of .push()"
    fi
    # Pattern: someSignal().prop = — object mutation
    if echo "$line" | grep -qE '\(\)\.[a-zA-Z_]+\s*=\s*[^=]'; then
      # Filter out == and === comparisons
      if ! echo "$line" | grep -qE '\(\)\.[a-zA-Z_]+\s*===?\s*'; then
        warn_msg "$file:$line_num — Possible in-place object mutation on signal value" \
          "$(echo "$line" | sed 's/^[[:space:]]*//')" \
          "Use .update(obj => ({ ...obj, prop: val })) for new reference"
      fi
    fi
  done < "$file"
done <<< "$ts_files"
echo ""

# ── Check for nested effects ──
echo -e "${BLUE}[6/6] Checking for nested effect() calls...${NC}"
while IFS= read -r file; do
  line_num=0
  effect_depth=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if echo "$line" | grep -qE '\beffect\s*\('; then
      effect_depth=$((effect_depth + 1))
      if [ "$effect_depth" -gt 1 ]; then
        error_msg "$file:$line_num — Nested effect() detected" \
          "Do not nest effect() inside effect() — flatten or restructure" \
          "Create separate effects at the class field level"
      fi
    fi
    # Rough brace tracking for effect scope
    closes=$(echo "$line" | grep -oE '\}\s*\)\s*;' | wc -l)
    if [ "$closes" -gt 0 ] && [ "$effect_depth" -gt 0 ]; then
      effect_depth=$((effect_depth - 1))
    fi
  done < "$file"
done <<< "$ts_files"

# ── Summary ──
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Audit Summary${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "  Errors:   ${RED}$errors${NC}"
echo -e "  Warnings: ${YELLOW}$warnings${NC}"
echo ""
if [ "$errors" -eq 0 ] && [ "$warnings" -eq 0 ]; then
  echo -e "  ${GREEN}🎉 No signal anti-patterns detected!${NC}"
elif [ "$errors" -eq 0 ]; then
  echo -e "  ${YELLOW}Review warnings above for potential improvements${NC}"
else
  echo -e "  ${RED}Fix errors above — they indicate bugs or memory leaks${NC}"
fi
