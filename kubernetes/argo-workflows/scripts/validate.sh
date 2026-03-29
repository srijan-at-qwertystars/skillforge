#!/bin/bash
# Validate workflow YAML syntax and structure

set -e

WORKFLOW_FILE="${1:-}"

if [[ -z "$WORKFLOW_FILE" ]]; then
    echo "Error: Workflow file required"
    echo "Usage: $0 <workflow-file.yaml>"
    exit 1
fi

if [[ ! -f "$WORKFLOW_FILE" ]]; then
    echo "Error: File not found: $WORKFLOW_FILE"
    exit 1
fi

echo "=== Validating Workflow: $WORKFLOW_FILE ==="
echo ""

# Check YAML syntax
echo "--- YAML Syntax Check ---"
if command -v yq &> /dev/null; then
    yq eval '.' "$WORKFLOW_FILE" > /dev/null && echo "✓ YAML syntax valid"
else
    echo "⚠ yq not installed, skipping YAML validation"
fi

# Check required fields
echo ""
echo "--- Required Fields Check ---"

if grep -q "apiVersion: argoproj.io/v1alpha1" "$WORKFLOW_FILE"; then
    echo "✓ apiVersion: argoproj.io/v1alpha1"
else
    echo "✗ Missing or incorrect apiVersion"
fi

if grep -q "kind: Workflow" "$WORKFLOW_FILE" || grep -q "kind: CronWorkflow" "$WORKFLOW_FILE"; then
    echo "✓ kind: Workflow or CronWorkflow"
else
    echo "✗ Missing kind field"
fi

if grep -q "entrypoint:" "$WORKFLOW_FILE"; then
    echo "✓ entrypoint defined"
else
    echo "✗ Missing entrypoint"
fi

if grep -q "templates:" "$WORKFLOW_FILE"; then
    echo "✓ templates section found"
else
    echo "✗ Missing templates section"
fi

# Check for common issues
echo ""
echo "--- Common Issues Check ---"

if grep -q "{{workflow.parameters" "$WORKFLOW_FILE"; then
    if ! grep -q "arguments:" "$WORKFLOW_FILE"; then
        echo "⚠ Uses workflow.parameters but no arguments section found"
    fi
fi

if grep -q "{{inputs.parameters" "$WORKFLOW_FILE"; then
    if ! grep -q "inputs:" "$WORKFLOW_FILE"; then
        echo "⚠ Uses inputs.parameters but no inputs section found"
    fi
fi

if grep -q "{{inputs.artifacts" "$WORKFLOW_FILE"; then
    if ! grep -q "artifacts:" "$WORKFLOW_FILE"; then
        echo "⚠ Uses inputs.artifacts but no artifacts section found"
    fi
fi

echo ""
echo "=== Validation Complete ==="
echo "To test: argo lint $WORKFLOW_FILE"
