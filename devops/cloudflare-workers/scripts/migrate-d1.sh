#!/usr/bin/env bash
# migrate-d1.sh — D1 migration helper for Cloudflare Workers
#
# Usage:
#   ./migrate-d1.sh <command> <database-name> [options]
#
# Commands:
#   create <db> <description>    Create a new migration file
#   apply-local <db>             Apply pending migrations locally
#   apply-remote <db>            Apply pending migrations to remote/production
#   list <db>                    List all migrations and their status
#   schema <db>                  Show current database schema
#   status <db>                  Show pending vs applied migrations
#   seed <db> [--file <path>]    Run seed data (default: seeds/seed.sql)
#   reset-local <db>             Drop and recreate local database
#   backup <db>                  Export remote database
#
# Options:
#   --env <name>                 Wrangler environment (e.g., staging, production)
#   --dir <path>                 Migrations directory (default: migrations/)
#
# Examples:
#   ./migrate-d1.sh create my-db "add users table"
#   ./migrate-d1.sh apply-local my-db
#   ./migrate-d1.sh apply-remote my-db --env production
#   ./migrate-d1.sh schema my-db
#   ./migrate-d1.sh list my-db
#   ./migrate-d1.sh reset-local my-db

set -euo pipefail

COMMAND="${1:-}"
DB_NAME="${2:-}"
DESCRIPTION=""
ENV_FLAG=""
MIGRATIONS_DIR="migrations"
SEED_FILE="seeds/seed.sql"

if [[ -z "$COMMAND" ]] || [[ -z "$DB_NAME" ]]; then
  head -22 "$0" | tail -20
  exit 1
fi

shift 2

# Parse remaining args
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)  ENV_FLAG="--env $2"; shift 2 ;;
    --dir)  MIGRATIONS_DIR="$2"; shift 2 ;;
    --file) SEED_FILE="$2"; shift 2 ;;
    --help|-h) head -22 "$0" | tail -20; exit 0 ;;
    *)
      if [[ -z "$DESCRIPTION" ]]; then
        DESCRIPTION="$1"
      fi
      shift
      ;;
  esac
done

wrangler_cmd() {
  # shellcheck disable=SC2086
  npx wrangler $@
}

