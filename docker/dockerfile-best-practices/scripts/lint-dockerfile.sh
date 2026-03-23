#!/usr/bin/env bash
# =============================================================================
# lint-dockerfile.sh — Wrapper around hadolint for Dockerfile linting
#
# Usage:
#   ./lint-dockerfile.sh [DOCKERFILE_PATH]
#   ./lint-dockerfile.sh                    # defaults to ./Dockerfile
#   ./lint-dockerfile.sh path/to/Dockerfile
#
# Runs hadolint with common ignore rules, parses output by severity
# (error/warning/info), and exits with an appropriate code for CI usage.
#
# Exit codes:
#   0 — no issues found
#   1 — errors detected (CI should fail)
#   2 — warnings detected but no errors
# =============================================================================
set -euo pipefail

DOCKERFILE="${1:-./Dockerfile}"

# ---------------------------------------------------------------------------
# Color helpers (disabled when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  GREEN='\033[0;32m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' YELLOW='' BLUE='' GREEN='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Prerequisite check
# ---------------------------------------------------------------------------
if ! command -v hadolint &>/dev/null; then
  echo -e "${RED}Error: hadolint is not installed.${RESET}"
  echo ""
  echo "Install options:"
  echo "  brew install hadolint                        # macOS"
  echo "  sudo apt-get install hadolint                # Debian/Ubuntu (if packaged)"
  echo "  scoop install hadolint                       # Windows"
  echo "  docker run --rm -i hadolint/hadolint < Dockerfile  # via Docker"
  echo ""
  echo "Or download a binary from:"
  echo "  https://github.com/hadolint/hadolint/releases"
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate input
# ---------------------------------------------------------------------------
if [[ ! -f "$DOCKERFILE" ]]; then
  echo -e "${RED}Error: Dockerfile not found at '${DOCKERFILE}'${RESET}"
  exit 1
fi

echo -e "${BOLD}Linting: ${DOCKERFILE}${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Common ignore rules (adjust to taste)
# ---------------------------------------------------------------------------
IGNORE_RULES=(
  --ignore DL3008   # Pin versions in apt-get install
  --ignore DL3018   # Pin versions in apk add
  --ignore DL3059   # Multiple consecutive RUN instructions (allow for readability)
)

# ---------------------------------------------------------------------------
# Run hadolint and capture output
# ---------------------------------------------------------------------------
RAW_OUTPUT=$(hadolint --format tty "${IGNORE_RULES[@]}" "$DOCKERFILE" 2>&1) || true

if [[ -z "$RAW_OUTPUT" ]]; then
  echo -e "${GREEN}✔ No issues found — Dockerfile looks good!${RESET}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Categorise results by severity
# ---------------------------------------------------------------------------
ERRORS=""
WARNINGS=""
INFOS=""
ERROR_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0

while IFS= read -r line; do
  if [[ "$line" == *" error "* ]] || [[ "$line" == *"DL"*"error"* ]] || [[ "$line" == *" error:"* ]]; then
    ERRORS+="  ${line}"$'\n'
    ((ERROR_COUNT++)) || true
  elif [[ "$line" == *" warning "* ]] || [[ "$line" == *"DL"*"warning"* ]] || [[ "$line" == *" warning:"* ]]; then
    WARNINGS+="  ${line}"$'\n'
    ((WARNING_COUNT++)) || true
  elif [[ "$line" == *" info "* ]] || [[ "$line" == *"DL"*"info"* ]] || [[ "$line" == *" info:"* ]] || [[ "$line" == *" style "* ]]; then
    INFOS+="  ${line}"$'\n'
    ((INFO_COUNT++)) || true
  else
    # Fallback: treat unrecognised lines as warnings
    WARNINGS+="  ${line}"$'\n'
    ((WARNING_COUNT++)) || true
  fi
done <<< "$RAW_OUTPUT"

# ---------------------------------------------------------------------------
# Print categorised output
# ---------------------------------------------------------------------------
if [[ $ERROR_COUNT -gt 0 ]]; then
  echo -e "${RED}${BOLD}Errors (${ERROR_COUNT}):${RESET}"
  echo -e "${RED}${ERRORS}${RESET}"
fi

if [[ $WARNING_COUNT -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}Warnings (${WARNING_COUNT}):${RESET}"
  echo -e "${YELLOW}${WARNINGS}${RESET}"
fi

if [[ $INFO_COUNT -gt 0 ]]; then
  echo -e "${BLUE}${BOLD}Info (${INFO_COUNT}):${RESET}"
  echo -e "${BLUE}${INFOS}${RESET}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${BOLD}Summary:${RESET} ${ERROR_COUNT} error(s), ${WARNING_COUNT} warning(s), ${INFO_COUNT} info(s)"

if [[ $ERROR_COUNT -gt 0 ]]; then
  echo -e "${RED}✖ Lint failed — fix errors before merging.${RESET}"
  exit 1
elif [[ $WARNING_COUNT -gt 0 ]]; then
  echo -e "${YELLOW}⚠ Lint passed with warnings.${RESET}"
  exit 2
else
  echo -e "${GREEN}✔ Lint passed (info-only findings).${RESET}"
  exit 0
fi
