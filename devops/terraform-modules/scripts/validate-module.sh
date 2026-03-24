#!/usr/bin/env bash
#
# validate-module.sh — Run a comprehensive validation suite on a Terraform module.
#
# Usage:
#   ./validate-module.sh [module-directory]
#
# Arguments:
#   module-directory  Path to the module directory (default: current directory)
#
# Checks performed:
#   1. terraform fmt -check    — Code formatting
#   2. terraform init          — Provider/module initialization
#   3. terraform validate      — Configuration validity
#   4. tflint                  — Linting rules (if installed)
#   5. tfsec / trivy           — Security scanning (if installed)
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#
# Examples:
#   ./validate-module.sh
#   ./validate-module.sh ./modules/vpc
#   ./validate-module.sh ../terraform-aws-ecs-service
#
set -euo pipefail

MODULE_DIR="${1:-.}"
ERRORS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; ERRORS=$((ERRORS + 1)); }
skip() { echo -e "${YELLOW}⊘ SKIP${NC}: $1 (not installed)"; }

if [[ ! -d "$MODULE_DIR" ]]; then
  echo "Error: Directory '$MODULE_DIR' does not exist."
  exit 1
fi

echo "Validating module: $(cd "$MODULE_DIR" && pwd)"
echo "==========================================="
echo ""

# --- 1. terraform fmt ---
echo "--- Formatting Check ---"
if command -v terraform &>/dev/null; then
  if terraform fmt -check -recursive -diff "$MODULE_DIR" >/dev/null 2>&1; then
    pass "terraform fmt"
  else
    fail "terraform fmt — run 'terraform fmt -recursive $MODULE_DIR' to fix"
    terraform fmt -check -recursive -diff "$MODULE_DIR" 2>&1 || true
  fi
else
  skip "terraform"
  exit 1
fi

# --- 2. terraform init ---
echo ""
echo "--- Initialization ---"
INIT_DIR=$(mktemp -d)
cp -r "$MODULE_DIR"/. "$INIT_DIR/"

if terraform -chdir="$INIT_DIR" init -backend=false -input=false -no-color >/dev/null 2>&1; then
  pass "terraform init"
else
  fail "terraform init"
  terraform -chdir="$INIT_DIR" init -backend=false -input=false -no-color 2>&1 || true
fi

# --- 3. terraform validate ---
echo ""
echo "--- Validation ---"
if terraform -chdir="$INIT_DIR" validate -no-color >/dev/null 2>&1; then
  pass "terraform validate"
else
  fail "terraform validate"
  terraform -chdir="$INIT_DIR" validate -no-color 2>&1 || true
fi

rm -rf "$INIT_DIR"

# --- 4. tflint ---
echo ""
echo "--- Linting ---"
if command -v tflint &>/dev/null; then
  pushd "$MODULE_DIR" >/dev/null
  if tflint --init >/dev/null 2>&1 && tflint --no-color 2>/dev/null; then
    pass "tflint"
  else
    fail "tflint"
    tflint --no-color 2>&1 || true
  fi
  popd >/dev/null
else
  skip "tflint"
fi

# --- 5. Security scanning ---
echo ""
echo "--- Security Scanning ---"
if command -v trivy &>/dev/null; then
  if trivy config --severity HIGH,CRITICAL --exit-code 1 "$MODULE_DIR" >/dev/null 2>&1; then
    pass "trivy (tfsec)"
  else
    fail "trivy (tfsec) — HIGH/CRITICAL issues found"
    trivy config --severity HIGH,CRITICAL "$MODULE_DIR" 2>&1 || true
  fi
elif command -v tfsec &>/dev/null; then
  if tfsec "$MODULE_DIR" --no-color --soft-fail >/dev/null 2>&1; then
    pass "tfsec"
  else
    fail "tfsec — security issues found"
    tfsec "$MODULE_DIR" --no-color 2>&1 || true
  fi
else
  skip "tfsec / trivy"
fi

if command -v checkov &>/dev/null; then
  if checkov -d "$MODULE_DIR" --framework terraform --compact --quiet >/dev/null 2>&1; then
    pass "checkov"
  else
    fail "checkov — policy violations found"
    checkov -d "$MODULE_DIR" --framework terraform --compact 2>&1 || true
  fi
else
  skip "checkov"
fi

# --- Summary ---
echo ""
echo "==========================================="
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GREEN}All checks passed!${NC}"
  exit 0
else
  echo -e "${RED}${ERRORS} check(s) failed.${NC}"
  exit 1
fi
