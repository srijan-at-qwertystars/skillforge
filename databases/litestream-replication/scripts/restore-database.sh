#!/usr/bin/env bash
# restore-database.sh — Restore a Litestream-replicated SQLite database.
# Stops the application, restores to a point-in-time or latest, verifies, restarts.
set -euo pipefail

###############################################################################
# Configuration (override via environment variables)
###############################################################################
DB_PATH="${DB_PATH:-/data/app.db}"
REPLICA_URL="${REPLICA_URL:?REPLICA_URL is required (e.g., s3://my-bucket/app)}"
APP_SERVICE="${APP_SERVICE:-myapp}"
LITESTREAM_SERVICE="${LITESTREAM_SERVICE:-litestream}"
RESTORE_TIMESTAMP="${RESTORE_TIMESTAMP:-}"          # Empty = latest
RESTORE_GENERATION="${RESTORE_GENERATION:-}"        # Empty = auto-select
BACKUP_BEFORE_RESTORE="${BACKUP_BEFORE_RESTORE:-true}"
CONFIG_PATH="${CONFIG_PATH:-/etc/litestream.yml}"

###############################################################################
# Helpers
###############################################################################
log()  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [restore] $*"; }
warn() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [restore] WARNING: $*" >&2; }
die()  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [restore] ERROR: $*" >&2; exit 1; }

###############################################################################
# Pre-flight checks
###############################################################################
preflight() {
  log "Running pre-flight checks..."

  if ! command -v litestream &>/dev/null; then
    die "litestream not found in PATH"
  fi

  if ! command -v sqlite3 &>/dev/null; then
    die "sqlite3 not found in PATH"
  fi

  log "Listing available restore points..."
  litestream generations "$REPLICA_URL" 2>/dev/null || warn "Could not list generations"
  litestream snapshots "$REPLICA_URL" 2>/dev/null || warn "Could not list snapshots"
}

###############################################################################
# 1. Stop application and Litestream
###############################################################################
stop_services() {
  log "Stopping services..."

  # Try systemctl first, then docker, then generic process kill
  if command -v systemctl &>/dev/null; then
    systemctl stop "$APP_SERVICE" 2>/dev/null && log "Stopped $APP_SERVICE (systemd)" || true
    systemctl stop "$LITESTREAM_SERVICE" 2>/dev/null && log "Stopped $LITESTREAM_SERVICE (systemd)" || true
  elif command -v docker &>/dev/null; then
    docker stop "$APP_SERVICE" 2>/dev/null && log "Stopped $APP_SERVICE (docker)" || true
    docker stop "$LITESTREAM_SERVICE" 2>/dev/null && log "Stopped $LITESTREAM_SERVICE (docker)" || true
  fi

  # Ensure no litestream process is running
  if pgrep -x litestream &>/dev/null; then
    log "Sending SIGTERM to remaining litestream processes..."
    pkill -TERM -x litestream 2>/dev/null || true
    sleep 3
    if pgrep -x litestream &>/dev/null; then
      warn "Litestream still running after SIGTERM"
    fi
  fi

  log "Services stopped"
}

###############################################################################
# 2. Back up current database (safety net)
###############################################################################
backup_current() {
  if [ "$BACKUP_BEFORE_RESTORE" != "true" ]; then
    log "Skipping pre-restore backup (BACKUP_BEFORE_RESTORE=false)"
    return 0
  fi

  if [ ! -f "$DB_PATH" ]; then
    log "No existing database to back up"
    return 0
  fi

  BACKUP_DIR="$(dirname "$DB_PATH")/pre-restore-backups"
  TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
  BACKUP_PATH="${BACKUP_DIR}/$(basename "$DB_PATH").${TIMESTAMP}.bak"

  mkdir -p "$BACKUP_DIR"
  cp "$DB_PATH" "$BACKUP_PATH"
  [ -f "${DB_PATH}-wal" ] && cp "${DB_PATH}-wal" "${BACKUP_PATH}-wal"
  [ -f "${DB_PATH}-shm" ] && cp "${DB_PATH}-shm" "${BACKUP_PATH}-shm"

  log "Current database backed up to: $BACKUP_PATH"
}

