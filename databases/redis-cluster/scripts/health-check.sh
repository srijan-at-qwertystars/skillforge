#!/usr/bin/env bash
set -euo pipefail

# Redis Cluster Health Check
# Performs comprehensive diagnostics on a running Redis Cluster.
#
# Usage:
#   ./health-check.sh <host>:<port> [OPTIONS]
#
# Options:
#   --password <pass>   AUTH password for the cluster
#   --json              Output results as JSON
#   --verbose           Show detailed per-node information
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more warnings
#   2 - One or more failures
#
# Examples:
#   ./health-check.sh 127.0.0.1:7000
#   ./health-check.sh 10.0.0.5:6379 --password s3cret --verbose
#   ./health-check.sh redis-node:6379 --json

# ── Globals ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; JSON_RESULTS=()

record() {
  local status="$1" check="$2" detail="$3"
  case "$status" in
    PASS) ((PASS_COUNT++)); color="$GREEN" ;;
    WARN) ((WARN_COUNT++)); color="$YELLOW" ;;
    FAIL) ((FAIL_COUNT++)); color="$RED" ;;
  esac
  if [[ "$JSON_OUTPUT" == true ]]; then
    JSON_RESULTS+=("{\"check\":\"${check}\",\"status\":\"${status}\",\"detail\":\"${detail//\"/\\\"}\"}")
  else
    printf "  ${color}[%-4s]${NC} %-30s %s\n" "$status" "$check" "$detail"
  fi
}

# ── Argument parsing ────────────────────────────────────────────────────────
ENTRY_POINT="" ; PASSWORD="" ; JSON_OUTPUT=false ; VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password) PASSWORD="$2"; shift 2 ;;
    --json)     JSON_OUTPUT=true; shift ;;
    --verbose)  VERBOSE=true; shift ;;
    -h|--help)  head -24 "$0" | tail -n +2 | sed 's/^# \?//'; exit 0 ;;
    *)          ENTRY_POINT="$1"; shift ;;
  esac
done

if [[ -z "$ENTRY_POINT" ]]; then
  echo "Error: cluster entry point required. Usage: $0 <host>:<port>" >&2
  exit 2
fi

HOST="${ENTRY_POINT%%:*}"
PORT="${ENTRY_POINT##*:}"

# ── Redis CLI wrapper ───────────────────────────────────────────────────────
rcli() {
  local h="$1" p="$2"; shift 2
  local auth_args=()
  [[ -n "$PASSWORD" ]] && auth_args=(-a "$PASSWORD" --no-auth-warning)
  redis-cli -h "$h" -p "$p" "${auth_args[@]}" "$@" 2>/dev/null
}

# ── Verify connectivity ─────────────────────────────────────────────────────
if ! rcli "$HOST" "$PORT" PING | grep -qi pong; then
  echo -e "${RED}ERROR:${NC} Cannot connect to $ENTRY_POINT" >&2
  exit 2
fi

[[ "$JSON_OUTPUT" != true ]] && echo -e "\n${BOLD}Redis Cluster Health Check — ${ENTRY_POINT}${NC}\n"

# ── Gather cluster info ─────────────────────────────────────────────────────
CLUSTER_INFO=$(rcli "$HOST" "$PORT" CLUSTER INFO)
CLUSTER_NODES=$(rcli "$HOST" "$PORT" CLUSTER NODES)

get_info_field() { echo "$CLUSTER_INFO" | grep -oP "^${1}:\K[^\r]+" || echo ""; }

# Collect all node addresses
declare -a NODE_ADDRS=() NODE_IDS=() NODE_ROLES=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  addr=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
  role="replica"
  echo "$line" | grep -q "master" && role="master"
  NODE_ADDRS+=("$addr")
  NODE_IDS+=("$(echo "$line" | awk '{print $1}')")
  NODE_ROLES+=("$role")
done <<< "$CLUSTER_NODES"

