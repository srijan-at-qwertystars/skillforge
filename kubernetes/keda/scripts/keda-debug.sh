#!/bin/bash
# keda-debug.sh - Debug a specific ScaledObject

set -e

NAMESPACE=${1:-default}
SCALED_OBJECT=${2:-}

if [ -z "$SCALED_OBJECT" ]; then
    echo "Usage: $0 <namespace> <scaledobject-name>"
    echo
    echo "Available ScaledObjects in namespace '$NAMESPACE':"
    kubectl get scaledobject -n "$NAMESPACE" 2>/dev/null || echo "  None found"
    exit 1
fi

echo "=== Debugging ScaledObject: $SCALED_OBJECT (namespace: $NAMESPACE) ==="
echo

# Get ScaledObject details
echo "1. ScaledObject YAML..."
kubectl get scaledobject "$SCALED_OBJECT" -n "$NAMESPACE" -o yaml
echo

# Get ScaledObject status conditions
echo "2. Status Conditions..."
kubectl get scaledobject "$SCALED_OBJECT" -n "$NAMESPACE" -o jsonpath='{.status.conditions}' | jq . 2>/dev/null || kubectl get scaledobject "$SCALED_OBJECT" -n "$NAMESPACE" -o jsonpath='{.status.conditions}'
echo

# Get associated HPA
echo "3. Associated HPA..."
HPA_NAME=$(kubectl get hpa -n "$NAMESPACE" -l app.kubernetes.io/managed-by=keda-operator -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i "$SCALED_OBJECT" || true)
if [ -n "$HPA_NAME" ]; then
    kubectl describe hpa "$HPA_NAME" -n "$NAMESPACE"
else
    echo "   No HPA found for this ScaledObject"
fi
echo

# Get scale target
echo "4. Scale Target..."
TARGET_KIND=$(kubectl get scaledobject "$SCALED_OBJECT" -n "$NAMESPACE" -o jsonpath='{.spec.scaleTargetRef.kind}')
TARGET_NAME=$(kubectl get scaledobject "$SCALED_OBJECT" -n "$NAMESPACE" -o jsonpath='{.spec.scaleTargetRef.name}')
echo "   Target: $TARGET_KIND/$TARGET_NAME"
kubectl get "$TARGET_KIND" "$TARGET_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   Target not found"
echo

# Get events
echo "5. Recent Events..."
kubectl get events -n "$NAMESPACE" --field-selector reason=KEDAScaleTarget --sort-by='.lastTimestamp' | tail -10
echo

# Check TriggerAuthentication
echo "6. TriggerAuthentications in namespace..."
kubectl get triggerauthentication -n "$NAMESPACE" 2>/dev/null || echo "   None found"
echo

echo "=== Debug Complete ==="
