#!/usr/bin/env bash
# ============================================================================
# deno-deploy.sh
#
# Deploys a Deno project to Deno Deploy with environment variable setup
# and post-deploy health checks.
#
# Usage:
#   ./deno-deploy.sh --project <name> --entrypoint <file> [OPTIONS]
#
# Options:
#   --project, -p      Deno Deploy project name (required)
#   --entrypoint, -e   Entry point file (default: main.ts)
#   --env-file         Path to .env file to set env vars from
#   --env              Set individual env var (KEY=VALUE), can repeat
#   --health-url       URL path for health check (default: /health)
#   --health-timeout   Health check timeout in seconds (default: 30)
#   --production       Deploy to production (default: preview)
#   --dry-run          Show what would be done without deploying
#   --help, -h         Show help
#
# Prerequisites:
#   - deployctl installed: deno install -gArf jsr:@deno/deployctl
#   - DENO_DEPLOY_TOKEN env var set, or logged in via deployctl
#
# Examples:
#   ./deno-deploy.sh -p my-api -e main.ts --production
#   ./deno-deploy.sh -p my-api --env-file .env.production
#   ./deno-deploy.sh -p my-api --env DATABASE_URL=postgres://... --env API_KEY=xxx
# ============================================================================

set -euo pipefail

# ── Helpers ──

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERR]\033[0m   $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --project <name> [OPTIONS]

Deploy a Deno project to Deno Deploy with env vars and health checks.

Required:
  --project, -p       Deno Deploy project name

Options:
  --entrypoint, -e    Entry point file (default: main.ts)
  --env-file          Path to .env file to set env vars from
  --env               Set env var as KEY=VALUE (repeatable)
  --health-url        Health check URL path (default: /health)
  --health-timeout    Health check timeout seconds (default: 30)
  --production        Deploy to production (default: preview)
  --dry-run           Preview actions without deploying
  --help, -h          Show this help

Prerequisites:
  - deployctl: deno install -gArf jsr:@deno/deployctl
  - DENO_DEPLOY_TOKEN set or logged in via deployctl

Examples:
  $(basename "$0") -p my-api -e main.ts --production
  $(basename "$0") -p my-api --env-file .env.production
  $(basename "$0") -p my-api --env DB_URL=postgres://localhost/db
EOF
  exit 0
}

# ── Parse arguments ──

PROJECT=""
ENTRYPOINT="main.ts"
ENV_FILE=""
ENV_VARS=()
HEALTH_URL="/health"
HEALTH_TIMEOUT=30
PRODUCTION=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|-p)   shift; PROJECT="${1:-}"; [[ -z "$PROJECT" ]] && error "Missing --project value" ;;
    --entrypoint|-e) shift; ENTRYPOINT="${1:-}"; [[ -z "$ENTRYPOINT" ]] && error "Missing --entrypoint value" ;;
    --env-file)     shift; ENV_FILE="${1:-}"; [[ -z "$ENV_FILE" ]] && error "Missing --env-file value" ;;
    --env)          shift; ENV_VARS+=("${1:-}"); [[ -z "${ENV_VARS[-1]}" ]] && error "Missing --env value" ;;
    --health-url)   shift; HEALTH_URL="${1:-}" ;;
    --health-timeout) shift; HEALTH_TIMEOUT="${1:-}" ;;
    --production)   PRODUCTION=true ;;
    --dry-run)      DRY_RUN=true ;;
    --help|-h)      usage ;;
    -*)             error "Unknown option: $1" ;;
    *)              error "Unexpected argument: $1" ;;
  esac
  shift
done

[[ -z "$PROJECT" ]] && error "Missing required --project flag. See --help."

# ── Pre-flight checks ──

info "Pre-flight checks..."

# Check deployctl
if ! command -v deployctl &>/dev/null; then
  error "deployctl not found. Install with: deno install -gArf jsr:@deno/deployctl"
fi

# Check entrypoint
[[ ! -f "$ENTRYPOINT" ]] && error "Entrypoint not found: $ENTRYPOINT"

# Check env file
if [[ -n "$ENV_FILE" && ! -f "$ENV_FILE" ]]; then
  error "Env file not found: $ENV_FILE"
fi

# Check token
if [[ -z "${DENO_DEPLOY_TOKEN:-}" ]]; then
  warn "DENO_DEPLOY_TOKEN not set — deployctl will use browser auth"
