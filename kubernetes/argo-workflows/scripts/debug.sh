#!/bin/bash
# Debug a failed workflow

set -e

WORKFLOW_NAME="${1:-}"
NAMESPACE="${ARGO_NAMESPACE:-argo}"

if [[ -z "$WORKFLOW_NAME" ]]; then
    echo "Error: Workflow name required"
    echo "Usage: $0 <workflow-name>"
    echo ""
    echo "Recent workflows:"
    argo list -n "$NAMESPACE" --limit 10
    exit 1
fi

echo "=== Debugging Workflow: $WORKFLOW_NAME ==="
echo ""

# Get workflow details
echo "--- Workflow Status ---"
argo get "$WORKFLOW_NAME" -n "$NAMESPACE"

echo ""
echo "--- Workflow Events ---"
kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=$WORKFLOW_NAME" 2>/dev/null || echo "No events found"

echo ""
echo "--- Pod Status ---"
PODS=$(kubectl get pods -n "$NAMESPACE" -l "workflows.argoproj.io/workflow=$WORKFLOW_NAME" -o name 2>/dev/null || true)

if [[ -n "$PODS" ]]; then
    for POD in $PODS; do
        echo "Pod: $POD"
        kubectl describe "$POD" -n "$NAMESPACE" 2>/dev/null | head -30
        echo ""
    done
else
    echo "No pods found for this workflow."
fi

echo ""
echo "--- Logs (last 50 lines) ---"
argo logs "$WORKFLOW_NAME" -n "$NAMESPACE" --tail 50 2>/dev/null || echo "No logs available"

echo ""
echo "=== Debug Commands ==="
echo "Full workflow YAML: argo get $WORKFLOW_NAME -n $NAMESPACE -o yaml"
echo "All logs: argo logs $WORKFLOW_NAME -n $NAMESPACE"
echo "Follow logs: argo logs $WORKFLOW_NAME -n $NAMESPACE -f"
echo "Exec into pod: kubectl exec -it <pod-name> -n $NAMESPACE -c main -- sh"
