#!/usr/bin/env bash
#
# rls-audit.sh — Audit Row Level Security (RLS) policies on a Supabase database
#
# Usage:
#   ./rls-audit.sh [OPTIONS]
#
# Options:
#   --local                  Connect to local Supabase (default)
#   --connection-string <s>  Use a custom PostgreSQL connection string
#   --schema <name>          Schema to audit (default: public)
#   --verbose                Show detailed policy definitions
#   --json                   Output results as JSON
#   --help                   Show this help message
#
# Examples:
#   ./rls-audit.sh                                          # Audit local instance
#   ./rls-audit.sh --connection-string "postgresql://..."   # Audit remote DB
#   ./rls-audit.sh --schema public --verbose                # Verbose audit
#
# Requirements:
#   - psql (PostgreSQL client) — usually bundled with PostgreSQL or libpq
#   - For --local: local Supabase instance running (supabase start)
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
readonly DIM='\033[2m'
readonly NC='\033[0m'

readonly PASS="${GREEN}✔ PASS${NC}"
readonly FAIL="${RED}✖ FAIL${NC}"
readonly WARN="${YELLOW}⚠ WARN${NC}"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CONNECTION_STRING="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
SCHEMA="public"
VERBOSE=false
JSON_OUTPUT=false
ISSUES_FOUND=0
WARNINGS_FOUND=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✔${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; WARNINGS_FOUND=$((WARNINGS_FOUND + 1)); }
error()   { echo -e "${RED}✖${NC}  $*" >&2; ISSUES_FOUND=$((ISSUES_FOUND + 1)); }
fatal()   { echo -e "${RED}✖${NC}  $*" >&2; exit 1; }

section() {
  echo ""
  echo -e "${BOLD}━━━ $* ━━━${NC}"
  echo ""
}

usage() {
  sed -n '3,/^$/s/^# \?//p' "$0"
  exit 0
}

# Run a psql query and return the result. Exits on connection failure.
run_query() {
  local query="$1"
  psql "$CONNECTION_STRING" \
    --no-psqlrc \
    --tuples-only \
    --no-align \
    --field-separator='|' \
    --quiet \
    -c "$query" 2>/dev/null \
  || fatal "Database query failed. Check your connection string."
}

# Run a psql query and return formatted table output.
run_query_table() {
  local query="$1"
  psql "$CONNECTION_STRING" \
    --no-psqlrc \
    --quiet \
    -c "$query" 2>/dev/null \
  || fatal "Database query failed. Check your connection string."
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)              CONNECTION_STRING="postgresql://postgres:postgres@127.0.0.1:54322/postgres"; shift ;;
    --connection-string)
      [[ -z "${2:-}" ]] && fatal "--connection-string requires a value"
      CONNECTION_STRING="$2"; shift 2 ;;
    --schema)
      [[ -z "${2:-}" ]] && fatal "--schema requires a value"
      SCHEMA="$2"; shift 2 ;;
    --verbose)            VERBOSE=true; shift ;;
    --json)               JSON_OUTPUT=true; shift ;;
    --help|-h)            usage ;;
    *)                    fatal "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight Checks
# ---------------------------------------------------------------------------
if ! command -v psql &>/dev/null; then
  fatal "psql not found. Install PostgreSQL client: apt install postgresql-client / brew install libpq"
fi

# Test connection
if ! psql "$CONNECTION_STRING" --no-psqlrc -c "SELECT 1" &>/dev/null 2>&1; then
  fatal "Cannot connect to database. Verify the connection string or start local Supabase."
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║             Supabase RLS Security Audit                     ║${NC}"
echo -e "${BOLD}║             Schema: ${SCHEMA}$(printf '%*s' $((38 - ${#SCHEMA})) '')║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

# ---------------------------------------------------------------------------
# Audit 1: Tables WITHOUT RLS enabled
# ---------------------------------------------------------------------------
section "1. Tables WITHOUT RLS Enabled"

