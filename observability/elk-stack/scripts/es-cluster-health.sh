#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# es-cluster-health.sh
#
# Checks and displays Elasticsearch cluster health information including
# node status, shard allocation, disk and JVM usage, index statistics,
# and pending tasks. Output is color-coded by severity.
#
# Prerequisites:
#   - curl
#   - jq
#
# Usage:
#   ./es-cluster-health.sh
#   ./es-cluster-health.sh --url https://localhost:9200 --user elastic --password secret
#   ./es-cluster-health.sh --help
#
# Flags:
#   --url        Elasticsearch URL (default: http://localhost:9200)
#   --user       Username for authentication (optional)
#   --password   Password for authentication (optional)
#   --help       Show this help message
###############################################################################

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
ES_URL="http://localhost:9200"
ES_USER=""
ES_PASSWORD=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { printf "${RED}ERROR: %s${RESET}\n" "$*" >&2; exit 1; }

usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo ""
    echo "Check Elasticsearch cluster health and display diagnostics."
    echo ""
    echo "Options:"
    echo "  --url        Elasticsearch URL (default: http://localhost:9200)"
    echo "  --user       Username for authentication"
    echo "  --password   Password for authentication"
    echo "  --help       Show this help message"
    exit 0
}

check_dependencies() {
    command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
    command -v jq   >/dev/null 2>&1 || die "jq is required but not installed."
}

# Build the curl argument array once so every call reuses it.
build_curl_args() {
    CURL_ARGS=(-s -S --max-time 10)
    if [[ -n "$ES_USER" && -n "$ES_PASSWORD" ]]; then
        CURL_ARGS+=(-u "${ES_USER}:${ES_PASSWORD}")
    fi
    # Accept self-signed certs when talking to https endpoints
    if [[ "$ES_URL" == https://* ]]; then
        CURL_ARGS+=(--cacert /dev/null -k)
    fi
}

es_get() {
    local path="$1"
    local response
    if ! response=$(curl "${CURL_ARGS[@]}" "${ES_URL}${path}" 2>&1); then
        die "Failed to reach Elasticsearch at ${ES_URL}${path}: ${response}"
    fi
    echo "$response"
}

# Map status text to a colour
status_color() {
    case "$1" in
        green)  echo -e "${GREEN}${1}${RESET}" ;;
        yellow) echo -e "${YELLOW}${1}${RESET}" ;;
        red)    echo -e "${RED}${1}${RESET}" ;;
        *)      echo "$1" ;;
    esac
}

section() {
    echo ""
    printf "${CYAN}${BOLD}── %s ─────────────────────────────────────────────${RESET}\n" "$1"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                ES_URL="${2:?'--url requires a value'}"
                shift 2
                ;;
            --user)
                ES_USER="${2:?'--user requires a value'}"
                shift 2
                ;;
            --password)
                ES_PASSWORD="${2:?'--password requires a value'}"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Display functions
# ---------------------------------------------------------------------------
show_cluster_health() {
    section "Cluster Health"

    local health
    health=$(es_get "/_cluster/health")

    local cluster_name status num_nodes num_data_nodes
    cluster_name=$(echo "$health" | jq -r '.cluster_name')
    status=$(echo "$health" | jq -r '.status')
    num_nodes=$(echo "$health" | jq -r '.number_of_nodes')
    num_data_nodes=$(echo "$health" | jq -r '.number_of_data_nodes')

    printf "  Cluster Name   : ${BOLD}%s${RESET}\n" "$cluster_name"
    printf "  Status         : %b\n" "$(status_color "$status")"
    printf "  Nodes          : %s  (data: %s)\n" "$num_nodes" "$num_data_nodes"
}

show_shard_allocation() {
    section "Shard Allocation"

    local health
    health=$(es_get "/_cluster/health")

    local active relocating initializing unassigned
    active=$(echo "$health" | jq -r '.active_shards')
    relocating=$(echo "$health" | jq -r '.relocating_shards')
    initializing=$(echo "$health" | jq -r '.initializing_shards')
    unassigned=$(echo "$health" | jq -r '.unassigned_shards')

    printf "  Active         : ${GREEN}%s${RESET}\n" "$active"
    printf "  Relocating     : %s\n" "$relocating"
    printf "  Initializing   : %s\n" "$initializing"

    if [[ "$unassigned" -gt 0 ]]; then
        printf "  Unassigned     : ${RED}%s${RESET}\n" "$unassigned"
    else
        printf "  Unassigned     : ${GREEN}%s${RESET}\n" "$unassigned"
    fi
}

