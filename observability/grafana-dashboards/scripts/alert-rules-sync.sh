#!/usr/bin/env bash
#
# alert-rules-sync.sh — Export/import Grafana unified alert rules between instances.
#
# Usage:
#   Export:
#     ./alert-rules-sync.sh export <GRAFANA_URL> <API_KEY> [OUTPUT_DIR]
#
#   Import:
#     ./alert-rules-sync.sh import <GRAFANA_URL> <API_KEY> <INPUT_DIR>
#
#   Sync (export from source, import to target):
#     ./alert-rules-sync.sh sync <SOURCE_URL> <SOURCE_KEY> <TARGET_URL> <TARGET_KEY>
#
# Examples:
#   ./alert-rules-sync.sh export http://localhost:3000 glsa_xxx ./alerts-backup
#   ./alert-rules-sync.sh import https://grafana-staging.co glsa_yyy ./alerts-backup
#   ./alert-rules-sync.sh sync http://prod:3000 glsa_xxx http://staging:3000 glsa_yyy
#
# Requirements: curl, jq
#
# Exports:
#   alert-rules.json         — All alert rule groups
#   contact-points.json      — Contact points
#   notification-policies.json — Notification policy tree
#   mute-timings.json        — Mute timing intervals

set -euo pipefail

ACTION="${1:-}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  echo "Usage:"
  echo "  $0 export <GRAFANA_URL> <API_KEY> [OUTPUT_DIR]"
  echo "  $0 import <GRAFANA_URL> <API_KEY> <INPUT_DIR>"
  echo "  $0 sync   <SOURCE_URL> <SOURCE_KEY> <TARGET_URL> <TARGET_KEY>"
  exit 1
}

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || error "Required: $cmd"
done

api_get() {
  local url="$1" key="$2" endpoint="$3"
  curl -sf \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    "${url%/}${endpoint}"
}

api_post() {
  local url="$1" key="$2" endpoint="$3" data="$4"
  curl -sf -X POST \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${url%/}${endpoint}"
}

api_put() {
  local url="$1" key="$2" endpoint="$3" data="$4"
  curl -sf -X PUT \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${url%/}${endpoint}"
}

# ─── Export ────────────────────────────────────────────────────────────────────

do_export() {
  local url="${1}" key="${2}" outdir="${3:-./alerts-export-$(date +%F)}"

  info "Exporting alert configuration from ${url}..."

  # Test connection
  api_get "$url" "$key" "/api/health" >/dev/null 2>&1 || error "Cannot connect to ${url}"

  mkdir -p "$outdir"

  # Alert rules (ruler API)
  info "Exporting alert rules..."
  local rules
  rules=$(api_get "$url" "$key" "/api/ruler/grafana/api/v1/rules" 2>/dev/null) || {
    warn "Failed to export alert rules (check permissions: requires alerting.rules:read)"
    rules="{}"
  }
  echo "$rules" | jq '.' > "${outdir}/alert-rules.json"
  local rule_count
  rule_count=$(echo "$rules" | jq '[.[] | .[] | .rules[]] | length')
  info "  Alert rules: ${rule_count}"

  # Contact points
  info "Exporting contact points..."
  local contacts
  contacts=$(api_get "$url" "$key" "/api/v1/provisioning/contact-points" 2>/dev/null) || {
    warn "Failed to export contact points"
    contacts="[]"
  }
  echo "$contacts" | jq '.' > "${outdir}/contact-points.json"
  info "  Contact points: $(echo "$contacts" | jq 'length')"

  # Notification policies
  info "Exporting notification policies..."
  local policies
  policies=$(api_get "$url" "$key" "/api/v1/provisioning/policies" 2>/dev/null) || {
    warn "Failed to export notification policies"
    policies="{}"
  }
  echo "$policies" | jq '.' > "${outdir}/notification-policies.json"
  info "  Notification policy tree exported"

  # Mute timings
  info "Exporting mute timings..."
  local mutes
  mutes=$(api_get "$url" "$key" "/api/v1/provisioning/mute-timings" 2>/dev/null) || {
    warn "Failed to export mute timings"
    mutes="[]"
  }
  echo "$mutes" | jq '.' > "${outdir}/mute-timings.json"
  info "  Mute timings: $(echo "$mutes" | jq 'length')"

  # Metadata
  cat > "${outdir}/_metadata.json" <<EOF
{
  "source": "${url}",
  "exported_at": "$(date -u +%FT%TZ)",
  "alert_rules": ${rule_count},
  "contact_points": $(echo "$contacts" | jq 'length'),
  "mute_timings": $(echo "$mutes" | jq 'length')
}
EOF

  info "Export complete → ${outdir}/"
}

