#!/usr/bin/env bash
# check-routes.sh — Analyze SvelteKit route tree, detect conflicts, list all
# routes with their parameters and file types.
#
# Usage:
#   ./check-routes.sh [options]
#
# Options:
#   --dir <path>     Path to SvelteKit project root (default: current directory)
#   --json           Output results as JSON
#   --verbose        Show all files per route, not just summary
#   --conflicts      Only show conflicting routes
#   -h, --help       Show this help message
#
# Run from SvelteKit project root or specify --dir.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[routes]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

# --- Defaults ---
PROJECT_DIR="."
OUTPUT_JSON=false
VERBOSE=false
CONFLICTS_ONLY=false

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)        PROJECT_DIR="$2"; shift 2 ;;
        --json)       OUTPUT_JSON=true; shift ;;
        --verbose)    VERBOSE=true; shift ;;
        --conflicts)  CONFLICTS_ONLY=true; shift ;;
        -h|--help)
            sed -n '2,/^$/s/^# //p' "$0"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

ROUTES_DIR="${PROJECT_DIR}/src/routes"

if [[ ! -d "$ROUTES_DIR" ]]; then
    error "Cannot find $ROUTES_DIR. Specify --dir or run from SvelteKit project root."
    exit 1
fi

# --- Collect all route directories ---
declare -A ROUTE_FILES
declare -A ROUTE_PARAMS
declare -A ROUTE_TYPES
declare -a ALL_ROUTES=()
declare -a URL_PATTERNS=()

# Convert filesystem path to URL pattern
path_to_url() {
    local path="$1"
    local relative="${path#"$ROUTES_DIR"}"
    [[ -z "$relative" ]] && relative="/"

    # Remove route groups: (groupname) -> nothing
    local url
    url=$(echo "$relative" | sed -E 's#/\([^)]+\)##g')

    # Clean up double slashes
    url=$(echo "$url" | sed 's#//#/#g')

    [[ -z "$url" ]] && url="/"
    echo "$url"
}

# Extract params from a route path
extract_params() {
    local path="$1"
    echo "$path" | grep -oE '\[[^\]]+\]' | tr '\n' ' ' || true
}

# Determine route type from files present
get_route_type() {
    local dir="$1"
    local types=""
    [[ -f "$dir/+page.svelte" ]] && types+="page "
    [[ -f "$dir/+page.ts" ]] && types+="load "
    [[ -f "$dir/+page.server.ts" ]] && types+="server-load "
    [[ -f "$dir/+server.ts" ]] && types+="api "
    [[ -f "$dir/+layout.svelte" ]] && types+="layout "
    [[ -f "$dir/+layout.ts" || -f "$dir/+layout.server.ts" ]] && types+="layout-load "
    [[ -f "$dir/+error.svelte" ]] && types+="error "
    echo "${types% }"
}

# --- Scan routes ---
while IFS= read -r dir; do
    # Skip directories with no route files
    has_route_file=false
    for f in "+page.svelte" "+page.ts" "+page.server.ts" "+server.ts" "+layout.svelte"; do
        if [[ -f "$dir/$f" ]]; then
            has_route_file=true
            break
        fi
    done
    [[ "$has_route_file" == false ]] && continue

    url=$(path_to_url "$dir")
    params=$(extract_params "$url")
    route_type=$(get_route_type "$dir")
    relative="${dir#"$ROUTES_DIR"}"
    [[ -z "$relative" ]] && relative="/"

    ALL_ROUTES+=("$relative")
    ROUTE_FILES["$relative"]="$dir"
    ROUTE_PARAMS["$relative"]="$params"
    ROUTE_TYPES["$relative"]="$route_type"
    URL_PATTERNS+=("$url")

done < <(find "$ROUTES_DIR" -type d | sort)

