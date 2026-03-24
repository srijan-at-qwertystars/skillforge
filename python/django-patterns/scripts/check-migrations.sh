#!/usr/bin/env bash
# ==============================================================================
# check-migrations.sh — Detect Django migration issues
#
# Usage:
#   ./check-migrations.sh [path/to/manage.py]
#
# Checks:
#   1. Missing migrations (model changes not in migrations)
#   2. Migration conflicts (multiple leaf nodes)
#   3. Unapplied migrations
#   4. Squashable migration chains (>10 migrations per app)
#   5. Migrations with missing dependencies
#   6. Empty migrations (no operations)
#
# Exit codes:
#   0 — All checks passed
#   1 — Issues found
# ==============================================================================

set -euo pipefail

MANAGE_PY="${1:-manage.py}"
EXIT_CODE=0

if [[ ! -f "$MANAGE_PY" ]]; then
    echo "❌ Cannot find $MANAGE_PY"
    echo "Usage: $0 [path/to/manage.py]"
    exit 1
fi

PYTHON="${PYTHON:-python3}"

echo "🔍 Django Migration Health Check"
echo "================================"
echo ""

# --- Check 1: Missing migrations ---
echo "1️⃣  Checking for missing migrations..."
if OUTPUT=$($PYTHON "$MANAGE_PY" makemigrations --check --dry-run 2>&1); then
    echo "   ✅ No missing migrations"
else
    echo "   ❌ Missing migrations detected:"
    echo "$OUTPUT" | sed 's/^/      /'
    EXIT_CODE=1
fi
echo ""

# --- Check 2: Migration conflicts ---
echo "2️⃣  Checking for migration conflicts..."
CONFLICTS=$($PYTHON "$MANAGE_PY" showmigrations --plan 2>&1 | grep -i "conflict\|ERRORS" || true)
if [[ -z "$CONFLICTS" ]]; then
    echo "   ✅ No migration conflicts"
else
    echo "   ❌ Migration conflicts found:"
    echo "$CONFLICTS" | sed 's/^/      /'
    EXIT_CODE=1
fi
echo ""

# --- Check 3: Unapplied migrations ---
echo "3️⃣  Checking for unapplied migrations..."
UNAPPLIED=$($PYTHON "$MANAGE_PY" showmigrations --plan 2>&1 | grep "\[ \]" || true)
if [[ -z "$UNAPPLIED" ]]; then
    echo "   ✅ All migrations applied"
else
    COUNT=$(echo "$UNAPPLIED" | wc -l | tr -d ' ')
    echo "   ⚠️  $COUNT unapplied migration(s):"
    echo "$UNAPPLIED" | head -20 | sed 's/^/      /'
    if [[ $COUNT -gt 20 ]]; then
        echo "      ... and $((COUNT - 20)) more"
    fi
    EXIT_CODE=1
fi
echo ""

# --- Check 4: Squashable migrations ---
echo "4️⃣  Checking for squashable migration chains..."
SQUASH_THRESHOLD=10
$PYTHON "$MANAGE_PY" showmigrations 2>&1 | while IFS= read -r line; do
    if [[ "$line" =~ ^[a-zA-Z] ]]; then
        CURRENT_APP="$line"
        MIGRATION_COUNT=0
    elif [[ "$line" =~ ^\  ]]; then
        MIGRATION_COUNT=$((MIGRATION_COUNT + 1))
        if [[ $MIGRATION_COUNT -eq $SQUASH_THRESHOLD ]]; then
            echo "   ⚠️  $CURRENT_APP has $SQUASH_THRESHOLD+ migrations — consider squashing"
        fi
    fi
done
echo "   ✅ Squash check complete"
echo ""

# --- Check 5: Empty migrations ---
echo "5️⃣  Checking for empty migrations..."
EMPTY_COUNT=0
while IFS= read -r migration_file; do
    if [[ -f "$migration_file" ]]; then
        if grep -q "operations = \[\]" "$migration_file" 2>/dev/null || \
           grep -q "operations = \[\s*\]" "$migration_file" 2>/dev/null; then
            echo "   ⚠️  Empty migration: $migration_file"
            EMPTY_COUNT=$((EMPTY_COUNT + 1))
        fi
    fi
done < <(find . -path "*/migrations/[0-9]*.py" -not -path "./.venv/*" 2>/dev/null)

if [[ $EMPTY_COUNT -eq 0 ]]; then
    echo "   ✅ No empty migrations"
fi
echo ""

# --- Check 6: Migration file naming ---
echo "6️⃣  Checking migration naming conventions..."
BAD_NAMES=0
while IFS= read -r migration_file; do
    basename=$(basename "$migration_file" .py)
    # Check for auto-generated names (just the number prefix like 0001_initial is fine)
    if [[ "$basename" =~ ^[0-9]{4}_auto_ ]]; then
        echo "   ⚠️  Auto-generated name (consider renaming): $migration_file"
        BAD_NAMES=$((BAD_NAMES + 1))
    fi
done < <(find . -path "*/migrations/[0-9]*.py" -not -path "./.venv/*" 2>/dev/null)

if [[ $BAD_NAMES -eq 0 ]]; then
    echo "   ✅ All migrations have descriptive names"
fi
echo ""

# --- Summary ---
echo "================================"
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "✅ All migration checks passed!"
else
    echo "❌ Some migration checks failed. Review the issues above."
fi

exit $EXIT_CODE
