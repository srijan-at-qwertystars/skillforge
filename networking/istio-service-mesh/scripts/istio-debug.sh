#!/usr/bin/env bash
# istio-debug.sh — Debug Istio mesh issues
# Usage: ./istio-debug.sh [command] [pod] [namespace]
#
# Commands:
#   status     — Proxy sync status overview (default)
#   config     — Dump proxy config for a pod
#   mtls       — Check mTLS status
#   analyze    — Run istioctl analyze
#   logs       — Tail Envoy proxy logs
#   endpoints  — Show endpoints for a pod
#   certs      — Check certificate info
#   metrics    — Show key Envoy metrics
#   all        — Run all checks

set -euo pipefail

COMMAND="${1:-status}"
POD="${2:-}"
NAMESPACE="${3:-default}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

header() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}\n"; }
log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_pod() {
    if [[ -z "$POD" ]]; then
        error "Pod name required. Usage: $0 $COMMAND <pod> [namespace]"
        echo ""
        echo "Available pods with sidecars in namespace '$NAMESPACE':"
        kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}' | grep istio-proxy || true
        exit 1
    fi
}

cmd_status() {
    header "Proxy Sync Status"
    istioctl proxy-status 2>&1 || true

    echo ""
    header "Istio System Health"
    kubectl get pods -n istio-system -o wide 2>&1

    echo ""
    header "Injection-Enabled Namespaces"
    kubectl get namespaces -l istio-injection=enabled --no-headers 2>/dev/null || true
    kubectl get namespaces -l 'istio.io/rev' --no-headers 2>/dev/null || true
}

cmd_config() {
    require_pod
    local fqpod="$POD"
    [[ "$fqpod" != *.* ]] && fqpod="$POD.$NAMESPACE"

    header "Listeners — $fqpod"
    istioctl proxy-config listeners "$fqpod" 2>&1 | head -30

    header "Routes — $fqpod"
    istioctl proxy-config routes "$fqpod" 2>&1 | head -30

    header "Clusters — $fqpod"
    istioctl proxy-config clusters "$fqpod" 2>&1 | head -30

    header "Endpoints — $fqpod"
    istioctl proxy-config endpoints "$fqpod" --status healthy 2>&1 | head -30

    echo ""
    log "Use 'istioctl proxy-config <section> $fqpod -o json' for full details."
}

cmd_mtls() {
    header "mTLS Status"

    echo "PeerAuthentication policies:"
    kubectl get peerauthentication --all-namespaces 2>&1 || echo "  (none)"

    echo ""
    if [[ -n "$POD" ]]; then
        local fqpod="$POD"
        [[ "$fqpod" != *.* ]] && fqpod="$POD.$NAMESPACE"
        echo "mTLS check for $fqpod:"
        istioctl authn tls-check "$fqpod" 2>&1 | head -20 || true
    else
        echo "DestinationRule TLS settings:"
        kubectl get destinationrules --all-namespaces -o json 2>/dev/null | \
            jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.spec.trafficPolicy.tls.mode // "not set")"' 2>/dev/null || echo "  (none)"
    fi

    echo ""
    echo "Plaintext traffic check (requires Prometheus):"
    echo "  Query: istio_requests_total{connection_security_policy=\"none\"}"
}

cmd_analyze() {
    header "Config Analysis"

    if [[ "$NAMESPACE" == "all" ]]; then
        istioctl analyze --all-namespaces 2>&1
    else
        istioctl analyze -n "$NAMESPACE" 2>&1
    fi
}

cmd_logs() {
    require_pod
    header "Envoy Proxy Logs — $POD ($NAMESPACE)"

    echo "Recent logs (last 50 lines):"
    kubectl logs "$POD" -c istio-proxy -n "$NAMESPACE" --tail=50 2>&1

    echo ""
    log "For streaming: kubectl logs $POD -c istio-proxy -n $NAMESPACE -f"
    log "For debug level: istioctl proxy-config log $POD.$NAMESPACE --level debug"
}

cmd_endpoints() {
    require_pod
    local fqpod="$POD"
    [[ "$fqpod" != *.* ]] && fqpod="$POD.$NAMESPACE"

    header "Endpoints visible to $fqpod"
    istioctl proxy-config endpoints "$fqpod" 2>&1

    echo ""
    header "Kubernetes Endpoints in $NAMESPACE"
    kubectl get endpoints -n "$NAMESPACE" 2>&1
}

cmd_certs() {
    require_pod
    local fqpod="$POD"
    [[ "$fqpod" != *.* ]] && fqpod="$POD.$NAMESPACE"

    header "Certificate Info — $fqpod"
    istioctl proxy-config secret "$fqpod" 2>&1

    echo ""
    echo "Certificate details:"
    istioctl proxy-config secret "$fqpod" -o json 2>/dev/null | \
        jq -r '.[0].certificate_chain.inline_bytes // empty' | \
        base64 -d 2>/dev/null | \
        openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || \
        warn "Could not decode certificate."
}

cmd_metrics() {
    require_pod
    header "Key Envoy Metrics — $POD ($NAMESPACE)"

    local stats
    stats=$(kubectl exec "$POD" -c istio-proxy -n "$NAMESPACE" -- \
        pilot-agent request GET /stats 2>/dev/null) || {
        error "Failed to get stats from $POD."
        return 1
    }

    echo "Connection metrics:"
    echo "$stats" | grep -E "upstream_cx_total|upstream_cx_active|upstream_cx_connect_fail" | head -10

    echo ""
    echo "Request metrics:"
    echo "$stats" | grep -E "upstream_rq_total|upstream_rq_active|upstream_rq_[2345]xx" | head -10

    echo ""
    echo "Circuit breaker metrics:"
    echo "$stats" | grep -E "upstream_rq_pending_overflow|upstream_cx_overflow|outlier_detection" | head -10

    echo ""
    echo "Retry metrics:"
    echo "$stats" | grep -E "upstream_rq_retry" | head -10
}

cmd_all() {
    cmd_status
    if [[ -n "$POD" ]]; then
        cmd_config
        cmd_mtls
        cmd_logs
        cmd_certs
        cmd_metrics
    else
        cmd_mtls
    fi
    cmd_analyze
}

usage() {
    echo "Usage: $0 <command> [pod] [namespace]"
    echo ""
    echo "Commands:"
    echo "  status     Proxy sync status overview (default)"
    echo "  config     Dump proxy config for a pod (requires pod)"
    echo "  mtls       Check mTLS status"
    echo "  analyze    Run istioctl analyze"
    echo "  logs       Tail Envoy proxy logs (requires pod)"
    echo "  endpoints  Show endpoints for a pod (requires pod)"
    echo "  certs      Check certificate info (requires pod)"
    echo "  metrics    Show key Envoy metrics (requires pod)"
    echo "  all        Run all checks"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 config productpage-v1-abc123 default"
    echo "  $0 mtls reviews-v1-xyz789 production"
    echo "  $0 analyze all   # analyze all namespaces"
    echo "  $0 all productpage-v1-abc123 default"
}

case "$COMMAND" in
    status)    cmd_status ;;
    config)    cmd_config ;;
    mtls)      cmd_mtls ;;
    analyze)   cmd_analyze ;;
    logs)      cmd_logs ;;
    endpoints) cmd_endpoints ;;
    certs)     cmd_certs ;;
    metrics)   cmd_metrics ;;
    all)       cmd_all ;;
    help|-h|--help) usage ;;
    *)
        error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
