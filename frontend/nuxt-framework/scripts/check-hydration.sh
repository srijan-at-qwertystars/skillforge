#!/usr/bin/env bash
# ==============================================================================
# check-hydration.sh — Find potential hydration mismatch issues in a Nuxt project
#
# Usage:
#   ./check-hydration.sh [project-dir]
#   ./check-hydration.sh              # Uses current directory
#   ./check-hydration.sh ./my-app     # Scan specific project
#
# Checks for:
#   1. Direct browser API usage (window, document, localStorage) in setup
#   2. Non-deterministic values (Math.random, Date.now, crypto.randomUUID)
#   3. Plain ref() used for shared/global state (should be useState)
#   4. $fetch in <script setup> (causes double-fetch)
#   5. Missing <ClientOnly> around client-only components
#   6. Conditional rendering that may differ server vs client
# ==============================================================================
set -euo pipefail

PROJECT_DIR="${1:-.}"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Error: Directory '$PROJECT_DIR' does not exist."
  exit 1
fi

# Check for nuxt.config
if [[ ! -f "$PROJECT_DIR/nuxt.config.ts" && ! -f "$PROJECT_DIR/nuxt.config.js" ]]; then
  echo "Warning: No nuxt.config found in '$PROJECT_DIR'. Is this a Nuxt project?"
fi

ISSUES=0
WARNINGS=0

# Colors (if terminal supports them)
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

print_issue() {
  echo -e "${RED}❌ ISSUE:${NC} $1"
  echo -e "   ${CYAN}File:${NC} $2"
  echo -e "   ${YELLOW}Fix:${NC} $3"
  echo ""
  ISSUES=$((ISSUES + 1))
}

print_warning() {
  echo -e "${YELLOW}⚠️  WARNING:${NC} $1"
  echo -e "   ${CYAN}File:${NC} $2"
  echo -e "   ${YELLOW}Fix:${NC} $3"
  echo ""
  WARNINGS=$((WARNINGS + 1))
}

echo "🔍 Scanning for hydration issues in: $PROJECT_DIR"
echo "================================================================"
echo ""

# ---------- Check 1: Browser APIs in script setup ----------
echo "📋 Check 1: Browser-only APIs in setup context"
echo "------------------------------------------------"

while IFS= read -r file; do
  if grep -n 'window\.\|document\.\|localStorage\.\|sessionStorage\.\|navigator\.' "$file" 2>/dev/null | grep -v 'onMounted\|onBeforeMount\|import\.meta\.\|process\.client\|//' | head -5 | while IFS= read -r match; do
    print_issue "Direct browser API usage may cause hydration mismatch" \
      "$file: $match" \
      "Wrap in onMounted() or use <ClientOnly>, or guard with import.meta.client"
  done; then true; fi
done < <(find "$PROJECT_DIR" \( -name "*.vue" -o -name "*.ts" \) \
  -not -path "*/node_modules/*" \
  -not -path "*/.nuxt/*" \
  -not -path "*/.output/*" \
  -not -path "*/server/*" \
  -not -name "*.client.ts" \
  -not -name "*.server.ts" 2>/dev/null)

# ---------- Check 2: Non-deterministic values ----------
echo "📋 Check 2: Non-deterministic values in templates/setup"
echo "--------------------------------------------------------"

while IFS= read -r file; do
  if grep -n 'Math\.random\|crypto\.randomUUID\|Date\.now\|new Date()' "$file" 2>/dev/null | grep -v 'onMounted\|useState\|//' | head -5 | while IFS= read -r match; do
    print_warning "Non-deterministic value may differ between server and client" \
      "$file: $match" \
      "Use useState() to generate once, or compute in onMounted()"
  done; then true; fi
done < <(find "$PROJECT_DIR" -name "*.vue" \
  -not -path "*/node_modules/*" \
  -not -path "*/.nuxt/*" \
  -not -path "*/.output/*" 2>/dev/null)

