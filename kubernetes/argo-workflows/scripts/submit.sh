#!/bin/bash
# Quick workflow submission and monitoring

set -e

WORKFLOW_FILE="${1:-workflow.yaml}"
WATCH="${2:-false}"
NAMESPACE="${ARGO_NAMESPACE:-argo}"

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    echo "Error: Workflow file not found: $WORKFLOW_FILE"
    echo "Usage: $0 <workflow-file.yaml> [watch]"
    exit 1
fi

echo "Submitting workflow: $WORKFLOW_FILE"

if [[ "$WATCH" == "watch" ]] || [[ "$WATCH" == "true" ]] || [[ "$WATCH" == "-w" ]]; then
    argo submit "$WORKFLOW_FILE" -n "$NAMESPACE" --watch
else
    WORKFLOW_NAME=$(argo submit "$WORKFLOW_FILE" -n "$NAMESPACE" -o name)
    echo "Workflow submitted: $WORKFLOW_NAME"
    echo ""
    echo "Commands to monitor:"
    echo "  argo list -n $NAMESPACE"
    echo "  argo get $WORKFLOW_NAME -n $NAMESPACE"
    echo "  argo logs $WORKFLOW_NAME -n $NAMESPACE"
    echo "  argo watch $WORKFLOW_NAME -n $NAMESPACE"
fi
