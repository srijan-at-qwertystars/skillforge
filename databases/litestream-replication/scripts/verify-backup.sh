#!/usr/bin/env bash
# verify-backup.sh — Verify Litestream backup integrity.
# Restores to a temp location, runs integrity checks, compares generation counts.
set -euo pipefail

###############################################################################
# Configuration (override via environment variables)
###############################################################################
REPLICA_URL="${REPLICA_URL:?REPLICA_URL is required (e.g., s3://my-bucket/app)}"
LIVE_DB_PATH="${LIVE_DB_PATH:-}"                 # Optional: compare with live DB
CONFIG_PATH="${CONFIG_PATH:-/etc/litestream.yml}"
ALERT_EMAIL="${ALERT_EMAIL:-}"                   # Optional: email on failure
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"               # Optional: Slack/webhook on failure
LOG_FILE="${LOG_FILE:-/var/log/backup-verify.log}"
METRICS_FILE="${METRICS_FILE:-/var/log/backup-verify-metrics.csv}"

###############################################################################
# State
###############################################################################
TMPDIR=""
RESTORE_DB=""
ERRORS=0
WARNINGS=0
RESTORE_DURATION=0

###############################################################################
# Helpers
###############################################################################
log()  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [verify] $*" | tee -a "$LOG_FILE"; }
warn() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [verify] WARNING: $*" | tee -a "$LOG_FILE" >&2; WARNINGS=$(( WARNINGS + 1 )); }
fail() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [verify] FAIL: $*" | tee -a "$LOG_FILE" >&2; ERRORS=$(( ERRORS + 1 )); }

