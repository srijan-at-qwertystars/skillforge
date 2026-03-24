#!/usr/bin/env bash
#
# publish-chart.sh — Package and publish a Helm chart
#
# Usage:
#   ./publish-chart.sh <chart-path> <registry-url> [--type oci|chartmuseum]
#
# Examples:
#   # OCI registry (default)
#   ./publish-chart.sh ./mychart oci://ghcr.io/myorg/charts
#   ./publish-chart.sh ./mychart oci://123456.dkr.ecr.us-east-1.amazonaws.com/charts
#
#   # ChartMuseum
#   ./publish-chart.sh ./mychart https://charts.example.com --type chartmuseum
#
# Prerequisites:
#   - helm v3.8+ (for OCI support)
#   - Authenticated to registry (helm registry login / docker login)
#   - For ChartMuseum: curl, helm-push plugin or direct API
#
# Environment variables:
#   HELM_REGISTRY_USER     — Registry username (optional, for auto-login)
#   HELM_REGISTRY_PASSWORD — Registry password (optional, for auto-login)
#   CHART_VERSION_OVERRIDE — Override chart version (optional)
#   DRY_RUN                — Set to "true" to skip actual push
#

set -euo pipefail

CHART_PATH="${1:?Usage: $0 <chart-path> <registry-url> [--type oci|chartmuseum]}"
REGISTRY_URL="${2:?Usage: $0 <chart-path> <registry-url> [--type oci|chartmuseum]}"
PUBLISH_TYPE="oci"

# Parse optional flags
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      PUBLISH_TYPE="${2:?--type requires a value (oci or chartmuseum)}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}→${NC} $1"; }
pass() { echo -e "${GREEN}✔${NC} $1"; }
fail() { echo -e "${RED}✘${NC} $1"; exit 1; }

# ── Validate ────────────────────────────────────────────────────────
if [[ ! -f "${CHART_PATH}/Chart.yaml" ]]; then
  fail "Not a Helm chart: ${CHART_PATH}/Chart.yaml not found"
fi

if ! command -v helm &>/dev/null; then
  fail "helm is not installed"
fi

CHART_NAME=$(grep '^name:' "${CHART_PATH}/Chart.yaml" | head -1 | awk '{print $2}')
CHART_VERSION=$(grep '^version:' "${CHART_PATH}/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '"')

if [[ -n "${CHART_VERSION_OVERRIDE:-}" ]]; then
  info "Overriding chart version: ${CHART_VERSION} → ${CHART_VERSION_OVERRIDE}"
  sed -i "s/^version:.*/version: ${CHART_VERSION_OVERRIDE}/" "${CHART_PATH}/Chart.yaml"
  CHART_VERSION="${CHART_VERSION_OVERRIDE}"
fi

info "Chart: ${CHART_NAME} v${CHART_VERSION}"
info "Registry: ${REGISTRY_URL}"
info "Type: ${PUBLISH_TYPE}"

# ── Lint before publish ─────────────────────────────────────────────
info "Linting chart..."
if ! helm lint "${CHART_PATH}" --strict; then
  fail "Chart lint failed — fix errors before publishing"
fi
pass "Lint passed"

# ── Update dependencies ────────────────────────────────────────────
if [[ -f "${CHART_PATH}/Chart.lock" ]] || grep -q '^dependencies:' "${CHART_PATH}/Chart.yaml" 2>/dev/null; then
  info "Building dependencies..."
  helm dependency build "${CHART_PATH}"
  pass "Dependencies built"
fi

# ── Package ─────────────────────────────────────────────────────────
info "Packaging chart..."
PACKAGE_DIR=$(mktemp -d)
PACKAGE_OUTPUT=$(helm package "${CHART_PATH}" -d "${PACKAGE_DIR}" 2>&1)
PACKAGE_FILE=$(echo "${PACKAGE_OUTPUT}" | grep -oP '(?<=to: ).*\.tgz' || find "${PACKAGE_DIR}" -name "*.tgz" | head -1)

if [[ ! -f "${PACKAGE_FILE}" ]]; then
  fail "Packaging failed: ${PACKAGE_OUTPUT}"
fi
pass "Packaged: $(basename "${PACKAGE_FILE}")"

# ── Auto-login if credentials provided ──────────────────────────────
if [[ -n "${HELM_REGISTRY_USER:-}" && -n "${HELM_REGISTRY_PASSWORD:-}" ]]; then
  REGISTRY_HOST=$(echo "${REGISTRY_URL}" | sed 's|oci://||' | sed 's|https\?://||' | cut -d'/' -f1)
  info "Logging in to ${REGISTRY_HOST}..."
  echo "${HELM_REGISTRY_PASSWORD}" | helm registry login "${REGISTRY_HOST}" \
    --username "${HELM_REGISTRY_USER}" --password-stdin
  pass "Authenticated"
fi

# ── Publish ─────────────────────────────────────────────────────────
if [[ "${DRY_RUN:-}" == "true" ]]; then
  info "DRY RUN — would publish ${PACKAGE_FILE} to ${REGISTRY_URL}"
  pass "Dry run complete"
  rm -rf "${PACKAGE_DIR}"
  exit 0
fi

case "${PUBLISH_TYPE}" in
  oci)
    info "Pushing to OCI registry..."
    if helm push "${PACKAGE_FILE}" "${REGISTRY_URL}" 2>&1; then
      pass "Published ${CHART_NAME}:${CHART_VERSION} to ${REGISTRY_URL}"
    else
      fail "Failed to push to OCI registry"
    fi
    ;;

  chartmuseum)
    info "Pushing to ChartMuseum..."

    # Try helm-push plugin first
    if helm plugin list 2>/dev/null | grep -q 'cm-push\|push'; then
      if helm cm-push "${PACKAGE_FILE}" "${REGISTRY_URL}" 2>&1; then
        pass "Published via helm-push plugin"
      else
        fail "helm cm-push failed"
      fi
    elif command -v curl &>/dev/null; then
      # Fallback to curl API
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --data-binary "@${PACKAGE_FILE}" \
        "${REGISTRY_URL}/api/charts")
      if [[ "${HTTP_CODE}" == "201" ]]; then
        pass "Published via ChartMuseum API (HTTP ${HTTP_CODE})"
      else
        fail "ChartMuseum API returned HTTP ${HTTP_CODE}"
      fi
    else
      fail "Neither helm-push plugin nor curl available for ChartMuseum"
    fi
    ;;

  *)
    fail "Unknown publish type: ${PUBLISH_TYPE}. Use 'oci' or 'chartmuseum'."
    ;;
esac

# ── Verify ──────────────────────────────────────────────────────────
if [[ "${PUBLISH_TYPE}" == "oci" ]]; then
  info "Verifying published chart..."
  if helm show chart "${REGISTRY_URL}/${CHART_NAME}" --version "${CHART_VERSION}" > /dev/null 2>&1; then
    pass "Verification successful — chart is available"
  else
    info "Verification skipped — chart may take a moment to be available"
  fi
fi

# ── Cleanup ─────────────────────────────────────────────────────────
rm -rf "${PACKAGE_DIR}"

echo ""
echo -e "${GREEN}✅ Successfully published ${CHART_NAME} v${CHART_VERSION}${NC}"
echo ""
echo "Install with:"
if [[ "${PUBLISH_TYPE}" == "oci" ]]; then
  echo "  helm install myrelease ${REGISTRY_URL}/${CHART_NAME} --version ${CHART_VERSION}"
else
  echo "  helm repo add myrepo ${REGISTRY_URL}"
  echo "  helm install myrelease myrepo/${CHART_NAME} --version ${CHART_VERSION}"
fi
