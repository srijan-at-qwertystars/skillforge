#!/usr/bin/env bash
# setup-dev.sh — Set up a local Temporal development environment
#
# Usage:
#   ./setup-dev.sh              # Start Temporal dev server with defaults
#   ./setup-dev.sh --persist    # Start with persistent storage (survives restarts)
#   ./setup-dev.sh --port 7233  # Use a custom gRPC port
#   ./setup-dev.sh --stop       # Stop running dev server
#   ./setup-dev.sh --status     # Check if dev server is running

set -euo pipefail

# Defaults
PERSIST=false
GRPC_PORT=7233
UI_PORT=8233
NAMESPACE="default"
DB_FILE=""
ACTION="start"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --persist         Persist data across restarts (creates temporal.db)"
    echo "  --port PORT       gRPC port (default: 7233)"
    echo "  --ui-port PORT    Web UI port (default: 8233)"
    echo "  --namespace NS    Default namespace (default: 'default')"
    echo "  --stop            Stop the running dev server"
    echo "  --status          Check dev server status"
    echo "  -h, --help        Show this help"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --persist)    PERSIST=true; shift ;;
        --port)       GRPC_PORT="$2"; shift 2 ;;
        --ui-port)    UI_PORT="$2"; shift 2 ;;
        --namespace)  NAMESPACE="$2"; shift 2 ;;
        --stop)       ACTION="stop"; shift ;;
        --status)     ACTION="status"; shift ;;
        -h|--help)    usage ;;
        *)            log_error "Unknown option: $1"; usage ;;
    esac
done

check_temporal_cli() {
    if command -v temporal &>/dev/null; then
        log_ok "Temporal CLI found: $(temporal --version 2>/dev/null || echo 'unknown version')"
        return 0
    fi

    log_warn "Temporal CLI not found. Installing..."

    if command -v brew &>/dev/null; then
        brew install temporal
    elif command -v go &>/dev/null; then
        go install go.temporal.io/cli/cmd/temporal@latest
    elif command -v npm &>/dev/null; then
        npm install -g @temporalio/cli
    else
        log_error "Cannot auto-install Temporal CLI. Install manually:"
        echo "  brew install temporal"
        echo "  go install go.temporal.io/cli/cmd/temporal@latest"
        echo "  curl -sSf https://temporal.download/cli.sh | sh"
        exit 1
    fi
}

stop_server() {
    log_info "Stopping Temporal dev server..."
    if pgrep -f "temporal server start-dev" &>/dev/null; then
        pkill -f "temporal server start-dev" 2>/dev/null || true
        sleep 2
        log_ok "Dev server stopped"
    else
        log_warn "No running dev server found"
    fi
}

check_status() {
    if pgrep -f "temporal server start-dev" &>/dev/null; then
        log_ok "Temporal dev server is running"
        log_info "gRPC: localhost:${GRPC_PORT}"
        log_info "Web UI: http://localhost:${UI_PORT}"

        # Check health
        if command -v temporal &>/dev/null; then
            if temporal operator cluster health 2>/dev/null | grep -q "SERVING"; then
                log_ok "Server is healthy (SERVING)"
            else
                log_warn "Server is running but may not be ready yet"
            fi
        fi
    else
        log_warn "Temporal dev server is NOT running"
        log_info "Start with: $0"
    fi
}

start_server() {
    check_temporal_cli

    # Check if already running
    if pgrep -f "temporal server start-dev" &>/dev/null; then
        log_warn "Dev server is already running. Use --stop first or --status to check."
        check_status
        return 0
    fi

    # Build command
    local cmd="temporal server start-dev"
    cmd+=" --port ${GRPC_PORT}"
    cmd+=" --ui-port ${UI_PORT}"
    cmd+=" --namespace ${NAMESPACE}"

    if [[ "$PERSIST" == "true" ]]; then
        DB_FILE="temporal-dev.db"
        cmd+=" --db-filename ${DB_FILE}"
        log_info "Persistent mode: data stored in ${DB_FILE}"
    fi

    log_info "Starting Temporal dev server..."
    log_info "  gRPC port:  ${GRPC_PORT}"
    log_info "  UI port:    ${UI_PORT}"
    log_info "  Namespace:  ${NAMESPACE}"
    echo ""

    # Start in background
    $cmd &
    local pid=$!
    echo "$pid" > /tmp/temporal-dev-server.pid

    # Wait for server to be ready
    log_info "Waiting for server to be ready..."
    local retries=0
    local max_retries=30
    while [[ $retries -lt $max_retries ]]; do
        if temporal operator cluster health 2>/dev/null | grep -q "SERVING"; then
            break
        fi
        retries=$((retries + 1))
        sleep 1
    done

    if [[ $retries -ge $max_retries ]]; then
        log_warn "Server may still be starting. Check with: $0 --status"
    else
        echo ""
        log_ok "Temporal dev server is ready!"
        log_info "  gRPC endpoint: localhost:${GRPC_PORT}"
        log_info "  Web UI:        http://localhost:${UI_PORT}"
        log_info "  PID:           ${pid}"
        echo ""
        log_info "Quick test:"
        echo "  temporal workflow start --task-queue test --type HelloWorld --input '\"world\"'"
        echo ""
        log_info "Stop with: $0 --stop"
    fi
}

# Execute action
case "$ACTION" in
    start)  start_server ;;
    stop)   stop_server ;;
    status) check_status ;;
esac
