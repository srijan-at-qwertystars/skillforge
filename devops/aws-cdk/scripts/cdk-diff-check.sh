#!/usr/bin/env bash
#
# cdk-diff-check.sh — CI/CD helper for safe CDK deployments
#
# Runs cdk synth + cdk diff, outputs a summary of changes, and fails if
# destructive changes (resource replacements or deletions) are detected.
#
# Usage:
#   ./cdk-diff-check.sh [STACK_NAME] [OPTIONS]
#
# Options:
#   --stack STACK_NAME     Stack to diff (default: all stacks)
#   --allow-destructive   Don't fail on destructive changes (just warn)
#   --context KEY=VALUE   Pass context values (can repeat)
#   --output FILE         Write diff output to file
#   --strict              Use strict diff mode
#
# Examples:
#   ./cdk-diff-check.sh                           # Diff all stacks
#   ./cdk-diff-check.sh --stack MyStack            # Diff specific stack
#   ./cdk-diff-check.sh --allow-destructive        # Warn but don't fail
#   ./cdk-diff-check.sh --context stage=prod       # With context
#
# Exit codes:
#   0 — No changes or only additions/modifications
#   1 — Destructive changes detected (unless --allow-destructive)
#   2 — Synthesis or diff failed

set -euo pipefail

# --- Configuration ---
STACK_NAME=""
ALLOW_DESTRUCTIVE=false
CONTEXT_ARGS=()
OUTPUT_FILE=""
STRICT_FLAG=""
DIFF_OUTPUT=""
EXIT_CODE=0

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack) STACK_NAME="$2"; shift 2 ;;
    --allow-destructive) ALLOW_DESTRUCTIVE=true; shift ;;
    --context) CONTEXT_ARGS+=("-c" "$2"); shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --strict) STRICT_FLAG="--strict"; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^#//' | sed 's/^ //'
      exit 0
      ;;
    *)
      # Positional arg treated as stack name
      if [[ -z "$STACK_NAME" ]]; then
        STACK_NAME="$1"
      else
        echo "❌ Unknown option: $1"
        exit 2
      fi
      shift
      ;;
  esac
done

# --- Helper functions ---
log_header() {
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  $1"
  echo "═══════════════════════════════════════════════════════════"
}

log_step() {
  echo "▶ $1"
}

# --- Synthesis ---
log_header "CDK Diff Check"
log_step "Running cdk synth..."

SYNTH_CMD="npx cdk synth ${STACK_NAME} ${CONTEXT_ARGS[*]:-} 2>&1"
if ! SYNTH_OUTPUT=$(eval "$SYNTH_CMD"); then
  echo ""
  echo "❌ SYNTHESIS FAILED"
  echo "$SYNTH_OUTPUT"
  exit 2
fi
echo "   ✅ Synthesis successful"

# --- Diff ---
log_step "Running cdk diff..."

DIFF_CMD="npx cdk diff ${STACK_NAME} ${STRICT_FLAG} ${CONTEXT_ARGS[*]:-} 2>&1"
DIFF_OUTPUT=$(eval "$DIFF_CMD") || true

# Save to file if requested
if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$DIFF_OUTPUT" > "$OUTPUT_FILE"
  echo "   📄 Diff output saved to $OUTPUT_FILE"
fi

# --- Analyze diff output ---
log_header "Change Summary"

# Count changes by type
RESOURCES_ADDED=$(echo "$DIFF_OUTPUT" | grep -c '^\[+\]' || true)
RESOURCES_MODIFIED=$(echo "$DIFF_OUTPUT" | grep -c '^\[~\]' || true)
RESOURCES_REMOVED=$(echo "$DIFF_OUTPUT" | grep -c '^\[-\]' || true)

# Detect replacements (resource will be destroyed and recreated)
REPLACEMENTS=$(echo "$DIFF_OUTPUT" | grep -ci 'replace' || true)

# Detect security group changes
SG_CHANGES=$(echo "$DIFF_OUTPUT" | grep -c 'SecurityGroup\|SecurityGroupIngress\|SecurityGroupEgress' || true)

# Detect IAM changes
IAM_CHANGES=$(echo "$DIFF_OUTPUT" | grep -c 'AWS::IAM' || true)

# Check for "no differences" / "no changes"
NO_CHANGES=$(echo "$DIFF_OUTPUT" | grep -ci 'no differences\|no changes\|There were no differences' || true)

echo "  ➕ Resources added:     $RESOURCES_ADDED"
echo "  🔄 Resources modified:  $RESOURCES_MODIFIED"
echo "  ➖ Resources removed:   $RESOURCES_REMOVED"
echo "  ♻️  Replacements:        $REPLACEMENTS"
echo ""

if [[ $SG_CHANGES -gt 0 ]]; then
  echo "  ⚠️  Security group changes detected ($SG_CHANGES)"
fi

if [[ $IAM_CHANGES -gt 0 ]]; then
  echo "  ⚠️  IAM changes detected ($IAM_CHANGES)"
fi

# --- Determine result ---
DESTRUCTIVE_COUNT=$((RESOURCES_REMOVED + REPLACEMENTS))

if [[ $NO_CHANGES -gt 0 && $RESOURCES_ADDED -eq 0 && $RESOURCES_MODIFIED -eq 0 && $RESOURCES_REMOVED -eq 0 ]]; then
  log_header "Result: NO CHANGES"
  echo "  ✅ Stack is up to date. Nothing to deploy."
  EXIT_CODE=0

elif [[ $DESTRUCTIVE_COUNT -gt 0 ]]; then
  log_header "Result: DESTRUCTIVE CHANGES DETECTED"
  echo ""
  echo "  🚨 $RESOURCES_REMOVED resource(s) will be DELETED"
  echo "  🚨 $REPLACEMENTS resource(s) will be REPLACED"
  echo ""

  # Show the destructive changes
  echo "  Destructive changes:"
  echo "$DIFF_OUTPUT" | grep -E '^\[-\]|replace' | head -20 | sed 's/^/    /'
  echo ""

  if [[ "$ALLOW_DESTRUCTIVE" == "true" ]]; then
    echo "  ⚠️  --allow-destructive flag set. Continuing with warning."
    EXIT_CODE=0
  else
    echo "  ❌ Failing build due to destructive changes."
    echo "     Use --allow-destructive to override."
    EXIT_CODE=1
  fi

else
  log_header "Result: SAFE CHANGES"
  echo "  ✅ No destructive changes. Safe to deploy."
  EXIT_CODE=0
fi

# --- Print full diff ---
if [[ $RESOURCES_ADDED -gt 0 || $RESOURCES_MODIFIED -gt 0 || $RESOURCES_REMOVED -gt 0 ]]; then
  echo ""
  echo "─── Full Diff Output ───"
  echo "$DIFF_OUTPUT"
  echo "────────────────────────"
fi

exit $EXIT_CODE
