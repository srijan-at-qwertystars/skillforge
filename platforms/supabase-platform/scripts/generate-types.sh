#!/usr/bin/env bash
#
# generate-types.sh — Generate TypeScript types from a Supabase schema
#
# Usage:
#   ./generate-types.sh [--local | --project-id <id>] [--output <path>]
#
# Options:
#   --local              Generate types from the local Supabase instance (default)
#   --project-id <id>    Generate types from a remote Supabase project
#   --output <path>      Output file path (default: src/supabase.types.ts)
#   --diff               Show diff against existing types (if any)
#   --quiet              Suppress informational output
#   --help               Show this help message
#
# Examples:
#   ./generate-types.sh                                   # Local, default output
#   ./generate-types.sh --project-id abc123               # Remote project
#   ./generate-types.sh --local --output lib/db-types.ts  # Custom output path
#   ./generate-types.sh --project-id abc123 --diff        # Show what changed
#
# Requirements:
#   - Supabase CLI (npx supabase or globally installed)
#   - For --local: local Supabase instance running (supabase start)
#   - For --project-id: authenticated via `supabase login`
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants & Colors
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SOURCE="local"
PROJECT_ID=""
OUTPUT="src/supabase.types.ts"
SHOW_DIFF=false
QUIET=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { $QUIET || echo -e "${BLUE}ℹ${NC}  $*"; }
success() { $QUIET || echo -e "${GREEN}✔${NC}  $*"; }
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
    --local)        SOURCE="local"; shift ;;
    --project-id)
      [[ -z "${2:-}" ]] && fatal "--project-id requires a value"
      SOURCE="remote"; PROJECT_ID="$2"; shift 2 ;;
    --output)
      [[ -z "${2:-}" ]] && fatal "--output requires a value"
      OUTPUT="$2"; shift 2 ;;
    --diff)         SHOW_DIFF=true; shift ;;
    --quiet|-q)     QUIET=true; shift ;;
    --help|-h)      usage ;;
    *)              fatal "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight Checks
# ---------------------------------------------------------------------------

# Check Supabase CLI
SUPABASE_CMD=""
if command -v supabase &>/dev/null; then
  SUPABASE_CMD="supabase"
elif command -v npx &>/dev/null; then
  SUPABASE_CMD="npx supabase"
  info "Using npx to run Supabase CLI"
else
  fatal "Supabase CLI not found. Install with: npm install -g supabase"
fi

# Verify the CLI actually works
if ! $SUPABASE_CMD --version &>/dev/null 2>&1; then
  fatal "Supabase CLI is installed but not working. Try reinstalling."
fi
info "Using $($SUPABASE_CMD --version 2>/dev/null || echo 'supabase CLI')"

# If local mode, verify local instance is running
if [[ "$SOURCE" == "local" ]]; then
  if ! $SUPABASE_CMD status &>/dev/null 2>&1; then
    fatal "Local Supabase instance is not running. Start it with: supabase start"
  fi
  info "Local Supabase instance detected"
fi

# If remote mode, verify we have a project ID and are logged in
if [[ "$SOURCE" == "remote" ]]; then
  if [[ -z "$PROJECT_ID" ]]; then
    fatal "Project ID is required for remote type generation. Use --project-id <id>"
  fi
  info "Targeting remote project: ${PROJECT_ID}"
fi

# Ensure output directory exists
OUTPUT_DIR=$(dirname "$OUTPUT")
if [[ ! -d "$OUTPUT_DIR" ]]; then
  info "Creating output directory: ${OUTPUT_DIR}"
  mkdir -p "$OUTPUT_DIR"
fi

# ---------------------------------------------------------------------------
# Generate Types
# ---------------------------------------------------------------------------
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

info "Generating TypeScript types..."

if [[ "$SOURCE" == "local" ]]; then
  if ! $SUPABASE_CMD gen types typescript --local > "$TEMP_FILE" 2>/dev/null; then
    fatal "Type generation failed. Ensure local Supabase is running and has tables."
  fi
else
  if ! $SUPABASE_CMD gen types typescript --project-id "$PROJECT_ID" > "$TEMP_FILE" 2>/dev/null; then
    fatal "Type generation failed. Check your project ID and authentication (supabase login)."
  fi
fi

# Verify we got actual content (not an empty or error-only file)
if [[ ! -s "$TEMP_FILE" ]]; then
  fatal "Type generation produced an empty file. Ensure your database has at least one table."
fi

# Quick sanity check — generated types should contain the Database export
if ! grep -q "Database" "$TEMP_FILE" 2>/dev/null; then
  warn "Generated file does not contain a 'Database' type. The output may be incomplete."
fi

# ---------------------------------------------------------------------------
# Diff (optional)
# ---------------------------------------------------------------------------
if $SHOW_DIFF && [[ -f "$OUTPUT" ]]; then
  if diff --color=auto -u "$OUTPUT" "$TEMP_FILE" > /dev/null 2>&1; then
    success "Types are unchanged — no update needed"
    exit 0
  else
    info "Changes detected:"
    diff --color=auto -u "$OUTPUT" "$TEMP_FILE" || true
    echo ""
  fi
fi

# ---------------------------------------------------------------------------
# Write Output
# ---------------------------------------------------------------------------
# Add a header comment with generation metadata
{
  echo "// ==================================================================="
  echo "// AUTO-GENERATED — DO NOT EDIT"
  echo "// Generated by generate-types.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "// Source: ${SOURCE}${PROJECT_ID:+ (project: ${PROJECT_ID})}"
  echo "// Re-generate: ./generate-types.sh ${SOURCE == "remote" && echo "--project-id $PROJECT_ID" || echo "--local"} --output $OUTPUT"
  echo "// ==================================================================="
  echo ""
  cat "$TEMP_FILE"
} > "$OUTPUT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
LINE_COUNT=$(wc -l < "$OUTPUT")
TYPE_COUNT=$(grep -c "export type\|export interface" "$OUTPUT" 2>/dev/null || echo "0")

success "TypeScript types written to ${OUTPUT}"
info "  Lines: ${LINE_COUNT}  |  Exported types: ${TYPE_COUNT}"
