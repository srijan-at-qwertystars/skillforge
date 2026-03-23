---
name: playwright-e2e-testing
description:
  positive: "Use when user writes E2E tests with Playwright, asks about page object model, test fixtures, locators, auto-waiting, network interception, visual regression, or Playwright configuration and CI setup."
  negative: "Do NOT use for Cypress, Selenium, Puppeteer, or unit/integration testing frameworks (use pytest-patterns for Python tests)."
---

# Playwright End-to-End Testing

## Setup and Configuration

Install Playwright and initialize the project:

```bash
npm init playwright@latest
npx playwright install --with-deps
```

### playwright.config.ts

```typescript
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [
    ['html'],
    ['junit', { outputFile: 'results.xml' }],
  ],
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
    { name: 'mobile-chrome', use: { ...devices['Pixel 7'] } },
    { name: 'mobile-safari', use: { ...devices['iPhone 14'] } },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
  },
});
```

Set `fullyParallel: true` to run tests in parallel across files and within files. Use `projects` to target multiple browsers and devices. Configure `webServer` to auto-start the dev server before tests.

## Locator Strategies

Prefer user-facing locators in this order:

1. `getByRole` — best for interactive elements, filters hidden elements by default
2. `getByLabel` — form inputs with associated labels
3. `getByPlaceholder` — inputs with stable placeholder text
4. `getByText` — visible static text
5. `getByTestId` — escape hatch for elements without accessible roles
6. CSS/XPath — last resort only

```typescript
// Preferred: role-based
await page.getByRole('button', { name: 'Submit' }).click();
await page.getByRole('heading', { level: 1 }).toBeVisible();

// Form inputs
await page.getByLabel('Email address').fill('user@example.com');
await page.getByPlaceholder('Search...').fill('query');

// Test IDs for complex widgets
await page.getByTestId('date-picker').click();

// Chaining and filtering
const row = page.getByRole('row').filter({ hasText: 'John' });
await row.getByRole('button', { name: 'Edit' }).click();

// Scoped locators
const nav = page.getByRole('navigation');
await nav.getByRole('link', { name: 'Dashboard' }).click();

// nth element when multiple matches exist
await page.getByRole('listitem').nth(2).click();
```

Never use CSS classes or DOM structure for selectors — they break on refactors. Use `data-testid` only when no semantic locator exists.

## Auto-Waiting and Assertions

Playwright auto-waits for elements to be actionable (visible, enabled, stable) before performing actions. Never add manual sleeps.

```typescript
import { test, expect } from '@playwright/test';

test('form submission shows success', async ({ page }) => {
  await page.goto('/contact');
  await page.getByLabel('Name').fill('Alice');
  await page.getByRole('button', { name: 'Send' }).click();

  // Auto-retrying assertions — poll until condition met or timeout
  await expect(page.getByText('Message sent')).toBeVisible();
  await expect(page.getByRole('alert')).toHaveText('Success');
  await expect(page).toHaveURL(/\/thank-you/);
  await expect(page).toHaveTitle('Thank You');
});

test('table loads data', async ({ page }) => {
  await page.goto('/users');
  // Wait for specific count
  await expect(page.getByRole('row')).toHaveCount(11); // header + 10 rows
  // Negative assertion
  await expect(page.getByText('Loading...')).not.toBeVisible();
});

// Custom polling assertion
await expect.poll(async () => {
  const response = await page.request.get('/api/status');
  return response.json();
}, { timeout: 30_000 }).toEqual({ status: 'ready' });
```

Use `expect` with auto-retrying matchers (`toBeVisible`, `toHaveText`, `toHaveCount`, `toHaveURL`). Avoid `waitForTimeout()` — it causes flaky tests.

## Page Object Model

Encapsulate page interactions in classes. Keep selectors and actions in the page object; keep assertions in tests.

```typescript
// pages/login-page.ts
import { type Locator, type Page } from '@playwright/test';

export class LoginPage {
  readonly emailInput: Locator;
  readonly passwordInput: Locator;
  readonly submitButton: Locator;
  readonly errorMessage: Locator;

  constructor(private readonly page: Page) {
    this.emailInput = page.getByLabel('Email');
    this.passwordInput = page.getByLabel('Password');
    this.submitButton = page.getByRole('button', { name: 'Sign in' });
    this.errorMessage = page.getByRole('alert');
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
import { test, expect } from '@playwright/test';
import { LoginPage } from '../pages/login-page';

test('successful login redirects to dashboard', async ({ page }) => {
  const loginPage = new LoginPage(page);
  await loginPage.goto();
  await loginPage.login('admin@test.com', 'password123');
  await expect(page).toHaveURL('/dashboard');
});

test('invalid credentials show error', async ({ page }) => {
  const loginPage = new LoginPage(page);
  await loginPage.goto();
  await loginPage.login('wrong@test.com', 'bad');
  await expect(loginPage.errorMessage).toHaveText('Invalid credentials');
});
```

