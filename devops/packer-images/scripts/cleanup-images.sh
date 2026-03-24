#!/usr/bin/env bash
# =============================================================================
# cleanup-images.sh — Clean up old/unused machine images across cloud providers
#
# Usage:
#   ./cleanup-images.sh <provider> [options]
#   ./cleanup-images.sh aws --prefix "app-base" --keep 5
#   ./cleanup-images.sh aws --prefix "app-base" --keep 5 --dry-run
#   ./cleanup-images.sh aws --prefix "app-base" --keep 3 --region us-west-2
#   ./cleanup-images.sh aws --older-than 30 --prefix "dev-"
#   ./cleanup-images.sh azure --prefix "golden" --keep 3 --resource-group images-rg
#   ./cleanup-images.sh gcp --prefix "golden" --keep 5 --project my-project
#   ./cleanup-images.sh docker --repo "myorg/myapp" --keep 10
#   ./cleanup-images.sh all --prefix "app-" --keep 5 --dry-run
#
# Providers:
#   aws       Clean up Amazon Machine Images (AMIs) and associated snapshots
#   azure     Clean up Azure managed images
#   gcp       Clean up Google Compute Engine images
#   docker    Clean up Docker images from a registry
#   all       Clean up across all configured providers
#
# Options:
#   --prefix PREFIX       Image name prefix to match (required)
#   --keep N              Number of most recent images to keep (required)
#   --older-than DAYS     Alternative: delete images older than N days
#   --region REGION       AWS region (default: us-east-1, or AWS_REGION env var)
#   --resource-group RG   Azure resource group for managed images
#   --project PROJECT     GCP project ID
#   --repo REPOSITORY     Docker repository (e.g., myorg/myapp)
#   --registry REGISTRY   Docker registry URL (default: docker.io)
#   --dry-run             Show what would be deleted without deleting
#   --force               Skip confirmation prompt
#   --quiet               Suppress non-essential output
#   -h, --help            Show this help
#
# Environment Variables:
#   AWS_REGION              Default AWS region
#   AZURE_SUBSCRIPTION_ID   Azure subscription
#   GCP_PROJECT_ID          GCP project
#
# Exit Codes:
#   0  Success (or dry run completed)
#   1  Cleanup failure
#   2  Missing dependency
#   3  Invalid arguments
# =============================================================================

set -euo pipefail

# --- Defaults ---
PROVIDER=""
PREFIX=""
KEEP=""
OLDER_THAN=""
AWS_REGION="${AWS_REGION:-us-east-1}"
AZURE_RG=""
GCP_PROJECT="${GCP_PROJECT_ID:-}"
DOCKER_REPO=""
DOCKER_REGISTRY="docker.io"
DRY_RUN=false
FORCE=false
QUIET=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { [ "$QUIET" = true ] && return; echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_delete(){ echo -e "${RED}[DEL]${NC}   $*"; }
log_dry()   { echo -e "${CYAN}[DRY]${NC}   $*"; }

# --- Help ---
show_help() {
  sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//' | head -n -1
  exit 0
}

# --- Argument parsing ---
[ $# -eq 0 ] && { show_help; }

PROVIDER="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)         PREFIX="$2"; shift 2 ;;
    --keep)           KEEP="$2"; shift 2 ;;
    --older-than)     OLDER_THAN="$2"; shift 2 ;;
    --region)         AWS_REGION="$2"; shift 2 ;;
    --resource-group) AZURE_RG="$2"; shift 2 ;;
    --project)        GCP_PROJECT="$2"; shift 2 ;;
    --repo)           DOCKER_REPO="$2"; shift 2 ;;
    --registry)       DOCKER_REGISTRY="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --force)          FORCE=true; shift ;;
    --quiet|-q)       QUIET=true; shift ;;
    -h|--help)        show_help ;;
    *)                log_error "Unknown option: $1"; exit 3 ;;
  esac
done

# --- Validation ---
if [ -z "$PREFIX" ] && [ "$PROVIDER" != "docker" ]; then
  log_error "--prefix is required"
  exit 3
fi

if [ -z "$KEEP" ] && [ -z "$OLDER_THAN" ]; then
  log_error "Either --keep N or --older-than DAYS is required"
  exit 3
fi

require_cmd() {
  command -v "$1" &>/dev/null || { log_error "'$1' is required but not found"; exit 2; }
}

# --- Confirmation prompt ---
confirm() {
  if [ "$FORCE" = true ] || [ "$DRY_RUN" = true ]; then return 0; fi
  echo ""
  read -rp "Proceed with deletion? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) echo "Aborted."; exit 0 ;;
  esac
}

