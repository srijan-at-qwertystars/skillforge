#!/usr/bin/env bash
###############################################################################
# benchmark-nats.sh — Benchmark NATS pub/sub, request/reply, and JetStream
#
# Usage:
#   ./benchmark-nats.sh [OPTIONS]
#
# Options:
#   --server URL    NATS server URL         (default: nats://localhost:4222)
#   --creds FILE    Path to a .creds file for authentication
#   --size BYTES    Message payload size     (default: 128)
#   --count NUM     Messages per benchmark   (default: 1000000)
#   --quick         Abbreviated run (100 000 msgs, fewer iterations)
#   --help          Show this help message
#
# Benchmarks executed:
#   1. Core NATS pub/sub throughput   (nats bench)
#   2. Request/reply latency          (nats bench --request)
#   3. JetStream publish rate         (nats bench --js)
#   4. JetStream consume rate         (nats bench --js --consumer)
#
# Requires: nats CLI  (https://github.com/nats-io/natscli)
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SERVER="nats://localhost:4222"
CREDS=""
MSG_SIZE=128
MSG_COUNT=1000000
QUICK=false

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()   { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()     { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()   { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()    { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }
header() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$*"; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^###*$/{ s/^# \{0,1\}//; p; }' "$0"
  exit 0
}

# ─── Argument parsing ───────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)  SERVER="$2";    shift 2 ;;
      --creds)   CREDS="$2";     shift 2 ;;
      --size)    MSG_SIZE="$2";  shift 2 ;;
      --count)   MSG_COUNT="$2"; shift 2 ;;
      --quick)   QUICK=true;     shift   ;;
      --help|-h) usage ;;
      *)         echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  if $QUICK; then
    MSG_COUNT=100000
    info "Quick mode: ${MSG_COUNT} messages per test"
  fi
}

# Build common flags for the nats CLI
nats_flags=()
build_flags() {
  nats_flags=("--server" "$SERVER")
  [[ -n "$CREDS" ]] && nats_flags+=("--creds" "$CREDS")
}

# Helper: run nats with common flags
run_nats() {
  nats "${nats_flags[@]}" "$@"
}

# ─── Prerequisite check ─────────────────────────────────────────────────────
check_prerequisites() {
  if ! command -v nats &>/dev/null; then
    err "nats CLI not found. Install from https://github.com/nats-io/natscli"
    exit 2
  fi

  # Verify connectivity
  if ! run_nats server ping --count 1 &>/dev/null; then
    err "Cannot reach NATS server at ${SERVER}"
    exit 2
  fi
  ok "Connected to ${SERVER}"
}

# ─── Benchmark helpers ───────────────────────────────────────────────────────

# Unique subjects avoid collision between runs
BENCH_ID="bench-$(date +%s)"

# 1. Core pub/sub throughput
bench_pubsub() {
  header "Core NATS Pub/Sub Throughput"
  info "Publishing ${MSG_COUNT} messages (${MSG_SIZE}B payload) with 1 pub / 1 sub"

  run_nats bench "${BENCH_ID}.pubsub" \
    --pub 1 \
    --sub 1 \
    --size "$MSG_SIZE" \
    --msgs "$MSG_COUNT" \
    2>&1 | tee /dev/stderr | tail -5

  echo ""
  info "Multi-publisher (4 pub / 4 sub):"
  run_nats bench "${BENCH_ID}.pubsub.multi" \
    --pub 4 \
    --sub 4 \
    --size "$MSG_SIZE" \
    --msgs "$MSG_COUNT" \
    2>&1 | tee /dev/stderr | tail -5
}

# 2. Request/reply latency
bench_reqreply() {
  header "Request / Reply Latency"

  # Use fewer messages for latency tests (they are inherently slower)
  local rr_count=$(( MSG_COUNT / 10 ))
  (( rr_count < 1000 )) && rr_count=1000

  info "Running ${rr_count} request/reply round-trips (${MSG_SIZE}B payload)"

  run_nats bench "${BENCH_ID}.reqreply" \
    --pub 1 \
    --sub 1 \
    --size "$MSG_SIZE" \
    --msgs "$rr_count" \
    --request \
    2>&1 | tee /dev/stderr | tail -10
}

