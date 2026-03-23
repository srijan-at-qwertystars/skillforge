#!/usr/bin/env bash
# pydantic-migrate.sh — Scan Python files for Pydantic v1 patterns and suggest v2 replacements.
# Wraps bump-pydantic for automated migration with a manual-review fallback.
#
# Usage:
#   pydantic-migrate.sh <path>           # apply changes
#   pydantic-migrate.sh --diff <path>    # preview changes only
#   pydantic-migrate.sh --check <path>   # scan for v1 patterns without modifying

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $(basename "$0") [OPTIONS] <path>"
    echo ""
    echo "Scan Python files for Pydantic v1 patterns and migrate to v2."
    echo ""
    echo "Options:"
    echo "  --diff     Preview changes without applying them"
    echo "  --check    Scan for v1 patterns only (no modifications)"
    echo "  --help     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") src/"
    echo "  $(basename "$0") --diff ."
    echo "  $(basename "$0") --check app/models.py"
}

MODE="apply"
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --diff)   MODE="diff"; shift ;;
        --check)  MODE="check"; shift ;;
        --help)   usage; exit 0 ;;
        -*)       echo "Unknown option: $1"; usage; exit 1 ;;
        *)        TARGET="$1"; shift ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo -e "${RED}Error: No path specified.${NC}"
    usage
    exit 1
fi

if [[ ! -e "$TARGET" ]]; then
    echo -e "${RED}Error: Path '$TARGET' does not exist.${NC}"
    exit 1
fi

# v1 patterns to detect
V1_PATTERNS=(
    '\.dict()'
    '\.json()'
    '\.parse_obj('
    '\.parse_raw('
    '\.from_orm('
    '\.copy('
    '\.construct('
    '\.__fields__'
    '\.schema()'
    '\.update_forward_refs()'
    '@validator'
    '@root_validator'
    'pre=True'
    'class Config:'
    'orm_mode'
    'regex='
    '__root__'
    'from pydantic.v1'
    'json_encoders'
    '__get_validators__'
)

scan_v1_patterns() {
    local target="$1"
    local found=0

    echo -e "${CYAN}Scanning for Pydantic v1 patterns in: ${target}${NC}"
    echo ""

    for pattern in "${V1_PATTERNS[@]}"; do
        matches=$(grep -rn --include="*.py" -E "$pattern" "$target" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            if [[ $found -eq 0 ]]; then
                echo -e "${YELLOW}Found v1 patterns:${NC}"
                echo ""
            fi
            found=1
            echo -e "${RED}Pattern: ${pattern}${NC}"
            echo "$matches" | head -20
            count=$(echo "$matches" | wc -l)
            if [[ $count -gt 20 ]]; then
                echo "  ... and $((count - 20)) more matches"
            fi
            echo ""
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo -e "${GREEN}No Pydantic v1 patterns found. Code appears to be v2-compatible.${NC}"
    fi

    return $found
}

run_bump_pydantic() {
    local target="$1"
    local mode="$2"

    if ! command -v bump-pydantic &>/dev/null; then
        echo -e "${YELLOW}bump-pydantic not found. Installing...${NC}"
        pip install bump-pydantic --quiet
    fi

    echo -e "${CYAN}Running bump-pydantic...${NC}"
    echo ""

    if [[ "$mode" == "diff" ]]; then
        bump-pydantic "$target" --diff 2>&1 || true
    else
        bump-pydantic "$target" 2>&1 || true
        echo ""
        echo -e "${GREEN}Migration complete. Review changes manually:${NC}"
        echo "  - Custom json_encoders → field_serializer / PlainSerializer"
        echo "  - Complex root_validator logic → model_validator(mode='before'/'after')"
        echo "  - __get_validators__ → __get_pydantic_core_schema__"
    fi
}

case "$MODE" in
    check)
        scan_v1_patterns "$TARGET"
        ;;
    diff)
        scan_v1_patterns "$TARGET" || true
        echo ""
        run_bump_pydantic "$TARGET" "diff"
        ;;
    apply)
        scan_v1_patterns "$TARGET" || true
        echo ""
        run_bump_pydantic "$TARGET" "apply"
        ;;
esac
