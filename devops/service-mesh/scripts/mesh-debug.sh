#!/usr/bin/env bash
#
# mesh-debug.sh — Service mesh debugging toolkit.
# Inspects proxy status, config, listeners, routes, clusters, and certificates.
#
# Usage:
#   ./mesh-debug.sh <command> [OPTIONS]
#
# Commands:
#   status              Show proxy sync status for all pods
#   config <pod>        Dump Envoy config for a pod
#   listeners <pod>     Show listeners (ports/protocols) for a pod
#   routes <pod>        Show route configuration for a pod
#   clusters <pod>      Show upstream clusters for a pod
#   endpoints <pod>     Show endpoints for a pod
#   certs <pod>         Check certificates and expiry for a pod
#   analyze [ns]        Run istioctl analyze on a namespace (default: all)
#   overview            Full mesh overview: versions, policies, config issues
#   connectivity <src> <dst>  Test connectivity and mTLS between two pods
#
# Options:
#   -n, --namespace NS  Namespace (default: default)
#   -o, --output FMT    Output format: short|json|yaml (default: short)
#   -h, --help          Show this help message
#
set -euo pipefail

NAMESPACE="default"
OUTPUT="short"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_section() { echo -e "\n${CYAN}=== $* ===${NC}"; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
    echo ""
    sed -n '/^# Commands:/,/^# Options:/p' "$0" | head -n -1 | sed 's/^# //' | sed 's/^#//'
    exit 0
}

require_pod() {
    if [[ -z "${1:-}" ]]; then
        log_error "Pod name required. Usage: $0 $COMMAND <pod> [-n namespace]"
        exit 1
    fi
}

require_istioctl() {
    if ! command -v istioctl &>/dev/null; then
        log_error "istioctl is not installed or not in PATH"
        exit 1
    fi
}

get_output_flag() {
    case "$OUTPUT" in
        json) echo "-o json" ;;
        yaml) echo "-o yaml" ;;
        *)    echo "" ;;
    esac
}

# Parse command
COMMAND="${1:-help}"
shift || true

# Parse remaining arguments
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -o|--output)    OUTPUT="$2";    shift 2 ;;
        -h|--help)      usage ;;
        -*)             log_error "Unknown option: $1"; usage ;;
        *)              POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

require_istioctl

case "$COMMAND" in
    status)
        log_section "Proxy Sync Status"
        istioctl proxy-status
        echo ""
        log_info "Legend: SYNCED=up-to-date, STALE=outdated config, NOT SENT=no config pushed"
        ;;

    config)
        POD="${POSITIONAL_ARGS[0]:-}"
        require_pod "$POD"
        log_section "Envoy Config Dump: $POD"
        OUTPUT_FLAG=$(get_output_flag)
        # shellcheck disable=SC2086
        istioctl proxy-config all "$POD" -n "$NAMESPACE" $OUTPUT_FLAG
        ;;

    listeners)
        POD="${POSITIONAL_ARGS[0]:-}"
        require_pod "$POD"
        log_section "Listeners: $POD"
        OUTPUT_FLAG=$(get_output_flag)
        # shellcheck disable=SC2086
        istioctl proxy-config listeners "$POD" -n "$NAMESPACE" $OUTPUT_FLAG
        echo ""
        LISTENER_COUNT=$(istioctl proxy-config listeners "$POD" -n "$NAMESPACE" 2>/dev/null | tail -n +2 | wc -l)
        log_info "Total listeners: $LISTENER_COUNT"
        ;;

    routes)
        POD="${POSITIONAL_ARGS[0]:-}"
        require_pod "$POD"
        log_section "Routes: $POD"
        OUTPUT_FLAG=$(get_output_flag)
        # shellcheck disable=SC2086
        istioctl proxy-config routes "$POD" -n "$NAMESPACE" $OUTPUT_FLAG
        echo ""
        ROUTE_COUNT=$(istioctl proxy-config routes "$POD" -n "$NAMESPACE" 2>/dev/null | tail -n +2 | wc -l)
        log_info "Total route entries: $ROUTE_COUNT"
        ;;

    clusters)
        POD="${POSITIONAL_ARGS[0]:-}"
        require_pod "$POD"
        log_section "Clusters: $POD"
        OUTPUT_FLAG=$(get_output_flag)
        # shellcheck disable=SC2086
        istioctl proxy-config clusters "$POD" -n "$NAMESPACE" $OUTPUT_FLAG
        echo ""
        CLUSTER_COUNT=$(istioctl proxy-config clusters "$POD" -n "$NAMESPACE" 2>/dev/null | tail -n +2 | wc -l)
        log_info "Total clusters: $CLUSTER_COUNT"
        ;;

    endpoints)
        POD="${POSITIONAL_ARGS[0]:-}"
        require_pod "$POD"
        log_section "Endpoints: $POD"
        OUTPUT_FLAG=$(get_output_flag)
        # shellcheck disable=SC2086
        istioctl proxy-config endpoints "$POD" -n "$NAMESPACE" $OUTPUT_FLAG
        ;;

    certs)
        POD="${POSITIONAL_ARGS[0]:-}"
        require_pod "$POD"
        log_section "Certificate Status: $POD"

        echo -e "\n${YELLOW}Active Certificates:${NC}"
        istioctl proxy-config secret "$POD" -n "$NAMESPACE"

        echo -e "\n${YELLOW}Certificate Details:${NC}"
        CERT_DATA=$(istioctl proxy-config secret "$POD" -n "$NAMESPACE" -o json 2>/dev/null)

        if echo "$CERT_DATA" | python3 -c "
