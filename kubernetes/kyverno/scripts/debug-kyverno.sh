#!/bin/bash
# Debug Kyverno webhook and policy issues

set -e

echo "=== Kyverno Pods Status ==="
kubectl get pods -n kyverno -o wide

echo ""
echo "=== Kyverno Validating Webhooks ==="
kubectl get validatingwebhookconfiguration | grep kyverno

echo ""
echo "=== Kyverno Mutating Webhooks ==="
kubectl get mutatingwebhookconfiguration | grep kyverno

echo ""
echo "=== Recent Kyverno Logs (last 50 lines) ==="
kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=50 --prefix 2>/dev/null || \
  kubectl logs -n kyverno -l app=kyverno --tail=50 --prefix 2>/dev/null || \
  echo "Could not retrieve logs"

echo ""
echo "=== Cluster Policies ==="
kubectl get clusterpolicy

echo ""
echo "=== Policies (all namespaces) ==="
kubectl get policy --all-namespaces
