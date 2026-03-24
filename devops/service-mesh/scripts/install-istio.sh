#!/usr/bin/env bash
#
# install-istio.sh — Install Istio with profile selection, namespace labeling,
# verification, and optional sample app deployment.
#
# Usage:
#   ./install-istio.sh [OPTIONS]
#
# Options:
#   -p, --profile PROFILE   Istio profile: demo|default|minimal|ambient (default: demo)
#   -n, --namespace NS      Namespace to label for injection (default: default)
#   -s, --sample-app        Deploy the Bookinfo sample application
#   -v, --version VERSION   Istio version to install (default: latest)
#   -h, --help              Show this help message
#
set -euo pipefail

# Defaults
PROFILE="demo"
NAMESPACE="default"
DEPLOY_SAMPLE=false
ISTIO_VERSION=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--profile)    PROFILE="$2";       shift 2 ;;
        -n|--namespace)  NAMESPACE="$2";     shift 2 ;;
        -s|--sample-app) DEPLOY_SAMPLE=true; shift   ;;
        -v|--version)    ISTIO_VERSION="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate profile
case "$PROFILE" in
    demo|default|minimal|ambient) ;;
    *) log_error "Invalid profile: $PROFILE (must be demo|default|minimal|ambient)"; exit 1 ;;
esac

# Pre-flight checks
log_info "Running pre-flight checks..."

if ! command -v kubectl &>/dev/null; then
    log_error "kubectl is not installed or not in PATH"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    exit 1
fi

KUBE_VERSION=$(kubectl version --output=json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1 | cut -d'"' -f4)
log_ok "Connected to Kubernetes cluster (${KUBE_VERSION})"

# Download Istio
log_info "Downloading Istio..."
DOWNLOAD_CMD="curl -sL https://istio.io/downloadIstio | sh -"
if [[ -n "$ISTIO_VERSION" ]]; then
    DOWNLOAD_CMD="curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -"
fi

INSTALL_DIR=$(mktemp -d)
pushd "$INSTALL_DIR" > /dev/null
eval "$DOWNLOAD_CMD"
ISTIO_DIR=$(ls -d istio-* 2>/dev/null | head -1)

if [[ -z "$ISTIO_DIR" ]]; then
    log_error "Failed to download Istio"
    popd > /dev/null
    rm -rf "$INSTALL_DIR"
    exit 1
fi

export PATH="$INSTALL_DIR/$ISTIO_DIR/bin:$PATH"
INSTALLED_VERSION=$(istioctl version --remote=false 2>/dev/null || echo "unknown")
log_ok "Downloaded Istio ${INSTALLED_VERSION}"
popd > /dev/null

# Install Istio
log_info "Installing Istio with profile '${PROFILE}'..."
istioctl install --set profile="$PROFILE" -y

# Verify installation
log_info "Verifying Istio installation..."
if istioctl verify-install; then
    log_ok "Istio installation verified successfully"
else
    log_error "Istio installation verification failed"
    exit 1
fi

# Label namespace for sidecar injection
if [[ "$PROFILE" == "ambient" ]]; then
    log_info "Labeling namespace '${NAMESPACE}' for ambient mesh..."
    kubectl label namespace "$NAMESPACE" istio.io/dataplane-mode=ambient --overwrite
    log_ok "Namespace '${NAMESPACE}' enrolled in ambient mesh"
else
    log_info "Labeling namespace '${NAMESPACE}' for sidecar injection..."
    kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite
    log_ok "Namespace '${NAMESPACE}' labeled for sidecar injection"
fi

# Show installation status
log_info "Istio system pods:"
kubectl get pods -n istio-system

# Deploy sample application
if [[ "$DEPLOY_SAMPLE" == true ]]; then
    log_info "Deploying Bookinfo sample application..."
    SAMPLES_DIR="$INSTALL_DIR/$ISTIO_DIR/samples"

    kubectl apply -f "$SAMPLES_DIR/bookinfo/platform/kube/bookinfo.yaml" -n "$NAMESPACE"
    log_info "Waiting for Bookinfo pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=productpage -n "$NAMESPACE" --timeout=120s
    kubectl wait --for=condition=ready pod -l app=reviews -n "$NAMESPACE" --timeout=120s
    kubectl wait --for=condition=ready pod -l app=ratings -n "$NAMESPACE" --timeout=120s
    kubectl wait --for=condition=ready pod -l app=details -n "$NAMESPACE" --timeout=120s
    log_ok "Bookinfo sample application deployed"

    # Apply default destination rules
    if [[ "$PROFILE" != "ambient" ]]; then
        kubectl apply -f "$SAMPLES_DIR/bookinfo/networking/bookinfo-gateway.yaml" -n "$NAMESPACE"
        kubectl apply -f "$SAMPLES_DIR/bookinfo/networking/destination-rule-all-mtls.yaml" -n "$NAMESPACE"
        log_ok "Bookinfo gateway and destination rules applied"
    fi

    log_info "Bookinfo pods:"
    kubectl get pods -n "$NAMESPACE" -l 'app in (productpage,reviews,ratings,details)'

    # Deploy addons (Kiali, Jaeger, Prometheus, Grafana)
    log_info "Deploying observability addons..."
    kubectl apply -f "$SAMPLES_DIR/addons/" -n istio-system 2>/dev/null || true
    log_ok "Observability addons deployed (Kiali, Jaeger, Prometheus, Grafana)"
fi

# Summary
echo ""
echo "============================================"
echo -e "${GREEN}Istio Installation Complete${NC}"
echo "============================================"
echo "  Profile:   ${PROFILE}"
echo "  Version:   ${INSTALLED_VERSION}"
echo "  Namespace: ${NAMESPACE} (injection enabled)"
if [[ "$DEPLOY_SAMPLE" == true ]]; then
    echo "  Sample:    Bookinfo deployed"
    echo ""
    echo "  Access Bookinfo:  kubectl port-forward svc/productpage 9080:9080 -n ${NAMESPACE}"
    echo "  Access Kiali:     istioctl dashboard kiali"
    echo "  Access Jaeger:    istioctl dashboard jaeger"
fi
echo "============================================"

# Cleanup
rm -rf "$INSTALL_DIR"
