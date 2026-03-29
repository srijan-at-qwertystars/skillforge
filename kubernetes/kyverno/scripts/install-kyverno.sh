#!/bin/bash
# Install Kyverno via Helm

set -e

NAMESPACE="${1:-kyverno}"
REPLICAS="${2:-3}"

echo "Installing Kyverno in namespace: $NAMESPACE"
echo "Replicas: $REPLICAS"

# Add Helm repo
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

# Install Kyverno
helm install kyverno kyverno/kyverno \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set replicas="$REPLICAS" \
  --set resources.limits.memory=512Mi \
  --set resources.limits.cpu=500m

echo "Kyverno installed successfully!"
echo ""
echo "Check status: kubectl get pods -n $NAMESPACE"
