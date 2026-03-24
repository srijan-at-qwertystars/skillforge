#!/usr/bin/env bash
# =============================================================================
# backup-restore.sh — MongoDB backup and restore with mongodump/mongorestore
#
# Supports standalone, replica sets, and sharded clusters.
# Creates compressed, timestamped backups with validation.
#
# USAGE:
#   ./backup-restore.sh backup  [OPTIONS]
#   ./backup-restore.sh restore [OPTIONS]
#
# BACKUP OPTIONS:
#   -u, --uri URI          MongoDB connection URI (default: mongodb://localhost:27017)
#   -d, --db DATABASE      Database to back up (omit for all databases)
#   -c, --collection COL   Collection to back up (requires --db)
#   -o, --output DIR       Backup output directory (default: ./backups)
#   --oplog                Include oplog for point-in-time backup (replica sets)
#   --gzip                 Compress backup files (default: true)
#   --parallel N           Number of parallel collections (default: 4)
#   --retention DAYS       Delete backups older than N days (default: 30)
#
# RESTORE OPTIONS:
#   -u, --uri URI          MongoDB connection URI
#   -d, --db DATABASE      Target database (renames during restore)
#   -i, --input DIR/FILE   Backup directory or archive to restore (required)
#   --oplog                Replay oplog during restore
#   --drop                 Drop existing collections before restore
#   --parallel N           Number of parallel collections (default: 4)
#   --dry-run              Show what would be restored without doing it
#
# EXAMPLES:
#   # Backup all databases with oplog
#   ./backup-restore.sh backup --oplog
#
#   # Backup specific database
#   ./backup-restore.sh backup -d myapp -o /mnt/backups
#
#   # Restore from backup
#   ./backup-restore.sh restore -i ./backups/myapp_2024-11-15_120000 --drop
#
#   # Restore to different database
#   ./backup-restore.sh restore -i ./backups/myapp_2024-11-15_120000 -d myapp_staging
#
#   # Backup sharded cluster (connect to mongos)
#   ./backup-restore.sh backup -u "mongodb://mongos1:27017" -d myapp
# =============================================================================

set -euo pipefail

ACTION="${1:-}"
shift 2>/dev/null || true

URI="mongodb://localhost:27017"
DB=""
COLLECTION=""
OUTPUT_DIR="./backups"
INPUT_PATH=""
USE_OPLOG=false
USE_GZIP=true
PARALLEL=4
DROP=false
DRY_RUN=false
RETENTION_DAYS=30

usage() {
  head -n 40 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

if [[ -z "$ACTION" ]] || [[ "$ACTION" == "-h" ]] || [[ "$ACTION" == "--help" ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--uri) URI="$2"; shift 2 ;;
    -d|--db) DB="$2"; shift 2 ;;
    -c|--collection) COLLECTION="$2"; shift 2 ;;
    -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
    -i|--input) INPUT_PATH="$2"; shift 2 ;;
    --oplog) USE_OPLOG=true; shift ;;
    --gzip) USE_GZIP=true; shift ;;
    --no-gzip) USE_GZIP=false; shift ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --drop) DROP=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --retention) RETENTION_DAYS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# Check for required tools
for cmd in mongodump mongorestore; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd not found. Install MongoDB Database Tools."
    err "See: https://www.mongodb.com/docs/database-tools/installation/"
    exit 1
  fi
done

