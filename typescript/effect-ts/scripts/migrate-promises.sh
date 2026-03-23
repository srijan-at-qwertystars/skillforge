#!/usr/bin/env bash
# migrate-promises.sh — Find Promise-based patterns in a codebase for migration to Effect
#
# Usage:
#   ./migrate-promises.sh <directory>
#   ./migrate-promises.sh ./src
#   ./migrate-promises.sh ./src --verbose
#   ./migrate-promises.sh ./src --json
#
# Scans TypeScript/JavaScript files for common Promise-based patterns and reports
# them as candidates for migration to Effect. Categories:
#
#   1. async/await functions         → Effect.gen / Effect.tryPromise
#   2. Promise.all / Promise.race    → Effect.all / Effect.race
#   3. try/catch blocks              → Effect.catchTag / Effect.catchAll
#   4. new Promise constructors      → Effect.async
#   5. .then/.catch chains           → pipe / Effect.map / Effect.flatMap
#   6. setTimeout/setInterval        → Effect.sleep / Schedule
#   7. Manual retry loops            → Effect.retry with Schedule
#   8. throw new Error               → Effect.fail with tagged errors
#
# Exit code: 0 if patterns found, 1 if no patterns found or error.

set -euo pipefail

TARGET_DIR="${1:-}"
VERBOSE=false
JSON_OUTPUT=false

if [ -z "$TARGET_DIR" ]; then
  echo "Usage: $0 <directory> [--verbose] [--json]"
  echo ""
  echo "Scans TypeScript files for Promise-based patterns to migrate to Effect."
  exit 1
fi

shift || true
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    --json) JSON_OUTPUT=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory not found: $TARGET_DIR"
  exit 1
fi

TOTAL=0

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

search_pattern() {
  local label="$1"
  local pattern="$2"
  local suggestion="$3"
  local count

  count=$(grep -rn --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    -E "$pattern" "$TARGET_DIR" 2>/dev/null | grep -v node_modules | grep -v dist | wc -l)

  if [ "$count" -gt 0 ]; then
    TOTAL=$((TOTAL + count))
    if [ "$JSON_OUTPUT" = true ]; then
      echo "  { \"pattern\": \"$label\", \"count\": $count, \"suggestion\": \"$suggestion\" },"
    else
      echo -e "${YELLOW}📋 $label${NC} — ${RED}$count${NC} occurrences"
      echo -e "   ${GREEN}→ $suggestion${NC}"
      if [ "$VERBOSE" = true ]; then
        echo ""
        grep -rn --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
          -E "$pattern" "$TARGET_DIR" 2>/dev/null | grep -v node_modules | grep -v dist | head -10 | \
          while IFS= read -r line; do
            echo -e "   ${CYAN}$line${NC}"
          done
        echo ""
      fi
    fi
  fi
}

if [ "$JSON_OUTPUT" = true ]; then
  echo "{ \"directory\": \"$TARGET_DIR\", \"patterns\": ["
else
  echo ""
  echo "🔍 Scanning $TARGET_DIR for Promise-based patterns..."
  echo "=================================================="
  echo ""
fi

search_pattern \
  "async/await functions" \
  "async\s+function|async\s*\(" \
  "Effect.gen(function* () { ... }) with Effect.tryPromise"

search_pattern \
  "Promise.all" \
  "Promise\.all\s*\(" \
  "Effect.all([...], { concurrency: 'unbounded' })"

search_pattern \
  "Promise.race" \
  "Promise\.race\s*\(" \
  "Effect.race or Effect.raceFirst"

search_pattern \
  "Promise.allSettled" \
  "Promise\.allSettled\s*\(" \
  "Effect.all with { mode: 'either' } or Effect.forEach with Effect.either"

search_pattern \
  "new Promise constructor" \
  "new\s+Promise\s*\(" \
  "Effect.async or Effect.tryPromise"

search_pattern \
  ".then() chains" \
  "\.\s*then\s*\(" \
  "Effect.map / Effect.flatMap or pipe()"

search_pattern \
  ".catch() chains" \
  "\.\s*catch\s*\(" \
  "Effect.catchTag / Effect.catchAll"

search_pattern \
  "try/catch blocks" \
  "}\s*catch\s*\(" \
  "Effect.catchTag / Effect.catchAll with tagged errors"

search_pattern \
  "throw new Error" \
  "throw\s+new\s+(Error|TypeError|RangeError)" \
  "Effect.fail(new TaggedError(...))"

search_pattern \
  "setTimeout" \
  "setTimeout\s*\(" \
  "Effect.sleep('N seconds')"

search_pattern \
  "setInterval" \
  "setInterval\s*\(" \
  "Effect.repeat(Schedule.spaced('N seconds'))"

search_pattern \
  "Manual retry loops" \
  "for\s*\(.*retry|while\s*\(.*retry|retries?\s*[-+<>=]" \
  "Effect.retry(Schedule.exponential(...))"

search_pattern \
  "Express/Fastify route handlers" \
  "(app|router)\.(get|post|put|patch|delete)\s*\(" \
  "@effect/platform HttpRouter.get/post/..."

search_pattern \
  "Zod schemas" \
  "z\.(object|string|number|boolean|array|enum|union|literal)\s*\(" \
  "Effect Schema (Schema.Struct, Schema.String, etc.)"

if [ "$JSON_OUTPUT" = true ]; then
  echo "  null"
  echo "], \"total\": $TOTAL }"
else
  echo ""
  echo "=================================================="
  if [ "$TOTAL" -gt 0 ]; then
    echo -e "📊 Total migration candidates: ${RED}$TOTAL${NC}"
    echo ""
    echo "💡 Tip: Start with leaf functions (no callers) and work up."
    echo "   Use ManagedRuntime to bridge Effect into existing Express routes."
  else
    echo -e "${GREEN}✅ No Promise-based patterns found. Code may already use Effect!${NC}"
  fi
fi
