#!/usr/bin/env bash
#
# proto-breaking-check.sh — Run buf breaking change detection against a git branch.
#
# Usage:
#   ./proto-breaking-check.sh [branch] [options]
#
# Arguments:
#   branch    Git branch to compare against (default: main)
#
# Options:
#   --path <dir>     Path to proto directory (default: auto-detected from buf.yaml)
#   --level <level>  Breaking detection level: FILE, PACKAGE, WIRE, WIRE_JSON (default: from buf.yaml)
#   --verbose        Show detailed output
#   --ci             CI mode: exit code only, no colors
#
# Examples:
#   ./proto-breaking-check.sh
#   ./proto-breaking-check.sh main
#   ./proto-breaking-check.sh develop --verbose
#   ./proto-breaking-check.sh main --level WIRE
#   ./proto-breaking-check.sh main --ci
#
# Requires: buf, git

set -euo pipefail

# --- Colors (disabled in CI mode) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Defaults ---
BRANCH="main"
PROTO_PATH=""
LEVEL=""
VERBOSE=false
CI_MODE=false

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            PROTO_PATH="$2"
            shift 2
            ;;
        --level)
            LEVEL="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --ci)
            CI_MODE=true
            RED=""
            GREEN=""
            YELLOW=""
            CYAN=""
            NC=""
            shift
            ;;
        --help)
            head -25 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Error: unknown option '$1'"
            exit 1
            ;;
        *)
            BRANCH="$1"
            shift
            ;;
    esac
done

# --- Check dependencies ---

if ! command -v buf &> /dev/null; then
    echo -e "${RED}Error: buf not found.${NC}"
    echo "Install: brew install bufbuild/buf/buf"
    exit 1
fi

if ! command -v git &> /dev/null; then
    echo -e "${RED}Error: git not found.${NC}"
    exit 1
fi

# --- Verify git state ---

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo -e "${RED}Error: not inside a git repository.${NC}"
    exit 1
fi

# Verify branch exists
if ! git rev-parse --verify "$BRANCH" &>/dev/null; then
    echo -e "${RED}Error: branch '$BRANCH' does not exist.${NC}"
    echo "Available branches:"
    git branch -a | head -20
    exit 1
fi

# --- Detect proto changes ---

CHANGED_PROTOS=$(git diff --name-only "$BRANCH" -- '*.proto' 2>/dev/null || true)
if [[ -z "$CHANGED_PROTOS" ]]; then
    echo -e "${GREEN}No .proto files changed compared to ${BRANCH}.${NC}"
    exit 0
fi

if [[ "$VERBOSE" == true || "$CI_MODE" == false ]]; then
    echo -e "${CYAN}Changed .proto files (vs ${BRANCH}):${NC}"
    echo "$CHANGED_PROTOS" | sed 's/^/  /'
    echo ""
fi

# --- Build buf args ---

BUF_ARGS=("breaking" "--against" ".git#branch=${BRANCH}")

if [[ -n "$PROTO_PATH" ]]; then
    BUF_ARGS+=("$PROTO_PATH")
fi

if [[ -n "$LEVEL" ]]; then
    BUF_ARGS+=("--config" "{\"version\":\"v2\",\"breaking\":{\"use\":[\"${LEVEL}\"]}}")
fi

# --- Run breaking change detection ---

if [[ "$CI_MODE" == false ]]; then
    echo -e "${CYAN}Running buf breaking change detection against '${BRANCH}'...${NC}"
    echo ""
fi

RESULT=""
EXIT_CODE=0
if RESULT=$(buf "${BUF_ARGS[@]}" 2>&1); then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    if [[ "$CI_MODE" == false ]]; then
        echo -e "${GREEN}✓ No breaking changes detected.${NC}"
    fi
    exit 0
fi

# --- Breaking changes found ---

BREAK_COUNT=$(echo "$RESULT" | grep -c '.' || true)

if [[ "$CI_MODE" == false ]]; then
    echo -e "${RED}✗ ${BREAK_COUNT} breaking change(s) detected:${NC}"
    echo ""
fi

# Parse and display breaking changes
echo "$RESULT" | while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi

    if [[ "$CI_MODE" == true ]]; then
        echo "$line"
    else
        # Color the output: file:line:col: message
        FILE=$(echo "$line" | cut -d: -f1)
        REST=$(echo "$line" | cut -d: -f2-)
        echo -e "  ${YELLOW}${FILE}${NC}:${REST}"
    fi
done

if [[ "$CI_MODE" == false ]]; then
    echo ""
    echo -e "${YELLOW}To fix:${NC}"
    echo "  - Add new fields instead of modifying existing ones"
    echo "  - Use 'reserved' for removed fields"
    echo "  - Never change field numbers or types"
    echo "  - See: buf.build/docs/breaking/rules"
fi

exit 1