case "$COMMAND" in
  create)
    if [[ -z "$DESCRIPTION" ]]; then
      echo "Error: Description required. Usage: $0 create <db> \"description\"" >&2
      exit 1
    fi

    echo "📝 Creating migration: ${DESCRIPTION}"
    mkdir -p "${MIGRATIONS_DIR}"
    wrangler_cmd d1 migrations create "${DB_NAME}" "${DESCRIPTION}"

    # Find the newly created file
    LATEST=$(ls -t "${MIGRATIONS_DIR}"/*.sql 2>/dev/null | head -1)
    if [[ -n "$LATEST" ]]; then
      echo ""
      echo "✅ Created: ${LATEST}"
      echo ""
      echo "-- Migration: ${DESCRIPTION}" > "${LATEST}"
      echo "-- Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "${LATEST}"
      echo "" >> "${LATEST}"
      echo "-- Write your SQL migration below:" >> "${LATEST}"
      echo "" >> "${LATEST}"
      echo "📝 Edit ${LATEST} and add your SQL"
      echo "   Then run: $0 apply-local ${DB_NAME}"
    fi
    ;;

  apply-local)
    echo "🔧 Applying migrations locally to '${DB_NAME}'..."
    # shellcheck disable=SC2086
    wrangler_cmd d1 migrations apply "${DB_NAME}" --local ${ENV_FLAG}
    echo ""
    echo "✅ Local migrations applied"
    echo "   Test your app: npx wrangler dev"
    ;;

  apply-remote)
    echo "⚠️  Applying migrations to REMOTE database '${DB_NAME}'..."
    echo "   This will modify your production/remote database."
    echo ""

    # Show pending migrations
    echo "📋 Pending migrations:"
    # shellcheck disable=SC2086
    wrangler_cmd d1 migrations list "${DB_NAME}" --remote ${ENV_FLAG} 2>/dev/null || true
    echo ""

    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi

    # shellcheck disable=SC2086
    wrangler_cmd d1 migrations apply "${DB_NAME}" --remote ${ENV_FLAG}
    echo ""
    echo "✅ Remote migrations applied"
    ;;

  list)
    echo "📋 Migrations for '${DB_NAME}':"
    echo ""
    echo "--- Local ---"
    # shellcheck disable=SC2086
    wrangler_cmd d1 migrations list "${DB_NAME}" --local ${ENV_FLAG} 2>/dev/null || echo "  (no local database)"
    echo ""
    echo "--- Remote ---"
    # shellcheck disable=SC2086
    wrangler_cmd d1 migrations list "${DB_NAME}" --remote ${ENV_FLAG} 2>/dev/null || echo "  (no remote database or not authenticated)"
    ;;

  schema)
    echo "📊 Schema for '${DB_NAME}':"
    echo ""

    LOCAL_OR_REMOTE="--local"
    if [[ -n "$ENV_FLAG" ]]; then
      LOCAL_OR_REMOTE="--remote"
    fi

    echo "--- Tables ---"
    # shellcheck disable=SC2086
    wrangler_cmd d1 execute "${DB_NAME}" ${LOCAL_OR_REMOTE} ${ENV_FLAG} \
      --command "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'd1_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'sqlite_%' ORDER BY name;" 2>/dev/null || echo "  (could not connect)"

    echo ""
    echo "--- Full Schema ---"
    # shellcheck disable=SC2086
    wrangler_cmd d1 execute "${DB_NAME}" ${LOCAL_OR_REMOTE} ${ENV_FLAG} \
      --command "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'd1_%' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'sqlite_%' ORDER BY name;" 2>/dev/null || echo "  (could not connect)"
    ;;

  status)
    echo "📊 Migration status for '${DB_NAME}':"
    echo ""

    # List local migration files
    echo "--- Migration files ---"
    if [[ -d "$MIGRATIONS_DIR" ]]; then
      ls -1 "${MIGRATIONS_DIR}"/*.sql 2>/dev/null | while read -r f; do
        echo "  📄 $(basename "$f")"
      done
    else
      echo "  (no migrations directory)"
    fi

    echo ""
    echo "--- Applied (remote) ---"
    # shellcheck disable=SC2086
    wrangler_cmd d1 migrations list "${DB_NAME}" --remote ${ENV_FLAG} 2>/dev/null || echo "  (could not connect)"
    ;;

  seed)
    if [[ ! -f "$SEED_FILE" ]]; then
      echo "❌ Seed file not found: ${SEED_FILE}" >&2
      echo "   Create it or specify with --file <path>"
      exit 1
    fi

    echo "🌱 Seeding '${DB_NAME}' from ${SEED_FILE}..."
    # shellcheck disable=SC2086
    wrangler_cmd d1 execute "${DB_NAME}" --local ${ENV_FLAG} --file="${SEED_FILE}"
    echo "✅ Seed data applied locally"
    ;;

  reset-local)
    echo "⚠️  Resetting LOCAL database '${DB_NAME}'..."
    echo "   This will delete all local data."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi

    # Delete local D1 state
    rm -rf .wrangler/state/v3/d1
    echo "🗑️  Local database deleted"

    # Re-apply migrations
    echo "🔧 Re-applying migrations..."
    # shellcheck disable=SC2086
    wrangler_cmd d1 migrations apply "${DB_NAME}" --local ${ENV_FLAG}
    echo "✅ Local database reset and migrations applied"
    ;;

  backup)
    echo "📦 Backing up remote database '${DB_NAME}'..."
    BACKUP_DIR="backups"
    BACKUP_FILE="${BACKUP_DIR}/backup-$(date +%Y%m%d-%H%M%S).sql"
    mkdir -p "$BACKUP_DIR"

    # Export schema
    # shellcheck disable=SC2086
    wrangler_cmd d1 execute "${DB_NAME}" --remote ${ENV_FLAG} \
      --command "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL;" \
      > "${BACKUP_FILE}" 2>/dev/null

    echo "✅ Backup saved to ${BACKUP_FILE}"
    echo "   Note: For full data export, use the Cloudflare dashboard or D1 API."
    ;;

  *)
    echo "❌ Unknown command: ${COMMAND}" >&2
    echo "   Run $0 --help for usage"
    exit 1
    ;;
esac