Structure: one page object per page/component. Store in `tests/pages/` or `pages/`. Page objects return data or void — never assert internally.

## Test Fixtures

### Built-in Fixtures

Playwright provides `page`, `context`, `browser`, `browserName`, and `request` as built-in fixtures. Each test gets a fresh `BrowserContext` and `Page` by default.

### Custom Fixtures

```typescript
// fixtures.ts
import { test as base } from '@playwright/test';
import { LoginPage } from './pages/login-page';
import { DashboardPage } from './pages/dashboard-page';

type MyFixtures = {
  loginPage: LoginPage;
  dashboardPage: DashboardPage;
  authenticatedPage: Page;
};

export const test = base.extend<MyFixtures>({
  loginPage: async ({ page }, use) => {
    await use(new LoginPage(page));
  },

  dashboardPage: async ({ page }, use) => {
    await use(new DashboardPage(page));
  },

  // Fixture with setup logic
  authenticatedPage: async ({ browser }, use) => {
    const context = await browser.newContext({
      storageState: 'playwright/.auth/user.json',
    });
    const page = await context.newPage();
    await use(page);
    await context.close();
  },
});

export { expect } from '@playwright/test';
```

### Worker-Scoped Fixtures

Share expensive resources across tests in the same worker:

```typescript
import { test as base } from '@playwright/test';

export const test = base.extend<{}, { dbConnection: DbClient }>({
  dbConnection: [async ({}, use) => {
    const db = await connectToDb();
    await use(db);
    await db.close();
  }, { scope: 'worker' }],
});
```

## Network Interception

Use `page.route()` or `context.route()` to intercept, mock, or block network requests.

```typescript
test('display mocked user data', async ({ page }) => {
  // Mock API response
  await page.route('**/api/users', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify([
        { id: 1, name: 'Alice', role: 'Admin' },
        { id: 2, name: 'Bob', role: 'User' },
      ]),
    });
  });

  await page.goto('/users');
  await expect(page.getByRole('row')).toHaveCount(3);
});

test('handle API error gracefully', async ({ page }) => {
  await page.route('**/api/users', (route) =>
    route.fulfill({ status: 500, body: 'Server Error' })
  );
  await page.goto('/users');
  await expect(page.getByText('Something went wrong')).toBeVisible();
});

test('modify response data', async ({ page }) => {
  await page.route('**/api/settings', async (route) => {
    const response = await route.fetch();
    const json = await response.json();
    json.featureFlag = true;
    await route.fulfill({ response, body: JSON.stringify(json) });
  });
  await page.goto('/settings');
});

// Block analytics and third-party scripts
await page.route('**/{analytics,tracking}/**', (route) => route.abort());

// Wait for a specific request
const responsePromise = page.waitForResponse('**/api/save');
await page.getByRole('button', { name: 'Save' }).click();
const response = await responsePromise;
expect(response.status()).toBe(200);
```

Scope route mocks to individual tests. Use `route.fetch()` to modify real responses. Store mock data in JSON fixture files for reuse.

## Authentication

### Global Setup with storageState

```typescript
// playwright.config.ts
export default defineConfig({
  projects: [
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        storageState: 'playwright/.auth/user.json',
      },
      dependencies: ['setup'],
    },
  ],
});

// tests/auth.setup.ts
import { test as setup, expect } from '@playwright/test';

setup('authenticate', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('admin@test.com');
  await page.getByLabel('Password').fill('password123');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('/dashboard');
  await page.context().storageState({ path: 'playwright/.auth/user.json' });
});
```

Add `playwright/.auth/` to `.gitignore`. Use separate setup projects for different user roles (admin, regular user). The `dependencies` array ensures setup runs first.

## Visual Regression Testing

```typescript
test('homepage matches snapshot', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveScreenshot('homepage.png');
});

test('component visual check', async ({ page }) => {
  await page.goto('/components');
  const card = page.getByTestId('profile-card');

  // Element screenshot with masking dynamic content
  await expect(card).toHaveScreenshot('profile-card.png', {
    mask: [page.locator('.timestamp'), page.locator('.avatar')],
    maxDiffPixelRatio: 0.01,
  });
});

// Full-page screenshot
await expect(page).toHaveScreenshot('full-page.png', { fullPage: true });
```

