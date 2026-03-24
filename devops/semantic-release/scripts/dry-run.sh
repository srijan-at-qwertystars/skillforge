#!/usr/bin/env bash
#
# dry-run.sh — Run semantic-release dry-run with enhanced output
#
# Usage:
#   ./dry-run.sh                    # Standard dry-run
#   ./dry-run.sh --debug            # With full debug output
#   ./dry-run.sh --plugin <name>    # Debug specific plugin only
#   ./dry-run.sh --json             # Output results as JSON
#   ./dry-run.sh --branch next      # Simulate release from specific branch
#
# Prerequisites:
#   - GITHUB_TOKEN or GITLAB_TOKEN set (or gh CLI authenticated)
#   - Inside a Git repository with semantic-release configured
#   - npm dependencies installed (npm ci)
#
# What this shows:
#   - Current version (from last tag)
#   - Commits that will be analyzed
#   - Calculated next version and release type
#   - What each plugin would do
#   - Generated release notes preview

set -euo pipefail

# --- Defaults ---
DEBUG_MODE=false
DEBUG_PLUGIN=""
JSON_OUTPUT=false
BRANCH=""
EXTRA_ARGS=()

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)     DEBUG_MODE=true; shift ;;
    --plugin)    DEBUG_PLUGIN="$2"; shift 2 ;;
    --json)      JSON_OUTPUT=true; shift ;;
    --branch)    BRANCH="$2"; shift 2 ;;
    -h|--help)
      head -22 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# --- Preflight ---
if [[ ! -d .git ]]; then
  echo -e "${RED}Error: Not a Git repository${NC}" >&2
  exit 1
fi

if [[ ! -f package.json ]]; then
  echo -e "${RED}Error: No package.json found${NC}" >&2
  exit 1
fi

# Check for semantic-release
if ! npx --no -- semantic-release --version &>/dev/null 2>&1; then
  echo -e "${RED}Error: semantic-release not found. Run 'npm install --save-dev semantic-release'${NC}" >&2
  exit 1
fi

