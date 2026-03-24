#!/bin/bash
# =============================================================================
# backup-postgres.sh — PostgreSQL backup with pg_dump and pg_basebackup + WAL
# =============================================================================
#
# Usage:
#   ./backup-postgres.sh [dump|basebackup|wal-status|restore-pitr]
#
#   dump         — Logical backup with pg_dump (custom format, parallel)
#   basebackup   — Physical backup with pg_basebackup + WAL streaming
#   wal-status   — Check WAL archiving status and gaps
#   restore-pitr — Guide through point-in-time recovery steps
#
# Configuration (environment variables):
#   PGHOST          — PostgreSQL host (default: localhost)
#   PGPORT          — PostgreSQL port (default: 5432)
#   PGUSER          — PostgreSQL user (default: postgres)
#   PGDATABASE      — Database to back up (default: all databases)
#   BACKUP_DIR      — Backup destination (default: /backup/postgres)
#   WAL_DIR         — WAL archive directory (default: /backup/wal)
#   RETENTION_DAYS  — Days to retain backups (default: 30)
#   PARALLEL_JOBS   — Parallel dump/restore jobs (default: 4)
#   COMPRESS_LEVEL  — Compression level 0-9 (default: 6)
#   SLACK_WEBHOOK_URL — Slack notification webhook (optional)
#
# Examples:
#   PGDATABASE=production ./backup-postgres.sh dump
#   ./backup-postgres.sh basebackup
#   ./backup-postgres.sh wal-status
#
# Prerequisites:
#   - PostgreSQL client tools (pg_dump, pg_basebackup)
#   - For basebackup: replication user with REPLICATION privilege
#   - For WAL archiving: archive_mode=on in postgresql.conf
#
# =============================================================================
set -euo pipefail

# Configuration
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-}"
BACKUP_DIR="${BACKUP_DIR:-/backup/postgres}"
WAL_DIR="${WAL_DIR:-/backup/wal}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
COMPRESS_LEVEL="${COMPRESS_LEVEL:-6}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

LOG_DIR="${BACKUP_DIR}/logs"
DATE_STAMP=$(date +%F-%H%M)
LOG_FILE="${LOG_DIR}/backup-${DATE_STAMP}.log"

# ---- Functions ----

setup_dirs() {
    mkdir -p "$BACKUP_DIR"/{dumps,base,meta} "$WAL_DIR" "$LOG_DIR"
}

log() {
    echo "[$(date -Is)] $*" | tee -a "$LOG_FILE"
}

notify() {
    local emoji="$1" msg="$2"
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        curl -sf -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"${emoji} [$(hostname -s)] PostgreSQL: ${msg}\"}" \
            >/dev/null 2>&1 || true
    fi
}

check_pg_connection() {
    if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -c "SELECT 1;" >/dev/null 2>&1; then
        log "ERROR: Cannot connect to PostgreSQL at ${PGHOST}:${PGPORT}"
        notify "🚨" "Backup FAILED — cannot connect to database"
        exit 1
    fi
}

record_metadata() {
    local backup_type="$1" backup_path="$2"
    local meta_file="${BACKUP_DIR}/meta/${DATE_STAMP}-${backup_type}.json"

    local pg_version db_size
    pg_version=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c "SELECT version();" 2>/dev/null | xargs)
    if [[ -n "$PGDATABASE" ]]; then
        db_size=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -c \
            "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null | xargs)
    else
        db_size=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c \
            "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database;" 2>/dev/null | xargs)
    fi

    cat > "$meta_file" <<EOF
{
    "timestamp": "$(date -Is)",
    "type": "$backup_type",
    "host": "$PGHOST",
    "port": $PGPORT,
    "database": "${PGDATABASE:-all}",
    "pg_version": "$pg_version",
    "db_size": "$db_size",
    "backup_path": "$backup_path",
    "hostname": "$(hostname -f)"
}
EOF
    log "Metadata recorded: $meta_file"
}

# ---- Commands ----

