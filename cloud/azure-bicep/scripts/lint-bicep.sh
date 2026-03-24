#!/usr/bin/env bash
# lint-bicep.sh — Run Bicep linter, check best practices, validate against Azure
#
# Usage:
#   ./lint-bicep.sh                           # Lint all .bicep files in current dir
#   ./lint-bicep.sh -f main.bicep             # Lint a specific file
#   ./lint-bicep.sh -d ./modules              # Lint all files in a directory
#   ./lint-bicep.sh --validate -g myRg        # Lint + validate against Azure
#   ./lint-bicep.sh --strict                  # Treat warnings as errors
#   ./lint-bicep.sh --fix                     # Auto-format files
#   ./lint-bicep.sh --ci                      # CI mode: non-interactive, exit code on failure
#
# Prerequisites: Azure CLI with Bicep extension

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

# Defaults
TARGET_FILE=""
TARGET_DIR="."
VALIDATE=false
RESOURCE_GROUP=""
STRICT=false
FIX=false
CI_MODE=false

TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)      TARGET_FILE="$2"; shift 2 ;;
    -d|--dir)       TARGET_DIR="$2"; shift 2 ;;
    -g|--group)     RESOURCE_GROUP="$2"; shift 2 ;;
    --validate)     VALIDATE=true; shift ;;
    --strict)       STRICT=true; shift ;;
    --fix)          FIX=true; shift ;;
    --ci)           CI_MODE=true; STRICT=true; shift ;;
    -h|--help)      sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Collect files ──────────────────────────────────────────────────────────────
collect_files() {
  if [[ -n "$TARGET_FILE" ]]; then
    if [[ -f "$TARGET_FILE" ]]; then
      echo "$TARGET_FILE"
    else
      error "File not found: $TARGET_FILE"
      exit 1
    fi
  else
    find "$TARGET_DIR" -name '*.bicep' -not -name '*.test.bicep' -not -path '*/.git/*' | sort
  fi
}

# ── Lint single file ──────────────────────────────────────────────────────────
lint_file() {
  local file="$1"
  TOTAL=$((TOTAL + 1))
  local output
  local exit_code=0

  output=$(az bicep lint --file "$file" 2>&1) || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    error "FAIL: $file"
    echo "$output" | sed 's/^/  /'
    FAILED=$((FAILED + 1))
    return 1
  fi

  # Check for warnings in output
  if echo "$output" | grep -qi "warning"; then
    if [[ "$STRICT" == true ]]; then
      error "FAIL (warnings as errors): $file"
      echo "$output" | sed 's/^/  /'
      FAILED=$((FAILED + 1))
      return 1
    else
      warn "WARN: $file"
      echo "$output" | grep -i "warning" | sed 's/^/  /'
      WARNINGS=$((WARNINGS + 1))
      PASSED=$((PASSED + 1))
    fi
  else
    info "PASS: $file"
    PASSED=$((PASSED + 1))
  fi
  return 0
}

# ── Build check (compile to ARM) ──────────────────────────────────────────────
build_check() {
  local file="$1"
  local output
  local exit_code=0

  output=$(az bicep build --file "$file" --stdout 2>&1 >/dev/null) || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    error "BUILD FAIL: $file"
    echo "$output" | sed 's/^/  /'
    return 1
  fi
  return 0
}

# ── Format file ────────────────────────────────────────────────────────────────
format_file() {
  local file="$1"
  if az bicep format --file "$file" 2>/dev/null; then
    info "Formatted: $file"
  else
    # Fallback to standalone bicep
    if command -v bicep &>/dev/null; then
      bicep format "$file" 2>/dev/null && info "Formatted: $file"
    else
      warn "Cannot format: $file (format command not available)"
    fi
  fi
}

