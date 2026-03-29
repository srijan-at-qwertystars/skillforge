#!/bin/bash
# keda-uninstall.sh - Uninstall KEDA

set -e

NAMESPACE=${1:-keda}

echo "=== Uninstalling KEDA ==="
echo "Namespace: $NAMESPACE"
echo

read -p "Are you sure? This will remove all KEDA resources. [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Delete all ScaledObjects and ScaledJobs first (to clean up HPAs)
echo "1. Removing ScaledObjects and ScaledJobs..."
kubectl delete scaledobject --all --all-namespaces 2>/dev/null || true
kubectl delete scaledjob --all --all-namespaces 2>/dev/null || true
echo

# Uninstall Helm release
echo "2. Uninstalling Helm release..."
helm uninstall keda -n "$NAMESPACE" 2>/dev/null || echo "   Helm release not found"
echo

# Delete namespace
echo "3. Deleting namespace..."
kubectl delete namespace "$NAMESPACE" --wait=false 2>/dev/null || echo "   Namespace not found"
echo

# Note about CRDs
echo "4. CRD cleanup note..."
echo "   CRDs are preserved by default. To remove them:"
echo "   kubectl delete crd scaledobjects.keda.sh scaledjobs.keda.sh triggerauthentications.keda.sh clustertriggerauthentications.keda.sh"
echo

echo "=== KEDA Uninstallation Complete ==="