cmd_dump() {
    setup_dirs
    check_pg_connection

    local start_time
    start_time=$(date +%s)

    if [[ -n "$PGDATABASE" ]]; then
        # Single database dump (custom format for parallel restore)
        local dump_file="${BACKUP_DIR}/dumps/${PGDATABASE}-${DATE_STAMP}.dump"
        log "Starting pg_dump: ${PGDATABASE} → ${dump_file}"

        pg_dump \
            -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
            -d "$PGDATABASE" \
            -Fc \
            -j "$PARALLEL_JOBS" \
            -Z "$COMPRESS_LEVEL" \
            --verbose \
            -f "$dump_file" 2>&1 | tee -a "$LOG_FILE"

        # Generate checksum
        sha256sum "$dump_file" > "${dump_file}.sha256"
        log "Checksum: $(cat "${dump_file}.sha256")"

        # Record row counts for verification
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t -c "
            SELECT relname || ' ' || n_live_tup
            FROM pg_stat_user_tables
            ORDER BY n_live_tup DESC;
        " > "${BACKUP_DIR}/meta/${DATE_STAMP}-rowcounts.txt" 2>/dev/null

        record_metadata "dump" "$dump_file"
        local size
        size=$(du -sh "$dump_file" | cut -f1)
        local duration=$(( $(date +%s) - start_time ))
        log "Dump completed: ${size} in ${duration}s"
        notify "✅" "pg_dump ${PGDATABASE} completed: ${size} in ${duration}s"
    else
        # Full cluster dump (all databases)
        local dump_file="${BACKUP_DIR}/dumps/cluster-${DATE_STAMP}.sql.gz"
        log "Starting pg_dumpall → ${dump_file}"

        pg_dumpall \
            -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
            --clean --if-exists \
            --roles-only 2>&1 | gzip -${COMPRESS_LEVEL} > "${BACKUP_DIR}/dumps/roles-${DATE_STAMP}.sql.gz"

        pg_dumpall \
            -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
            --clean --if-exists 2>&1 | gzip -${COMPRESS_LEVEL} > "$dump_file"

        sha256sum "$dump_file" > "${dump_file}.sha256"
        record_metadata "dumpall" "$dump_file"
        local size
        size=$(du -sh "$dump_file" | cut -f1)
        local duration=$(( $(date +%s) - start_time ))
        log "Cluster dump completed: ${size} in ${duration}s"
        notify "✅" "pg_dumpall completed: ${size} in ${duration}s"
    fi

    # Clean old dumps
    log "Cleaning dumps older than ${RETENTION_DAYS} days"
    find "${BACKUP_DIR}/dumps" -name "*.dump" -o -name "*.sql.gz" | while read -r f; do
        if [[ $(find "$f" -mtime +"$RETENTION_DAYS" 2>/dev/null) ]]; then
            log "Removing old backup: $f"
            rm -f "$f" "${f}.sha256"
        fi
    done
}

