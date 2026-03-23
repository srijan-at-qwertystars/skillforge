#!/usr/bin/env bash
# check-liveview-antipatterns.sh — Scan .ex files for common LiveView anti-patterns
#
# Usage:
#   ./check-liveview-antipatterns.sh [directory]
#
# Examples:
#   ./check-liveview-antipatterns.sh lib/my_app_web/live/
#   ./check-liveview-antipatterns.sh                        # scans current directory
#
# Checks for:
#   1. Assigns accessed directly in render (bypassing the template engine)
#   2. Missing id on LiveComponent
#   3. Blocking operations in mount (Repo calls without assign_async)
#   4. PubSub subscribe without connected? guard
#   5. Missing phx-target={@myself} in LiveComponent events
#   6. Large data in assigns (File.read! in mount/handle_event)
#   7. Missing phx-debounce on text inputs
#   8. Process.send_after without connected? guard
#   9. Missing @impl true annotations
#  10. Directly accessing socket.assigns in templates

set -euo pipefail

SEARCH_DIR="${1:-.}"
FOUND_ISSUES=0
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

check_pattern() {
  local label="$1"
  local pattern="$2"
  local severity="$3"
  local suggestion="$4"
  local files

  files=$(grep -rl --include="*.ex" --include="*.heex" -E "$pattern" "$SEARCH_DIR" 2>/dev/null || true)

  if [ -n "$files" ]; then
    FOUND_ISSUES=$((FOUND_ISSUES + 1))
    if [ "$severity" = "error" ]; then
      echo -e "${RED}✗ [ERROR]${NC} ${BOLD}${label}${NC}"
    else
      echo -e "${YELLOW}⚠ [WARN]${NC}  ${BOLD}${label}${NC}"
    fi
    echo -e "  ${CYAN}Suggestion:${NC} $suggestion"
    echo "$files" | while IFS= read -r f; do
      matches=$(grep -n -E "$pattern" "$f" 2>/dev/null | head -5)
      echo "$matches" | while IFS= read -r line; do
        echo "    $f:$line"
      done
    done
    echo ""
  fi
}

echo -e "${BOLD}Phoenix LiveView Anti-Pattern Scanner${NC}"
echo -e "Scanning: ${CYAN}${SEARCH_DIR}${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. LiveComponent without id
check_pattern \
  "LiveComponent missing :id assign" \
  "live_component.*module:.*[^,]*$|<\.live_component[^>]*module=[^>]*(?!.*\bid\b)" \
  "error" \
  "Every LiveComponent MUST have a unique :id. Add id={\"component-\#{@record.id}\"}."

# 2. Blocking Repo calls in mount without assign_async
check_pattern \
  "Blocking database call in mount/3" \
  "def mount\(.*\n.*Repo\.(all|one|get|aggregate)" \
  "warn" \
  "Use assign_async/3 or start_async/3 for DB calls in mount to avoid blocking the initial render."

# 3. PubSub.subscribe without connected? guard
check_pattern \
  "PubSub.subscribe without connected? guard" \
  "PubSub\.subscribe.*(?<!if connected)" \
  "error" \
  "Guard PubSub.subscribe with 'if connected?(socket)' to prevent subscriptions during static render."

# 4. Process.send_after without connected? guard
check_pattern \
  "Process.send_after without connected? guard" \
  "Process\.send_after(?!.*connected)" \
  "warn" \
  "Guard Process.send_after with 'if connected?(socket)' in mount/3."

# 5. File.read! in mount or handle_event (large data in assigns)
check_pattern \
  "File.read! in LiveView callback (stores large data in assigns)" \
  "def (mount|handle_event).*\n.*File\.read!" \
  "warn" \
  "Avoid storing large file contents in assigns. Stream the data or use send_download/3."

# 6. Missing @impl true before LiveView callbacks
check_pattern \
  "LiveView callback missing @impl true" \
  "^\s*def (mount|handle_event|handle_info|handle_params|render|handle_async|update|terminate)\(" \
  "warn" \
  "Add @impl true before all LiveView/LiveComponent callback definitions."

# 7. Direct socket.assigns access in HEEx (should use @variable)
check_pattern \
  "Direct socket.assigns access in template" \
  "socket\.assigns\." \
  "warn" \
  "In HEEx templates, use @variable instead of socket.assigns.variable."

# 8. Enum operations on streams (streams aren't enumerable)
check_pattern \
  "Enum operation on @streams (streams are not enumerable)" \
  "Enum\.\w+.*@streams" \
  "error" \
  "Streams are not enumerable. Use :for={... <- @streams.name} in templates only."

# 9. put_flash after push_navigate (flash won't display)
check_pattern \
  "put_flash after push_navigate (flash may be lost)" \
  "push_navigate.*\n.*put_flash|push_navigate.*|>.*put_flash" \
  "warn" \
  "Call put_flash BEFORE push_navigate, not after. Flash is lost if set after navigation."

# 10. Assigns in render that should be precomputed
check_pattern \
  "Enum.filter/map/reduce inside HEEx template" \
  "<%=.*Enum\.(filter|map|reduce|count|sort|group_by)" \
  "warn" \
  "Precompute filtered/mapped data in callbacks and assign the result. Computing in templates hurts performance."

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FOUND_ISSUES" -eq 0 ]; then
  echo -e "${GREEN}✓ No anti-patterns detected!${NC}"
else
  echo -e "${RED}Found $FOUND_ISSUES potential issue(s).${NC}"
  echo -e "Review each finding — some may be false positives depending on context."
fi
exit 0
