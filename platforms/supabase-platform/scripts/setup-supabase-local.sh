#!/usr/bin/env bash
#
# setup-supabase-local.sh — Set up a local Supabase development environment
#
# Usage:
#   ./setup-supabase-local.sh [OPTIONS]
#
# Options:
#   --project-dir <path>   Project directory (default: current directory)
#   --skip-migration       Skip creating the sample profiles migration
#   --skip-types           Skip TypeScript type generation
#   --reset                Reset the local Supabase instance before starting
#   --help                 Show this help message
#
# This script is idempotent — safe to run multiple times. It will:
#   1. Check/install the Supabase CLI
#   2. Verify Docker is running
#   3. Initialize Supabase if not already done
#   4. Start the local Supabase stack
#   5. Create an initial migration with a profiles table (with RLS)
#   6. Generate TypeScript types from the schema
#   7. Print all local service URLs and keys
#
# Requirements:
#   - Docker Desktop (or Docker Engine + Docker Compose)
#   - Node.js/npm OR Homebrew (for CLI installation)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants & Colors
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT_DIR="."
SKIP_MIGRATION=false
SKIP_TYPES=false
RESET=false
MIGRATION_NAME="create_profiles_table"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✔${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✖${NC}  $*" >&2; }
fatal()   { error "$@"; exit 1; }

usage() {
  sed -n '3,/^$/s/^# \?//p' "$0"
  exit 0
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)   PROJECT_DIR="$2"; shift 2 ;;
    --skip-migration) SKIP_MIGRATION=true; shift ;;
    --skip-types)    SKIP_TYPES=true; shift ;;
    --reset)         RESET=true; shift ;;
    --help|-h)       usage ;;
    *)               fatal "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 1: Check / Install Supabase CLI
# ---------------------------------------------------------------------------
install_supabase_cli() {
  info "Supabase CLI not found. Attempting installation..."

  if command -v npm &>/dev/null; then
    info "Installing via npm..."
    npm install -g supabase
  elif command -v brew &>/dev/null; then
    info "Installing via Homebrew..."
    brew install supabase/tap/supabase
  else
    fatal "Neither npm nor brew found. Install one of them first, then re-run."
  fi

  command -v supabase &>/dev/null || fatal "Supabase CLI installation failed."
  success "Supabase CLI installed ($(supabase --version 2>/dev/null || echo 'unknown version'))"
}

if command -v supabase &>/dev/null; then
  success "Supabase CLI found ($(supabase --version 2>/dev/null || echo 'unknown version'))"
else
  install_supabase_cli
fi

# ---------------------------------------------------------------------------
# Step 2: Check Docker
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  fatal "Docker is not installed. Install Docker Desktop and try again."
fi

if ! docker info &>/dev/null 2>&1; then
  fatal "Docker daemon is not running. Start Docker Desktop and try again."
fi
success "Docker is running"

# ---------------------------------------------------------------------------
# Step 3: Navigate to project directory
# ---------------------------------------------------------------------------
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
info "Working in $(pwd)"

# ---------------------------------------------------------------------------
# Step 4: Initialize Supabase (idempotent)
# ---------------------------------------------------------------------------
if [[ -f "supabase/config.toml" ]]; then
  success "Supabase already initialized (supabase/config.toml exists)"
else
  info "Initializing Supabase project..."
  supabase init
  success "Supabase initialized"
fi

# ---------------------------------------------------------------------------
# Step 5: Optionally reset, then start local services
# ---------------------------------------------------------------------------
if $RESET; then
  warn "Resetting local Supabase instance..."
  supabase stop --no-backup 2>/dev/null || true
fi

info "Starting local Supabase services (this may take a minute on first run)..."
if supabase start 2>&1; then
  success "Local Supabase services are running"