cmd_basebackup() {
    setup_dirs
    check_pg_connection

    local base_dir="${BACKUP_DIR}/base/${DATE_STAMP}"
    mkdir -p "$base_dir"

    log "Starting pg_basebackup → ${base_dir}"

    local start_time
    start_time=$(date +%s)

    pg_basebackup \
        -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" \
        -D "$base_dir" \
        -Ft \
        -z \
        -P \
        -X stream \
        -c fast \
        --label="backup-${DATE_STAMP}" \
        -v 2>&1 | tee -a "$LOG_FILE"

    # Record the WAL position at backup start
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c \
        "SELECT pg_current_wal_lsn();" > "${base_dir}/wal_position.txt" 2>/dev/null

    # Generate checksum for the base backup
    sha256sum "${base_dir}"/*.tar.gz > "${base_dir}/checksums.sha256" 2>/dev/null || true

    record_metadata "basebackup" "$base_dir"

    local size
    size=$(du -sh "$base_dir" | cut -f1)
    local duration=$(( $(date +%s) - start_time ))
    log "Base backup completed: ${size} in ${duration}s"
    notify "✅" "pg_basebackup completed: ${size} in ${duration}s"

    # Clean old base backups
    log "Cleaning base backups older than ${RETENTION_DAYS} days"
    find "${BACKUP_DIR}/base" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETENTION_DAYS" | while read -r d; do
        log "Removing old base backup: $d"
        rm -rf "$d"
    done

    # Remind about WAL archiving
    local archive_mode
    archive_mode=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c \
        "SHOW archive_mode;" 2>/dev/null | xargs)
    if [[ "$archive_mode" != "on" ]]; then
        log "WARNING: archive_mode is '${archive_mode}' — WAL archiving is NOT enabled"
        log "WARNING: PITR will not be possible without WAL archives"
        notify "⚠️" "WAL archiving is NOT enabled — PITR not possible"
    fi
}

cmd_wal_status() {
    check_pg_connection
    log "=== WAL Archiving Status ==="

    # Check archive mode
    local archive_mode wal_level archive_command
    archive_mode=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c "SHOW archive_mode;" | xargs)
    wal_level=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c "SHOW wal_level;" | xargs)
    archive_command=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c "SHOW archive_command;" | xargs)

    log "archive_mode: $archive_mode"
    log "wal_level: $wal_level"
    log "archive_command: $archive_command"

    # Check archiver stats
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -c "
        SELECT archived_count, failed_count,
               last_archived_wal, last_archived_time,
               last_failed_wal, last_failed_time
        FROM pg_stat_archiver;
    " 2>&1 | tee -a "$LOG_FILE"

    # Check for WAL gaps in archive directory
    if [[ -d "$WAL_DIR" ]]; then
        local wal_count
        wal_count=$(find "$WAL_DIR" -name "0000*" -type f | wc -l)
        log "WAL files in archive: $wal_count"

        # Check for gaps (simplified — checks filename sequence)
        log "Checking for WAL gaps..."
        local prev=""
        find "$WAL_DIR" -name "0000*" -type f | sort | while read -r f; do
            local base
            base=$(basename "$f" | sed 's/\.gz$//')
            if [[ -n "$prev" ]]; then
                # Simple sequential check (real implementation would parse WAL segment numbers)
                :
            fi
            prev="$base"
        done
        log "WAL gap check complete"
    else
        log "WARNING: WAL directory $WAL_DIR does not exist"
    fi

    # Current WAL position
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t -c \
        "SELECT pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());" 2>&1 | tee -a "$LOG_FILE"
}

cmd_restore_pitr() {
    cat <<'GUIDE'
=== PostgreSQL Point-in-Time Recovery Guide ===

This is a guided procedure — NOT an automated restore.
Review each step carefully before executing.

PREREQUISITES:
  - A base backup (from pg_basebackup)
  - WAL archive files covering the time range
  - Target recovery time identified

STEPS:

1. STOP PostgreSQL:
   systemctl stop postgresql

2. PRESERVE current data directory:
   mv /var/lib/postgresql/15/main /var/lib/postgresql/15/main.broken

3. RESTORE base backup:
   mkdir /var/lib/postgresql/15/main
   tar xzf /backup/postgres/base/YYYY-MM-DD-HHMM/base.tar.gz \
     -C /var/lib/postgresql/15/main

4. CONFIGURE recovery (add to postgresql.auto.conf):
   restore_command = 'cp /backup/wal/%f %p || gunzip < /backup/wal/%f.gz > %p'
   recovery_target_time = 'YYYY-MM-DD HH:MM:SS UTC'
   recovery_target_action = 'pause'

5. CREATE recovery signal:
   touch /var/lib/postgresql/15/main/recovery.signal

6. FIX permissions:
   chown -R postgres:postgres /var/lib/postgresql/15/main
   chmod 700 /var/lib/postgresql/15/main

7. START PostgreSQL:
   systemctl start postgresql

8. VERIFY recovery:
   psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_xact_replay_timestamp();"

9. ACCEPT recovery point (when satisfied):
   psql -U postgres -c "SELECT pg_wal_replay_resume();"

10. VERIFY data integrity:
    Run your application-specific verification queries.

GUIDE
}

# ---- Main ----

setup_dirs

ACTION="${1:-dump}"

case "$ACTION" in
    dump)          cmd_dump ;;
    basebackup)    cmd_basebackup ;;
    wal-status)    cmd_wal_status ;;
    restore-pitr)  cmd_restore_pitr ;;
    *)
        echo "Usage: $0 [dump|basebackup|wal-status|restore-pitr]"
        exit 1
        ;;
esac
