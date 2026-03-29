#!/bin/bash
# Validate all Kyverno policies in a directory

set -e

POLICY_DIR="${1:-.}"

echo "Validating Kyverno policies in: $POLICY_DIR"
echo ""

for policy in "$POLICY_DIR"/*.yaml; do
  if [ -f "$policy" ]; then
    echo "Validating: $(basename "$policy")"
    kyverno validate "$policy" || echo "FAILED: $policy"
  fi
done

echo ""
echo "Validation complete!"
