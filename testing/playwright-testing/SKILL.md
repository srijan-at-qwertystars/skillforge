---
name: playwright-testing
description: >
  Guide for writing browser automation and end-to-end tests with Playwright.
  Use when writing browser tests, e2e tests, UI automation, cross-browser testing
  with Playwright, visual regression tests, component testing in browsers,
  network mocking for UI tests, or multi-browser test suites.
  Do NOT use for unit tests without a browser, API-only testing without UI,
  Selenium-specific code, Cypress-specific code, Puppeteer-specific code,
  mobile native app testing (Appium/Detox), or load/performance testing tools
  like k6 or Artillery.
---

# Playwright Testing

## Installation and Project Setup

```bash
npm init playwright@latest          # new project (scaffolds config, examples, CI workflow)
npm install -D @playwright/test     # existing project
npx playwright install --with-deps  # install browsers + OS deps
```

Minimal `playwright.config.ts`:

```ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
  webServer: {
    command: 'npm run dev',
    port: 3000,
    reuseExistingServer: !process.env.CI,
  },
});
```

## Test Structure

```ts
import { test, expect } from '@playwright/test';

test.describe('Login flow', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/login');
  });

  test('successful login redirects to dashboard', async ({ page }) => {
    await page.getByLabel('Email').fill('user@example.com');
    await page.getByLabel('Password').fill('secret');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL('/dashboard');
  });

  test('invalid credentials show error', async ({ page }) => {
    await page.getByLabel('Email').fill('bad@example.com');
    await page.getByLabel('Password').fill('wrong');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByText('Invalid credentials')).toBeVisible();
  });
});
```

Use `test.skip()`, `test.fixme()`, `test.slow()`, `test.only()`, and `test.afterEach()` for test control.

## Locators

Prefer accessible locators over CSS/XPath. Priority order:

```ts
page.getByRole('button', { name: 'Submit' });    // 1. Role (best)
page.getByRole('heading', { level: 1 });
page.getByLabel('Email address');                  // 2. Label
page.getByPlaceholder('Search...');                // 3. Placeholder
page.getByText('Welcome back');                    // 4. Text
page.getByText(/total: \$[\d.]+/i);               //    (supports regex)
page.getByTestId('nav-menu');                      // 5. Test ID [data-testid]
page.locator('input[type="email"]');               // 6. CSS (escape hatch)
page.locator('xpath=//div[@class="results"]//li'); // 7. XPath (last resort)

// Chain and filter
const row = page.getByRole('row').filter({ hasText: 'John' });
await row.getByRole('button', { name: 'Edit' }).click();
```

## Actions

```ts
// Click
await page.getByRole('button', { name: 'Save' }).click();
await page.getByRole('button').dblclick();
await page.getByRole('button').click({ button: 'right' });

// Fill (clears then types) vs type (key-by-key)
await page.getByLabel('Name').fill('Alice');
await page.getByLabel('Search').pressSequentially('hello', { delay: 100 });

// Keyboard
await page.keyboard.press('Enter');
await page.keyboard.press('Control+A');

// Hover
await page.getByText('Menu').hover();

// Select dropdown
await page.getByLabel('Country').selectOption('us');
await page.getByLabel('Colors').selectOption(['red', 'blue']);

// Checkbox and radio
await page.getByLabel('Agree to terms').check();
await page.getByLabel('Option A').uncheck();

// File upload
await page.getByLabel('Upload').setInputFiles('file.pdf');
await page.getByLabel('Upload').setInputFiles(['a.png', 'b.png']);
await page.getByLabel('Upload').setInputFiles([]); // clear

// Drag and drop
await page.getByTestId('source').dragTo(page.getByTestId('target'));
```

## Assertions

All assertions auto-retry until timeout. Use `expect` with locators:

```ts
// Visibility
await expect(page.getByText('Success')).toBeVisible();
await expect(page.getByTestId('modal')).toBeHidden();

// Text content
await expect(page.getByRole('heading')).toHaveText('Dashboard');
await expect(page.getByRole('alert')).toContainText('saved');

// URL and title
await expect(page).toHaveURL(/\/dashboard/);
await expect(page).toHaveTitle('My App');

// Count
await expect(page.getByRole('listitem')).toHaveCount(5);

// Attributes and CSS
await expect(page.getByRole('button')).toBeEnabled();
await expect(page.getByRole('button')).toBeDisabled();
await expect(page.locator('input')).toHaveAttribute('type', 'email');
await expect(page.locator('input')).toHaveValue('alice@test.com');
await expect(page.locator('.box')).toHaveCSS('color', 'rgb(255, 0, 0)');

// Negation
await expect(page.getByText('Error')).not.toBeVisible();

// Soft assertions (don't stop test on failure)
await expect.soft(page.getByTestId('status')).toHaveText('Active');
```

## Page Navigation and Waiting

Playwright auto-waits for elements to be actionable. Use explicit waits only when needed:

