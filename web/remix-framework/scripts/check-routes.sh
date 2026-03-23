#!/usr/bin/env bash
# check-routes.sh — Analyze route tree, detect conflicts, list all routes
#
# Usage:
#   ./check-routes.sh [app-dir]
#
# Defaults to ./app/routes if no argument is given.
#
# Output:
#   - All routes with their URL patterns and params
#   - Detected conflicts (duplicate URLs, ambiguous params)
#   - Layout routes and their children
#   - Resource routes (no component export)
#
# Requires: bash 4+, find, grep

set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Determine routes directory ---
APP_DIR="${1:-app}"
ROUTES_DIR="${APP_DIR}/routes"

if [[ ! -d "$ROUTES_DIR" ]]; then
  echo -e "${RED}Error: Routes directory not found at ${ROUTES_DIR}${NC}" >&2
  echo "Usage: $0 [app-dir]  (defaults to ./app)" >&2
  exit 1
fi

# --- Collect route files ---
declare -a ROUTE_FILES=()
while IFS= read -r -d '' file; do
  ROUTE_FILES+=("$file")
done < <(find "$ROUTES_DIR" -maxdepth 1 -type f \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" \) -print0 | sort -z)

if [[ ${#ROUTE_FILES[@]} -eq 0 ]]; then
  echo -e "${YELLOW}No route files found in ${ROUTES_DIR}${NC}"
  exit 0
fi

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Route Analysis: ${ROUTES_DIR}${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# --- Helper: Convert filename to URL pattern ---
filename_to_url() {
  local filename="$1"
  # Remove directory prefix and extension
  local base
  base=$(basename "$filename")
  base="${base%.*}"  # remove .tsx/.ts/.jsx/.js

  # Handle index routes
  if [[ "$base" == "_index" ]]; then
    echo "/"
    return
  fi

  # Handle pathless layouts (start with _)
  if [[ "$base" =~ ^_ ]]; then
    echo "(pathless layout)"
    return
  fi

  # Convert dots to slashes (flat route convention)
  local url="/${base//\.//}"

  # Convert $param to :param
  url=$(echo "$url" | sed 's/\$\([a-zA-Z_][a-zA-Z0-9_]*\)/:\1/g')

  # Convert lone $ (splat) to *
  url="${url//\$/\*}"

  # Handle route groups — remove (group) segments
  url=$(echo "$url" | sed 's/([^)]*)\.//g; s/([^)]*)//g')

  echo "$url"
}

# --- Helper: Extract params from filename ---
extract_params() {
  local base
  base=$(basename "$1")
  base="${base%.*}"
  local params=""
  # Match $paramName
  while [[ "$base" =~ \$([a-zA-Z_][a-zA-Z0-9_]*) ]]; do
    params="${params}:${BASH_REMATCH[1]} "
    base="${base/${BASH_REMATCH[0]}/}"
  done
  # Match lone $ (splat)
  if [[ "$base" =~ \$ ]]; then
    params="${params}* (splat) "
  fi
  echo "${params:-none}"
}

# --- Helper: Check if route is a resource route ---
is_resource_route() {
  local file="$1"
  # Resource routes have NO default export
  if grep -qE '^\s*export\s+default\s' "$file" 2>/dev/null; then
    return 1  # has default export → not resource
  fi
  # Must have at least a loader or action
  if grep -qE '^\s*export\s+(async\s+)?function\s+(loader|action)' "$file" 2>/dev/null; then
    return 0  # resource route
  fi
  return 1
}

# --- Helper: Check if route is a layout route ---
is_layout_route() {
  local file="$1"
  grep -qE '<Outlet\s*/?\s*>' "$file" 2>/dev/null
}

# --- Analyze and display routes ---
declare -A URL_MAP
TOTAL_ROUTES=0
TOTAL_LAYOUTS=0
TOTAL_RESOURCES=0
TOTAL_PAGES=0
CONFLICTS=0

printf "${BOLD}%-45s %-25s %-15s %s${NC}\n" "FILE" "URL" "PARAMS" "TYPE"
printf "%-45s %-25s %-15s %s\n" "----" "---" "------" "----"

for file in "${ROUTE_FILES[@]}"; do
  TOTAL_ROUTES=$((TOTAL_ROUTES + 1))
  filename=$(basename "$file")
  url=$(filename_to_url "$file")
  params=$(extract_params "$file")

  # Determine type
  route_type="page"
  type_color="$NC"

  if is_resource_route "$file"; then
    route_type="resource"
    type_color="$YELLOW"
    TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
  elif is_layout_route "$file"; then
    route_type="layout"
    type_color="$CYAN"
    TOTAL_LAYOUTS=$((TOTAL_LAYOUTS + 1))
  else
    TOTAL_PAGES=$((TOTAL_PAGES + 1))
  fi

  printf "%-45s %-25s %-15s ${type_color}%s${NC}\n" "$filename" "$url" "$params" "$route_type"

  # Track URLs for conflict detection
  if [[ "$url" != "(pathless layout)" ]]; then
    if [[ -v "URL_MAP[$url]" ]]; then
      URL_MAP["$url"]="${URL_MAP[$url]}, $filename"
    else
      URL_MAP["$url"]="$filename"
    fi
  fi
done

# --- Detect conflicts ---
echo ""
echo -e "${BOLD}${CYAN}── Conflict Detection ──${NC}"
echo ""

for url in "${!URL_MAP[@]}"; do
  files="${URL_MAP[$url]}"
  if [[ "$files" == *","* ]]; then
    CONFLICTS=$((CONFLICTS + 1))
    echo -e "${RED}⚠ CONFLICT:${NC} URL '${url}' matched by multiple files:"
    IFS=',' read -ra file_list <<< "$files"
    for f in "${file_list[@]}"; do
      echo -e "  ${YELLOW}→${NC}${f}"
    done
  fi
done

if [[ $CONFLICTS -eq 0 ]]; then
  echo -e "${GREEN}✓ No route conflicts detected${NC}"
fi

# --- Check for missing error boundaries ---
echo ""
echo -e "${BOLD}${CYAN}── Missing Error Boundaries ──${NC}"
echo ""

MISSING_EB=0
for file in "${ROUTE_FILES[@]}"; do
  if is_resource_route "$file"; then
    continue  # resource routes don't need error boundaries
  fi
  if ! grep -qE 'export\s+function\s+ErrorBoundary' "$file" 2>/dev/null; then
    MISSING_EB=$((MISSING_EB + 1))
    echo -e "${YELLOW}⚠${NC} $(basename "$file") — no ErrorBoundary export"
  fi
done

if [[ $MISSING_EB -eq 0 ]]; then
  echo -e "${GREEN}✓ All page/layout routes have ErrorBoundary exports${NC}"
fi

# --- Summary ---
echo ""
echo -e "${BOLD}${CYAN}── Summary ──${NC}"
echo ""
echo -e "  Total routes:     ${BOLD}${TOTAL_ROUTES}${NC}"
echo -e "  Page routes:      ${TOTAL_PAGES}"
echo -e "  Layout routes:    ${TOTAL_LAYOUTS}"
echo -e "  Resource routes:  ${TOTAL_RESOURCES}"
echo -e "  Conflicts:        $([ $CONFLICTS -gt 0 ] && echo -e "${RED}${CONFLICTS}${NC}" || echo -e "${GREEN}0${NC}")"
echo -e "  Missing ErrorBoundary: $([ $MISSING_EB -gt 0 ] && echo -e "${YELLOW}${MISSING_EB}${NC}" || echo -e "${GREEN}0${NC}")"
echo ""