# =========================================================================
# AWS Cleanup
# =========================================================================
cleanup_aws() {
  require_cmd aws
  require_cmd jq

  log_info "AWS AMI cleanup: prefix='$PREFIX' region=$AWS_REGION"

  # Get all matching AMIs sorted by creation date (oldest first)
  local amis
  amis=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners self \
    --filters "Name=name,Values=${PREFIX}*" \
    --query 'sort_by(Images, &CreationDate)[*].{id:ImageId,name:Name,created:CreationDate}' \
    --output json 2>/dev/null)

  local total
  total=$(echo "$amis" | jq 'length')
  log_info "Found $total AMI(s) matching '$PREFIX*'"

  if [ "$total" -eq 0 ]; then
    log_info "Nothing to clean up"
    return 0
  fi

  # Determine which images to delete
  local to_delete_json
  if [ -n "$KEEP" ]; then
    if [ "$total" -le "$KEEP" ]; then
      log_info "Total ($total) <= keep ($KEEP) — nothing to delete"
      return 0
    fi
    local to_delete_count=$((total - KEEP))
    to_delete_json=$(echo "$amis" | jq ".[:$to_delete_count]")
    log_info "Will delete $to_delete_count AMI(s), keeping newest $KEEP"
  elif [ -n "$OLDER_THAN" ]; then
    local cutoff_date
    cutoff_date=$(date -u -d "$OLDER_THAN days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
                  date -u -v-"${OLDER_THAN}"d +%Y-%m-%dT%H:%M:%S 2>/dev/null)
    to_delete_json=$(echo "$amis" | jq --arg cutoff "$cutoff_date" '[.[] | select(.created < $cutoff)]')
    local to_delete_count
    to_delete_count=$(echo "$to_delete_json" | jq 'length')
    log_info "Will delete $to_delete_count AMI(s) older than $OLDER_THAN days (before $cutoff_date)"
  fi

  # List images to delete
  echo ""
  echo "Images to delete:"
  echo "$to_delete_json" | jq -r '.[] | "  \(.id)  \(.name)  \(.created)"'
  echo ""

  if [ -n "$KEEP" ]; then
    echo "Images to KEEP (newest $KEEP):"
    echo "$amis" | jq -r ".[-${KEEP}:][] | \"  \(.id)  \(.name)  \(.created)\""
    echo ""
  fi

  confirm

  # Delete each AMI and its snapshots
  echo "$to_delete_json" | jq -r '.[].id' | while read -r ami_id; do
    local ami_name
    ami_name=$(echo "$to_delete_json" | jq -r --arg id "$ami_id" '.[] | select(.id == $id) | .name')

    if [ "$DRY_RUN" = true ]; then
      log_dry "Would deregister $ami_id ($ami_name) and associated snapshots"
      continue
    fi

    # Get snapshots before deregistering
    local snapshots
    snapshots=$(aws ec2 describe-images \
      --region "$AWS_REGION" \
      --image-ids "$ami_id" \
      --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
      --output text 2>/dev/null || echo "")

    # Deregister AMI
    log_delete "Deregistering $ami_id ($ami_name)"
    aws ec2 deregister-image --region "$AWS_REGION" --image-id "$ami_id"

    # Delete snapshots
    for snap in $snapshots; do
      if [ -n "$snap" ] && [ "$snap" != "None" ] && [ "$snap" != "null" ]; then
        log_delete "  Deleting snapshot $snap"
        aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$snap" 2>/dev/null || \
          log_warn "  Could not delete snapshot $snap (may be in use)"
      fi
    done
  done

  log_info "AWS cleanup complete ✓"
}

# =========================================================================
# Azure Cleanup
# =========================================================================
cleanup_azure() {
  require_cmd az
  require_cmd jq

  if [ -z "$AZURE_RG" ]; then
    log_error "--resource-group is required for Azure cleanup"
    exit 3
  fi

  log_info "Azure image cleanup: prefix='$PREFIX' rg=$AZURE_RG"

  # List all matching managed images sorted by date
  local images
  images=$(az image list \
    --resource-group "$AZURE_RG" \
    --query "sort_by([?starts_with(name, '${PREFIX}')], &name) | [*].{id:id,name:name}" \
    --output json 2>/dev/null)

  local total
  total=$(echo "$images" | jq 'length')
  log_info "Found $total image(s) matching '$PREFIX*'"

  if [ "$total" -eq 0 ] || { [ -n "$KEEP" ] && [ "$total" -le "$KEEP" ]; }; then
    log_info "Nothing to clean up"
    return 0
  fi

  local to_delete_count=$((total - KEEP))
  local to_delete_json
  to_delete_json=$(echo "$images" | jq ".[:$to_delete_count]")

  echo ""
  echo "Images to delete ($to_delete_count):"
  echo "$to_delete_json" | jq -r '.[] | "  \(.name)"'
  echo ""

  confirm

  echo "$to_delete_json" | jq -r '.[].id' | while read -r image_id; do
    local image_name
    image_name=$(echo "$to_delete_json" | jq -r --arg id "$image_id" '.[] | select(.id == $id) | .name')
    if [ "$DRY_RUN" = true ]; then
      log_dry "Would delete $image_name"
    else
      log_delete "Deleting $image_name"
      az image delete --ids "$image_id" 2>/dev/null || log_warn "Could not delete $image_name"
    fi
  done

  log_info "Azure cleanup complete ✓"
}

