#!/bin/bash
# keda-install.sh - Install or upgrade KEDA via Helm

set -e

NAMESPACE=${1:-keda}
VERSION=${2:-}  # Optional specific version

echo "=== Installing/Upgrading KEDA ==="
echo "Namespace: $NAMESPACE"
[ -n "$VERSION" ] && echo "Version: $VERSION"
echo

# Add Helm repo
echo "1. Adding KEDA Helm repository..."
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
echo

# Install or upgrade
echo "2. Installing KEDA..."
if [ -n "$VERSION" ]; then
    helm upgrade --install keda kedacore/keda \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --version "$VERSION"
else
    helm upgrade --install keda kedacore/keda \
        --namespace "$NAMESPACE" \
        --create-namespace
fi
echo

# Wait for rollout
echo "3. Waiting for KEDA pods to be ready..."
kubectl wait --for=condition=ready pod -l app=keda-operator -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keda-operator -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
echo "   (timeout waiting for pods, check status manually)"
echo

# Verify
echo "4. Verifying installation..."
kubectl get pods -n "$NAMESPACE"
echo

# Show CRDs
echo "5. Installed CRDs..."
kubectl get crd | grep keda.sh | awk '{print "   " $1}'
echo

echo "=== KEDA Installation Complete ==="
echo
echo "Quick test:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get scaledobject --all-namespaces"
