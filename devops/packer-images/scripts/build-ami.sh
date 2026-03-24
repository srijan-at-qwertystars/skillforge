#!/usr/bin/env bash
# =============================================================================
# build-ami.sh — Build, tag, and manage AMIs with Packer
#
# Usage:
#   ./build-ami.sh build [--var-file <file>] [--only <source>] [--debug]
#   ./build-ami.sh validate [--var-file <file>]
#   ./build-ami.sh cleanup --prefix <ami-prefix> --keep <count> [--region <region>] [--dry-run]
#   ./build-ami.sh register --manifest <file> --bucket <hcp-bucket> [--channel <channel>]
#   ./build-ami.sh tag --ami-id <ami-id> --tags Key=Value,Key2=Value2
#   ./build-ami.sh list --prefix <ami-prefix> [--region <region>]
#
# Examples:
#   ./build-ami.sh build --var-file prod.pkrvars.hcl
#   ./build-ami.sh cleanup --prefix "app-production" --keep 5
#   ./build-ami.sh cleanup --prefix "app-dev" --keep 3 --dry-run
#   ./build-ami.sh tag --ami-id ami-12345678 --tags Team=platform,CostCenter=eng
#   ./build-ami.sh list --prefix "app-"
#
# Environment variables:
#   PACKER_DIR          Directory containing .pkr.hcl files (default: .)
#   AWS_REGION          AWS region (default: us-east-1)
#   PACKER_LOG          Enable debug logging (set to 1)
#   HCP_CLIENT_ID       HCP Packer credentials (for register command)
#   HCP_CLIENT_SECRET   HCP Packer credentials (for register command)
# =============================================================================

set -euo pipefail

# --- Defaults ---
PACKER_DIR="${PACKER_DIR:-.}"
AWS_REGION="${AWS_REGION:-us-east-1}"
VAR_FILE=""
ONLY_SOURCE=""
DEBUG=false
DRY_RUN=false
MANIFEST_FILE="manifests/manifest.json"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}==>${NC} $*"; }
log_warn()  { echo -e "${YELLOW}==> WARNING:${NC} $*"; }
log_error() { echo -e "${RED}==> ERROR:${NC} $*" >&2; }

# --- Preflight checks ---
require_cmd() {
  command -v "$1" &>/dev/null || { log_error "'$1' is required but not found"; exit 1; }
}

# --- Commands ---

cmd_validate() {
  require_cmd packer
  log_info "Formatting check"
  packer fmt -check -diff "$PACKER_DIR" || {
    log_warn "Files need formatting. Run: packer fmt -recursive $PACKER_DIR"
  }

  log_info "Initializing plugins"
  packer init "$PACKER_DIR"

  log_info "Validating template"
  local args=()
  [ -n "$VAR_FILE" ] && args+=("-var-file=$VAR_FILE")
  packer validate "${args[@]}" "$PACKER_DIR"
  log_info "Validation passed ✅"
}

cmd_build() {
  require_cmd packer
  require_cmd jq

  cmd_validate

  log_info "Starting Packer build"
  local args=("-color=false")
  [ -n "$VAR_FILE" ] && args+=("-var-file=$VAR_FILE")
  [ -n "$ONLY_SOURCE" ] && args+=("-only=$ONLY_SOURCE")
  [ "$DEBUG" = true ] && {
    export PACKER_LOG=1
    export PACKER_LOG_PATH="packer-$(date +%Y%m%d-%H%M%S).log"
    log_info "Debug log: $PACKER_LOG_PATH"
    args+=("-on-error=ask")
  }

  packer build "${args[@]}" "$PACKER_DIR"

  # Extract AMI details from manifest
  if [ -f "$PACKER_DIR/$MANIFEST_FILE" ]; then
    local ami_id region
    ami_id=$(jq -r '.builds[-1].artifact_id' "$PACKER_DIR/$MANIFEST_FILE" | cut -d: -f2)
    region=$(jq -r '.builds[-1].artifact_id' "$PACKER_DIR/$MANIFEST_FILE" | cut -d: -f1)
    log_info "Build complete ✅"
    log_info "AMI ID: $ami_id"
    log_info "Region: $region"

    # Auto-tag with build metadata
    if command -v aws &>/dev/null && [ -n "$ami_id" ] && [ "$ami_id" != "null" ]; then
      log_info "Tagging AMI with build metadata"
      aws ec2 create-tags --region "$region" --resources "$ami_id" --tags \
        "Key=BuildTimestamp,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "Key=BuildHost,Value=$(hostname)" \
        "Key=GitSHA,Value=$(git rev-parse HEAD 2>/dev/null || echo 'unknown')" \
        2>/dev/null || log_warn "Could not tag AMI (AWS credentials may not be configured)"
    fi
  else
    log_warn "Manifest not found at $PACKER_DIR/$MANIFEST_FILE"
  fi
}

