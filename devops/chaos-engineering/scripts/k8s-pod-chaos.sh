#!/usr/bin/env bash
# ============================================================================
# k8s-pod-chaos.sh — Kill pods and simulate node failures in Kubernetes.
#
# Usage:
#   ./k8s-pod-chaos.sh kill-pod <namespace> <pod-name> [--grace-period=0]
#   ./k8s-pod-chaos.sh kill-random <namespace> <label-selector> [count]
#   ./k8s-pod-chaos.sh kill-percentage <namespace> <label-selector> <percent>
#   ./k8s-pod-chaos.sh drain-node <node-name>
#   ./k8s-pod-chaos.sh cordon-node <node-name>
#   ./k8s-pod-chaos.sh uncordon-node <node-name>
#   ./k8s-pod-chaos.sh kill-continuous <namespace> <label-selector> <interval_s> <duration_s>
#   ./k8s-pod-chaos.sh status <namespace> <label-selector>
#
# Examples:
#   ./k8s-pod-chaos.sh kill-random production app=payment-svc 2
#   ./k8s-pod-chaos.sh kill-percentage staging app=api-gateway 50
#   ./k8s-pod-chaos.sh drain-node worker-node-3
#   ./k8s-pod-chaos.sh kill-continuous production app=order-svc 30 300
#   ./k8s-pod-chaos.sh status production app=payment-svc
#
# Requirements: kubectl configured with cluster access
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $(date -u +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date -u +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date -u +%H:%M:%S) $*"; }
log_chaos() { echo -e "${CYAN}[CHAOS]${NC} $(date -u +%H:%M:%S) $*"; }

check_deps() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in PATH"
        exit 1
    fi
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
}

