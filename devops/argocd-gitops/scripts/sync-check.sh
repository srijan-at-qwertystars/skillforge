#!/usr/bin/env bash
# =============================================================================
# sync-check.sh — Check sync status of all Argo CD applications
#
# Reports sync state, detects drift, identifies failed syncs. Designed for
# CI/CD pipelines, monitoring scripts, and operational dashboards.
#
# Usage:
#   ./sync-check.sh [OPTIONS]
#
# Options:
#   -n, --namespace    Argo CD namespace (default: argocd)
#   -p, --project      Filter by AppProject name
#   -l, --label        Filter by label selector (e.g., team=backend)
#   -o, --output       Output format: table | json | brief (default: table)
#   --failed-only      Show only failed/errored syncs
#   --drifted-only     Show only out-of-sync (drifted) applications
#   --wait             Wait for all apps to sync, with timeout
#   --timeout          Timeout in seconds for --wait (default: 300)
#   --exit-code        Exit non-zero if any app is OutOfSync or failed
#   -h, --help         Show this help message
#
# Examples:
#   ./sync-check.sh                               # Status of all apps
#   ./sync-check.sh --drifted-only                 # Only drifted apps
#   ./sync-check.sh --failed-only -o json          # Failed syncs as JSON
#   ./sync-check.sh -p production --exit-code      # CI gate for production
#   ./sync-check.sh --wait --timeout 600           # Wait for all syncs
#   ./sync-check.sh -l team=backend -o brief       # Quick summary
# =============================================================================

set -euo pipefail

NAMESPACE="argocd"
PROJECT=""
LABEL=""
OUTPUT="table"
FAILED_ONLY=false
DRIFTED_ONLY=false
WAIT=false
TIMEOUT=300
EXIT_CODE=false

usage() {
  head -n 28 "$0" | tail -n 26 | sed 's/^# \?//'
  exit 0
}

err() { echo "[ERROR] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
    -p|--project)     PROJECT="$2"; shift 2 ;;
    -l|--label)       LABEL="$2"; shift 2 ;;
    -o|--output)      OUTPUT="$2"; shift 2 ;;
    --failed-only)    FAILED_ONLY=true; shift ;;
    --drifted-only)   DRIFTED_ONLY=true; shift ;;
    --wait)           WAIT=true; shift ;;
    --timeout)        TIMEOUT="$2"; shift 2 ;;
    --exit-code)      EXIT_CODE=true; shift ;;
    -h|--help)        usage ;;
    *)                err "Unknown option: $1" ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || err "kubectl not found in PATH"
command -v jq >/dev/null 2>&1 || err "jq not found in PATH"
[[ "$OUTPUT" =~ ^(table|json|brief)$ ]] || err "Invalid output: $OUTPUT (use table, json, or brief)"

# ─── Build kubectl command ──────────────────────────────────────────────────

KUBECTL_ARGS=(-n "$NAMESPACE")
if [[ -n "$LABEL" ]]; then
  KUBECTL_ARGS+=(-l "$LABEL")
fi

# ─── Fetch application data ────────────────────────────────────────────────

fetch_apps() {
  kubectl get applications.argoproj.io "${KUBECTL_ARGS[@]}" -o json 2>/dev/null \
    || err "Failed to list applications in namespace $NAMESPACE"
}

