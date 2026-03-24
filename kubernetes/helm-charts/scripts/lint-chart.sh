#!/usr/bin/env bash
#
# lint-chart.sh — Comprehensive Helm chart linting and validation
#
# Usage:
#   ./lint-chart.sh <chart-path> [values-file...]
#
# Examples:
#   ./lint-chart.sh ./mychart
#   ./lint-chart.sh ./mychart values-prod.yaml values-staging.yaml
#
# Runs the following checks (skips tools not installed):
#   1. helm lint (strict mode)
#   2. helm template (render validation)
#   3. kubeconform (Kubernetes schema validation)
#   4. chart-testing (ct lint) if available
#   5. Custom validation checks (Chart.yaml, values.yaml, templates)
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
#

set -euo pipefail

CHART_PATH="${1:?Usage: $0 <chart-path> [values-file...]}"
shift
VALUES_FILES=("$@")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

pass() { echo -e "${GREEN}✔${NC} $1"; }
fail() { echo -e "${RED}✘${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}⚠${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "${CYAN}ℹ${NC} $1"; }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

if [[ ! -d "${CHART_PATH}" ]]; then
  fail "Chart directory not found: ${CHART_PATH}"
  exit 1
fi

if [[ ! -f "${CHART_PATH}/Chart.yaml" ]]; then
  fail "Not a Helm chart: ${CHART_PATH}/Chart.yaml not found"
  exit 1
fi

CHART_NAME=$(grep '^name:' "${CHART_PATH}/Chart.yaml" | head -1 | awk '{print $2}')
echo -e "${CYAN}Linting chart: ${CHART_NAME} (${CHART_PATH})${NC}"

# ── 1. Helm Lint ────────────────────────────────────────────────────
section "Helm Lint"

if command -v helm &>/dev/null; then
  VALUES_ARGS=""
  for vf in "${VALUES_FILES[@]}"; do
    VALUES_ARGS="${VALUES_ARGS} -f ${vf}"
  done

  if helm lint "${CHART_PATH}" ${VALUES_ARGS} --strict 2>&1; then
    pass "helm lint --strict passed"
  else
    fail "helm lint --strict failed"
  fi
else
  warn "helm not found — skipping helm lint"
fi

# ── 2. Helm Template ───────────────────────────────────────────────
section "Helm Template Rendering"

if command -v helm &>/dev/null; then
  TEMPLATE_OUTPUT=$(mktemp)
  VALUES_ARGS=""
  for vf in "${VALUES_FILES[@]}"; do
    VALUES_ARGS="${VALUES_ARGS} -f ${vf}"
  done

  if helm template lint-test "${CHART_PATH}" ${VALUES_ARGS} > "${TEMPLATE_OUTPUT}" 2>&1; then
    RESOURCE_COUNT=$(grep -c '^kind:' "${TEMPLATE_OUTPUT}" || true)
    pass "helm template rendered ${RESOURCE_COUNT} resources"
  else
    fail "helm template rendering failed:"
    cat "${TEMPLATE_OUTPUT}" >&2
  fi

  # Also render with CI values if available
  if [[ -d "${CHART_PATH}/ci" ]]; then
    for ci_values in "${CHART_PATH}"/ci/*.yaml; do
      if [[ -f "${ci_values}" ]]; then
        if helm template lint-ci "${CHART_PATH}" -f "${ci_values}" > /dev/null 2>&1; then
          pass "Rendered with CI values: $(basename "${ci_values}")"
        else
          fail "Failed rendering with CI values: $(basename "${ci_values}")"
        fi
      fi
    done
  fi
else
  warn "helm not found — skipping template rendering"
fi

# ── 3. Kubeconform / Kubeval ────────────────────────────────────────
section "Schema Validation"

if command -v kubeconform &>/dev/null; then
  if [[ -f "${TEMPLATE_OUTPUT}" && -s "${TEMPLATE_OUTPUT}" ]]; then
    KUBE_RESULT=$(kubeconform -strict -summary -output text "${TEMPLATE_OUTPUT}" 2>&1) && {
      pass "kubeconform validation passed"
    } || {
      fail "kubeconform validation failed:"
      echo "${KUBE_RESULT}" >&2
    }
  fi
elif command -v kubeval &>/dev/null; then
  if [[ -f "${TEMPLATE_OUTPUT}" && -s "${TEMPLATE_OUTPUT}" ]]; then
    if kubeval --strict "${TEMPLATE_OUTPUT}" 2>&1; then
      pass "kubeval validation passed"
    else
      fail "kubeval validation failed"
    fi
  fi
else
  info "kubeconform/kubeval not found — skipping schema validation"
  info "Install: go install github.com/yannh/kubeconform/cmd/kubeconform@latest"
fi

# ── 4. Chart Testing (ct) ──────────────────────────────────────────
section "Chart Testing"

if command -v ct &>/dev/null; then
  if ct lint --charts "${CHART_PATH}" --validate-maintainers=false 2>&1; then
    pass "ct lint passed"
  else
    fail "ct lint failed"
  fi
else
  info "ct (chart-testing) not found — skipping"
  info "Install: https://github.com/helm/chart-testing"
fi

# ── 5. Custom Validation ───────────────────────────────────────────
section "Custom Validation Checks"

# Check Chart.yaml required fields
CHART_YAML="${CHART_PATH}/Chart.yaml"

if grep -q '^apiVersion: v2' "${CHART_YAML}"; then
  pass "Chart.yaml uses apiVersion v2"
else
  fail "Chart.yaml should use apiVersion v2"
fi

if grep -q '^version:' "${CHART_YAML}"; then
  VERSION=$(grep '^version:' "${CHART_YAML}" | head -1 | awk '{print $2}' | tr -d '"')
  if [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "Chart version is valid semver: ${VERSION}"
  else
    fail "Chart version is not valid semver: ${VERSION}"
  fi
else
  fail "Chart.yaml missing version field"
fi

if grep -q '^appVersion:' "${CHART_YAML}"; then
  pass "Chart.yaml has appVersion"
else
  warn "Chart.yaml missing appVersion"
fi

if grep -q '^description:' "${CHART_YAML}"; then
  pass "Chart.yaml has description"
else
  warn "Chart.yaml missing description"
fi

# Check for _helpers.tpl
if [[ -f "${CHART_PATH}/templates/_helpers.tpl" ]]; then
  pass "_helpers.tpl exists"
else
  warn "_helpers.tpl not found — consider adding named templates"
fi

# Check for NOTES.txt
if [[ -f "${CHART_PATH}/templates/NOTES.txt" ]]; then
  pass "NOTES.txt exists"
else
  warn "NOTES.txt not found — consider adding post-install notes"
fi

# Check for tests
if ls "${CHART_PATH}"/templates/tests/*.yaml &>/dev/null 2>&1; then
  pass "Chart has test templates"
else
  warn "No test templates found in templates/tests/"
fi

# Check for values.schema.json
if [[ -f "${CHART_PATH}/values.schema.json" ]]; then
  pass "values.schema.json exists"
else
  warn "values.schema.json not found — consider adding for values validation"
fi

# Check for .helmignore
if [[ -f "${CHART_PATH}/.helmignore" ]]; then
  pass ".helmignore exists"
else
  warn ".helmignore not found"
fi

# Security: check for hardcoded secrets
section "Security Checks"

TEMPLATE_DIR="${CHART_PATH}/templates"
if [[ -d "${TEMPLATE_DIR}" ]]; then
  # Check for hardcoded passwords/secrets in templates
  if grep -rn 'password:\s*["\x27][^{]' "${TEMPLATE_DIR}" 2>/dev/null | grep -v '_test\.' | grep -v '#'; then
    fail "Possible hardcoded password found in templates"
  else
    pass "No hardcoded passwords in templates"
  fi

  # Check for latest tag
  if grep -rn 'tag:\s*["'"'"']latest["'"'"']' "${CHART_PATH}/values.yaml" 2>/dev/null; then
    warn "image tag set to 'latest' in values.yaml — use specific versions in production"
  else
    pass "No 'latest' image tag in default values"
  fi
fi

# ── Cleanup ─────────────────────────────────────────────────────────
[[ -f "${TEMPLATE_OUTPUT:-}" ]] && rm -f "${TEMPLATE_OUTPUT}"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ ${ERRORS} -eq 0 ]]; then
  echo -e "${GREEN}All checks passed!${NC} (${WARNINGS} warnings)"
  exit 0
else
  echo -e "${RED}${ERRORS} error(s)${NC}, ${WARNINGS} warning(s)"
  exit 1
fi
