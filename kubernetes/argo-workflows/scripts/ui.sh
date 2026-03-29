#!/bin/bash
# Port-forward Argo UI and open browser

set -e

NAMESPACE="${ARGO_NAMESPACE:-argo}"
PORT="${ARGO_PORT:-2746}"

echo "Starting port-forward to Argo UI on port $PORT..."
echo "Press Ctrl+C to stop"
echo ""

# Check if server is running
if ! kubectl get deployment argo-server -n "$NAMESPACE" &> /dev/null; then
    echo "Error: Argo server not found in namespace $NAMESPACE"
    echo "Is Argo Workflows installed?"
    exit 1
fi

# Start port-forward
kubectl -n "$NAMESPACE" port-forward deployment/argo-server "${PORT}:2746" &
PID=$!

sleep 2

echo "Argo UI available at: https://localhost:$PORT"
echo ""

# Try to open browser (optional)
if command -v xdg-open &> /dev/null; then
    xdg-open "https://localhost:$PORT" 2>/dev/null || true
elif command -v open &> /dev/null; then
    open "https://localhost:$PORT" 2>/dev/null || true
fi

# Wait for port-forward
wait $PID
