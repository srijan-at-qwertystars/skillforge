#!/usr/bin/env bash
# =============================================================================
# install-argocd.sh — Install Argo CD on a Kubernetes cluster
#
# Usage:
#   ./install-argocd.sh [OPTIONS]
#
# Options:
#   -m, --method     Installation method: helm | manifests (default: manifests)
#   -t, --type       Installation type: ha | non-ha (default: non-ha)
#   -n, --namespace  Target namespace (default: argocd)
#   -v, --version    Argo CD version (default: stable)
#   --values         Helm values file (only with --method helm)
#   --dry-run        Print commands without executing
#   -h, --help       Show this help message
#
# Examples:
#   ./install-argocd.sh                                    # Non-HA with manifests
#   ./install-argocd.sh -m helm -t ha                      # HA with Helm
#   ./install-argocd.sh -m helm --values my-values.yaml    # Helm with custom values
#   ./install-argocd.sh -t ha -v v2.9.3                    # HA manifests, specific version
# =============================================================================

set -euo pipefail

# Defaults
METHOD="manifests"
TYPE="non-ha"
NAMESPACE="argocd"
VERSION="stable"
VALUES_FILE=""
DRY_RUN=false

usage() {
  head -n 18 "$0" | tail -n 16 | sed 's/^# \?//'
  exit 0
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

run() {
  log "$ $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "(dry-run: skipped)"
  else
    eval "$@"
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--method)    METHOD="$2"; shift 2 ;;
    -t|--type)      TYPE="$2"; shift 2 ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -v|--version)   VERSION="$2"; shift 2 ;;
    --values)       VALUES_FILE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage ;;
    *)              err "Unknown option: $1" ;;
  esac
done

# Validate inputs
[[ "$METHOD" =~ ^(helm|manifests)$ ]] || err "Invalid method: $METHOD (use 'helm' or 'manifests')"
[[ "$TYPE" =~ ^(ha|non-ha)$ ]]       || err "Invalid type: $TYPE (use 'ha' or 'non-ha')"

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || err "kubectl not found in PATH"
if [[ "$METHOD" == "helm" ]]; then
  command -v helm >/dev/null 2>&1 || err "helm not found in PATH (required for --method helm)"
fi

log "Installing Argo CD"
log "  Method:    $METHOD"
log "  Type:      $TYPE"
log "  Namespace: $NAMESPACE"
log "  Version:   $VERSION"
echo

# Create namespace
run "kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"

if [[ "$METHOD" == "manifests" ]]; then
  # Determine manifest URL
  if [[ "$TYPE" == "ha" ]]; then
    MANIFEST_PATH="manifests/ha/install.yaml"
  else
    MANIFEST_PATH="manifests/install.yaml"
  fi

  if [[ "$VERSION" == "stable" ]]; then
    URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/$MANIFEST_PATH"
  else
    URL="https://raw.githubusercontent.com/argoproj/argo-cd/$VERSION/$MANIFEST_PATH"
  fi

  log "Applying manifests from: $URL"
  run "kubectl apply -n $NAMESPACE -f $URL"

elif [[ "$METHOD" == "helm" ]]; then
  log "Adding Argo Helm repo"
  run "helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true"
  run "helm repo update argo"

  HELM_ARGS="argo/argo-cd -n $NAMESPACE --create-namespace"

  # Set version if not 'stable'
  if [[ "$VERSION" != "stable" ]]; then
    # Strip leading 'v' for Helm chart version
    CHART_VERSION="${VERSION#v}"
    HELM_ARGS="$HELM_ARGS --version $CHART_VERSION"
  fi

  # HA settings
  if [[ "$TYPE" == "ha" ]]; then
    HELM_ARGS="$HELM_ARGS \
      --set controller.replicas=2 \
      --set server.replicas=2 \
      --set repoServer.replicas=2 \
      --set redis-ha.enabled=true \
      --set redis-ha.haproxy.enabled=true"
  fi

  # Custom values file
  if [[ -n "$VALUES_FILE" ]]; then
    [[ -f "$VALUES_FILE" ]] || err "Values file not found: $VALUES_FILE"
    HELM_ARGS="$HELM_ARGS -f $VALUES_FILE"
  fi

  log "Installing/upgrading Argo CD via Helm"
  run "helm upgrade --install argocd $HELM_ARGS"
fi

echo
log "Waiting for deployments to be ready..."
if [[ "$DRY_RUN" != "true" ]]; then
  kubectl wait --for=condition=available deploy --all -n "$NAMESPACE" --timeout=300s 2>/dev/null || {
    log "Warning: Timed out waiting for all deployments. Check pod status:"
    kubectl get pods -n "$NAMESPACE"
  }
fi

echo
log "Argo CD installed successfully in namespace '$NAMESPACE'"

# Print initial admin password
if [[ "$DRY_RUN" != "true" ]]; then
  ADMIN_PASS=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) || true
  if [[ -n "${ADMIN_PASS:-}" ]]; then
    log "Initial admin password: $ADMIN_PASS"
    log "Change it immediately: argocd account update-password"
  else
    log "Initial admin secret not found (may be using SSO or already deleted)"
  fi
fi

log "Access the UI: kubectl port-forward svc/argocd-server -n $NAMESPACE 8080:443"
