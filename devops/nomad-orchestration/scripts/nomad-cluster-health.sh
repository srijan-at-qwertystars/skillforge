#!/usr/bin/env bash
# nomad-cluster-health.sh — Checks Nomad cluster health: servers, clients, allocations, Consul.
# Usage: ./nomad-cluster-health.sh
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

ISSUES=0

check_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
check_fail() { echo -e "  ${RED}✗${NC} $1"; ((ISSUES++)); }
check_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
section()    { echo -e "\n${BLUE}=== $1 ===${NC}"; }

NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"

# Check nomad CLI available
if ! command -v nomad &>/dev/null; then
  echo -e "${RED}Error: nomad CLI not found in PATH${NC}"
  exit 1
fi

echo -e "${BLUE}Nomad Cluster Health Check${NC}"
echo "Target: ${NOMAD_ADDR}"
echo "Time:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# --- Agent Health ---
section "Agent Health"
if curl -sf "${NOMAD_ADDR}/v1/agent/health" >/dev/null 2>&1; then
  check_ok "Nomad API responding"
else
  check_fail "Nomad API not responding at ${NOMAD_ADDR}"
  echo -e "${RED}Cannot continue — API unreachable${NC}"
  exit 1
fi

# --- Server Status ---
section "Server Status"
SERVER_OUTPUT=$(nomad server members 2>&1) || true

if echo "$SERVER_OUTPUT" | grep -q "alive"; then
  TOTAL_SERVERS=$(echo "$SERVER_OUTPUT" | grep -c "alive" || true)
  LEADER_COUNT=$(echo "$SERVER_OUTPUT" | grep -c "true" || true)

  if [[ $LEADER_COUNT -eq 1 ]]; then
    check_ok "Leader elected"
  elif [[ $LEADER_COUNT -eq 0 ]]; then
    check_fail "No leader elected"
  else
    check_fail "Multiple leaders detected (split brain)"
  fi

  if [[ $TOTAL_SERVERS -ge 3 ]]; then
    check_ok "$TOTAL_SERVERS servers alive (quorum safe)"
  elif [[ $TOTAL_SERVERS -eq 2 ]]; then
    check_warn "$TOTAL_SERVERS servers alive — one failure loses quorum"
  elif [[ $TOTAL_SERVERS -eq 1 ]]; then
    check_fail "Only 1 server — no fault tolerance"
  fi

  # Check for failed/left servers
  FAILED_SERVERS=$(echo "$SERVER_OUTPUT" | grep -c "failed\|left" || true)
  if [[ $FAILED_SERVERS -gt 0 ]]; then
    check_warn "$FAILED_SERVERS server(s) failed or left"
  fi
else
  check_fail "Cannot parse server membership"
fi

# --- Raft Peers ---
section "Raft Consensus"
RAFT_OUTPUT=$(nomad operator raft list-peers 2>&1) || true
if echo "$RAFT_OUTPUT" | grep -q "leader"; then
  RAFT_PEERS=$(echo "$RAFT_OUTPUT" | grep -c "voter" || true)
  check_ok "$RAFT_PEERS Raft voter(s)"

  RAFT_LEADER=$(echo "$RAFT_OUTPUT" | grep "leader" | awk '{print $1}')
  check_ok "Raft leader: $RAFT_LEADER"
else
  check_warn "Cannot query Raft peers (may require ACL token)"
fi

# --- Client Status ---
section "Client Nodes"
NODE_OUTPUT=$(nomad node status 2>&1) || true

if echo "$NODE_OUTPUT" | grep -qE "ready|down|ineligible"; then
  READY_NODES=$(echo "$NODE_OUTPUT" | grep -c "ready" || true)
  DOWN_NODES=$(echo "$NODE_OUTPUT" | grep -c "down" || true)
  INELIGIBLE=$(echo "$NODE_OUTPUT" | grep -c "ineligible" || true)
  DRAINING=$(echo "$NODE_OUTPUT" | grep -c "drain" || true)

  check_ok "$READY_NODES node(s) ready"

  if [[ $DOWN_NODES -gt 0 ]]; then
    check_fail "$DOWN_NODES node(s) down"
  fi

  if [[ $INELIGIBLE -gt 0 ]]; then
    check_warn "$INELIGIBLE node(s) ineligible"
  fi

  if [[ $DRAINING -gt 0 ]]; then
    check_warn "$DRAINING node(s) draining"
  fi
else
  check_warn "No client nodes registered or cannot parse output"
fi

# --- Allocation Health ---
section "Allocations"
ALLOC_RUNNING=0
ALLOC_PENDING=0
ALLOC_FAILED=0
ALLOC_LOST=0

