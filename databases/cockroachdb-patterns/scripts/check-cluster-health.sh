#!/usr/bin/env bash
#
# check-cluster-health.sh
# Checks CockroachDB cluster health: node status, range distribution,
# replication status, hotspot detection, and license info.
#
# Usage: ./check-cluster-health.sh [--host HOST] [--port PORT] [--insecure]
#
# Examples:
#   ./check-cluster-health.sh --insecure
#   ./check-cluster-health.sh --host crdb.example.com --port 26257
#   ./check-cluster-health.sh --host localhost --insecure

set -euo pipefail

HOST="localhost"
PORT="26257"
INSECURE_FLAG=""
CERTS_DIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_header() { echo -e "\n${BLUE}=== $* ===${NC}"; }
log_ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail()   { echo -e "${RED}[FAIL]${NC}  $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       HOST="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --insecure)   INSECURE_FLAG="--insecure"; shift ;;
        --certs-dir)  CERTS_DIR="--certs-dir=$2"; shift 2 ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

CONN_FLAGS="${INSECURE_FLAG} ${CERTS_DIR} --host=${HOST}:${PORT}"

run_sql() {
    cockroach sql ${CONN_FLAGS} --format=table -e "$1" 2>/dev/null
}

run_sql_raw() {
    cockroach sql ${CONN_FLAGS} --format=csv -e "$1" 2>/dev/null
}

check_connectivity() {
    log_header "Connectivity Check"
    if run_sql "SELECT 1 AS connected;" &>/dev/null; then
        log_ok "Successfully connected to ${HOST}:${PORT}"
    else
        log_fail "Cannot connect to ${HOST}:${PORT}"
        echo "Ensure CockroachDB is running and connection flags are correct."
        exit 1
    fi
}

check_node_status() {
    log_header "Node Status"
    cockroach node status ${CONN_FLAGS} --format=table 2>/dev/null || {
        log_fail "Could not retrieve node status"
        return 1
    }

    local total_nodes live_nodes
    total_nodes=$(run_sql_raw "SELECT count(*) FROM crdb_internal.gossip_nodes;" | tail -1)
    live_nodes=$(run_sql_raw "SELECT count(*) FROM crdb_internal.gossip_nodes WHERE expiration > now();" | tail -1)

    echo ""
    if [[ "${total_nodes}" == "${live_nodes}" ]]; then
        log_ok "All ${total_nodes} nodes are live"
    else
        log_warn "${live_nodes}/${total_nodes} nodes are live"
    fi
}

check_cluster_version() {
    log_header "Cluster Version"
    run_sql "SELECT crdb_internal.node_executable_version() AS version;"
}

check_range_distribution() {
    log_header "Range Distribution"
    run_sql "
        SELECT
            lease_holder AS node,
            count(*) AS ranges,
            round(avg(range_size_mb)::NUMERIC, 2) AS avg_range_mb
        FROM crdb_internal.ranges
        GROUP BY lease_holder
        ORDER BY lease_holder;
    "

    local total_ranges
    total_ranges=$(run_sql_raw "SELECT count(*) FROM crdb_internal.ranges;" | tail -1)
    echo "Total ranges: ${total_ranges}"
}

check_replication_status() {
    log_header "Replication Status"

    local under_replicated over_replicated unavailable
    under_replicated=$(run_sql_raw "
        SELECT count(*) FROM crdb_internal.ranges
        WHERE array_length(replicas, 1) < 3;
    " | tail -1)

    over_replicated=$(run_sql_raw "
        SELECT count(*) FROM crdb_internal.ranges
        WHERE array_length(replicas, 1) > 3;
    " | tail -1)

    unavailable=$(run_sql_raw "
        SELECT count(*) FROM crdb_internal.ranges
        WHERE array_length(replicas, 1) = 0;
    " | tail -1)

    if [[ "${under_replicated}" == "0" ]]; then
        log_ok "No under-replicated ranges"
    else
        log_warn "${under_replicated} under-replicated ranges"
    fi

    if [[ "${over_replicated}" == "0" ]]; then
        log_ok "No over-replicated ranges"
    else
        log_warn "${over_replicated} over-replicated ranges"
    fi

    if [[ "${unavailable}" == "0" ]]; then
        log_ok "No unavailable ranges"
    else
        log_fail "${unavailable} unavailable ranges!"
    fi
}

check_hotspots() {
    log_header "Hotspot Detection (Top 10 by QPS)"
    run_sql "
        SELECT
            range_id,
            table_name,
            index_name,
            queries_per_second,
            lease_holder
        FROM crdb_internal.ranges
        ORDER BY queries_per_second DESC
        LIMIT 10;
    " 2>/dev/null || log_warn "Could not retrieve hotspot data"
}

check_contention() {
    log_header "Contention Events (Top 10)"
    run_sql "
        SELECT
            table_id,
            index_id,
            count AS events,
            key
        FROM crdb_internal.cluster_contention_events
        ORDER BY count DESC
        LIMIT 10;
    " 2>/dev/null || log_ok "No contention events found"
}

check_jobs() {
    log_header "Active Jobs"
    run_sql "
        SELECT
            job_id,
            job_type,
            status,
            description,
            fraction_completed
        FROM [SHOW JOBS]
        WHERE status IN ('running', 'paused', 'pending')
        ORDER BY created DESC
        LIMIT 10;
    " 2>/dev/null || log_ok "No active jobs"
}

check_storage() {
    log_header "Storage Usage"
    run_sql "
        SELECT
            node_id,
            store_id,
            pg_size_pretty(used::BIGINT) AS used,
            pg_size_pretty(available::BIGINT) AS available,
            pg_size_pretty(capacity::BIGINT) AS capacity,
            round((used::FLOAT / capacity::FLOAT * 100)::NUMERIC, 1) AS pct_used
        FROM crdb_internal.kv_store_status
        ORDER BY node_id;
    " 2>/dev/null || log_warn "Could not retrieve storage data"
}

check_license() {
    log_header "License Information"
    run_sql "SHOW CLUSTER SETTING enterprise.license;" 2>/dev/null || true
    run_sql "SHOW CLUSTER SETTING cluster.organization;" 2>/dev/null || true
}

check_clock_offsets() {
    log_header "Clock Offsets"
    run_sql "
        SELECT
            node_id,
            address,
            round((metrics->>'clock-offset.meannanos')::FLOAT / 1e6, 2) AS offset_ms,
            round((metrics->>'clock-offset.stddevnanos')::FLOAT / 1e6, 2) AS stddev_ms
        FROM crdb_internal.gossip_nodes
        ORDER BY node_id;
    " 2>/dev/null || log_warn "Could not retrieve clock offset data"
}

main() {
    echo "============================================"
    echo " CockroachDB Cluster Health Check"
    echo "============================================"
    echo "Target: ${HOST}:${PORT}"

    check_connectivity
    check_cluster_version
    check_node_status
    check_range_distribution
    check_replication_status
    check_hotspots
    check_contention
    check_storage
    check_clock_offsets
    check_jobs
    check_license

    log_header "Health Check Complete"
    echo ""
}

main
