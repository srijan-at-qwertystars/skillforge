#!/usr/bin/env bash
# migration-ops.sh — Common drizzle-kit migration operations
#
# Usage:
#   ./migration-ops.sh <command> [options]
#
# Commands:
#   generate     — Generate SQL migration files from schema diff
#   migrate      — Apply pending migrations to the database
#   push         — Push schema directly to DB (dev only, no migration files)
#   pull         — Introspect DB and generate TypeScript schema files
#   studio       — Launch Drizzle Studio visual DB browser
#   drop         — Interactively drop a migration
#   check        — Verify migration file consistency
#   up           — Upgrade migration snapshots to latest format
#   status       — Show current migration status
#   reset        — Drop all tables and re-migrate (DESTRUCTIVE)
#   seed         — Run seed script (expects src/db/seed.ts or seed.ts)
#   fresh        — Reset + seed (DESTRUCTIVE)
#
# Options:
#   --config <path>    Custom drizzle config path (default: drizzle.config.ts)
#   --verbose          Enable verbose output
#   --dry-run          Show what would be done (generate only)
#
# Examples:
#   ./migration-ops.sh generate
#   ./migration-ops.sh push
#   ./migration-ops.sh studio --config ./custom-drizzle.config.ts
#   ./migration-ops.sh reset

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────────
CONFIG_FILE="drizzle.config.ts"
VERBOSE=""
DRY_RUN=""

# ─── Parse args ─────────────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    --verbose) VERBOSE="--verbose"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) COMMAND="help"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Detect runner ──────────────────────────────────────────────────────────────
RUNNER="npx"
if [ -f "bun.lockb" ] && command -v bun &>/dev/null; then
  RUNNER="bunx"
fi

DK="$RUNNER drizzle-kit"

# ─── Validate config exists ────────────────────────────────────────────────────
check_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "   Run init-drizzle.sh first or specify --config <path>"
    exit 1
  fi
}

# ─── Commands ───────────────────────────────────────────────────────────────────
case "$COMMAND" in

  generate)
    check_config
    echo "📋 Generating migration files from schema diff..."
    $DK generate --config "$CONFIG_FILE" $VERBOSE
    echo ""
    echo "✅ Migration files generated in ./drizzle/"
    echo "   Review the SQL, then run: $0 migrate"
    ;;

  migrate)
    check_config
    echo "🚀 Applying pending migrations..."
    $DK migrate --config "$CONFIG_FILE" $VERBOSE
    echo "✅ Migrations applied successfully"
    ;;

  push)
    check_config
    echo "⚡ Pushing schema directly to database (no migration files)..."
    echo "   ⚠️  This is for development only. Use 'generate + migrate' for production."
    $DK push --config "$CONFIG_FILE" $VERBOSE
    echo "✅ Schema pushed"
    ;;

  pull)
    check_config
    echo "📥 Introspecting database schema..."
    $DK pull --config "$CONFIG_FILE" $VERBOSE
    echo "✅ Schema pulled. Check generated files."
    ;;

  studio)
    check_config
    echo "🎨 Launching Drizzle Studio..."
    echo "   Open https://local.drizzle.studio in your browser"
    $DK studio --config "$CONFIG_FILE" $VERBOSE
    ;;

  drop)
    check_config
    echo "🗑️  Dropping a migration (interactive)..."
    $DK drop --config "$CONFIG_FILE"
    ;;

  check)
    check_config
    echo "🔍 Checking migration consistency..."
    $DK check --config "$CONFIG_FILE" $VERBOSE
    echo "✅ Migrations are consistent"
    ;;

  up)
    check_config
    echo "⬆️  Upgrading migration snapshots..."
    $DK up --config "$CONFIG_FILE" $VERBOSE
    echo "✅ Snapshots upgraded"
    ;;

  status)
    check_config
    echo "📊 Migration status:"
    echo ""
    echo "Migration files in ./drizzle/:"
    if [ -d "drizzle" ]; then
      find drizzle -name "*.sql" -type f | sort | while read -r f; do
        echo "  📄 $(basename "$f")"
      done
      SQL_COUNT=$(find drizzle -name "*.sql" -type f | wc -l)
      echo ""
      echo "Total: $SQL_COUNT migration file(s)"
    else
      echo "  (no migrations directory found)"
    fi
    echo ""
    echo "Run 'drizzle-kit check' to verify consistency."
    ;;

  reset)
    check_config
    echo "⚠️  This will DROP all tables and re-run migrations."
    read -rp "Are you sure? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
      echo "🗑️  Dropping and re-migrating..."
      $DK push --config "$CONFIG_FILE" $VERBOSE
      echo "✅ Database reset complete"
    else
      echo "Aborted."
    fi
    ;;

  seed)
    echo "🌱 Running seed script..."
    if [ -f "src/db/seed.ts" ]; then
      $RUNNER tsx src/db/seed.ts
    elif [ -f "seed.ts" ]; then
      $RUNNER tsx seed.ts
    elif [ -f "src/db/seed.js" ]; then
      node src/db/seed.js
    else
      echo "❌ No seed file found. Create src/db/seed.ts"
      exit 1
    fi
    echo "✅ Seeding complete"
    ;;

  fresh)
    check_config
    echo "⚠️  This will DROP all tables, re-migrate, and seed."
    read -rp "Are you sure? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
      $0 reset --config "$CONFIG_FILE" $VERBOSE <<< "yes"
      $0 seed
      echo "✅ Fresh database ready"
    else
      echo "Aborted."
    fi
    ;;

  help|*)
    cat <<'HELP'
Drizzle Migration Operations

Usage: ./migration-ops.sh <command> [options]

Commands:
  generate   Generate SQL migration files from schema changes
  migrate    Apply pending migrations to the database
  push       Push schema directly (dev only, no files created)
  pull       Introspect existing DB → TypeScript schema
  studio     Launch Drizzle Studio visual browser
  drop       Interactively remove a migration
  check      Verify migration file consistency
  up         Upgrade snapshot format to latest
  status     Show migration file listing
  reset      Drop all + re-push schema (⚠️ DESTRUCTIVE)
  seed       Run src/db/seed.ts
  fresh      Reset + seed (⚠️ DESTRUCTIVE)

Options:
  --config <path>   Config file (default: drizzle.config.ts)
  --verbose         Verbose output
  -h, --help        Show this help

Workflow:
  Development:  push (fast iteration)
  Production:   generate → review SQL → migrate
  Brownfield:   pull → adjust schema → generate
HELP
    ;;
esac
