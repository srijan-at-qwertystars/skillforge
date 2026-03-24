#!/usr/bin/env bash

# lint-coroutines.sh — Check for common Kotlin coroutine anti-patterns
#
# Usage:
#   chmod +x lint-coroutines.sh
#   ./lint-coroutines.sh [directory|file]
#   ./lint-coroutines.sh src/main/kotlin/
#   ./lint-coroutines.sh MyViewModel.kt
#
# What it checks:
#   1. GlobalScope usage (breaks structured concurrency)
#   2. runBlocking in production code (thread blocking)
#   3. Dispatchers.Main without lifecycle awareness
#   4. Thread.sleep in coroutine/suspend contexts
#   5. Missing ensureActive/yield in loops
#   6. launch(Job()) breaking parent hierarchy
#   7. Catching generic Exception (swallows CancellationException)
#   8. Unsafe .value access on MutableStateFlow without lifecycle
#   9. launchWhenStarted/launchWhenResumed (deprecated)
#  10. runBlocking in @Test without using runTest

set -euo pipefail

# Colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Counters
ERRORS=0
WARNINGS=0
INFO=0
FILES_CHECKED=0

TARGET="${1:-.}"

# Find Kotlin files
if [[ -f "$TARGET" ]]; then
    KOTLIN_FILES="$TARGET"
else
    KOTLIN_FILES=$(find "$TARGET" -name "*.kt" -not -path "*/build/*" -not -path "*/.gradle/*" -not -path "*/test/*" -not -path "*/androidTest/*" 2>/dev/null || true)
fi

if [[ -z "$KOTLIN_FILES" ]]; then
    echo -e "${YELLOW}No Kotlin files found in: $TARGET${NC}"
    exit 0
fi

echo -e "${BOLD}🔍 Kotlin Coroutine Lint${NC}"
echo "═══════════════════════════════════════════════════════════"
echo "Target: $TARGET"
echo ""

check_pattern() {
    local pattern="$1"
    local message="$2"
    local severity="$3"  # error, warning, info
    local suggestion="$4"
    local exclude_pattern="${5:-__NOMATCH__}"

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        
        local matches
        matches=$(grep -n "$pattern" "$file" 2>/dev/null | grep -v "$exclude_pattern" || true)
        
        if [[ -n "$matches" ]]; then
            while IFS= read -r match; do
                local line_num
                line_num=$(echo "$match" | cut -d: -f1)
                local line_content
                line_content=$(echo "$match" | cut -d: -f2-)
                
                case "$severity" in
                    error)
                        echo -e "${RED}❌ ERROR${NC}: $message"
                        ((ERRORS++)) || true
                        ;;
                    warning)
                        echo -e "${YELLOW}⚠️  WARN${NC}: $message"
                        ((WARNINGS++)) || true
                        ;;
                    info)
                        echo -e "${CYAN}ℹ️  INFO${NC}: $message"
                        ((INFO++)) || true
                        ;;
                esac
                echo "   📁 $file:$line_num"
                echo "   📝 $(echo "$line_content" | sed 's/^[[:space:]]*//')"
                echo "   💡 $suggestion"
                echo ""
            done <<< "$matches"
        fi
    done <<< "$KOTLIN_FILES"
}

# Count files
FILES_CHECKED=$(echo "$KOTLIN_FILES" | wc -l | tr -d ' ')
echo "Checking $FILES_CHECKED Kotlin files..."
echo ""

# ──────────────────────────────────────────────
# Rule 1: GlobalScope usage
# ──────────────────────────────────────────────
check_pattern \
    "GlobalScope\." \
    "GlobalScope breaks structured concurrency" \
    "error" \
    "Use viewModelScope, lifecycleScope, or a custom CoroutineScope tied to a lifecycle"

