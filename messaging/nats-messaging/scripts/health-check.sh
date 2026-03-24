#!/usr/bin/env bash
###############################################################################
# health-check.sh — Comprehensive NATS server health check
#
# Usage:
#   ./health-check.sh [OPTIONS]
#
# Options:
#   --server URL      NATS monitoring URL (default: http://localhost:8222)
#   --nats-url URL    NATS client URL for nats CLI (default: nats://localhost:4222)
#   --creds FILE      Credentials file for nats CLI
#   --json            Output results as JSON
#   --quiet           Only output on failure
#   --help            Show this help
#
# Exit codes:
#   0  Healthy    — all checks passed
#   1  Degraded   — reachable but warnings detected
#   2  Unhealthy  — unreachable or critical failures
#
# Works with or without the nats CLI — falls back to HTTP API.
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
MONITOR_URL="http://localhost:8222"
NATS_URL="nats://localhost:4222"
CREDS=""
JSON_OUTPUT=false
QUIET=false
EXIT_CODE=0

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()    { $QUIET || printf "  ${GREEN}✔${NC}  %s\n" "$*"; }
warning() { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1; }
fail()    { printf "  ${RED}✘${NC}  %s\n" "$*"; EXIT_CODE=2; }
header()  { $QUIET || printf "\n${BOLD}${CYAN}── %s ──${NC}\n" "$*"; }

# ─── Argument parsing ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)   MONITOR_URL="$2"; shift 2 ;;
        --nats-url) NATS_URL="$2";    shift 2 ;;
        --creds)    CREDS="$2";       shift 2 ;;
        --json)     JSON_OUTPUT=true; shift ;;
        --quiet)    QUIET=true;       shift ;;
        --help|-h)  sed -n '2,/^###*$/{ s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

HAS_NATS_CLI=false
command -v nats &>/dev/null && HAS_NATS_CLI=true

HAS_JQ=false
command -v jq &>/dev/null && HAS_JQ=true

# ─── JSON output accumulator ────────────────────────────────────────────────
declare -A JSON_RESULTS

json_set() { JSON_RESULTS["$1"]="$2"; }

print_json() {
    echo "{"
    local first=true
    for key in "${!JSON_RESULTS[@]}"; do
        $first || echo ","
        first=false
        printf '  "%s": %s' "$key" "${JSON_RESULTS[$key]}"
    done
    echo ""
    echo "}"
}

# ─── Check 1: Server reachability ───────────────────────────────────────────
check_health_endpoint() {
    header "Server Health"

    local healthz
    if healthz=$(curl -sf --max-time 5 "${MONITOR_URL}/healthz" 2>/dev/null); then
        pass "Server reachable at ${MONITOR_URL}"
        json_set "reachable" "true"
    else
        fail "Cannot reach server at ${MONITOR_URL}"
        json_set "reachable" "false"
        return 1
    fi
}

# ─── Check 2: Server stats ──────────────────────────────────────────────────
check_varz() {
    header "Server Stats"

    local varz
    varz=$(curl -sf --max-time 5 "${MONITOR_URL}/varz" 2>/dev/null) || {
        warning "Cannot fetch /varz"
        return
    }

    if $HAS_JQ; then
        local conns max_conns mem cpu slow version
        conns=$(echo "$varz" | jq -r '.connections // 0')
        max_conns=$(echo "$varz" | jq -r '.max_connections // 0')
        mem=$(echo "$varz" | jq -r '.mem // 0')
        cpu=$(echo "$varz" | jq -r '.cpu // 0')
        slow=$(echo "$varz" | jq -r '.slow_consumers // 0')
        version=$(echo "$varz" | jq -r '.version // "unknown"')

        local mem_mb=$((mem / 1048576))

        pass "Version: ${version}"
        pass "Connections: ${conns} / ${max_conns}"
        pass "Memory: ${mem_mb} MB"
        pass "CPU: ${cpu}%"

        json_set "version" "\"${version}\""
        json_set "connections" "${conns}"
        json_set "max_connections" "${max_conns}"
        json_set "memory_mb" "${mem_mb}"

        # Warnings
        if [[ "$slow" -gt 0 ]]; then
            warning "Slow consumers detected: ${slow}"
            json_set "slow_consumers" "${slow}"
        else
            pass "Slow consumers: 0"
            json_set "slow_consumers" "0"
        fi

        if [[ "$max_conns" -gt 0 ]]; then
            local pct=$((conns * 100 / max_conns))
            if [[ "$pct" -gt 85 ]]; then
                warning "Connection utilization at ${pct}%"
            fi
        fi
    else
        pass "Server responding (install jq for detailed stats)"
    fi
}

