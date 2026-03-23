#!/usr/bin/env bash
# sqlite-optimize.sh — Optimize SQLite database performance
# Usage: sqlite-optimize.sh <database_path> [--vacuum] [--analyze] [--reindex] [--all]
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <database_path> [options]"
    echo ""
    echo "Options:"
    echo "  --analyze    Run ANALYZE to update query planner statistics"
    echo "  --vacuum     Run VACUUM to defragment and compact the database"
    echo "  --reindex    Rebuild all indexes"
    echo "  --optimize   Run PRAGMA optimize (lightweight, safe for frequent use)"
    echo "  --wal-checkpoint  Force a WAL checkpoint (TRUNCATE mode)"
    echo "  --incremental-vacuum <pages>  Reclaim pages from freelist"
    echo "  --recommendations  Show index recommendations"
    echo "  --all        Run analyze + vacuum + reindex + optimize + checkpoint"
    echo ""
    echo "With no options, runs --optimize --analyze (safe defaults)."
    exit 1
fi

DB_PATH="$1"
shift

if [[ ! -f "$DB_PATH" ]]; then
    echo "ERROR: Database file not found: $DB_PATH"
    exit 1
fi

SQLITE3="${SQLITE3_BIN:-sqlite3}"
if ! command -v "$SQLITE3" &>/dev/null; then
    echo "ERROR: sqlite3 not found. Install SQLite or set SQLITE3_BIN."
    exit 1
fi

DO_ANALYZE=false
DO_VACUUM=false
DO_REINDEX=false
DO_OPTIMIZE=false
DO_CHECKPOINT=false
DO_INCREMENTAL=false
DO_RECOMMENDATIONS=false
INCREMENTAL_PAGES=0

if [[ $# -eq 0 ]]; then
    DO_OPTIMIZE=true
    DO_ANALYZE=true
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --analyze)       DO_ANALYZE=true ;;
        --vacuum)        DO_VACUUM=true ;;
        --reindex)       DO_REINDEX=true ;;
        --optimize)      DO_OPTIMIZE=true ;;
        --wal-checkpoint) DO_CHECKPOINT=true ;;
        --incremental-vacuum)
            DO_INCREMENTAL=true
            INCREMENTAL_PAGES="${2:-1000}"
            shift
            ;;
        --recommendations) DO_RECOMMENDATIONS=true ;;
        --all)
            DO_ANALYZE=true
            DO_VACUUM=true
            DO_REINDEX=true
            DO_OPTIMIZE=true
            DO_CHECKPOINT=true
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

SIZE_BEFORE=$(stat -c%s "$DB_PATH" 2>/dev/null || stat -f%z "$DB_PATH" 2>/dev/null)

echo "SQLite Optimize: $DB_PATH"
echo "Size before: $(echo "$SIZE_BEFORE" | awk '{printf "%.2f MB\n", $1/1048576}')"
echo ""

if $DO_OPTIMIZE; then
    echo "── Running PRAGMA optimize ────────────────────────────────"
    echo "  (Runs ANALYZE on tables where planner statistics are stale)"
    "$SQLITE3" "$DB_PATH" "PRAGMA optimize;"
    echo "  Done."
    echo ""
fi

if $DO_ANALYZE; then
    echo "── Running ANALYZE ────────────────────────────────────────"
    echo "  (Updates query planner statistics for all tables)"
    "$SQLITE3" "$DB_PATH" "ANALYZE;"
    echo "  Done."
    echo ""
fi

if $DO_CHECKPOINT; then
    JOURNAL_MODE=$("$SQLITE3" "$DB_PATH" "PRAGMA journal_mode;")
    echo "── WAL Checkpoint ─────────────────────────────────────────"
    if [[ "$JOURNAL_MODE" == "wal" ]]; then
        RESULT=$("$SQLITE3" "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);")
        echo "  Checkpoint result: $RESULT (busy, log, checkpointed)"
    else
        echo "  Skipped: not in WAL mode (journal_mode=$JOURNAL_MODE)"
    fi
    echo ""
