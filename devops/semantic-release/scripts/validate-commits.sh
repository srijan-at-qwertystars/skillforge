#!/usr/bin/env bash
#
# validate-commits.sh — Check if recent commits follow Conventional Commits format
#
# Usage:
#   ./validate-commits.sh              # Check commits since last tag
#   ./validate-commits.sh -n 10        # Check last 10 commits
#   ./validate-commits.sh --since HEAD~5  # Check last 5 commits
#   ./validate-commits.sh --range v1.0.0..HEAD  # Check specific range
#   ./validate-commits.sh --strict     # Fail on warnings (scope required, etc.)
#   ./validate-commits.sh --fix-hints  # Show how to fix invalid commits
#
# Exit codes:
#   0 — All commits valid
#   1 — Invalid commits found
#   2 — Error (not a git repo, etc.)

set -euo pipefail

# --- Defaults ---
COUNT=""
SINCE=""
RANGE=""
STRICT=false
FIX_HINTS=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

# --- Valid types (Conventional Commits) ---
VALID_TYPES="feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--count)    COUNT="$2"; shift 2 ;;
    --since)       SINCE="$2"; shift 2 ;;
    --range)       RANGE="$2"; shift 2 ;;
    --strict)      STRICT=true; shift ;;
    --fix-hints)   FIX_HINTS=true; shift ;;
    -h|--help)
      head -18 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- Preflight ---
if [[ ! -d .git ]]; then
  echo -e "${RED}Error: Not a git repository${NC}" >&2
  exit 2
fi

# --- Determine commit range ---
if [[ -n "$RANGE" ]]; then
  GIT_LOG_ARGS=("$RANGE")
elif [[ -n "$SINCE" ]]; then
  GIT_LOG_ARGS=("${SINCE}..HEAD")
elif [[ -n "$COUNT" ]]; then
  GIT_LOG_ARGS=("-n" "$COUNT")
else
  # Default: since last tag, or last 20 commits if no tags
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [[ -n "$LAST_TAG" ]]; then
    GIT_LOG_ARGS=("${LAST_TAG}..HEAD")
    echo -e "${BLUE}Checking commits since ${LAST_TAG}${NC}"
  else
    GIT_LOG_ARGS=("-n" "20")
    echo -e "${BLUE}No tags found. Checking last 20 commits${NC}"
  fi
fi

echo ""

# --- Regex for Conventional Commits ---
# Format: type(scope)!: subject
CONVENTIONAL_REGEX="^(${VALID_TYPES})(\([a-zA-Z0-9_./ -]+\))?(!)?: .+"
# Merge commits and [skip ci] are allowed
MERGE_REGEX="^Merge (branch|pull request|remote)"
SKIP_REGEX="^(chore\(release\)|Revert \"|Release )"

# --- Validate ---
TOTAL=0
VALID=0
INVALID=0
WARNINGS=0
INVALID_COMMITS=()
WARNING_COMMITS=()

