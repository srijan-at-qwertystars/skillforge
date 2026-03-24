#!/usr/bin/env bash
###############################################################################
# nats-health-check.sh — Comprehensive NATS server health check
#
# Usage:
#   ./nats-health-check.sh [OPTIONS]
#
# Options:
#   --server URL     NATS server URL   (default: nats://localhost:4222)
#   --creds FILE     Path to a .creds file for authentication
#   --json           Output results as JSON (for monitoring pipelines)
#   --help           Show this help message
#
# Exit codes:
#   0  Healthy     — all checks passed
#   1  Degraded    — server reachable but one or more subsystems have warnings
#   2  Unhealthy   — server unreachable or critical failures detected
#
# Requires: nats CLI  (https://github.com/nats-io/natscli)
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SERVER="nats://localhost:4222"
CREDS=""
JSON_OUTPUT=false

# Aggregate exit code — only increases (healthy → degraded → unhealthy)
EXIT_CODE=0

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

pass()    { printf "  ${GREEN}✔${NC}  %s\n" "$*"; }
warning() { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1; }
fail()    { printf "  ${RED}✘${NC}  %s\n" "$*"; EXIT_CODE=2; }
header()  { printf "\n${BOLD}${CYAN}── %s ──${NC}\n" "$*"; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^###*$/{ s/^# \{0,1\}//; p; }' "$0"
  exit 0
}

# ─── Argument parsing ───────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)  SERVER="$2";      shift 2 ;;
      --creds)   CREDS="$2";       shift 2 ;;
      --json)    JSON_OUTPUT=true;  shift   ;;
      --help|-h) usage ;;
      *)         echo "Unknown option: $1" >&2; usage ;;
    esac
  done
}

# Build a reusable array of common nats CLI flags
nats_flags() {
  local flags=("--server" "$SERVER")
  [[ -n "$CREDS" ]] && flags+=("--creds" "$CREDS")
  printf '%s\n' "${flags[@]}"
}

# Helper: run the nats CLI with common flags
run_nats() {
  local -a flags=("--server" "$SERVER")
  [[ -n "$CREDS" ]] && flags+=("--creds" "$CREDS")
  nats "${flags[@]}" "$@"
}

# ─── Prerequisite check ─────────────────────────────────────────────────────
check_prerequisites() {
  if ! command -v nats &>/dev/null; then
    fail "nats CLI not found. Install from https://github.com/nats-io/natscli"
    exit 2
  fi
}

# ─── Check 1: Basic connectivity ────────────────────────────────────────────
check_connectivity() {
  header "Connectivity"

  if run_nats server ping --count 1 &>/dev/null; then
    local rtt
    rtt=$(run_nats server ping --count 1 2>&1 | grep -oP '\d+(\.\d+)?\s*(ms|µs|us|ns)' | head -1 || echo "n/a")
    pass "Server reachable at ${SERVER} (RTT: ${rtt})"
  else
    fail "Cannot reach server at ${SERVER}"
    # No point continuing if we cannot connect
    echo ""
    printf "${RED}Server is unreachable — aborting remaining checks.${NC}\n"
    exit 2
  fi
}

# ─── Check 2: JetStream status ──────────────────────────────────────────────
check_jetstream() {
  header "JetStream"

  local acct_info
  if acct_info=$(run_nats account info 2>&1); then
    # Extract key metrics
    local memory used_mem storage used_store streams consumers
    memory=$(echo "$acct_info"  | grep -i "memory"  | head -1 || true)
    storage=$(echo "$acct_info" | grep -i "storage" | head -1 || true)
    streams=$(echo "$acct_info" | grep -i "streams" | head -1 || true)
    consumers=$(echo "$acct_info" | grep -i "consumers" | head -1 || true)

    pass "JetStream is enabled"
    [[ -n "$memory" ]]    && pass "Memory:    ${memory##* }"
    [[ -n "$storage" ]]   && pass "Storage:   ${storage##* }"
    [[ -n "$streams" ]]   && pass "Streams:   ${streams##* }"
    [[ -n "$consumers" ]] && pass "Consumers: ${consumers##* }"
  else
    warning "JetStream may not be enabled or account info unavailable"
    echo "  $acct_info"
  fi
}

