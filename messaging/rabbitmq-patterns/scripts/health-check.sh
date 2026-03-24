#!/usr/bin/env bash
#
# health-check.sh — RabbitMQ health check script
# Verifies node status, cluster health, queue depths, and consumer counts
#
set -euo pipefail

# Configuration (override via environment variables)
RABBITMQ_HOST="${RABBITMQ_HOST:-localhost}"
RABBITMQ_MGMT_PORT="${RABBITMQ_MGMT_PORT:-15672}"
RABBITMQ_USER="${RABBITMQ_USER:-admin}"
RABBITMQ_PASS="${RABBITMQ_PASS:-admin_secret}"
RABBITMQ_VHOST="${RABBITMQ_VHOST:-%2F}"
QUEUE_DEPTH_WARN="${QUEUE_DEPTH_WARN:-10000}"
QUEUE_DEPTH_CRIT="${QUEUE_DEPTH_CRIT:-100000}"
UNACKED_WARN="${UNACKED_WARN:-1000}"
UNACKED_CRIT="${UNACKED_CRIT:-10000}"

API_URL="http://${RABBITMQ_HOST}:${RABBITMQ_MGMT_PORT}/api"
EXIT_CODE=0

# Colors and output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; EXIT_CODE=1; }
fail()  { echo -e "  ${RED}✗${NC} $*"; EXIT_CODE=2; }
header(){ echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

api_get() {
    curl -sf --connect-timeout 5 --max-time 10 \
        -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" \
        "${API_URL}$1" 2>/dev/null
}

# -------------------------------------------------------------------
header "Node Status"
# -------------------------------------------------------------------

overview=$(api_get "/overview") || {
    fail "Cannot connect to RabbitMQ management API at ${API_URL}"
    echo ""
    echo "Exit code: 2 (CRITICAL)"
    exit 2
}

rabbitmq_version=$(echo "$overview" | jq -r '.rabbitmq_version // "unknown"')
erlang_version=$(echo "$overview" | jq -r '.erlang_version // "unknown"')
cluster_name=$(echo "$overview" | jq -r '.cluster_name // "unknown"')
pass "Connected to cluster: ${cluster_name}"
pass "RabbitMQ ${rabbitmq_version} / Erlang ${erlang_version}"

# -------------------------------------------------------------------
header "Cluster Health"
# -------------------------------------------------------------------

nodes=$(api_get "/nodes") || { fail "Cannot retrieve node list"; }

total_nodes=$(echo "$nodes" | jq 'length')
running_nodes=$(echo "$nodes" | jq '[.[] | select(.running == true)] | length')

if [ "$running_nodes" -eq "$total_nodes" ]; then
    pass "All nodes running: ${running_nodes}/${total_nodes}"
else
    fail "Nodes down: ${running_nodes}/${total_nodes} running"
    echo "$nodes" | jq -r '.[] | select(.running != true) | "    DOWN: \(.name)"'
fi

# Check for alarms on each node
alarm_count=0
while IFS= read -r node_info; do
    node_name=$(echo "$node_info" | jq -r '.name')
    mem_alarm=$(echo "$node_info" | jq -r '.mem_alarm')
    disk_alarm=$(echo "$node_info" | jq -r '.disk_free_alarm')

    if [ "$mem_alarm" = "true" ]; then
        fail "Memory alarm ACTIVE on ${node_name}"
        alarm_count=$((alarm_count + 1))
    fi
    if [ "$disk_alarm" = "true" ]; then
        fail "Disk alarm ACTIVE on ${node_name}"
        alarm_count=$((alarm_count + 1))
    fi
done < <(echo "$nodes" | jq -c '.[]')

if [ "$alarm_count" -eq 0 ]; then
    pass "No resource alarms active"
fi

# Check node resource usage
while IFS= read -r node_info; do
    node_name=$(echo "$node_info" | jq -r '.name')
    mem_used=$(echo "$node_info" | jq -r '.mem_used // 0')
    mem_limit=$(echo "$node_info" | jq -r '.mem_limit // 1')
    fd_used=$(echo "$node_info" | jq -r '.fd_used // 0')
    fd_total=$(echo "$node_info" | jq -r '.fd_total // 1')
    proc_used=$(echo "$node_info" | jq -r '.proc_used // 0')
    proc_total=$(echo "$node_info" | jq -r '.proc_total // 1')

    if [ "$mem_limit" -gt 0 ]; then
        mem_pct=$((mem_used * 100 / mem_limit))
        if [ "$mem_pct" -gt 90 ]; then
            fail "${node_name}: Memory at ${mem_pct}%"
        elif [ "$mem_pct" -gt 75 ]; then
            warn "${node_name}: Memory at ${mem_pct}%"
        else
            pass "${node_name}: Memory at ${mem_pct}%"
        fi
    fi

    if [ "$fd_total" -gt 0 ]; then
        fd_pct=$((fd_used * 100 / fd_total))
        if [ "$fd_pct" -gt 90 ]; then
            fail "${node_name}: File descriptors at ${fd_pct}% (${fd_used}/${fd_total})"
        elif [ "$fd_pct" -gt 75 ]; then
            warn "${node_name}: File descriptors at ${fd_pct}% (${fd_used}/${fd_total})"
        else
            pass "${node_name}: File descriptors at ${fd_pct}% (${fd_used}/${fd_total})"
        fi
    fi
done < <(echo "$nodes" | jq -c '.[]')

# -------------------------------------------------------------------
header "Connections & Channels"
# -------------------------------------------------------------------

conn_count=$(echo "$overview" | jq '.object_totals.connections // 0')
chan_count=$(echo "$overview" | jq '.object_totals.channels // 0')
pass "Connections: ${conn_count}"
pass "Channels: ${chan_count}"

if [ "$conn_count" -gt 0 ]; then
    chan_per_conn=$((chan_count / conn_count))
    if [ "$chan_per_conn" -gt 50 ]; then
        warn "High channel-to-connection ratio: ${chan_per_conn} (possible channel leak)"
    fi
fi

# -------------------------------------------------------------------
header "Queue Depths"
# -------------------------------------------------------------------

queues=$(api_get "/queues/${RABBITMQ_VHOST}?columns=name,messages,messages_ready,messages_unacknowledged,consumers,state,type") || {
    warn "Cannot retrieve queue list for vhost ${RABBITMQ_VHOST}"
    queues="[]"
}

queue_count=$(echo "$queues" | jq 'length')
pass "Total queues: ${queue_count}"

problem_queues=0
no_consumer_queues=0

while IFS= read -r queue_info; do
    [ -z "$queue_info" ] && continue
    q_name=$(echo "$queue_info" | jq -r '.name')
    q_messages=$(echo "$queue_info" | jq -r '.messages // 0')
    q_ready=$(echo "$queue_info" | jq -r '.messages_ready // 0')
    q_unacked=$(echo "$queue_info" | jq -r '.messages_unacknowledged // 0')
    q_consumers=$(echo "$queue_info" | jq -r '.consumers // 0')
    q_state=$(echo "$queue_info" | jq -r '.state // "unknown"')

    # Check queue state
    if [ "$q_state" != "running" ] && [ "$q_state" != "idle" ]; then
        fail "Queue '${q_name}' in state: ${q_state}"
        problem_queues=$((problem_queues + 1))
    fi

    # Check queue depth
    if [ "$q_messages" -ge "$QUEUE_DEPTH_CRIT" ]; then
        fail "Queue '${q_name}': ${q_messages} messages (CRITICAL threshold: ${QUEUE_DEPTH_CRIT})"
        problem_queues=$((problem_queues + 1))
    elif [ "$q_messages" -ge "$QUEUE_DEPTH_WARN" ]; then
        warn "Queue '${q_name}': ${q_messages} messages (WARN threshold: ${QUEUE_DEPTH_WARN})"
        problem_queues=$((problem_queues + 1))
    fi

    # Check unacked messages
    if [ "$q_unacked" -ge "$UNACKED_CRIT" ]; then
        fail "Queue '${q_name}': ${q_unacked} unacked (CRITICAL threshold: ${UNACKED_CRIT})"
        problem_queues=$((problem_queues + 1))
    elif [ "$q_unacked" -ge "$UNACKED_WARN" ]; then
        warn "Queue '${q_name}': ${q_unacked} unacked (WARN threshold: ${UNACKED_WARN})"
        problem_queues=$((problem_queues + 1))
    fi

    # Check for queues with messages but no consumers
    if [ "$q_messages" -gt 0 ] && [ "$q_consumers" -eq 0 ]; then
        warn "Queue '${q_name}': ${q_messages} messages with 0 consumers"
        no_consumer_queues=$((no_consumer_queues + 1))
    fi
done < <(echo "$queues" | jq -c '.[]')

if [ "$problem_queues" -eq 0 ]; then
    pass "All queue depths within thresholds"
fi

# -------------------------------------------------------------------
header "Consumer Summary"
# -------------------------------------------------------------------

total_consumers=$(echo "$overview" | jq '.object_totals.consumers // 0')
pass "Total consumers: ${total_consumers}"

if [ "$no_consumer_queues" -gt 0 ]; then
    warn "${no_consumer_queues} queue(s) with messages but no consumers"
else
    pass "All queues with messages have consumers"
fi

# -------------------------------------------------------------------
header "Message Rates"
# -------------------------------------------------------------------

publish_rate=$(echo "$overview" | jq '.message_stats.publish_details.rate // 0')
deliver_rate=$(echo "$overview" | jq '.message_stats.deliver_get_details.rate // 0')
ack_rate=$(echo "$overview" | jq '.message_stats.ack_details.rate // 0')

pass "Publish rate:  ${publish_rate} msg/s"
pass "Deliver rate:  ${deliver_rate} msg/s"
pass "Ack rate:      ${ack_rate} msg/s"

# Check if publish rate significantly exceeds delivery rate
if command -v bc > /dev/null 2>&1; then
    if [ "$(echo "$publish_rate > 0 && $deliver_rate > 0" | bc -l)" -eq 1 ]; then
        ratio=$(echo "scale=2; $publish_rate / $deliver_rate" | bc -l)
        if [ "$(echo "$ratio > 2.0" | bc -l)" -eq 1 ]; then
            warn "Publish rate (${publish_rate}/s) is ${ratio}x delivery rate (${deliver_rate}/s) — queues may be growing"
        fi
    fi
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}  HEALTHY — All checks passed${NC}"
elif [ "$EXIT_CODE" -eq 1 ]; then
    echo -e "${YELLOW}  WARNING — Some issues detected${NC}"
else
    echo -e "${RED}  CRITICAL — Immediate attention required${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit "$EXIT_CODE"
