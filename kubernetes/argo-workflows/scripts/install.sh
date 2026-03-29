#!/bin/bash
# Install Argo Workflows CLI and server components

set -e

ARGO_VERSION="${ARGO_VERSION:-latest}"
NAMESPACE="${ARGO_NAMESPACE:-argo}"

echo "=== Installing Argo Workflows ==="

# Install Argo CLI
if ! command -v argo &> /dev/null; then
    echo "Installing Argo CLI..."
    if [[ "$ARGO_VERSION" == "latest" ]]; then
        curl -sLO https://github.com/argoproj/argo-workflows/releases/latest/download/argo-linux-amd64.gz
    else
        curl -sLO "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/argo-linux-amd64.gz"
    fi
    gunzip argo-linux-amd64.gz
    chmod +x argo-linux-amd64
    sudo mv argo-linux-amd64 /usr/local/bin/argo
    rm -f argo-linux-amd64.gz
    echo "Argo CLI installed: $(argo version --short)"
else
    echo "Argo CLI already installed: $(argo version --short)"
fi

# Install Argo Workflows server on Kubernetes
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
fi

if [[ "$ARGO_VERSION" == "latest" ]]; then
    kubectl apply -n "$NAMESPACE" -f https://github.com/argoproj/argo-workflows/releases/latest/download/install.yaml
else
    kubectl apply -n "$NAMESPACE" -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/install.yaml"
fi

# Patch for quick start (server auth mode)
kubectl patch deployment argo-server -n "$NAMESPACE" --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": ["server", "--auth-mode=server"]}]'

echo ""
echo "=== Installation Complete ==="
echo "Port-forward UI: kubectl -n $NAMESPACE port-forward deployment/argo-server 2746:2746"
echo "Access UI: https://localhost:2746"