NO_RLS_TABLES=$(run_query "
  SELECT tablename
  FROM pg_tables
  WHERE schemaname = '${SCHEMA}'
    AND tablename NOT LIKE 'pg_%'
    AND tablename NOT LIKE '__%'
  EXCEPT
  SELECT relname
  FROM pg_class
  JOIN pg_namespace ON pg_namespace.oid = relnamespace
  WHERE nspname = '${SCHEMA}'
    AND relrowsecurity = true;
")

if [[ -z "$NO_RLS_TABLES" ]]; then
  echo -e "  ${PASS}  All tables in '${SCHEMA}' have RLS enabled"
else
  echo -e "  ${FAIL}  The following tables do NOT have RLS enabled:"
  echo ""
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    echo -e "    ${RED}•${NC} ${table}"
  done <<< "$NO_RLS_TABLES"
  echo ""
  echo -e "  ${DIM}Fix: ALTER TABLE ${SCHEMA}.<table> ENABLE ROW LEVEL SECURITY;${NC}"
  ISSUES_FOUND=$((ISSUES_FOUND + $(echo "$NO_RLS_TABLES" | grep -c . || true)))
fi

# ---------------------------------------------------------------------------
# Audit 2: Tables WITH RLS but NO policies (locked out)
# ---------------------------------------------------------------------------
section "2. Tables with RLS Enabled but NO Policies"

RLS_NO_POLICIES=$(run_query "
  SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}'
    AND c.relkind = 'r'
    AND c.relrowsecurity = true
    AND NOT EXISTS (
      SELECT 1
      FROM pg_policy p
      WHERE p.polrelid = c.oid
    );
")

if [[ -z "$RLS_NO_POLICIES" ]]; then
  echo -e "  ${PASS}  All RLS-enabled tables have at least one policy"
else
  echo -e "  ${WARN}  The following tables have RLS ON but no policies (all access blocked):"
  echo ""
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    echo -e "    ${YELLOW}•${NC} ${table}"
  done <<< "$RLS_NO_POLICIES"
  echo ""
  echo -e "  ${DIM}This means ALL queries to these tables will return empty / be denied.${NC}"
fi

# ---------------------------------------------------------------------------
# Audit 3: Permissive policies (potential over-exposure)
# ---------------------------------------------------------------------------
section "3. Overly Permissive Policies"

PERMISSIVE_POLICIES=$(run_query "
  SELECT
    c.relname AS table_name,
    p.polname AS policy_name,
    p.polcmd  AS command,
    pg_get_expr(p.polqual, p.polrelid, true) AS using_expr,
    pg_get_expr(p.polwithcheck, p.polrelid, true) AS check_expr
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}'
    AND p.polpermissive = true
    AND (
      pg_get_expr(p.polqual, p.polrelid, true) = 'true'
      OR pg_get_expr(p.polwithcheck, p.polrelid, true) = 'true'
    );
")

if [[ -z "$PERMISSIVE_POLICIES" ]]; then
  echo -e "  ${PASS}  No policies found using bare 'true' as expression"
else
  echo -e "  ${WARN}  Policies using 'true' expression (unrestricted access):"
  echo ""
  while IFS='|' read -r table policy cmd using_expr check_expr; do
    [[ -z "$table" ]] && continue
    # Translate command code to human-readable form
    case "$cmd" in
      r) cmd_str="SELECT" ;;
      a) cmd_str="INSERT" ;;
      w) cmd_str="UPDATE" ;;
      d) cmd_str="DELETE" ;;
      '*') cmd_str="ALL" ;;
      *)  cmd_str="$cmd" ;;
    esac
    echo -e "    ${YELLOW}•${NC} ${BOLD}${table}${NC}.${policy} (${cmd_str})"
    [[ "$using_expr" == "true" ]] && echo -e "      USING: ${RED}true${NC} — allows all rows"
    [[ "$check_expr" == "true" ]] && echo -e "      WITH CHECK: ${RED}true${NC} — allows all writes"
  done <<< "$PERMISSIVE_POLICIES"
  echo ""
  echo -e "  ${DIM}Tip: SELECT policies with 'true' may be intentional (public data).${NC}"
  echo -e "  ${DIM}     INSERT/UPDATE/DELETE with 'true' is usually a security risk.${NC}"
