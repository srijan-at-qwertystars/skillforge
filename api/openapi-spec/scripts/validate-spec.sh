#!/usr/bin/env bash
# =============================================================================
# validate-spec.sh — Validate an OpenAPI specification file
#
# Validates an OpenAPI spec using Spectral (preferred) or swagger-cli (fallback).
# Automatically installs the chosen tool if not found.
#
# Usage:
#   ./validate-spec.sh <spec-file> [--tool spectral|swagger-cli] [--ruleset <file>]
#
# Examples:
#   ./validate-spec.sh openapi.yaml
#   ./validate-spec.sh api/spec.json --tool swagger-cli
#   ./validate-spec.sh openapi.yaml --ruleset .spectral.yml
#
# Requirements:
#   - Node.js 18+ and npm (for automatic installation)
#   - Or pre-installed: npx @stoplight/spectral-cli / npx @apidevtools/swagger-cli
#
# Exit codes:
#   0 — Validation passed (no errors)
#   1 — Validation failed (errors found)
#   2 — Usage error or missing dependencies
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Defaults ---
SPEC_FILE=""
TOOL="auto"
RULESET=""

# --- Usage ---
usage() {
    echo "Usage: $0 <spec-file> [--tool spectral|swagger-cli] [--ruleset <file>]"
    echo ""
    echo "Options:"
    echo "  <spec-file>              Path to OpenAPI spec (YAML or JSON)"
    echo "  --tool <name>            Validation tool: spectral (default), swagger-cli"
    echo "  --ruleset <file>         Custom Spectral ruleset file (only with spectral)"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 openapi.yaml"
    echo "  $0 api/spec.json --tool swagger-cli"
    echo "  $0 openapi.yaml --ruleset .spectral.yml"
    exit 2
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --tool)
            TOOL="$2"
            shift 2
            ;;
        --ruleset)
            RULESET="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}Error: Unknown option $1${NC}" >&2
            usage
            ;;
        *)
            if [[ -z "$SPEC_FILE" ]]; then
                SPEC_FILE="$1"
            else
                echo -e "${RED}Error: Unexpected argument '$1'${NC}" >&2
                usage
            fi
            shift
            ;;
    esac
done

# --- Validate inputs ---
if [[ -z "$SPEC_FILE" ]]; then
    echo -e "${RED}Error: No spec file specified${NC}" >&2
    usage
fi

if [[ ! -f "$SPEC_FILE" ]]; then
    echo -e "${RED}Error: File not found: $SPEC_FILE${NC}" >&2
    exit 2
fi

# --- Check Node.js ---
check_node() {
    if ! command -v node &>/dev/null; then
        echo -e "${RED}Error: Node.js is required but not installed.${NC}" >&2
        echo "Install from https://nodejs.org/ or via your package manager." >&2
        exit 2
    fi
    if ! command -v npx &>/dev/null; then
        echo -e "${RED}Error: npx is required but not found.${NC}" >&2
        exit 2
    fi
}

# --- Detect tool ---
detect_tool() {
    if [[ "$TOOL" != "auto" ]]; then
        return
    fi
    if command -v spectral &>/dev/null || npx --yes @stoplight/spectral-cli --version &>/dev/null 2>&1; then
        TOOL="spectral"
    elif command -v swagger-cli &>/dev/null || npx --yes @apidevtools/swagger-cli --version &>/dev/null 2>&1; then
        TOOL="swagger-cli"
    else
        TOOL="spectral"  # Default to spectral
    fi
}

# --- Validate with Spectral ---
validate_spectral() {
    echo -e "${BLUE}▶ Validating with Spectral...${NC}"
    echo -e "${BLUE}  File: $SPEC_FILE${NC}"

    local cmd="npx --yes @stoplight/spectral-cli lint"

    if [[ -n "$RULESET" ]]; then
        echo -e "${BLUE}  Ruleset: $RULESET${NC}"
        cmd="$cmd --ruleset $RULESET"
    fi

    cmd="$cmd $SPEC_FILE"

    echo ""
    if eval "$cmd"; then
        echo ""
        echo -e "${GREEN}✅ Validation passed — no errors found.${NC}"
        return 0
    else
        local exit_code=$?
        echo ""
        echo -e "${RED}❌ Validation failed — see errors above.${NC}"
        return 1
    fi
}

# --- Validate with swagger-cli ---
validate_swagger_cli() {
    echo -e "${BLUE}▶ Validating with swagger-cli...${NC}"
    echo -e "${BLUE}  File: $SPEC_FILE${NC}"
    echo ""

    if npx --yes @apidevtools/swagger-cli validate "$SPEC_FILE"; then
        echo ""
        echo -e "${GREEN}✅ Validation passed — spec is valid.${NC}"
        return 0
    else
        echo ""
        echo -e "${RED}❌ Validation failed — see errors above.${NC}"
        return 1
    fi
}

# --- Main ---
main() {
    check_node
    detect_tool

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  OpenAPI Spec Validator${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    case "$TOOL" in
        spectral)
            validate_spectral
            ;;
        swagger-cli)
            validate_swagger_cli
            ;;
        *)
            echo -e "${RED}Error: Unknown tool '$TOOL'. Use 'spectral' or 'swagger-cli'.${NC}" >&2
            exit 2
            ;;
    esac
}

main