TOTAL_ROUTES=${#ALL_ROUTES[@]}

# --- Detect conflicts ---
declare -A URL_OWNERS
declare -a CONFLICTS=()

for i in "${!ALL_ROUTES[@]}"; do
    route="${ALL_ROUTES[$i]}"
    url="${URL_PATTERNS[$i]}"

    if [[ -n "${URL_OWNERS[$url]:-}" ]]; then
        CONFLICTS+=("$url")
        URL_OWNERS["$url"]="${URL_OWNERS[$url]}, $route"
    else
        URL_OWNERS["$url"]="$route"
    fi
done

# Deduplicate conflicts
declare -A UNIQUE_CONFLICTS
for c in "${CONFLICTS[@]:-}"; do
    [[ -n "$c" ]] && UNIQUE_CONFLICTS["$c"]=1
done

# --- Detect potential issues ---
declare -a WARNINGS=()

for route in "${ALL_ROUTES[@]}"; do
    dir="${ROUTE_FILES[$route]}"
    # Warn if +page.svelte and +server.ts coexist (content negotiation)
    if [[ -f "$dir/+page.svelte" && -f "$dir/+server.ts" ]]; then
        WARNINGS+=("$route: has both +page.svelte and +server.ts (content negotiation)")
    fi
    # Warn if +page.ts and +page.server.ts both exist
    if [[ -f "$dir/+page.ts" && -f "$dir/+page.server.ts" ]]; then
        WARNINGS+=("$route: has both +page.ts and +page.server.ts (universal + server load)")
    fi
done

# --- JSON Output ---
if [[ "$OUTPUT_JSON" == true ]]; then
    echo "{"
    echo "  \"total_routes\": $TOTAL_ROUTES,"
    echo "  \"routes\": ["
    for i in "${!ALL_ROUTES[@]}"; do
        route="${ALL_ROUTES[$i]}"
        url="${URL_PATTERNS[$i]}"
        params="${ROUTE_PARAMS[$route]}"
        rtype="${ROUTE_TYPES[$route]}"
        comma=","
        [[ $i -eq $((TOTAL_ROUTES - 1)) ]] && comma=""
        echo "    {\"path\": \"$route\", \"url\": \"$url\", \"params\": \"$params\", \"types\": \"$rtype\"}${comma}"
    done
    echo "  ],"
    echo "  \"conflicts\": ${#UNIQUE_CONFLICTS[@]},"
    echo "  \"warnings\": ${#WARNINGS[@]}"
    echo "}"
    exit 0
fi

# --- Pretty Output ---
if [[ "$CONFLICTS_ONLY" != true ]]; then
    echo ""
    echo -e "${BOLD}SvelteKit Route Analysis${NC}"
    echo -e "${BOLD}========================${NC}"
    echo ""
    echo -e "Routes directory: ${CYAN}$ROUTES_DIR${NC}"
    echo -e "Total routes:     ${BOLD}$TOTAL_ROUTES${NC}"
    echo ""

    # Route listing
    echo -e "${BOLD}Routes:${NC}"
    printf "  %-35s %-25s %s\n" "URL" "PARAMS" "TYPE"
    printf "  %-35s %-25s %s\n" "---" "------" "----"

    for i in "${!ALL_ROUTES[@]}"; do
        route="${ALL_ROUTES[$i]}"
        url="${URL_PATTERNS[$i]}"
        params="${ROUTE_PARAMS[$route]:-—}"
        rtype="${ROUTE_TYPES[$route]}"
        [[ -z "$params" ]] && params="—"
        printf "  %-35s %-25s %s\n" "$url" "$params" "$rtype"

        if [[ "$VERBOSE" == true ]]; then
            dir="${ROUTE_FILES[$route]}"
            for f in "$dir"/+*; do
                [[ -f "$f" ]] && echo -e "    ${CYAN}$(basename "$f")${NC}"
            done
        fi
    done
fi

# --- Conflicts ---
if [[ ${#UNIQUE_CONFLICTS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}⚠ Route Conflicts (${#UNIQUE_CONFLICTS[@]}):${NC}"
    for url in "${!UNIQUE_CONFLICTS[@]}"; do
        echo -e "  ${RED}$url${NC} — claimed by: ${URL_OWNERS[$url]}"
    done
else
    if [[ "$CONFLICTS_ONLY" != true ]]; then
        echo ""
        echo -e "${GREEN}✓ No route conflicts detected${NC}"
    fi
fi

# --- Warnings ---
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}Warnings (${#WARNINGS[@]}):${NC}"
    for w in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}⚡ $w${NC}"
    done
fi

echo ""