# ─── Check 3: JetStream ─────────────────────────────────────────────────────
check_jetstream() {
    header "JetStream"

    local jsz
    jsz=$(curl -sf --max-time 5 "${MONITOR_URL}/jsz" 2>/dev/null) || {
        warning "JetStream not available or not enabled"
        json_set "jetstream_enabled" "false"
        return
    }

    json_set "jetstream_enabled" "true"

    if $HAS_JQ; then
        local streams consumers mem_used mem_reserved store_used store_reserved
        streams=$(echo "$jsz" | jq -r '.streams // 0')
        consumers=$(echo "$jsz" | jq -r '.consumers // 0')
        mem_used=$(echo "$jsz" | jq -r '.memory // 0')
        mem_reserved=$(echo "$jsz" | jq -r '.reserved_memory // 0')
        store_used=$(echo "$jsz" | jq -r '.store // 0')
        store_reserved=$(echo "$jsz" | jq -r '.reserved_store // 0')

        pass "JetStream enabled"
        pass "Streams: ${streams}"
        pass "Consumers: ${consumers}"

        json_set "js_streams" "${streams}"
        json_set "js_consumers" "${consumers}"

        # Storage warnings
        if [[ "$store_reserved" -gt 0 ]]; then
            local store_pct=$((store_used * 100 / store_reserved))
            pass "Storage: ${store_pct}% used"
            json_set "js_storage_pct" "${store_pct}"
            if [[ "$store_pct" -gt 90 ]]; then
                fail "JetStream storage critical: ${store_pct}%"
            elif [[ "$store_pct" -gt 75 ]]; then
                warning "JetStream storage high: ${store_pct}%"
            fi
        fi

        if [[ "$mem_reserved" -gt 0 ]]; then
            local mem_pct=$((mem_used * 100 / mem_reserved))
            pass "Memory: ${mem_pct}% used"
            json_set "js_memory_pct" "${mem_pct}"
            if [[ "$mem_pct" -gt 85 ]]; then
                warning "JetStream memory high: ${mem_pct}%"
            fi
        fi
    else
        pass "JetStream responding"
    fi
}

# ─── Check 4: Cluster state ─────────────────────────────────────────────────
check_cluster() {
    header "Cluster"

    local routez
    routez=$(curl -sf --max-time 5 "${MONITOR_URL}/routez" 2>/dev/null) || {
        pass "Standalone mode (no cluster routes)"
        json_set "cluster_mode" "\"standalone\""
        return
    }

    if $HAS_JQ; then
        local num_routes
        num_routes=$(echo "$routez" | jq -r '.num_routes // 0')

        if [[ "$num_routes" -gt 0 ]]; then
            pass "Cluster mode: ${num_routes} route(s) connected"
            json_set "cluster_mode" "\"clustered\""
            json_set "cluster_routes" "${num_routes}"

            # Show route details
            echo "$routez" | jq -r '.routes[] | "      → \(.remote_id // "?") at \(.ip):\(.port) (RTT: \(.rtt // "?"))"' 2>/dev/null || true
        else
            warning "Cluster configured but no routes connected"
            json_set "cluster_mode" "\"disconnected\""
            json_set "cluster_routes" "0"
        fi
    else
        pass "Cluster routing active"
    fi
}