fi

if $DO_INCREMENTAL; then
    echo "── Incremental VACUUM ─────────────────────────────────────"
    FREELIST=$("$SQLITE3" "$DB_PATH" "PRAGMA freelist_count;")
    echo "  Freelist pages before: $FREELIST"
    "$SQLITE3" "$DB_PATH" "PRAGMA incremental_vacuum($INCREMENTAL_PAGES);"
    FREELIST_AFTER=$("$SQLITE3" "$DB_PATH" "PRAGMA freelist_count;")
    echo "  Freelist pages after:  $FREELIST_AFTER"
    echo ""
fi

if $DO_REINDEX; then
    echo "── Running REINDEX ────────────────────────────────────────"
    echo "  (Rebuilds all indexes)"
    "$SQLITE3" "$DB_PATH" "REINDEX;"
    echo "  Done."
    echo ""
fi

if $DO_VACUUM; then
    echo "── Running VACUUM ─────────────────────────────────────────"
    echo "  (Defragmenting and compacting database — this may take a while)"
    echo "  WARNING: Requires exclusive lock. No other connections allowed."
    "$SQLITE3" "$DB_PATH" "VACUUM;"
    echo "  Done."
    echo ""
fi

if $DO_RECOMMENDATIONS; then
    echo "── Index Recommendations ──────────────────────────────────"
    echo ""
    echo "  Tables without indexes (excluding small/system tables):"
    "$SQLITE3" "$DB_PATH" <<'EOF'
.headers off
SELECT '  ⚠  ' || m.name || ' (no indexes)'
FROM sqlite_master m
WHERE m.type = 'table'
  AND m.name NOT LIKE 'sqlite_%'
  AND m.name NOT LIKE '%_fts%'
  AND NOT EXISTS (
      SELECT 1 FROM sqlite_master i
      WHERE i.type = 'index'
        AND i.tbl_name = m.name
        AND i.name NOT LIKE 'sqlite_autoindex_%'
  )
ORDER BY m.name;
EOF

    echo ""
    echo "  Tables with many columns but few indexes:"
    "$SQLITE3" "$DB_PATH" <<'EOF'
.headers off
SELECT '  ℹ  ' || m.name || ': ' ||
       (SELECT count(*) FROM pragma_table_info(m.name)) || ' columns, ' ||
       (SELECT count(*) FROM pragma_index_list(m.name)) || ' indexes'
FROM sqlite_master m
WHERE m.type = 'table'
  AND m.name NOT LIKE 'sqlite_%'
  AND (SELECT count(*) FROM pragma_table_info(m.name)) > 5
  AND (SELECT count(*) FROM pragma_index_list(m.name)) < 2
ORDER BY m.name;
EOF

    echo ""
    echo "  Tip: Run 'EXPLAIN QUERY PLAN <your_query>' to verify index usage."
    echo ""
fi

SIZE_AFTER=$(stat -c%s "$DB_PATH" 2>/dev/null || stat -f%z "$DB_PATH" 2>/dev/null)
SAVED=$((SIZE_BEFORE - SIZE_AFTER))

echo "── Summary ────────────────────────────────────────────────"
echo "  Size before: $(echo "$SIZE_BEFORE" | awk '{printf "%.2f MB", $1/1048576}')"
echo "  Size after:  $(echo "$SIZE_AFTER" | awk '{printf "%.2f MB", $1/1048576}')"
if [[ $SAVED -gt 0 ]]; then
    echo "  Saved:       $(echo "$SAVED" | awk '{printf "%.2f MB", $1/1048576}')"
elif [[ $SAVED -lt 0 ]]; then
    echo "  Growth:      $(echo "$((-SAVED))" | awk '{printf "%.2f MB", $1/1048576}')"
else
    echo "  No size change."
fi
echo "  Done."
