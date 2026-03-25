#!/usr/bin/env bash
# ==============================================================================
# manage-ops.sh — Common Django management operations
#
# Usage:
#   ./manage-ops.sh <command> [options]
#
# Commands:
#   migrate          Run migrations (optionally for specific app)
#   makemigrations   Create new migrations (optionally for specific app)
#   superuser        Create superuser interactively or from env vars
#   collectstatic    Collect static files for production
#   shell            Open Django shell (IPython if available)
#   test             Run test suite with coverage
#   check            Run deployment checks
#   dbshell          Open database shell
#   showmigrations   Show migration status
#   flush            Reset database (with confirmation)
#   squash           Squash migrations for an app
#   dumpdata         Export data as JSON fixture
#   loaddata         Import data from fixture
#
# Environment:
#   DJANGO_SETTINGS_MODULE  Settings module (default: config.settings)
#   DJANGO_SUPERUSER_EMAIL  Superuser email (for non-interactive creation)
#   DJANGO_SUPERUSER_PASSWORD  Superuser password
# ==============================================================================

set -euo pipefail

# --- Configuration ---
MANAGE_PY="${MANAGE_PY:-python manage.py}"
SETTINGS="${DJANGO_SETTINGS_MODULE:-config.settings}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}ℹ${NC}  $*"; }
log_ok()    { echo -e "${GREEN}✅${NC} $*"; }
log_warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
log_error() { echo -e "${RED}❌${NC} $*"; }

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in

    migrate)
        # Usage: ./manage-ops.sh migrate [app_name] [migration_name]
        APP="${1:-}"
        MIGRATION="${2:-}"
        log_info "Running migrations..."
        if [[ -n "$APP" && -n "$MIGRATION" ]]; then
            $MANAGE_PY migrate "$APP" "$MIGRATION" --settings="$SETTINGS"
        elif [[ -n "$APP" ]]; then
            $MANAGE_PY migrate "$APP" --settings="$SETTINGS"
        else
            $MANAGE_PY migrate --settings="$SETTINGS"
        fi
        log_ok "Migrations complete."
        ;;

    makemigrations)
        # Usage: ./manage-ops.sh makemigrations [app_name] [--name migration_name]
        log_info "Creating migrations..."
        $MANAGE_PY makemigrations "$@" --settings="$SETTINGS"
        log_ok "Migrations created."
        ;;

    superuser)
        # Usage: ./manage-ops.sh superuser
        # Non-interactive if DJANGO_SUPERUSER_EMAIL and DJANGO_SUPERUSER_PASSWORD are set
        if [[ -n "${DJANGO_SUPERUSER_EMAIL:-}" && -n "${DJANGO_SUPERUSER_PASSWORD:-}" ]]; then
            log_info "Creating superuser non-interactively..."
            DJANGO_SUPERUSER_USERNAME="${DJANGO_SUPERUSER_USERNAME:-admin}"
            $MANAGE_PY createsuperuser \
                --noinput \
                --username "$DJANGO_SUPERUSER_USERNAME" \
                --email "$DJANGO_SUPERUSER_EMAIL" \
                --settings="$SETTINGS" 2>/dev/null || log_warn "Superuser may already exist."
        else
            log_info "Creating superuser interactively..."
            $MANAGE_PY createsuperuser --settings="$SETTINGS"
        fi
        log_ok "Superuser ready."
        ;;

    collectstatic)
        # Usage: ./manage-ops.sh collectstatic
        log_info "Collecting static files..."
        $MANAGE_PY collectstatic --noinput --settings="$SETTINGS"
        log_ok "Static files collected."
        ;;

    shell)
        # Usage: ./manage-ops.sh shell
        log_info "Opening Django shell..."
        if python -c "import IPython" 2>/dev/null; then
            $MANAGE_PY shell -i ipython --settings="$SETTINGS"
        else
            $MANAGE_PY shell --settings="$SETTINGS"
        fi
        ;;

    test)
        # Usage: ./manage-ops.sh test [app_name] [--parallel] [--verbosity 2]
        log_info "Running tests..."
        if command -v pytest &>/dev/null; then
            pytest "$@" --ds="$SETTINGS"
        else
            $MANAGE_PY test "$@" --settings="$SETTINGS"
        fi
        log_ok "Tests complete."
        ;;

    check)
        # Usage: ./manage-ops.sh check [--deploy]
        log_info "Running system checks..."
        $MANAGE_PY check "$@" --settings="$SETTINGS"
        log_info "Running deployment checks..."
        $MANAGE_PY check --deploy --settings="$SETTINGS" 2>&1 || true
        log_ok "Checks complete."
        ;;

    dbshell)
        # Usage: ./manage-ops.sh dbshell
        log_info "Opening database shell..."
        $MANAGE_PY dbshell --settings="$SETTINGS"
        ;;

    showmigrations)
        # Usage: ./manage-ops.sh showmigrations [app_name]
        $MANAGE_PY showmigrations "$@" --settings="$SETTINGS"
        ;;

    flush)
        # Usage: ./manage-ops.sh flush
        log_warn "This will DELETE ALL DATA in the database!"
        read -r -p "Type 'yes' to confirm: " confirm
        if [[ "$confirm" == "yes" ]]; then
            $MANAGE_PY flush --settings="$SETTINGS"
            log_ok "Database flushed."
        else
            log_info "Aborted."
        fi
        ;;

    squash)
        # Usage: ./manage-ops.sh squash <app_name> <start_migration> <end_migration>
        APP="${1:?App name required}"
        START="${2:?Start migration required}"
        END="${3:?End migration required}"
        log_info "Squashing migrations for $APP: $START → $END"
        $MANAGE_PY squashmigrations "$APP" "$START" "$END" --settings="$SETTINGS"
        log_ok "Migrations squashed."
        ;;

    dumpdata)
        # Usage: ./manage-ops.sh dumpdata <app_name> [--output file.json]
        log_info "Exporting data..."
        $MANAGE_PY dumpdata "$@" --indent 2 --settings="$SETTINGS"
        ;;

    loaddata)
        # Usage: ./manage-ops.sh loaddata <fixture_file>
        log_info "Loading fixture data..."
        $MANAGE_PY loaddata "$@" --settings="$SETTINGS"
        log_ok "Data loaded."
        ;;

    help|*)
        cat << 'HELPEOF'
Django Management Operations

Usage: ./manage-ops.sh <command> [options]

Commands:
  migrate [app] [name]         Run database migrations
  makemigrations [app]         Create new migration files
  superuser                    Create superuser (env vars for non-interactive)
  collectstatic                Collect static files to STATIC_ROOT
  shell                        Open Django/IPython shell
  test [app] [opts]            Run tests (pytest if available, else manage.py test)
  check [--deploy]             Run system and deployment checks
  dbshell                      Open database shell
  showmigrations [app]         Display migration status
  flush                        Delete all data (with confirmation)
  squash <app> <start> <end>   Squash migration range
  dumpdata <app> [--output f]  Export data as JSON
  loaddata <fixture>           Import fixture data

Environment Variables:
  MANAGE_PY                    Path to manage.py (default: python manage.py)
  DJANGO_SETTINGS_MODULE       Settings module (default: config.settings)
  DJANGO_SUPERUSER_EMAIL       For non-interactive superuser creation
  DJANGO_SUPERUSER_PASSWORD    For non-interactive superuser creation
  DJANGO_SUPERUSER_USERNAME    Username (default: admin)
HELPEOF
        ;;
esac
