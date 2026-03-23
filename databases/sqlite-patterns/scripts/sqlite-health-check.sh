#!/usr/bin/env bash
# sqlite-health-check.sh — Check SQLite database health
# Usage: sqlite-health-check.sh <database_path>
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <database_path>"
    echo "Check SQLite database health: integrity, WAL status, page stats, and more."
    exit 1
fi

DB_PATH="$1"

if [[ ! -f "$DB_PATH" ]]; then
    echo "ERROR: Database file not found: $DB_PATH"
    exit 1
fi

SQLITE3="${SQLITE3_BIN:-sqlite3}"
if ! command -v "$SQLITE3" &>/dev/null; then
    echo "ERROR: sqlite3 not found. Install SQLite or set SQLITE3_BIN."
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           SQLite Health Check Report                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Database: $DB_PATH"
echo "Date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Size:     $(du -h "$DB_PATH" | cut -f1)"
echo ""

# Check for WAL and SHM files
WAL_FILE="${DB_PATH}-wal"
SHM_FILE="${DB_PATH}-shm"
if [[ -f "$WAL_FILE" ]]; then
    echo "WAL file: $(du -h "$WAL_FILE" | cut -f1)"
else
    echo "WAL file: not present"
fi
if [[ -f "$SHM_FILE" ]]; then
    echo "SHM file: $(du -h "$SHM_FILE" | cut -f1)"
else
    echo "SHM file: not present"
fi
echo ""

echo "── Database Configuration ──────────────────────────────────"
"$SQLITE3" "$DB_PATH" <<'EOF'
.headers off
SELECT 'Journal mode:    ' || journal_mode FROM pragma_journal_mode();
SELECT 'Synchronous:     ' || synchronous FROM pragma_synchronous();
SELECT 'Foreign keys:    ' || foreign_keys FROM pragma_foreign_keys();
SELECT 'Auto-vacuum:     ' || auto_vacuum FROM pragma_auto_vacuum();
SELECT 'Page size:       ' || page_size || ' bytes' FROM pragma_page_size();
SELECT 'Cache size:      ' || cache_size FROM pragma_cache_size();
SELECT 'Encoding:        ' || encoding FROM pragma_encoding();
SELECT 'Busy timeout:    ' || busy_timeout || ' ms' FROM pragma_busy_timeout();
EOF
echo ""

echo "── Page Statistics ────────────────────────────────────────"
"$SQLITE3" "$DB_PATH" <<'EOF'
.headers off
SELECT 'Page count:      ' || page_count FROM pragma_page_count();
SELECT 'Freelist pages:  ' || freelist_count FROM pragma_freelist_count();
SELECT 'Schema version:  ' || schema_version FROM pragma_schema_version();
SELECT 'Data version:    ' || data_version FROM pragma_data_version();
EOF

# Calculate database size and free space
"$SQLITE3" "$DB_PATH" <<'EOF'
.headers off
SELECT 'Total size:      ' || (page_count * page_size) || ' bytes (' ||
       round(page_count * page_size / 1048576.0, 2) || ' MB)'
FROM pragma_page_count(), pragma_page_size();
SELECT 'Free space:      ' || (freelist_count * page_size) || ' bytes (' ||
       round(freelist_count * page_size / 1048576.0, 2) || ' MB, ' ||
       CASE WHEN page_count > 0
           THEN round(100.0 * freelist_count / page_count, 1)
           ELSE 0
       END || '%)'
FROM pragma_freelist_count(), pragma_page_size(), pragma_page_count();
EOF
echo ""

echo "── WAL Checkpoint Status ──────────────────────────────────"
JOURNAL_MODE=$("$SQLITE3" "$DB_PATH" "PRAGMA journal_mode;")
if [[ "$JOURNAL_MODE" == "wal" ]]; then
    "$SQLITE3" "$DB_PATH" <<'EOF'
.headers off
SELECT 'WAL auto-checkpoint: ' || wal_autocheckpoint FROM pragma_wal_autocheckpoint();
EOF
    CHECKPOINT=$("$SQLITE3" "$DB_PATH" "PRAGMA wal_checkpoint(PASSIVE);")
    echo "Checkpoint result:   $CHECKPOINT (busy, log, checkpointed)"
else
    echo "Not in WAL mode (journal_mode=$JOURNAL_MODE)"
fi
echo ""

echo "── Table Summary ──────────────────────────────────────────"
"$SQLITE3" "$DB_PATH" <<'EOF'
.headers on
.mode column
SELECT
    name AS 'Table',
    (SELECT count(*) FROM pragma_table_info(m.name)) AS 'Columns',
    (SELECT count(*) FROM pragma_index_list(m.name)) AS 'Indexes'
FROM sqlite_master m
WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
ORDER BY name;
EOF
echo ""

echo "── Integrity Check ────────────────────────────────────────"
INTEGRITY=$("$SQLITE3" "$DB_PATH" "PRAGMA integrity_check;")
if [[ "$INTEGRITY" == "ok" ]]; then
    echo "✅ Integrity check: PASSED"
else
    echo "❌ Integrity check: FAILED"
    echo "$INTEGRITY"
fi

FK_CHECK=$("$SQLITE3" "$DB_PATH" "PRAGMA foreign_key_check;" 2>/dev/null)
if [[ -z "$FK_CHECK" ]]; then
    echo "✅ Foreign key check: PASSED"
else
    echo "❌ Foreign key check: FAILED"
    echo "$FK_CHECK"
fi
echo ""
echo "── Done ───────────────────────────────────────────────────"
