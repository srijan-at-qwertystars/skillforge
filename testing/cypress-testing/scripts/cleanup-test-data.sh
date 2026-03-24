#!/usr/bin/env bash
# cleanup-test-data.sh — Clean up Cypress test artifacts and optionally reset test DB
# Usage: ./cleanup-test-data.sh [--all] [--db] [--artifacts] [--cache] [--dry-run]
set -euo pipefail

# --- Defaults ---
CLEAN_ARTIFACTS=false
CLEAN_DB=false
CLEAN_CACHE=false
DRY_RUN=false
CLEANED=0

# --- Parse arguments ---
if [ $# -eq 0 ]; then
  CLEAN_ARTIFACTS=true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) CLEAN_ARTIFACTS=true; CLEAN_DB=true; CLEAN_CACHE=true; shift ;;
    --artifacts) CLEAN_ARTIFACTS=true; shift ;;
    --db) CLEAN_DB=true; shift ;;
    --cache) CLEAN_CACHE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--all] [--artifacts] [--db] [--cache] [--dry-run]"
      echo ""
      echo "Options:"
      echo "  --all         Clean everything (artifacts + db + cache)"
      echo "  --artifacts   Remove screenshots, videos, downloads (default if no flags)"
      echo "  --db          Reset test database (runs db:reset:test if available)"
      echo "  --cache       Clear Cypress cache (~/.cache/Cypress)"
      echo "  --dry-run     Show what would be removed without deleting"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

remove_dir() {
  local dir="$1"
  local label="$2"

  if [ -d "$dir" ]; then
    local count
    count=$(find "$dir" -type f 2>/dev/null | wc -l)
    local size
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)

    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would remove $dir ($count files, $size)"
    else
      rm -rf "$dir"
      mkdir -p "$dir"
      echo "  ✓ Removed $label: $count files ($size)"
    fi
    CLEANED=$((CLEANED + count))
  else
    echo "  - $label: directory not found, skipping"
  fi
}

echo "🧹 Cypress Test Cleanup"
echo ""

# --- Clean test artifacts ---
if [ "$CLEAN_ARTIFACTS" = true ]; then
  echo "📸 Cleaning test artifacts..."
  remove_dir "cypress/screenshots" "Screenshots"
  remove_dir "cypress/videos" "Videos"
  remove_dir "cypress/downloads" "Downloads"

  # Clean coverage reports if they exist
  if [ -d ".nyc_output" ]; then
    remove_dir ".nyc_output" "NYC output"
  fi
  if [ -d "coverage" ]; then
    remove_dir "coverage" "Coverage reports"
  fi

  # Clean mochawesome reports if they exist
  if [ -d "cypress/reports" ]; then
    remove_dir "cypress/reports" "Test reports"
  fi

  echo ""
fi

# --- Reset test database ---
if [ "$CLEAN_DB" = true ]; then
  echo "🗄️  Resetting test database..."

  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] Would run database reset command"
  else
    # Try common database reset patterns
    if npm run --silent db:reset:test 2>/dev/null; then
      echo "  ✓ Ran npm run db:reset:test"
    elif npm run --silent db:seed:test 2>/dev/null; then
      echo "  ✓ Ran npm run db:seed:test"
    elif [ -f "prisma/schema.prisma" ]; then
      echo "  ℹ Prisma detected. Run: npx prisma db push --force-reset"
    elif [ -f "knexfile.js" ] || [ -f "knexfile.ts" ]; then
      echo "  ℹ Knex detected. Run: npx knex migrate:rollback --all && npx knex migrate:latest && npx knex seed:run"
    else
      echo "  ⚠ No known database reset command found."
      echo "    Add a 'db:reset:test' script to package.json."
    fi
  fi
  echo ""
fi

# --- Clear Cypress cache ---
if [ "$CLEAN_CACHE" = true ]; then
  echo "💾 Clearing Cypress cache..."

  CACHE_DIR="${CYPRESS_CACHE_FOLDER:-$HOME/.cache/Cypress}"

  if [ -d "$CACHE_DIR" ]; then
    local_size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] Would remove $CACHE_DIR ($local_size)"
    else
      npx cypress cache clear 2>/dev/null || rm -rf "$CACHE_DIR"
      echo "  ✓ Cleared Cypress cache ($local_size freed)"
    fi
  else
    echo "  - Cypress cache not found at $CACHE_DIR"
  fi
  echo ""
fi

# --- Summary ---
if [ "$DRY_RUN" = true ]; then
  echo "🔍 Dry run complete. $CLEANED files would be removed."
  echo "   Run without --dry-run to execute cleanup."
else
  echo "✅ Cleanup complete. $CLEANED files removed."
fi