import json, sys, base64, subprocess
data = json.load(sys.stdin)
for secret in data.get('dynamicActiveSecrets', []):
    name = secret.get('name', 'unknown')
    tls_cert = secret.get('secret', {}).get('tlsCertificate', {})
    chain = tls_cert.get('certificateChain', {}).get('inlineBytes', '')
    if chain:
        cert_pem = base64.b64decode(chain)
        result = subprocess.run(['openssl', 'x509', '-text', '-noout', '-dates'],
            input=cert_pem, capture_output=True)
        dates = result.stdout.decode()
        for line in dates.split('\n'):
            line = line.strip()
            if line.startswith('Not Before') or line.startswith('Not After'):
                print(f'  {name}: {line}')
            if 'Subject:' in line:
                print(f'  {name}: {line}')
" 2>/dev/null; then
            log_ok "Certificate inspection complete"
        else
            log_warn "Could not parse certificate details. Use: istioctl proxy-config secret $POD -n $NAMESPACE -o json"
        fi
        ;;

    analyze)
        TARGET_NS="${POSITIONAL_ARGS[0]:-}"
        if [[ -n "$TARGET_NS" ]]; then
            log_section "Configuration Analysis: namespace $TARGET_NS"
            istioctl analyze -n "$TARGET_NS"
        else
            log_section "Configuration Analysis: all namespaces"
            istioctl analyze --all-namespaces
        fi
        ;;

    overview)
        log_section "Mesh Overview"

        echo -e "\n${YELLOW}Istio Version:${NC}"
        istioctl version

        echo -e "\n${YELLOW}Control Plane Pods:${NC}"
        kubectl get pods -n istio-system -o wide 2>/dev/null || log_warn "Cannot list istio-system pods"

        echo -e "\n${YELLOW}Injection-Enabled Namespaces:${NC}"
        kubectl get namespaces -l istio-injection=enabled --no-headers 2>/dev/null || echo "  (none with sidecar injection)"
        kubectl get namespaces -l istio.io/dataplane-mode=ambient --no-headers 2>/dev/null || echo "  (none with ambient mode)"

        echo -e "\n${YELLOW}Mesh Policies:${NC}"
        echo "  PeerAuthentication:"
        kubectl get peerauthentication -A --no-headers 2>/dev/null || echo "    (none)"
        echo "  AuthorizationPolicy:"
        kubectl get authorizationpolicy -A --no-headers 2>/dev/null || echo "    (none)"

        echo -e "\n${YELLOW}Traffic Config:${NC}"
        echo "  VirtualServices:     $(kubectl get virtualservice -A --no-headers 2>/dev/null | wc -l)"
        echo "  DestinationRules:    $(kubectl get destinationrule -A --no-headers 2>/dev/null | wc -l)"
        echo "  Gateways:            $(kubectl get gateway -A --no-headers 2>/dev/null | wc -l)"
        echo "  ServiceEntries:      $(kubectl get serviceentry -A --no-headers 2>/dev/null | wc -l)"
        echo "  EnvoyFilters:        $(kubectl get envoyfilter -A --no-headers 2>/dev/null | wc -l)"

        echo -e "\n${YELLOW}Configuration Analysis:${NC}"
        istioctl analyze --all-namespaces 2>&1 | head -20
        ;;

    connectivity)
        SRC_POD="${POSITIONAL_ARGS[0]:-}"
        DST="${POSITIONAL_ARGS[1]:-}"
        require_pod "$SRC_POD"
        if [[ -z "$DST" ]]; then
            log_error "Destination required. Usage: $0 connectivity <src-pod> <dst-service>"
            exit 1
        fi

        log_section "Connectivity Test: $SRC_POD → $DST"

        echo -e "\n${YELLOW}Source Proxy Status:${NC}"
        istioctl proxy-status | grep "$SRC_POD" || log_warn "Source pod not found in mesh"

        echo -e "\n${YELLOW}mTLS Check:${NC}"
        istioctl authn tls-check "$SRC_POD.$NAMESPACE" "$DST" 2>/dev/null || \
            log_warn "Could not check mTLS status (command may not be available in this Istio version)"

        echo -e "\n${YELLOW}Endpoint Health:${NC}"
        istioctl proxy-config endpoints "$SRC_POD" -n "$NAMESPACE" 2>/dev/null | grep "$DST" | head -10

        echo -e "\n${YELLOW}Route to Destination:${NC}"
        istioctl proxy-config routes "$SRC_POD" -n "$NAMESPACE" 2>/dev/null | grep "$DST" | head -10
        ;;

    help|--help|-h)
        usage
        ;;

    *)
        log_error "Unknown command: $COMMAND"
        usage
        ;;
esac
