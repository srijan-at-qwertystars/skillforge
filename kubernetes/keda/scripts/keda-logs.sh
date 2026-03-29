#!/bin/bash
# keda-logs.sh - Stream KEDA operator logs

NAMESPACE=${1:-keda}
COMPONENT=${2:-operator}  # operator or metrics-server

if [ "$COMPONENT" != "operator" ] && [ "$COMPONENT" != "metrics-server" ]; then
    echo "Usage: $0 [namespace] [operator|metrics-server]"
    exit 1
fi

echo "Streaming KEDA $COMPONENT logs (namespace: $NAMESPACE)..."
echo "Press Ctrl+C to stop"
echo

kubectl logs -n "$NAMESPACE" -l app=keda-$COMPONENT --tail=100 -f 2>/dev/null || \
kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=keda-$COMPONENT --tail=100 -f 2>/dev/null || \
kubectl logs -n "$NAMESPACE" deployment/keda-$COMPONENT --tail=100 -f 2>/dev/null || \
echo "Could not find KEDA $COMPONENT deployment"
