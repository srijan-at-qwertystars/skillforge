#!/usr/bin/env bash
#
# consul-backup.sh — Creates Consul snapshots with rotation and optional S3 upload.
#
# Usage:
#   ./consul-backup.sh                              # Snapshot to default directory
#   ./consul-backup.sh -d /backups/consul            # Custom backup directory
#   ./consul-backup.sh -r 30                         # Keep last 30 snapshots
#   ./consul-backup.sh -s s3://my-bucket/consul/     # Upload to S3
#   ./consul-backup.sh -d /backups -r 14 -s s3://bucket/consul/ -t my-acl-token
#
# Options:
#   -d DIR      Backup directory (default: /opt/consul/snapshots)
#   -r COUNT    Number of snapshots to retain locally (default: 7)
#   -s S3_URI   S3 URI for remote upload (requires aws CLI)
#   -t TOKEN    Consul ACL token (or set CONSUL_HTTP_TOKEN env var)
#   -a ADDR     Consul HTTP address (default: http://127.0.0.1:8500)
#   -v          Verbose output
#   -h          Show help
#
# Prerequisites:
#   - consul binary in PATH
#   - aws CLI in PATH (if using S3 upload)
#   - Appropriate ACL token with operator:read permissions
#
# Recommended cron:
#   0 */6 * * * /usr/local/bin/consul-backup.sh -d /backups/consul -r 28 -s s3://bucket/consul/ 2>&1 | logger -t consul-backup

set -euo pipefail

# Defaults
BACKUP_DIR="/opt/consul/snapshots"
RETAIN_COUNT=7
S3_URI=""
CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
TOKEN="${CONSUL_HTTP_TOKEN:-}"
VERBOSE=false
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME_SHORT=$(hostname -s)
SNAP_NAME="consul-${HOSTNAME_SHORT}-${TIMESTAMP}.snap"

usage() {
  echo "Usage: $0 [-d DIR] [-r COUNT] [-s S3_URI] [-t TOKEN] [-a ADDR] [-v] [-h]"
  echo ""
  echo "Options:"
  echo "  -d DIR      Backup directory (default: /opt/consul/snapshots)"
  echo "  -r COUNT    Snapshots to retain locally (default: 7)"
  echo "  -s S3_URI   S3 URI for upload (e.g., s3://bucket/prefix/)"
  echo "  -t TOKEN    Consul ACL token"
  echo "  -a ADDR     Consul HTTP address (default: http://127.0.0.1:8500)"
  echo "  -v          Verbose output"
  echo "  -h          Show help"
  exit 0
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    log "$@"
  fi
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

while getopts "d:r:s:t:a:vh" opt; do
  case "$opt" in
    d) BACKUP_DIR="$OPTARG" ;;
    r) RETAIN_COUNT="$OPTARG" ;;
    s) S3_URI="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    a) CONSUL_ADDR="$OPTARG" ;;
    v) VERBOSE=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# Validate
command -v consul &>/dev/null || die "'consul' not found in PATH"
[[ "$RETAIN_COUNT" -gt 0 ]] || die "Retain count must be > 0"

if [[ -n "$S3_URI" ]]; then
  command -v aws &>/dev/null || die "'aws' CLI not found (required for S3 upload)"
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

SNAP_PATH="${BACKUP_DIR}/${SNAP_NAME}"

# Build consul command
CONSUL_OPTS=(-http-addr="$CONSUL_ADDR")
if [[ -n "$TOKEN" ]]; then
  CONSUL_OPTS+=(-token="$TOKEN")
fi

# Take snapshot
log "Taking Consul snapshot..."
log_verbose "  Address: $CONSUL_ADDR"
log_verbose "  Output:  $SNAP_PATH"

if ! consul snapshot save "${CONSUL_OPTS[@]}" "$SNAP_PATH"; then
  die "Snapshot save failed"
fi

# Verify snapshot
log_verbose "Verifying snapshot integrity..."
if ! consul snapshot inspect "$SNAP_PATH" > /dev/null 2>&1; then
  die "Snapshot verification failed: $SNAP_PATH"
fi

SNAP_SIZE=$(stat -c%s "$SNAP_PATH" 2>/dev/null || stat -f%z "$SNAP_PATH" 2>/dev/null)
log "Snapshot saved: ${SNAP_NAME} ($(numfmt --to=iec "$SNAP_SIZE" 2>/dev/null || echo "${SNAP_SIZE} bytes"))"

# Inspect snapshot details
if [[ "$VERBOSE" == "true" ]]; then
  consul snapshot inspect "$SNAP_PATH"
fi

# Upload to S3
if [[ -n "$S3_URI" ]]; then
  log "Uploading snapshot to S3..."
  S3_DEST="${S3_URI%/}/${SNAP_NAME}"
  log_verbose "  Destination: $S3_DEST"

  if aws s3 cp "$SNAP_PATH" "$S3_DEST" \
    --sse AES256 \
    --only-show-errors; then
    log "S3 upload complete: $S3_DEST"
  else
    log "WARNING: S3 upload failed (local backup retained)"
  fi
fi

# Rotate old snapshots
log_verbose "Rotating local snapshots (keeping last ${RETAIN_COUNT})..."
SNAP_COUNT=$(find "$BACKUP_DIR" -name "consul-*.snap" -type f | wc -l)
if [[ "$SNAP_COUNT" -gt "$RETAIN_COUNT" ]]; then
  REMOVE_COUNT=$((SNAP_COUNT - RETAIN_COUNT))
  find "$BACKUP_DIR" -name "consul-*.snap" -type f -printf '%T+ %p\n' \
    | sort \
    | head -n "$REMOVE_COUNT" \
    | awk '{print $2}' \
    | while read -r old_snap; do
        log_verbose "  Removing: $(basename "$old_snap")"
        rm -f "$old_snap"
      done
  log "Rotated: removed ${REMOVE_COUNT} old snapshot(s)"
else
  log_verbose "No rotation needed (${SNAP_COUNT}/${RETAIN_COUNT} snapshots)"
fi

log "Backup complete."
