#!/usr/bin/env bash
# ==============================================================================
# migration-ops.sh — Common Alembic migration operations
#
# Usage:
#   ./migration-ops.sh <command> [options]
#
# Commands:
#   create <message>       Create a new auto-generated migration
#   create-empty <message> Create an empty migration (for data migrations)
#   upgrade [target]       Upgrade to target (default: head)
#   downgrade [target]     Downgrade to target (default: -1)
#   history                Show migration history
#   current                Show current revision
#   heads                  Show head revisions
#   stamp <revision>       Stamp DB as revision without running migrations
#   merge <message>        Merge multiple heads into one
#   check                  Check if migrations are needed (exit 1 if yes)
#   diff                   Show SQL that would be generated (offline mode)
#   branches               Show branch points in migration history
# ==============================================================================

set -euo pipefail

ALEMBIC_CMD="${ALEMBIC_CMD:-alembic}"
COMMAND="${1:?Usage: $0 <command> [options]. Run with 'help' for details.}"
shift

case "$COMMAND" in
    create)
        # Create a new auto-generated migration
        MESSAGE="${1:?Usage: $0 create <message>}"
        echo "📝 Creating migration: $MESSAGE"
        $ALEMBIC_CMD revision --autogenerate -m "$MESSAGE"
        echo ""
        echo "⚠️  Review the generated migration before applying!"
        echo "   Autogenerate misses: renames, data migrations, custom constraints."
        ;;

    create-empty)
        # Create an empty migration (for data migrations or custom DDL)
        MESSAGE="${1:?Usage: $0 create-empty <message>}"
        echo "📝 Creating empty migration: $MESSAGE"
        $ALEMBIC_CMD revision -m "$MESSAGE"
        echo ""
        echo "Edit the generated file to add your upgrade() and downgrade() logic."
        ;;

    upgrade)
        # Upgrade to a target revision (default: head)
        TARGET="${1:-head}"
        echo "⬆️  Upgrading to: $TARGET"
        $ALEMBIC_CMD upgrade "$TARGET"
        echo "✅ Upgrade complete."
        $ALEMBIC_CMD current
        ;;

    downgrade)
        # Downgrade to a target revision (default: -1 = one step back)
        TARGET="${1:--1}"
        echo "⬇️  Downgrading to: $TARGET"
        echo ""

        # Show current before downgrade
        echo "Current revision:"
        $ALEMBIC_CMD current
        echo ""

        read -rp "Are you sure? (y/N): " CONFIRM
        if [[ "${CONFIRM,,}" != "y" ]]; then
            echo "Aborted."
            exit 0
        fi

        $ALEMBIC_CMD downgrade "$TARGET"
        echo "✅ Downgrade complete."
        $ALEMBIC_CMD current
        ;;

    history)
        # Show migration history
        VERBOSE="${1:-}"
        if [[ "$VERBOSE" == "-v" || "$VERBOSE" == "--verbose" ]]; then
            $ALEMBIC_CMD history --verbose
        else
            $ALEMBIC_CMD history --indicate-current
        fi
        ;;

    current)
        # Show current revision(s)
        $ALEMBIC_CMD current --verbose
        ;;

    heads)
        # Show head revision(s)
        HEADS=$($ALEMBIC_CMD heads)
        HEAD_COUNT=$(echo "$HEADS" | wc -l)
        echo "$HEADS"
        if [[ "$HEAD_COUNT" -gt 1 ]]; then
            echo ""
            echo "⚠️  Multiple heads detected! Run '$0 merge <message>' to merge."
        fi
        ;;

    stamp)
        # Stamp the database with a revision without running migrations
        REVISION="${1:?Usage: $0 stamp <revision>}"
        echo "🔖 Stamping database as revision: $REVISION"
        echo "   (No migrations will be run — this only updates alembic_version)"
        read -rp "Are you sure? (y/N): " CONFIRM
        if [[ "${CONFIRM,,}" != "y" ]]; then
            echo "Aborted."
            exit 0
        fi
        $ALEMBIC_CMD stamp "$REVISION"
        echo "✅ Stamped."
        ;;

    merge)
        # Merge multiple heads into a single head
        MESSAGE="${1:-merge_heads}"
        HEADS=$($ALEMBIC_CMD heads 2>&1)
        HEAD_COUNT=$(echo "$HEADS" | grep -c "^" || true)

        if [[ "$HEAD_COUNT" -le 1 ]]; then
            echo "✅ Only one head exists — no merge needed."
            echo "$HEADS"
            exit 0
        fi

        echo "🔀 Merging $HEAD_COUNT heads: $MESSAGE"
        echo "$HEADS"
        echo ""
        $ALEMBIC_CMD merge heads -m "$MESSAGE"
        echo "✅ Merge revision created. Run '$0 upgrade' to apply."
        ;;

    check)
        # Check if there are pending migrations or model changes
        echo "🔍 Checking for pending migrations..."
        if $ALEMBIC_CMD check 2>&1; then
            echo "✅ No pending migrations."
            exit 0
        else
            echo "⚠️  Migrations are needed. Run '$0 create <message>' to generate."
            exit 1
        fi
        ;;

    diff)
        # Show the SQL that would be generated (offline/SQL mode)
        TARGET="${1:-head}"
        echo "📋 SQL diff for upgrade to $TARGET:"
        echo "---"
        $ALEMBIC_CMD upgrade "$TARGET" --sql
        ;;

    branches)
        # Show branch points
        $ALEMBIC_CMD branches --verbose
        ;;

    help|--help|-h)
        head -25 "$0" | tail -22
        ;;

    *)
        echo "Unknown command: $COMMAND"
        echo "Run '$0 help' for usage."
        exit 1
        ;;
esac
