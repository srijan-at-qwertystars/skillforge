#!/usr/bin/env bash
set -euo pipefail

# rabbitmq-health-check.sh — Comprehensive RabbitMQ health check
# Usage: ./rabbitmq-health-check.sh [--api URL] [--user USER] [--pass PASS] [--json]
#
# Supports two modes:
#   1. CLI mode (rabbitmqctl) — run directly on a RabbitMQ node
#   2. API mode (HTTP management API) — run remotely

API_URL="${RABBITMQ_API_URL:-http://localhost:15672}"
API_USER="${RABBITMQ_USER:-guest}"
API_PASS="${RABBITMQ_PASS:-guest}"
OUTPUT_JSON=false
USE_API=false
EXIT_CODE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Comprehensive RabbitMQ health check.

Options:
  --api <url>      Management API URL (default: http://localhost:15672)
  --user <user>    API username (default: guest, or \$RABBITMQ_USER)
  --pass <pass>    API password (default: guest, or \$RABBITMQ_PASS)
  --remote         Force API mode (don't try rabbitmqctl)
  --json           Output results as JSON
  -h, --help       Show this help

Environment variables:
  RABBITMQ_API_URL   Management API URL
  RABBITMQ_USER      API username
  RABBITMQ_PASS      API password

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --api)    API_URL="$2"; USE_API=true; shift 2 ;;
        --user)   API_USER="$2"; shift 2 ;;
        --pass)   API_PASS="$2"; shift 2 ;;
        --remote) USE_API=true; shift ;;
        --json)   OUTPUT_JSON=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *)        echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Detect mode
if [[ "${USE_API}" == "false" ]] && command -v rabbitmqctl &>/dev/null; then
    MODE="cli"
else
    MODE="api"
fi

print_header() { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "\n${YELLOW}=== $1 ===${NC}"; }
print_ok()     { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "  ${GREEN}✓${NC} $1"; }
print_warn()   { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "  ${YELLOW}⚠${NC} $1"; }
print_fail()   { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "  ${RED}✗${NC} $1"; EXIT_CODE=1; }
print_info()   { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "  $1"; }

api_get() {
    curl -sf -u "${API_USER}:${API_PASS}" "${API_URL}/api/$1" 2>/dev/null
}

# ─── Node Status ───
check_node_status() {
    print_header "Node Status"

    if [[ "${MODE}" == "cli" ]]; then
        if rabbitmq-diagnostics check_running &>/dev/null; then
            print_ok "Node is running"
        else
            print_fail "Node is NOT running"
            return
        fi

        local version
        version=$(rabbitmqctl eval 'rabbit_misc:version().' 2>/dev/null | tr -d '"')
        print_info "Version: ${version}"

        local uptime
        uptime=$(rabbitmqctl eval '{Total, _} = statistics(wall_clock), Total div 1000.' 2>/dev/null)
        if [[ -n "${uptime}" ]]; then
            local days=$((uptime / 86400))
            local hours=$(( (uptime % 86400) / 3600 ))
            print_info "Uptime: ${days}d ${hours}h"
        fi
    else
        local node_data
        node_data=$(api_get "overview" 2>/dev/null)
        if [[ -z "${node_data}" ]]; then
            print_fail "Cannot reach management API at ${API_URL}"
            return
        fi
        local version
        version=$(echo "${node_data}" | python3 -c "import sys,json; print(json.load(sys.stdin)['rabbitmq_version'])" 2>/dev/null)
        print_ok "Management API reachable"
        print_info "Version: ${version}"
    fi
}

