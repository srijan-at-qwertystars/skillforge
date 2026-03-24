#!/usr/bin/env bash
# =============================================================================
# setup-project.sh
#
# Initialize a Playwright project with best-practice structure, config,
# and browser installation. Creates a production-ready folder layout.
#
# Usage:
#   ./setup-project.sh [OPTIONS]
#
# Options:
#   --dir DIR           Project directory (default: current directory)
#   --browsers LIST     Comma-separated browsers to install (default: chromium)
#                       Options: chromium, firefox, webkit
#   --base-url URL      Application base URL (default: http://localhost:3000)
#   --with-auth         Include authentication setup files
#   --with-axe          Include @axe-core/playwright for accessibility testing
#   --with-ci           Generate GitHub Actions workflow
#   --skip-install      Skip npm install (for existing projects)
#   --help              Show this help message
#
# Examples:
#   ./setup-project.sh
#   ./setup-project.sh --dir my-app --browsers chromium,firefox --with-auth --with-ci
#   ./setup-project.sh --with-axe --base-url http://localhost:8080
# =============================================================================

set -euo pipefail

# Defaults
PROJECT_DIR="."
BROWSERS="chromium"
BASE_URL="http://localhost:3000"
WITH_AUTH=false
WITH_AXE=false
WITH_CI=false
SKIP_INSTALL=false

usage() {
  head -n 27 "$0" | tail -n +3 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)          PROJECT_DIR="$2"; shift 2 ;;
    --browsers)     BROWSERS="$2"; shift 2 ;;
    --base-url)     BASE_URL="$2"; shift 2 ;;
    --with-auth)    WITH_AUTH=true; shift ;;
    --with-axe)     WITH_AXE=true; shift ;;
    --with-ci)      WITH_CI=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    --help|-h)      usage ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

echo "=== Playwright Project Setup ==="
echo "Directory:  $PROJECT_DIR"
echo "Browsers:   $BROWSERS"
echo "Base URL:   $BASE_URL"
echo "Auth:       $WITH_AUTH"
echo "Axe a11y:   $WITH_AXE"
echo "CI:         $WITH_CI"
echo ""

# Create project directory
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Step 1: Initialize package.json if missing
if [[ ! -f "package.json" ]]; then
  echo ">>> Initializing package.json..."
  npm init -y --quiet
fi

# Step 2: Install dependencies
if [[ "$SKIP_INSTALL" == false ]]; then
  echo ">>> Installing @playwright/test..."
  npm install -D @playwright/test

  if [[ "$WITH_AXE" == true ]]; then
    echo ">>> Installing @axe-core/playwright..."
    npm install -D @axe-core/playwright
  fi

  echo ">>> Installing browsers: $BROWSERS..."
  npx playwright install --with-deps $(echo "$BROWSERS" | tr ',' ' ')
fi

# Step 3: Create folder structure
echo ">>> Creating project structure..."
mkdir -p tests
mkdir -p pages
mkdir -p fixtures
mkdir -p test-results
mkdir -p playwright/.auth

# Step 4: Create playwright.config.ts
if [[ ! -f "playwright.config.ts" ]]; then
  echo ">>> Creating playwright.config.ts..."

  # Build projects array based on selected browsers
  PROJECTS=""
  IFS=',' read -ra BROWSER_ARRAY <<< "$BROWSERS"
  for browser in "${BROWSER_ARRAY[@]}"; do
    case "$browser" in
      chromium)
        PROJECTS+="    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
"
        ;;
      firefox)
        PROJECTS+="    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
"
        ;;
      webkit)
        PROJECTS+="    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
"
        ;;
    esac
  done

  cat > playwright.config.ts <<CONFIG
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI
    ? [['blob'], ['html', { open: 'never' }]]
    : [['html', { open: 'on-failure' }]],
  use: {
    baseURL: process.env.BASE_URL || '${BASE_URL}',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'on-first-retry',
    actionTimeout: 10_000,
    navigationTimeout: 15_000,
  },
  projects: [
${PROJECTS}  ],
  webServer: {
    command: 'npm run dev',
    url: '${BASE_URL}',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
CONFIG
fi

# Step 5: Create example test
if [[ ! -f "tests/example.spec.ts" ]]; then
  cat > tests/example.spec.ts <<'TEST'
import { test, expect } from '@playwright/test';

test.describe('Homepage', () => {
  test('has title', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle(/.+/);
  });

  test('main heading is visible', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });
});
TEST
fi

