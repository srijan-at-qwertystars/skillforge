#!/usr/bin/env bash
# api-explorer.sh — curl + jq combo tool for exploring REST APIs
#
# Usage:
#   api-explorer.sh <url>                          GET with pretty-printed response
#   api-explorer.sh <url> <jq-filter>              GET with jq filter applied
#   api-explorer.sh -X POST <url> -d '{"key":"v"}' POST with JSON body
#   api-explorer.sh -H "Auth: Bearer $TOKEN" <url> Custom headers
#
# Features:
#   - Automatic JSON detection and pretty-printing
#   - Response headers, status code, and timing display
#   - Built-in jq filtering on responses
#   - Follow redirects, show response metadata
#   - Pagination helper for common API patterns
#   - Save responses to files
#
# Environment:
#   API_BASE_URL   Base URL prepended to relative paths
#   API_TOKEN      Bearer token added to Authorization header
#   API_HEADERS    Additional headers (newline-separated)
#
# Requirements: curl, jq, bash 4+

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly DIM='\033[2m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Defaults
JQ_FILTER="."
METHOD="GET"
SHOW_HEADERS=false
SAVE_FILE=""
FOLLOW_PAGES=false
MAX_PAGES=10
VERBOSE=false

usage() {
    echo -e "${BOLD}api-explorer.sh${NC} — curl + jq API exploration tool"
    echo
    echo -e "${BOLD}Usage:${NC}"
    echo "  api-explorer.sh [options] <url> [jq-filter]"
    echo
    echo -e "${BOLD}Options:${NC}"
    echo "  -X METHOD        HTTP method (GET, POST, PUT, PATCH, DELETE)"
    echo "  -H 'Key: Value'  Add request header (repeatable)"
    echo "  -d '{...}'        Request body (JSON)"
    echo "  -f <file>         Request body from file"
    echo "  -q <filter>       jq filter to apply to response"
    echo "  -o <file>         Save response body to file"
    echo "  -i                Show response headers"
    echo "  -p                Follow pagination (Link header or page params)"
    echo "  --max-pages N     Max pages to follow (default: 10)"
    echo "  -v                Verbose mode (show curl command)"
    echo "  -h, --help        Show this help"
    echo
    echo -e "${BOLD}Environment Variables:${NC}"
    echo "  API_BASE_URL      Prepended to relative URLs"
    echo "  API_TOKEN         Added as Bearer token"
    echo "  API_HEADERS       Extra headers (newline-separated)"
    echo
    echo -e "${BOLD}Examples:${NC}"
    echo "  api-explorer.sh https://api.github.com/users/octocat"
    echo "  api-explorer.sh https://api.github.com/repos/jqlang/jq/releases '.[0].tag_name'"
    echo "  api-explorer.sh -X POST -d '{\"name\":\"test\"}' https://api.example.com/items"
    echo "  API_BASE_URL=https://api.github.com api-explorer.sh /users/octocat '.name'"
    exit 0
}

# Parse arguments
CURL_ARGS=()
HEADERS=()
BODY=""
BODY_FILE=""
URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -X)
            METHOD="$2"
            shift 2
            ;;
        -H)
            HEADERS+=("$2")
            shift 2
            ;;
        -d)
            BODY="$2"
            shift 2
            ;;
        -f)
            BODY_FILE="$2"
            shift 2
            ;;
        -q)
            JQ_FILTER="$2"
            shift 2
            ;;
        -o)
            SAVE_FILE="$2"
            shift 2
            ;;
        -i)
            SHOW_HEADERS=true
            shift
            ;;
        -p)
            FOLLOW_PAGES=true
            shift
            ;;
        --max-pages)
            MAX_PAGES="$2"
            shift 2
            ;;
        -v)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            exit 1
            ;;
        *)
            if [[ -z "$URL" ]]; then
                URL="$1"
            else
                JQ_FILTER="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$URL" ]]; then
    echo -e "${RED}Error: URL is required${NC}" >&2
    echo "Run with --help for usage" >&2
    exit 1
fi

