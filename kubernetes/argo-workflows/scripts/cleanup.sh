#!/bin/bash
# Clean up completed/failed workflows

set -e

NAMESPACE="${ARGO_NAMESPACE:-argo}"
ALL_COMPLETED="${1:-false}"

echo "=== Argo Workflow Cleanup ==="

if [[ "$ALL_COMPLETED" == "--all" ]] || [[ "$ALL_COMPLETED" == "all" ]]; then
    echo "Deleting ALL completed workflows..."
    argo delete --all --completed -n "$NAMESPACE"
else
    # List completed workflows
    COMPLETED=$(argo list -n "$NAMESPACE" --completed -o name 2>/dev/null || true)
    
    if [[ -z "$COMPLETED" ]]; then
        echo "No completed workflows found."
    else
        echo "Completed workflows found:"
        echo "$COMPLETED"
        echo ""
        read -p "Delete these workflows? (y/N): " CONFIRM
        if [[ "$CONFIRM" == "y" ]] || [[ "$CONFIRM" == "Y" ]]; then
            echo "$COMPLETED" | xargs -I {} argo delete {} -n "$NAMESPACE"
            echo "Deleted completed workflows."
        else
            echo "Cleanup cancelled."
        fi
    fi
fi

# Show remaining workflows
echo ""
echo "Remaining workflows:"
argo list -n "$NAMESPACE"