parse_apps() {
  local raw="$1"
  echo "$raw" | jq -r '
    [.items[] | {
      name: .metadata.name,
      project: (.spec.project // "default"),
      syncStatus: (.status.sync.status // "Unknown"),
      healthStatus: (.status.health.status // "Unknown"),
      revision: (.status.sync.revision // "N/A" | .[0:8]),
      targetRev: (.spec.source.targetRevision // (.spec.sources[0].targetRevision // "N/A")),
      repoURL: (.spec.source.repoURL // (.spec.sources[0].repoURL // "N/A") | split("/") | last | rtrimstr(".git")),
      syncPhase: (.status.operationState.phase // "N/A"),
      syncFinished: (.status.operationState.finishedAt // "N/A"),
      syncMessage: (.status.operationState.message // ""),
      conditions: ([.status.conditions[]?.message] | join("; ") | if . == "" then "-" else . end),
      autoSync: (if .spec.syncPolicy.automated != null then "auto" else "manual" end)
    }]
  '
}

# ─── Apply filters ─────────────────────────────────────────────────────────

apply_filters() {
  local data="$1"

  if [[ -n "$PROJECT" ]]; then
    data=$(echo "$data" | jq --arg p "$PROJECT" '[.[] | select(.project == $p)]')
  fi

  if [[ "$FAILED_ONLY" == "true" ]]; then
    data=$(echo "$data" | jq '[.[] | select(.syncPhase == "Failed" or .syncPhase == "Error" or .healthStatus == "Degraded" or .healthStatus == "Missing")]')
  fi

  if [[ "$DRIFTED_ONLY" == "true" ]]; then
    data=$(echo "$data" | jq '[.[] | select(.syncStatus != "Synced")]')
  fi

  echo "$data"
}

# ─── Compute stats ─────────────────────────────────────────────────────────

compute_stats() {
  local data="$1"
  echo "$data" | jq '{
    total: length,
    synced: [.[] | select(.syncStatus == "Synced")] | length,
    outOfSync: [.[] | select(.syncStatus == "OutOfSync")] | length,
    unknown: [.[] | select(.syncStatus == "Unknown")] | length,
    healthy: [.[] | select(.healthStatus == "Healthy")] | length,
    degraded: [.[] | select(.healthStatus == "Degraded")] | length,
    progressing: [.[] | select(.healthStatus == "Progressing")] | length,
    suspended: [.[] | select(.healthStatus == "Suspended")] | length,
    missing: [.[] | select(.healthStatus == "Missing" or .healthStatus == "Unknown")] | length,
    syncSucceeded: [.[] | select(.syncPhase == "Succeeded")] | length,
    syncFailed: [.[] | select(.syncPhase == "Failed" or .syncPhase == "Error")] | length,
    autoSync: [.[] | select(.autoSync == "auto")] | length,
    manualSync: [.[] | select(.autoSync == "manual")] | length
  }'
}

# ─── Output formatters ─────────────────────────────────────────────────────

output_table() {
  local data="$1"
  local stats="$2"

  # Header
  printf "\033[1m%-28s %-12s %-12s %-11s %-10s %-10s %-6s\033[0m\n" \
    "APPLICATION" "SYNC" "HEALTH" "OPERATION" "REVISION" "REPO" "MODE"
  printf "%-28s %-12s %-12s %-11s %-10s %-10s %-6s\n" \
    "──────────────────────────" "──────────" "──────────" "─────────" "────────" "────────" "────"

  echo "$data" | jq -r '.[] |
    [.name, .syncStatus, .healthStatus, .syncPhase, .revision, .repoURL, .autoSync] | @tsv' | \
  while IFS=$'\t' read -r name sync health phase rev repo mode; do
    # Color coding
    case "$sync" in
      Synced)     sc="\033[32m" ;;
      OutOfSync)  sc="\033[33m" ;;
      *)          sc="\033[31m" ;;
    esac
    case "$health" in
      Healthy)     hc="\033[32m" ;;
      Degraded)    hc="\033[31m" ;;
      Progressing) hc="\033[33m" ;;
      Suspended)   hc="\033[36m" ;;
      *)           hc="\033[31m" ;;
    esac
    case "$phase" in
      Succeeded) pc="\033[32m" ;;
      Failed|Error) pc="\033[31m" ;;
      Running)   pc="\033[33m" ;;
      *)         pc="\033[0m" ;;
    esac
    r="\033[0m"

    printf "%-28s ${sc}%-12s${r} ${hc}%-12s${r} ${pc}%-11s${r} %-10s %-10s %-6s\n" \
      "$name" "$sync" "$health" "$phase" "$rev" "$repo" "$mode"
  done

  # Summary bar
  local total synced oos degraded failed
  total=$(echo "$stats" | jq -r .total)
  synced=$(echo "$stats" | jq -r .synced)
  oos=$(echo "$stats" | jq -r .outOfSync)
  degraded=$(echo "$stats" | jq -r .degraded)
  failed=$(echo "$stats" | jq -r .syncFailed)

  echo
  printf "Total: %s | " "$total"
  [[ "$synced" -gt 0 ]]   && printf "\033[32m✓ %s synced\033[0m | " "$synced"
  [[ "$oos" -gt 0 ]]      && printf "\033[33m↕ %s drifted\033[0m | " "$oos"
  [[ "$degraded" -gt 0 ]] && printf "\033[31m✗ %s degraded\033[0m | " "$degraded"
  [[ "$failed" -gt 0 ]]   && printf "\033[31m⚠ %s failed\033[0m | " "$failed"
  echo

  # Show details for problem apps
  local problems
  problems=$(echo "$data" | jq -r '[.[] | select(.syncStatus != "Synced" or .healthStatus != "Healthy" or .syncPhase == "Failed" or .syncPhase == "Error")]')
  local problem_count
  problem_count=$(echo "$problems" | jq 'length')

  if [[ "$problem_count" -gt 0 ]]; then
    echo
    echo "=== Issues ==="
    echo "$problems" | jq -r '.[] |
      "  \(.name): sync=\(.syncStatus) health=\(.healthStatus) op=\(.syncPhase)" +
      (if .conditions != "-" then " — " + .conditions else "" end) +
      (if .syncMessage != "" then " — " + .syncMessage else "" end)
    '
  fi
}

