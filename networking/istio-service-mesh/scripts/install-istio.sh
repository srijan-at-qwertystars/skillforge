#!/usr/bin/env bash
# install-istio.sh — Install Istio on a Kubernetes cluster
# Usage: ./install-istio.sh [profile] [namespace]
#   profile:   default | demo | minimal | production (default: default)
#   namespace: namespace to enable sidecar injection (default: default)

set -euo pipefail

ISTIO_PROFILE="${1:-default}"
TARGET_NS="${2:-default}"
ISTIO_VERSION="${ISTIO_VERSION:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v kubectl &>/dev/null; then
        error "kubectl not found. Install it first."
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi

    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "$nodes" -eq 0 ]]; then
        error "No nodes found in the cluster."
        exit 1
    fi
    log "Cluster has $nodes node(s)."
}

download_istioctl() {
    if command -v istioctl &>/dev/null; then
        local current_version
        current_version=$(istioctl version --remote=false 2>/dev/null || echo "unknown")
        log "istioctl already installed (version: $current_version)."
        if [[ -n "$ISTIO_VERSION" && "$current_version" != *"$ISTIO_VERSION"* ]]; then
            warn "Requested version $ISTIO_VERSION differs from installed $current_version."
            warn "Set ISTIO_VERSION='' to use the installed version, or proceeding with download."
        else
            return 0
        fi
    fi

    log "Downloading istioctl..."
    local download_args=""
    if [[ -n "$ISTIO_VERSION" ]]; then
        download_args="ISTIO_VERSION=$ISTIO_VERSION"
    fi

    if ! curl -sL https://istio.io/downloadIstio | sh -s -- ${download_args:+$download_args}; then
        error "Failed to download Istio."
        exit 1
    fi

    local istio_dir
    istio_dir=$(ls -d istio-* 2>/dev/null | sort -V | tail -1)
    if [[ -z "$istio_dir" ]]; then
        error "Istio directory not found after download."
        exit 1
    fi

    export PATH="$PWD/$istio_dir/bin:$PATH"
    log "istioctl installed from $istio_dir."
}

install_istio() {
    log "Installing Istio with profile: $ISTIO_PROFILE"

    if istioctl verify-install &>/dev/null 2>&1; then
        warn "Istio appears to be already installed. Running upgrade check..."
        istioctl verify-install
    fi

    istioctl install --set profile="$ISTIO_PROFILE" -y

    log "Waiting for istiod to be ready..."
    kubectl wait --for=condition=available deployment/istiod \
        -n istio-system --timeout=120s

    log "Istio installed successfully."
}

enable_sidecar_injection() {
    log "Enabling sidecar injection on namespace: $TARGET_NS"

    kubectl create namespace "$TARGET_NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "$TARGET_NS" istio-injection=enabled --overwrite

    log "Sidecar injection enabled for namespace '$TARGET_NS'."
}

deploy_sample_app() {
    log "Deploying Bookinfo sample application..."

    local istio_dir
    istio_dir=$(ls -d istio-* 2>/dev/null | sort -V | tail -1)

    local bookinfo_path=""
    if [[ -n "$istio_dir" && -f "$istio_dir/samples/bookinfo/platform/kube/bookinfo.yaml" ]]; then
        bookinfo_path="$istio_dir/samples/bookinfo/platform/kube/bookinfo.yaml"
    else
        bookinfo_path="https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml"
    fi

    kubectl apply -f "$bookinfo_path" -n "$TARGET_NS"

    log "Waiting for sample app pods..."
    kubectl wait --for=condition=ready pod -l app=productpage \
        -n "$TARGET_NS" --timeout=120s || warn "Timeout waiting for productpage pod."

    log "Sample app deployed."
}

verify_installation() {
    log "Verifying installation..."

    echo ""
    echo "=== Istio System Pods ==="
    kubectl get pods -n istio-system

    echo ""
    echo "=== Istio Version ==="
    istioctl version

    echo ""
    echo "=== Pre-flight Analysis ==="
    istioctl analyze -n "$TARGET_NS" || true

    echo ""
    echo "=== Sidecar Injection Status ==="
    kubectl get namespace "$TARGET_NS" --show-labels | grep -o 'istio-injection=[^ ]*' || true

    echo ""
    echo "=== Application Pods ==="
    kubectl get pods -n "$TARGET_NS"

    echo ""
    log "Installation complete!"
    log "Next steps:"
    log "  - Access Kiali: istioctl dashboard kiali"
    log "  - Check proxy status: istioctl proxy-status"
    log "  - Analyze config: istioctl analyze --all-namespaces"
}

main() {
    echo "============================================"
    echo "  Istio Installation Script"
    echo "  Profile:   $ISTIO_PROFILE"
    echo "  Namespace: $TARGET_NS"
    echo "============================================"
    echo ""

    check_prerequisites
    download_istioctl
    install_istio
    enable_sidecar_injection

    read -rp "Deploy Bookinfo sample app? [y/N]: " deploy_sample
    if [[ "${deploy_sample,,}" == "y" ]]; then
        deploy_sample_app
    fi

    verify_installation
}

main "$@"
