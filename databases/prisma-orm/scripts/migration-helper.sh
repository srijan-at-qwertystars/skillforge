#!/usr/bin/env bash
# =============================================================================
# migration-helper.sh — Interactive Prisma migration workflow helper
#
# Usage:
#   ./migration-helper.sh              # Interactive menu
#   ./migration-helper.sh status       # Check migration status
#   ./migration-helper.sh create       # Create a new migration
#   ./migration-helper.sh apply        # Apply pending migrations (dev)
#   ./migration-helper.sh deploy       # Apply pending migrations (production)
#   ./migration-helper.sh reset        # Reset database (destructive!)
#   ./migration-helper.sh history      # Show migration history
#   ./migration-helper.sh diff         # Show drift between schema and DB
#   ./migration-helper.sh generate     # Regenerate Prisma Client
#   ./migration-helper.sh baseline     # Baseline an existing database
#
# Requirements:
#   - Node.js and npm installed
#   - Prisma CLI (npx prisma)
#   - DATABASE_URL set in .env or environment
# =============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}ℹ ${NC}$*"; }
success() { echo -e "${GREEN}✅${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠️ ${NC}$*"; }
error()   { echo -e "${RED}❌${NC} $*"; }

# Check prerequisites
check_prereqs() {
  if ! command -v npx &> /dev/null; then
    error "npx not found. Install Node.js first."
    exit 1
  fi
  if [ ! -f "prisma/schema.prisma" ] && [ ! -d "prisma/schema" ]; then
    error "No Prisma schema found. Run from your project root."
    exit 1
  fi
}

cmd_status() {
  info "Checking migration status..."
  echo ""
  npx prisma migrate status
}

cmd_create() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    read -r -p "Migration name (snake_case): " name
  fi
  if [ -z "$name" ]; then
    error "Migration name is required."
    exit 1
  fi
  info "Creating migration: $name"
  echo ""
  read -r -p "Create only (review SQL before applying)? [Y/n] " create_only
  if [[ "$create_only" =~ ^[Nn]$ ]]; then
    npx prisma migrate dev --name "$name"
  else
    npx prisma migrate dev --create-only --name "$name"
    echo ""
    success "Migration SQL created. Review it in prisma/migrations/"
    echo "  Run 'npx prisma migrate dev' to apply."
  fi
}

cmd_apply() {
  info "Applying migrations (dev mode)..."
  echo ""
  npx prisma migrate dev
  success "Migrations applied."
}

cmd_deploy() {
  info "Deploying migrations (production mode)..."
  echo ""
  npx prisma migrate deploy
  success "Migrations deployed."
}

cmd_reset() {
  warn "This will DROP the database, re-apply all migrations, and run seed."
  read -r -p "Are you sure? Type 'reset' to confirm: " confirm
  if [ "$confirm" != "reset" ]; then
    info "Aborted."
    exit 0
  fi
  echo ""
  npx prisma migrate reset
  success "Database reset complete."
}

cmd_history() {
  info "Migration history:"
  echo ""
  if [ -d "prisma/migrations" ]; then
    for dir in prisma/migrations/*/; do
      if [ -d "$dir" ]; then
        migration_name=$(basename "$dir")
        sql_file="$dir/migration.sql"
        if [ -f "$sql_file" ]; then
          line_count=$(wc -l < "$sql_file")
          echo -e "  ${GREEN}✓${NC} $migration_name  (${line_count} lines SQL)"
        else
          echo -e "  ${YELLOW}?${NC} $migration_name  (no SQL file)"
        fi
      fi
    done
  else
    echo "  No migrations directory found."
  fi
  echo ""
  info "Database status:"
  npx prisma migrate status 2>&1 || true
}

cmd_diff() {
  info "Checking schema drift..."
  echo ""
  echo "--- Schema vs Migrations ---"
  npx prisma migrate diff \
    --from-migrations ./prisma/migrations \
    --to-schema-datamodel ./prisma/schema.prisma \
    2>&1 || warn "Could not compare against migrations."
  echo ""
}

cmd_generate() {
  info "Regenerating Prisma Client..."
  npx prisma generate
  success "Prisma Client regenerated."
}

cmd_baseline() {
  info "Baselining an existing database..."
  echo ""
  echo "This creates a migration from the current schema and marks it as applied"
  echo "without actually running the SQL. Use when adopting Prisma on an existing DB."
  echo ""
  read -r -p "Migration name [baseline]: " name
  name="${name:-baseline}"

  npx prisma migrate diff \
    --from-empty \
    --to-schema-datamodel ./prisma/schema.prisma \
    --script > "prisma/migrations/0_${name}/migration.sql" 2>/dev/null || {
    mkdir -p "prisma/migrations/0_${name}"
    npx prisma migrate diff \
      --from-empty \
      --to-schema-datamodel ./prisma/schema.prisma \
      --script > "prisma/migrations/0_${name}/migration.sql"
  }

  npx prisma migrate resolve --applied "0_${name}"
  success "Baseline migration created and marked as applied."
}

show_menu() {
  echo ""
  echo -e "${BLUE}═══════════════════════════════════════${NC}"
  echo -e "${BLUE}  Prisma Migration Helper${NC}"
  echo -e "${BLUE}═══════════════════════════════════════${NC}"
  echo ""
  echo "  1) Status     — Check migration status"
  echo "  2) Create     — Create a new migration"
  echo "  3) Apply      — Apply pending migrations (dev)"
  echo "  4) Deploy     — Apply pending migrations (production)"
  echo "  5) Reset      — Reset database (destructive!)"
  echo "  6) History    — Show migration history"
  echo "  7) Diff       — Show schema drift"
  echo "  8) Generate   — Regenerate Prisma Client"
  echo "  9) Baseline   — Baseline existing database"
  echo "  0) Exit"
  echo ""
  read -r -p "Select option: " choice

  case "$choice" in
    1) cmd_status ;;
    2) cmd_create ;;
    3) cmd_apply ;;
    4) cmd_deploy ;;
    5) cmd_reset ;;
    6) cmd_history ;;
    7) cmd_diff ;;
    8) cmd_generate ;;
    9) cmd_baseline ;;
    0) exit 0 ;;
    *) error "Invalid option: $choice" ;;
  esac
}

# Main
check_prereqs

if [ $# -eq 0 ]; then
  # Interactive mode
  while true; do
    show_menu
    echo ""
    read -r -p "Press Enter to continue..." _
  done
else
  # Direct command mode
  case "$1" in
    status)   cmd_status ;;
    create)   cmd_create "${2:-}" ;;
    apply)    cmd_apply ;;
    deploy)   cmd_deploy ;;
    reset)    cmd_reset ;;
    history)  cmd_history ;;
    diff)     cmd_diff ;;
    generate) cmd_generate ;;
    baseline) cmd_baseline ;;
    *)        error "Unknown command: $1"; echo "Run without arguments for interactive menu."; exit 1 ;;
  esac
fi