# Step 6: Create page object example
if [[ ! -f "pages/BasePage.ts" ]]; then
  cat > pages/BasePage.ts <<'POM'
import { type Page, type Locator, expect } from '@playwright/test';

export abstract class BasePage {
  constructor(protected readonly page: Page) {}

  protected async navigateTo(path: string) {
    await this.page.goto(path);
  }

  async waitForURL(url: string | RegExp) {
    await expect(this.page).toHaveURL(url);
  }

  async screenshot(name: string) {
    return this.page.screenshot({ path: `screenshots/${name}.png`, fullPage: true });
  }

  get currentURL() { return this.page.url(); }
}
POM
fi

# Step 7: Create fixtures
if [[ ! -f "fixtures/test-fixtures.ts" ]]; then
  cat > fixtures/test-fixtures.ts <<'FIXTURES'
import { test as base } from '@playwright/test';

// Add page objects and custom fixtures here
// import { HomePage } from '../pages/HomePage';

type MyFixtures = {
  // homePage: HomePage;
};

export const test = base.extend<MyFixtures>({
  // homePage: async ({ page }, use) => {
  //   await use(new HomePage(page));
  // },
});

export { expect } from '@playwright/test';
FIXTURES
fi

# Step 8: Authentication setup (optional)
if [[ "$WITH_AUTH" == true ]]; then
  echo ">>> Creating authentication setup..."
  cat > tests/auth.setup.ts <<'AUTH'
import { test as setup } from '@playwright/test';

const authFile = 'playwright/.auth/user.json';

setup('authenticate', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill(process.env.TEST_EMAIL || 'test@example.com');
  await page.getByLabel('Password').fill(process.env.TEST_PASSWORD || 'password');
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await page.waitForURL('**/dashboard');
  await page.context().storageState({ path: authFile });
});
AUTH
fi

# Step 9: Accessibility test (optional)
if [[ "$WITH_AXE" == true ]]; then
  echo ">>> Creating accessibility test..."
  cat > tests/accessibility.spec.ts <<'A11Y'
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test.describe('Accessibility', () => {
  test('homepage has no a11y violations', async ({ page }) => {
    await page.goto('/');
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa'])
      .analyze();
    expect(results.violations).toEqual([]);
  });
});
A11Y
fi

# Step 10: GitHub Actions workflow (optional)
if [[ "$WITH_CI" == true ]]; then
  echo ">>> Creating GitHub Actions workflow..."
  mkdir -p .github/workflows
  cat > .github/workflows/playwright.yml <<'WORKFLOW'
name: Playwright Tests
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

jobs:
  test:
    timeout-minutes: 30
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'
      - run: npm ci
      - name: Cache Playwright browsers
        uses: actions/cache@v4
        id: pw-cache
        with:
          path: ~/.cache/ms-playwright
          key: pw-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
      - if: steps.pw-cache.outputs.cache-hit != 'true'
        run: npx playwright install --with-deps
      - if: steps.pw-cache.outputs.cache-hit == 'true'
        run: npx playwright install-deps
      - run: npx playwright test
      - uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 14
WORKFLOW
fi

# Step 11: .gitignore
if [[ ! -f ".gitignore" ]]; then
  cat > .gitignore <<'GITIGNORE'
node_modules/
test-results/
playwright-report/
blob-report/
playwright/.auth/
screenshots/
GITIGNORE
else
  for entry in "test-results/" "playwright-report/" "playwright/.auth/" "blob-report/"; do
    if ! grep -qF "$entry" .gitignore 2>/dev/null; then
      echo "$entry" >> .gitignore
    fi
  done
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Project structure:"
echo "  playwright.config.ts    — Configuration"
echo "  tests/                  — Test files"
echo "  pages/                  — Page Object Models"
echo "  fixtures/               — Custom test fixtures"
echo ""
echo "Next steps:"
echo "  npx playwright test                  # Run tests"
echo "  npx playwright test --ui             # Interactive UI mode"
echo "  npx playwright codegen ${BASE_URL}   # Generate tests"
echo "  npx playwright show-report           # View last report"
