#!/usr/bin/env bash
# =============================================================================
# app-health-check.sh — Check health and sync status of Argo CD applications
#
# Reports degraded, out-of-sync, or unhealthy applications. Useful for
# monitoring, CI/CD gates, and operational dashboards.
#
# Usage:
#   ./app-health-check.sh [OPTIONS]
#
# Options:
#   -n, --namespace  Argo CD namespace (default: argocd)
#   -p, --project    Filter by AppProject name
#   -o, --output     Output format: table | json | summary (default: table)
#   --unhealthy      Show only unhealthy/degraded apps
#   --out-of-sync    Show only out-of-sync apps
#   --exit-code      Exit with non-zero code if any app is unhealthy
#   -h, --help       Show this help message
#
# Examples:
#   ./app-health-check.sh                          # Show all apps
#   ./app-health-check.sh --unhealthy              # Only degraded apps
#   ./app-health-check.sh --exit-code              # CI gate (fails if unhealthy)
#   ./app-health-check.sh -p production -o json    # JSON output for project
# =============================================================================

set -euo pipefail

NAMESPACE="argocd"
PROJECT=""
OUTPUT="table"
FILTER_UNHEALTHY=false
FILTER_OUTOFSYNC=false
EXIT_CODE=false

usage() {
  head -n 21 "$0" | tail -n 19 | sed 's/^# \?//'
  exit 0
}

err() { echo "[ERROR] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
    -p|--project)     PROJECT="$2"; shift 2 ;;
    -o|--output)      OUTPUT="$2"; shift 2 ;;
    --unhealthy)      FILTER_UNHEALTHY=true; shift ;;
    --out-of-sync)    FILTER_OUTOFSYNC=true; shift ;;
    --exit-code)      EXIT_CODE=true; shift ;;
    -h|--help)        usage ;;
    *)                err "Unknown option: $1" ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || err "kubectl not found in PATH"
[[ "$OUTPUT" =~ ^(table|json|summary)$ ]] || err "Invalid output format: $OUTPUT (use table, json, or summary)"

# ─── Gather application data ────────────────────────────────────────────────

# Build jsonpath to extract app info
APPS_JSON=$(kubectl get applications.argoproj.io -n "$NAMESPACE" -o json 2>/dev/null) || err "Failed to list applications in namespace $NAMESPACE"

APP_COUNT=$(echo "$APPS_JSON" | jq '.items | length')

if [[ "$APP_COUNT" -eq 0 ]]; then
  echo "No Argo CD applications found in namespace $NAMESPACE"
  exit 0
fi

