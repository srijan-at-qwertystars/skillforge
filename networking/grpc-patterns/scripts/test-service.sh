#!/usr/bin/env bash
#
# test-service.sh — Test a gRPC service using grpcurl
#
# Usage:
#   ./test-service.sh                          # List services on localhost:50051
#   ./test-service.sh list                     # List all services
#   ./test-service.sh describe <service>       # Describe a service/method
#   ./test-service.sh call <method> [json]     # Call an RPC with optional JSON body
#   ./test-service.sh health [service]         # Health check
#   ./test-service.sh --host <host:port> ...   # Custom host
#
# Prerequisites: grpcurl (https://github.com/fullstorydev/grpcurl)

set -euo pipefail

# --- Defaults ---
HOST="localhost:50051"
TLS_FLAGS=("-plaintext")
PROTO_FLAGS=()
HEADERS=()

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] COMMAND [ARGS]

Commands:
  list                           List all services (requires reflection)
  describe <service|method>      Describe a service or method
  call <method> [json_data]      Call an RPC method with optional JSON body
  health [service_name]          Run gRPC health check
  methods <service>              List methods for a service

Options:
  --host HOST:PORT       Target host (default: localhost:50051)
  --tls                  Use TLS (disables -plaintext)
  --cacert FILE          CA certificate for TLS
  --cert FILE            Client certificate (mTLS)
  --key FILE             Client key (mTLS)
  --proto FILE           Use proto file instead of reflection
  --import-path DIR      Proto import path
  -H KEY:VALUE           Add request header (repeatable)
  -h, --help             Show this help

Examples:
  $(basename "$0") list
  $(basename "$0") describe orders.v1.OrderService
  $(basename "$0") call orders.v1.OrderService/CreateOrder '{"customer_id":"c1"}'
  $(basename "$0") health orders.v1.OrderService
  $(basename "$0") --host prod-api:443 --tls --cacert ca.crt list
  $(basename "$0") -H "authorization:Bearer tok123" call orders.v1.OrderService/GetOrder '{"id":"o1"}'
EOF
    exit 0
}

log_info()  { echo -e "${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }
log_cmd()   { echo -e "${CYAN}→${NC} $*"; }

# --- Parse global options ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        HOST="$2"; shift 2 ;;
        --tls)         TLS_FLAGS=(); shift ;;
        --cacert)      TLS_FLAGS=("-cacert" "$2"); shift 2 ;;
        --cert)        TLS_FLAGS+=("-cert" "$2"); shift 2 ;;
        --key)         TLS_FLAGS+=("-key" "$2"); shift 2 ;;
        --proto)       PROTO_FLAGS+=("-proto" "$2"); shift 2 ;;
        --import-path) PROTO_FLAGS+=("-import-path" "$2"); shift 2 ;;
        -H)            HEADERS+=("-H" "$2"); shift 2 ;;
        -h|--help)     usage ;;
        -*)            log_error "Unknown option: $1"; usage ;;
        *)             break ;;
    esac
done

# Check grpcurl is installed
if ! command -v grpcurl &>/dev/null; then
    log_error "grpcurl is not installed."
    echo "Install: https://github.com/fullstorydev/grpcurl#installation"
    echo "  brew install grpcurl        # macOS"
    echo "  go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest  # Go"
    exit 1
fi

COMMAND="${1:-list}"
shift || true

run_grpcurl() {
    grpcurl "${TLS_FLAGS[@]}" "${PROTO_FLAGS[@]+"${PROTO_FLAGS[@]}"}" "${HEADERS[@]+"${HEADERS[@]}"}" "$@" "$HOST"
}

case "$COMMAND" in
    list)
        log_cmd "grpcurl ${TLS_FLAGS[*]} $HOST list"
        echo ""
        SERVICES=$(run_grpcurl list 2>&1) || {
            log_error "Failed to list services. Is reflection enabled?"
            echo "$SERVICES"
            exit 1
        }
        echo "$SERVICES" | while IFS= read -r svc; do
            if [[ "$svc" == grpc.reflection.* ]]; then
                echo -e "  ${CYAN}$svc${NC} (reflection)"
            elif [[ "$svc" == grpc.health.* ]]; then
                echo -e "  ${GREEN}$svc${NC} (health)"
            elif [[ "$svc" == grpc.channelz.* ]]; then
                echo -e "  ${YELLOW}$svc${NC} (channelz)"
            else
                echo -e "  $svc"
            fi
        done
        echo ""
        log_info "Found $(echo "$SERVICES" | wc -l | tr -d ' ') services"
        ;;

    describe)
        TARGET="${1:?Usage: describe <service|method>}"
        log_cmd "grpcurl ${TLS_FLAGS[*]} $HOST describe $TARGET"
        echo ""
        run_grpcurl describe "$TARGET"
        ;;

    methods)
        SERVICE="${1:?Usage: methods <service>}"
        log_cmd "Listing methods for $SERVICE"
        echo ""
        run_grpcurl describe "$SERVICE" | grep -E '^\s+rpc\s' | while IFS= read -r method; do
            echo -e "  ${GREEN}${method}${NC}"
        done
        ;;

    call)
        METHOD="${1:?Usage: call <fully.qualified.Service/Method> [json_data]}"
        shift
        DATA="${1:-}"

        if [[ -n "$DATA" ]]; then
            log_cmd "grpcurl ${TLS_FLAGS[*]} -d '$DATA' $HOST $METHOD"
            echo ""
            run_grpcurl -d "$DATA" "$METHOD"
        else
            log_cmd "grpcurl ${TLS_FLAGS[*]} $HOST $METHOD"
            echo ""
            run_grpcurl -d '{}' "$METHOD"
        fi
        ;;

    health)
        SERVICE="${1:-}"
        if [[ -n "$SERVICE" ]]; then
            DATA="{\"service\":\"$SERVICE\"}"
            log_cmd "Health check for service: $SERVICE"
        else
            DATA='{}'
            log_cmd "Health check (overall)"
        fi
        echo ""

        RESULT=$(run_grpcurl -d "$DATA" grpc.health.v1.Health/Check 2>&1) || {
            log_error "Health check failed"
            echo "$RESULT"
            exit 1
        }
        echo "$RESULT"

        if echo "$RESULT" | grep -q '"SERVING"'; then
            log_info "Service is SERVING"
        elif echo "$RESULT" | grep -q '"NOT_SERVING"'; then
            log_error "Service is NOT_SERVING"
            exit 1
        else
            log_warn "Unknown health status"
        fi
        ;;

    *)
        log_error "Unknown command: $COMMAND"
        usage
        ;;
esac
