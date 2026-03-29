#!/bin/bash
# Apply a policy in Audit mode first, then switch to Enforce

set -e

POLICY_FILE="$1"

if [ -z "$POLICY_FILE" ]; then
  echo "Usage: $0 <policy-file.yaml>"
  exit 1
fi

if [ ! -f "$POLICY_FILE" ]; then
  echo "Error: File not found: $POLICY_FILE"
  exit 1
fi

echo "Applying policy in Audit mode first..."

# Create a temporary file with Audit mode
TMP_FILE=$(mktemp)
sed 's/validationFailureAction: Enforce/validationFailureAction: Audit/g' "$POLICY_FILE" > "$TMP_FILE"

kubectl apply -f "$TMP_FILE"
rm "$TMP_FILE"

echo ""
echo "Policy applied in Audit mode."
echo "Monitor policy reports, then switch to Enforce with:"
echo "  kubectl patch clusterpolicy <policy-name> --type merge -p '{\"spec\":{\"validationFailureAction\":\"Enforce\"}}'"