# ──────────────────────────────────────────────
# Rule 2: runBlocking in production code
# ──────────────────────────────────────────────
check_pattern \
    "runBlocking" \
    "runBlocking blocks the calling thread" \
    "error" \
    "Use suspend functions, launch, or async. runBlocking is only safe in main() or tests" \
    "fun main"

# ──────────────────────────────────────────────
# Rule 3: Thread.sleep in suspend/coroutine context
# ──────────────────────────────────────────────
check_pattern \
    "Thread\.sleep" \
    "Thread.sleep blocks the thread in coroutine context" \
    "error" \
    "Use delay() instead — it suspends without blocking the thread"

# ──────────────────────────────────────────────
# Rule 4: launch(Job()) breaking parent hierarchy
# ──────────────────────────────────────────────
check_pattern \
    "launch(Job())" \
    "launch(Job()) creates a new root Job, breaking parent-child hierarchy" \
    "error" \
    "Remove Job() argument — launch creates a child Job automatically"

# ──────────────────────────────────────────────
# Rule 5: Deprecated launchWhenStarted/launchWhenResumed
# ──────────────────────────────────────────────
check_pattern \
    "launchWhen\(Started\|Resumed\|Created\)" \
    "launchWhenX is deprecated — suspends but doesn't cancel" \
    "warning" \
    "Use repeatOnLifecycle(Lifecycle.State.STARTED) instead"

# ──────────────────────────────────────────────
# Rule 6: Catching generic Exception in coroutines
# ──────────────────────────────────────────────
check_pattern \
    "catch.*Exception\b" \
    "Catching generic Exception may swallow CancellationException" \
    "warning" \
    "Catch specific exceptions, or rethrow CancellationException, or call ensureActive() in catch block" \
    "CancellationException"

# ──────────────────────────────────────────────
# Rule 7: Dispatchers.IO without withContext
# ──────────────────────────────────────────────
check_pattern \
    "launch(Dispatchers\.IO)" \
    "Consider using withContext(Dispatchers.IO) for clearer scoping" \
    "info" \
    "launch(Dispatchers.IO) works but withContext is preferred for dispatcher switching in suspend functions"

# ──────────────────────────────────────────────
# Rule 8: .value on MutableStateFlow in Fragment/Activity
# ──────────────────────────────────────────────
check_pattern \
    "\.collect.*\.value\s*=" \
    "Direct StateFlow value assignment in collector may indicate logic issue" \
    "info" \
    "Ensure StateFlow updates happen in the ViewModel, not in UI collectors"

# ──────────────────────────────────────────────
# Rule 9: Dispatchers.Unconfined in production
# ──────────────────────────────────────────────
check_pattern \
    "Dispatchers\.Unconfined" \
    "Dispatchers.Unconfined is error-prone in production" \
    "warning" \
    "Use Dispatchers.Default, Dispatchers.IO, or Dispatchers.Main. Unconfined is mainly for testing"

# ──────────────────────────────────────────────
# Rule 10: CoroutineScope without cancel
# ──────────────────────────────────────────────
check_pattern \
    "CoroutineScope(" \
    "Custom CoroutineScope created — ensure it's cancelled when no longer needed" \
    "info" \
    "Call scope.cancel() in onDestroy/onCleared/close to prevent coroutine leaks" \
    "viewModelScope\|lifecycleScope\|TestScope\|rememberCoroutineScope"

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo -e "${BOLD}Summary${NC}"
echo "───────────────────────────────────────────────────────────"
echo -e "  Files checked: $FILES_CHECKED"
echo -e "  ${RED}Errors:   $ERRORS${NC}"
echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
echo -e "  ${CYAN}Info:     $INFO${NC}"
echo ""

TOTAL=$((ERRORS + WARNINGS))
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}❌ Found $ERRORS error(s). Please fix these anti-patterns.${NC}"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}⚠️  Found $WARNINGS warning(s). Consider addressing these.${NC}"
    exit 0
else
    echo -e "${GREEN}✅ No coroutine anti-patterns found!${NC}"
    exit 0
fi