# ---------- Check 3: Module-level ref for shared state ----------
echo "📋 Check 3: Module-level ref() for shared state"
echo "-------------------------------------------------"

while IFS= read -r file; do
  if grep -n '^const .* = ref(' "$file" 2>/dev/null | grep -v 'useState\|//' | head -5 | while IFS= read -r match; do
    print_warning "Module-level ref() leaks state between SSR requests" \
      "$file: $match" \
      "Use useState() for shared state or move ref() inside a function/composable return"
  done; then true; fi
done < <(find "$PROJECT_DIR/composables" "$PROJECT_DIR/utils" -name "*.ts" 2>/dev/null)

# ---------- Check 4: Bare $fetch in script setup ----------
echo "📋 Check 4: Bare \$fetch in component setup (causes double-fetch)"
echo "------------------------------------------------------------------"

while IFS= read -r file; do
  # Look for $fetch not inside a function or event handler
  if grep -n '\$fetch(' "$file" 2>/dev/null | grep -v 'useFetch\|useAsyncData\|defineEventHandler\|async function\|const .* = async\|=>' | head -5 | while IFS= read -r match; do
    print_issue "Bare \$fetch in setup causes double-fetch (SSR + client)" \
      "$file: $match" \
      "Use useFetch() or useAsyncData() instead for SSR deduplication"
  done; then true; fi
done < <(find "$PROJECT_DIR" -name "*.vue" \
  -not -path "*/node_modules/*" \
  -not -path "*/.nuxt/*" \
  -not -path "*/.output/*" 2>/dev/null)

# ---------- Check 5: v-if with client-only conditions ----------
echo "📋 Check 5: Conditional rendering with potential client-only values"
echo "-------------------------------------------------------------------"

while IFS= read -r file; do
  if grep -n 'v-if=".*isMobile\|v-if=".*isClient\|v-if=".*window\|v-if=".*screen\|v-if=".*innerWidth' "$file" 2>/dev/null | head -5 | while IFS= read -r match; do
    print_warning "Client-only condition in v-if may cause hydration mismatch" \
      "$file: $match" \
      "Use CSS media queries, <ClientOnly>, or set value in onMounted()"
  done; then true; fi
done < <(find "$PROJECT_DIR" -name "*.vue" \
  -not -path "*/node_modules/*" \
  -not -path "*/.nuxt/*" \
  -not -path "*/.output/*" 2>/dev/null)

# ---------- Check 6: useState with non-serializable values ----------
echo "📋 Check 6: useState with potentially non-serializable values"
echo "--------------------------------------------------------------"

while IFS= read -r file; do
  if grep -n 'useState.*new Map\|useState.*new Set\|useState.*function\|useState.*=>' "$file" 2>/dev/null | head -5 | while IFS= read -r match; do
    print_issue "useState values must be JSON-serializable (no Map, Set, functions)" \
      "$file: $match" \
      "Use plain objects/arrays instead of Map/Set, avoid function values"
  done; then true; fi
done < <(find "$PROJECT_DIR" \( -name "*.vue" -o -name "*.ts" \) \
  -not -path "*/node_modules/*" \
  -not -path "*/.nuxt/*" \
  -not -path "*/.output/*" \
  -not -path "*/server/*" 2>/dev/null)

# ---------- Summary ----------
echo "================================================================"
if [[ $ISSUES -eq 0 && $WARNINGS -eq 0 ]]; then
  echo -e "${GREEN}✅ No hydration issues detected!${NC}"
else
  echo -e "Found: ${RED}${ISSUES} issues${NC}, ${YELLOW}${WARNINGS} warnings${NC}"
  echo ""
  echo "Quick fixes reference:"
  echo "  • Browser APIs → onMounted() or <ClientOnly>"
  echo "  • Random/Date → useState() or onMounted()"
  echo "  • Shared ref() → useState()"
  echo "  • Bare \$fetch → useFetch() / useAsyncData()"
  echo "  • Client v-if → CSS media queries or deferred check"
fi
echo ""
exit $ISSUES
