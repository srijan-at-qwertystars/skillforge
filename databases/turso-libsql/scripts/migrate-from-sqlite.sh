#!/usr/bin/env bash
#
# migrate-from-sqlite.sh — Migrate an existing SQLite database to Turso
#
# Usage:
#   ./migrate-from-sqlite.sh <sqlite-file> <turso-db-name> [group]
#
# Examples:
#   ./migrate-from-sqlite.sh ./myapp.db myapp
#   ./migrate-from-sqlite.sh /data/prod.sqlite myapp prod
#
# What this script does:
#   1. Validates the SQLite file
#   2. Shows current database stats (tables, rows, size)
#   3. Creates a Turso database (or uses existing)
#   4. Dumps SQLite and imports into Turso
#   5. Verifies row counts match
#   6. Prints connection details
#
# Prerequisites:
#   - sqlite3 CLI installed
#   - Turso CLI installed and authenticated
#

set -euo pipefail

SQLITE_FILE="${1:-}"
TURSO_DB="${2:-}"
GROUP="${3:-}"

if [ -z "$SQLITE_FILE" ] || [ -z "$TURSO_DB" ]; then
  echo "Usage: $0 <sqlite-file> <turso-db-name> [group]"
  echo ""
  echo "Examples:"
  echo "  $0 ./myapp.db myapp"
  echo "  $0 /data/prod.sqlite myapp prod"
  exit 1
fi

# --- Check prerequisites ---

if ! command -v sqlite3 &> /dev/null; then
  echo "Error: sqlite3 not found. Install SQLite CLI first."
  exit 1
fi

if ! command -v turso &> /dev/null; then
  echo "Error: Turso CLI not found."
  echo "Install with: curl -sSfL https://get.tur.so/install.sh | bash"
  exit 1
fi

if [ ! -f "$SQLITE_FILE" ]; then
  echo "Error: SQLite file not found: $SQLITE_FILE"
  exit 1
fi

# --- Validate SQLite file ---

echo "==> Validating SQLite file: $SQLITE_FILE"
INTEGRITY=$(sqlite3 "$SQLITE_FILE" "PRAGMA integrity_check" 2>&1)
if [ "$INTEGRITY" != "ok" ]; then
  echo "    ✗ Integrity check failed: $INTEGRITY"
  echo "    Consider running: sqlite3 $SQLITE_FILE 'REINDEX'"
  exit 1
fi
echo "    ✓ Integrity check passed"

# --- Show source stats ---

FILE_SIZE=$(du -h "$SQLITE_FILE" | cut -f1)
echo ""
echo "==> Source database: $SQLITE_FILE ($FILE_SIZE)"
echo ""
echo "    Tables and row counts:"
TABLES=$(sqlite3 "$SQLITE_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
for TABLE in $TABLES; do
  COUNT=$(sqlite3 "$SQLITE_FILE" "SELECT count(*) FROM \"$TABLE\"" 2>/dev/null || echo "?")
  printf "    %-30s %s rows\n" "$TABLE" "$COUNT"
done

# --- Create Turso database ---

echo ""
echo "==> Creating Turso database '$TURSO_DB'..."

if turso db show "$TURSO_DB" &> /dev/null; then
  echo "    ⚠ Database '$TURSO_DB' already exists."
  read -p "    Overwrite? This will destroy existing data. (y/N): " OVERWRITE
  if [ "${OVERWRITE,,}" = "y" ]; then
    turso db destroy "$TURSO_DB" --yes
    echo "    ✓ Old database destroyed"
  else
    echo "    Aborting."
    exit 1
  fi
fi

CREATE_FLAGS=""
if [ -n "$GROUP" ]; then
  CREATE_FLAGS="--group $GROUP"
fi

# Try direct file import first (faster for large DBs)
echo "    Attempting direct file import..."
if turso db create "$TURSO_DB" --from-file "$SQLITE_FILE" $CREATE_FLAGS 2>/dev/null; then
  echo "    ✓ Database created from file import"
else
  echo "    Direct import not available, using SQL dump..."

  # Create empty database
  turso db create "$TURSO_DB" $CREATE_FLAGS
  echo "    ✓ Empty database created"

  # Dump and import
  DUMP_FILE=$(mktemp /tmp/turso-migration-XXXXXX.sql)
  trap "rm -f $DUMP_FILE" EXIT

  echo "    Dumping SQLite to SQL..."
  sqlite3 "$SQLITE_FILE" .dump > "$DUMP_FILE"
  DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
  echo "    ✓ Dump complete ($DUMP_SIZE)"

  echo "    Importing into Turso..."
  turso db shell "$TURSO_DB" < "$DUMP_FILE"
  echo "    ✓ Import complete"
fi

# --- Verify migration ---

echo ""
echo "==> Verifying migration..."
ALL_MATCH=true
for TABLE in $TABLES; do
  SRC_COUNT=$(sqlite3 "$SQLITE_FILE" "SELECT count(*) FROM \"$TABLE\"" 2>/dev/null || echo "?")
  DST_COUNT=$(turso db shell "$TURSO_DB" "SELECT count(*) FROM \"$TABLE\"" 2>/dev/null | tail -1 | tr -d '[:space:]')

  if [ "$SRC_COUNT" = "$DST_COUNT" ]; then
    printf "    %-30s ✓ %s rows\n" "$TABLE" "$SRC_COUNT"
  else
    printf "    %-30s ✗ source=%s turso=%s\n" "$TABLE" "$SRC_COUNT" "$DST_COUNT"
    ALL_MATCH=false
  fi
done

echo ""
if [ "$ALL_MATCH" = true ]; then
  echo "    ✓ All tables verified — row counts match"
else
  echo "    ⚠ Some tables have mismatched row counts. Review above."
fi

# --- Print connection details ---

DB_URL=$(turso db show "$TURSO_DB" --url)
AUTH_TOKEN=$(turso db tokens create "$TURSO_DB")

echo ""
echo "============================================"
echo "  Migration Complete"
echo "============================================"
echo ""
echo "Add to your .env file:"
echo ""
echo "  TURSO_DATABASE_URL=$DB_URL"
echo "  TURSO_AUTH_TOKEN=$AUTH_TOKEN"
echo ""
echo "Update your code:"
echo "  - Replace sqlite3/better-sqlite3 with @libsql/client"
echo "  - See references/sqlite-migration.md for ORM guides"
echo "============================================"