# ─── Check 5: Leaf nodes ────────────────────────────────────────────────────
check_leafnodes() {
    local leafz
    leafz=$(curl -sf --max-time 5 "${MONITOR_URL}/leafz" 2>/dev/null) || return

    if $HAS_JQ; then
        local num_leafs
        num_leafs=$(echo "$leafz" | jq -r '.leafnodes // 0')
        if [[ "$num_leafs" -gt 0 ]]; then
            header "Leaf Nodes"
            pass "${num_leafs} leaf node(s) connected"
            json_set "leaf_nodes" "${num_leafs}"
        fi
    fi
}

# ─── Check 6: Slow consumer detail ──────────────────────────────────────────
check_slow_consumers() {
    local connz
    connz=$(curl -sf --max-time 5 "${MONITOR_URL}/connz?sort=pending&limit=5" 2>/dev/null) || return

    if $HAS_JQ; then
        local slow_list
        slow_list=$(echo "$connz" | jq -r '.connections[] | select(.slow_consumer == true) | "\(.cid) \(.name // "unnamed") pending=\(.pending_bytes)"' 2>/dev/null)
        if [[ -n "$slow_list" ]]; then
            header "Slow Consumers (Detail)"
            while IFS= read -r line; do
                warning "  $line"
            done <<< "$slow_list"
        fi
    fi
}

# ─── Check 7: Stream health (via nats CLI) ──────────────────────────────────
check_streams_cli() {
    $HAS_NATS_CLI || return

    header "Streams (via nats CLI)"

    local nats_args=("--server" "$NATS_URL")
    [[ -n "$CREDS" ]] && nats_args+=("--creds" "$CREDS")

    local stream_list
    stream_list=$(nats stream ls -n "${nats_args[@]}" 2>/dev/null) || {
        warning "Could not list streams"
        return
    }

    if [[ -z "$stream_list" ]]; then
        pass "No streams configured"
        return
    fi

    local count=0
    while IFS= read -r stream; do
        [[ -z "$stream" ]] && continue
        stream=$(echo "$stream" | xargs)
        local info
        if info=$(nats stream info "$stream" "${nats_args[@]}" 2>&1); then
            local msgs bytes
            msgs=$(echo "$info" | grep -i "messages:" | head -1 | awk '{print $NF}' || echo "?")
            bytes=$(echo "$info" | grep -i "bytes:" | head -1 | awk '{print $NF}' || echo "?")
            pass "${stream}: msgs=${msgs}  bytes=${bytes}"
        fi
        (( count++ ))
    done <<< "$stream_list"

    json_set "streams_checked" "${count}"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    case $EXIT_CODE in
        0) printf "${GREEN}${BOLD}✔ HEALTHY${NC}  — all checks passed\n" ;;
        1) printf "${YELLOW}${BOLD}⚠ DEGRADED${NC} — warnings detected\n" ;;
        2) printf "${RED}${BOLD}✘ UNHEALTHY${NC} — critical issues found\n" ;;
    esac
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    $QUIET || printf "${BOLD}NATS Health Check${NC}  —  %s\n" "${MONITOR_URL}"
    $QUIET || printf "Timestamp: %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    check_health_endpoint || {
        json_set "status" "\"unhealthy\""
        if $JSON_OUTPUT; then print_json; fi
        exit 2
    }

    check_varz
    check_jetstream
    check_cluster
    check_leafnodes
    check_slow_consumers
    check_streams_cli

    case $EXIT_CODE in
        0) json_set "status" "\"healthy\"" ;;
        1) json_set "status" "\"degraded\"" ;;
        2) json_set "status" "\"unhealthy\"" ;;
    esac

    if $JSON_OUTPUT; then
        print_json
    else
        print_summary
    fi

    exit "$EXIT_CODE"
}

main
