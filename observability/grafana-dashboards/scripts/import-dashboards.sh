#!/usr/bin/env bash
#
# import-dashboards.sh — Import dashboard JSON files into a Grafana instance.
#
# Usage:
#   ./import-dashboards.sh --api-key <KEY> --input-dir <DIR> [OPTIONS]
#
# Options:
#   --url <URL>              Grafana base URL (default: http://localhost:3000)
#   --api-key <KEY>          Grafana API key or service account token (required)
#   --input-dir <DIR>        Directory containing dashboard JSON files (required)
#   --folder <NAME>          Target Grafana folder name; created if it doesn't exist
#   --ds-map <OLD=NEWUID>    Data source substitution (repeatable). Replaces every
#                            occurrence of "OldName" with "NewUID" in each dashboard JSON.
#   -h, --help               Show this help message
#
# Description:
#   Recursively finds *.json files in the input directory and imports each one
#   via POST /api/dashboards/db. The dashboard "id" is set to null and "version"
#   to 0 so Grafana treats each as a fresh import. Existing dashboards with the
#   same UID are overwritten (overwrite: true).
#
# Dependencies: curl, jq
#

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
GRAFANA_URL="http://localhost:3000"
API_KEY=""
INPUT_DIR=""
FOLDER_NAME=""
declare -a DS_MAPS=()

# ── Functions ─────────────────────────────────────────────────────────────────
usage() {
    sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
    exit 0
}

die() { echo "ERROR: $*" >&2; exit 1; }

check_deps() {
    for cmd in curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found in PATH."
    done
}

grafana_post() {
    local endpoint="$1"
    local payload="$2"
    curl -fsSL -X POST \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${GRAFANA_URL}${endpoint}" 2>&1
}

grafana_get() {
    local endpoint="$1"
    curl -fsSL \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        "${GRAFANA_URL}${endpoint}" 2>&1
}

get_or_create_folder() {
    local name="$1"

    # Search for existing folder
    local folders
    folders=$(grafana_get "/api/folders") || die "Failed to list folders."

    local existing_id
    existing_id=$(echo "$folders" | jq -r --arg n "$name" '.[] | select(.title == $n) | .id' | head -1)

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        echo "$existing_id"
        return
    fi

    # Create folder
    local result
    result=$(grafana_post "/api/folders" "{\"title\": \"${name}\"}") || die "Failed to create folder '${name}'."
    echo "$result" | jq -r '.id'
}

apply_ds_substitutions() {
    local json="$1"
    for mapping in "${DS_MAPS[@]}"; do
        local old_name="${mapping%%=*}"
        local new_uid="${mapping#*=}"
        json=$(echo "$json" | jq --arg old "$old_name" --arg new "$new_uid" '
            walk(if type == "object" and .datasource? then
                if .datasource == $old then .datasource = $new
                elif (.datasource | type) == "object" and .datasource.uid? == $old then .datasource.uid = $new
                else . end
            else . end)
        ')
    done
    echo "$json"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)       GRAFANA_URL="${2:?--url requires a value}"; shift 2 ;;
        --api-key)   API_KEY="${2:?--api-key requires a value}"; shift 2 ;;
        --input-dir) INPUT_DIR="${2:?--input-dir requires a value}"; shift 2 ;;
        --folder)    FOLDER_NAME="${2:?--folder requires a value}"; shift 2 ;;
        --ds-map)    DS_MAPS+=("${2:?--ds-map requires OLD=NEW value}"); shift 2 ;;
        -h|--help)   usage ;;
        *)           die "Unknown option: $1" ;;
    esac
done

# ── Validation ────────────────────────────────────────────────────────────────
check_deps
[[ -n "$API_KEY" ]]  || die "--api-key is required. Use -h for help."
[[ -n "$INPUT_DIR" ]] || die "--input-dir is required. Use -h for help."
[[ -d "$INPUT_DIR" ]] || die "Input directory does not exist: ${INPUT_DIR}"

GRAFANA_URL="${GRAFANA_URL%/}"

# ── Resolve target folder ────────────────────────────────────────────────────
FOLDER_ID=0
if [[ -n "$FOLDER_NAME" ]]; then
    echo "Resolving target folder '${FOLDER_NAME}' ..."
    FOLDER_ID=$(get_or_create_folder "$FOLDER_NAME")
    echo "  Using folder ID: ${FOLDER_ID}"
fi

# ── Collect JSON files ────────────────────────────────────────────────────────
mapfile -t json_files < <(find "$INPUT_DIR" -type f -name '*.json' | sort)
total=${#json_files[@]}

if [[ "$total" -eq 0 ]]; then
    echo "No .json files found in ${INPUT_DIR}."
    exit 0
fi

echo "Found ${total} dashboard file(s). Starting import..."

# ── Import loop ──────────────────────────────────────────────────────────────
success=0
failed=0

for i in "${!json_files[@]}"; do
    file="${json_files[$i]}"
    idx=$((i + 1))
    basename_file=$(basename "$file")

    # Read and prepare the dashboard JSON
    raw_json=$(cat "$file")

    # Extract dashboard object — handle both wrapped and unwrapped formats
    if echo "$raw_json" | jq -e '.dashboard' >/dev/null 2>&1; then
        dash=$(echo "$raw_json" | jq '.dashboard')
    else
        dash="$raw_json"
    fi

    title=$(echo "$dash" | jq -r '.title // "unknown"')
    echo "Importing ${idx}/${total}: ${title} (${basename_file})"

    # Reset id/version for fresh import
    dash=$(echo "$dash" | jq '.id = null | .version = 0')

    # Apply data source substitutions
    if [[ ${#DS_MAPS[@]} -gt 0 ]]; then
        dash=$(apply_ds_substitutions "$dash")
    fi

    # Build import payload
    payload=$(jq -n \
        --argjson dash "$dash" \
        --argjson fid "$FOLDER_ID" \
        '{ dashboard: $dash, folderId: $fid, overwrite: true }')

    # POST to Grafana
    response=$(grafana_post "/api/dashboards/db" "$payload" 2>&1) && rc=0 || rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "  ✗ Failed: ${response}"
        failed=$((failed + 1))
    else
        status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null)
        echo "  ✓ ${status}"
        success=$((success + 1))
    fi
done

echo ""
echo "Import complete."
echo "  Total files : ${total}"
echo "  Succeeded   : ${success}"
echo "  Failed      : ${failed}"

[[ "$failed" -eq 0 ]] || exit 1
