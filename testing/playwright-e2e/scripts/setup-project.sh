#!/usr/bin/env bash
# ============================================================================
# setup-project.sh — Initialize Playwright in an existing project
#
# Usage:
#   ./setup-project.sh [--dir <project-dir>] [--browsers chromium,firefox,webkit]
#                      [--no-ci] [--no-examples]
#
# Installs Playwright, generates recommended config, GitHub Actions workflow,
# and optional example tests with Page Object Model structure.
# ============================================================================

set -euo pipefail

# Defaults
PROJECT_DIR="."
BROWSERS="chromium,firefox,webkit"
INSTALL_CI=true
INSTALL_EXAMPLES=true

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Initialize Playwright in an existing project with recommended configuration.

Options:
  --dir <path>          Project directory (default: current directory)
  --browsers <list>     Comma-separated browsers to install (default: chromium,firefox,webkit)
  --no-ci               Skip GitHub Actions workflow generation
  --no-examples         Skip example test generation
  -h, --help            Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --dir ./my-app --browsers chromium
  $(basename "$0") --no-ci --no-examples
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)        PROJECT_DIR="$2"; shift 2 ;;
    --browsers)   BROWSERS="$2"; shift 2 ;;
    --no-ci)      INSTALL_CI=false; shift ;;
    --no-examples) INSTALL_EXAMPLES=false; shift ;;
    -h|--help)    usage ;;
    *)            error "Unknown option: $1. Use --help for usage." ;;
  esac
done

# Validate project directory
cd "$PROJECT_DIR" || error "Cannot access directory: $PROJECT_DIR"

if [[ ! -f "package.json" ]]; then
  error "No package.json found in $(pwd). Run this from a Node.js project root."
fi

log "Setting up Playwright in $(pwd)"

# -------------------------------------------
# 1. Install Playwright
# -------------------------------------------
log "Installing @playwright/test..."
npm install -D @playwright/test

log "Installing browsers: $BROWSERS"
IFS=',' read -ra BROWSER_ARRAY <<< "$BROWSERS"
for browser in "${BROWSER_ARRAY[@]}"; do
  npx playwright install --with-deps "$browser"
done

# -------------------------------------------
# 2. Create directory structure
# -------------------------------------------
log "Creating directory structure..."
mkdir -p tests/pages
mkdir -p tests/fixtures
mkdir -p playwright/.auth

# -------------------------------------------
# 3. Generate playwright.config.ts
# -------------------------------------------
log "Generating playwright.config.ts..."
cat > playwright.config.ts << 'CONFIGEOF'
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI
    ? [['blob'], ['github'], ['html', { open: 'never' }]]
    : [['list'], ['html', { open: 'on-failure' }]],
  use: {
    baseURL: process.env.BASE_URL || 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
      dependencies: ['setup'],
    },
    {
      name: 'firefox',
      use: { ...devices['Desktop Firefox'] },
      dependencies: ['setup'],
    },
    {
      name: 'webkit',
      use: { ...devices['Desktop Safari'] },
      dependencies: ['setup'],
    },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
CONFIGEOF

# -------------------------------------------
# 4. Update .gitignore
# -------------------------------------------
log "Updating .gitignore..."
GITIGNORE_ENTRIES=(
  "test-results/"
  "playwright-report/"
  "blob-report/"
  "playwright/.auth/"
  "playwright/.cache/"
)

touch .gitignore
for entry in "${GITIGNORE_ENTRIES[@]}"; do
  if ! grep -qxF "$entry" .gitignore 2>/dev/null; then
    echo "$entry" >> .gitignore
  fi
done

# -------------------------------------------
# 5. GitHub Actions workflow
# -------------------------------------------
if $INSTALL_CI; then
  log "Generating GitHub Actions workflow..."
  mkdir -p .github/workflows

  cat > .github/workflows/playwright.yml << 'CIEOF'
name: Playwright Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Cache Playwright browsers
        id: playwright-cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

      - name: Install Playwright browsers
        if: steps.playwright-cache.outputs.cache-hit != 'true'
        run: npx playwright install --with-deps

      - name: Install Playwright system deps
        if: steps.playwright-cache.outputs.cache-hit == 'true'
        run: npx playwright install-deps

      - name: Run Playwright tests
        run: npx playwright test

      - name: Upload report
        uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 14
CIEOF
fi

# -------------------------------------------
# 6. Example tests and page objects
# -------------------------------------------
if $INSTALL_EXAMPLES; then
  log "Generating example tests and page objects..."

  cat > tests/pages/base-page.ts << 'PAGEEOF'
import { type Page, type Locator } from '@playwright/test';

export abstract class BasePage {
  constructor(protected readonly page: Page) {}

  abstract readonly url: string;

  async goto() {
    await this.page.goto(this.url);
  }

  async getTitle(): Promise<string> {
    return this.page.title();
  }
}
PAGEEOF

  cat > tests/pages/home-page.ts << 'HOMEEOF'
import { type Page, type Locator } from '@playwright/test';
import { BasePage } from './base-page';

export class HomePage extends BasePage {
  readonly url = '/';
  readonly heading: Locator;
  readonly navLinks: Locator;

  constructor(page: Page) {
    super(page);
    this.heading = page.getByRole('heading', { level: 1 });
    this.navLinks = page.getByRole('navigation').getByRole('link');
  }
}
HOMEEOF

  cat > tests/example.spec.ts << 'TESTEOF'
import { test, expect } from '@playwright/test';
import { HomePage } from './pages/home-page';

test.describe('Home page', () => {
  test('has a heading', async ({ page }) => {
    const homePage = new HomePage(page);
    await homePage.goto();
    await expect(homePage.heading).toBeVisible();
  });

  test('has navigation', async ({ page }) => {
    const homePage = new HomePage(page);
    await homePage.goto();
    await expect(homePage.navLinks.first()).toBeVisible();
  });
});
TESTEOF
fi

# -------------------------------------------
# 7. Add npm scripts
# -------------------------------------------
log "Adding npm scripts..."
if command -v npx &>/dev/null; then
  npx -y npm-add-script -k "test:e2e" -v "playwright test" 2>/dev/null || warn "Could not add npm scripts automatically. Add manually: \"test:e2e\": \"playwright test\""
  npx -y npm-add-script -k "test:e2e:ui" -v "playwright test --ui" 2>/dev/null || true
  npx -y npm-add-script -k "test:e2e:debug" -v "playwright test --debug" 2>/dev/null || true
fi

# -------------------------------------------
# Done
# -------------------------------------------
log "Playwright setup complete!"
echo ""
echo "  Directory structure:"
echo "    tests/            — test files"
echo "    tests/pages/      — page objects"
echo "    tests/fixtures/   — custom fixtures"
echo "    playwright/.auth/ — auth state (gitignored)"
echo ""
echo "  Commands:"
echo "    npx playwright test          — run all tests"
echo "    npx playwright test --ui     — interactive UI mode"
echo "    npx playwright test --debug  — step-through debugger"
echo "    npx playwright codegen       — generate tests by recording"
echo "    npx playwright show-report   — view HTML report"