# ─── Import ────────────────────────────────────────────────────────────────────

do_import() {
  local url="${1}" key="${2}" indir="${3}"

  [ -d "$indir" ] || error "Input directory not found: ${indir}"

  info "Importing alert configuration to ${url}..."

  # Test connection
  api_get "$url" "$key" "/api/health" >/dev/null 2>&1 || error "Cannot connect to ${url}"

  # Import mute timings first (policies may reference them)
  if [ -f "${indir}/mute-timings.json" ]; then
    info "Importing mute timings..."
    local mute_count=0
    while IFS= read -r mute; do
      local name
      name=$(echo "$mute" | jq -r '.name')
      api_put "$url" "$key" "/api/v1/provisioning/mute-timings/${name}" "$mute" >/dev/null 2>&1 && {
        mute_count=$((mute_count + 1))
      } || {
        # Try POST if PUT fails (new mute timing)
        api_post "$url" "$key" "/api/v1/provisioning/mute-timings" "$mute" >/dev/null 2>&1 && {
          mute_count=$((mute_count + 1))
        } || warn "  Failed to import mute timing: ${name}"
      }
    done < <(jq -c '.[]' "${indir}/mute-timings.json" 2>/dev/null)
    info "  Imported ${mute_count} mute timings"
  fi

  # Import contact points
  if [ -f "${indir}/contact-points.json" ]; then
    info "Importing contact points..."
    local cp_count=0
    while IFS= read -r cp; do
      local uid
      uid=$(echo "$cp" | jq -r '.uid')
      api_put "$url" "$key" "/api/v1/provisioning/contact-points/${uid}" "$cp" >/dev/null 2>&1 && {
        cp_count=$((cp_count + 1))
      } || {
        api_post "$url" "$key" "/api/v1/provisioning/contact-points" "$cp" >/dev/null 2>&1 && {
          cp_count=$((cp_count + 1))
        } || warn "  Failed to import contact point: ${uid}"
      }
    done < <(jq -c '.[]' "${indir}/contact-points.json" 2>/dev/null)
    info "  Imported ${cp_count} contact points"
  fi

  # Import notification policies
  if [ -f "${indir}/notification-policies.json" ]; then
    info "Importing notification policies..."
    local policy_data
    policy_data=$(cat "${indir}/notification-policies.json")
    api_put "$url" "$key" "/api/v1/provisioning/policies" "$policy_data" >/dev/null 2>&1 && {
      info "  Notification policies imported"
    } || warn "  Failed to import notification policies"
  fi

  # Import alert rules
  if [ -f "${indir}/alert-rules.json" ]; then
    info "Importing alert rules..."
    local group_count=0
    # Iterate over folders (top-level keys)
    while IFS= read -r folder; do
      local groups
      groups=$(jq -c --arg f "$folder" '.[$f][]' "${indir}/alert-rules.json" 2>/dev/null)
      while IFS= read -r group; do
        local group_name
        group_name=$(echo "$group" | jq -r '.name')
        # Use provisioning API for rule groups
        api_post "$url" "$key" "/api/ruler/grafana/api/v1/rules/${folder}" "$group" >/dev/null 2>&1 && {
          group_count=$((group_count + 1))
        } || warn "  Failed to import rule group: ${folder}/${group_name}"
      done <<< "$groups"
    done < <(jq -r 'keys[]' "${indir}/alert-rules.json" 2>/dev/null)
    info "  Imported ${group_count} rule groups"
  fi

  info "Import complete!"
}

# ─── Sync ──────────────────────────────────────────────────────────────────────

do_sync() {
  local src_url="$1" src_key="$2" tgt_url="$3" tgt_key="$4"
  local tmpdir
  tmpdir=$(mktemp -d)

  info "Syncing alerts: ${src_url} → ${tgt_url}"

  do_export "$src_url" "$src_key" "$tmpdir"
  do_import "$tgt_url" "$tgt_key" "$tmpdir"

  rm -rf "$tmpdir"
  info "Sync complete!"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "$ACTION" in
  export)
    [ $# -ge 3 ] || usage
    do_export "${2}" "${3}" "${4:-}"
    ;;
  import)
    [ $# -ge 4 ] || usage
    do_import "${2}" "${3}" "${4}"
    ;;
  sync)
    [ $# -ge 5 ] || usage
    do_sync "${2}" "${3}" "${4}" "${5}"
    ;;
  *)
    usage
    ;;
esac