# Parse allocation metrics from the API
if METRICS=$(curl -sf "${NOMAD_ADDR}/v1/operator/metrics" 2>/dev/null); then
  ALLOC_RUNNING=$(echo "$METRICS" | grep -oP '"nomad\.nomad\.allocs\.running.*?"Value":\s*\K[0-9]+' 2>/dev/null | head -1 || echo "0")
  check_ok "Running allocations metric available"
else
  # Fallback: count from job statuses
  JOB_LIST=$(nomad job status -short 2>/dev/null | tail -n +2 || true)
  if [[ -n "$JOB_LIST" ]]; then
    TOTAL_JOBS=$(echo "$JOB_LIST" | wc -l)
    DEAD_JOBS=$(echo "$JOB_LIST" | grep -c "dead" || true)
    RUNNING_JOBS=$(echo "$JOB_LIST" | grep -c "running" || true)
    PENDING_JOBS=$(echo "$JOB_LIST" | grep -c "pending" || true)

    check_ok "$TOTAL_JOBS total job(s)"
    check_ok "$RUNNING_JOBS running, $PENDING_JOBS pending, $DEAD_JOBS dead"

    if [[ $PENDING_JOBS -gt 0 ]]; then
      check_warn "$PENDING_JOBS job(s) pending — check for placement issues"
    fi
  else
    check_warn "No jobs registered"
  fi
fi

# --- Blocked Evaluations ---
section "Evaluations"
BLOCKED_EVALS=$(nomad eval list -status blocked 2>/dev/null | tail -n +2 | wc -l || echo "0")
if [[ $BLOCKED_EVALS -gt 0 ]]; then
  check_fail "$BLOCKED_EVALS blocked evaluation(s) — jobs cannot be placed"
else
  check_ok "No blocked evaluations"
fi

# --- Consul Connectivity ---
section "Consul Integration"
CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"

if curl -sf "${CONSUL_ADDR}/v1/status/leader" >/dev/null 2>&1; then
  check_ok "Consul API responding at ${CONSUL_ADDR}"

  # Check Nomad service registered in Consul
  if curl -sf "${CONSUL_ADDR}/v1/catalog/service/nomad" 2>/dev/null | grep -q "ServiceName"; then
    NOMAD_CONSUL_INSTANCES=$(curl -sf "${CONSUL_ADDR}/v1/catalog/service/nomad" 2>/dev/null | grep -c "ServiceID" || echo "0")
    check_ok "Nomad registered in Consul ($NOMAD_CONSUL_INSTANCES instance(s))"
  else
    check_warn "Nomad not registered as a Consul service"
  fi

  # Check Nomad client service
  if curl -sf "${CONSUL_ADDR}/v1/catalog/service/nomad-client" 2>/dev/null | grep -q "ServiceName"; then
    CLIENT_CONSUL=$(curl -sf "${CONSUL_ADDR}/v1/catalog/service/nomad-client" 2>/dev/null | grep -c "ServiceID" || echo "0")
    check_ok "Nomad clients registered in Consul ($CLIENT_CONSUL instance(s))"
  else
    check_warn "Nomad clients not registered as Consul services"
  fi
else
  check_warn "Consul not reachable at ${CONSUL_ADDR} — service mesh may be unavailable"
fi

# --- Vault Connectivity ---
section "Vault Integration"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
  VAULT_STATUS=$(curl -sf "${VAULT_ADDR}/v1/sys/health" 2>/dev/null)
  VAULT_SEALED=$(echo "$VAULT_STATUS" | grep -oP '"sealed":\s*\K(true|false)' || echo "unknown")
  VAULT_INIT=$(echo "$VAULT_STATUS" | grep -oP '"initialized":\s*\K(true|false)' || echo "unknown")

  if [[ "$VAULT_SEALED" == "false" && "$VAULT_INIT" == "true" ]]; then
    check_ok "Vault initialized and unsealed"
  elif [[ "$VAULT_SEALED" == "true" ]]; then
    check_fail "Vault is sealed — secrets injection will fail"
  else
    check_warn "Vault status: initialized=$VAULT_INIT sealed=$VAULT_SEALED"
  fi
else
  check_warn "Vault not reachable at ${VAULT_ADDR}"
fi

# --- Summary ---
echo ""
echo -e "${BLUE}=== Summary ===${NC}"
if [[ $ISSUES -eq 0 ]]; then
  echo -e "${GREEN}All checks passed — cluster is healthy${NC}"
  exit 0
else
  echo -e "${RED}$ISSUES issue(s) detected${NC}"
  exit 1
fi
