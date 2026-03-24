#!/usr/bin/env bash
# =============================================================================
# bootstrap-apps.sh — Bootstrap an App of Apps pattern for Argo CD
#
# Creates a root Application that manages child Application manifests from a
# Git repository. Optionally scaffolds the directory structure and initial
# child apps in a local gitops repo.
#
# Usage:
#   ./bootstrap-apps.sh [OPTIONS]
#
# Options:
#   -n, --namespace     Argo CD namespace (default: argocd)
#   -r, --repo          GitOps repository URL (required)
#   -b, --branch        Target branch (default: main)
#   -p, --path          Path in repo containing child Application YAMLs (default: apps)
#   --project           Argo CD project name (default: default)
#   --name              Root application name (default: root)
#   --scaffold          Scaffold local directory structure for the gitops repo
#   --scaffold-dir      Local directory for scaffold output (default: ./gitops-repo)
#   --apps              Comma-separated list of initial apps to scaffold
#   --dest-server       Destination cluster URL (default: https://kubernetes.default.svc)
#   --dry-run           Print manifests without applying
#   -h, --help          Show this help message
#
# Examples:
#   # Create root app pointing to existing repo
#   ./bootstrap-apps.sh -r https://github.com/org/gitops.git
#
#   # Scaffold a new gitops repo structure with initial apps
#   ./bootstrap-apps.sh -r https://github.com/org/gitops.git \
#     --scaffold --apps frontend,backend,redis
#
#   # Custom path and project
#   ./bootstrap-apps.sh -r https://github.com/org/gitops.git \
#     -p platform/apps --project platform --name platform-root
#
#   # Dry run to preview the root Application manifest
#   ./bootstrap-apps.sh -r https://github.com/org/gitops.git --dry-run
# =============================================================================

set -euo pipefail

# Defaults
NAMESPACE="argocd"
REPO_URL=""
BRANCH="main"
APPS_PATH="apps"
PROJECT="default"
ROOT_NAME="root"
SCAFFOLD=false
SCAFFOLD_DIR="./gitops-repo"
APPS_LIST=""
DEST_SERVER="https://kubernetes.default.svc"
DRY_RUN=false

usage() {
  head -n 34 "$0" | tail -n 32 | sed 's/^# \?//'
  exit 0
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)    NAMESPACE="$2"; shift 2 ;;
    -r|--repo)         REPO_URL="$2"; shift 2 ;;
    -b|--branch)       BRANCH="$2"; shift 2 ;;
    -p|--path)         APPS_PATH="$2"; shift 2 ;;
    --project)         PROJECT="$2"; shift 2 ;;
    --name)            ROOT_NAME="$2"; shift 2 ;;
    --scaffold)        SCAFFOLD=true; shift ;;
    --scaffold-dir)    SCAFFOLD_DIR="$2"; shift 2 ;;
    --apps)            APPS_LIST="$2"; shift 2 ;;
    --dest-server)     DEST_SERVER="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=true; shift ;;
    -h|--help)         usage ;;
    *)                 err "Unknown option: $1" ;;
  esac
done

[[ -n "$REPO_URL" ]] || err "--repo is required. Provide the GitOps repository URL."

# ─── Generate root Application manifest ────────────────────────────────────

generate_root_app() {
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ROOT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: argocd-bootstrap
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: ${PROJECT}
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${APPS_PATH}
  destination:
    server: ${DEST_SERVER}
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
}

# ─── Generate child Application manifest ───────────────────────────────────

generate_child_app() {
  local app_name="$1"
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: platform
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: ${PROJECT}
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: workloads/${app_name}/overlays/production
    # Uncomment for Kustomize:
    # kustomize:
    #   images:
    #     - name: ${app_name}
    #       newTag: latest
  destination:
    server: ${DEST_SERVER}
    namespace: ${app_name}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
EOF
}

# ─── Scaffold directory structure ──────────────────────────────────────────