fi

# ---------------------------------------------------------------------------
# Audit 4: All policies grouped by table
# ---------------------------------------------------------------------------
section "4. All Policies by Table"

ALL_POLICIES=$(run_query "
  SELECT
    c.relname,
    p.polname,
    CASE p.polcmd
      WHEN 'r' THEN 'SELECT'
      WHEN 'a' THEN 'INSERT'
      WHEN 'w' THEN 'UPDATE'
      WHEN 'd' THEN 'DELETE'
      WHEN '*' THEN 'ALL'
      ELSE p.polcmd::text
    END,
    CASE WHEN p.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
    COALESCE(pg_get_expr(p.polqual, p.polrelid, true), '-'),
    COALESCE(pg_get_expr(p.polwithcheck, p.polrelid, true), '-')
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}'
  ORDER BY c.relname, p.polname;
")

if [[ -z "$ALL_POLICIES" ]]; then
  echo -e "  ${DIM}No policies found in schema '${SCHEMA}'${NC}"
else
  CURRENT_TABLE=""
  while IFS='|' read -r table policy cmd perm using_expr check_expr; do
    [[ -z "$table" ]] && continue
    if [[ "$table" != "$CURRENT_TABLE" ]]; then
      [[ -n "$CURRENT_TABLE" ]] && echo ""
      echo -e "  ${BOLD}${table}${NC}"
      CURRENT_TABLE="$table"
    fi
    echo -e "    ${GREEN}→${NC} ${policy} (${cmd}, ${perm})"
    if $VERBOSE; then
      echo -e "      ${DIM}USING:      ${using_expr}${NC}"
      echo -e "      ${DIM}WITH CHECK: ${check_expr}${NC}"
    fi
  done <<< "$ALL_POLICIES"
fi

# ---------------------------------------------------------------------------
# Audit 5: Anti-pattern detection
# ---------------------------------------------------------------------------
section "5. Anti-Pattern Detection"

# 5a. Check for policies referencing auth.uid() in INSERT USING (should be WITH CHECK)
INSERT_USING_AUTH=$(run_query "
  SELECT c.relname, p.polname
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}'
    AND p.polcmd = 'a'
    AND pg_get_expr(p.polqual, p.polrelid, true) LIKE '%auth.uid()%';
")

if [[ -z "$INSERT_USING_AUTH" ]]; then
  echo -e "  ${PASS}  No INSERT policies misusing USING clause"
else
  echo -e "  ${WARN}  INSERT policies with auth.uid() in USING (should use WITH CHECK):"
  while IFS='|' read -r table policy; do
    [[ -z "$table" ]] && continue
    echo -e "    ${YELLOW}•${NC} ${table}.${policy}"
  done <<< "$INSERT_USING_AUTH"
fi

# 5b. Check for DELETE/UPDATE policies without USING clause
MISSING_USING=$(run_query "
  SELECT c.relname, p.polname,
    CASE p.polcmd WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}'
    AND p.polcmd IN ('w', 'd')
    AND pg_get_expr(p.polqual, p.polrelid, true) IS NULL;
")

if [[ -z "$MISSING_USING" ]]; then
  echo -e "  ${PASS}  All UPDATE/DELETE policies have USING clauses"
else
  echo -e "  ${FAIL}  UPDATE/DELETE policies missing USING clause:"
  while IFS='|' read -r table policy cmd; do
    [[ -z "$table" ]] && continue
    echo -e "    ${RED}•${NC} ${table}.${policy} (${cmd})"
  done <<< "$MISSING_USING"
fi