while IFS= read -r line; do
  # Split hash and message
  HASH="${line%% *}"
  MSG="${line#* }"
  SHORT_HASH="${HASH:0:7}"
  TOTAL=$((TOTAL + 1))

  # Skip merge commits
  if [[ "$MSG" =~ $MERGE_REGEX ]]; then
    VALID=$((VALID + 1))
    continue
  fi

  # Skip release/revert commits
  if [[ "$MSG" =~ $SKIP_REGEX ]]; then
    VALID=$((VALID + 1))
    continue
  fi

  # Check conventional commit format
  if [[ "$MSG" =~ $CONVENTIONAL_REGEX ]]; then
    TYPE="${BASH_REMATCH[1]}"
    SCOPE="${BASH_REMATCH[2]}"
    BREAKING="${BASH_REMATCH[3]}"

    # Strict mode checks
    if $STRICT; then
      if [[ -z "$SCOPE" ]]; then
        WARNINGS=$((WARNINGS + 1))
        WARNING_COMMITS+=("  ${YELLOW}⚠${NC}  ${DIM}${SHORT_HASH}${NC} ${MSG}  ${YELLOW}(missing scope)${NC}")
      fi

      # Check subject length
      SUBJECT="${MSG#*: }"
      if [[ ${#SUBJECT} -gt 72 ]]; then
        WARNINGS=$((WARNINGS + 1))
        WARNING_COMMITS+=("  ${YELLOW}⚠${NC}  ${DIM}${SHORT_HASH}${NC} ${MSG}  ${YELLOW}(subject > 72 chars)${NC}")
      fi
    fi

    VALID=$((VALID + 1))
  else
    INVALID=$((INVALID + 1))
    INVALID_COMMITS+=("$SHORT_HASH" "$MSG")
  fi
done < <(git log --format="%H %s" "${GIT_LOG_ARGS[@]}" 2>/dev/null)

if [[ $TOTAL -eq 0 ]]; then
  echo -e "${YELLOW}No commits found in the specified range${NC}"
  exit 0
fi

# --- Report valid commits ---
echo -e "${GREEN}Valid:${NC}   $VALID / $TOTAL commits"

# --- Report warnings ---
if [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}Warnings:${NC} $WARNINGS"
  for w in "${WARNING_COMMITS[@]}"; do
    echo -e "$w"
  done
  echo ""
fi

# --- Report invalid commits ---
if [[ $INVALID -gt 0 ]]; then
  echo -e "${RED}Invalid:${NC} $INVALID commits"
  echo ""

  for ((i = 0; i < ${#INVALID_COMMITS[@]}; i += 2)); do
    hash="${INVALID_COMMITS[$i]}"
    msg="${INVALID_COMMITS[$((i + 1))]}"
    echo -e "  ${RED}✗${NC}  ${DIM}${hash}${NC} ${msg}"

    if $FIX_HINTS; then
      # Try to suggest a fix
      if [[ "$msg" =~ ^[Aa]dd ]]; then
        echo -e "     ${BLUE}→ Suggested: feat: ${msg,,}${NC}"
      elif [[ "$msg" =~ ^[Ff]ix ]]; then
        echo -e "     ${BLUE}→ Suggested: fix: ${msg}${NC}"
      elif [[ "$msg" =~ ^[Uu]pdate ]]; then
        echo -e "     ${BLUE}→ Suggested: chore: ${msg,,}${NC}"
      elif [[ "$msg" =~ ^[Rr]emove ]]; then
        echo -e "     ${BLUE}→ Suggested: refactor: ${msg,,}${NC}"
      else
        echo -e "     ${BLUE}→ Format: <type>(<scope>): <description>${NC}"
        echo -e "     ${BLUE}  Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert${NC}"
      fi
    fi
  done

  echo ""

  # Summary
  if $FIX_HINTS; then
    echo -e "${BLUE}To amend the last commit message:${NC}"
    echo "  git commit --amend -m \"feat(scope): your description\""
    echo ""
    echo -e "${BLUE}To rewrite multiple commits (interactive rebase):${NC}"
    echo "  git rebase -i HEAD~${INVALID}"
    echo "  # Change 'pick' to 'reword' for commits to fix"
    echo ""
  fi

  if $STRICT && [[ $WARNINGS -gt 0 ]]; then
    echo -e "${RED}FAILED${NC} — $INVALID invalid commits and $WARNINGS warnings (strict mode)"
    exit 1
  fi

  echo -e "${RED}FAILED${NC} — $INVALID commit(s) do not follow Conventional Commits format"
  exit 1
fi

# --- Strict mode: fail on warnings ---
if $STRICT && [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}FAILED (strict)${NC} — $WARNINGS warnings found"
  exit 1
fi

# --- All good ---
echo ""
echo -e "${GREEN}PASSED${NC} — All $TOTAL commits follow Conventional Commits format ✓"

# Show version bump preview
FEAT_COUNT=$(git log --format="%s" "${GIT_LOG_ARGS[@]}" 2>/dev/null | grep -c "^feat" || true)
FIX_COUNT=$(git log --format="%s" "${GIT_LOG_ARGS[@]}" 2>/dev/null | grep -c "^fix" || true)
BREAKING_COUNT=$(git log --format="%B" "${GIT_LOG_ARGS[@]}" 2>/dev/null | grep -c "BREAKING CHANGE\|^[a-z]\+!:" || true)

echo ""
echo -e "${BLUE}Version bump preview:${NC}"
echo "  Features (minor): $FEAT_COUNT"
echo "  Fixes (patch):    $FIX_COUNT"
echo "  Breaking (major): $BREAKING_COUNT"

if [[ $BREAKING_COUNT -gt 0 ]]; then
  echo -e "  ${YELLOW}→ Next release: MAJOR${NC}"
elif [[ $FEAT_COUNT -gt 0 ]]; then
  echo -e "  ${GREEN}→ Next release: MINOR${NC}"
elif [[ $FIX_COUNT -gt 0 ]]; then
  echo -e "  ${GREEN}→ Next release: PATCH${NC}"
else
  echo -e "  ${DIM}→ No release-triggering commits${NC}"
fi

exit 0
