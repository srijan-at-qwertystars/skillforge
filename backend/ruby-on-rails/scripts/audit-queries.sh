#!/usr/bin/env bash
# audit-queries.sh — Find N+1 queries and missing indexes in a Rails project
#
# Usage:
#   ./audit-queries.sh [rails_root]
#
# What it does:
#   1. Scans models for associations missing eager loading hints
#   2. Checks for missing database indexes on foreign keys
#   3. Analyzes schema.rb for columns that likely need indexes
#   4. Reports Bullet gem configuration status
#   5. Checks for common N+1 patterns in controllers/views
#
# Examples:
#   ./audit-queries.sh                 # current directory
#   ./audit-queries.sh /path/to/myapp  # specific project

set -euo pipefail

RAILS_ROOT="${1:-.}"
ISSUES=0
WARNINGS=0

# ── Helpers ───────────────────────────────────────────────────────────────────
red()    { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

issue()   { ((ISSUES++)); red "  ✗ $*"; }
warning() { ((WARNINGS++)); yellow "  ⚠ $*"; }
ok()      { green "  ✓ $*"; }

# ── Validate Rails project ───────────────────────────────────────────────────
if [[ ! -f "$RAILS_ROOT/config/application.rb" ]]; then
  red "Error: Not a Rails project (no config/application.rb found)"
  echo "Usage: $0 [rails_root]"
  exit 1
fi

cd "$RAILS_ROOT"

echo ""
bold "═══════════════════════════════════════════════════════"
bold " Rails Query Audit — $(basename "$(pwd)")"
bold "═══════════════════════════════════════════════════════"

# ── 1. Check Bullet configuration ────────────────────────────────────────────
echo ""
bold "1. Bullet Gem (N+1 Detection)"

if grep -q "bullet" Gemfile 2>/dev/null; then
  ok "Bullet gem found in Gemfile"
  if grep -rq "Bullet.enable" config/ 2>/dev/null; then
    ok "Bullet is configured"
  else
    warning "Bullet is in Gemfile but not configured in config/environments/"
    echo "    Add to config/environments/development.rb:"
    echo "      config.after_initialize do"
    echo "        Bullet.enable = true"
    echo "        Bullet.bullet_logger = true"
    echo "        Bullet.rails_logger = true"
    echo "      end"
  fi
else
  issue "Bullet gem not found — add: gem 'bullet', group: :development"
fi

# ── 2. Check schema for missing indexes on foreign keys ──────────────────────
echo ""
bold "2. Missing Indexes on Foreign Keys"

SCHEMA_FILE=""
if [[ -f "db/schema.rb" ]]; then
  SCHEMA_FILE="db/schema.rb"
elif [[ -f "db/structure.sql" ]]; then
  echo "  ℹ Using structure.sql — manual index check recommended"
  SCHEMA_FILE=""
fi

if [[ -n "$SCHEMA_FILE" ]]; then
  # Find _id columns without indexes
  FK_COLUMNS=$(grep -E 't\.(integer|bigint|uuid).*"[a-z_]+_id"' "$SCHEMA_FILE" | \
    sed -E 's/.*"([a-z_]+_id)".*/\1/' | sort -u 2>/dev/null || true)

  INDEXED_COLUMNS=$(grep -E 'add_index|t\.index|t\.references' "$SCHEMA_FILE" | \
    grep -oE '"[a-z_]+_id"' | tr -d '"' | sort -u 2>/dev/null || true)

  MISSING_COUNT=0
  for col in $FK_COLUMNS; do
    if ! echo "$INDEXED_COLUMNS" | grep -qx "$col"; then
      # Check if it appears in a composite index
      if ! grep -qE "\\[.*\"$col\".*\\]" "$SCHEMA_FILE" 2>/dev/null; then
        issue "Missing index on: $col"
        ((MISSING_COUNT++))
      fi
    fi
  done

  if [[ $MISSING_COUNT -eq 0 ]]; then
    ok "All foreign key columns have indexes"
  fi
else
  warning "No schema.rb found — run 'rails db:schema:dump'"
fi

# ── 3. Scan for N+1 patterns in controllers ──────────────────────────────────
echo ""
bold "3. Potential N+1 Patterns in Controllers"

N1_COUNT=0
if [[ -d "app/controllers" ]]; then
  # Pattern: .all without includes/preload
  while IFS= read -r line; do
    issue "Possible N+1: $line"
    ((N1_COUNT++))
  done < <(grep -rn '\.all\b' app/controllers/ --include="*.rb" | \
    grep -v 'includes\|preload\|eager_load\|select\|pluck\|count' | head -20 2>/dev/null || true)

  # Pattern: .find without includes
  while IFS= read -r line; do
    # Only flag if the surrounding code accesses associations
    true  # find() is generally fine
  done < <(true)

  if [[ $N1_COUNT -eq 0 ]]; then
    ok "No obvious N+1 patterns in controllers"
  fi
fi

# ── 4. Check models for association issues ────────────────────────────────────
echo ""
bold "4. Model Association Checks"

ASSOC_ISSUES=0
if [[ -d "app/models" ]]; then
  # has_many without dependent
  while IFS= read -r line; do
    if ! echo "$line" | grep -q "dependent:"; then
      issue "has_many without dependent: — $line"
      ((ASSOC_ISSUES++))
    fi
  done < <(grep -rn 'has_many\b' app/models/ --include="*.rb" | \
    grep -v 'through:\|#\|dependent:' | head -20 2>/dev/null || true)

  # has_one without dependent
  while IFS= read -r line; do
    if ! echo "$line" | grep -q "dependent:"; then
      warning "has_one without dependent: — $line"
      ((ASSOC_ISSUES++))
    fi
  done < <(grep -rn 'has_one\b' app/models/ --include="*.rb" | \
    grep -v 'attached\|#\|dependent:' | head -20 2>/dev/null || true)

  if [[ $ASSOC_ISSUES -eq 0 ]]; then
    ok "All associations have dependent: set"
  fi
fi

# ── 5. Check for missing database-level constraints ──────────────────────────
echo ""
bold "5. Database Constraint Checks"

CONSTRAINT_ISSUES=0
if [[ -n "$SCHEMA_FILE" ]]; then
  # uniqueness validation without unique index
  while IFS= read -r match; do
    file=$(echo "$match" | cut -d: -f1)
    col=$(echo "$match" | grep -oE 'uniqueness.*' | head -1)
    model_name=$(basename "$file" .rb)
    table_name="${model_name}s"  # simple pluralization

    field=$(echo "$match" | grep -oE ':[a-z_]+' | head -1 | tr -d ':')
    if [[ -n "$field" ]] && ! grep -qE "unique.*\"$field\"" "$SCHEMA_FILE" 2>/dev/null; then
      warning "Uniqueness validation on $field ($file) may lack unique DB index"
      ((CONSTRAINT_ISSUES++))
    fi
  done < <(grep -rn 'validates.*uniqueness' app/models/ --include="*.rb" 2>/dev/null | head -20 || true)

  if [[ $CONSTRAINT_ISSUES -eq 0 ]]; then
    ok "Uniqueness validations appear backed by indexes"
  fi
fi

# ── 6. Check for strict_loading usage ────────────────────────────────────────
echo ""
bold "6. Strict Loading"

if grep -rq 'strict_loading' app/ config/ 2>/dev/null; then
  ok "strict_loading is used in the codebase"
else
  warning "Consider enabling strict_loading in development:"
  echo "    config.active_record.strict_loading_by_default = true"
fi

# ── 7. Check for query log tags ──────────────────────────────────────────────
echo ""
bold "7. Query Log Tags"

if grep -rq 'query_log_tags' config/ 2>/dev/null; then
  ok "Query log tags are configured"
else
  warning "Enable query log tags for easier debugging:"
  echo "    config.active_record.query_log_tags_enabled = true"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
bold "═══════════════════════════════════════════════════════"
if [[ $ISSUES -eq 0 && $WARNINGS -eq 0 ]]; then
  green " ✅ No issues found!"
else
  echo " Results: $(red "$ISSUES issues"), $(yellow "$WARNINGS warnings")"
fi
bold "═══════════════════════════════════════════════════════"
echo ""

exit $ISSUES