# Extract relevant fields into a workable format
APPS_DATA=$(echo "$APPS_JSON" | jq -r '
  .items[] | {
    name: .metadata.name,
    project: (.spec.project // "default"),
    syncStatus: (.status.sync.status // "Unknown"),
    healthStatus: (.status.health.status // "Unknown"),
    revision: (.status.sync.revision // "N/A" | .[0:8]),
    destination: ((.spec.destination.server // "in-cluster") + "/" + (.spec.destination.namespace // "default")),
    lastSyncTime: (.status.operationState.finishedAt // "N/A"),
    syncPhase: (.status.operationState.phase // "N/A"),
    message: (.status.conditions // [] | map(.message) | join("; ") | if . == "" then "OK" else . end)
  }
')

# ─── Apply filters ──────────────────────────────────────────────────────────

FILTERED_DATA="$APPS_DATA"

if [[ -n "$PROJECT" ]]; then
  FILTERED_DATA=$(echo "$FILTERED_DATA" | jq "select(.project == \"$PROJECT\")")
fi

if [[ "$FILTER_UNHEALTHY" == "true" ]]; then
  FILTERED_DATA=$(echo "$FILTERED_DATA" | jq 'select(.healthStatus != "Healthy")')
fi

if [[ "$FILTER_OUTOFSYNC" == "true" ]]; then
  FILTERED_DATA=$(echo "$FILTERED_DATA" | jq 'select(.syncStatus != "Synced")')
fi

# Wrap into array
RESULT_ARRAY=$(echo "$FILTERED_DATA" | jq -s '.')

RESULT_COUNT=$(echo "$RESULT_ARRAY" | jq 'length')

# ─── Count categories ───────────────────────────────────────────────────────

HEALTHY=$(echo "$RESULT_ARRAY" | jq '[.[] | select(.healthStatus == "Healthy")] | length')
DEGRADED=$(echo "$RESULT_ARRAY" | jq '[.[] | select(.healthStatus == "Degraded")] | length')
PROGRESSING=$(echo "$RESULT_ARRAY" | jq '[.[] | select(.healthStatus == "Progressing")] | length')
SUSPENDED=$(echo "$RESULT_ARRAY" | jq '[.[] | select(.healthStatus == "Suspended")] | length')
MISSING=$(echo "$RESULT_ARRAY" | jq '[.[] | select(.healthStatus == "Missing" or .healthStatus == "Unknown")] | length')
SYNCED=$(echo "$RESULT_ARRAY" | jq '[.[] | select(.syncStatus == "Synced")] | length')
OUTOFSYNC=$(echo "$RESULT_ARRAY" | jq '[.[] | select(.syncStatus == "OutOfSync")] | length')

# ─── Output ─────────────────────────────────────────────────────────────────

case "$OUTPUT" in
  table)
    printf "%-30s %-15s %-12s %-12s %-10s %s\n" \
      "APPLICATION" "PROJECT" "HEALTH" "SYNC" "REVISION" "DESTINATION"
    printf "%-30s %-15s %-12s %-12s %-10s %s\n" \
      "───────────" "───────" "──────" "────" "────────" "───────────"

    echo "$RESULT_ARRAY" | jq -r '.[] |
      [.name, .project, .healthStatus, .syncStatus, .revision, .destination] | @tsv' | \
    while IFS=$'\t' read -r name project health sync rev dest; do
      # Color coding
      case "$health" in
        Healthy)     hcolor="\033[32m" ;;  # green
        Degraded)    hcolor="\033[31m" ;;  # red
        Progressing) hcolor="\033[33m" ;;  # yellow
        Suspended)   hcolor="\033[36m" ;;  # cyan
        *)           hcolor="\033[31m" ;;  # red
      esac
      case "$sync" in
        Synced)    scolor="\033[32m" ;;
        OutOfSync) scolor="\033[33m" ;;
        *)         scolor="\033[31m" ;;
      esac
      reset="\033[0m"

      printf "%-30s %-15s ${hcolor}%-12s${reset} ${scolor}%-12s${reset} %-10s %s\n" \
        "$name" "$project" "$health" "$sync" "$rev" "$dest"
    done

    echo
    echo "Summary: $RESULT_COUNT apps | ✓ $HEALTHY healthy | ✗ $DEGRADED degraded | ⟳ $PROGRESSING progressing | ⏸ $SUSPENDED suspended | ↑ $SYNCED synced | ↕ $OUTOFSYNC out-of-sync"
    ;;

  json)
    echo "$RESULT_ARRAY" | jq '{
      summary: {
        total: length,
        healthy: [.[] | select(.healthStatus == "Healthy")] | length,
        degraded: [.[] | select(.healthStatus == "Degraded")] | length,
        progressing: [.[] | select(.healthStatus == "Progressing")] | length,
        synced: [.[] | select(.syncStatus == "Synced")] | length,
        outOfSync: [.[] | select(.syncStatus == "OutOfSync")] | length
      },
      applications: .
    }'
    ;;

  summary)
    echo "=== Argo CD Application Health Summary ==="
    echo "  Total:        $RESULT_COUNT"
    echo "  Healthy:      $HEALTHY"
    echo "  Degraded:     $DEGRADED"
    echo "  Progressing:  $PROGRESSING"
    echo "  Suspended:    $SUSPENDED"
    echo "  Missing:      $MISSING"
    echo "  Synced:       $SYNCED"
    echo "  OutOfSync:    $OUTOFSYNC"

    if [[ "$DEGRADED" -gt 0 ]]; then
      echo
      echo "=== Degraded Applications ==="
      echo "$RESULT_ARRAY" | jq -r '.[] | select(.healthStatus == "Degraded") | "  \(.name) [\(.project)] — \(.message)"'
    fi

    if [[ "$OUTOFSYNC" -gt 0 ]]; then
      echo
      echo "=== Out-of-Sync Applications ==="
      echo "$RESULT_ARRAY" | jq -r '.[] | select(.syncStatus == "OutOfSync") | "  \(.name) [\(.project)] — rev: \(.revision)"'
    fi
    ;;
esac

# ─── Exit code ──────────────────────────────────────────────────────────────

if [[ "$EXIT_CODE" == "true" ]]; then
  if [[ "$DEGRADED" -gt 0 || "$MISSING" -gt 0 ]]; then
    echo >&2
    echo "FAIL: $DEGRADED degraded, $MISSING missing/unknown applications" >&2
    exit 1
  fi
fi

exit 0
