#!/usr/bin/env bash
#
# dashboard-export.sh — Export all dashboards from a Grafana instance as JSON.
# Organizes exports by folder structure.
#
# Usage:
#   ./dashboard-export.sh <GRAFANA_URL> <API_KEY> [OUTPUT_DIR]
#
# Examples:
#   ./dashboard-export.sh http://localhost:3000 glsa_xxxxxxxxxxxx
#   ./dashboard-export.sh https://grafana.company.com glsa_xxxxxxxxxxxx ./backup
#
# Arguments:
#   GRAFANA_URL  — Base URL of the Grafana instance (no trailing slash)
#   API_KEY      — Grafana API key or service account token (glsa_...)
#   OUTPUT_DIR   — Output directory (default: ./grafana-export-YYYY-MM-DD)
#
# Requirements: curl, jq
#
# Output structure:
#   <OUTPUT_DIR>/
#     General/
#       dashboard-uid.json
#     Infrastructure/
#       another-uid.json
#     _metadata.json          (export metadata)

set -euo pipefail

GRAFANA_URL="${1:-}"
API_KEY="${2:-}"
OUTPUT_DIR="${3:-./grafana-export-$(date +%F)}"

# ─── Validation ───────────────────────────────────────────────────────────────

if [ -z "$GRAFANA_URL" ] || [ -z "$API_KEY" ]; then
  echo "Usage: $0 <GRAFANA_URL> <API_KEY> [OUTPUT_DIR]"
  echo "  Example: $0 http://localhost:3000 glsa_xxxxxxxxxxxx"
  exit 1
fi

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required"; exit 1; }
done

GRAFANA_URL="${GRAFANA_URL%/}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

api_get() {
  local endpoint="$1"
  curl -sf \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    "${GRAFANA_URL}${endpoint}"
}

# ─── Test Connection ──────────────────────────────────────────────────────────

info "Testing connection to ${GRAFANA_URL}..."
health=$(api_get "/api/health" 2>&1) || error "Cannot connect to Grafana at ${GRAFANA_URL}"
info "Connected. Health: $(echo "$health" | jq -r '.database // "ok"')"

# ─── Build Folder Map ─────────────────────────────────────────────────────────

info "Fetching folders..."
folders_json=$(api_get "/api/folders?limit=1000") || error "Failed to fetch folders"
declare -A FOLDER_MAP
FOLDER_MAP["0"]="General"

while IFS='|' read -r fid ftitle; do
  FOLDER_MAP["$fid"]="$ftitle"
done < <(echo "$folders_json" | jq -r '.[] | "\(.id)|\(.title)"')

info "Found ${#FOLDER_MAP[@]} folders (including General)"

# ─── Search All Dashboards ────────────────────────────────────────────────────

info "Searching for dashboards..."
page=1
all_dashboards="[]"

while true; do
  result=$(api_get "/api/search?type=dash-db&limit=500&page=${page}") || error "Search failed"
  count=$(echo "$result" | jq 'length')
  if [ "$count" -eq 0 ]; then
    break
  fi
  all_dashboards=$(echo "$all_dashboards $result" | jq -s 'add')
  page=$((page + 1))
done

total=$(echo "$all_dashboards" | jq 'length')
info "Found ${total} dashboards to export"

if [ "$total" -eq 0 ]; then
  warn "No dashboards found. Check API key permissions."
  exit 0
fi

# ─── Export Dashboards ─────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
exported=0
failed=0

while IFS='|' read -r uid title folder_id; do
  folder_name="${FOLDER_MAP[$folder_id]:-Uncategorized}"
  safe_folder=$(echo "$folder_name" | sed 's/[^a-zA-Z0-9 _-]/_/g')
  mkdir -p "${OUTPUT_DIR}/${safe_folder}"

  outfile="${OUTPUT_DIR}/${safe_folder}/${uid}.json"

  dashboard_json=$(api_get "/api/dashboards/uid/${uid}" 2>/dev/null) || {
    warn "Failed to export: ${title} (${uid})"
    failed=$((failed + 1))
    continue
  }

  # Extract just the dashboard model (strip meta wrapper)
  echo "$dashboard_json" | jq '.dashboard' > "$outfile"
  exported=$((exported + 1))
  printf '  [%d/%d] %s → %s\n' "$exported" "$total" "$title" "${safe_folder}/${uid}.json"

done < <(echo "$all_dashboards" | jq -r '.[] | "\(.uid)|\(.title)|\(.folderId // 0)"')

# ─── Metadata ─────────────────────────────────────────────────────────────────

cat > "${OUTPUT_DIR}/_metadata.json" <<EOF
{
  "source": "${GRAFANA_URL}",
  "exported_at": "$(date -u +%FT%TZ)",
  "total_dashboards": ${total},
  "exported": ${exported},
  "failed": ${failed},
  "folders": $(echo "$folders_json" | jq '[.[] | {uid, title, id}]')
}
EOF

# ─── Summary ──────────────────────────────────────────────────────────────────

info "Export complete!"
info "  Exported: ${exported}/${total} dashboards"
[ "$failed" -gt 0 ] && warn "  Failed:   ${failed}"
info "  Output:   ${OUTPUT_DIR}/"
info "  Metadata: ${OUTPUT_DIR}/_metadata.json"