cmd_cleanup() {
  local prefix="$1"
  local keep="$2"
  local region="${3:-$AWS_REGION}"

  require_cmd aws
  require_cmd jq

  if [ -z "$prefix" ] || [ -z "$keep" ]; then
    log_error "Usage: $0 cleanup --prefix <ami-prefix> --keep <count> [--region <region>]"
    exit 1
  fi

  log_info "Finding AMIs with prefix '$prefix' in $region (keeping newest $keep)"

  # Get all matching AMIs sorted by creation date (oldest first)
  local amis
  amis=$(aws ec2 describe-images \
    --region "$region" \
    --owners self \
    --filters "Name=name,Values=${prefix}*" \
    --query 'sort_by(Images, &CreationDate)[*].[ImageId,Name,CreationDate]' \
    --output json)

  local total
  total=$(echo "$amis" | jq 'length')
  log_info "Found $total AMIs matching prefix '$prefix'"

  if [ "$total" -le "$keep" ]; then
    log_info "Nothing to clean up ($total <= $keep)"
    return 0
  fi

  local to_delete=$((total - keep))
  log_info "Will deregister $to_delete AMI(s)"

  echo "$amis" | jq -r ".[:$to_delete][] | @tsv" | while IFS=$'\t' read -r ami_id ami_name created; do
    if [ "$DRY_RUN" = true ]; then
      echo "  [DRY RUN] Would deregister: $ami_id ($ami_name, created $created)"
    else
      log_info "Deregistering: $ami_id ($ami_name)"

      # Find associated snapshots BEFORE deregistering
      local snapshots
      snapshots=$(aws ec2 describe-images \
        --region "$region" \
        --image-ids "$ami_id" \
        --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
        --output text 2>/dev/null || echo "")

      # Deregister AMI
      aws ec2 deregister-image --region "$region" --image-id "$ami_id"

      # Delete associated snapshots
      for snap in $snapshots; do
        if [ -n "$snap" ] && [ "$snap" != "None" ]; then
          log_info "  Deleting snapshot: $snap"
          aws ec2 delete-snapshot --region "$region" --snapshot-id "$snap" 2>/dev/null || true
        fi
      done
    fi
  done

  log_info "Cleanup complete ✅"
}

cmd_register() {
  local manifest="$1"
  local bucket="$2"
  local channel="${3:-}"

  require_cmd hcp

  if [ -z "$manifest" ] || [ -z "$bucket" ]; then
    log_error "Usage: $0 register --manifest <file> --bucket <hcp-bucket> [--channel <channel>]"
    exit 1
  fi

  if [ ! -f "$manifest" ]; then
    log_error "Manifest file not found: $manifest"
    exit 1
  fi

  log_info "Build already registered via hcp_packer_registry block"
  log_info "Use HCP CLI to manage channels:"

  if [ -n "$channel" ]; then
    local fingerprint
    fingerprint=$(jq -r '.builds[-1].packer_run_uuid' "$manifest")
    log_info "Promoting version $fingerprint to channel '$channel'"
    hcp packer channels set-version \
      --bucket-name "$bucket" \
      --channel "$channel" \
      --version "$fingerprint"
    log_info "Promoted to $channel ✅"
  fi
}

cmd_tag() {
  local ami_id="$1"
  local tags_str="$2"
  local region="${AWS_REGION}"

  require_cmd aws

  if [ -z "$ami_id" ] || [ -z "$tags_str" ]; then
    log_error "Usage: $0 tag --ami-id <ami-id> --tags Key=Value,Key2=Value2"
    exit 1
  fi

  log_info "Tagging AMI $ami_id"

  # Parse comma-separated Key=Value pairs
  local tag_args=()
  IFS=',' read -ra tag_pairs <<< "$tags_str"
  for pair in "${tag_pairs[@]}"; do
    local key="${pair%%=*}"
    local value="${pair#*=}"
    tag_args+=("Key=$key,Value=$value")
  done

  aws ec2 create-tags \
    --region "$region" \
    --resources "$ami_id" \
    --tags "${tag_args[@]}"

  log_info "Tagged ✅"
}

cmd_list() {
  local prefix="$1"
  local region="${2:-$AWS_REGION}"

  require_cmd aws

  log_info "AMIs matching '$prefix*' in $region:"
  aws ec2 describe-images \
    --region "$region" \
    --owners self \
    --filters "Name=name,Values=${prefix}*" \
    --query 'sort_by(Images, &CreationDate)[*].[ImageId,Name,CreationDate,State]' \
    --output table
}

# --- Argument parsing ---
COMMAND="${1:-}"
[ -z "$COMMAND" ] && { echo "Usage: $0 {build|validate|cleanup|register|tag|list} [options]"; exit 1; }
shift

AMI_PREFIX=""
KEEP_COUNT=""
AMI_ID=""
TAGS=""
HCP_BUCKET=""
HCP_CHANNEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --var-file)     VAR_FILE="$2"; shift 2 ;;
    --only)         ONLY_SOURCE="$2"; shift 2 ;;
    --debug)        DEBUG=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --prefix)       AMI_PREFIX="$2"; shift 2 ;;
    --keep)         KEEP_COUNT="$2"; shift 2 ;;
    --region)       AWS_REGION="$2"; shift 2 ;;
    --ami-id)       AMI_ID="$2"; shift 2 ;;
    --tags)         TAGS="$2"; shift 2 ;;
    --manifest)     MANIFEST_FILE="$2"; shift 2 ;;
    --bucket)       HCP_BUCKET="$2"; shift 2 ;;
    --channel)      HCP_CHANNEL="$2"; shift 2 ;;
    *)              log_error "Unknown option: $1"; exit 1 ;;
  esac
done

case "$COMMAND" in
  validate)  cmd_validate ;;
  build)     cmd_build ;;
  cleanup)   cmd_cleanup "$AMI_PREFIX" "$KEEP_COUNT" "$AWS_REGION" ;;
  register)  cmd_register "$MANIFEST_FILE" "$HCP_BUCKET" "$HCP_CHANNEL" ;;
  tag)       cmd_tag "$AMI_ID" "$TAGS" ;;
  list)      cmd_list "$AMI_PREFIX" "$AWS_REGION" ;;
  *)         log_error "Unknown command: $COMMAND"; exit 1 ;;
esac
