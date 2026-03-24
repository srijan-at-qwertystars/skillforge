#!/usr/bin/env bash
# =============================================================================
# setup-playwright-ci.sh
#
# Sets up Playwright for CI environments. Handles:
#   - Installing Playwright and browser dependencies
#   - Generating a GitHub Actions workflow file
#   - Configuring npm caching for faster CI runs
#
# Usage:
#   ./setup-playwright-ci.sh [OPTIONS]
#
# Options:
#   --workflow-dir DIR    Directory for workflow file (default: .github/workflows)
#   --browsers LIST       Comma-separated browsers (default: chromium,firefox,webkit)
#   --shards N            Number of CI shards (default: 1)
#   --node-version VER    Node.js version (default: 20)
#   --skip-install        Skip npm install of Playwright
#   --help                Show this help message
#
# Examples:
#   ./setup-playwright-ci.sh
#   ./setup-playwright-ci.sh --browsers chromium --shards 4
#   ./setup-playwright-ci.sh --workflow-dir ci/ --node-version 22
# =============================================================================

set -euo pipefail

# Defaults
WORKFLOW_DIR=".github/workflows"
BROWSERS="chromium,firefox,webkit"
SHARDS=1
NODE_VERSION="20"
SKIP_INSTALL=false

usage() {
  head -n 20 "$0" | tail -n +3 | sed 's/^# \?//'
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow-dir)  WORKFLOW_DIR="$2"; shift 2 ;;
    --browsers)      BROWSERS="$2"; shift 2 ;;
    --shards)        SHARDS="$2"; shift 2 ;;
    --node-version)  NODE_VERSION="$2"; shift 2 ;;
    --skip-install)  SKIP_INSTALL=true; shift ;;
    --help|-h)       usage ;;
    *)               echo "Unknown option: $1"; usage ;;
  esac
done

echo "=== Playwright CI Setup ==="
echo "Workflow dir:  $WORKFLOW_DIR"
echo "Browsers:      $BROWSERS"
echo "Shards:        $SHARDS"
echo "Node version:  $NODE_VERSION"
echo ""

# Step 1: Install Playwright if not skipped
if [[ "$SKIP_INSTALL" == false ]]; then
  echo ">>> Installing @playwright/test..."
  if [[ -f "package.json" ]]; then
    npm install -D @playwright/test
  else
    echo "No package.json found. Initializing..."
    npm init -y
    npm install -D @playwright/test
  fi

  echo ">>> Installing Playwright browsers with system dependencies..."
  npx playwright install --with-deps $( echo "$BROWSERS" | tr ',' ' ' )
  echo "✓ Playwright installed successfully"
else
  echo ">>> Skipping Playwright install (--skip-install)"
fi

# Step 2: Create workflow directory
mkdir -p "$WORKFLOW_DIR"

# Step 3: Generate the GitHub Actions workflow
WORKFLOW_FILE="$WORKFLOW_DIR/playwright.yml"
echo ">>> Generating workflow: $WORKFLOW_FILE"

# Build shard matrix
if [[ "$SHARDS" -gt 1 ]]; then
  SHARD_INDICES=$(seq -s ', ' 1 "$SHARDS")
  SHARD_STRATEGY=$(cat <<SHARD
    strategy:
      fail-fast: false
      matrix:
        shardIndex: [$SHARD_INDICES]
        shardTotal: [$SHARDS]
SHARD
)
  SHARD_FLAG="--shard=\${{ matrix.shardIndex }}/\${{ matrix.shardTotal }}"
  ARTIFACT_NAME="playwright-report-\${{ matrix.shardIndex }}"
else
  SHARD_STRATEGY=""
  SHARD_FLAG=""
  ARTIFACT_NAME="playwright-report"
fi

# Build browser install command
BROWSER_LIST=$(echo "$BROWSERS" | tr ',' ' ')

cat > "$WORKFLOW_FILE" <<WORKFLOW
name: Playwright Tests
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

jobs:
  test:
    timeout-minutes: 60
    runs-on: ubuntu-latest
${SHARD_STRATEGY}
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: ${NODE_VERSION}
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Cache Playwright browsers
        uses: actions/cache@v4
        id: playwright-cache
        with:
          path: ~/.cache/ms-playwright
          key: playwright-\${{ runner.os }}-\${{ hashFiles('package-lock.json') }}

      - name: Install Playwright browsers
        if: steps.playwright-cache.outputs.cache-hit != 'true'
        run: npx playwright install --with-deps ${BROWSER_LIST}

      - name: Install Playwright system deps
        if: steps.playwright-cache.outputs.cache-hit == 'true'
        run: npx playwright install-deps ${BROWSER_LIST}

      - name: Run Playwright tests
        run: npx playwright test ${SHARD_FLAG}

      - uses: actions/upload-artifact@v4
        if: \${{ !cancelled() }}
        with:
          name: ${ARTIFACT_NAME}
          path: playwright-report/
          retention-days: 14
WORKFLOW

echo "✓ Workflow created: $WORKFLOW_FILE"

# Step 4: Create .gitignore entries if needed
if [[ -f ".gitignore" ]]; then
  for entry in "test-results/" "playwright-report/" "playwright/.auth/"; do
    if ! grep -qF "$entry" .gitignore 2>/dev/null; then
      echo "$entry" >> .gitignore
      echo "  Added $entry to .gitignore"
    fi
  done
else
  cat > .gitignore <<GITIGNORE
# Playwright
test-results/
playwright-report/
playwright/.auth/
blob-report/
GITIGNORE
  echo "✓ Created .gitignore with Playwright entries"
fi

echo ""
echo "=== Setup Complete ==="
echo "Run tests locally:  npx playwright test"
echo "Run in CI:          git push (workflow triggers on push/PR)"
if [[ "$SHARDS" -gt 1 ]]; then
  echo "Sharding:           $SHARDS shards configured"
fi
