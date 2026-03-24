#!/usr/bin/env bash
# =============================================================================
# git-bisect-helper.sh — Automated Git Bisect Runner
# =============================================================================
#
# Usage: ./git-bisect-helper.sh [OPTIONS] <test-command>
#
# Arguments:
#   <test-command>    Command to test each commit (exit 0 = good, non-zero = bad)
#
# Options:
#   -g, --good <ref>   Known good commit/tag (default: auto-detect first commit)
#   -b, --bad <ref>    Known bad commit/tag (default: HEAD)
#   -p, --path <path>  Limit bisect to changes in <path>
#   -v, --verbose      Show test output for each step
#   -h, --help         Show this help message
#
# Examples:
#   ./git-bisect-helper.sh "npm test"
#   ./git-bisect-helper.sh -g v1.0.0 -b HEAD "python -m pytest tests/auth/"
#   ./git-bisect-helper.sh -g abc1234 -p src/api/ "make test"
#   ./git-bisect-helper.sh --verbose "cargo test --lib"
#
# The script will:
#   1. Start bisect with the given good/bad range
#   2. Automatically run the test command at each bisect step
#   3. Report the first bad commit with full details
#   4. Clean up (reset bisect) when done or on interrupt
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

GOOD_REF=""
BAD_REF="HEAD"
BISECT_PATH=""
VERBOSE=false
TEST_CMD=""

usage() {
    sed -n '2,21p' "$0" | sed 's/^# \?//'
    exit 0
}

log_info()  { echo -e "${BLUE}ℹ️  $*${NC}"; }
log_ok()    { echo -e "${GREEN}✅ $*${NC}"; }
log_warn()  { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error() { echo -e "${RED}❌ $*${NC}"; }
log_step()  { echo -e "${BOLD}▶ $*${NC}"; }

# Cleanup on exit
cleanup() {
    if git bisect log &>/dev/null; then
        log_info "Cleaning up bisect session..."
        git bisect reset &>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--good)    GOOD_REF="$2"; shift 2 ;;
        -b|--bad)     BAD_REF="$2"; shift 2 ;;
        -p|--path)    BISECT_PATH="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help)    usage ;;
        -*)           log_error "Unknown option: $1"; usage ;;
        *)            TEST_CMD="$1"; shift ;;
    esac
done

if [ -z "$TEST_CMD" ]; then
    log_error "No test command provided"
    echo ""
    usage
fi

# Verify we're in a git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not inside a Git repository"
    exit 1
fi

# Check for clean working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
    log_error "Working tree is not clean. Commit or stash changes first."
    exit 1
fi

# Auto-detect good ref if not provided
if [ -z "$GOOD_REF" ]; then
    # Try to find the first commit
    GOOD_REF=$(git rev-list --max-parents=0 HEAD | tail -1)
    log_warn "No --good ref specified. Using first commit: $(git log --oneline -1 "$GOOD_REF")"
    echo "  Tip: Provide a closer good ref with -g for faster bisect"
    echo ""
fi

# Validate refs
if ! git rev-parse --verify "$GOOD_REF" &>/dev/null; then
    log_error "Invalid good ref: $GOOD_REF"
    exit 1
fi
if ! git rev-parse --verify "$BAD_REF" &>/dev/null; then
    log_error "Invalid bad ref: $BAD_REF"
    exit 1
fi

# Count commits in range
TOTAL_COMMITS=$(git rev-list --count "$GOOD_REF..$BAD_REF")
MAX_STEPS=$(echo "l($TOTAL_COMMITS)/l(2)" | bc -l 2>/dev/null | awk '{printf "%d", $1+1}' || echo "?")

echo "==========================================="
echo "  Git Bisect Helper"
echo "==========================================="
echo ""
echo "  Good: $(git log --oneline -1 "$GOOD_REF")"
echo "  Bad:  $(git log --oneline -1 "$BAD_REF")"
echo "  Commits to search: $TOTAL_COMMITS"
echo "  Estimated steps: ~$MAX_STEPS"
echo "  Test command: $TEST_CMD"
if [ -n "$BISECT_PATH" ]; then
    echo "  Scope: $BISECT_PATH"
fi
echo ""

# Start bisect
log_step "Starting bisect..."
git bisect start $BAD_REF $GOOD_REF ${BISECT_PATH:+-- "$BISECT_PATH"} 2>&1

# Run bisect with the test command
STEP=0
log_step "Running automated bisect..."
echo ""

BISECT_OUTPUT=$(mktemp)

# Use git bisect run
if $VERBOSE; then
    git bisect run sh -c "$TEST_CMD" 2>&1 | tee "$BISECT_OUTPUT"
else
    git bisect run sh -c "$TEST_CMD" 2>&1 | tee "$BISECT_OUTPUT" | \
        grep -E '(^Bisecting:|is the first bad commit|running|bisect found)' || true
fi

echo ""
echo "==========================================="
echo "  Result"
echo "==========================================="
echo ""

# Extract the first bad commit
FIRST_BAD=$(grep -oP '[a-f0-9]{40}(?= is the first bad commit)' "$BISECT_OUTPUT" || true)
if [ -n "$FIRST_BAD" ]; then
    log_ok "First bad commit found:"
    echo ""
    git --no-pager log -1 --stat "$FIRST_BAD"
    echo ""
    echo -e "  SHA: ${YELLOW}$FIRST_BAD${NC}"
    echo -e "  Short: ${YELLOW}$(git rev-parse --short "$FIRST_BAD")${NC}"
    echo ""
    echo "  Inspect with:"
    echo "    git show $FIRST_BAD"
    echo "    git diff ${FIRST_BAD}^..$FIRST_BAD"
else
    log_warn "Could not determine the first bad commit"
    echo "  Check the full output above for details"
fi

rm -f "$BISECT_OUTPUT"

# bisect reset happens in cleanup trap
