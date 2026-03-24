#!/usr/bin/env bash
# deploy-worker.sh — Deploy a Cloudflare Worker with staging → production promotion
#
# Usage:
#   ./deploy-worker.sh [options]
#
# Options:
#   --staging          Deploy to staging only (default behavior)
#   --production       Promote to production (skips staging)
#   --promote          Deploy to staging, smoke test, then promote to production
#   --rollback [n]     Rollback to previous deployment (n versions back, default 1)
#   --skip-tests       Skip test step
#   --skip-lint        Skip lint step
#   --dry-run          Build only, don't deploy
#   --dir <path>       Worker project directory (default: current dir)
#
# Examples:
#   ./deploy-worker.sh --staging
#   ./deploy-worker.sh --promote
#   ./deploy-worker.sh --rollback
#   ./deploy-worker.sh --rollback 2
#
# Requires: wrangler, npm, jq
# Set SMOKE_TEST_URL to override the default health check URL.

set -euo pipefail

# --- Configuration ---
TARGET="staging"
SKIP_TESTS=false
SKIP_LINT=false
DRY_RUN=false
ROLLBACK=false
ROLLBACK_VERSIONS=1
WORKER_DIR="."
SMOKE_TEST_URL="${SMOKE_TEST_URL:-}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --staging)     TARGET="staging"; shift ;;
    --production)  TARGET="production"; shift ;;
    --promote)     TARGET="promote"; shift ;;
    --rollback)
      ROLLBACK=true
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        ROLLBACK_VERSIONS="$2"; shift
      fi
      shift
      ;;
    --skip-tests)  SKIP_TESTS=true; shift ;;
    --skip-lint)   SKIP_LINT=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --dir)         WORKER_DIR="$2"; shift 2 ;;
    --help|-h)     head -20 "$0" | tail -18; exit 0 ;;
    *)             echo "Error: Unknown option '$1'" >&2; exit 1 ;;
  esac
done

cd "${WORKER_DIR}"

# Verify wrangler.toml exists
if [[ ! -f wrangler.toml ]]; then
  echo "❌ wrangler.toml not found in $(pwd)" >&2
  exit 1
fi

WORKER_NAME=$(grep -m1 '^name' wrangler.toml | sed 's/name *= *"\(.*\)"/\1/')
echo "📦 Worker: ${WORKER_NAME}"
echo "🎯 Target: ${TARGET}"
echo ""

# --- Rollback ---
if $ROLLBACK; then
  echo "⏪ Rolling back ${ROLLBACK_VERSIONS} version(s)..."
  DEPLOYMENTS=$(npx wrangler deployments list --json 2>/dev/null || echo "[]")
  VERSIONS=$(echo "$DEPLOYMENTS" | jq -r '.[].id' 2>/dev/null || true)

  if [[ -z "$VERSIONS" ]]; then
    echo "❌ Could not fetch deployment history. Manual rollback:"
    echo "   npx wrangler rollback"
    exit 1
  fi

  npx wrangler rollback
  echo "✅ Rollback initiated"
  exit 0
fi

# --- Step 1: Lint ---
if ! $SKIP_LINT; then
  echo "🔍 Step 1/5: Linting..."
  if [[ -f node_modules/.bin/eslint ]]; then
    npx eslint src/ --quiet || { echo "❌ Lint failed"; exit 1; }
    echo "   ✅ Lint passed"
  else
    echo "   ⏭️  ESLint not installed, skipping"
  fi
else
  echo "⏭️  Step 1/5: Lint (skipped)"
fi

# --- Step 2: Type check ---
echo "🔍 Step 2/5: Type checking..."
if [[ -f tsconfig.json ]]; then
  npx tsc --noEmit || { echo "❌ Type check failed"; exit 1; }
  echo "   ✅ Types OK"
else
  echo "   ⏭️  No tsconfig.json, skipping"
fi

# --- Step 3: Test ---
if ! $SKIP_TESTS; then
  echo "🧪 Step 3/5: Running tests..."
  if [[ -f vitest.config.ts ]] || [[ -f vitest.config.js ]]; then
    npx vitest run --reporter=verbose || { echo "❌ Tests failed"; exit 1; }
    echo "   ✅ Tests passed"
  elif grep -q '"test"' package.json 2>/dev/null; then
    npm test || { echo "❌ Tests failed"; exit 1; }
    echo "   ✅ Tests passed"
  else
    echo "   ⏭️  No test config found, skipping"
  fi
else
  echo "⏭️  Step 3/5: Tests (skipped)"
fi

# --- Step 4: Build/Deploy ---
if $DRY_RUN; then
  echo "📦 Step 4/5: Dry run build..."
  npx wrangler deploy --dry-run --outdir dist
  echo "   ✅ Build output in dist/"
  ls -lh dist/ 2>/dev/null || true
  echo ""
  echo "🏁 Dry run complete — no deployment made."
  exit 0
fi

deploy_to_env() {
  local env_name="$1"
  echo "🚀 Step 4/5: Deploying to ${env_name}..."
  if [[ "$env_name" == "production" ]]; then
    npx wrangler deploy
  else
    npx wrangler deploy --env "${env_name}"
  fi
  echo "   ✅ Deployed to ${env_name}"
}

# --- Step 5: Smoke test ---
smoke_test() {
  local url="$1"
  echo "🏥 Step 5/5: Smoke testing ${url}..."
  local response
  local http_code

  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${url}" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" ]]; then
    echo "   ✅ Health check passed (HTTP ${http_code})"
    return 0
  else
    echo "   ❌ Health check failed (HTTP ${http_code})"
    return 1
  fi
}

get_worker_url() {
  local env_name="$1"
  if [[ -n "$SMOKE_TEST_URL" ]]; then
    echo "$SMOKE_TEST_URL"
    return
  fi
  if [[ "$env_name" == "production" ]]; then
    echo "https://${WORKER_NAME}.workers.dev/health"
  else
    echo "https://${WORKER_NAME}-${env_name}.workers.dev/health"
  fi
}

case "$TARGET" in
  staging)
    deploy_to_env staging
    STAGING_URL=$(get_worker_url staging)
    # Smoke test is best-effort for staging
    smoke_test "$STAGING_URL" || echo "   ⚠️  Smoke test failed — check manually"
    echo ""
    echo "🏁 Staging deployment complete."
    echo "   Promote to production: $0 --production"
    ;;
  production)
    deploy_to_env production
    PROD_URL=$(get_worker_url production)
    if ! smoke_test "$PROD_URL"; then
      echo ""
      echo "   ⚠️  Production smoke test failed!"
      echo "   Rollback: $0 --rollback"
    fi
    echo ""
    echo "🏁 Production deployment complete."
    ;;
  promote)
    # Deploy to staging first
    deploy_to_env staging
    STAGING_URL=$(get_worker_url staging)

    echo ""
    if smoke_test "$STAGING_URL"; then
      echo ""
      echo "✅ Staging smoke test passed. Promoting to production..."
      echo ""
      deploy_to_env production
      PROD_URL=$(get_worker_url production)
      if ! smoke_test "$PROD_URL"; then
        echo ""
        echo "   ⚠️  Production smoke test failed!"
        echo "   Rollback: $0 --rollback"
      fi
      echo ""
      echo "🏁 Promotion complete: staging → production"
    else
      echo ""
      echo "❌ Staging smoke test failed. Aborting promotion."
      echo "   Fix issues and try again."
      exit 1
    fi
    ;;
esac