# ── Validate against Azure ────────────────────────────────────────────────────
validate_against_azure() {
  local file="$1"
  if [[ -z "$RESOURCE_GROUP" ]]; then
    warn "Skipping Azure validation (no resource group specified with -g)"
    return 0
  fi

  step "Validating $file against Azure..."
  local output
  local exit_code=0

  output=$(az deployment group validate \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$file" \
    2>&1) || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    error "VALIDATION FAIL: $file"
    echo "$output" | sed 's/^/  /'
    return 1
  fi
  info "Azure validation passed: $file"
  return 0
}

# ── Best practices check ──────────────────────────────────────────────────────
check_best_practices() {
  local file="$1"
  local issues=0

  # Check for hardcoded locations
  if grep -Pn "location:\s*'[a-z]+'" "$file" 2>/dev/null | grep -v "//.*disable-next-line" | grep -v "param location" > /dev/null 2>&1; then
    warn "  Hardcoded location found in $file — use param location"
    issues=$((issues + 1))
  fi

  # Check for missing @description on params
  local params_without_desc
  params_without_desc=$(awk '
    /^@description/ { has_desc=1; next }
    /^param / { if (!has_desc) print NR": "$0; has_desc=0; next }
    { has_desc=0 }
  ' "$file" 2>/dev/null || true)
  if [[ -n "$params_without_desc" ]]; then
    warn "  Parameters without @description in $file:"
    echo "$params_without_desc" | sed 's/^/    /'
    issues=$((issues + 1))
  fi

  # Check for concat() usage
  if grep -Pn "concat\(" "$file" 2>/dev/null | head -3 > /dev/null 2>&1; then
    warn "  concat() found in $file — prefer string interpolation '\${x}-\${y}'"
    issues=$((issues + 1))
  fi

  # Check for missing targetScope in non-RG deployments
  if grep -q "Microsoft.Resources/resourceGroups" "$file" 2>/dev/null; then
    if ! grep -q "targetScope" "$file" 2>/dev/null; then
      warn "  $file creates resource groups but lacks targetScope declaration"
      issues=$((issues + 1))
    fi
  fi

  return $issues
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  info "=== Bicep Lint & Validation ==="
  [[ "$STRICT" == true ]] && info "Strict mode: warnings treated as errors"
  [[ "$CI_MODE" == true ]] && info "CI mode: non-interactive"
  echo ""

  local files
  files=$(collect_files)

  if [[ -z "$files" ]]; then
    warn "No .bicep files found"
    exit 0
  fi

  local overall_exit=0

  # Format pass (if requested)
  if [[ "$FIX" == true ]]; then
    step "Formatting files..."
    while IFS= read -r file; do
      format_file "$file"
    done <<< "$files"
    echo ""
  fi

  # Lint pass
  step "Linting..."
  while IFS= read -r file; do
    lint_file "$file" || overall_exit=1
  done <<< "$files"
  echo ""

  # Build check
  step "Build check (compile to ARM)..."
  while IFS= read -r file; do
    build_check "$file" || overall_exit=1
  done <<< "$files"
  echo ""

  # Best practices
  step "Best practices check..."
  while IFS= read -r file; do
    check_best_practices "$file" || true
  done <<< "$files"
  echo ""

  # Azure validation
  if [[ "$VALIDATE" == true ]]; then
    step "Azure validation..."
    # Only validate main template files (not modules)
    while IFS= read -r file; do
      if [[ "$(basename "$file")" == "main.bicep" ]] || [[ ! "$file" =~ modules/ ]]; then
        validate_against_azure "$file" || overall_exit=1
      fi
    done <<< "$files"
    echo ""
  fi

  # Summary
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Results: $PASSED passed, $FAILED failed, $WARNINGS warnings (of $TOTAL files)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ $FAILED -gt 0 ]]; then
    error "Lint check failed"
    exit 1
  fi

  if [[ "$STRICT" == true && $WARNINGS -gt 0 ]]; then
    error "Strict mode: $WARNINGS warnings treated as errors"
    exit 1
  fi

  info "All checks passed ✓"
  exit $overall_exit
}

main