show_node_info() {
    section "Nodes & Roles"

    local nodes
    nodes=$(es_get "/_cat/nodes?format=json&h=name,node.role,master,ip")

    echo "$nodes" | jq -r '
        .[] | "  \(.name)  roles=\(.["node.role"])  master=\(.master)  ip=\(.ip)"
    '
}

show_disk_usage() {
    section "Disk Usage (per node)"

    local alloc
    alloc=$(es_get "/_cat/allocation?format=json&h=node,disk.total,disk.used,disk.avail,disk.percent&bytes=b")

    printf "  ${BOLD}%-20s %12s %12s %12s %8s${RESET}\n" "Node" "Total" "Used" "Available" "Use%"

    echo "$alloc" | jq -r '.[] | "\(.node)|\(.["disk.total"])|\(.["disk.used"])|\(.["disk.avail"])|\(.["disk.percent"])"' \
    | while IFS='|' read -r node total used avail pct; do
        # Convert bytes to human-readable
        h_total=$(numfmt --to=iec-i --suffix=B "$total" 2>/dev/null || echo "$total")
        h_used=$(numfmt --to=iec-i --suffix=B "$used" 2>/dev/null || echo "$used")
        h_avail=$(numfmt --to=iec-i --suffix=B "$avail" 2>/dev/null || echo "$avail")

        local color="$GREEN"
        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            [[ "$pct" -ge 80 ]] && color="$YELLOW"
            [[ "$pct" -ge 90 ]] && color="$RED"
        fi

        printf "  %-20s %12s %12s %12s ${color}%7s%%${RESET}\n" \
            "$node" "$h_total" "$h_used" "$h_avail" "$pct"
    done
}

show_jvm_usage() {
    section "JVM Heap Usage (per node)"

    local jvm
    jvm=$(es_get "/_nodes/stats/jvm")

    printf "  ${BOLD}%-20s %12s %12s %8s${RESET}\n" "Node" "Heap Used" "Heap Max" "Use%"

    echo "$jvm" | jq -r '
        .nodes | to_entries[] |
        "\(.value.name)|\(.value.jvm.mem.heap_used_in_bytes)|\(.value.jvm.mem.heap_max_in_bytes)|\(.value.jvm.mem.heap_used_percent)"
    ' | while IFS='|' read -r name used max pct; do
        h_used=$(numfmt --to=iec-i --suffix=B "$used" 2>/dev/null || echo "$used")
        h_max=$(numfmt --to=iec-i --suffix=B "$max" 2>/dev/null || echo "$max")

        local color="$GREEN"
        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            [[ "$pct" -ge 75 ]] && color="$YELLOW"
            [[ "$pct" -ge 90 ]] && color="$RED"
        fi

        printf "  %-20s %12s %12s ${color}%7s%%${RESET}\n" "$name" "$h_used" "$h_max" "$pct"
    done
}

show_index_stats() {
    section "Index & Document Counts"

    local stats
    stats=$(es_get "/_cluster/stats")

    local index_count doc_count store_size
    index_count=$(echo "$stats" | jq -r '.indices.count')
    doc_count=$(echo "$stats" | jq -r '.indices.docs.count')
    store_size=$(echo "$stats" | jq -r '.indices.store.size_in_bytes')

    h_store=$(numfmt --to=iec-i --suffix=B "$store_size" 2>/dev/null || echo "$store_size")

    printf "  Indices          : %s\n" "$index_count"
    printf "  Documents        : %s\n" "$doc_count"
    printf "  Total Store Size : %s\n" "$h_store"
}

show_pending_tasks() {
    section "Pending Cluster Tasks"

    local tasks
    tasks=$(es_get "/_cluster/pending_tasks")

    local count
    count=$(echo "$tasks" | jq '.tasks | length')

    if [[ "$count" -eq 0 ]]; then
        printf "  ${GREEN}No pending tasks${RESET}\n"
    else
        printf "  ${YELLOW}%s pending task(s):${RESET}\n" "$count"
        echo "$tasks" | jq -r '.tasks[] | "    [\(.priority)] \(.source) (inserted \(.time_in_queue))"'
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_dependencies
    build_curl_args

    echo ""
    printf "${BOLD}Elasticsearch Cluster Health Report${RESET}\n"
    printf "Target: ${CYAN}%s${RESET}\n" "$ES_URL"
    printf "Time  : %s\n" "$(date +'%Y-%m-%dT%H:%M:%S%z')"

    show_cluster_health
    show_shard_allocation
    show_node_info
    show_disk_usage
    show_jvm_usage
    show_index_stats
    show_pending_tasks

    echo ""
    printf "${BOLD}── Done ──────────────────────────────────────────────${RESET}\n\n"
}

main "$@"
