#!/usr/bin/env bash
# envoy-stats-parser.sh — Parse Envoy /stats/prometheus endpoint for key metrics.
#
# Usage:
#   ./envoy-stats-parser.sh [admin-url] [filter]
#
# Examples:
#   ./envoy-stats-parser.sh                                  # defaults to localhost:9901
#   ./envoy-stats-parser.sh http://localhost:9901             # explicit URL
#   ./envoy-stats-parser.sh http://localhost:9901 upstream    # filter by keyword
#   ./envoy-stats-parser.sh http://envoy:9901 my_cluster     # remote Envoy, filter by cluster
#
# Output:
#   Categorized key Envoy metrics: requests, connections, errors, health, circuit breakers.
#
# Requirements:
#   - curl
#   - awk

set -euo pipefail

ADMIN_URL="${1:-http://localhost:9901}"
FILTER="${2:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Remove trailing slash
ADMIN_URL="${ADMIN_URL%/}"

STATS_URL="${ADMIN_URL}/stats/prometheus"

echo -e "${BOLD}Envoy Stats Summary${NC}"
echo -e "${CYAN}Source:${NC} ${STATS_URL}"
echo -e "${CYAN}Filter:${NC} ${FILTER:-<none>}"
echo ""

STATS=$(curl -sf "$STATS_URL" 2>/dev/null) || {
  echo -e "${RED}ERROR:${NC} Failed to fetch stats from $STATS_URL"
  echo "Ensure Envoy admin interface is accessible."
  exit 1
}

if [[ -n "$FILTER" ]]; then
  STATS=$(echo "$STATS" | grep -i "$FILTER" || true)
  if [[ -z "$STATS" ]]; then
    echo -e "${YELLOW}No metrics matched filter '${FILTER}'${NC}"
    exit 0
  fi
fi

print_section() {
  local title="$1"
  echo -e "${BOLD}${CYAN}── ${title} ──${NC}"
}

extract_metric() {
  local pattern="$1"
  local label="${2:-}"
  echo "$STATS" | grep -E "^${pattern}" | grep -v "^#" | while IFS= read -r line; do
    local name value
    name=$(echo "$line" | awk '{print $1}')
    value=$(echo "$line" | awk '{print $2}')
    # Format large numbers
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
      printf "  %-70s %s\n" "$name" "$value"
    elif [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$value" != "0" ]]; then
      printf "  %-70s %s\n" "$name" "$value"
    fi
  done
}

# === Request Metrics ===
print_section "HTTP Request Metrics"
extract_metric "envoy_http_downstream_rq_total"
extract_metric "envoy_http_downstream_rq_[2345]xx"
extract_metric "envoy_http_downstream_rq_active"
echo ""

# === Upstream Cluster Metrics ===
print_section "Upstream Cluster Requests"
extract_metric "envoy_cluster_upstream_rq_total"
extract_metric "envoy_cluster_upstream_rq_[2345]xx"
extract_metric "envoy_cluster_upstream_rq_timeout"
extract_metric "envoy_cluster_upstream_rq_retry"
extract_metric "envoy_cluster_upstream_rq_pending_overflow"
echo ""

# === Connection Metrics ===
print_section "Connection Metrics"
extract_metric "envoy_cluster_upstream_cx_total"
extract_metric "envoy_cluster_upstream_cx_active"
extract_metric "envoy_cluster_upstream_cx_connect_fail"
extract_metric "envoy_cluster_upstream_cx_connect_timeout"
extract_metric "envoy_cluster_upstream_cx_overflow"
extract_metric "envoy_listener_downstream_cx_total"
extract_metric "envoy_listener_downstream_cx_active"
echo ""

# === Health Check Metrics ===
print_section "Health Check Status"
extract_metric "envoy_cluster_health_check_"
extract_metric "envoy_cluster_membership_healthy"
extract_metric "envoy_cluster_membership_total"
extract_metric "envoy_cluster_membership_degraded"
echo ""

# === Circuit Breaker Metrics ===
print_section "Circuit Breaker Status"
extract_metric "envoy_cluster_circuit_breakers_.*_cx_open"
extract_metric "envoy_cluster_circuit_breakers_.*_rq_open"
extract_metric "envoy_cluster_circuit_breakers_.*_rq_pending_open"
extract_metric "envoy_cluster_circuit_breakers_.*_remaining"
echo ""

# === TLS Metrics ===
print_section "TLS / SSL"
extract_metric "envoy_listener_ssl_"
extract_metric "envoy_cluster_ssl_"
echo ""

# === Error Metrics ===
print_section "Errors & Resets"
extract_metric "envoy_cluster_upstream_rq_rx_reset"
extract_metric "envoy_cluster_upstream_rq_tx_reset"
extract_metric "envoy_http_downstream_rq_rx_reset"
extract_metric "envoy_cluster_upstream_flow_control"
echo ""

# === Server Info ===
print_section "Server"
extract_metric "envoy_server_uptime"
extract_metric "envoy_server_memory_allocated"
extract_metric "envoy_server_memory_heap_size"
extract_metric "envoy_server_live"
extract_metric "envoy_server_concurrency"
echo ""

echo -e "${GREEN}Done.${NC} Full stats available at: ${STATS_URL}"