# Resolve URL
if [[ "$URL" == /* && -n "${API_BASE_URL:-}" ]]; then
    URL="${API_BASE_URL}${URL}"
fi

# Build curl command
build_curl_cmd() {
    local url="$1"
    local cmd=(curl -sS -w '\n%{http_code}\n%{time_total}' -L)

    cmd+=(-X "$METHOD")

    # Auth token
    if [[ -n "${API_TOKEN:-}" ]]; then
        cmd+=(-H "Authorization: Bearer ${API_TOKEN}")
    fi

    # Content-Type for POST/PUT/PATCH
    if [[ -n "$BODY" || -n "$BODY_FILE" ]]; then
        cmd+=(-H "Content-Type: application/json")
    fi

    # Custom headers
    for h in "${HEADERS[@]+"${HEADERS[@]}"}"; do
        cmd+=(-H "$h")
    done

    # Environment headers
    if [[ -n "${API_HEADERS:-}" ]]; then
        while IFS= read -r h; do
            [[ -n "$h" ]] && cmd+=(-H "$h")
        done <<< "$API_HEADERS"
    fi

    # Include response headers if requested
    if [[ "$SHOW_HEADERS" == true ]]; then
        cmd+=(-D -)
    fi

    # Body
    if [[ -n "$BODY" ]]; then
        cmd+=(-d "$BODY")
    elif [[ -n "$BODY_FILE" ]]; then
        cmd+=(-d "@$BODY_FILE")
    fi

    cmd+=("$url")
    echo "${cmd[@]}"
}

execute_request() {
    local url="$1"
    local curl_cmd
    curl_cmd=$(build_curl_cmd "$url")

    if [[ "$VERBOSE" == true ]]; then
        echo -e "${DIM}> ${curl_cmd}${NC}" >&2
    fi

    echo -e "${DIM}${METHOD} ${url}${NC}" >&2

    local response
    response=$(eval "$curl_cmd" 2>&1) || {
        echo -e "${RED}Error: curl failed${NC}" >&2
        echo "$response" >&2
        return 1
    }

    # Split response body, status code, and timing
    local body status_code timing
    timing=$(echo "$response" | tail -1)
    status_code=$(echo "$response" | tail -2 | head -1)
    body=$(echo "$response" | head -n -2)

    # If headers were included, separate them
    if [[ "$SHOW_HEADERS" == true ]]; then
        local header_end
        header_end=$(echo "$body" | grep -n '^$' | head -1 | cut -d: -f1)
        if [[ -n "$header_end" ]]; then
            echo -e "${DIM}$(echo "$body" | head -n "$header_end")${NC}" >&2
            body=$(echo "$body" | tail -n +"$((header_end + 1))")
        fi
    fi

    # Status code coloring
    local status_color="$GREEN"
    if [[ "$status_code" -ge 400 ]]; then
        status_color="$RED"
    elif [[ "$status_code" -ge 300 ]]; then
        status_color="$YELLOW"
    fi

    echo -e "${status_color}${status_code}${NC} ${DIM}(${timing}s)${NC}" >&2

    # Output body
    echo "$body"
}

format_response() {
    local body="$1"

    # Check if response is JSON
    if echo "$body" | jq empty 2>/dev/null; then
        echo "$body" | jq -C "$JQ_FILTER" 2>&1 || {
            echo -e "${RED}jq filter error. Raw response:${NC}" >&2
            echo "$body" | jq -C '.'
        }
    else
        echo -e "${YELLOW}Response is not JSON:${NC}" >&2
        echo "$body"
    fi
}

# Execute
RESPONSE=$(execute_request "$URL")

# Format and output
OUTPUT=$(format_response "$RESPONSE")

if [[ -n "$SAVE_FILE" ]]; then
    # Strip ANSI colors for file output
    echo "$OUTPUT" | sed 's/\x1b\[[0-9;]*m//g' > "$SAVE_FILE"
    echo -e "${GREEN}✓ Saved to: ${SAVE_FILE}${NC}" >&2
else
    echo "$OUTPUT"
fi

# Pagination
if [[ "$FOLLOW_PAGES" == true ]]; then
    page=1
    while [[ $page -lt $MAX_PAGES ]]; do
        # Try common pagination patterns
        next_url=""

        # Pattern 1: Link header (GitHub style)
        next_url=$(curl -sI -L "$URL" | grep -i '^link:' | \
            grep -oP '(?<=<)[^>]+(?=>; rel="next")' || true)

        # Pattern 2: next_page in response body
        if [[ -z "$next_url" ]]; then
            next_url=$(echo "$RESPONSE" | jq -r '.next // .next_page // .paging.next // empty' 2>/dev/null || true)
        fi

        [[ -z "$next_url" ]] && break

        page=$((page + 1))
        echo -e "\n${DIM}--- Page $page ---${NC}" >&2
        RESPONSE=$(execute_request "$next_url")
        format_response "$RESPONSE"
    done
fi