# 5c. Check for service_role references in policies (may indicate misconfiguration)
SERVICE_ROLE=$(run_query "
  SELECT c.relname, p.polname
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}'
    AND (
      pg_get_expr(p.polqual, p.polrelid, true) LIKE '%service_role%'
      OR pg_get_expr(p.polwithcheck, p.polrelid, true) LIKE '%service_role%'
    );
")

if [[ -z "$SERVICE_ROLE" ]]; then
  echo -e "  ${PASS}  No policies reference service_role (good — use admin client instead)"
else
  echo -e "  ${WARN}  Policies referencing service_role:"
  while IFS='|' read -r table policy; do
    [[ -z "$table" ]] && continue
    echo -e "    ${YELLOW}•${NC} ${table}.${policy}"
  done <<< "$SERVICE_ROLE"
  echo -e "  ${DIM}Tip: service_role bypasses RLS. Use the admin client instead of policy exceptions.${NC}"
fi

# ---------------------------------------------------------------------------
# Audit 6: Missing indexes on foreign key / RLS-referenced columns
# ---------------------------------------------------------------------------
section "6. Missing Indexes on Foreign Key Columns"

MISSING_FK_INDEXES=$(run_query "
  SELECT
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS referenced_table
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
  WHERE tc.constraint_type = 'FOREIGN KEY'
    AND tc.table_schema = '${SCHEMA}'
    AND NOT EXISTS (
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = '${SCHEMA}'
        AND tablename = tc.table_name
        AND indexdef LIKE '%' || kcu.column_name || '%'
    );
")

if [[ -z "$MISSING_FK_INDEXES" ]]; then
  echo -e "  ${PASS}  All foreign key columns have indexes"
else
  echo -e "  ${WARN}  Foreign key columns without indexes (may slow RLS evaluation):"
  echo ""
  while IFS='|' read -r table column ref_table; do
    [[ -z "$table" ]] && continue
    echo -e "    ${YELLOW}•${NC} ${table}.${column} → ${ref_table}"
    echo -e "      ${DIM}Fix: CREATE INDEX idx_${table}_${column} ON ${SCHEMA}.${table} (${column});${NC}"
  done <<< "$MISSING_FK_INDEXES"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"

TOTAL_TABLES=$(run_query "
  SELECT COUNT(*)
  FROM pg_tables
  WHERE schemaname = '${SCHEMA}'
    AND tablename NOT LIKE 'pg_%'
    AND tablename NOT LIKE '__%';
" | tr -d ' ')

TOTAL_POLICIES=$(run_query "
  SELECT COUNT(*)
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}';
" | tr -d ' ')

RLS_ENABLED=$(run_query "
  SELECT COUNT(*)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${SCHEMA}'
    AND c.relkind = 'r'
    AND c.relrowsecurity = true;
" | tr -d ' ')

echo -e "  Tables in schema:     ${BOLD}${TOTAL_TABLES}${NC}"
echo -e "  Tables with RLS:      ${BOLD}${RLS_ENABLED}${NC} / ${TOTAL_TABLES}"
echo -e "  Total policies:       ${BOLD}${TOTAL_POLICIES}${NC}"
echo -e "  Critical issues:      ${ISSUES_FOUND:+${RED}}${ISSUES_FOUND}${NC}"
echo -e "  Warnings:             ${WARNINGS_FOUND:+${YELLOW}}${WARNINGS_FOUND}${NC}"
echo ""

if [[ $ISSUES_FOUND -gt 0 ]]; then
  echo -e "  ${FAIL}  ${RED}${ISSUES_FOUND} critical issue(s) found — review and fix before deploying${NC}"
  exit 1
elif [[ $WARNINGS_FOUND -gt 0 ]]; then
  echo -e "  ${WARN}  ${YELLOW}${WARNINGS_FOUND} warning(s) — review recommended${NC}"
  exit 0
else
  echo -e "  ${PASS}  ${GREEN}All checks passed — RLS configuration looks good!${NC}"
  exit 0
fi
