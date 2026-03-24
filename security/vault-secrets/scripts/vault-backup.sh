#!/usr/bin/env bash
#
# vault-backup.sh — Backs up Vault Raft snapshots with rotation
#
# Usage:
#   ./vault-backup.sh                          # Backup to default dir with 7-day retention
#   ./vault-backup.sh --dir /backups/vault     # Custom backup directory
#   ./vault-backup.sh --retain 30              # Keep 30 days of backups
#   ./vault-backup.sh --s3 s3://bucket/vault   # Upload to S3 after local backup
#
# Prerequisites:
#   - vault CLI installed and configured (VAULT_ADDR, VAULT_TOKEN)
#   - Token must have sys/storage/raft/snapshot read capability
#   - aws CLI installed if using --s3 option
#
# This script:
#   1. Takes a Raft snapshot of the Vault cluster
#   2. Verifies snapshot integrity
#   3. Compresses the snapshot
#   4. Optionally uploads to S3
#   5. Rotates old backups based on retention policy
#   6. Logs all operations
#
# Recommended: Run via cron every 6 hours
#   0 */6 * * * /opt/vault/scripts/vault-backup.sh --dir /backups/vault --retain 14 2>&1 | logger -t vault-backup

set -euo pipefail

# --- Defaults ---
BACKUP_DIR="/opt/vault/backups"
RETAIN_DAYS=7
S3_DEST=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HOSTNAME_TAG=$(hostname -s)
SNAPSHOT_FILE="vault-snapshot-${HOSTNAME_TAG}-${TIMESTAMP}.snap"
LOG_FILE="/var/log/vault-backup.log"

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      BACKUP_DIR="$2"
      shift 2
      ;;
    --retain)
      RETAIN_DAYS="$2"
      shift 2
      ;;
    --s3)
      S3_DEST="$2"
      shift 2
      ;;
    --help|-h)
      head -22 "$0" | tail -20
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- Helpers ---
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

err() {
  log "ERROR: $1"
  exit 1
}

cleanup() {
  rm -f "${BACKUP_DIR}/${SNAPSHOT_FILE}" 2>/dev/null || true
}

# --- Preflight Checks ---
command -v vault >/dev/null 2>&1 || err "vault CLI not found"
[[ -n "${VAULT_ADDR:-}" ]] || err "VAULT_ADDR not set"
[[ -n "${VAULT_TOKEN:-}" ]] || err "VAULT_TOKEN not set"

vault status &>/dev/null || err "Cannot connect to Vault at ${VAULT_ADDR}"

SEALED=$(vault status -format=json | jq -r '.sealed')
[[ "$SEALED" == "false" ]] || err "Vault is sealed — cannot take snapshot"

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/vault-backup.log"

# --- Take Snapshot ---
log "Starting Vault Raft snapshot..."
log "Backup directory: ${BACKUP_DIR}"
log "Retention: ${RETAIN_DAYS} days"

SNAP_PATH="${BACKUP_DIR}/${SNAPSHOT_FILE}"

if ! vault operator raft snapshot save "$SNAP_PATH" 2>&1; then
  err "Failed to take Raft snapshot"
fi

# --- Verify Snapshot ---
SNAP_SIZE=$(stat -c%s "$SNAP_PATH" 2>/dev/null || stat -f%z "$SNAP_PATH" 2>/dev/null)
if [[ "$SNAP_SIZE" -lt 100 ]]; then
  err "Snapshot file is suspiciously small (${SNAP_SIZE} bytes)"
fi
log "Snapshot created: ${SNAPSHOT_FILE} (${SNAP_SIZE} bytes)"

# --- Compress ---
log "Compressing snapshot..."
gzip -f "$SNAP_PATH"
COMPRESSED_FILE="${SNAP_PATH}.gz"
COMPRESSED_SIZE=$(stat -c%s "$COMPRESSED_FILE" 2>/dev/null || stat -f%z "$COMPRESSED_FILE" 2>/dev/null)
log "Compressed: ${SNAPSHOT_FILE}.gz (${COMPRESSED_SIZE} bytes)"

# --- Generate Checksum ---
sha256sum "$COMPRESSED_FILE" > "${COMPRESSED_FILE}.sha256"
log "Checksum: ${SNAPSHOT_FILE}.gz.sha256"

# --- Upload to S3 (optional) ---
if [[ -n "$S3_DEST" ]]; then
  command -v aws >/dev/null 2>&1 || err "aws CLI not found but --s3 specified"
  log "Uploading to ${S3_DEST}..."
  aws s3 cp "$COMPRESSED_FILE" "${S3_DEST}/${SNAPSHOT_FILE}.gz" --quiet
  aws s3 cp "${COMPRESSED_FILE}.sha256" "${S3_DEST}/${SNAPSHOT_FILE}.gz.sha256" --quiet
  log "S3 upload complete"
fi

# --- Rotate Old Backups ---
log "Rotating backups older than ${RETAIN_DAYS} days..."
DELETED_COUNT=0
while IFS= read -r -d '' old_file; do
  rm -f "$old_file"
  rm -f "${old_file}.sha256" 2>/dev/null || true
  DELETED_COUNT=$((DELETED_COUNT + 1))
done < <(find "$BACKUP_DIR" -name "vault-snapshot-*.snap.gz" -mtime +"$RETAIN_DAYS" -print0 2>/dev/null)

log "Rotated ${DELETED_COUNT} old backup(s)"

# --- S3 Rotation (optional) ---
if [[ -n "$S3_DEST" ]]; then
  CUTOFF_DATE=$(date -d "-${RETAIN_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-${RETAIN_DAYS}d +%Y-%m-%d)
  log "S3 retention: removing objects older than ${CUTOFF_DATE}"
  aws s3 ls "${S3_DEST}/" 2>/dev/null | while read -r line; do
    FILE_DATE=$(echo "$line" | awk '{print $1}')
    FILE_NAME=$(echo "$line" | awk '{print $4}')
    if [[ -n "$FILE_NAME" && "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
      aws s3 rm "${S3_DEST}/${FILE_NAME}" --quiet 2>/dev/null || true
    fi
  done
fi

# --- Summary ---
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "vault-snapshot-*.snap.gz" 2>/dev/null | wc -l)
log "Backup complete. ${BACKUP_COUNT} snapshot(s) in ${BACKUP_DIR}"
log "Latest: ${SNAPSHOT_FILE}.gz (${COMPRESSED_SIZE} bytes)"