# =========================================================================
# GCP Cleanup
# =========================================================================
cleanup_gcp() {
  require_cmd gcloud
  require_cmd jq

  local project="${GCP_PROJECT}"
  if [ -z "$project" ]; then
    project=$(gcloud config get-value project 2>/dev/null)
  fi
  if [ -z "$project" ]; then
    log_error "--project is required (or set GCP_PROJECT_ID / gcloud config)"
    exit 3
  fi

  log_info "GCP image cleanup: prefix='$PREFIX' project=$project"

  # List matching images sorted by creation timestamp
  local images
  images=$(gcloud compute images list \
    --project="$project" \
    --filter="name~'^${PREFIX}'" \
    --sort-by=creationTimestamp \
    --format=json 2>/dev/null)

  local total
  total=$(echo "$images" | jq 'length')
  log_info "Found $total image(s) matching '$PREFIX*'"

  if [ "$total" -eq 0 ] || { [ -n "$KEEP" ] && [ "$total" -le "$KEEP" ]; }; then
    log_info "Nothing to clean up"
    return 0
  fi

  local to_delete_count=$((total - KEEP))
  local to_delete_json
  to_delete_json=$(echo "$images" | jq ".[:$to_delete_count]")

  echo ""
  echo "Images to delete ($to_delete_count):"
  echo "$to_delete_json" | jq -r '.[] | "  \(.name)  \(.creationTimestamp)"'
  echo ""

  confirm

  echo "$to_delete_json" | jq -r '.[].name' | while read -r image_name; do
    if [ "$DRY_RUN" = true ]; then
      log_dry "Would delete $image_name"
    else
      log_delete "Deleting $image_name"
      gcloud compute images delete "$image_name" \
        --project="$project" \
        --quiet 2>/dev/null || log_warn "Could not delete $image_name"
    fi
  done

  log_info "GCP cleanup complete ✓"
}

# =========================================================================
# Docker Cleanup
# =========================================================================
cleanup_docker() {
  require_cmd docker

  if [ -z "$DOCKER_REPO" ]; then
    log_error "--repo is required for Docker cleanup (e.g., myorg/myapp)"
    exit 3
  fi

  log_info "Docker image cleanup: repo=$DOCKER_REPO"

  # List local images for the repository
  local images
  images=$(docker images "$DOCKER_REPO" --format '{{.ID}}\t{{.Tag}}\t{{.CreatedAt}}' | sort -t$'\t' -k3 2>/dev/null)

  local total
  total=$(echo "$images" | grep -c '[^ ]' || echo 0)
  log_info "Found $total local image(s) for $DOCKER_REPO"

  if [ "$total" -eq 0 ] || { [ -n "$KEEP" ] && [ "$total" -le "$KEEP" ]; }; then
    log_info "Nothing to clean up"
    return 0
  fi

  local to_delete_count=$((total - KEEP))

  echo ""
  echo "Images to delete ($to_delete_count oldest):"
  echo "$images" | head -"$to_delete_count" | while IFS=$'\t' read -r id tag created; do
    echo "  $DOCKER_REPO:$tag ($id, $created)"
  done
  echo ""

  confirm

  echo "$images" | head -"$to_delete_count" | while IFS=$'\t' read -r id tag created; do
    if [ "$DRY_RUN" = true ]; then
      log_dry "Would remove $DOCKER_REPO:$tag ($id)"
    else
      log_delete "Removing $DOCKER_REPO:$tag ($id)"
      docker rmi "$DOCKER_REPO:$tag" 2>/dev/null || log_warn "Could not remove $DOCKER_REPO:$tag"
    fi
  done

  # Prune dangling images
  if [ "$DRY_RUN" = false ]; then
    log_info "Pruning dangling images..."
    docker image prune -f >/dev/null 2>&1 || true
  fi

  log_info "Docker cleanup complete ✓"
}

# =========================================================================
# Dispatch
# =========================================================================
case "$PROVIDER" in
  aws)     cleanup_aws ;;
  azure)   cleanup_azure ;;
  gcp)     cleanup_gcp ;;
  docker)  cleanup_docker ;;
  all)
    log_info "Running cleanup across all providers"
    echo ""
    # Run each provider, skip if CLI not available
    if command -v aws &>/dev/null; then
      cleanup_aws
      echo ""
    else
      log_warn "Skipping AWS (aws CLI not found)"
    fi

    if command -v az &>/dev/null && [ -n "$AZURE_RG" ]; then
      cleanup_azure
      echo ""
    else
      log_warn "Skipping Azure (az CLI not found or --resource-group not set)"
    fi

    if command -v gcloud &>/dev/null; then
      cleanup_gcp
      echo ""
    else
      log_warn "Skipping GCP (gcloud CLI not found)"
    fi

    if command -v docker &>/dev/null && [ -n "$DOCKER_REPO" ]; then
      cleanup_docker
      echo ""
    else
      log_warn "Skipping Docker (docker CLI not found or --repo not set)"
    fi
    ;;
  *)
    log_error "Unknown provider: $PROVIDER (use: aws, azure, gcp, docker, all)"
    exit 3
    ;;
esac

log_info "Done"
