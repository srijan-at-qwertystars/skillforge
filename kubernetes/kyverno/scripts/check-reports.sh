#!/bin/bash
# Check Kyverno policy reports across all namespaces

set -e

echo "=== Cluster Policy Reports ==="
kubectl get clusterpolicyreport -o wide 2>/dev/null || echo "No cluster policy reports found"

echo ""
echo "=== Namespace Policy Reports ==="
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  reports=$(kubectl get policyreport -n "$ns" -o name 2>/dev/null)
  if [ -n "$reports" ]; then
    echo ""
    echo "Namespace: $ns"
    kubectl get policyreport -n "$ns" -o wide
  fi
done

echo ""
echo "=== Summary of Failures ==="
kubectl get clusterpolicyreport -o json 2>/dev/null | jq -r '
  .items[] | 
  select(.results != null) |
  .results[] | 
  select(.result == "fail") |
  "\(.policy)/\(.rule): \(.message)"
' 2>/dev/null || echo "No failures in cluster reports"
