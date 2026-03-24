#!/usr/bin/env bash
# =============================================================================
# es-health-check.sh — Elasticsearch cluster health diagnostic
#
# Usage:
#   ./es-health-check.sh [ES_URL] [OPTIONS]
#
# Arguments:
#   ES_URL    Elasticsearch URL (default: http://localhost:9200)
#
# Options:
#   -u USER:PASS    Basic auth credentials
#   -k KEY          API key (base64 encoded)
#   --insecure      Skip TLS verification
#   -v              Verbose output (include full JSON responses)
#
# Examples:
#   ./es-health-check.sh
#   ./es-health-check.sh https://es.example.com:9200 -u elastic:changeme
#   ./es-health-check.sh https://es.example.com:9200 -k "base64apikey"
# =============================================================================

set -euo pipefail

ES_URL="${1:-http://localhost:9200}"
# Remove trailing slash
ES_URL="${ES_URL%/}"

shift 2>/dev/null || true

AUTH_ARGS=()
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) AUTH_ARGS+=("-u" "$2"); shift 2 ;;
    -k) AUTH_ARGS+=("-H" "Authorization: ApiKey $2"); shift 2 ;;
    --insecure) AUTH_ARGS+=("-k"); shift ;;
    -v) VERBOSE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

CURL_OPTS=(-s -S --connect-timeout 5 --max-time 30)

es_get() {
  local path="$1"
  curl "${CURL_OPTS[@]}" "${AUTH_ARGS[@]}" "${ES_URL}${path}" 2>/dev/null
}

es_get_text() {
  local path="$1"
  curl "${CURL_OPTS[@]}" "${AUTH_ARGS[@]}" -H "Accept: text/plain" "${ES_URL}${path}" 2>/dev/null
}

print_header() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

print_ok()   { echo "  ✅ $1"; }
print_warn() { echo "  ⚠️  $1"; }
print_err()  { echo "  ❌ $1"; }

# --- Connectivity ---
print_header "CONNECTIVITY"
if ! CLUSTER_INFO=$(es_get "/"); then
  print_err "Cannot connect to ${ES_URL}"
  exit 1
fi
CLUSTER_NAME=$(echo "$CLUSTER_INFO" | grep -o '"cluster_name" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
VERSION=$(echo "$CLUSTER_INFO" | grep -o '"number" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
print_ok "Connected to cluster '${CLUSTER_NAME}' (ES ${VERSION})"

# --- Cluster Health ---
print_header "CLUSTER HEALTH"
HEALTH=$(es_get "/_cluster/health")
STATUS=$(echo "$HEALTH" | grep -o '"status" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
NODE_COUNT=$(echo "$HEALTH" | grep -o '"number_of_nodes" *: *[0-9]*' | head -1 | grep -o '[0-9]*$')
DATA_NODES=$(echo "$HEALTH" | grep -o '"number_of_data_nodes" *: *[0-9]*' | head -1 | grep -o '[0-9]*$')
ACTIVE_SHARDS=$(echo "$HEALTH" | grep -o '"active_shards" *: *[0-9]*' | head -1 | grep -o '[0-9]*$')
UNASSIGNED=$(echo "$HEALTH" | grep -o '"unassigned_shards" *: *[0-9]*' | head -1 | grep -o '[0-9]*$')
RELOCATING=$(echo "$HEALTH" | grep -o '"relocating_shards" *: *[0-9]*' | head -1 | grep -o '[0-9]*$')
INITIALIZING=$(echo "$HEALTH" | grep -o '"initializing_shards" *: *[0-9]*' | head -1 | grep -o '[0-9]*$')
PENDING=$(echo "$HEALTH" | grep -o '"number_of_pending_tasks" *: *[0-9]*' | head -1 | grep -o '[0-9]*$')

case "$STATUS" in
  green)  print_ok  "Status: GREEN" ;;
  yellow) print_warn "Status: YELLOW (replicas unassigned)" ;;
  red)    print_err  "Status: RED (primary shards missing!)" ;;
  *)      print_err  "Status: UNKNOWN ($STATUS)" ;;
esac

