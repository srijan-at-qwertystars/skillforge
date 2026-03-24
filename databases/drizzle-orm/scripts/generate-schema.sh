#!/usr/bin/env bash
# generate-schema.sh — Introspect an existing database and generate Drizzle schema files
#
# Usage:
#   ./generate-schema.sh                          # Uses DATABASE_URL from env or .env
#   ./generate-schema.sh --url "postgres://..."   # Explicit connection string
#   ./generate-schema.sh --dialect mysql           # Override dialect detection
#   ./generate-schema.sh --out ./src/db/schema     # Custom output directory
#
# Requires: drizzle-kit (npm i -D drizzle-kit)

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- Defaults ---
DB_URL="${DATABASE_URL:-}"
DIALECT=""
OUT_DIR="./src/db"
SCHEMA_FILTER=""

# --- Load .env if present ---
if [ -z "$DB_URL" ] && [ -f ".env" ]; then
  DB_URL=$(grep -E '^DATABASE_URL=' .env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
fi

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      DB_URL="$2"
      shift 2
      ;;
    --dialect)
      DIALECT="$2"
      shift 2
      ;;
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --schemas)
      SCHEMA_FILTER="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--url DATABASE_URL] [--dialect postgres|mysql|sqlite] [--out DIR] [--schemas 'public,auth']"
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# --- Validate ---
[ -n "$DB_URL" ] || die "No database URL. Set DATABASE_URL env var, create .env file, or pass --url"

# --- Auto-detect dialect from URL ---
if [ -z "$DIALECT" ]; then
  case "$DB_URL" in
    postgres://*|postgresql://*)
      DIALECT="postgresql"
      ;;
    mysql://*)
      DIALECT="mysql"
      ;;
    libsql://*|file:*|*.db)
      DIALECT="sqlite"
      ;;
    *)
      die "Cannot detect dialect from URL. Use --dialect to specify."
      ;;
  esac
fi
info "Detected dialect: ${DIALECT}"

# --- Check drizzle-kit ---
if ! npx drizzle-kit --version &>/dev/null 2>&1; then
  die "drizzle-kit not found. Install with: npm i -D drizzle-kit"
fi
ok "drizzle-kit found"

# --- Create temp config ---
TEMP_CONFIG=$(mktemp /tmp/drizzle-introspect-XXXXXX.ts)
trap 'rm -f "$TEMP_CONFIG"' EXIT

SCHEMA_FILTER_LINE=""
if [ -n "$SCHEMA_FILTER" ]; then
  IFS=',' read -ra SCHEMAS <<< "$SCHEMA_FILTER"
  SCHEMA_ARRAY=$(printf "'%s', " "${SCHEMAS[@]}")
  SCHEMA_ARRAY="[${SCHEMA_ARRAY%, }]"
  SCHEMA_FILTER_LINE="  schemaFilter: ${SCHEMA_ARRAY},"
fi

cat > "$TEMP_CONFIG" << EOF
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  out: '${OUT_DIR}',
  dialect: '${DIALECT}',
  dbCredentials: {
    url: '${DB_URL}',
  },
${SCHEMA_FILTER_LINE}
});
EOF

# --- Create output directory ---
mkdir -p "$OUT_DIR"

# --- Run introspection ---
info "Introspecting database..."
echo ""

npx drizzle-kit pull --config="$TEMP_CONFIG"
PULL_EXIT=$?

if [ $PULL_EXIT -ne 0 ]; then
  die "Introspection failed (exit code: $PULL_EXIT)"
fi

echo ""
ok "Schema files generated in ${OUT_DIR}/"

# --- List generated files ---
echo ""
info "Generated files:"
find "$OUT_DIR" -name '*.ts' -newer "$TEMP_CONFIG" -type f 2>/dev/null | while read -r f; do
  lines=$(wc -l < "$f")
  echo "  ${f} (${lines} lines)"
done

# --- Post-introspection advice ---
echo ""
echo -e "${YELLOW}Post-introspection checklist:${NC}"
echo "  1. Review generated schema for type accuracy (especially enums, arrays, JSON)"
echo "  2. Add relations() declarations for the relational query API"
echo "  3. Add \$type<T>() to jsonb columns for TypeScript types"
echo "  4. Create a db client file that imports the schema"
echo "  5. Update drizzle.config.ts to point to the generated schema"
echo ""
echo "  Example db client:"
echo "    import { drizzle } from 'drizzle-orm/postgres-js';"
echo "    import postgres from 'postgres';"
echo "    import * as schema from '${OUT_DIR}/schema';"
echo "    export const db = drizzle(postgres(process.env.DATABASE_URL!), { schema });"
echo ""
