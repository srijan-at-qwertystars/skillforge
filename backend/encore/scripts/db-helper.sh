#!/bin/bash
# Database management helpers for Encore

set -e

COMMAND=${1:-help}
SERVICE_NAME=${2:-}

case "$COMMAND" in
    reset)
        echo "🗄️  Resetting local database..."
        encore db reset
        ;;
    shell)
        echo "🐚 Opening database shell..."
        encore db shell
        ;;
    migrate)
        echo "🔄 Running database migrations..."
        encore db migrate
        ;;
    status)
        echo "📊 Database status:"
        encore db status
        ;;
    new-migration)
        if [ -z "$SERVICE_NAME" ]; then
            echo "Usage: $0 new-migration <service-name>"
            exit 1
        fi
        echo "📝 Creating new migration for service: $SERVICE_NAME"
        echo "Add your migration files to: $SERVICE_NAME/migrations/"
        echo ""
        echo "Example migration file:"
        echo "  $SERVICE_NAME/migrations/001_create_table.up.sql"
        ;;
    help|*)
        echo "Encore Database Helper"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  reset          - Reset local database"
        echo "  shell          - Open database shell (psql)"
        echo "  migrate        - Run pending migrations"
        echo "  status         - Show database status"
        echo "  new-migration <service> - Show migration creation help"
        echo ""
        ;;
esac
