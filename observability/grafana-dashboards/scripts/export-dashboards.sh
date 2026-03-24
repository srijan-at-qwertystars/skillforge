#!/usr/bin/env bash
#
# export-dashboards.sh — Export all dashboards from a Grafana instance via API.
#
# Usage:
#   ./export-dashboards.sh --api-key <KEY> [OPTIONS]
#
# Options:
#   --url <URL>          Grafana base URL (default: http://localhost:3000)
#   --api-key <KEY>      Grafana API key or service account token (required)
#   --output-dir <DIR>   Directory to save exported dashboards (default: ./exported-dashboards)
#   -h, --help           Show this help message
#
# Description:
#   Queries /api/search to discover all dashboards, then fetches each one
#   via /api/dashboards/uid/<uid>. The exported JSON is cleaned by removing
#   the "id" and "version" fields so it can be cleanly re-imported.
#   Dashboards are saved as <output-dir>/<folder-title>/<uid>.json.
#
# Dependencies: curl, jq
#

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
GRAFANA_URL="http://localhost:3000"
API_KEY=""
OUTPUT_DIR="./exported-dashboards"

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

grafana_get() {
    local endpoint="$1"
    local http_code body
    body=$(curl -fsSL -w "\n%{http_code}" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        "${GRAFANA_URL}${endpoint}" 2>&1) || true

    http_code=$(echo "$body" | tail -n1)
    body=$(echo "$body" | sed '$d')

    if [[ "$http_code" -ge 400 ]] 2>/dev/null; then
        echo "API error (HTTP ${http_code}) on ${endpoint}: ${body}" >&2
        return 1
    fi
    echo "$body"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)        GRAFANA_URL="${2:?--url requires a value}"; shift 2 ;;
        --api-key)    API_KEY="${2:?--api-key requires a value}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
        -h|--help)    usage ;;
        *)            die "Unknown option: $1" ;;
    esac
done

# ── Validation ────────────────────────────────────────────────────────────────
check_deps
[[ -n "$API_KEY" ]] || die "--api-key is required. Use -h for help."

# Remove trailing slash from URL
GRAFANA_URL="${GRAFANA_URL%/}"

# ── Discover dashboards ──────────────────────────────────────────────────────
echo "Connecting to Grafana at ${GRAFANA_URL} ..."

search_result=$(grafana_get "/api/search?type=dash-db&limit=5000") \
    || die "Failed to list dashboards. Check URL and API key."

dashboard_count=$(echo "$search_result" | jq 'length')
if [[ "$dashboard_count" -eq 0 ]]; then
    echo "No dashboards found."
    exit 0
fi

echo "Found ${dashboard_count} dashboard(s). Starting export..."

# ── Export loop ───────────────────────────────────────────────────────────────
success=0
failed=0
index=0

echo "$search_result" | jq -c '.[]' | while IFS= read -r item; do
    index=$((index + 1))
    uid=$(echo "$item" | jq -r '.uid')
    title=$(echo "$item" | jq -r '.title')
    folder_title=$(echo "$item" | jq -r '.folderTitle // "General"')

    echo "Exporting dashboard ${index}/${dashboard_count}: ${title}"

    # Fetch full dashboard model
    dash_json=$(grafana_get "/api/dashboards/uid/${uid}") || {
        echo "  ✗ Failed to fetch UID ${uid}" >&2
        failed=$((failed + 1))
        continue
    }

    # Strip id and version for clean import
    clean_json=$(echo "$dash_json" | jq '
        .dashboard |= del(.id, .version)
    ')

    # Sanitize folder name for filesystem
    safe_folder=$(echo "$folder_title" | sed 's/[^a-zA-Z0-9._-]/_/g')
    dest_dir="${OUTPUT_DIR}/${safe_folder}"
    mkdir -p "$dest_dir"

    dest_file="${dest_dir}/${uid}.json"
    echo "$clean_json" | jq '.' > "$dest_file"
    echo "  ✓ Saved to ${dest_file}"
    success=$((success + 1))
done

echo ""
echo "Export complete."
echo "  Output directory : ${OUTPUT_DIR}"
echo "  Total dashboards : ${dashboard_count}"
echo "  Exported         : ${success:-$dashboard_count}"
if [[ "${failed:-0}" -gt 0 ]]; then
    echo "  Failed           : ${failed}"
fi