do_scaffold() {
  log "Scaffolding gitops repo structure at: $SCAFFOLD_DIR"

  mkdir -p "$SCAFFOLD_DIR/${APPS_PATH}"
  mkdir -p "$SCAFFOLD_DIR/workloads"

  # Create README
  cat > "$SCAFFOLD_DIR/README.md" <<'READMEEOF'
# GitOps Repository

This repository follows the **App of Apps** pattern for Argo CD.

## Structure

```
├── apps/                    # Application manifests (managed by root app)
│   ├── frontend.yaml
│   ├── backend.yaml
│   └── ...
├── workloads/               # Actual Kubernetes manifests per app
│   ├── frontend/
│   │   ├── base/
│   │   │   ├── kustomization.yaml
│   │   │   ├── deployment.yaml
│   │   │   └── service.yaml
│   │   └── overlays/
│   │       ├── dev/
│   │       ├── staging/
│   │       └── production/
│   └── backend/
│       └── ...
└── README.md
```

## How it works

1. The **root** Application watches `apps/` and syncs any Application YAMLs it finds.
2. Each Application YAML in `apps/` points to a workload directory under `workloads/`.
3. Changes to workload manifests trigger sync for that specific application.
READMEEOF

  # Generate child app manifests
  if [[ -n "$APPS_LIST" ]]; then
    IFS=',' read -ra APPS <<< "$APPS_LIST"
    for app in "${APPS[@]}"; do
      app=$(echo "$app" | xargs)  # trim whitespace
      log "  Creating Application manifest: ${APPS_PATH}/${app}.yaml"
      generate_child_app "$app" > "$SCAFFOLD_DIR/${APPS_PATH}/${app}.yaml"

      # Scaffold workload directories with Kustomize structure
      local base_dir="$SCAFFOLD_DIR/workloads/${app}/base"
      mkdir -p "$base_dir"
      for env in dev staging production; do
        mkdir -p "$SCAFFOLD_DIR/workloads/${app}/overlays/${env}"
        cat > "$SCAFFOLD_DIR/workloads/${app}/overlays/${env}/kustomization.yaml" <<KUSTEOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${app}
resources:
  - ../../base
patches: []
# images:
#   - name: ${app}
#     newTag: v1.0.0
KUSTEOF
      done

      # Base kustomization
      cat > "$base_dir/kustomization.yaml" <<KUSTEOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
KUSTEOF

      # Placeholder deployment
      cat > "$base_dir/deployment.yaml" <<DEPLEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${app}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${app}
  template:
    metadata:
      labels:
        app: ${app}
    spec:
      containers:
        - name: ${app}
          image: ${app}:latest
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
DEPLEOF

      # Placeholder service
      cat > "$base_dir/service.yaml" <<SVCEOF
apiVersion: v1
kind: Service
metadata:
  name: ${app}
spec:
  selector:
    app: ${app}
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
SVCEOF
    done
  fi

  log "Scaffold complete. Files:"
  find "$SCAFFOLD_DIR" -type f | sort | sed 's|^|  |'
  echo
  log "Next steps:"
  log "  1. cd $SCAFFOLD_DIR && git init && git add . && git commit -m 'initial gitops structure'"
  log "  2. Push to $REPO_URL"
  log "  3. Run this script again without --scaffold to create the root Application"
}

# ─── Apply root Application ───────────────────────────────────────────────

do_apply() {
  local manifest
  manifest=$(generate_root_app)

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry run — root Application manifest:"
    echo "---"
    echo "$manifest"
    return
  fi

  command -v kubectl >/dev/null 2>&1 || err "kubectl not found in PATH"

  log "Creating root Application '${ROOT_NAME}' in namespace '${NAMESPACE}'"
  log "  Repository: $REPO_URL"
  log "  Branch:     $BRANCH"
  log "  Path:       $APPS_PATH"
  log "  Project:    $PROJECT"
  echo

  echo "$manifest" | kubectl apply -f -

  echo
  log "Root Application created successfully."
  log "Argo CD will now sync all Application manifests found in '${APPS_PATH}/'."
  log "Monitor: argocd app get ${ROOT_NAME}"
}

# ─── Main ──────────────────────────────────────────────────────────────────

if [[ "$SCAFFOLD" == "true" ]]; then
  do_scaffold
fi

do_apply
