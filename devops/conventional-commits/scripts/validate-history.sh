#!/usr/bin/env bash
#
# validate-history.sh — Check git history for conventional commit compliance
#
# Usage:
#   ./validate-history.sh                    # Check all commits on current branch
#   ./validate-history.sh --from HEAD~10     # Check last 10 commits
#   ./validate-history.sh --from v1.0.0      # Check commits since tag v1.0.0
#   ./validate-history.sh --from main        # Check commits not on main
#   ./validate-history.sh --from abc123 --to def456   # Check a range
#   ./validate-history.sh --strict           # Treat warnings as errors
#   ./validate-history.sh --json             # Output results as JSON
#   ./validate-history.sh --summary          # Summary only (no per-commit detail)
#
# What it does:
#   - Iterates over git commits in the specified range
#   - Validates each commit message against conventional commit format
#   - Reports violations with commit SHA, author, and reason
#   - Prints a summary with compliance percentage
#
# Exit codes:
#   0 — All commits are compliant
#   1 — One or more violations found

set -euo pipefail

# --- Defaults ---
FROM=""
TO="HEAD"
STRICT=false
JSON_OUTPUT=false
SUMMARY_ONLY=false

# --- Conventional commit regex ---
# Matches: type(scope)!: description
CC_REGEX='^(revert: )?(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|hotfix|security|deps|i18n|a11y|dx|infra|data)(\([a-zA-Z0-9_./-]+\))?(!)?: .+'

# Merge/auto-generated patterns to skip
SKIP_REGEX='^(Merge (branch|pull request|remote-tracking)|Revert "|Initial commit$|Auto-merge)'

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)     FROM="$2"; shift 2 ;;
    --to)       TO="$2"; shift 2 ;;
    --strict)   STRICT=true; shift ;;
    --json)     JSON_OUTPUT=true; shift ;;
    --summary)  SUMMARY_ONLY=true; shift ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Ensure we're in a git repo ---
git rev-parse --git-dir &>/dev/null || { echo "Error: not a git repository" >&2; exit 1; }

# --- Build git log range ---
if [[ -n "$FROM" ]]; then
  RANGE="${FROM}..${TO}"
else
  RANGE="$TO"
fi

# --- Collect commits ---
COMMITS=$(git log "$RANGE" --pretty=format:"%H|%an|%s" --no-merges 2>/dev/null) || {
  echo "Error: invalid range '$RANGE'" >&2
  exit 1
}

if [[ -z "$COMMITS" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    echo '{"total":0,"compliant":0,"violations":0,"skipped":0,"compliance_pct":100,"details":[]}'
  else
    echo "No commits found in range."
  fi
  exit 0
fi

# --- Analyze ---
TOTAL=0
COMPLIANT=0
VIOLATIONS=0
SKIPPED=0
VIOLATION_LIST=()

while IFS='|' read -r sha author subject; do
  TOTAL=$((TOTAL + 1))

  # Skip merge/auto commits
  if echo "$subject" | grep -qE "$SKIP_REGEX"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Check conventional commit format
  if echo "$subject" | grep -qE "$CC_REGEX"; then
    COMPLIANT=$((COMPLIANT + 1))
  else
    VIOLATIONS=$((VIOLATIONS + 1))
    SHORT_SHA="${sha:0:7}"

    # Determine specific violation reason
    REASON=""
    if ! echo "$subject" | grep -qE '^[a-z]+'; then
      REASON="does not start with a lowercase type"
    elif ! echo "$subject" | grep -qE '^[a-z]+(\([^)]*\))?(!)?: '; then
      REASON="missing colon-space separator after type/scope"
    elif echo "$subject" | grep -qE '^[a-z]+(\([^)]*\))?(!)?: $'; then
      REASON="empty description after type"
    else
      REASON="type not in allowed list or invalid format"
    fi

    VIOLATION_LIST+=("${SHORT_SHA}|${author}|${subject}|${REASON}")
  fi
done <<< "$COMMITS"

# --- Calculate compliance ---
CHECKED=$((TOTAL - SKIPPED))
if [[ $CHECKED -gt 0 ]]; then
  COMPLIANCE_PCT=$((COMPLIANT * 100 / CHECKED))
else
  COMPLIANCE_PCT=100
fi

# --- Output: JSON ---
if [[ "$JSON_OUTPUT" == true ]]; then
  echo "{"
  echo "  \"total\": $TOTAL,"
  echo "  \"compliant\": $COMPLIANT,"
  echo "  \"violations\": $VIOLATIONS,"
  echo "  \"skipped\": $SKIPPED,"
  echo "  \"compliance_pct\": $COMPLIANCE_PCT,"
  echo "  \"details\": ["
  for i in "${!VIOLATION_LIST[@]}"; do
    IFS='|' read -r sha author subject reason <<< "${VIOLATION_LIST[$i]}"
    COMMA=""
    [[ $i -lt $((${#VIOLATION_LIST[@]} - 1)) ]] && COMMA=","
    # Escape quotes in subject
    subject="${subject//\"/\\\"}"
    echo "    {\"sha\": \"$sha\", \"author\": \"$author\", \"subject\": \"$subject\", \"reason\": \"$reason\"}${COMMA}"
  done
  echo "  ]"
  echo "}"
  [[ $VIOLATIONS -eq 0 ]] && exit 0 || exit 1
fi

# --- Output: Text ---
echo ""
echo "━━━ Conventional Commits — History Validation ━━━"
echo ""
echo "  Range:      ${FROM:-'(all)'}..${TO}"
echo "  Total:      $TOTAL commits"
echo "  Checked:    $CHECKED (skipped $SKIPPED merge/auto)"
echo "  Compliant:  $COMPLIANT"
echo "  Violations: $VIOLATIONS"
echo ""

if [[ $COMPLIANCE_PCT -ge 90 ]]; then
  echo -e "  Compliance: ${GREEN}${COMPLIANCE_PCT}%${NC}"
elif [[ $COMPLIANCE_PCT -ge 70 ]]; then
  echo -e "  Compliance: ${YELLOW}${COMPLIANCE_PCT}%${NC}"
else
  echo -e "  Compliance: ${RED}${COMPLIANCE_PCT}%${NC}"
fi
echo ""

# --- Violation details ---
if [[ $VIOLATIONS -gt 0 ]] && [[ "$SUMMARY_ONLY" == false ]]; then
  echo "━━━ Violations ━━━"
  echo ""
  for entry in "${VIOLATION_LIST[@]}"; do
    IFS='|' read -r sha author subject reason <<< "$entry"
    echo -e "  ${RED}✖${NC} ${CYAN}${sha}${NC} ${DIM}(${author})${NC}"
    echo -e "    ${subject}"
    echo -e "    ${YELLOW}→ ${reason}${NC}"
    echo ""
  done
fi

# --- Exit code ---
if [[ $VIOLATIONS -eq 0 ]]; then
  echo -e "${GREEN}All commits are compliant.${NC}"
  exit 0
else
  echo -e "${RED}${VIOLATIONS} violation(s) found.${NC}"
  if [[ "$STRICT" == true ]]; then
    exit 1
  else
    # Non-strict: warn but don't fail
    exit 1
  fi
fi