get_pods() {
    local ns="$1" selector="$2"
    kubectl get pods -n "$ns" -l "$selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

cmd_kill_pod() {
    local ns="${1:?Namespace required}"
    local pod="${2:?Pod name required}"
    local grace="${3:---grace-period=0}"

    log_chaos "Killing pod $pod in namespace $ns"
    kubectl delete pod "$pod" -n "$ns" "$grace" --force 2>/dev/null || \
        kubectl delete pod "$pod" -n "$ns" "$grace"
    log_info "Pod $pod deleted"

    log_info "Waiting for replacement pod..."
    sleep 5
    kubectl get pods -n "$ns" --field-selector="status.phase!=Succeeded" | head -20
}

cmd_kill_random() {
    local ns="${1:?Namespace required}"
    local selector="${2:?Label selector required (e.g., app=my-svc)}"
    local count="${3:-1}"

    local pods
    pods=$(get_pods "$ns" "$selector")
    if [[ -z "$pods" ]]; then
        log_error "No pods found matching -l $selector in namespace $ns"
        exit 1
    fi

    local pod_array=($pods)
    local total=${#pod_array[@]}
    log_info "Found $total pods matching '$selector' in $ns"

    if [[ "$count" -gt "$total" ]]; then
        log_warn "Requested $count but only $total pods available; killing all"
        count=$total
    fi

    local selected
    selected=$(printf '%s\n' "${pod_array[@]}" | shuf -n "$count")

    for pod in $selected; do
        log_chaos "Killing pod: $pod"
        kubectl delete pod "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null &
    done
    wait

    log_info "Killed $count of $total pods"
    sleep 3
    kubectl get pods -n "$ns" -l "$selector"
}

cmd_kill_percentage() {
    local ns="${1:?Namespace required}"
    local selector="${2:?Label selector required}"
    local percent="${3:?Percentage required (1-100)}"

    local pods
    pods=$(get_pods "$ns" "$selector")
    local pod_array=($pods)
    local total=${#pod_array[@]}
    local count=$(( (total * percent + 99) / 100 ))

    if [[ "$count" -lt 1 ]]; then count=1; fi
    log_info "Killing $count of $total pods (${percent}%)"

    cmd_kill_random "$ns" "$selector" "$count"
}

cmd_drain_node() {
    local node="${1:?Node name required}"

    log_chaos "Draining node: $node"
    log_warn "This will evict all pods from the node"

    kubectl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=120s

    log_info "Node $node drained"
    log_warn "Run './k8s-pod-chaos.sh uncordon-node $node' to restore"
}

cmd_cordon_node() {
    local node="${1:?Node name required}"

    log_chaos "Cordoning node: $node (no new pods will be scheduled)"
    kubectl cordon "$node"
    log_info "Node $node cordoned"
    log_warn "Run './k8s-pod-chaos.sh uncordon-node $node' to restore"
}

cmd_uncordon_node() {
    local node="${1:?Node name required}"

    log_info "Uncordoning node: $node"
    kubectl uncordon "$node"
    log_info "Node $node is schedulable again"
}

cmd_kill_continuous() {
    local ns="${1:?Namespace required}"
    local selector="${2:?Label selector required}"
    local interval="${3:?Interval in seconds required}"
    local duration="${4:?Duration in seconds required}"

    local end_time=$(( $(date +%s) + duration ))
    local kills=0

    log_chaos "Continuous pod kill: $selector in $ns"
    log_info "Interval: ${interval}s, Duration: ${duration}s"
    log_warn "Press Ctrl+C to abort early"

    trap 'log_info "Aborted after $kills kills"; exit 0' INT TERM

    while [[ $(date +%s) -lt $end_time ]]; do
        local remaining=$(( end_time - $(date +%s) ))
        log_info "Remaining: ${remaining}s — killing random pod..."

        local pods
        pods=$(get_pods "$ns" "$selector")
        if [[ -z "$pods" ]]; then
            log_warn "No pods found, waiting..."
            sleep "$interval"
            continue
        fi

        local target
        target=$(echo "$pods" | tr ' ' '\n' | shuf -n 1)
        log_chaos "Killing: $target"
        kubectl delete pod "$target" -n "$ns" --grace-period=0 --force 2>/dev/null || true
        kills=$((kills + 1))

        sleep "$interval"
    done

    log_info "Continuous chaos complete: $kills pods killed in ${duration}s"
}

cmd_status() {
    local ns="${1:?Namespace required}"
    local selector="${2:?Label selector required}"

    echo -e "\n${CYAN}=== Pod Status ===${NC}"
    kubectl get pods -n "$ns" -l "$selector" -o wide

    echo -e "\n${CYAN}=== Recent Events ===${NC}"
    kubectl get events -n "$ns" --field-selector involvedObject.kind=Pod \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -10

    echo -e "\n${CYAN}=== Deployment Status ===${NC}"
    kubectl get deployments -n "$ns" -l "$selector" 2>/dev/null || true
}

usage() {
    cat <<'EOF'
Usage: k8s-pod-chaos.sh <command> [args...]

Commands:
  kill-pod <ns> <pod> [--grace-period=N]          Kill a specific pod
  kill-random <ns> <selector> [count]             Kill N random pods by label
  kill-percentage <ns> <selector> <percent>       Kill a percentage of pods
  drain-node <node>                               Drain a node (simulate failure)
  cordon-node <node>                              Prevent scheduling on node
  uncordon-node <node>                            Restore node scheduling
  kill-continuous <ns> <selector> <int_s> <dur_s> Kill pods continuously
  status <ns> <selector>                          Show pod/deployment status

Requires: kubectl with cluster access
EOF
    exit 1
}

# --- Main ---
check_deps

case "${1:-}" in
    kill-pod)        shift; cmd_kill_pod "$@" ;;
    kill-random)     shift; cmd_kill_random "$@" ;;
    kill-percentage) shift; cmd_kill_percentage "$@" ;;
    drain-node)      shift; cmd_drain_node "$@" ;;
    cordon-node)     shift; cmd_cordon_node "$@" ;;
    uncordon-node)   shift; cmd_uncordon_node "$@" ;;
    kill-continuous) shift; cmd_kill_continuous "$@" ;;
    status)          shift; cmd_status "$@" ;;
    *)               usage ;;
esac
