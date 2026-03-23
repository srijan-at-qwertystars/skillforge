#!/usr/bin/env bash
#
# db-management.sh — Common Turso CLI database operations
#
# Usage:
#   ./db-management.sh <command> [args...]
#
# Commands:
#   list                          List all databases
#   info <db-name>                Show database details and storage info
#   inspect <db-name>             Detailed storage inspection (tables, rows)
#   shell <db-name> [sql]         Open interactive shell or run SQL
#   replicate <db-name> <location> Add a replica location
#   unreplicate <db-name> <loc>   Remove a replica location
#   destroy <db-name>             Delete a database (with confirmation)
#   token <db-name> [expiry]      Generate auth token (default: 365d)
#   locations                     List all available locations
#   usage                         Show account billing/usage
#
# Examples:
#   ./db-management.sh list
#   ./db-management.sh info myapp
#   ./db-management.sh inspect myapp
#   ./db-management.sh shell myapp "SELECT count(*) FROM users"
#   ./db-management.sh replicate myapp lhr
#   ./db-management.sh destroy myapp
#   ./db-management.sh token myapp 30d
#

set -euo pipefail

COMMAND="${1:-}"
shift 2>/dev/null || true

if ! command -v turso &> /dev/null; then
  echo "Error: Turso CLI not found."
  echo "Install with: curl -sSfL https://get.tur.so/install.sh | bash"
  exit 1
fi

case "$COMMAND" in
  list)
    echo "==> Databases:"
    turso db list
    ;;

  info)
    DB_NAME="${1:?Error: db-name required. Usage: $0 info <db-name>}"
    echo "==> Database info: $DB_NAME"
    turso db show "$DB_NAME"
    echo ""
    echo "==> Connection URL:"
    turso db show "$DB_NAME" --url
    ;;

  inspect)
    DB_NAME="${1:?Error: db-name required. Usage: $0 inspect <db-name>}"
    echo "==> Inspecting '$DB_NAME' (storage, tables, rows)..."
    turso db inspect "$DB_NAME" --verbose
    ;;

  shell)
    DB_NAME="${1:?Error: db-name required. Usage: $0 shell <db-name> [sql]}"
    shift
    SQL="${*:-}"
    if [ -n "$SQL" ]; then
      turso db shell "$DB_NAME" "$SQL"
    else
      echo "==> Opening interactive shell for '$DB_NAME'..."
      echo "    Type .quit to exit"
      turso db shell "$DB_NAME"
    fi
    ;;

  replicate)
    DB_NAME="${1:?Error: db-name required. Usage: $0 replicate <db-name> <location>}"
    LOCATION="${2:?Error: location required. Usage: $0 replicate <db-name> <location>}"
    echo "==> Adding replica location '$LOCATION' to '$DB_NAME'..."
    GROUP=$(turso db show "$DB_NAME" 2>/dev/null | grep -i group | awk '{print $NF}')
    if [ -z "$GROUP" ]; then
      echo "Error: Could not determine group for database '$DB_NAME'"
      exit 1
    fi
    turso group locations add "$GROUP" "$LOCATION"
    echo "    ✓ Location '$LOCATION' added to group '$GROUP'"
    ;;

  unreplicate)
    DB_NAME="${1:?Error: db-name required. Usage: $0 unreplicate <db-name> <location>}"
    LOCATION="${2:?Error: location required. Usage: $0 unreplicate <db-name> <location>}"
    GROUP=$(turso db show "$DB_NAME" 2>/dev/null | grep -i group | awk '{print $NF}')
    if [ -z "$GROUP" ]; then
      echo "Error: Could not determine group for database '$DB_NAME'"
      exit 1
    fi
    echo "==> Removing location '$LOCATION' from group '$GROUP'..."
    turso group locations remove "$GROUP" "$LOCATION"
    echo "    ✓ Location '$LOCATION' removed"
    ;;

  destroy)
    DB_NAME="${1:?Error: db-name required. Usage: $0 destroy <db-name>}"
    echo "==> About to DESTROY database '$DB_NAME'"
    echo "    This action is irreversible!"
    read -p "    Type the database name to confirm: " CONFIRM
    if [ "$CONFIRM" = "$DB_NAME" ]; then
      turso db destroy "$DB_NAME" --yes
      echo "    ✓ Database '$DB_NAME' destroyed"
    else
      echo "    ✗ Confirmation failed. Aborting."
      exit 1
    fi
    ;;

  token)
    DB_NAME="${1:?Error: db-name required. Usage: $0 token <db-name> [expiry]}"
    EXPIRY="${2:-365d}"
    echo "==> Generating token for '$DB_NAME' (expires: $EXPIRY)..."
    TOKEN=$(turso db tokens create "$DB_NAME" --expiration "$EXPIRY")
    echo ""
    echo "Token:"
    echo "$TOKEN"
    echo ""
    echo "Set in your environment:"
    echo "  export TURSO_AUTH_TOKEN=\"$TOKEN\""
    ;;

  locations)
    echo "==> Available Turso locations:"
    turso db locations
    ;;

  usage)
    echo "==> Account usage:"
    turso org billing
    echo ""
    turso plan show
    ;;

  *)
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  list                            List all databases"
    echo "  info <db-name>                  Show database details"
    echo "  inspect <db-name>               Storage inspection"
    echo "  shell <db-name> [sql]           Interactive shell or run SQL"
    echo "  replicate <db-name> <location>  Add replica location"
    echo "  unreplicate <db-name> <loc>     Remove replica location"
    echo "  destroy <db-name>               Delete database"
    echo "  token <db-name> [expiry]        Generate auth token"
    echo "  locations                       List available locations"
    echo "  usage                           Show billing/usage"
    exit 1
    ;;
esac
