#!/usr/bin/env bash
# =============================================================================
# mock-server.sh — Start a mock API server from an OpenAPI specification
#
# Starts a mock server using Prism (preferred) or json-server (fallback) that
# returns realistic responses based on your OpenAPI spec. Useful for frontend
# development, testing, and API prototyping.
#
# Usage:
#   ./mock-server.sh <spec-file> [options]
#
# Examples:
#   ./mock-server.sh openapi.yaml
#   ./mock-server.sh openapi.yaml --port 8080
#   ./mock-server.sh openapi.yaml --dynamic
#   ./mock-server.sh openapi.yaml --tool prism --host 0.0.0.0 --port 3000
#
# Requirements:
#   - Node.js 18+ and npm
#
# Features:
#   - Validates requests against the spec
#   - Returns examples from the spec when available
#   - Dynamic mode generates random valid responses
#   - CORS enabled by default
#
# Exit codes:
#   0 — Server stopped normally
#   1 — Server error
#   2 — Usage error or missing dependencies
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Defaults ---
SPEC_FILE=""
PORT=4010
HOST="127.0.0.1"
TOOL="prism"
DYNAMIC=false
CORS=true
VERBOSE=false

# --- Usage ---
usage() {
    echo "Usage: $0 <spec-file> [options]"
    echo ""
    echo "Options:"
    echo "  <spec-file>              Path to OpenAPI spec (YAML or JSON)"
    echo "  -p, --port <port>        Server port (default: 4010)"
    echo "  -H, --host <host>        Server host (default: 127.0.0.1)"
    echo "  -t, --tool <name>        Mock tool: prism (default)"
    echo "  -d, --dynamic            Enable dynamic response generation"
    echo "  --no-cors                Disable CORS headers"
    echo "  -v, --verbose            Verbose logging"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 openapi.yaml                     # Start on port 4010"
    echo "  $0 openapi.yaml -p 8080             # Custom port"
    echo "  $0 openapi.yaml -d                  # Dynamic responses"
    echo "  $0 openapi.yaml -H 0.0.0.0 -p 3000 # Bind to all interfaces"
    echo ""
    echo "Dynamic mode:"
    echo "  Without --dynamic: returns examples from spec (deterministic)"
    echo "  With --dynamic: generates random valid data from schemas"
    exit 2
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -H|--host)
            HOST="$2"
            shift 2
            ;;
        -t|--tool)
            TOOL="$2"
            shift 2
            ;;
        -d|--dynamic)
            DYNAMIC=true
            shift
            ;;
        --no-cors)
            CORS=false
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
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

# Validate port
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
    echo -e "${RED}Error: Invalid port number: $PORT${NC}" >&2
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

# --- Start Prism mock server ---
start_prism() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  OpenAPI Mock Server (Prism)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}  Spec:     $SPEC_FILE${NC}"
    echo -e "${BLUE}  Host:     $HOST${NC}"
    echo -e "${BLUE}  Port:     $PORT${NC}"
    echo -e "${BLUE}  Dynamic:  $DYNAMIC${NC}"
    echo -e "${BLUE}  CORS:     $CORS${NC}"
    echo ""

    # Build command
    local cmd="npx --yes @stoplight/prism-cli mock"
    cmd="$cmd $SPEC_FILE"
    cmd="$cmd --host $HOST"
    cmd="$cmd --port $PORT"

    if [[ "$DYNAMIC" == "true" ]]; then
        cmd="$cmd --dynamic"
    fi

    if [[ "$CORS" == "false" ]]; then
        cmd="$cmd --cors false"
    fi

    echo -e "${GREEN}▶ Starting mock server...${NC}"
    echo -e "${CYAN}  URL: http://$HOST:$PORT${NC}"
    echo ""
    echo -e "${YELLOW}  Press Ctrl+C to stop the server${NC}"
    echo ""

    # Handle graceful shutdown
    trap 'echo ""; echo -e "${BLUE}Server stopped.${NC}"; exit 0' INT TERM

    eval "$cmd"
}

# --- Main ---
main() {
    check_node

    case "$TOOL" in
        prism)
            start_prism
            ;;
        *)
            echo -e "${RED}Error: Unknown tool '$TOOL'. Supported: prism${NC}" >&2
            exit 2
            ;;
    esac
}

main
