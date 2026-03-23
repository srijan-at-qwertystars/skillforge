#!/usr/bin/env bash
# diagnose.sh — Diagnose common Temporal issues
#
# Usage:
#   ./diagnose.sh                          # Run all checks
#   ./diagnose.sh --server                 # Check server health only
#   ./diagnose.sh --queue my-queue         # Check a specific task queue
#   ./diagnose.sh --workflow my-wf-id      # Diagnose a specific workflow
#   ./diagnose.sh --failed                 # List recent failed workflows
#   ./diagnose.sh --stuck                  # Find stuck workflows

set -euo pipefail

# Defaults
ACTION="all"
TASK_QUEUE=""
WORKFLOW_ID=""
NAMESPACE="${TEMPORAL_NAMESPACE:-default}"
ADDRESS="${TEMPORAL_ADDRESS:-localhost:7233}"
LIMIT=20

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --server              Check server health and cluster info"
    echo "  --queue QUEUE         Diagnose a specific task queue"
    echo "  --workflow WF_ID      Diagnose a specific workflow"
    echo "  --failed              List recently failed workflows"
    echo "  --stuck               Find stuck/long-running workflows"
    echo "  --namespace NS        Namespace (default: 'default' or \$TEMPORAL_NAMESPACE)"
    echo "  --address ADDR        Server address (default: localhost:7233 or \$TEMPORAL_ADDRESS)"
    echo "  --limit N             Max results (default: 20)"
    echo "  -h, --help            Show this help"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)    ACTION="server"; shift ;;
        --queue)     ACTION="queue"; TASK_QUEUE="$2"; shift 2 ;;
        --workflow)  ACTION="workflow"; WORKFLOW_ID="$2"; shift 2 ;;
        --failed)    ACTION="failed"; shift ;;
        --stuck)     ACTION="stuck"; shift ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --address)   ADDRESS="$2"; shift 2 ;;
        --limit)     LIMIT="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           log_error "Unknown option: $1"; usage ;;
    esac
done

# Check for temporal CLI
if ! command -v temporal &>/dev/null; then
    log_error "Temporal CLI not found. Install with: brew install temporal"
    exit 1
fi

TEMPORAL_CMD="temporal --namespace ${NAMESPACE} --address ${ADDRESS}"

check_server() {
    log_section "Server Health"

    # Cluster health
    if $TEMPORAL_CMD operator cluster health 2>/dev/null | grep -q "SERVING"; then
        log_ok "Temporal server is SERVING"
    else
        log_error "Temporal server is not reachable at ${ADDRESS}"
        log_info "Check that the server is running and the address is correct"
        return 1
    fi

    # Cluster info
    log_info "Cluster info:"
    $TEMPORAL_CMD operator cluster describe 2>/dev/null | head -20 || true

    # Namespace info
    log_section "Namespace: ${NAMESPACE}"
    if $TEMPORAL_CMD operator namespace describe 2>/dev/null; then
        log_ok "Namespace '${NAMESPACE}' exists"
    else
        log_error "Namespace '${NAMESPACE}' not found"
        log_info "Create with: temporal operator namespace create --namespace ${NAMESPACE}"
    fi

    # System search attributes
    log_section "Search Attributes"
    $TEMPORAL_CMD operator search-attribute list 2>/dev/null | head -30 || log_warn "Could not list search attributes"
}

check_queue() {
    local queue="$1"
    log_section "Task Queue: ${queue}"

    local output
    output=$($TEMPORAL_CMD task-queue describe --task-queue "$queue" 2>/dev/null) || {
        log_error "Could not describe task queue: ${queue}"
        return 1
    }

    echo "$output"

    # Check for active pollers
    if echo "$output" | grep -qi "poller"; then
        log_ok "Task queue has active pollers"
    else
        log_warn "No active pollers found for task queue: ${queue}"
        log_info "Ensure a worker is running and polling this queue"
    fi
}

