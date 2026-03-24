#!/usr/bin/env bash
# check-reactivity.sh — Detect patterns that break SolidJS reactivity.
#
# Usage:
#   ./check-reactivity.sh [directory]
#
# Scans .tsx/.jsx/.ts/.js files for common reactivity-breaking patterns.
# Does NOT modify files — report only.
#
# Examples:
#   ./check-reactivity.sh src/
#   ./check-reactivity.sh .

set -euo pipefail

TARGET="${1:-.}"
ISSUES=0

if [[ ! -d "$TARGET" ]]; then
  echo "Error: '$TARGET' is not a directory."
  exit 1
fi

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'
[[ ! -t 1 ]] && RED="" && YEL="" && GRN="" && CYN="" && RST=""

warn() {
  local severity="$1" label="$2" detail="$3" matches="$4"
  ISSUES=$((ISSUES + 1))
  local color="$YEL"
  [[ "$severity" == "error" ]] && color="$RED"

  echo -e "${color}[$ISSUES] $label${RST}"
  echo -e "  ${CYN}$detail${RST}"
  echo "$matches" | head -15 | sed 's/^/    /'
  local total
  total=$(echo "$matches" | wc -l)
  (( total > 15 )) && echo "    ... and $((total - 15)) more"
  echo ""
}

search() {
  grep -rn --include='*.tsx' --include='*.jsx' --include='*.ts' --include='*.js' \
    -E "$1" "$TARGET" 2>/dev/null || true
}

echo "============================================"
echo " SolidJS Reactivity Check"
echo " Scanning: $TARGET"
echo "============================================"
echo ""

# 1. Destructured props in function parameters
m=$(search 'function\s+\w+\s*\(\s*\{' || true)
if [[ -n "$m" ]]; then
  warn "error" \
    "Destructured props in function parameters" \
    "Props destructuring breaks reactivity. Use: function Comp(props) { ... }" \
    "$m"
fi

# 2. Destructured props in body: const { ... } = props
m=$(search 'const\s+\{[^}]+\}\s*=\s*props' || true)
if [[ -n "$m" ]]; then
  warn "error" \
    "Destructured props in component body" \
    "Use splitProps() or access props.x directly." \
    "$m"
fi

# 3. Signals referenced without calling — in JSX text content
m=$(search '\{[a-z][a-zA-Z]*\}' | grep -v '()' | grep -v 'props\.' | grep -v 'class=' | grep -v 'style=' | grep -v 'import' | grep -v '//' | head -30 || true)
# This is heuristic — may have false positives

# 4. Direct store/signal mutation
m=$(search '\bstore\.[a-zA-Z]+\s*=' | grep -v 'setState\|setStore\|createStore\|const\|let\|function\|=>' || true)
if [[ -n "$m" ]]; then
  warn "error" \
    "Direct store mutation detected" \
    "Use setStore() or produce() instead of mutating store properties directly." \
    "$m"
fi

# 5. Async createEffect
m=$(search 'createEffect\s*\(\s*async' || true)
if [[ -n "$m" ]]; then
  warn "error" \
    "Async function in createEffect" \
    "Tracking stops at first await. Read all dependencies before await, or use createResource." \
    "$m"
fi

# 6. .map() in JSX (should use <For>)
m=$(search '\.\s*map\s*\(' || true)
if [[ -n "$m" ]]; then
  warn "warn" \
    "Array .map() detected — prefer <For> or <Index>" \
    "Using .map() recreates all DOM nodes on update. Use <For each={...}> instead." \
    "$m"
fi

# 7. Early returns in components (if/return before JSX)
m=$(search 'if\s*\(.*\)\s*return\s' | grep -v 'test\|spec\|\.test\.' || true)
if [[ -n "$m" ]]; then
  warn "warn" \
    "Early return in component body" \
    "Components run once. Early returns won't re-evaluate. Use <Show> for conditional rendering." \
    "$m"
fi

# 8. Spreading store values
m=$(search '\.\.\.\s*store\b|\.\.\.\s*state\b' | grep -v 'setState\|setStore' || true)
if [[ -n "$m" ]]; then
  warn "warn" \
    "Spreading store/state object" \
    "Spreading copies values and breaks proxy tracking. Access store properties directly." \
    "$m"
fi

# 9. className instead of class
m=$(search 'className=' || true)
if [[ -n "$m" ]]; then
  warn "warn" \
    "className used instead of class" \
    "Solid uses native HTML attributes. Replace className with class." \
    "$m"
fi

# 10. setTimeout/setInterval without onCleanup
m=$(search 'setInterval\s*\(|setTimeout\s*\(' || true)
if [[ -n "$m" ]]; then
  # Check if any of these files also have onCleanup
  files_with_timers=$(echo "$m" | cut -d: -f1 | sort -u)
  missing_cleanup=""
  for f in $files_with_timers; do
    if ! grep -q 'onCleanup' "$f" 2>/dev/null; then
      missing_cleanup+="$f"$'\n'
    fi
  done
  if [[ -n "$missing_cleanup" ]]; then
    warn "warn" \
      "Timer without onCleanup" \
      "setInterval/setTimeout should be paired with onCleanup to prevent leaks." \
      "$missing_cleanup"
  fi
fi

# --- Summary ---
echo "============================================"
if (( ISSUES == 0 )); then
  echo -e "${GRN}No reactivity issues detected! ✅${RST}"
else
  echo -e "${YEL}Found $ISSUES potential issue(s).${RST}"
  echo "Review each finding — some may be false positives."
fi
echo "============================================"