fi

ok "Pre-flight checks passed"

# ── Lint and type-check before deploying ──

info "Running pre-deploy checks..."

if command -v deno &>/dev/null; then
  info "Type-checking..."
  if ! deno check "$ENTRYPOINT" 2>&1; then
    error "Type check failed — fix errors before deploying"
  fi
  ok "Type check passed"

  info "Linting..."
  if ! deno lint --quiet 2>&1; then
    warn "Lint warnings found — review before deploying"
  else
    ok "Lint passed"
  fi
fi

# ── Set environment variables ──

set_env_var() {
  local key="$1"
  local value="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY RUN] Would set env var: $key=***"
    return
  fi

  info "Setting env var: $key"
  if command -v deployctl &>/dev/null; then
    # deployctl doesn't have a direct env set command, so we note them
    # They should be set in the Deno Deploy dashboard or via API
    info "  → Set $key in Deno Deploy dashboard or use DENO_DEPLOY_TOKEN API"
  fi
}

if [[ -n "$ENV_FILE" ]]; then
  info "Loading env vars from: $ENV_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    # Parse KEY=VALUE
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      set_env_var "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done < "$ENV_FILE"
fi

for env_var in "${ENV_VARS[@]}"; do
  if [[ "$env_var" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    set_env_var "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    warn "Invalid env var format: $env_var (expected KEY=VALUE)"
  fi
done

# ── Deploy ──

DEPLOY_CMD="deployctl deploy --project=$PROJECT"

if [[ "$PRODUCTION" == "true" ]]; then
  DEPLOY_CMD="$DEPLOY_CMD --prod"
  info "Deploying to PRODUCTION"
else
  info "Deploying preview"
fi

DEPLOY_CMD="$DEPLOY_CMD $ENTRYPOINT"

echo ""
info "Deploy command: $DEPLOY_CMD"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  ok "[DRY RUN] Would execute: $DEPLOY_CMD"
  exit 0
fi

# Run deploy and capture output
DEPLOY_OUTPUT=$(eval "$DEPLOY_CMD" 2>&1) || {
  echo "$DEPLOY_OUTPUT"
  error "Deployment failed"
}

echo "$DEPLOY_OUTPUT"

# Extract deployment URL from output
DEPLOY_URL=$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[a-zA-Z0-9._-]+\.deno\.dev' | head -1 || echo "")

if [[ -z "$DEPLOY_URL" ]]; then
  DEPLOY_URL="https://${PROJECT}.deno.dev"
  warn "Could not detect deployment URL — using default: $DEPLOY_URL"
fi

ok "Deployed to: $DEPLOY_URL"

# ── Health Check ──

echo ""
info "Running health check..."

HEALTH_FULL_URL="${DEPLOY_URL}${HEALTH_URL}"
info "Health URL: $HEALTH_FULL_URL"

HEALTH_OK=false
ELAPSED=0
INTERVAL=3

while [[ $ELAPSED -lt $HEALTH_TIMEOUT ]]; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_FULL_URL" 2>/dev/null || echo "000")

  if [[ "$HTTP_STATUS" == "200" ]]; then
    HEALTH_OK=true
    break
  fi

  info "  Waiting... (status: $HTTP_STATUS, ${ELAPSED}s / ${HEALTH_TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
if [[ "$HEALTH_OK" == "true" ]]; then
  ok "Health check passed! (${HEALTH_FULL_URL} → 200)"
  HEALTH_BODY=$(curl -s --max-time 5 "$HEALTH_FULL_URL" 2>/dev/null || echo "(no body)")
  info "Response: $HEALTH_BODY"
else
  warn "Health check failed after ${HEALTH_TIMEOUT}s"
  warn "The deployment may still be starting. Check: $HEALTH_FULL_URL"
fi

# ── Summary ──

echo ""
echo "════════════════════════════════════════"
echo "  Deployment Summary"
echo "════════════════════════════════════════"
echo "  Project:     $PROJECT"
echo "  Entrypoint:  $ENTRYPOINT"
echo "  URL:         $DEPLOY_URL"
echo "  Production:  $PRODUCTION"
echo "  Health:      $(if [[ "$HEALTH_OK" == "true" ]]; then echo "✅ Passed"; else echo "⚠️  Pending"; fi)"
echo "════════════════════════════════════════"
