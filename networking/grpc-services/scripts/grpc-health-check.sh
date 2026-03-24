#!/usr/bin/env bash
#
# grpc-health-check.sh — Health check a gRPC service using grpcurl.
#
# Usage:
#   ./grpc-health-check.sh <host:port> [service-name] [options]
#
# Arguments:
#   host:port      Target gRPC server (e.g., localhost:50051)
#   service-name   Optional: specific service to health-check
#
# Options:
#   --tls              Use TLS (default: plaintext)
#   --cacert <file>    CA certificate for TLS
#   --cert <file>      Client certificate (mTLS)
#   --key <file>       Client key (mTLS)
#   --list             List all services via reflection
#   --verbose          Show detailed output
#
# Examples:
#   ./grpc-health-check.sh localhost:50051
#   ./grpc-health-check.sh localhost:50051 acme.payments.v1.PaymentService
#   ./grpc-health-check.sh myhost:443 --tls --cacert ca.crt
#   ./grpc-health-check.sh localhost:50051 --list
#
# Requires: grpcurl (https://github.com/fullstorydev/grpcurl)

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Defaults ---
TLS_FLAG="-plaintext"
TLS_ARGS=""
LIST_SERVICES=false
VERBOSE=false
SERVICE=""
TARGET=""

# --- Argument parsing ---

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <host:port> [service-name] [options]"
    echo "  Run with --help for more options."
    exit 1
fi

TARGET="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tls)
            TLS_FLAG=""
            shift
            ;;
        --cacert)
            TLS_FLAG=""
            TLS_ARGS="$TLS_ARGS -cacert $2"
            shift 2
            ;;
        --cert)
            TLS_FLAG=""
            TLS_ARGS="$TLS_ARGS -cert $2"
            shift 2
            ;;
        --key)
            TLS_FLAG=""
            TLS_ARGS="$TLS_ARGS -key $2"
            shift 2
            ;;
        --list)
            LIST_SERVICES=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            head -30 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            if [[ -z "$SERVICE" ]]; then
                SERVICE="$1"
            else
                echo "Error: unexpected argument '$1'"
                exit 1
            fi
            shift
            ;;
    esac
done

# --- Check dependencies ---

if ! command -v grpcurl &> /dev/null; then
    echo -e "${RED}Error: grpcurl not found.${NC}"
    echo "Install: brew install grpcurl  or  go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest"
    exit 1
fi

# --- Build grpcurl flags ---
# shellcheck disable=SC2206
GRPC_FLAGS=($TLS_FLAG $TLS_ARGS)

# --- List services ---

if [[ "$LIST_SERVICES" == true ]]; then
    echo -e "${CYAN}Listing services on ${TARGET}...${NC}"
    echo ""
    if grpcurl "${GRPC_FLAGS[@]}" "$TARGET" list 2>/dev/null; then
        echo ""
        echo -e "${GREEN}Services listed successfully.${NC}"
    else
        echo -e "${RED}Failed to list services. Is reflection enabled?${NC}"
        exit 1
    fi
    exit 0
fi

# --- Health check ---

echo -e "${CYAN}Health checking ${TARGET}...${NC}"

# Build health check request
HEALTH_DATA="{}"
if [[ -n "$SERVICE" ]]; then
    HEALTH_DATA="{\"service\":\"$SERVICE\"}"
    echo -e "  Service: ${SERVICE}"
fi

# Run health check
RESULT=""
if RESULT=$(grpcurl "${GRPC_FLAGS[@]}" -d "$HEALTH_DATA" "$TARGET" grpc.health.v1.Health/Check 2>&1); then
    STATUS=$(echo "$RESULT" | grep -o '"status": *"[^"]*"' | head -1 | cut -d'"' -f4)

    case "$STATUS" in
        SERVING)
            echo -e "  Status:  ${GREEN}SERVING ✓${NC}"
            ;;
        NOT_SERVING)
            echo -e "  Status:  ${RED}NOT_SERVING ✗${NC}"
            exit 1
            ;;
        SERVICE_UNKNOWN)
            echo -e "  Status:  ${YELLOW}SERVICE_UNKNOWN ?${NC}"
            exit 1
            ;;
        *)
            echo -e "  Status:  ${YELLOW}${STATUS:-UNKNOWN}${NC}"
            if [[ "$VERBOSE" == true ]]; then
                echo "$RESULT"
            fi
            ;;
    esac
else
    # Health check failed
    if echo "$RESULT" | grep -q "UNIMPLEMENTED"; then
        echo -e "  Status:  ${YELLOW}Health service not implemented${NC}"
        echo ""
        echo "The server doesn't implement grpc.health.v1.Health."
        echo "Falling back to reflection check..."
        echo ""

        if grpcurl "${GRPC_FLAGS[@]}" "$TARGET" list &>/dev/null; then
            echo -e "  Reflection: ${GREEN}Available ✓${NC} (server is responding)"
            SERVICES=$(grpcurl "${GRPC_FLAGS[@]}" "$TARGET" list 2>/dev/null || true)
            SERVICE_COUNT=$(echo "$SERVICES" | grep -c '.' || true)
            echo -e "  Services:   ${SERVICE_COUNT} registered"
        else
            echo -e "  Reflection: ${RED}Not available${NC}"
            echo -e "  ${YELLOW}Server may be up but reflection is disabled.${NC}"
        fi
    else
        echo -e "  Status:  ${RED}UNREACHABLE ✗${NC}"
        if [[ "$VERBOSE" == true ]]; then
            echo ""
            echo "Error details:"
            echo "$RESULT"
        else
            # Show concise error
            ERROR_MSG=$(echo "$RESULT" | head -3)
            echo "  Error:   $ERROR_MSG"
        fi
        exit 1
    fi
fi

# --- Verbose: list services ---

if [[ "$VERBOSE" == true ]]; then
    echo ""
    echo -e "${CYAN}Registered services:${NC}"
    grpcurl "${GRPC_FLAGS[@]}" "$TARGET" list 2>/dev/null || echo "  (reflection not available)"
fi

echo ""
echo -e "${GREEN}Done.${NC}"
