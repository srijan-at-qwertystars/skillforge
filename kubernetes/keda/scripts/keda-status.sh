#!/bin/bash
# keda-status.sh - Check KEDA installation and resource status

set -e

echo "=== KEDA Status Check ==="
echo

# Check if KEDA is installed
echo "1. Checking KEDA namespace..."
kubectl get namespace keda 2>/dev/null || echo "   KEDA namespace not found - KEDA may not be installed"
echo

# Check KEDA pods
echo "2. KEDA pods status..."
kubectl get pods -n keda 2>/dev/null || echo "   No pods found in keda namespace"
echo

# Check KEDA CRDs
echo "3. KEDA Custom Resource Definitions..."
kubectl get crd | grep keda.sh || echo "   No KEDA CRDs found"
echo

# List all ScaledObjects across namespaces
echo "4. ScaledObjects across all namespaces..."
kubectl get scaledobject --all-namespaces 2>/dev/null || echo "   No ScaledObjects found"
echo

# List all ScaledJobs across namespaces
echo "5. ScaledJobs across all namespaces..."
kubectl get scaledjob --all-namespaces 2>/dev/null || echo "   No ScaledJobs found"
echo

# List all TriggerAuthentications
echo "6. TriggerAuthentications..."
kubectl get triggerauthentication --all-namespaces 2>/dev/null || echo "   No TriggerAuthentications found"
echo

# List KEDA-created HPAs
echo "7. KEDA-managed HPAs..."
kubectl get hpa --all-namespaces -l app.kubernetes.io/managed-by=keda-operator 2>/dev/null || echo "   No KEDA-managed HPAs found"
echo

echo "=== Status Check Complete ==="
