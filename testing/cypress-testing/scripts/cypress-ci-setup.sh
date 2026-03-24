#!/usr/bin/env bash
# cypress-ci-setup.sh — Generate CI configuration for Cypress testing
# Usage: ./cypress-ci-setup.sh [--provider github|gitlab|circle] [--parallel N]
set -euo pipefail

# --- Defaults ---
PROVIDER="github"
PARALLEL=1
PROJECT_NAME=$(basename "$(pwd)")

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--provider github|gitlab|circle] [--parallel N]"
      echo ""
      echo "Options:"
      echo "  --provider    CI provider (default: github)"
      echo "  --parallel    Number of parallel containers (default: 1)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "🔧 Generating CI config for Cypress"
echo "   Provider: $PROVIDER | Parallel: $PARALLEL | Project: $PROJECT_NAME"

generate_github_actions() {
  mkdir -p .github/workflows

  local STRATEGY_BLOCK=""
  local PARALLEL_FLAGS=""
  local RECORD_FLAGS=""

  if [ "$PARALLEL" -gt 1 ]; then
    STRATEGY_BLOCK="
    strategy:
      fail-fast: false
      matrix:
        containers: [$(seq -s ', ' 1 "$PARALLEL")]"
    PARALLEL_FLAGS="
          record: true
          parallel: true
          group: 'e2e-tests'"
    RECORD_FLAGS="
          CYPRESS_RECORD_KEY: \${{ secrets.CYPRESS_RECORD_KEY }}"
  fi

  cat > .github/workflows/cypress.yml << WORKFLOW
name: Cypress Tests
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  cypress-e2e:
    runs-on: ubuntu-latest
    timeout-minutes: 30${STRATEGY_BLOCK}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Cache Cypress binary
        uses: actions/cache@v4
        with:
          path: ~/.cache/Cypress
          key: cypress-\${{ runner.os }}-\${{ hashFiles('package-lock.json') }}
          restore-keys: |
            cypress-\${{ runner.os }}-

      - name: Install dependencies
        run: npm ci

      - name: Run Cypress E2E tests
        uses: cypress-io/github-action@v7
        with:
          install: false
          build: npm run build
          start: npm start
          wait-on: 'http://localhost:3000'
          wait-on-timeout: 120
          browser: chrome${PARALLEL_FLAGS}
        env:
          CI: true${RECORD_FLAGS}

      - name: Upload screenshots on failure
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-screenshots\${{ matrix.containers && format('-{0}', matrix.containers) || '' }}
          path: cypress/screenshots
          if-no-files-found: ignore
          retention-days: 7

      - name: Upload videos on failure
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-videos\${{ matrix.containers && format('-{0}', matrix.containers) || '' }}
          path: cypress/videos
          if-no-files-found: ignore
          retention-days: 7

  cypress-component:
    runs-on: ubuntu-latest
    timeout-minutes: 15

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Cache Cypress binary
        uses: actions/cache@v4
        with:
          path: ~/.cache/Cypress
          key: cypress-\${{ runner.os }}-\${{ hashFiles('package-lock.json') }}
          restore-keys: |
            cypress-\${{ runner.os }}-

      - name: Install dependencies
        run: npm ci

      - name: Run Cypress Component tests
        uses: cypress-io/github-action@v7
        with:
          install: false
          component: true
          browser: chrome
        env:
          CI: true
WORKFLOW

  echo "✅ Created .github/workflows/cypress.yml"
}

generate_gitlab_ci() {
  cat > .gitlab-ci-cypress.yml << 'GITLAB'
stages:
  - test

variables:
  CYPRESS_CACHE_FOLDER: "$CI_PROJECT_DIR/.cypress-cache"
  npm_config_cache: "$CI_PROJECT_DIR/.npm-cache"

.cypress-base:
  image: cypress/browsers:node-20.18.1-chrome-130.0.6723.116-1-ff-132.0.1-edge-130.0.2849.68-1
  cache:
    key:
      files:
        - package-lock.json
    paths:
      - .npm-cache
      - .cypress-cache
    policy: pull-push
  before_script:
    - npm ci --prefer-offline

cypress-e2e:
  extends: .cypress-base
  stage: test
  script:
    - npm run build
    - npm start &
    - npx wait-on http://localhost:3000 --timeout 120000
    - npx cypress run --browser chrome
  artifacts:
    when: on_failure
    expire_in: 3 days
    paths:
      - cypress/screenshots
      - cypress/videos

cypress-component:
  extends: .cypress-base
  stage: test
  script:
    - npx cypress run --component --browser chrome
  artifacts:
    when: on_failure
    expire_in: 3 days
    paths:
      - cypress/screenshots
GITLAB

  echo "✅ Created .gitlab-ci-cypress.yml"
}

generate_circleci() {
  mkdir -p .circleci

  cat > .circleci/config.yml << CIRCLE
version: 2.1
orbs:
  cypress: cypress-io/cypress@3

workflows:
  cypress-tests:
    jobs:
      - cypress/run:
          name: e2e-tests
          install-command: npm ci
          build: npm run build
          start: npm start
          wait-on: 'http://localhost:3000'
          browser: chrome
          parallelism: ${PARALLEL}
          store_artifacts: true
      - cypress/run:
          name: component-tests
          install-command: npm ci
          component: true
          browser: chrome
CIRCLE

  echo "✅ Created .circleci/config.yml"
}

# --- Generate based on provider ---
case "$PROVIDER" in
  github) generate_github_actions ;;
  gitlab) generate_gitlab_ci ;;
  circle) generate_circleci ;;
  *) echo "❌ Unknown provider: $PROVIDER. Use github, gitlab, or circle."; exit 1 ;;
esac

echo ""
echo "📋 Next steps:"
case "$PROVIDER" in
  github)
    echo "  1. Commit .github/workflows/cypress.yml"
    if [ "$PARALLEL" -gt 1 ]; then
      echo "  2. Add CYPRESS_RECORD_KEY to GitHub repo secrets"
      echo "  3. Ensure Cypress Cloud project is configured"
    fi
    ;;
  gitlab)
    echo "  1. Merge .gitlab-ci-cypress.yml into your .gitlab-ci.yml"
    ;;
  circle)
    echo "  1. Commit .circleci/config.yml"
    echo "  2. Connect your repo to CircleCI"
    ;;
esac
echo ""