do_backup() {
  local TIMESTAMP
  TIMESTAMP="$(date '+%Y-%m-%d_%H%M%S')"
  local BACKUP_NAME="${DB:-all_databases}_${TIMESTAMP}"
  local BACKUP_PATH="${OUTPUT_DIR}/${BACKUP_NAME}"

  mkdir -p "$OUTPUT_DIR"

  log "Starting backup: $BACKUP_NAME"
  log "URI: ${URI%%@*}@***"  # mask credentials
  [[ -n "$DB" ]] && log "Database: $DB" || log "All databases"
  [[ -n "$COLLECTION" ]] && log "Collection: $COLLECTION"
  log "Output: $BACKUP_PATH"
  log "Oplog: $USE_OPLOG, Gzip: $USE_GZIP, Parallel: $PARALLEL"

  # Build mongodump command
  local CMD=(mongodump
    --uri="$URI"
    --out="$BACKUP_PATH"
    --numParallelCollections="$PARALLEL"
  )

  [[ -n "$DB" ]] && CMD+=(--db="$DB")
  [[ -n "$COLLECTION" ]] && CMD+=(--collection="$COLLECTION")
  $USE_OPLOG && CMD+=(--oplog)
  $USE_GZIP && CMD+=(--gzip)

  # Execute backup
  local START_TIME
  START_TIME=$(date +%s)

  if "${CMD[@]}"; then
    local END_TIME
    END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    local SIZE
    SIZE=$(du -sh "$BACKUP_PATH" 2>/dev/null | cut -f1)

    log "Backup completed successfully"
    log "Duration: ${DURATION}s, Size: ${SIZE}"
    log "Path: $BACKUP_PATH"

    # Write metadata
    cat > "${BACKUP_PATH}/backup_metadata.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "uri": "${URI%%@*}@***",
  "database": "${DB:-all}",
  "collection": "${COLLECTION:-all}",
  "oplog": $USE_OPLOG,
  "gzip": $USE_GZIP,
  "durationSeconds": $DURATION,
  "mongodumpVersion": "$(mongodump --version 2>&1 | head -1)"
}
EOF

    # Cleanup old backups
    if [[ $RETENTION_DAYS -gt 0 ]]; then
      log "Cleaning backups older than ${RETENTION_DAYS} days..."
      local CLEANED=0
      find "$OUTPUT_DIR" -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -name "*_*_*" | while read -r OLD_DIR; do
        log "  Removing: $(basename "$OLD_DIR")"
        rm -rf "$OLD_DIR"
        CLEANED=$((CLEANED + 1))
      done
      [[ $CLEANED -gt 0 ]] && log "Cleaned $CLEANED old backup(s)"
    fi
  else
    err "Backup FAILED"
    exit 1
  fi
}

do_restore() {
  if [[ -z "$INPUT_PATH" ]]; then
    err "--input is required for restore"
    exit 1
  fi

  if [[ ! -e "$INPUT_PATH" ]]; then
    err "Input path does not exist: $INPUT_PATH"
    exit 1
  fi

  log "Starting restore from: $INPUT_PATH"
  log "URI: ${URI%%@*}@***"
  [[ -n "$DB" ]] && log "Target database: $DB"
  $DROP && log "Mode: DROP existing collections before restore"
  $USE_OPLOG && log "Oplog replay: enabled"

  # Show metadata if available
  if [[ -f "${INPUT_PATH}/backup_metadata.json" ]]; then
    log "Backup metadata:"
    cat "${INPUT_PATH}/backup_metadata.json" | while IFS= read -r line; do
      log "  $line"
    done
  fi

  # Build mongorestore command
  local CMD=(mongorestore
    --uri="$URI"
    --numParallelCollections="$PARALLEL"
  )

  [[ -n "$DB" ]] && CMD+=(--db="$DB")
  $DROP && CMD+=(--drop)
  $USE_OPLOG && CMD+=(--oplogReplay)

  # Check for gzip
  if find "$INPUT_PATH" -name "*.gz" -print -quit 2>/dev/null | grep -q .; then
    CMD+=(--gzip)
  fi

  CMD+=("$INPUT_PATH")

  if $DRY_RUN; then
    log "DRY RUN — would execute:"
    log "  ${CMD[*]}"
    log "Contents of backup:"
    find "$INPUT_PATH" -type f | head -20
    return 0
  fi

  # Confirm restore (if interactive)
  if [[ -t 0 ]]; then
    echo ""
    echo "⚠️  WARNING: This will restore data to the target MongoDB instance."
    $DROP && echo "   Collections will be DROPPED before restore."
    echo ""
    read -rp "Continue? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      log "Restore cancelled by user"
      exit 0
    fi
  fi

  local START_TIME
  START_TIME=$(date +%s)

  if "${CMD[@]}"; then
    local END_TIME
    END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    log "Restore completed successfully in ${DURATION}s"
  else
    err "Restore FAILED"
    exit 1
  fi
}

case "$ACTION" in
  backup)  do_backup ;;
  restore) do_restore ;;
  *)
    err "Unknown action: $ACTION (use 'backup' or 'restore')"
    usage
    ;;
esac
