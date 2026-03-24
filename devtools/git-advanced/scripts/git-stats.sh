#!/usr/bin/env bash
# =============================================================================
# git-stats.sh — Git Repository Statistics
# =============================================================================
#
# Usage: ./git-stats.sh [OPTIONS]
#
# Options:
#   -n, --top <N>     Number of top entries to show (default: 10)
#   -s, --section <S> Only show specific section:
#                       contributors, churn, frequency, files, branches, all
#   -b, --branch <B>  Analyze specific branch (default: current branch)
#   -h, --help        Show this help message
#
# Sections:
#   contributors  — Top contributors by commits, insertions, deletions
#   churn         — Most frequently changed files
#   frequency     — Commit frequency by day/hour/month
#   files         — Largest files in the repository
#   branches      — Branch age and commit counts
#   all           — Show all sections (default)
#
# Examples:
#   ./git-stats.sh
#   ./git-stats.sh -n 20 -s contributors
#   ./git-stats.sh --section churn --branch main
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

TOP_N=10
SECTION="all"
BRANCH=""

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \?//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--top)     TOP_N="$2"; shift 2 ;;
        -s|--section) SECTION="$2"; shift 2 ;;
        -b|--branch)  BRANCH="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

# Verify we're in a git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "❌ Not inside a Git repository"
    exit 1
fi

BRANCH=${BRANCH:-$(git symbolic-ref --short HEAD 2>/dev/null || echo "HEAD")}

header() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ──── Repository Overview ────
show_overview() {
    header "📊 Repository Overview"

    REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
    TOTAL_COMMITS=$(git rev-list --count "$BRANCH" 2>/dev/null || echo "0")
    TOTAL_AUTHORS=$(git log --format='%aN' "$BRANCH" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    TOTAL_FILES=$(git ls-files | wc -l | tr -d ' ')
    FIRST_COMMIT=$(git log --reverse --format='%ai' "$BRANCH" 2>/dev/null | head -1 | cut -d' ' -f1)
    LAST_COMMIT=$(git log -1 --format='%ai' "$BRANCH" 2>/dev/null | cut -d' ' -f1)
    REPO_SIZE=$(du -sh "$(git rev-parse --git-dir)" 2>/dev/null | awk '{print $1}')
    TOTAL_BRANCHES=$(git branch -a 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_TAGS=$(git tag 2>/dev/null | wc -l | tr -d ' ')

    echo ""
    echo -e "  Repository:    ${CYAN}$REPO_NAME${NC}"
    echo -e "  Branch:        ${CYAN}$BRANCH${NC}"
    echo -e "  Total commits: ${GREEN}$TOTAL_COMMITS${NC}"
    echo -e "  Contributors:  ${GREEN}$TOTAL_AUTHORS${NC}"
    echo -e "  Tracked files: ${GREEN}$TOTAL_FILES${NC}"
    echo -e "  Branches:      ${GREEN}$TOTAL_BRANCHES${NC}"
    echo -e "  Tags:          ${GREEN}$TOTAL_TAGS${NC}"
    echo -e "  .git size:     ${YELLOW}$REPO_SIZE${NC}"
    echo -e "  First commit:  ${DIM}$FIRST_COMMIT${NC}"
    echo -e "  Latest commit: ${DIM}$LAST_COMMIT${NC}"
}

# ──── Contributor Stats ────
show_contributors() {
    header "👥 Top Contributors (by commits)"

    echo ""
    printf "  ${DIM}%-4s %-30s %8s %10s %10s${NC}\n" "#" "Author" "Commits" "++Lines" "--Lines"
    echo -e "  ${DIM}──── ────────────────────────────── ──────── ────────── ──────────${NC}"

    git log --format='%aN' "$BRANCH" 2>/dev/null \
        | sort \
        | uniq -c \
        | sort -rn \
        | head -"$TOP_N" \
        | while read -r count author; do
            # Get insertions/deletions for this author
            stats=$(git log --author="$author" --pretty=tformat: --numstat "$BRANCH" 2>/dev/null \
                | awk '{ ins += $1; del += $2 } END { printf "%d %d", ins, del }')
            ins=$(echo "$stats" | awk '{print $1}')
            del=$(echo "$stats" | awk '{print $2}')
            RANK=$((${RANK:-0} + 1))
            printf "  %-4s %-30s %8s %10s %10s\n" "$RANK." "$author" "$count" "+$ins" "-$del"
        done

    echo ""
    echo -e "  ${DIM}Top contributors by lines changed:${NC}"
    git log --format='%aN' --numstat "$BRANCH" 2>/dev/null \
        | awk 'NF==1 { author=$0 } NF==3 { ins[author]+=$1; del[author]+=$2 } END { for(a in ins) printf "  %-30s %+10d lines\n", a, ins[a]-del[a] }' \
        | sort -t'+' -k2 -rn \
        | head -"$TOP_N"
}

# ──── File Churn Analysis ────
show_churn() {
    header "🔄 File Churn (most frequently changed files)"

    echo ""
    printf "  ${DIM}%-4s %-60s %8s${NC}\n" "#" "File" "Changes"
    echo -e "  ${DIM}──── ──────────────────────────────────────────────────────────── ────────${NC}"

    git log --name-only --pretty=format: "$BRANCH" 2>/dev/null \
        | grep -v '^$' \
        | sort \
        | uniq -c \
        | sort -rn \
        | head -"$TOP_N" \
        | awk '{ printf "  %-4d %-60s %8d\n", NR, $2, $1 }'

    echo ""
    echo -e "  ${DIM}Files with most insertions + deletions:${NC}"
    git log --numstat --pretty=format: "$BRANCH" 2>/dev/null \
        | grep -v '^$' \
        | awk '{ ins[$3]+=$1; del[$3]+=$2 } END { for(f in ins) printf "  %-60s +%-8d -%-8d\n", f, ins[f], del[f] }' \
        | sort -t'+' -k2 -rn \
        | head -"$TOP_N"
}

# ──── Commit Frequency ────
show_frequency() {
    header "📅 Commit Frequency"

    echo ""
    echo -e "  ${BOLD}By day of week:${NC}"
    git log --format='%ad' --date=format:'%A' "$BRANCH" 2>/dev/null \
        | sort \
        | uniq -c \
        | sort -rn \
        | while read -r count day; do
            BAR=$(printf '█%.0s' $(seq 1 $((count / ($(git rev-list --count "$BRANCH" 2>/dev/null) / 50 + 1) + 1))))
            printf "  %-12s %5d  %s\n" "$day" "$count" "$BAR"
        done

    echo ""
    echo -e "  ${BOLD}By hour of day:${NC}"
    git log --format='%ad' --date=format:'%H' "$BRANCH" 2>/dev/null \
        | sort \
        | uniq -c \
        | sort -k2 -n \
        | while read -r count hour; do
            BAR=$(printf '█%.0s' $(seq 1 $((count / ($(git rev-list --count "$BRANCH" 2>/dev/null) / 100 + 1) + 1))))
            printf "  %s:00  %5d  %s\n" "$hour" "$count" "$BAR"
        done

    echo ""
    echo -e "  ${BOLD}Commits per month (last 12):${NC}"
    for i in $(seq 11 -1 0); do
        MONTH=$(date -d "$i months ago" '+%Y-%m' 2>/dev/null || date -v-"${i}m" '+%Y-%m' 2>/dev/null || continue)
        COUNT=$(git log --after="${MONTH}-01" --before="$(date -d "$((i-1)) months ago" '+%Y-%m-01' 2>/dev/null || date -v-"$((i-1))m" '+%Y-%m-01' 2>/dev/null || echo "$MONTH-32")" --oneline "$BRANCH" 2>/dev/null | wc -l | tr -d ' ')
        BAR=$(printf '█%.0s' $(seq 1 $((COUNT + 1))) 2>/dev/null || echo "")
        printf "  %s  %5d  %s\n" "$MONTH" "$COUNT" "$BAR"
    done
}

# ──── Largest Files ────
show_files() {
    header "📦 Largest Files in Repository"

    echo ""
    echo -e "  ${BOLD}Largest tracked files (current tree):${NC}"
    printf "  ${DIM}%-4s %-60s %10s${NC}\n" "#" "File" "Size"
    echo -e "  ${DIM}──── ──────────────────────────────────────────────────────────── ──────────${NC}"

    git ls-files -z 2>/dev/null \
        | xargs -0 -I{} sh -c 'if [ -f "{}" ]; then wc -c < "{}" | tr -d " " | xargs -I@ echo "@ {}"; fi' 2>/dev/null \
        | sort -rn \
        | head -"$TOP_N" \
        | awk '{
            size=$1;
            file=$2;
            if (size >= 1048576) printf "  %-4d %-60s %7.1f MB\n", NR, file, size/1048576;
            else if (size >= 1024) printf "  %-4d %-60s %7.1f KB\n", NR, file, size/1024;
            else printf "  %-4d %-60s %7d B\n", NR, file, size;
        }'

    echo ""
    echo -e "  ${BOLD}Largest objects in Git history:${NC}"
    git rev-list --objects --all 2>/dev/null \
        | git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' 2>/dev/null \
        | awk '/^blob/ {print $2, $3}' \
        | sort -rn \
        | head -"$TOP_N" \
        | awk '{
            size=$1;
            file=$2;
            if (size >= 1048576) printf "  %-60s %7.1f MB\n", file, size/1048576;
            else if (size >= 1024) printf "  %-60s %7.1f KB\n", file, size/1024;
            else printf "  %-60s %7d B\n", file, size;
        }'

    echo ""
    echo -e "  ${BOLD}File type distribution:${NC}"
    git ls-files 2>/dev/null \
        | sed 's/.*\.//' \
        | sort \
        | uniq -c \
        | sort -rn \
        | head -"$TOP_N" \
        | awk '{ printf "  .%-15s %6d files\n", $2, $1 }'
}

# ──── Branch Age ────
show_branches() {
    header "🌿 Branch Information"

    echo ""
    printf "  ${DIM}%-30s %-12s %-8s %s${NC}\n" "Branch" "Last Commit" "Ahead" "Behind"
    echo -e "  ${DIM}────────────────────────────── ──────────── ──────── ────────${NC}"

    DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")

    git branch --format='%(refname:short)' 2>/dev/null | while read -r branch; do
        LAST_DATE=$(git log -1 --format='%ar' "$branch" 2>/dev/null || echo "unknown")
        if [ "$branch" != "$DEFAULT" ]; then
            AHEAD=$(git rev-list --count "$DEFAULT..$branch" 2>/dev/null || echo "?")
            BEHIND=$(git rev-list --count "$branch..$DEFAULT" 2>/dev/null || echo "?")
        else
            AHEAD="-"
            BEHIND="-"
        fi
        printf "  %-30s %-12s %-8s %s\n" "$branch" "$LAST_DATE" "$AHEAD" "$BEHIND"
    done

    echo ""
    echo -e "  ${BOLD}Stale branches (>30 days, no recent commits):${NC}"
    STALE_COUNT=0
    git branch --format='%(refname:short)' 2>/dev/null | while read -r branch; do
        LAST_EPOCH=$(git log -1 --format='%at' "$branch" 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        AGE_DAYS=$(( (NOW_EPOCH - LAST_EPOCH) / 86400 ))
        if [ "$AGE_DAYS" -gt 30 ] && [ "$branch" != "$DEFAULT" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
            echo -e "  ${YELLOW}⚠️  $branch${NC} — last commit $AGE_DAYS days ago"
        fi
    done
}

# ──── Main ────
echo ""
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}  Git Repository Statistics${NC}"
echo -e "${BOLD}==========================================${NC}"

show_overview

case "$SECTION" in
    contributors) show_contributors ;;
    churn)        show_churn ;;
    frequency)    show_frequency ;;
    files)        show_files ;;
    branches)     show_branches ;;
    all)
        show_contributors
        show_churn
        show_frequency
        show_files
        show_branches
        ;;
    *)
        echo "Unknown section: $SECTION"
        echo "Valid sections: contributors, churn, frequency, files, branches, all"
        exit 1
        ;;
esac

echo ""
echo -e "${DIM}Generated on $(date '+%Y-%m-%d %H:%M:%S') for branch: $BRANCH${NC}"
