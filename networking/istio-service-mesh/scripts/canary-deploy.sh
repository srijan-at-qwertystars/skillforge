#!/usr/bin/env bash
# canary-deploy.sh — Perform a canary deployment with Istio traffic splitting
# Usage: ./canary-deploy.sh <service> <namespace> <stable-version> <canary-version> [--auto]
#
# Gradually shifts traffic from stable to canary version using Istio VirtualService.
# Use --auto to skip confirmation prompts between weight shifts.

set -euo pipefail

SERVICE="${1:-}"
NAMESPACE="${2:-default}"
STABLE_VERSION="${3:-}"
CANARY_VERSION="${4:-}"
AUTO_MODE="${5:-}"

# Traffic shift progression (percentages to canary)
WEIGHT_STEPS=(5 10 25 50 75 100)
PAUSE_SECONDS=30

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${CYAN}── $* ──${NC}"; }

usage() {
    echo "Usage: $0 <service> <namespace> <stable-version> <canary-version> [--auto]"
    echo ""
    echo "Arguments:"
    echo "  service          Kubernetes service name"
    echo "  namespace        Target namespace"
    echo "  stable-version   Stable subset version label (e.g., v1)"
    echo "  canary-version   Canary subset version label (e.g., v2)"
    echo "  --auto           Skip confirmation prompts between weight shifts"
    echo ""
    echo "Example:"
    echo "  $0 reviews default v1 v2"
    echo "  $0 api-server production v3 v4 --auto"
    exit 1
}

if [[ -z "$SERVICE" || -z "$STABLE_VERSION" || -z "$CANARY_VERSION" ]]; then
    usage
fi

validate_prerequisites() {
    log "Validating prerequisites..."

    if ! command -v istioctl &>/dev/null; then
        error "istioctl not found in PATH."
        exit 1
    fi

    if ! kubectl get svc "$SERVICE" -n "$NAMESPACE" &>/dev/null; then
        error "Service '$SERVICE' not found in namespace '$NAMESPACE'."
        exit 1
    fi

    local stable_pods canary_pods
    stable_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE,version=$STABLE_VERSION" --no-headers 2>/dev/null | wc -l)
    canary_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE,version=$CANARY_VERSION" --no-headers 2>/dev/null | wc -l)

    if [[ "$stable_pods" -eq 0 ]]; then
        error "No pods found with labels app=$SERVICE,version=$STABLE_VERSION in $NAMESPACE."
        exit 1
    fi
    if [[ "$canary_pods" -eq 0 ]]; then
        error "No pods found with labels app=$SERVICE,version=$CANARY_VERSION in $NAMESPACE."
        exit 1
    fi

    log "Found $stable_pods stable pod(s) and $canary_pods canary pod(s)."
}

ensure_destination_rule() {
    header "DestinationRule"

    if kubectl get destinationrule "${SERVICE}-dr" -n "$NAMESPACE" &>/dev/null; then
        log "DestinationRule '${SERVICE}-dr' already exists."
        return
    fi

    log "Creating DestinationRule with subsets..."
    cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ${SERVICE}-dr
  namespace: ${NAMESPACE}
spec:
  host: ${SERVICE}
  trafficPolicy:
    loadBalancer:
      simple: LEAST_REQUEST
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: stable
      labels:
        version: "${STABLE_VERSION}"
    - name: canary
      labels:
        version: "${CANARY_VERSION}"
EOF
}

apply_traffic_split() {
    local canary_weight=$1
    local stable_weight=$((100 - canary_weight))

    cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ${SERVICE}-canary
  namespace: ${NAMESPACE}
spec:
  hosts:
    - ${SERVICE}
  http:
    - route:
        - destination:
            host: ${SERVICE}
            subset: stable
          weight: ${stable_weight}
        - destination:
            host: ${SERVICE}
            subset: canary
          weight: ${canary_weight}
EOF

    log "Traffic split: stable=${stable_weight}% canary=${canary_weight}%"
}

check_canary_health() {
    local canary_weight=$1

    log "Checking canary health..."

    # Check pod readiness
    local not_ready
    not_ready=$(kubectl get pods -n "$NAMESPACE" -l "app=$SERVICE,version=$CANARY_VERSION" \
        --no-headers 2>/dev/null | grep -cv "Running" || true)

    if [[ "$not_ready" -gt 0 ]]; then
        warn "Some canary pods are not running ($not_ready unhealthy)."
        return 1
    fi

    # Check for 5xx errors via istioctl (if available)
    if istioctl proxy-status &>/dev/null 2>&1; then
        local stale
        stale=$(istioctl proxy-status 2>/dev/null | grep -c "STALE" || true)
        if [[ "$stale" -gt 0 ]]; then
            warn "$stale proxy(ies) have STALE config."
        fi
    fi

    log "Canary health check passed at ${canary_weight}%."
    return 0
}

rollback() {
    header "ROLLBACK"
    warn "Rolling back to 100% stable traffic..."

    apply_traffic_split 0
    log "Rollback complete. All traffic routed to stable ($STABLE_VERSION)."
    exit 1
}

promote() {
    header "PROMOTION COMPLETE"
    log "Canary ($CANARY_VERSION) is now receiving 100% of traffic."
    log ""
    log "Next steps:"
    log "  1. Update the stable deployment to $CANARY_VERSION"
    log "  2. Remove the canary VirtualService:"
    log "     kubectl delete vs ${SERVICE}-canary -n ${NAMESPACE}"
    log "  3. Update the DestinationRule subsets"
}

run_canary() {
    header "Canary Deployment: $SERVICE"
    echo "  Namespace: $NAMESPACE"
    echo "  Stable:    $STABLE_VERSION"
    echo "  Canary:    $CANARY_VERSION"
    echo "  Steps:     ${WEIGHT_STEPS[*]}%"
    echo ""

    validate_prerequisites
    ensure_destination_rule

    # Start with 0% canary
    apply_traffic_split 0

    for weight in "${WEIGHT_STEPS[@]}"; do
        header "Shifting to ${weight}% canary"

        if [[ "$AUTO_MODE" != "--auto" ]]; then
            echo ""
            echo "Press ENTER to shift to ${weight}% canary, 'r' to rollback, or 's' to skip to 100%:"
            read -r response
            case "$response" in
                r|R) rollback ;;
                s|S) weight=100 ;;
            esac
        fi

        apply_traffic_split "$weight"

        if [[ "$weight" -lt 100 ]]; then
            log "Waiting ${PAUSE_SECONDS}s before health check..."
            sleep "$PAUSE_SECONDS"

            if ! check_canary_health "$weight"; then
                error "Canary health check failed at ${weight}%."
                if [[ "$AUTO_MODE" == "--auto" ]]; then
                    rollback
                else
                    echo "Press ENTER to continue anyway, or 'r' to rollback:"
                    read -r response
                    [[ "$response" == "r" || "$response" == "R" ]] && rollback
                fi
            fi
        fi
    done

    promote
}

trap rollback ERR
run_canary
