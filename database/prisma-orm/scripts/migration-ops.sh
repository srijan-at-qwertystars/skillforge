#!/usr/bin/env bash
# ==============================================================================
# migration-ops.sh — Common Prisma migration operations
#
# Usage:
#   ./migration-ops.sh create <name>        # Create a new migration
#   ./migration-ops.sh apply                # Apply pending migrations (dev)
#   ./migration-ops.sh deploy               # Apply pending migrations (production)
#   ./migration-ops.sh reset                # Reset DB and reapply all migrations
#   ./migration-ops.sh status               # Show migration status
#   ./migration-ops.sh resolve-applied <name>   # Mark migration as applied
#   ./migration-ops.sh resolve-rolled-back <name> # Mark migration as rolled back
#   ./migration-ops.sh diff                 # Show diff between schema and DB
#   ./migration-ops.sh seed                 # Run seed script
#   ./migration-ops.sh push                 # Push schema without migration (prototyping)
#   ./migration-ops.sh pull                 # Introspect DB → update schema
#   ./migration-ops.sh validate             # Validate schema syntax
#   ./migration-ops.sh generate             # Regenerate Prisma Client
#   ./migration-ops.sh baseline <name>      # Baseline an existing database
#
# Environment:
#   DATABASE_URL          — Connection string (loaded from .env automatically)
#   DIRECT_DATABASE_URL   — Direct connection for migrations behind pooler
# ==============================================================================

set -euo pipefail

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in

  # ---- Create a new migration ----
  create)
    NAME="${1:?Usage: migration-ops.sh create <migration-name>}"
    echo "📝 Creating migration: $NAME"
    npx prisma migrate dev --name "$NAME"
    echo "✅ Migration '$NAME' created and applied."
    ;;

  # ---- Apply pending migrations (dev — creates migration if schema changed) ----
  apply)
    echo "🔄 Applying pending migrations (dev mode)..."
    npx prisma migrate dev
    echo "✅ Migrations applied."
    ;;

  # ---- Deploy pending migrations (production — never creates new ones) ----
  deploy)
    echo "🚀 Deploying pending migrations (production mode)..."
    npx prisma migrate deploy
    echo "✅ All pending migrations deployed."
    ;;

  # ---- Reset DB: drop, recreate, migrate, seed ----
  reset)
    echo "⚠️  Resetting database (ALL DATA WILL BE LOST)..."
    read -r -p "Continue? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      npx prisma migrate reset
      echo "✅ Database reset complete."
    else
      echo "❌ Aborted."
    fi
    ;;

  # ---- Force reset (no prompt, for CI) ----
  reset-force)
    echo "⚠️  Force resetting database..."
    npx prisma migrate reset --force
    echo "✅ Database reset complete."
    ;;

  # ---- Check migration status ----
  status)
    echo "📊 Migration status:"
    npx prisma migrate status
    ;;

  # ---- Mark a migration as applied (resolve drift) ----
  resolve-applied)
    NAME="${1:?Usage: migration-ops.sh resolve-applied <migration-name>}"
    echo "✅ Marking migration as applied: $NAME"
    npx prisma migrate resolve --applied "$NAME"
    ;;

  # ---- Mark a migration as rolled back ----
  resolve-rolled-back)
    NAME="${1:?Usage: migration-ops.sh resolve-rolled-back <migration-name>}"
    echo "↩️  Marking migration as rolled back: $NAME"
    npx prisma migrate resolve --rolled-back "$NAME"
    ;;

  # ---- Show diff between schema and migrations ----
  diff)
    echo "🔍 Schema diff (migrations → schema.prisma):"
    npx prisma migrate diff \
      --from-migrations ./prisma/migrations \
      --to-schema-datamodel ./prisma/schema.prisma
    ;;

  # ---- Diff from DB to schema ----
  diff-db)
    echo "🔍 Schema diff (database → schema.prisma):"
    npx prisma migrate diff \
      --from-schema-datasource ./prisma/schema.prisma \
      --to-schema-datamodel ./prisma/schema.prisma
    ;;

  # ---- Run seed ----
  seed)
    echo "🌱 Running seed script..."
    npx prisma db seed
    echo "✅ Seeding complete."
    ;;

  # ---- Push schema without migration files (prototyping) ----
  push)
    echo "⬆️  Pushing schema to database (no migration file)..."
    npx prisma db push
    echo "✅ Schema pushed."
    ;;

  # ---- Pull / introspect DB ----
  pull)
    echo "⬇️  Introspecting database → schema.prisma..."
    npx prisma db pull
    echo "✅ Schema updated from database. Run 'npx prisma generate' next."
    ;;

  # ---- Validate schema ----
  validate)
    echo "🔎 Validating schema..."
    npx prisma validate
    echo "✅ Schema is valid."
    ;;

  # ---- Regenerate client ----
  generate)
    echo "⚙️  Regenerating Prisma Client..."
    npx prisma generate
    echo "✅ Client generated."
    ;;

  # ---- Baseline: mark all existing migrations as applied without running them ----
  baseline)
    NAME="${1:?Usage: migration-ops.sh baseline <migration-name>}"
    echo "📌 Baselining database with migration: $NAME"
    echo "   Step 1: Creating migration without applying..."
    npx prisma migrate dev --name "$NAME" --create-only
    echo "   Step 2: Marking as applied..."
    npx prisma migrate resolve --applied "$NAME"
    echo "✅ Baseline complete."
    ;;

  # ---- Help ----
  help|--help|-h|*)
    echo "Prisma Migration Operations"
    echo ""
    echo "Usage: ./migration-ops.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  create <name>              Create and apply a new migration"
    echo "  apply                      Apply pending migrations (dev)"
    echo "  deploy                     Apply pending migrations (production)"
    echo "  reset                      Reset DB + reapply + seed (interactive)"
    echo "  reset-force                Reset DB without confirmation (CI)"
    echo "  status                     Show migration status"
    echo "  resolve-applied <name>     Mark migration as applied"
    echo "  resolve-rolled-back <name> Mark migration as rolled back"
    echo "  diff                       Diff migrations → schema"
    echo "  diff-db                    Diff database → schema"
    echo "  seed                       Run seed script"
    echo "  push                       Push schema (no migration file)"
    echo "  pull                       Introspect DB → schema"
    echo "  validate                   Validate schema syntax"
    echo "  generate                   Regenerate Prisma Client"
    echo "  baseline <name>            Baseline existing DB"
    echo ""
    ;;
esac
