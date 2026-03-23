#!/usr/bin/env bash
# =============================================================================
# backup-restore.sh — Backup and restore Argo CD configuration
#
# Backs up: Applications, ApplicationSets, AppProjects, repository credentials,
# cluster secrets, ConfigMaps, and notification config.
#
# Usage:
#   ./backup-restore.sh backup  [OPTIONS]
#   ./backup-restore.sh restore [OPTIONS]
#
# Options:
#   -n, --namespace   Argo CD namespace (default: argocd)
#   -d, --dir         Backup directory (default: argocd-backup-<timestamp>)
#   -c, --components  Comma-separated list of components to backup/restore
#                     (apps,appsets,projects,repos,clusters,config,secrets)
#                     Default: all
#   --dry-run         Print commands without executing
#   -h, --help        Show this help message
#
# Examples:
#   ./backup-restore.sh backup                              # Full backup
#   ./backup-restore.sh backup -d /tmp/argocd-bak           # Custom directory
#   ./backup-restore.sh backup -c apps,projects             # Selective backup
#   ./backup-restore.sh restore -d argocd-backup-20240101   # Restore from dir
# =============================================================================

set -euo pipefail

NAMESPACE="argocd"
BACKUP_DIR=""
COMPONENTS="apps,appsets,projects,repos,clusters,config,secrets"
DRY_RUN=false
ACTION=""

usage() {
  head -n 22 "$0" | tail -n 20 | sed 's/^# \?//'
  exit 0
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "(dry-run) $*"
  else
    eval "$@"
  fi
}

has_component() {
  [[ ",$COMPONENTS," == *",$1,"* ]]
}

# Parse arguments
ACTION="${1:-}"; shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -d|--dir)        BACKUP_DIR="$2"; shift 2 ;;
    -c|--components) COMPONENTS="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)       usage ;;
    *)               err "Unknown option: $1" ;;
  esac
done

[[ "$ACTION" =~ ^(backup|restore)$ ]] || { usage; }
command -v kubectl >/dev/null 2>&1 || err "kubectl not found in PATH"

# ─── BACKUP ──────────────────────────────────────────────────────────────────

do_backup() {
  [[ -z "$BACKUP_DIR" ]] && BACKUP_DIR="argocd-backup-$(date +%Y%m%d-%H%M%S)"

  log "Starting Argo CD backup → $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"

  if has_component apps; then
    log "Backing up Applications..."
    run "kubectl get applications.argoproj.io -n $NAMESPACE -o yaml > '$BACKUP_DIR/applications.yaml'" || log "  No Applications found"
  fi

  if has_component appsets; then
    log "Backing up ApplicationSets..."
    run "kubectl get applicationsets.argoproj.io -n $NAMESPACE -o yaml > '$BACKUP_DIR/applicationsets.yaml'" || log "  No ApplicationSets found"
  fi

  if has_component projects; then
    log "Backing up AppProjects..."
    run "kubectl get appprojects.argoproj.io -n $NAMESPACE -o yaml > '$BACKUP_DIR/appprojects.yaml'" || log "  No AppProjects found"
  fi

  if has_component repos; then
    log "Backing up repository secrets..."
    run "kubectl get secrets -n $NAMESPACE -l argocd.argoproj.io/secret-type=repository -o yaml > '$BACKUP_DIR/repo-secrets.yaml'" 2>/dev/null || log "  No repo secrets found"
    run "kubectl get secrets -n $NAMESPACE -l argocd.argoproj.io/secret-type=repo-creds -o yaml > '$BACKUP_DIR/repo-cred-templates.yaml'" 2>/dev/null || log "  No repo credential templates found"
  fi

  if has_component clusters; then
    log "Backing up cluster secrets..."
    run "kubectl get secrets -n $NAMESPACE -l argocd.argoproj.io/secret-type=cluster -o yaml > '$BACKUP_DIR/cluster-secrets.yaml'" 2>/dev/null || log "  No cluster secrets found"
  fi

  if has_component config; then
    log "Backing up ConfigMaps..."
    local cms=("argocd-cm" "argocd-rbac-cm" "argocd-cmd-params-cm" "argocd-notifications-cm" "argocd-ssh-known-hosts-cm" "argocd-tls-certs-cm")
    for cm in "${cms[@]}"; do
      run "kubectl get configmap -n $NAMESPACE $cm -o yaml > '$BACKUP_DIR/cm-$cm.yaml'" 2>/dev/null || log "  ConfigMap $cm not found (skipped)"
    done
  fi

  if has_component secrets; then
    log "Backing up Secrets (argocd-secret, notifications)..."
    run "kubectl get secret -n $NAMESPACE argocd-secret -o yaml > '$BACKUP_DIR/argocd-secret.yaml'" 2>/dev/null || log "  argocd-secret not found"
    run "kubectl get secret -n $NAMESPACE argocd-notifications-secret -o yaml > '$BACKUP_DIR/notifications-secret.yaml'" 2>/dev/null || log "  notifications-secret not found"
  fi

  # Create tarball
  if [[ "$DRY_RUN" != "true" ]]; then
    tar czf "${BACKUP_DIR}.tar.gz" "$BACKUP_DIR" 2>/dev/null || true
    log "Backup complete: ${BACKUP_DIR}.tar.gz"
    log "Files:"
    ls -la "$BACKUP_DIR/"
  fi
}

