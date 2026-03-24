#!/usr/bin/env bash
# =============================================================================
# git-cleanup.sh — Git Repository Cleanup Script
# =============================================================================
#
# Usage: ./git-cleanup.sh [OPTIONS]
#
# Options:
#   -n, --dry-run     Show what would be done without making changes
#   -a, --aggressive  Run aggressive gc (slower, more thorough)
#   -r, --remote      Also prune stale remote-tracking branches
#   -h, --help        Show this help message
#
# What it does:
#   1. Prunes stale remote-tracking branches
#   2. Removes local branches already merged into main/master
#   3. Runs git gc and prune
#   4. Reports disk space savings
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DRY_RUN=false
AGGRESSIVE=false
PRUNE_REMOTE=true

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 0
}

log_info()  { echo -e "${BLUE}ℹ️  $*${NC}"; }
log_ok()    { echo -e "${GREEN}✅ $*${NC}"; }
log_warn()  { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error() { echo -e "${RED}❌ $*${NC}"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run)    DRY_RUN=true; shift ;;
        -a|--aggressive) AGGRESSIVE=true; shift ;;
        -r|--remote)     PRUNE_REMOTE=true; shift ;;
        -h|--help)       usage ;;
        *)               log_error "Unknown option: $1"; usage ;;
    esac
done

# Verify we're in a git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not inside a Git repository"
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
echo "==========================================="
echo "  Git Repository Cleanup"
echo "  Repo: $REPO_ROOT"
echo "==========================================="
echo ""

if $DRY_RUN; then
    log_warn "DRY RUN MODE — no changes will be made"
    echo ""
fi

# Record initial size
SIZE_BEFORE=$(du -sk "$REPO_ROOT/.git" 2>/dev/null | awk '{print $1}')

# Detect default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "")
if [ -z "$DEFAULT_BRANCH" ]; then
    for branch in main master; do
        if git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            DEFAULT_BRANCH="$branch"
            break
        fi
    done
fi
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
log_info "Default branch: $DEFAULT_BRANCH"
echo ""

# --- Step 1: Prune stale remote-tracking branches ---
echo "━━━ Step 1: Prune stale remote-tracking branches ━━━"
if $PRUNE_REMOTE; then
    STALE_BRANCHES=$(git remote prune origin --dry-run 2>/dev/null | grep '\[would prune\]' || true)
    if [ -n "$STALE_BRANCHES" ]; then
        echo "$STALE_BRANCHES" | while read -r line; do
            echo "  🗑️  $line"
        done
        STALE_COUNT=$(echo "$STALE_BRANCHES" | wc -l | tr -d ' ')
        if ! $DRY_RUN; then
            git remote prune origin
            log_ok "Pruned $STALE_COUNT stale remote branches"
        else
            log_warn "Would prune $STALE_COUNT stale remote branches"
        fi
    else
        log_ok "No stale remote branches found"
    fi
else
    log_info "Skipping remote prune (use -r to enable)"
fi
echo ""

# --- Step 2: Remove merged local branches ---
echo "━━━ Step 2: Remove merged local branches ━━━"
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
MERGED_BRANCHES=$(git branch --merged "$DEFAULT_BRANCH" 2>/dev/null \
    | grep -vE "^\*|^\s+(${DEFAULT_BRANCH}|main|master|develop|release)" \
    | sed 's/^[[:space:]]*//' || true)

if [ -n "$MERGED_BRANCHES" ]; then
    MERGED_COUNT=0
    echo "$MERGED_BRANCHES" | while read -r branch; do
        if [ -n "$branch" ]; then
            echo "  🗑️  $branch (merged into $DEFAULT_BRANCH)"
        fi
    done
    MERGED_COUNT=$(echo "$MERGED_BRANCHES" | grep -c . || echo "0")
    if ! $DRY_RUN; then
        echo "$MERGED_BRANCHES" | while read -r branch; do
            if [ -n "$branch" ]; then
                git branch -d "$branch" 2>/dev/null || true
            fi
        done
        log_ok "Removed $MERGED_COUNT merged branches"
    else
        log_warn "Would remove $MERGED_COUNT merged branches"
    fi
else
    log_ok "No merged branches to clean up"
fi
echo ""

# --- Step 3: Clean up unreachable objects ---
echo "━━━ Step 3: Garbage collection and prune ━━━"
if ! $DRY_RUN; then
    if $AGGRESSIVE; then
        log_info "Running aggressive gc (this may take a while)..."
        git gc --aggressive --prune=now 2>&1 | tail -3
    else
        log_info "Running gc..."
        git gc --prune=now 2>&1 | tail -3
    fi
    git prune --expire=now 2>/dev/null || true
    log_ok "Garbage collection complete"
else
    if $AGGRESSIVE; then
        log_warn "Would run: git gc --aggressive --prune=now"
    else
        log_warn "Would run: git gc --prune=now"
    fi
fi
echo ""

# --- Step 4: Additional cleanup ---
echo "━━━ Step 4: Additional cleanup ━━━"
if ! $DRY_RUN; then
    # Remove stale worktree references
    git worktree prune 2>/dev/null && log_ok "Pruned stale worktrees" || true

    # Remove empty reflog entries
    git reflog expire --expire=90.days --all 2>/dev/null && log_ok "Expired old reflog entries" || true
else
    log_warn "Would prune stale worktrees and expire old reflog entries"
fi
echo ""

# --- Report ---
echo "==========================================="
echo "  Summary"
echo "==========================================="

SIZE_AFTER=$(du -sk "$REPO_ROOT/.git" 2>/dev/null | awk '{print $1}')
if [ -n "$SIZE_BEFORE" ] && [ -n "$SIZE_AFTER" ]; then
    SAVED=$((SIZE_BEFORE - SIZE_AFTER))
    SIZE_BEFORE_H=$(du -sh "$REPO_ROOT/.git" 2>/dev/null | awk '{print $1}')

    if [ $SAVED -gt 0 ]; then
        echo -e "  .git before:  ${YELLOW}$(echo "$SIZE_BEFORE" | awk '{printf "%.1f MB", $1/1024}')${NC}"
        echo -e "  .git after:   ${GREEN}$(echo "$SIZE_AFTER" | awk '{printf "%.1f MB", $1/1024}')${NC}"
        echo -e "  Space saved:  ${GREEN}$(echo "$SAVED" | awk '{printf "%.1f MB", $1/1024}')${NC}"
    else
        echo -e "  .git size:    ${GREEN}$(echo "$SIZE_AFTER" | awk '{printf "%.1f MB", $1/1024}')${NC}"
        echo -e "  Space saved:  ${YELLOW}none (already optimized)${NC}"
    fi
fi

echo ""
if $DRY_RUN; then
    log_warn "Dry run complete. Run without -n to apply changes."
fi