First run creates baseline snapshots. Subsequent runs diff against baselines. Update baselines with `npx playwright test --update-snapshots`. Set `maxDiffPixelRatio` or `maxDiffPixels` to control sensitivity. Mask dynamic elements (timestamps, avatars, ads) to prevent false failures. Store snapshots in version control.

Configure in `playwright.config.ts`:

```typescript
export default defineConfig({
  expect: {
    toHaveScreenshot: { maxDiffPixelRatio: 0.01 },
  },
});
```

## Parallel Execution and Test Isolation

Each test runs in its own `BrowserContext` — cookies, storage, and cache are isolated by default. Avoid shared mutable state between tests.

```typescript
// Run tests within a file in parallel
test.describe.configure({ mode: 'parallel' });

// Serial execution when order matters (avoid when possible)
test.describe.configure({ mode: 'serial' });
```

Set `fullyParallel: true` in config for maximum parallelism. Control worker count with `workers` option or `--workers=4` CLI flag. Use `test.describe.configure({ mode: 'serial' })` only when tests have true sequential dependencies.

## Debugging

```bash
# Run with Playwright Inspector (step-by-step)
npx playwright test --debug

# Run specific test in headed mode
npx playwright test login.spec.ts --headed

# Generate and view trace
npx playwright test --trace on
npx playwright show-trace trace.zip

# Run with UI mode (interactive test runner)
npx playwright test --ui

# Generate test code by recording actions
npx playwright codegen http://localhost:3000
```

Enable traces on failure in config:

```typescript
use: {
  trace: 'on-first-retry',  // or 'retain-on-failure'
  video: 'retain-on-failure',
},
```

Use `page.pause()` in test code to open Inspector at a specific point. Use `--ui` mode for interactive exploration during development.

## CI/CD Integration

### GitHub Actions

```yaml
name: Playwright Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shardIndex: [1, 2, 3, 4]
        shardTotal: [4]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npx playwright install --with-deps
      - run: npx playwright test --shard=${{ matrix.shardIndex }}/${{ matrix.shardTotal }}
      - uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: playwright-report-${{ matrix.shardIndex }}
          path: playwright-report/
          retention-days: 7
```

### Docker

```dockerfile
FROM mcr.microsoft.com/playwright:v1.52.0-noble
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx playwright test
```

Use the official Playwright Docker image matching your installed version. Set `workers: 1` in CI for stability, or increase with available resources. Use sharding via matrix strategy to distribute tests across runners. Merge reports from shards in a separate job using `npx playwright merge-reports`.

## Mobile and Responsive Testing

```typescript
import { devices } from '@playwright/test';

// In config projects:
{ name: 'mobile', use: { ...devices['iPhone 14'] } },
{ name: 'tablet', use: { ...devices['iPad Pro 11'] } },

// Custom viewport in test
test('responsive layout', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await expect(page.getByRole('button', { name: 'Menu' })).toBeVisible();
});

// Geolocation and permissions
test('location-based content', async ({ context }) => {
  await context.grantPermissions(['geolocation']);
  const page = await context.newPage();
  await page.goto('/store-locator');
});
```

Use `devices` presets for accurate device emulation (viewport, user agent, device scale factor, touch support). Test mobile navigation patterns (hamburger menus, swipe gestures) and responsive breakpoints.

## Common Patterns and Anti-Patterns

### Do

- Use `getByRole` and semantic locators as the default strategy.
- Keep tests independent — each test sets up its own state.
- Use `storageState` for auth instead of logging in on every test.
- Mock external APIs to avoid flaky network-dependent tests.
- Run `--trace on-first-retry` to debug CI failures.
- Use `expect` auto-retrying assertions instead of manual waits.
- Store page objects separately from test files.
- Run the full suite against multiple browsers via `projects`.

### Do Not

- Use `page.waitForTimeout()` — rely on auto-waiting and assertions instead.
- Use CSS class selectors — they break on styling changes.
- Share state between tests — leads to order-dependent failures.
- Put assertions inside page objects — keep them in test files.
- Use `page.$()` or `page.evaluate()` for element interaction — use locators.
- Hardcode absolute URLs — use `baseURL` in config.
- Skip browser cleanup — let Playwright manage contexts automatically.
- Use `{ force: true }` to click elements — fix the underlying accessibility issue.

<!-- tested: pass -->
