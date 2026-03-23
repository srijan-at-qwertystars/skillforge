#!/usr/bin/env bash
#
# setup-turso.sh — Initialize a new Turso project
#
# Usage:
#   ./setup-turso.sh <db-name> [group-name] [location]
#
# Examples:
#   ./setup-turso.sh myapp                    # Create DB in nearest region
#   ./setup-turso.sh myapp prod ord           # Create DB in group 'prod', location 'ord' (Chicago)
#   ./setup-turso.sh myapp prod lhr           # Create DB in group 'prod', location 'lhr' (London)
#
# Prerequisites:
#   - Turso CLI installed: curl -sSfL https://get.tur.so/install.sh | bash
#
# What this script does:
#   1. Checks if Turso CLI is installed and user is authenticated
#   2. Creates a group (if specified and doesn't exist)
#   3. Creates a database
#   4. Generates an auth token
#   5. Prints connection URL and token for use in your application
#

set -euo pipefail

DB_NAME="${1:-}"
GROUP_NAME="${2:-}"
LOCATION="${3:-}"

if [ -z "$DB_NAME" ]; then
  echo "Usage: $0 <db-name> [group-name] [location]"
  echo ""
  echo "Examples:"
  echo "  $0 myapp"
  echo "  $0 myapp prod ord"
  exit 1
fi

# --- Check prerequisites ---

if ! command -v turso &> /dev/null; then
  echo "Error: Turso CLI not found."
  echo "Install with: curl -sSfL https://get.tur.so/install.sh | bash"
  exit 1
fi

echo "==> Checking authentication..."
if ! turso auth token &> /dev/null; then
  echo "Not authenticated. Logging in..."
  turso auth login
fi
echo "    ✓ Authenticated"

# --- Create group if specified ---

if [ -n "$GROUP_NAME" ]; then
  echo "==> Checking group '$GROUP_NAME'..."
  if turso group show "$GROUP_NAME" &> /dev/null; then
    echo "    ✓ Group '$GROUP_NAME' already exists"
  else
    LOC_FLAG=""
    if [ -n "$LOCATION" ]; then
      LOC_FLAG="--location $LOCATION"
    fi
    echo "    Creating group '$GROUP_NAME'..."
    turso group create "$GROUP_NAME" $LOC_FLAG
    echo "    ✓ Group '$GROUP_NAME' created"
  fi
fi

# --- Create database ---

echo "==> Creating database '$DB_NAME'..."
CREATE_FLAGS=""
if [ -n "$GROUP_NAME" ]; then
  CREATE_FLAGS="--group $GROUP_NAME"
elif [ -n "$LOCATION" ]; then
  CREATE_FLAGS="--location $LOCATION"
fi

if turso db show "$DB_NAME" &> /dev/null; then
  echo "    ⚠ Database '$DB_NAME' already exists, skipping creation"
else
  turso db create "$DB_NAME" $CREATE_FLAGS
  echo "    ✓ Database '$DB_NAME' created"
fi

# --- Get connection details ---

echo "==> Fetching connection details..."
DB_URL=$(turso db show "$DB_NAME" --url)
echo "    URL: $DB_URL"

# --- Generate auth token ---

echo "==> Generating auth token..."
AUTH_TOKEN=$(turso db tokens create "$DB_NAME")
echo "    ✓ Token generated"

# --- Print summary ---

echo ""
echo "============================================"
echo "  Turso Database Ready"
echo "============================================"
echo ""
echo "Add these to your .env file:"
echo ""
echo "  TURSO_DATABASE_URL=$DB_URL"
echo "  TURSO_AUTH_TOKEN=$AUTH_TOKEN"
echo ""
echo "Quick test:"
echo "  turso db shell $DB_NAME \"SELECT 'Hello from Turso!'\""
echo ""
echo "Inspect:"
echo "  turso db inspect $DB_NAME"
echo "============================================"