else
  # supabase start returns non-zero if already running in some versions
  if supabase status &>/dev/null 2>&1; then
    success "Local Supabase services were already running"
  else
    fatal "Failed to start local Supabase services. Check Docker logs."
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: Create sample migration (idempotent)
# ---------------------------------------------------------------------------
if ! $SKIP_MIGRATION; then
  # Check if a migration with this name already exists
  if find supabase/migrations -name "*${MIGRATION_NAME}*" 2>/dev/null | grep -q .; then
    success "Migration '${MIGRATION_NAME}' already exists — skipping"
  else
    info "Creating sample profiles migration..."

    # Generate a new migration file
    MIGRATION_OUTPUT=$(supabase migration new "$MIGRATION_NAME" 2>&1)
    # Extract the file path from output; fall back to finding the newest file
    MIGRATION_FILE=$(find supabase/migrations -name "*${MIGRATION_NAME}*" -type f | sort | tail -1)

    if [[ -z "$MIGRATION_FILE" ]]; then
      fatal "Could not locate migration file after creation."
    fi

    cat > "$MIGRATION_FILE" << 'SQL'
-- ==========================================================================
-- Migration: create_profiles_table
-- Creates a public.profiles table with Row Level Security (RLS) enabled.
-- Users can only read/write their own profile.
-- ==========================================================================

-- 1. Create the profiles table
CREATE TABLE IF NOT EXISTS public.profiles (
  id          uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username    text UNIQUE,
  full_name   text,
  avatar_url  text,
  bio         text,
  website     text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- 2. Add a comment for documentation
COMMENT ON TABLE public.profiles IS 'User profile data, one row per auth.users entry.';

-- 3. Enable RLS — no access unless explicit policies are defined
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- 4. Policy: anyone can read profiles (public directory)
CREATE POLICY "Profiles are viewable by everyone"
  ON public.profiles
  FOR SELECT
  USING (true);

-- 5. Policy: users can insert their own profile
CREATE POLICY "Users can create their own profile"
  ON public.profiles
  FOR INSERT
  WITH CHECK (auth.uid() = id);

-- 6. Policy: users can update their own profile
CREATE POLICY "Users can update their own profile"
  ON public.profiles
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- 7. Policy: users can delete their own profile
CREATE POLICY "Users can delete their own profile"
  ON public.profiles
  FOR DELETE
  USING (auth.uid() = id);

-- 8. Index for faster lookups by username
CREATE INDEX IF NOT EXISTS idx_profiles_username ON public.profiles (username);

-- 9. Trigger to auto-update updated_at on row changes
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_profiles_updated
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_updated_at();

-- 10. Automatically create a profile when a new user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.raw_user_meta_data ->> 'full_name',
    NEW.raw_user_meta_data ->> 'avatar_url'
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();
SQL

    # Apply the migration to the running local instance
    info "Applying migration to local database..."
    if supabase db reset --no-seed 2>&1; then
      success "Migration applied successfully"
    else
      warn "Could not auto-apply migration. Run 'supabase db reset' manually."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 7: Generate TypeScript types
# ---------------------------------------------------------------------------
if ! $SKIP_TYPES; then
  info "Generating TypeScript types..."
  mkdir -p src
  if supabase gen types typescript --local > src/supabase.types.ts 2>/dev/null; then
    success "TypeScript types written to src/supabase.types.ts"
  else
    warn "Type generation failed — this is normal if no tables exist yet."
  fi
fi

# ---------------------------------------------------------------------------
# Step 8: Print local service details
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Local Supabase Environment Ready${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
supabase status 2>/dev/null || true
echo ""
echo -e "${BOLD}Quick tips:${NC}"
echo "  • Dashboard:      http://127.0.0.1:54323"
echo "  • API:            http://127.0.0.1:54321"
echo "  • DB (psql):      postgresql://postgres:postgres@127.0.0.1:54322/postgres"
echo "  • Studio:         http://127.0.0.1:54323"
echo "  • Inbucket (mail):http://127.0.0.1:54324"
echo ""
echo "  supabase stop        — stop all services"
echo "  supabase db reset    — reset DB and re-run migrations"
echo "  supabase migration new <name> — create a new migration"
echo ""
success "Setup complete!"
