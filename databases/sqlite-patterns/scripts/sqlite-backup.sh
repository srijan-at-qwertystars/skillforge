#!/usr/bin/env bash
# sqlite-backup.sh — Safe online backup for SQLite databases
# Usage: sqlite-backup.sh <source_db> <backup_path> [--verify] [--compress]
set -euo pipefail

usage() {
    echo "Usage: $0 <source_db> <backup_path> [options]"
    echo ""
    echo "Perform a safe online backup of a SQLite database using the .backup command."
    echo "The source database can be actively used during backup."
    echo ""
    echo "Options:"
    echo "  --verify     Run integrity check on the backup after completion"
    echo "  --compress   Compress the backup with gzip after completion"
    echo "  --timestamp  Append a timestamp to the backup filename"
    echo "  --quiet      Suppress progress output"
    echo ""
    echo "Examples:"
    echo "  $0 app.db /backups/app.db --verify"
    echo "  $0 app.db /backups/app.db --verify --compress --timestamp"
    exit 1
}

if [[ $# -lt 2 ]]; then
    usage
fi

SOURCE_DB="$1"
BACKUP_PATH="$2"
shift 2

DO_VERIFY=false
DO_COMPRESS=false
DO_TIMESTAMP=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify)    DO_VERIFY=true ;;
        --compress)  DO_COMPRESS=true ;;
        --timestamp) DO_TIMESTAMP=true ;;
        --quiet)     QUIET=true ;;
        -h|--help)   usage ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

SQLITE3="${SQLITE3_BIN:-sqlite3}"
if ! command -v "$SQLITE3" &>/dev/null; then
    echo "ERROR: sqlite3 not found. Install SQLite or set SQLITE3_BIN."
    exit 1
fi

if [[ ! -f "$SOURCE_DB" ]]; then
    echo "ERROR: Source database not found: $SOURCE_DB"
    exit 1
fi

# Append timestamp if requested
if $DO_TIMESTAMP; then
    TIMESTAMP=$(date -u '+%Y%m%d_%H%M%S')
    DIR=$(dirname "$BACKUP_PATH")
    BASE=$(basename "$BACKUP_PATH" .db)
    BACKUP_PATH="${DIR}/${BASE}_${TIMESTAMP}.db"
fi

# Create backup directory if needed
BACKUP_DIR=$(dirname "$BACKUP_PATH")
mkdir -p "$BACKUP_DIR"

# Prevent overwriting source
REAL_SOURCE=$(realpath "$SOURCE_DB" 2>/dev/null || readlink -f "$SOURCE_DB")
REAL_BACKUP=$(realpath "$BACKUP_PATH" 2>/dev/null || echo "$BACKUP_PATH")
if [[ "$REAL_SOURCE" == "$REAL_BACKUP" ]]; then
    echo "ERROR: Backup path is the same as source. Choose a different path."
    exit 1
fi

log() {
    if ! $QUIET; then
        echo "$@"
    fi
}

log "SQLite Backup"
log "  Source:  $SOURCE_DB ($(du -h "$SOURCE_DB" | cut -f1))"
log "  Backup:  $BACKUP_PATH"
log ""

# Perform the backup using sqlite3 .backup command
# This is safe during concurrent access and uses the SQLite backup API internally
log "Starting backup..."
START_TIME=$(date +%s)

"$SQLITE3" "$SOURCE_DB" ".backup '$BACKUP_PATH'"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [[ ! -f "$BACKUP_PATH" ]]; then
    echo "ERROR: Backup file was not created."
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
log "  Backup completed in ${ELAPSED}s (${BACKUP_SIZE})"

# Verify backup integrity
if $DO_VERIFY; then
    log ""
    log "Verifying backup integrity..."
    INTEGRITY=$("$SQLITE3" "$BACKUP_PATH" "PRAGMA integrity_check;")
    if [[ "$INTEGRITY" == "ok" ]]; then
        log "  ✅ Integrity check: PASSED"
    else
        echo "  ❌ Integrity check: FAILED"
        echo "$INTEGRITY"
        rm -f "$BACKUP_PATH"
        echo "ERROR: Corrupt backup removed. Check source database."
        exit 1
    fi

    # Compare table counts between source and backup
    log "  Comparing table row counts..."
    TABLES=$("$SQLITE3" "$SOURCE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
    MISMATCH=false
    for TABLE in $TABLES; do
        SRC_COUNT=$("$SQLITE3" "$SOURCE_DB" "SELECT count(*) FROM \"$TABLE\";" 2>/dev/null || echo "error")
        BAK_COUNT=$("$SQLITE3" "$BACKUP_PATH" "SELECT count(*) FROM \"$TABLE\";" 2>/dev/null || echo "error")
        if [[ "$SRC_COUNT" != "$BAK_COUNT" ]]; then
            echo "  ⚠  Row count mismatch in $TABLE: source=$SRC_COUNT backup=$BAK_COUNT"
            MISMATCH=true
        fi
    done
    if ! $MISMATCH; then
        log "  ✅ Row counts match across all tables"
    else
        echo "  ⚠  Some row counts differ (may be due to concurrent writes during backup)"
    fi
fi

# Compress if requested
if $DO_COMPRESS; then
    log ""
    log "Compressing backup..."
    gzip -f "$BACKUP_PATH"
    BACKUP_PATH="${BACKUP_PATH}.gz"
    COMPRESSED_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
    log "  Compressed: ${COMPRESSED_SIZE}"
fi

log ""
log "── Backup Complete ────────────────────────────────────────"
log "  Output: $BACKUP_PATH"
log "  Size:   $(du -h "$BACKUP_PATH" | cut -f1)"
log "  Time:   ${ELAPSED}s"