# ─── Check 3: Stream details ────────────────────────────────────────────────
check_streams() {
  header "Streams"

  local stream_list
  if stream_list=$(run_nats stream ls --json 2>/dev/null); then
    local count
    count=$(echo "$stream_list" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$count" == "0" ]]; then
      warning "No streams found"
      return
    fi

    pass "${count} stream(s) found"

    # Per-stream details
    local names
    names=$(echo "$stream_list" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    print(s)
" 2>/dev/null || true)

    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local info
      if info=$(run_nats stream info "$name" 2>&1); then
        local msgs bytes replicas
        msgs=$(echo "$info"     | grep -i "messages:" | head -1 | awk '{print $NF}' || echo "?")
        bytes=$(echo "$info"    | grep -i "bytes:"    | head -1 | awk '{print $NF}' || echo "?")
        replicas=$(echo "$info" | grep -i "replicas:" | head -1 | awk '{print $NF}' || echo "?")
        pass "  ${name}: msgs=${msgs}  bytes=${bytes}  replicas=${replicas}"
      fi
    done <<< "$names"
  else
    # Fallback: non-JSON listing
    local plain_list
    if plain_list=$(run_nats stream ls 2>&1); then
      pass "Streams:"
      echo "$plain_list" | sed 's/^/       /'
    else
      warning "Unable to list streams"
    fi
  fi
}

# ─── Check 4: Consumer counts per stream ────────────────────────────────────
check_consumers() {
  header "Consumers"

  local stream_names
  stream_names=$(run_nats stream ls 2>/dev/null | grep -v "^$" || true)

  if [[ -z "$stream_names" ]]; then
    warning "No streams — skipping consumer check"
    return
  fi

  while IFS= read -r stream; do
    [[ -z "$stream" ]] && continue
    # Strip whitespace / formatting
    stream=$(echo "$stream" | xargs)

    local consumer_list
    if consumer_list=$(run_nats consumer ls "$stream" 2>/dev/null); then
      local ccount
      ccount=$(echo "$consumer_list" | grep -c '.' || echo "0")
      pass "${stream}: ${ccount} consumer(s)"
    fi
  done <<< "$stream_names"
}

# ─── Check 5: Cluster state ─────────────────────────────────────────────────
check_cluster() {
  header "Cluster"

  local report
  if report=$(run_nats server report jetstream 2>&1); then
    # Check for cluster-related content
    if echo "$report" | grep -qi "cluster\|replica\|peer"; then
      pass "Cluster mode detected"
      echo "$report" | head -30 | sed 's/^/       /'
    else
      pass "Server is running in standalone mode"
    fi
  else
    warning "Could not retrieve cluster report (may be standalone)"
  fi
}

# ─── Check 6: Account info and limits ───────────────────────────────────────
check_account_limits() {
  header "Account Limits"

  local acct_info
  if acct_info=$(run_nats account info 2>&1); then
    # Parse and display limits
    local max_conns max_payload max_subs
    max_conns=$(echo "$acct_info"   | grep -i "max conn"    | head -1 | awk '{print $NF}' || echo "n/a")
    max_payload=$(echo "$acct_info" | grep -i "max payload"  | head -1 | awk '{print $NF}' || echo "n/a")
    max_subs=$(echo "$acct_info"    | grep -i "max sub"      | head -1 | awk '{print $NF}' || echo "n/a")

    pass "Max connections: ${max_conns}"
    pass "Max payload:     ${max_payload}"
    pass "Max subs:        ${max_subs}"
  else
    warning "Could not retrieve account limits"
  fi
}

# ─── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  case $EXIT_CODE in
    0)
      printf "${GREEN}${BOLD}Result: HEALTHY${NC}  — all checks passed\n"
      ;;
    1)
      printf "${YELLOW}${BOLD}Result: DEGRADED${NC} — server reachable but warnings detected\n"
      ;;
    2)
      printf "${RED}${BOLD}Result: UNHEALTHY${NC} — critical issues found\n"
      ;;
  esac
  echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  printf "${BOLD}NATS Health Check${NC}  ─  ${SERVER}\n"
  printf "Timestamp: %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  check_prerequisites
  check_connectivity
  check_jetstream
  check_streams
  check_consumers
  check_cluster
  check_account_limits
  print_summary

  exit "$EXIT_CODE"
}

main "$@"