# 3. JetStream publish rate
bench_js_publish() {
  header "JetStream Publish Rate"

  local stream_name="BENCH_PUB_${BENCH_ID//[^a-zA-Z0-9]/_}"
  local subject="${BENCH_ID}.js.pub"

  info "Creating ephemeral stream ${stream_name}…"
  run_nats stream add "$stream_name" \
    --subjects "${subject}" \
    --storage memory \
    --replicas 1 \
    --retention limits \
    --max-msgs -1 \
    --max-bytes 1GB \
    --max-age 5m \
    --max-msg-size -1 \
    --discard old \
    --dupe-window 2m \
    --defaults 2>/dev/null || true

  info "Publishing ${MSG_COUNT} messages (${MSG_SIZE}B) to JetStream"
  run_nats bench "${subject}" \
    --pub 1 \
    --size "$MSG_SIZE" \
    --msgs "$MSG_COUNT" \
    --js \
    2>&1 | tee /dev/stderr | tail -5

  # Clean up
  run_nats stream rm "$stream_name" -f 2>/dev/null || true
  ok "Stream ${stream_name} removed"
}

# 4. JetStream consume rate
bench_js_consume() {
  header "JetStream Consume Rate"

  local stream_name="BENCH_CON_${BENCH_ID//[^a-zA-Z0-9]/_}"
  local subject="${BENCH_ID}.js.con"

  # Use a smaller count for the two-phase (publish then consume) benchmark
  local js_count=$(( MSG_COUNT / 5 ))
  (( js_count < 10000 )) && js_count=10000

  info "Creating ephemeral stream ${stream_name}…"
  run_nats stream add "$stream_name" \
    --subjects "${subject}" \
    --storage memory \
    --replicas 1 \
    --retention limits \
    --max-msgs -1 \
    --max-bytes 1GB \
    --max-age 5m \
    --max-msg-size -1 \
    --discard old \
    --dupe-window 2m \
    --defaults 2>/dev/null || true

  info "Pre-loading ${js_count} messages into stream…"
  run_nats bench "${subject}" \
    --pub 1 \
    --size "$MSG_SIZE" \
    --msgs "$js_count" \
    --js \
    2>&1 | tail -3

  info "Consuming ${js_count} messages from JetStream"
  run_nats bench "${subject}" \
    --sub 1 \
    --msgs "$js_count" \
    --js \
    --consumer "bench-consumer" \
    2>&1 | tee /dev/stderr | tail -5

  # Clean up
  run_nats stream rm "$stream_name" -f 2>/dev/null || true
  ok "Stream ${stream_name} removed"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
  header "Summary"
  printf "${BOLD}Server:${NC}        %s\n" "$SERVER"
  printf "${BOLD}Message size:${NC}  %s bytes\n" "$MSG_SIZE"
  printf "${BOLD}Message count:${NC} %s per test\n" "$MSG_COUNT"
  printf "${BOLD}Quick mode:${NC}    %s\n" "$QUICK"
  echo ""
  ok "All benchmarks complete."
  echo ""
  info "Tip: Compare results across runs to identify regressions."
  info "Tip: Use --size 1024 and --size 4096 to test different payload sizes."
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  build_flags

  printf "${BOLD}NATS Performance Benchmark${NC}\n"
  printf "Server:  %s\n" "$SERVER"
  printf "Payload: %s bytes   Messages: %s\n" "$MSG_SIZE" "$MSG_COUNT"
  printf "Date:    %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  check_prerequisites

  bench_pubsub
  bench_reqreply
  bench_js_publish
  bench_js_consume

  print_summary
}

main "$@"