echo "  Nodes: ${NODE_COUNT} total, ${DATA_NODES} data"
echo "  Shards: ${ACTIVE_SHARDS} active, ${UNASSIGNED} unassigned, ${RELOCATING} relocating, ${INITIALIZING} initializing"
echo "  Pending tasks: ${PENDING}"

if [[ "$UNASSIGNED" -gt 0 ]]; then
  print_warn "Unassigned shards detected. Run: GET _cluster/allocation/explain"
fi

# --- Node Status ---
print_header "NODE STATUS"
NODES=$(es_get_text "/_cat/nodes?v&h=name,role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent,segments.count&s=name")
echo "$NODES"

# Check for concerning nodes
echo ""
while IFS= read -r line; do
  [[ "$line" == name* ]] && continue
  [[ -z "$line" ]] && continue
  NODE_NAME=$(echo "$line" | awk '{print $1}')
  HEAP=$(echo "$line" | awk '{print $3}')
  CPU=$(echo "$line" | awk '{print $5}')
  DISK=$(echo "$line" | awk '{print $7}')

  if [[ -n "$HEAP" && "$HEAP" =~ ^[0-9]+$ && "$HEAP" -gt 85 ]]; then
    print_warn "Node '${NODE_NAME}': heap at ${HEAP}% (>85%)"
  fi
  if [[ -n "$CPU" && "$CPU" =~ ^[0-9]+$ && "$CPU" -gt 90 ]]; then
    print_warn "Node '${NODE_NAME}': CPU at ${CPU}% (>90%)"
  fi
  if [[ -n "$DISK" && "$DISK" =~ ^[0-9.]+$ ]]; then
    DISK_INT=${DISK%.*}
    if [[ "$DISK_INT" -gt 85 ]]; then
      print_err "Node '${NODE_NAME}': disk at ${DISK}% (>85% — approaching watermark!)"
    elif [[ "$DISK_INT" -gt 75 ]]; then
      print_warn "Node '${NODE_NAME}': disk at ${DISK}% (>75%)"
    fi
  fi
done <<< "$NODES"

# --- Disk Allocation ---
print_header "DISK ALLOCATION"
es_get_text "/_cat/allocation?v&s=disk.percent:desc"

# --- Shard Distribution ---
print_header "LARGEST INDICES (top 15)"
es_get_text "/_cat/indices?v&s=store.size:desc&h=index,health,pri,rep,docs.count,store.size&bytes=gb" | head -16

# --- Unassigned Shards ---
if [[ "$UNASSIGNED" -gt 0 ]]; then
  print_header "UNASSIGNED SHARDS"
  es_get_text "/_cat/shards?v&h=index,shard,prirep,state,unassigned.reason&s=state" | grep -E "^index|UNASSIGNED" | head -20
fi

# --- Pending Tasks ---
if [[ "$PENDING" -gt 0 ]]; then
  print_header "PENDING TASKS"
  es_get "/_cluster/pending_tasks" | head -50
fi

# --- Thread Pool (rejections) ---
print_header "THREAD POOL REJECTIONS"
THREAD_POOL=$(es_get_text "/_cat/thread_pool?v&h=node_name,name,active,queue,rejected&s=rejected:desc" | head -20)
echo "$THREAD_POOL"

REJECTIONS=$(echo "$THREAD_POOL" | awk 'NR>1 && $5 > 0 {print $1, $2, "rejected="$5}')
if [[ -n "$REJECTIONS" ]]; then
  echo ""
  print_warn "Thread pool rejections found:"
  echo "$REJECTIONS" | while read -r line; do echo "    $line"; done
fi

# --- Summary ---
print_header "SUMMARY"
ISSUES=0
[[ "$STATUS" != "green" ]] && ((ISSUES++))
[[ "$UNASSIGNED" -gt 0 ]] && ((ISSUES++))
[[ "$PENDING" -gt 5 ]] && ((ISSUES++))

if [[ "$ISSUES" -eq 0 ]]; then
  print_ok "Cluster looks healthy!"
else
  print_warn "${ISSUES} issue(s) detected. Review output above."
fi

echo ""
echo "Checked at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Target: ${ES_URL}"
echo ""