check_workflow() {
    local wf_id="$1"
    log_section "Workflow: ${wf_id}"

    # Describe workflow
    local desc
    desc=$($TEMPORAL_CMD workflow describe --workflow-id "$wf_id" 2>/dev/null) || {
        log_error "Could not find workflow: ${wf_id}"
        return 1
    }

    echo "$desc"

    # Extract status
    local status
    status=$(echo "$desc" | grep -i "status" | head -1 || echo "unknown")
    log_info "Status: ${status}"

    # Show recent history events
    log_section "Recent History Events"
    $TEMPORAL_CMD workflow show --workflow-id "$wf_id" 2>/dev/null | tail -30

    # Check for common issues
    log_section "Issue Detection"

    local history
    history=$($TEMPORAL_CMD workflow show --workflow-id "$wf_id" 2>/dev/null)

    # Check for WorkflowTaskFailed
    if echo "$history" | grep -q "WorkflowTaskFailed"; then
        log_error "Found WorkflowTaskFailed events — possible non-determinism or code error"
        echo "$history" | grep -A2 "WorkflowTaskFailed"
    else
        log_ok "No WorkflowTaskFailed events"
    fi

    # Check for WorkflowTaskTimedOut
    if echo "$history" | grep -q "WorkflowTaskTimedOut"; then
        log_warn "Found WorkflowTaskTimedOut events — workflow task exceeded timeout"
        log_info "Possible causes: large history replay, deadlock, slow code"
    else
        log_ok "No WorkflowTaskTimedOut events"
    fi

    # Check for ActivityTaskTimedOut
    if echo "$history" | grep -q "ActivityTaskTimedOut"; then
        log_warn "Found ActivityTaskTimedOut events — activity exceeded timeout"
        echo "$history" | grep -B1 -A2 "ActivityTaskTimedOut"
    fi

    # Check for ActivityTaskFailed
    local fail_count
    fail_count=$(echo "$history" | grep -c "ActivityTaskFailed" || echo "0")
    if [[ "$fail_count" -gt 0 ]]; then
        log_warn "Found ${fail_count} ActivityTaskFailed events"
    fi

    # Check history size
    local event_count
    event_count=$(echo "$history" | grep -c "^  EventId" || echo "0")
    if [[ "$event_count" -gt 5000 ]]; then
        log_warn "History has ${event_count} events (recommend continueAsNew at 5000)"
    elif [[ "$event_count" -gt 10000 ]]; then
        log_error "History has ${event_count} events — approaching warn limit (10,240)"
    else
        log_ok "History size: ${event_count} events"
    fi
}

list_failed() {
    log_section "Failed Workflows (last ${LIMIT})"

    local output
    output=$($TEMPORAL_CMD workflow list \
        --query 'ExecutionStatus="Failed"' \
        --limit "$LIMIT" 2>/dev/null) || {
        log_warn "Could not list failed workflows"
        return 0
    }

    if [[ -z "$output" ]]; then
        log_ok "No failed workflows found"
    else
        echo "$output"
        echo ""
        local count
        count=$($TEMPORAL_CMD workflow count --query 'ExecutionStatus="Failed"' 2>/dev/null || echo "?")
        log_info "Total failed: ${count}"
    fi

    # Also check timed out
    log_section "Timed Out Workflows"
    $TEMPORAL_CMD workflow list \
        --query 'ExecutionStatus="TimedOut"' \
        --limit "$LIMIT" 2>/dev/null || log_info "None found"

    # Check terminated
    log_section "Terminated Workflows (last 5)"
    $TEMPORAL_CMD workflow list \
        --query 'ExecutionStatus="Terminated"' \
        --limit 5 2>/dev/null || log_info "None found"
}

find_stuck() {
    log_section "Stuck Workflows"

    log_info "Looking for workflows running longer than expected..."

    # List running workflows, sorted by start time
    local running
    running=$($TEMPORAL_CMD workflow list \
        --query 'ExecutionStatus="Running"' \
        --limit "$LIMIT" 2>/dev/null) || {
        log_warn "Could not list running workflows"
        return 0
    }

    if [[ -z "$running" ]]; then
        log_ok "No running workflows found"
        return 0
    fi

    echo "$running"

    local count
    count=$($TEMPORAL_CMD workflow count --query 'ExecutionStatus="Running"' 2>/dev/null || echo "?")
    log_info "Total running: ${count}"

    echo ""
    log_info "To inspect a specific workflow:"
    echo "  $0 --workflow <workflow-id>"
    echo ""
    log_info "To unstick a workflow:"
    echo "  temporal workflow reset --workflow-id <id> --type LastWorkflowTask --reason 'unstick'"
}

run_all() {
    log_section "Temporal Diagnostic Report"
    log_info "Server: ${ADDRESS}"
    log_info "Namespace: ${NAMESPACE}"
    log_info "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    check_server || return 1

    # Summary counts
    log_section "Workflow Summary"
    for status in Running Completed Failed TimedOut Terminated ContinuedAsNew Canceled; do
        local count
        count=$($TEMPORAL_CMD workflow count --query "ExecutionStatus=\"${status}\"" 2>/dev/null || echo "error")
        printf "  %-20s %s\n" "${status}:" "${count}"
    done

    # Check for failures
    local fail_count
    fail_count=$($TEMPORAL_CMD workflow count --query 'ExecutionStatus="Failed"' 2>/dev/null || echo "0")
    if [[ "$fail_count" != "0" && "$fail_count" != "error" ]]; then
        log_warn "Found ${fail_count} failed workflows"
        log_info "Run with --failed for details"
    fi

    echo ""
    log_ok "Diagnostic complete"
    log_info "For specific diagnostics:"
    echo "  $0 --queue <queue-name>     # Check a task queue"
    echo "  $0 --workflow <workflow-id>  # Diagnose a workflow"
    echo "  $0 --failed                 # List failed workflows"
    echo "  $0 --stuck                  # Find stuck workflows"
}

# Execute
case "$ACTION" in
    all)      run_all ;;
    server)   check_server ;;
    queue)    check_queue "$TASK_QUEUE" ;;
    workflow) check_workflow "$WORKFLOW_ID" ;;
    failed)   list_failed ;;
    stuck)    find_stuck ;;
esac