# ─── RESTORE ─────────────────────────────────────────────────────────────────

strip_metadata() {
  # Remove cluster-specific metadata fields that prevent re-apply
  local file="$1"
  if command -v yq >/dev/null 2>&1; then
    yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
            .metadata.generation, .metadata.managedFields,
            .items[]?.metadata.resourceVersion, .items[]?.metadata.uid,
            .items[]?.metadata.creationTimestamp, .items[]?.metadata.generation,
            .items[]?.metadata.managedFields)' "$file"
  else
    # Fallback: use sed for basic cleanup (less reliable)
    sed -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
        -e '/generation:/d' "$file"
  fi
}

do_restore() {
  [[ -z "$BACKUP_DIR" ]] && err "Restore requires --dir <backup-directory>"
  [[ -d "$BACKUP_DIR" ]] || err "Backup directory not found: $BACKUP_DIR"

  log "Starting Argo CD restore from $BACKUP_DIR"
  log "  Namespace: $NAMESPACE"

  # Ensure namespace exists
  run "kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"

  # Restore order: config → secrets → projects → repos → clusters → apps → appsets
  local restore_order=("config" "secrets" "projects" "repos" "clusters" "apps" "appsets")

  for component in "${restore_order[@]}"; do
    has_component "$component" || continue

    case "$component" in
      config)
        log "Restoring ConfigMaps..."
        for f in "$BACKUP_DIR"/cm-*.yaml; do
          [[ -f "$f" ]] || continue
          log "  Applying $f"
          if [[ "$DRY_RUN" != "true" ]]; then
            strip_metadata "$f" | kubectl apply -n "$NAMESPACE" -f - || log "  Warning: failed to apply $f"
          fi
        done
        ;;
      secrets)
        log "Restoring Secrets..."
        for f in "$BACKUP_DIR/argocd-secret.yaml" "$BACKUP_DIR/notifications-secret.yaml"; do
          [[ -f "$f" ]] || continue
          log "  Applying $f"
          if [[ "$DRY_RUN" != "true" ]]; then
            strip_metadata "$f" | kubectl apply -n "$NAMESPACE" -f - || log "  Warning: failed to apply $f"
          fi
        done
        ;;
      projects)
        [[ -f "$BACKUP_DIR/appprojects.yaml" ]] || continue
        log "Restoring AppProjects..."
        if [[ "$DRY_RUN" != "true" ]]; then
          strip_metadata "$BACKUP_DIR/appprojects.yaml" | kubectl apply -n "$NAMESPACE" -f - || log "  Warning: failed"
        fi
        ;;
      repos)
        for f in "$BACKUP_DIR/repo-secrets.yaml" "$BACKUP_DIR/repo-cred-templates.yaml"; do
          [[ -f "$f" ]] || continue
          log "Restoring repo credentials from $f..."
          if [[ "$DRY_RUN" != "true" ]]; then
            strip_metadata "$f" | kubectl apply -n "$NAMESPACE" -f - || log "  Warning: failed"
          fi
        done
        ;;
      clusters)
        [[ -f "$BACKUP_DIR/cluster-secrets.yaml" ]] || continue
        log "Restoring cluster secrets..."
        if [[ "$DRY_RUN" != "true" ]]; then
          strip_metadata "$BACKUP_DIR/cluster-secrets.yaml" | kubectl apply -n "$NAMESPACE" -f - || log "  Warning: failed"
        fi
        ;;
      apps)
        [[ -f "$BACKUP_DIR/applications.yaml" ]] || continue
        log "Restoring Applications..."
        if [[ "$DRY_RUN" != "true" ]]; then
          strip_metadata "$BACKUP_DIR/applications.yaml" | kubectl apply -n "$NAMESPACE" -f - || log "  Warning: failed"
        fi
        ;;
      appsets)
        [[ -f "$BACKUP_DIR/applicationsets.yaml" ]] || continue
        log "Restoring ApplicationSets..."
        if [[ "$DRY_RUN" != "true" ]]; then
          strip_metadata "$BACKUP_DIR/applicationsets.yaml" | kubectl apply -n "$NAMESPACE" -f - || log "  Warning: failed"
        fi
        ;;
    esac
  done

  log "Restore complete. Restarting Argo CD components..."
  run "kubectl rollout restart deploy -n $NAMESPACE" || true
  run "kubectl rollout restart statefulset -n $NAMESPACE" 2>/dev/null || true

  log "Done. Verify with: argocd app list"
}

# ─── MAIN ────────────────────────────────────────────────────────────────────

case "$ACTION" in
  backup)  do_backup ;;
  restore) do_restore ;;
esac
