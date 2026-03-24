#!/usr/bin/env bash
# migrate-imports.sh — Convert @import to @use/@forward in a Sass project
#
# Usage:
#   ./migrate-imports.sh <entry-file-or-directory>
#   ./migrate-imports.sh src/styles/main.scss
#   ./migrate-imports.sh src/styles/           # finds all .scss entry points
#
# Options:
#   --dry-run    Preview changes without modifying files
#   --verbose    Show detailed output
#   --no-deps    Don't migrate dependencies (only the specified file)
#
# Prerequisites: Node.js 18+, npm
# Installs sass-migrator automatically if not found.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=false
VERBOSE=false
MIGRATE_DEPS=true
TARGET=""

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \?//'
  exit 1
}

log()   { echo -e "${GREEN}[migrate]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --verbose)  VERBOSE=true; shift ;;
    --no-deps)  MIGRATE_DEPS=false; shift ;;
    -h|--help)  usage ;;
    *)          TARGET="$1"; shift ;;
  esac
done

[[ -z "$TARGET" ]] && { error "No target specified."; usage; }

# --- Install sass-migrator if needed ---
if ! command -v sass-migrator &>/dev/null; then
  if ! npx --yes sass-migrator --version &>/dev/null 2>&1; then
    log "Installing sass-migrator..."
    npm install -g sass-migrator
  fi
fi

MIGRATOR="sass-migrator"
command -v sass-migrator &>/dev/null || MIGRATOR="npx --yes sass-migrator"

# --- Build file list ---
FILES=()
if [[ -d "$TARGET" ]]; then
  while IFS= read -r -d '' f; do
    # Skip partials (start with _) — they'll be migrated as dependencies
    base=$(basename "$f")
    [[ "$base" == _* ]] && continue
    FILES+=("$f")
  done < <(find "$TARGET" -name '*.scss' -o -name '*.sass' | tr '\n' '\0')
else
  [[ -f "$TARGET" ]] || { error "File not found: $TARGET"; exit 1; }
  FILES+=("$TARGET")
fi

[[ ${#FILES[@]} -eq 0 ]] && { error "No entry SCSS files found in $TARGET"; exit 1; }

log "Found ${#FILES[@]} entry file(s) to migrate"

# --- Pre-migration: count @import usage ---
IMPORT_COUNT=0
if [[ -d "$TARGET" ]]; then
  IMPORT_COUNT=$(grep -rl '@import' "$TARGET" --include='*.scss' --include='*.sass' 2>/dev/null | wc -l || true)
else
  IMPORT_COUNT=$(grep -c '@import' "$TARGET" 2>/dev/null || true)
fi
log "Files containing @import: $IMPORT_COUNT"

# --- Build migrator flags ---
FLAGS=(module)
$MIGRATE_DEPS && FLAGS+=(--migrate-deps)
$DRY_RUN && FLAGS+=(--dry-run)
$VERBOSE && FLAGS+=(--verbose)

# --- Run migration ---
ERRORS=0
for file in "${FILES[@]}"; do
  log "Migrating: ${BLUE}${file}${NC}"
  if $MIGRATOR "${FLAGS[@]}" "$file"; then
    [[ "$DRY_RUN" == false ]] && log "  ✅ Migrated successfully"
  else
    warn "  ⚠️  Migration had issues — review manually"
    ((ERRORS++)) || true
  fi
done

# --- Post-migration report ---
echo ""
if $DRY_RUN; then
  log "Dry run complete. No files were modified."
  log "Remove --dry-run to apply changes."
else
  REMAINING=0
  if [[ -d "$TARGET" ]]; then
    REMAINING=$(grep -rl '@import' "$TARGET" --include='*.scss' --include='*.sass' 2>/dev/null | wc -l || true)
  fi

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Migration complete!"
  log "  Entry files processed: ${#FILES[@]}"
  log "  Errors: $ERRORS"
  [[ "$REMAINING" -gt 0 ]] && warn "  Remaining @import files: $REMAINING (review manually)"

  echo ""
  log "Post-migration checklist:"
  echo "  1. Review all changes: git diff"
  echo "  2. Check for namespace issues: grep -rn 'TODO\|FIXME' --include='*.scss'"
  echo "  3. Update build config if needed (additionalData, global imports)"
  echo "  4. Run your build: npm run build"
  echo "  5. Visual regression test critical pages"
fi