NODE_COUNT=${#NODE_ADDRS[@]}
MASTER_COUNT=0
for r in "${NODE_ROLES[@]}"; do [[ "$r" == "master" ]] && ((MASTER_COUNT++)); done
REPLICA_COUNT=$((NODE_COUNT - MASTER_COUNT))

# ── 1. Cluster state ────────────────────────────────────────────────────────
cluster_state=$(get_info_field cluster_state)
if [[ "$cluster_state" == "ok" ]]; then
  record PASS "Cluster state" "cluster_state:ok"
else
  record FAIL "Cluster state" "cluster_state:${cluster_state}"
fi

# ── 2. Slot coverage ────────────────────────────────────────────────────────
slots_assigned=$(get_info_field cluster_slots_assigned)
if [[ "$slots_assigned" == "16384" ]]; then
  record PASS "Slot coverage" "16384/16384 slots assigned"
else
  record FAIL "Slot coverage" "${slots_assigned}/16384 slots assigned"
fi

# ── 3. Node states ──────────────────────────────────────────────────────────
fail_nodes=$(echo "$CLUSTER_NODES" | grep -cE 'fail|handshake' || true)
if [[ "$fail_nodes" -eq 0 ]]; then
  record PASS "Node states" "All ${NODE_COUNT} nodes healthy"
else
  bad=$(echo "$CLUSTER_NODES" | grep -E 'fail|handshake' | awk '{print $2}' | cut -d@ -f1 | tr '\n' ' ')
  record FAIL "Node states" "${fail_nodes} unhealthy node(s): ${bad}"
fi

# ── 4. Replication status ───────────────────────────────────────────────────
repl_ok=true; repl_detail=""
for i in "${!NODE_ADDRS[@]}"; do
  [[ "${NODE_ROLES[$i]}" != "replica" ]] && continue
  nh="${NODE_ADDRS[$i]%%:*}"; np="${NODE_ADDRS[$i]##*:}"
  info_repl=$(rcli "$nh" "$np" INFO replication 2>/dev/null || echo "")
  link_status=$(echo "$info_repl" | grep -oP '^master_link_status:\K[^\r]+' || echo "unknown")
  repl_offset=$(echo "$info_repl" | grep -oP '^slave_repl_offset:\K[^\r]+' || echo "0")
  master_offset=$(echo "$info_repl" | grep -oP '^master_repl_offset:\K[^\r]+' || echo "0")

  if [[ "$link_status" != "up" ]]; then
    repl_ok=false
    repl_detail+="${NODE_ADDRS[$i]}:link_down "
  fi
  lag=$((master_offset - repl_offset))
  if [[ $lag -gt 10000 ]]; then
    repl_ok=false
    repl_detail+="${NODE_ADDRS[$i]}:lag=${lag} "
  fi
done

if [[ "$MASTER_COUNT" -gt 0 && "$REPLICA_COUNT" -eq 0 ]]; then
  record WARN "Replication" "No replicas configured (${MASTER_COUNT} masters, 0 replicas)"
elif [[ "$repl_ok" == true ]]; then
  record PASS "Replication" "${MASTER_COUNT} masters, ${REPLICA_COUNT} replicas, links up"
else
  record FAIL "Replication" "Issues: ${repl_detail}"
fi

# ── 5. Memory usage ─────────────────────────────────────────────────────────
mem_worst_status="PASS"; mem_details=""
for i in "${!NODE_ADDRS[@]}"; do
  nh="${NODE_ADDRS[$i]%%:*}"; np="${NODE_ADDRS[$i]##*:}"
  info_mem=$(rcli "$nh" "$np" INFO memory 2>/dev/null || echo "")
  used=$(echo "$info_mem" | grep -oP '^used_memory:\K[^\r]+' || echo "0")
  maxmem=$(echo "$info_mem" | grep -oP '^maxmemory:\K[^\r]+' || echo "0")

  if [[ "$maxmem" -gt 0 ]]; then
    pct=$((used * 100 / maxmem))
    if [[ $pct -ge 90 ]]; then
      mem_worst_status="FAIL"
      mem_details+="${NODE_ADDRS[$i]}:${pct}% "
    elif [[ $pct -ge 75 ]]; then
      [[ "$mem_worst_status" != "FAIL" ]] && mem_worst_status="WARN"
      mem_details+="${NODE_ADDRS[$i]}:${pct}% "
    elif [[ "$VERBOSE" == true ]]; then
      mem_details+="${NODE_ADDRS[$i]}:${pct}% "
    fi
  elif [[ "$VERBOSE" == true ]]; then
    mem_details+="${NODE_ADDRS[$i]}:maxmemory_unset "
  fi
done
record "$mem_worst_status" "Memory usage" "${mem_details:-All nodes within limits}"

# ── 6. Connected clients ────────────────────────────────────────────────────
cli_worst="PASS"; cli_details=""
for i in "${!NODE_ADDRS[@]}"; do
  nh="${NODE_ADDRS[$i]%%:*}"; np="${NODE_ADDRS[$i]##*:}"
  info_cli=$(rcli "$nh" "$np" INFO clients 2>/dev/null || echo "")
  connected=$(echo "$info_cli" | grep -oP '^connected_clients:\K[^\r]+' || echo "0")
  info_srv=$(rcli "$nh" "$np" INFO server 2>/dev/null || echo "")
  maxclients_line=$(rcli "$nh" "$np" CONFIG GET maxclients 2>/dev/null | tail -1 || echo "10000")
  maxclients=${maxclients_line:-10000}
  [[ "$maxclients" -eq 0 ]] && maxclients=10000

  pct=$((connected * 100 / maxclients))
  if [[ $pct -ge 90 ]]; then
    cli_worst="FAIL"
    cli_details+="${NODE_ADDRS[$i]}:${connected}/${maxclients}(${pct}%) "
  elif [[ $pct -ge 70 ]]; then
    [[ "$cli_worst" != "FAIL" ]] && cli_worst="WARN"
    cli_details+="${NODE_ADDRS[$i]}:${connected}/${maxclients}(${pct}%) "
  elif [[ "$VERBOSE" == true ]]; then
    cli_details+="${NODE_ADDRS[$i]}:${connected}/${maxclients}(${pct}%) "
  fi
done
record "$cli_worst" "Connected clients" "${cli_details:-All nodes within limits}"

# ── 7. Latency check ────────────────────────────────────────────────────────
lat_worst="PASS"; lat_details=""
for i in "${!NODE_ADDRS[@]}"; do
  nh="${NODE_ADDRS[$i]%%:*}"; np="${NODE_ADDRS[$i]##*:}"
  # Measure round-trip via PING timing (5 samples)
  start_ns=$(date +%s%N)
  for _ in 1 2 3 4 5; do rcli "$nh" "$np" PING > /dev/null; done
  end_ns=$(date +%s%N)
  avg_us=$(( (end_ns - start_ns) / 5000 ))

  if [[ $avg_us -gt 10000 ]]; then
    lat_worst="FAIL"
    lat_details+="${NODE_ADDRS[$i]}:${avg_us}us "
  elif [[ $avg_us -gt 5000 ]]; then
    [[ "$lat_worst" != "FAIL" ]] && lat_worst="WARN"
    lat_details+="${NODE_ADDRS[$i]}:${avg_us}us "
  elif [[ "$VERBOSE" == true ]]; then
    lat_details+="${NODE_ADDRS[$i]}:${avg_us}us "
  fi
done
record "$lat_worst" "Latency" "${lat_details:-All nodes < 5ms}"

# ── 8. Slot distribution balance ────────────────────────────────────────────
if [[ "$MASTER_COUNT" -gt 0 ]]; then
  expected_per_master=$((16384 / MASTER_COUNT))
  max_slots=0; min_slots=16384
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | grep -q "master" || continue
    slot_ranges=$(echo "$line" | awk '{for(i=9;i<=NF;i++) print $i}')
    count=0
    for range in $slot_ranges; do
      if [[ "$range" == *-* ]]; then
        lo="${range%-*}"; hi="${range#*-}"
        count=$((count + hi - lo + 1))
      else
        ((count++))
      fi
    done
    [[ $count -gt $max_slots ]] && max_slots=$count
    [[ $count -lt $min_slots ]] && min_slots=$count
  done <<< "$CLUSTER_NODES"

  if [[ "$expected_per_master" -gt 0 ]]; then
    spread=$((max_slots - min_slots))
    imbalance_pct=$((spread * 100 / expected_per_master))
    if [[ $imbalance_pct -gt 20 ]]; then
      record WARN "Slot balance" "Imbalance ${imbalance_pct}% (${min_slots}-${max_slots} slots, expected ~${expected_per_master})"
    else
      record PASS "Slot balance" "Spread ${imbalance_pct}% (${min_slots}-${max_slots} slots across ${MASTER_COUNT} masters)"
    fi
  else
    record WARN "Slot balance" "Cannot determine balance"
  fi
else
  record FAIL "Slot balance" "No masters found"
fi

# ── 9. Rejected connections ─────────────────────────────────────────────────
rej_worst="PASS"; rej_details=""
for i in "${!NODE_ADDRS[@]}"; do
  nh="${NODE_ADDRS[$i]%%:*}"; np="${NODE_ADDRS[$i]##*:}"
  info_stats=$(rcli "$nh" "$np" INFO stats 2>/dev/null || echo "")
  rejected=$(echo "$info_stats" | grep -oP '^rejected_connections:\K[^\r]+' || echo "0")
  if [[ "$rejected" -gt 0 ]]; then
    [[ "$rej_worst" == "PASS" ]] && rej_worst="WARN"
    rej_details+="${NODE_ADDRS[$i]}:${rejected} "
  fi
done
record "$rej_worst" "Rejected connections" "${rej_details:-None across all nodes}"

# ── 10. Persistence status ──────────────────────────────────────────────────
persist_worst="PASS"; persist_details=""
for i in "${!NODE_ADDRS[@]}"; do
  nh="${NODE_ADDRS[$i]%%:*}"; np="${NODE_ADDRS[$i]##*:}"
  info_persist=$(rcli "$nh" "$np" INFO persistence 2>/dev/null || echo "")

  rdb_status=$(echo "$info_persist" | grep -oP '^rdb_last_bgsave_status:\K[^\r]+' || echo "none")
  aof_enabled=$(echo "$info_persist" | grep -oP '^aof_enabled:\K[^\r]+' || echo "0")
  aof_status=$(echo "$info_persist" | grep -oP '^aof_last_bgrewrite_status:\K[^\r]+' || echo "none")

  node_issues=""
  if [[ "$rdb_status" != "ok" && "$rdb_status" != "none" ]]; then
    node_issues+="rdb_fail "
  fi
  if [[ "$aof_enabled" == "1" && "$aof_status" != "ok" && "$aof_status" != "none" ]]; then
    node_issues+="aof_fail "
  fi
  if [[ -n "$node_issues" ]]; then
    persist_worst="FAIL"
    persist_details+="${NODE_ADDRS[$i]}:${node_issues}"
  elif [[ "$VERBOSE" == true ]]; then
    aof_label="off"; [[ "$aof_enabled" == "1" ]] && aof_label="on"
    persist_details+="${NODE_ADDRS[$i]}:rdb=${rdb_status},aof=${aof_label} "
  fi
done
record "$persist_worst" "Persistence" "${persist_details:-RDB/AOF healthy on all nodes}"

# ── Summary & exit ───────────────────────────────────────────────────────────
TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
if [[ "$JSON_OUTPUT" == true ]]; then
  items=$(IFS=,; echo "${JSON_RESULTS[*]}")
  echo "{\"cluster\":\"${ENTRY_POINT}\",\"checks\":[${items}],\"summary\":{\"total\":${TOTAL},\"pass\":${PASS_COUNT},\"warn\":${WARN_COUNT},\"fail\":${FAIL_COUNT}}}"
else
  echo ""
  echo -e "${BOLD}Summary:${NC} ${TOTAL} checks — " \
    "${GREEN}${PASS_COUNT} passed${NC}, " \
    "${YELLOW}${WARN_COUNT} warnings${NC}, " \
    "${RED}${FAIL_COUNT} failures${NC}"
  echo ""
fi
[[ "$FAIL_COUNT" -gt 0 ]] && exit 2
[[ "$WARN_COUNT" -gt 0 ]] && exit 1
exit 0