# --- Token setup ---
if [[ -z "${GITHUB_TOKEN:-}" && -z "${GITLAB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
  # Try to get token from gh CLI
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(gh auth token)
    echo -e "${DIM}Using GITHUB_TOKEN from gh CLI${NC}"
  else
    echo -e "${YELLOW}Warning: No GITHUB_TOKEN or GITLAB_TOKEN set.${NC}"
    echo -e "${YELLOW}Some verification steps may fail.${NC}"
    echo -e "${DIM}Tip: Install gh CLI and run 'gh auth login', or export GITHUB_TOKEN${NC}"
    echo ""
  fi
fi

# Ensure CI env is set for local runs
export CI="${CI:-true}"

# --- Pre-run info ---
if ! $JSON_OUTPUT; then
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  semantic-release Dry Run${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo ""

  # Current state
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "none")
  COMMIT_COUNT=0
  if [[ "$LAST_TAG" != "none" ]]; then
    COMMIT_COUNT=$(git rev-list "${LAST_TAG}..HEAD" --count 2>/dev/null || echo "0")
  else
    COMMIT_COUNT=$(git rev-list HEAD --count 2>/dev/null || echo "0")
  fi

  echo -e "${CYAN}Current state:${NC}"
  echo -e "  Branch:        ${BOLD}${CURRENT_BRANCH}${NC}"
  echo -e "  Last tag:      ${BOLD}${LAST_TAG}${NC}"
  echo -e "  Commits since: ${BOLD}${COMMIT_COUNT}${NC}"
  echo ""

  # Show commits that will be analyzed
  if [[ "$LAST_TAG" != "none" && $COMMIT_COUNT -gt 0 ]]; then
    echo -e "${CYAN}Commits to analyze:${NC}"
    git log "${LAST_TAG}..HEAD" --format="  %C(dim)%h%C(reset) %s" 2>/dev/null | head -20
    if [[ $COMMIT_COUNT -gt 20 ]]; then
      echo -e "  ${DIM}... and $((COMMIT_COUNT - 20)) more${NC}"
    fi
    echo ""
  elif [[ "$LAST_TAG" == "none" ]]; then
    echo -e "${CYAN}Commits to analyze:${NC}"
    git log --format="  %C(dim)%h%C(reset) %s" -20 2>/dev/null
    echo ""
  fi

  # Config detection
  echo -e "${CYAN}Configuration:${NC}"
  for f in .releaserc .releaserc.json .releaserc.yml .releaserc.yaml release.config.js release.config.cjs release.config.mjs; do
    if [[ -f "$f" ]]; then
      echo -e "  Config file:   ${BOLD}$f${NC}"
      break
    fi
  done

  # Check for release key in package.json
  if node -e "const p = require('./package.json'); if (p.release) process.exit(0); else process.exit(1);" 2>/dev/null; then
    echo -e "  Config file:   ${BOLD}package.json (release key)${NC}"
  fi
  echo ""

  echo -e "${CYAN}Running dry-run...${NC}"
  echo -e "${DIM}────────────────────────────────────────────────${NC}"
fi

# --- Build command ---
CMD=("npx" "semantic-release" "--dry-run")

# Add --no-ci for local runs
CMD+=("--no-ci")

# Branch override
if [[ -n "$BRANCH" ]]; then
  CMD+=("--branches" "$BRANCH")
fi

# Extra args
CMD+=("${EXTRA_ARGS[@]}")

# Debug env
DEBUG_ENV=""
if $DEBUG_MODE; then
  DEBUG_ENV="semantic-release:*"
elif [[ -n "$DEBUG_PLUGIN" ]]; then
  DEBUG_ENV="semantic-release:${DEBUG_PLUGIN}"
fi

# --- Execute ---
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

EXIT_CODE=0
if [[ -n "$DEBUG_ENV" ]]; then
  DEBUG="$DEBUG_ENV" "${CMD[@]}" 2>&1 | tee "$TMPFILE" || EXIT_CODE=$?
else
  "${CMD[@]}" 2>&1 | tee "$TMPFILE" || EXIT_CODE=$?
fi

# --- Post-run analysis ---
if ! $JSON_OUTPUT; then
  echo ""
  echo -e "${DIM}────────────────────────────────────────────────${NC}"
  echo ""

  OUTPUT=$(cat "$TMPFILE")

  # Extract key info from output
  NEXT_VERSION=$(echo "$OUTPUT" | grep -oP "next release version is \K[0-9]+\.[0-9]+\.[0-9]+[^ ]*" 2>/dev/null | head -1 || true)
  RELEASE_TYPE=$(echo "$OUTPUT" | grep -oP "Release type: \K\w+" 2>/dev/null | head -1 || true)
  NO_RELEASE=$(echo "$OUTPUT" | grep -c "no release published" 2>/dev/null || true)
  PUBLISHED=$(echo "$OUTPUT" | grep -oP "Published release \K.*" 2>/dev/null | head -1 || true)

  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Results${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
  echo ""

  if [[ $EXIT_CODE -ne 0 ]]; then
    echo -e "  ${RED}✗ Dry-run failed (exit code: $EXIT_CODE)${NC}"
    echo ""

    # Check common errors
    if echo "$OUTPUT" | grep -q "ENOGHTOKEN"; then
      echo -e "  ${YELLOW}Cause: GitHub token is missing or invalid${NC}"
      echo -e "  ${BLUE}Fix:   export GITHUB_TOKEN=\$(gh auth token)${NC}"
    elif echo "$OUTPUT" | grep -q "ENOGITHEAD"; then
      echo -e "  ${YELLOW}Cause: Git HEAD is not set (detached HEAD?)${NC}"
      echo -e "  ${BLUE}Fix:   git checkout <branch-name>${NC}"
    elif echo "$OUTPUT" | grep -q "EINVALIDBRANCH"; then
      echo -e "  ${YELLOW}Cause: Current branch not in 'branches' config${NC}"
      echo -e "  ${BLUE}Fix:   Add '${CURRENT_BRANCH}' to branches array in config${NC}"
    fi

  elif [[ $NO_RELEASE -gt 0 || -z "$NEXT_VERSION" ]]; then
    echo -e "  ${YELLOW}○ No release would be published${NC}"
    echo ""
    echo -e "  ${DIM}Possible reasons:${NC}"
    echo -e "  ${DIM}  - No feat/fix commits since last release${NC}"
    echo -e "  ${DIM}  - Commits don't follow Conventional Commits format${NC}"
    echo -e "  ${DIM}  - Current branch not configured for releases${NC}"

  else
    echo -e "  ${GREEN}✓ Release would be published${NC}"
    echo ""
    [[ -n "$RELEASE_TYPE" ]] && echo -e "  Release type:    ${BOLD}${RELEASE_TYPE}${NC}"
    [[ -n "$NEXT_VERSION" ]] && echo -e "  Next version:    ${BOLD}${NEXT_VERSION}${NC}"
    echo -e "  Last version:    ${LAST_TAG}"
    echo -e "  Commits:         ${COMMIT_COUNT}"

    # Show what plugins would do
    echo ""
    echo -e "  ${CYAN}Actions that would be taken:${NC}"
    echo "$OUTPUT" | grep -iE "(publish|create|push|update|wrote)" | head -10 | while read -r pline; do
      echo -e "    ${GREEN}→${NC} $pline"
    done
  fi

  echo ""
fi

exit $EXIT_CODE