# ─── Cluster State ───
check_cluster() {
    print_header "Cluster State"

    if [[ "${MODE}" == "cli" ]]; then
        local cluster_info
        cluster_info=$(rabbitmqctl cluster_status --formatter=json 2>/dev/null)
        local running
        running=$(echo "${cluster_info}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('running_nodes', d.get('nodes', {}).get('disc', []))))" 2>/dev/null || echo "?")
        print_info "Running nodes: ${running}"

        # Check for partitions
        local partitions
        partitions=$(echo "${cluster_info}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = d.get('partitions', {})
if isinstance(p, dict):
    total = sum(len(v) for v in p.values())
else:
    total = len(p) if p else 0
print(total)
" 2>/dev/null || echo "0")

        if [[ "${partitions}" == "0" ]]; then
            print_ok "No network partitions"
        else
            print_fail "Network partitions detected!"
        fi
    else
        local nodes
        nodes=$(api_get "nodes")
        if [[ -n "${nodes}" ]]; then
            echo "${nodes}" | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
running = [n for n in nodes if n.get('running', False)]
print(f'  Running nodes: {len(running)}/{len(nodes)}')
for n in nodes:
    status = '✓' if n.get('running') else '✗'
    print(f\"    {status} {n['name']} - {n.get('type', 'disc')}\")
" 2>/dev/null
            local partition_count
            partition_count=$(echo "${nodes}" | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
total = sum(len(n.get('partitions', [])) for n in nodes)
print(total)
" 2>/dev/null || echo "0")
            if [[ "${partition_count}" == "0" ]]; then
                print_ok "No network partitions"
            else
                print_fail "Network partitions detected!"
            fi
        fi
    fi
}

# ─── Memory & Disk ───
check_resources() {
    print_header "Memory & Disk"

    if [[ "${MODE}" == "api" ]]; then
        local nodes
        nodes=$(api_get "nodes")
        if [[ -n "${nodes}" ]]; then
            echo "${nodes}" | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    name = n['name']
    mem_used = n.get('mem_used', 0) / (1024**3)
    mem_limit = n.get('mem_limit', 0) / (1024**3)
    mem_pct = (n.get('mem_used', 0) / n.get('mem_limit', 1)) * 100
    disk_free = n.get('disk_free', 0) / (1024**3)
    disk_limit = n.get('disk_free_limit', 0) / (1024**3)
    fd_used = n.get('fd_used', 0)
    fd_total = n.get('fd_total', 0)
    procs = n.get('proc_used', 0)
    proc_total = n.get('proc_total', 0)

    print(f'  {name}:')
    print(f'    Memory: {mem_used:.2f} GB / {mem_limit:.2f} GB ({mem_pct:.1f}%)')
    print(f'    Disk free: {disk_free:.2f} GB (limit: {disk_limit:.2f} GB)')
    print(f'    File descriptors: {fd_used}/{fd_total}')
    print(f'    Erlang processes: {procs}/{proc_total}')
" 2>/dev/null
        fi
    else
        rabbitmqctl status 2>/dev/null | grep -A 10 "Memory" | head -12
    fi
}

# ─── Alarms ───
check_alarms() {
    print_header "Alarms"

    if [[ "${MODE}" == "api" ]]; then
        local health
        health=$(api_get "health/checks/alarms" 2>/dev/null)
        local status
        status=$(echo "${health}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
        if [[ "${status}" == "ok" ]]; then
            print_ok "No alarms active"
        else
            print_fail "Alarms active!"
            echo "${health}" | python3 -m json.tool 2>/dev/null
        fi
    else
        if rabbitmq-diagnostics check_local_alarms &>/dev/null; then
            print_ok "No local alarms"
        else
            print_fail "Local alarms active!"
        fi
    fi
}

# ─── Queue Depths ───
check_queues() {
    print_header "Queue Depths (top 15)"

    if [[ "${MODE}" == "api" ]]; then
        local queues
        queues=$(api_get "queues" 2>/dev/null)
        if [[ -n "${queues}" ]]; then
            echo "${queues}" | python3 -c "
import sys, json
queues = sorted(json.load(sys.stdin), key=lambda q: q.get('messages', 0), reverse=True)[:15]
if not queues:
    print('  No queues found')
else:
    print(f'  {\"Queue\":<40} {\"Ready\":>8} {\"Unacked\":>8} {\"Total\":>8} {\"Consumers\":>10} {\"Type\":<8}')
    print(f'  {\"-\"*40} {\"-\"*8} {\"-\"*8} {\"-\"*8} {\"-\"*10} {\"-\"*8}')
    for q in queues:
        name = q['name'][:40]
        ready = q.get('messages_ready', 0)
        unacked = q.get('messages_unacknowledged', 0)
        total = q.get('messages', 0)
        consumers = q.get('consumers', 0)
        qtype = q.get('type', 'classic')
        print(f'  {name:<40} {ready:>8} {unacked:>8} {total:>8} {consumers:>10} {qtype:<8}')
" 2>/dev/null
        fi
    else
        rabbitmqctl list_queues name messages_ready messages_unacknowledged messages consumers type 2>/dev/null | \
            sort -t$'\t' -k4 -rn | head -15
    fi
}

# ─── Consumer Status ───
check_consumers() {
    print_header "Consumer Summary"

    if [[ "${MODE}" == "api" ]]; then
        local queues
        queues=$(api_get "queues" 2>/dev/null)
        if [[ -n "${queues}" ]]; then
            echo "${queues}" | python3 -c "
import sys, json
queues = json.load(sys.stdin)
total_consumers = sum(q.get('consumers', 0) for q in queues)
queues_without_consumers = [q['name'] for q in queues if q.get('consumers', 0) == 0 and q.get('messages', 0) > 0]
print(f'  Total consumers: {total_consumers}')
print(f'  Total queues: {len(queues)}')
if queues_without_consumers:
    print(f'  ⚠ Queues with messages but no consumers ({len(queues_without_consumers)}):')
    for name in queues_without_consumers[:10]:
        print(f'    - {name}')
    if len(queues_without_consumers) > 10:
        print(f'    ... and {len(queues_without_consumers) - 10} more')
else:
    print('  ✓ All queues with messages have consumers')
" 2>/dev/null
        fi
    else
        local consumer_count
        consumer_count=$(rabbitmqctl list_consumers 2>/dev/null | wc -l)
        print_info "Total consumers: ${consumer_count}"
    fi
}

# ─── Connection Summary ───
check_connections() {
    print_header "Connections"

    if [[ "${MODE}" == "api" ]]; then
        local overview
        overview=$(api_get "overview" 2>/dev/null)
        if [[ -n "${overview}" ]]; then
            echo "${overview}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
obj = data.get('object_totals', {})
print(f\"  Connections: {obj.get('connections', 'N/A')}\")
print(f\"  Channels:    {obj.get('channels', 'N/A')}\")
print(f\"  Queues:      {obj.get('queues', 'N/A')}\")
print(f\"  Exchanges:   {obj.get('exchanges', 'N/A')}\")
print(f\"  Consumers:   {obj.get('consumers', 'N/A')}\")
rates = data.get('message_stats', {})
pub_rate = rates.get('publish_details', {}).get('rate', 0)
del_rate = rates.get('deliver_get_details', {}).get('rate', 0)
ack_rate = rates.get('ack_details', {}).get('rate', 0)
print(f\"  Publish rate:  {pub_rate:.1f} msg/s\")
print(f\"  Deliver rate:  {del_rate:.1f} msg/s\")
print(f\"  Ack rate:      {ack_rate:.1f} msg/s\")
" 2>/dev/null
        fi
    else
        local conn_count
        conn_count=$(rabbitmqctl list_connections 2>/dev/null | wc -l)
        local chan_count
        chan_count=$(rabbitmqctl list_channels 2>/dev/null | wc -l)
        print_info "Connections: ${conn_count}"
        print_info "Channels:    ${chan_count}"
    fi
}

# ─── Run all checks ───
main() {
    if [[ "${OUTPUT_JSON}" == "false" ]]; then
        echo -e "${GREEN}RabbitMQ Health Check${NC}"
        echo "Mode: ${MODE} | Target: ${API_URL}"
        echo "Time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi

    check_node_status
    check_cluster
    check_resources
    check_alarms
    check_queues
    check_consumers
    check_connections

    if [[ "${OUTPUT_JSON}" == "false" ]]; then
        echo ""
        if [[ ${EXIT_CODE} -eq 0 ]]; then
            echo -e "${GREEN}Overall: HEALTHY${NC}"
        else
            echo -e "${RED}Overall: UNHEALTHY${NC}"
        fi
    fi

    exit ${EXIT_CODE}
}

main
