#!/usr/bin/env bash
# migrate-from-react.sh — Detect React patterns that need SolidJS equivalents.
#
# Usage:
#   ./migrate-from-react.sh [directory]
#
# Scans .tsx/.jsx/.ts/.js files for React-specific patterns and suggests
# SolidJS replacements. Does NOT modify files — report only.
#
# Examples:
#   ./migrate-from-react.sh src/
#   ./migrate-from-react.sh .

set -euo pipefail

TARGET="${1:-.}"
FOUND=0

if [[ ! -d "$TARGET" ]]; then
  echo "Error: '$TARGET' is not a directory."
  exit 1
fi

# Color output if terminal supports it
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
RST='\033[0m'
[[ ! -t 1 ]] && RED="" && YEL="" && GRN="" && RST=""

check_pattern() {
  local pattern="$1"
  local label="$2"
  local suggestion="$3"
  local matches

  matches=$(grep -rn --include='*.tsx' --include='*.jsx' --include='*.ts' --include='*.js' \
    -E "$pattern" "$TARGET" 2>/dev/null || true)

  if [[ -n "$matches" ]]; then
    FOUND=$((FOUND + 1))
    echo -e "${RED}[$FOUND] $label${RST}"
    echo -e "  ${YEL}→ $suggestion${RST}"
    echo "$matches" | head -20 | sed 's/^/    /'
    local total
    total=$(echo "$matches" | wc -l)
    if (( total > 20 )); then
      echo "    ... and $((total - 20)) more"
    fi
    echo ""
  fi
}

echo "=========================================="
echo " React → SolidJS Migration Report"
echo " Scanning: $TARGET"
echo "=========================================="
echo ""

# --- Imports ---
check_pattern "from ['\"]react['\"]" \
  "React imports detected" \
  "Replace with: import { createSignal, ... } from 'solid-js'"

check_pattern "from ['\"]react-dom['\"]" \
  "ReactDOM imports detected" \
  "Replace with: import { render } from 'solid-js/web'"

# --- Hooks → Primitives ---
check_pattern "useState\b" \
  "useState → createSignal" \
  "const [val, setVal] = createSignal(initial); // read with val()"

check_pattern "useEffect\b" \
  "useEffect → createEffect" \
  "createEffect(() => { ... }); // auto-tracks deps, no dep array needed"

check_pattern "useMemo\b" \
  "useMemo → createMemo (or just inline)" \
  "const derived = createMemo(() => expr); // or just use inline in JSX"

check_pattern "useCallback\b" \
  "useCallback → not needed" \
  "Solid components run once; functions don't need memoization. Remove useCallback."

check_pattern "useRef\b" \
  "useRef → let variable" \
  "let ref!: HTMLElement; <div ref={ref} /> // plain variable, not hook"

check_pattern "useContext\b" \
  "React useContext → Solid useContext" \
  "Same API name but import from 'solid-js': import { useContext } from 'solid-js'"

check_pattern "useReducer\b" \
  "useReducer → createStore" \
  "const [state, setState] = createStore(initial); // from 'solid-js/store'"

# --- JSX Differences ---
check_pattern "className=" \
  "className → class" \
  "Solid uses native HTML attributes: class=\"...\" instead of className"

check_pattern "htmlFor=" \
  "htmlFor → for" \
  "Use native: for=\"...\" instead of htmlFor"

check_pattern "dangerouslySetInnerHTML" \
  "dangerouslySetInnerHTML → innerHTML" \
  "Use: <div innerHTML={htmlString} />"

check_pattern "onChange=\{" \
  "onChange may behave differently" \
  "Solid onChange fires on blur (native). Use onInput for real-time input tracking."

check_pattern 'style=\{\{[^}]*[a-z][A-Z]' \
  "camelCase style properties → kebab-case" \
  "Solid uses kebab-case: style={{ 'font-size': '16px' }} not fontSize"

# --- Patterns ---
check_pattern "\.map\s*\(" \
  ".map() in JSX → <For> or <Index>" \
  "Use <For each={items()}>{(item) => ...}</For> for optimal reactivity"

check_pattern "React\.Fragment|<>" \
  "React.Fragment / <>" \
  "Solid supports <> fragments natively, but check for React-specific patterns"

check_pattern "React\.memo|memo\(" \
  "React.memo → not needed" \
  "Solid components run once; there's no re-render to memoize against."

check_pattern "forwardRef" \
  "forwardRef → not needed" \
  "Pass ref as a regular prop in Solid. No forwardRef wrapper required."

check_pattern "React\.lazy|React\.Suspense" \
  "React.lazy → lazy from solid-js" \
  "import { lazy } from 'solid-js'; const Comp = lazy(() => import('./Comp'));"

check_pattern "useLayoutEffect" \
  "useLayoutEffect → createRenderEffect" \
  "createRenderEffect runs synchronously during render, before DOM paint."

check_pattern "key=" \
  "key prop → not used in Solid" \
  "Solid's <For> handles identity via callback. Remove key props."

# --- Summary ---
echo "=========================================="
if (( FOUND == 0 )); then
  echo -e "${GRN}No React patterns detected. Code looks Solid-ready! ✅${RST}"
else
  echo -e "${YEL}Found $FOUND React pattern(s) to migrate.${RST}"
  echo "Review each finding and apply the suggested SolidJS equivalent."
fi
echo "=========================================="
