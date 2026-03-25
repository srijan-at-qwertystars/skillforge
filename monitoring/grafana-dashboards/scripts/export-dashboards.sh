#!/usr/bin/env bash
#
# export-dashboards.sh — Export all dashboards from a Grafana instance to JSON files.
#
# Usage:
#   ./export-dashboards.sh                                        # Defaults: localhost:3000
#   ./export-dashboards.sh --url http://grafana.example.com       # Custom URL
#   ./export-dashboards.sh --token "glsa_xxxxx"                   # Service account token
#   ./export-dashboards.sh --user admin --password admin          # Basic auth
#   ./export-dashboards.sh --output-dir ./exported-dashboards     # Custom output directory
#   ./export-dashboards.sh --strip-ids                            # Remove id/version for VCS
#   ./export-dashboards.sh --folder "Production"                  # Export only from folder
#
# Prerequisites: curl, jq
#
# What this script does:
#   1. Connects to Grafana API
#   2. Lists all dashboards (optionally filtered by folder)
#   3. Exports each dashboard JSON to a file organized by folder
#   4. Optionally strips id/version fields for version control
#
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
OUTPUT_DIR="${OUTPUT_DIR:-./exported-dashboards}"
STRIP_IDS=false
FOLDER_FILTER=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)        GRAFANA_URL="$2"; shift 2 ;;
    --token)      GRAFANA_TOKEN="$2"; shift 2 ;;
    --user)       GRAFANA_USER="$2"; shift 2 ;;
    --password)   GRAFANA_PASSWORD="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --strip-ids)  STRIP_IDS=true; shift ;;
    --folder)     FOLDER_FILTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Dependency check ─────────────────────────────────────────────────────────
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

# ── Build auth header ────────────────────────────────────────────────────────
if [[ -n "${GRAFANA_TOKEN}" ]]; then
  AUTH_HEADER="Authorization: Bearer ${GRAFANA_TOKEN}"
else
  AUTH_HEADER="Authorization: Basic $(echo -n "${GRAFANA_USER}:${GRAFANA_PASSWORD}" | base64)"
fi

# ── Test connection ───────────────────────────────────────────────────────────
echo "==> Connecting to ${GRAFANA_URL}..."
HEALTH=$(curl -sf -H "${AUTH_HEADER}" "${GRAFANA_URL}/api/health" 2>/dev/null || true)
if [[ -z "$HEALTH" ]]; then
  echo "ERROR: Cannot connect to Grafana at ${GRAFANA_URL}" >&2
  echo "       Check URL, credentials, and network connectivity." >&2
  exit 1
fi
echo "    Connected. Database status: $(echo "$HEALTH" | jq -r '.database // "unknown"')"

# ── Build search query ────────────────────────────────────────────────────────
SEARCH_URL="${GRAFANA_URL}/api/search?type=dash-db&limit=5000"
if [[ -n "${FOLDER_FILTER}" ]]; then
  # Get folder ID by title
  FOLDER_ID=$(curl -sf -H "${AUTH_HEADER}" "${GRAFANA_URL}/api/folders" | \
    jq -r --arg title "${FOLDER_FILTER}" '.[] | select(.title == $title) | .id')
  if [[ -z "$FOLDER_ID" ]]; then
    echo "ERROR: Folder '${FOLDER_FILTER}' not found." >&2
    echo "       Available folders:" >&2
    curl -sf -H "${AUTH_HEADER}" "${GRAFANA_URL}/api/folders" | jq -r '.[].title' >&2
    exit 1
  fi
  SEARCH_URL="${SEARCH_URL}&folderIds=${FOLDER_ID}"
  echo "    Filtering to folder: ${FOLDER_FILTER} (id: ${FOLDER_ID})"
fi

# ── List dashboards ──────────────────────────────────────────────────────────
echo "==> Fetching dashboard list..."
DASHBOARDS=$(curl -sf -H "${AUTH_HEADER}" "${SEARCH_URL}")
DASHBOARD_COUNT=$(echo "$DASHBOARDS" | jq 'length')
echo "    Found ${DASHBOARD_COUNT} dashboards"

if [[ "$DASHBOARD_COUNT" -eq 0 ]]; then
  echo "    No dashboards to export."
  exit 0
fi

# ── Create output directory ───────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"

# ── Export each dashboard ─────────────────────────────────────────────────────
EXPORTED=0
FAILED=0

echo "$DASHBOARDS" | jq -c '.[]' | while read -r dash; do
  UID=$(echo "$dash" | jq -r '.uid')
  TITLE=$(echo "$dash" | jq -r '.title')
  FOLDER_TITLE=$(echo "$dash" | jq -r '.folderTitle // "General"')

  # Sanitize folder and title for filesystem
  SAFE_FOLDER=$(echo "$FOLDER_TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g')
  SAFE_TITLE=$(echo "$TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g')

  # Create folder directory
  FOLDER_DIR="${OUTPUT_DIR}/${SAFE_FOLDER}"
  mkdir -p "${FOLDER_DIR}"

  # Fetch full dashboard
  RESPONSE=$(curl -sf -H "${AUTH_HEADER}" "${GRAFANA_URL}/api/dashboards/uid/${UID}" 2>/dev/null || true)

  if [[ -z "$RESPONSE" ]]; then
    echo "    FAILED: ${FOLDER_TITLE}/${TITLE} (uid: ${UID})"
    continue
  fi

  # Extract dashboard JSON (without meta wrapper)
  DASHBOARD_JSON=$(echo "$RESPONSE" | jq '.dashboard')

  if [[ "$STRIP_IDS" == "true" ]]; then
    DASHBOARD_JSON=$(echo "$DASHBOARD_JSON" | jq 'del(.id) | .version = 0 | del(.iteration)')
  fi

  # Write to file
  OUTPUT_FILE="${FOLDER_DIR}/${SAFE_TITLE}.json"
  echo "$DASHBOARD_JSON" | jq '.' > "${OUTPUT_FILE}"
  echo "    ✓ ${FOLDER_TITLE}/${TITLE} → ${OUTPUT_FILE}"
done

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_FILES=$(find "${OUTPUT_DIR}" -name "*.json" -type f | wc -l)
echo ""
echo "════════════════════════════════════════════════════"
echo "  Export complete!"
echo "  Exported: ${TOTAL_FILES} dashboards"
echo "  Output:   ${OUTPUT_DIR}/"
if [[ "$STRIP_IDS" == "true" ]]; then
  echo "  IDs stripped for version control"
fi
echo ""
echo "  Directory structure:"
find "${OUTPUT_DIR}" -type f -name "*.json" | head -20 | sed 's/^/    /'
REMAINING=$(( TOTAL_FILES - 20 ))
if [[ $REMAINING -gt 0 ]]; then
  echo "    ... and ${REMAINING} more"
fi
echo "════════════════════════════════════════════════════"