cleanup() {
  if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

send_alert() {
  local message="$1"

  if [ -n "$ALERT_EMAIL" ] && command -v mail &>/dev/null; then
    echo "$message" | mail -s "ALERT: Litestream Backup Verification Failed" "$ALERT_EMAIL"
  fi

  if [ -n "$ALERT_WEBHOOK" ] && command -v curl &>/dev/null; then
    curl -sf -X POST "$ALERT_WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$message\"}" &>/dev/null || true
  fi
}

###############################################################################
# 1. Restore to temp location
###############################################################################
restore_to_temp() {
  log "=== Step 1: Restore from replica ==="

  TMPDIR=$(mktemp -d)
  RESTORE_DB="${TMPDIR}/verify.db"

  log "Temp directory: $TMPDIR"
  log "Replica URL: $REPLICA_URL"

  RESTORE_START=$(date +%s)
  if ! litestream restore -o "$RESTORE_DB" "$REPLICA_URL" 2>>"$LOG_FILE"; then
    fail "Restore from replica failed"
    return 1
  fi
  RESTORE_END=$(date +%s)
  RESTORE_DURATION=$(( RESTORE_END - RESTORE_START ))

  if [ ! -f "$RESTORE_DB" ]; then
    fail "Restored database file not found"
    return 1
  fi

  DB_SIZE=$(stat -c %s "$RESTORE_DB" 2>/dev/null || stat -f %z "$RESTORE_DB")
  log "Restore completed in ${RESTORE_DURATION}s ($(( DB_SIZE / 1048576 ))MB)"
}

###############################################################################
# 2. Run integrity checks
###############################################################################
run_integrity_checks() {
  log "=== Step 2: Integrity checks ==="

  # SQLite integrity check
  INTEGRITY=$(sqlite3 "$RESTORE_DB" "PRAGMA integrity_check;" 2>&1)
  if [ "$INTEGRITY" = "ok" ]; then
    log "✓ PRAGMA integrity_check: ok"
  else
    fail "PRAGMA integrity_check: $INTEGRITY"
  fi

  # Foreign key check
  FK_ERRORS=$(sqlite3 "$RESTORE_DB" "PRAGMA foreign_key_check;" 2>&1)
  if [ -z "$FK_ERRORS" ]; then
    log "✓ PRAGMA foreign_key_check: no violations"
  else
    warn "Foreign key violations found: $FK_ERRORS"
  fi

  # Journal mode
  JOURNAL=$(sqlite3 "$RESTORE_DB" "PRAGMA journal_mode;" 2>&1)
  log "Journal mode: $JOURNAL"

  # Page counts
  PAGE_COUNT=$(sqlite3 "$RESTORE_DB" "PRAGMA page_count;")
  PAGE_SIZE=$(sqlite3 "$RESTORE_DB" "PRAGMA page_size;")
  FREELIST_COUNT=$(sqlite3 "$RESTORE_DB" "PRAGMA freelist_count;")
  log "Pages: $PAGE_COUNT (size: $PAGE_SIZE, freelist: $FREELIST_COUNT)"

  # Table enumeration
  TABLE_COUNT=$(sqlite3 "$RESTORE_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
  INDEX_COUNT=$(sqlite3 "$RESTORE_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='index';")
  log "Schema: $TABLE_COUNT tables, $INDEX_COUNT indexes"

  # Verify each table is readable
  log "Checking table readability..."
  sqlite3 "$RESTORE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" | while read -r table; do
    ROW_COUNT=$(sqlite3 "$RESTORE_DB" "SELECT COUNT(*) FROM \"$table\";" 2>&1)
    if echo "$ROW_COUNT" | grep -q "^[0-9]*$"; then
      log "  ✓ $table: $ROW_COUNT rows"
    else
      fail "  ✗ $table: read error: $ROW_COUNT"
    fi
  done
}

###############################################################################
# 3. Compare generation counts
###############################################################################
compare_generations() {
  log "=== Step 3: Generation analysis ==="

  # List generations
  GEN_OUTPUT=$(litestream generations "$REPLICA_URL" 2>/dev/null)
  if [ -z "$GEN_OUTPUT" ]; then
    warn "Could not retrieve generation information"
    return 0
  fi

  GEN_COUNT=$(echo "$GEN_OUTPUT" | tail -n +2 | wc -l)
  log "Active generations: $GEN_COUNT"
  log "$GEN_OUTPUT"

  # List snapshots
  SNAP_OUTPUT=$(litestream snapshots "$REPLICA_URL" 2>/dev/null)
  if [ -n "$SNAP_OUTPUT" ]; then
    SNAP_COUNT=$(echo "$SNAP_OUTPUT" | tail -n +2 | wc -l)
    log "Available snapshots: $SNAP_COUNT"
  fi

  # Warn if too many generations (suggests frequent restarts)
  if [ "$GEN_COUNT" -gt 10 ]; then
    warn "High generation count ($GEN_COUNT) — may indicate frequent Litestream restarts"
  fi
}

###############################################################################
# 4. Compare with live database (optional)
###############################################################################
compare_with_live() {
  if [ -z "$LIVE_DB_PATH" ] || [ ! -f "$LIVE_DB_PATH" ]; then
    log "=== Step 4: Live comparison (skipped — no LIVE_DB_PATH) ==="
    return 0
  fi

  log "=== Step 4: Comparing with live database ==="

  # Schema comparison
  LIVE_SCHEMA=$(sqlite3 "$LIVE_DB_PATH" ".schema" 2>/dev/null | sort)
  RESTORED_SCHEMA=$(sqlite3 "$RESTORE_DB" ".schema" 2>/dev/null | sort)

  if [ "$LIVE_SCHEMA" = "$RESTORED_SCHEMA" ]; then
    log "✓ Schemas match"
  else
    warn "Schema mismatch between live and restored database"
  fi

  # Row count comparison
  log "Row count comparison:"
  sqlite3 "$LIVE_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" | while read -r table; do
    LIVE_COUNT=$(sqlite3 "$LIVE_DB_PATH" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || echo "ERR")
    RESTORED_COUNT=$(sqlite3 "$RESTORE_DB" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || echo "ERR")

    if [ "$LIVE_COUNT" = "$RESTORED_COUNT" ]; then
      log "  ✓ $table: $LIVE_COUNT rows (match)"
    elif [ "$RESTORED_COUNT" = "ERR" ]; then
      fail "  ✗ $table: missing in restored database"
    else
      DIFF=$(( LIVE_COUNT - RESTORED_COUNT ))
      ABS_DIFF=${DIFF#-}
      if [ "$ABS_DIFF" -le 10 ]; then
        log "  ~ $table: live=$LIVE_COUNT restored=$RESTORED_COUNT (diff=$DIFF, within tolerance)"
      else
        warn "$table: live=$LIVE_COUNT restored=$RESTORED_COUNT (diff=$DIFF)"
      fi
    fi
  done
}

###############################################################################
# 5. Record metrics
###############################################################################
record_metrics() {
  log "=== Step 5: Recording metrics ==="

  # Initialize CSV if needed
  if [ ! -f "$METRICS_FILE" ]; then
    echo "timestamp,replica_url,db_size_bytes,restore_duration_s,integrity,errors,warnings" > "$METRICS_FILE"
  fi

  DB_SIZE=$(stat -c %s "$RESTORE_DB" 2>/dev/null || stat -f %z "$RESTORE_DB" 2>/dev/null || echo 0)
  INTEGRITY_STATUS="ok"
  [ "$ERRORS" -gt 0 ] && INTEGRITY_STATUS="failed"

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$REPLICA_URL,$DB_SIZE,$RESTORE_DURATION,$INTEGRITY_STATUS,$ERRORS,$WARNINGS" >> "$METRICS_FILE"
  log "Metrics appended to $METRICS_FILE"
}

###############################################################################
# 6. Report results
###############################################################################
report() {
  log "============================================"
  log "Backup Verification Summary"
  log "============================================"
  log "  Replica:          $REPLICA_URL"
  log "  Restore time:     ${RESTORE_DURATION}s"
  log "  Errors:           $ERRORS"
  log "  Warnings:         $WARNINGS"

  if [ "$ERRORS" -gt 0 ]; then
    log "  Result:           ✗ FAILED"
    log "============================================"
    send_alert "Litestream backup verification FAILED for $REPLICA_URL — $ERRORS error(s), $WARNINGS warning(s). Check $LOG_FILE for details."
    exit 1
  elif [ "$WARNINGS" -gt 0 ]; then
    log "  Result:           ⚠ PASSED with warnings"
    log "============================================"
    exit 0
  else
    log "  Result:           ✓ PASSED"
    log "============================================"
    exit 0
  fi
}

###############################################################################
# Main
###############################################################################
main() {
  log "============================================"
  log "Litestream Backup Verification"
  log "============================================"
  log "Replica: $REPLICA_URL"
  log "Live DB: ${LIVE_DB_PATH:-not configured}"
  log "============================================"

  restore_to_temp
  if [ "$ERRORS" -eq 0 ]; then
    run_integrity_checks
    compare_generations
    compare_with_live
  fi
  record_metrics
  report
}

main "$@"