```ts
await page.goto('/products');
await page.goBack();
await page.reload();

await page.waitForURL('**/checkout');
await page.getByTestId('spinner').waitFor({ state: 'hidden' });

// Wait for network response
const responsePromise = page.waitForResponse('**/api/products');
await page.getByRole('button', { name: 'Load' }).click();
const response = await responsePromise;

await page.waitForLoadState('networkidle');
```

Avoid hard `waitForTimeout` sleeps — use event-driven waits instead.

## Network Interception

Mock API responses, block resources, or modify requests:

```ts
// Mock an API response
await page.route('**/api/users', async (route) => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify([{ id: 1, name: 'Alice' }]),
  });
});

// Modify a request before it reaches the server
await page.route('**/api/data', async (route) => {
  const headers = { ...route.request().headers(), 'X-Custom': 'value' };
  await route.continue({ headers });
});

// Abort requests (block images, analytics, etc.)
await page.route('**/*.{png,jpg}', (route) => route.abort());
await page.route('**/analytics/**', (route) => route.abort());

// Intercept and modify response
await page.route('**/api/config', async (route) => {
  const response = await route.fetch();
  const json = await response.json();
  json.featureFlag = true;
  await route.fulfill({ response, body: JSON.stringify(json) });
});

// Remove route handler
await page.unroute('**/api/users');
```

## Authentication Patterns

Use `storageState` to save and reuse auth across tests:

```ts
// global-setup.ts — run once before all tests
import { chromium } from '@playwright/test';

async function globalSetup() {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('http://localhost:3000/login');
  await page.getByLabel('Email').fill('admin@test.com');
  await page.getByLabel('Password').fill('password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('/dashboard');
  await page.context().storageState({ path: './auth/admin.json' });
  await browser.close();
}
export default globalSetup;
```

Reference in config:

```ts
export default defineConfig({
  globalSetup: require.resolve('./global-setup'),
  projects: [
    { name: 'authed', use: { storageState: './auth/admin.json' } },
    { name: 'guest', use: { storageState: { cookies: [], origins: [] } } },
  ],
});
```

## Visual Regression Testing

```ts
test('homepage matches screenshot', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveScreenshot('homepage.png');
});

test('component snapshot', async ({ page }) => {
  await page.goto('/components/card');
  await expect(page.getByTestId('product-card')).toHaveScreenshot('card.png', {
    maxDiffPixelRatio: 0.01,
    mask: [page.getByTestId('timestamp')],
  });
});
// Update baselines: npx playwright test --update-snapshots
// Non-visual snapshots:
expect(await page.content()).toMatchSnapshot('page.html');
```

## Component Testing

Test framework components in isolation (React, Vue, Svelte) with `@playwright/experimental-ct-react` (or `-vue`, `-svelte`):

```ts
import { test, expect } from '@playwright/experimental-ct-react';
import { Button } from './Button';

test('renders with label', async ({ mount }) => {
  const component = await mount(<Button label="Click me" />);
  await expect(component).toContainText('Click me');
});
```

## Parallel Execution and Test Isolation

Tests run in parallel by default, each in its own `BrowserContext` (isolated cookies, storage, cache):

```ts
export default defineConfig({
  fullyParallel: true,       // parallelize tests within files
  workers: 4,                // number of parallel workers
});

// Serial execution for dependent tests
test.describe.serial('checkout flow', () => {
  test('add to cart', async ({ page }) => { /* ... */ });
  test('complete payment', async ({ page }) => { /* ... */ });
});
```

## Trace Viewer and Debugging

```bash
npx playwright test --debug              # step-through inspector
npx playwright test --ui                 # interactive browser-based runner
npx playwright show-trace trace.zip      # view recorded trace
npx playwright codegen http://localhost:3000  # generate code by recording
```

Configure traces in `playwright.config.ts` via `trace: 'on-first-retry' | 'on' | 'retain-on-failure'`. Traces capture screenshots, DOM snapshots, network logs, and console output per action.

## CI/CD Integration

GitHub Actions workflow:

```yaml
name: Playwright Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npx playwright install --with-deps
      - run: npx playwright test
      - uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 30
```

Docker-based execution for consistent screenshots:

```yaml
    container:
      image: mcr.microsoft.com/playwright:v1.52.0-noble
      options: --user 1001
```

## Page Object Model

Encapsulate page interactions in reusable classes:

```ts
// pages/LoginPage.ts
import { type Page, type Locator } from '@playwright/test';

export class LoginPage {
  readonly emailInput: Locator;
  readonly passwordInput: Locator;
  readonly submitButton: Locator;

  constructor(private page: Page) {
    this.emailInput = page.getByLabel('Email');
    this.passwordInput = page.getByLabel('Password');
    this.submitButton = page.getByRole('button', { name: 'Sign in' });
  }

  async goto() {
    await this.page.goto('/login');
  }

  async login(email: string, password: string) {
    await this.emailInput.fill(email);
    await this.passwordInput.fill(password);
    await this.submitButton.click();
  }
}

// tests/login.spec.ts
test('login works', async ({ page }) => {
  const loginPage = new LoginPage(page);
  await loginPage.goto();
  await loginPage.login('user@example.com', 'pass');
  await expect(page).toHaveURL('/dashboard');
});
```