output_json() {
  local data="$1"
  local stats="$2"
  jq -n --argjson stats "$stats" --argjson apps "$data" '{
    timestamp: (now | todate),
    summary: $stats,
    applications: $apps
  }'
}

output_brief() {
  local stats="$1"
  local total synced oos degraded failed
  total=$(echo "$stats" | jq -r .total)
  synced=$(echo "$stats" | jq -r .synced)
  oos=$(echo "$stats" | jq -r .outOfSync)
  degraded=$(echo "$stats" | jq -r .degraded)
  failed=$(echo "$stats" | jq -r .syncFailed)

  if [[ "$oos" -eq 0 && "$degraded" -eq 0 && "$failed" -eq 0 ]]; then
    echo "OK: All ${total} applications synced and healthy"
  else
    echo "ISSUES: ${total} apps — ${synced} synced, ${oos} drifted, ${degraded} degraded, ${failed} failed"
  fi
}

# ─── Wait mode ──────────────────────────────────────────────────────────────

do_wait() {
  local start elapsed
  start=$(date +%s)
  echo "Waiting for all applications to sync (timeout: ${TIMEOUT}s)..."

  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
      echo "TIMEOUT: Not all applications synced within ${TIMEOUT}s"
      return 1
    fi

    local raw apps stats oos progressing
    raw=$(fetch_apps)
    apps=$(parse_apps "$raw")
    apps=$(apply_filters "$apps")
    stats=$(compute_stats "$apps")
    oos=$(echo "$stats" | jq -r .outOfSync)
    progressing=$(echo "$stats" | jq -r .progressing)

    if [[ "$oos" -eq 0 && "$progressing" -eq 0 ]]; then
      echo "All applications synced and healthy (${elapsed}s elapsed)"
      return 0
    fi

    printf "\r  [%3ds] Waiting... %s out-of-sync, %s progressing  " "$elapsed" "$oos" "$progressing"
    sleep 5
  done
}

# ─── Main ──────────────────────────────────────────────────────────────────

if [[ "$WAIT" == "true" ]]; then
  do_wait
  wait_result=$?
fi

RAW=$(fetch_apps)
APPS=$(parse_apps "$RAW")
APPS=$(apply_filters "$APPS")
STATS=$(compute_stats "$APPS")

APP_COUNT=$(echo "$APPS" | jq 'length')
if [[ "$APP_COUNT" -eq 0 ]]; then
  echo "No applications found matching filters."
  exit 0
fi

case "$OUTPUT" in
  table) output_table "$APPS" "$STATS" ;;
  json)  output_json "$APPS" "$STATS" ;;
  brief) output_brief "$STATS" ;;
esac

# ─── Exit code ──────────────────────────────────────────────────────────────

if [[ "$EXIT_CODE" == "true" ]]; then
  oos=$(echo "$STATS" | jq -r .outOfSync)
  failed=$(echo "$STATS" | jq -r .syncFailed)
  degraded=$(echo "$STATS" | jq -r .degraded)

  if [[ "$oos" -gt 0 || "$failed" -gt 0 || "$degraded" -gt 0 ]]; then
    echo >&2
    echo "FAIL: ${oos} out-of-sync, ${failed} failed syncs, ${degraded} degraded" >&2
    exit 1
  fi
fi

exit "${wait_result:-0}"