###############################################################################
# 3. Restore from replica
###############################################################################
restore_database() {
  log "Starting restore..."

  # Remove existing database files
  rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"

  # Build restore command
  RESTORE_CMD=(litestream restore)

  if [ -n "$RESTORE_TIMESTAMP" ]; then
    RESTORE_CMD+=(-timestamp "$RESTORE_TIMESTAMP")
    log "Restoring to timestamp: $RESTORE_TIMESTAMP"
  else
    log "Restoring to latest available point"
  fi

  if [ -n "$RESTORE_GENERATION" ]; then
    RESTORE_CMD+=(-generation "$RESTORE_GENERATION")
    log "Using generation: $RESTORE_GENERATION"
  fi

  RESTORE_CMD+=(-o "$DB_PATH" "$REPLICA_URL")

  RESTORE_START=$(date +%s)
  "${RESTORE_CMD[@]}"
  RESTORE_END=$(date +%s)
  RESTORE_DURATION=$(( RESTORE_END - RESTORE_START ))

  log "Restore completed in ${RESTORE_DURATION}s"
}

###############################################################################
# 4. Verify restored database
###############################################################################
verify_restore() {
  log "Verifying restored database..."

  # Check file exists
  if [ ! -f "$DB_PATH" ]; then
    die "Restored database file not found: $DB_PATH"
  fi

  DB_SIZE=$(stat -c %s "$DB_PATH" 2>/dev/null || stat -f %z "$DB_PATH")
  log "Database size: $(( DB_SIZE / 1048576 ))MB"

  # SQLite integrity check
  INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>&1)
  if [ "$INTEGRITY" != "ok" ]; then
    die "Integrity check failed: $INTEGRITY"
  fi
  log "✓ Integrity check passed"

  # Check journal mode
  JOURNAL=$(sqlite3 "$DB_PATH" "PRAGMA journal_mode;")
  log "Journal mode: $JOURNAL"
  if [ "$JOURNAL" != "wal" ]; then
    log "Setting WAL mode..."
    sqlite3 "$DB_PATH" "PRAGMA journal_mode=WAL;"
  fi
  log "✓ WAL mode set"

  # List tables and row counts
  log "Tables in restored database:"
  sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" | while read -r table; do
    COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM \"$table\";")
    log "  $table: $COUNT rows"
  done

  log "✓ Verification complete"
}

###############################################################################
# 5. Restart services
###############################################################################
restart_services() {
  log "Restarting services..."

  if command -v systemctl &>/dev/null; then
    systemctl start "$LITESTREAM_SERVICE" 2>/dev/null && log "Started $LITESTREAM_SERVICE (systemd)" || warn "Could not start $LITESTREAM_SERVICE"
    systemctl start "$APP_SERVICE" 2>/dev/null && log "Started $APP_SERVICE (systemd)" || warn "Could not start $APP_SERVICE"
  elif command -v docker &>/dev/null; then
    docker start "$LITESTREAM_SERVICE" 2>/dev/null && log "Started $LITESTREAM_SERVICE (docker)" || warn "Could not start $LITESTREAM_SERVICE"
    docker start "$APP_SERVICE" 2>/dev/null && log "Started $APP_SERVICE (docker)" || warn "Could not start $APP_SERVICE"
  else
    log "No service manager detected — start services manually"
    log "  litestream replicate -config $CONFIG_PATH &"
    log "  <start your application>"
  fi

  log "Services restarted"
}

###############################################################################
# Main
###############################################################################
main() {
  log "============================================"
  log "Litestream Database Restore"
  log "============================================"
  log "Database:    $DB_PATH"
  log "Replica:     $REPLICA_URL"
  log "Timestamp:   ${RESTORE_TIMESTAMP:-latest}"
  log "Generation:  ${RESTORE_GENERATION:-auto}"
  log "============================================"

  preflight
  stop_services
  backup_current
  restore_database
  verify_restore
  restart_services

  log "============================================"
  log "Restore complete!"
  log "============================================"
}

main "$@"