## Mobile Emulation and Responsive Testing

```ts
import { devices } from '@playwright/test';
export default defineConfig({
  projects: [
    { name: 'mobile-chrome', use: { ...devices['Pixel 7'] } },
    { name: 'mobile-safari', use: { ...devices['iPhone 14'] } },
    { name: 'tablet', use: { ...devices['iPad Pro 11'] } },
  ],
});
```

Use `isMobile` fixture in tests to branch on viewport size.

## Multi-Tab and Multi-Window Scenarios

```ts
test('link opens new tab', async ({ page, context }) => {
  await page.goto('/');
  const [newPage] = await Promise.all([
    context.waitForEvent('page'),
    page.getByRole('link', { name: 'Open docs' }).click(),
  ]);
  await newPage.waitForLoadState();
  await expect(newPage).toHaveURL(/\/docs/);
});

test('multi-user chat', async ({ browser }) => {
  const userA = await browser.newPage();
  const userB = await browser.newPage();
  await userA.goto('/chat');
  await userB.goto('/chat');
  await userA.getByLabel('Message').fill('Hello from A');
  await userA.getByRole('button', { name: 'Send' }).click();
  await expect(userB.getByText('Hello from A')).toBeVisible();
});
```

## Fixtures and Test Hooks

Define custom fixtures to share setup across tests:

```ts
import { test as base } from '@playwright/test';
import { LoginPage } from './pages/LoginPage';

export const test = base.extend<{ loginPage: LoginPage }>({
  loginPage: async ({ page }, use) => {
    const loginPage = new LoginPage(page);
    await loginPage.goto();
    await use(loginPage);
  },
});
export { expect } from '@playwright/test';

// Usage:
import { test, expect } from './fixtures';
test('dashboard loads', async ({ loginPage, page }) => {
  await loginPage.login('admin@test.com', 'pass');
  await expect(page).toHaveURL('/dashboard');
});
```

Run: `npx playwright test`, `npx playwright test --project=chromium`,
`npx playwright test tests/login.spec.ts`, `npx playwright test --grep "login"`.

## References

In-depth guides covering advanced topics, troubleshooting, and API details:

| Document | Description |
|----------|-------------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | POM with fixtures, custom/worker fixtures, API+UI testing, parallelism, sharding, custom reporters, multi-browser projects, auth with storageState, iframes, shadow DOM, web components, accessibility (axe-core), performance metrics, HAR recording/replay |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Flaky test diagnosis, strict mode violations, timing issues, selector strategies, debugging tools (trace viewer, UI mode, inspector, VS Code), CI issues (Docker, screenshots, deps), actionability checks, auto-waiting pitfalls, navigation races, file upload/download, geolocation/permissions |
| [`references/api-reference.md`](references/api-reference.md) | Complete API reference for Page, BrowserContext, Locator, expect, Route, Frame, Dialog, Download, FileChooser, Mouse, Keyboard, Touchscreen — with method signatures, params, return types, and examples |

## Scripts

Executable helpers for common Playwright workflows:

| Script | Usage |
|--------|-------|
| [`scripts/setup-playwright-ci.sh`](scripts/setup-playwright-ci.sh) | `./setup-playwright-ci.sh [--browsers chromium,firefox] [--shards 4]` — Installs Playwright, generates GitHub Actions workflow, configures caching |
| [`scripts/generate-page-object.sh`](scripts/generate-page-object.sh) | `./generate-page-object.sh --url http://localhost:3000/login --name LoginPage` — Generates POM TypeScript class and companion test file |
| [`scripts/run-visual-regression.sh`](scripts/run-visual-regression.sh) | `./run-visual-regression.sh [--project chromium] [--ci] [--docker]` — Runs visual regression tests with diff reporting and optional Docker consistency |

## Assets

Copy-ready templates for bootstrapping Playwright projects:

| Template | Description |
|----------|-------------|
| [`assets/playwright.config.ts`](assets/playwright.config.ts) | Production-ready config with chromium/firefox/webkit/mobile projects, retries, trace-on-first-retry, HTML+blob reporters, webServer |
| [`assets/global-setup.ts`](assets/global-setup.ts) | Authentication global setup that logs in and saves storageState for reuse across tests |
| [`assets/base-page.ts`](assets/base-page.ts) | Abstract base POM class with navigation, screenshots, test-ID utilities, waiting helpers, assertions, form interactions, and network mocking |
| [`assets/github-actions-playwright.yml`](assets/github-actions-playwright.yml) | GitHub Actions workflow with npm/browser caching, 4-shard matrix, blob report merging, and artifact upload |
