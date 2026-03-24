---
name: playwright-e2e
description: >
  Write, debug, and maintain Playwright end-to-end tests in TypeScript/JavaScript.
  USE when: writing browser tests, E2E tests, integration tests with Playwright,
  setting up playwright.config.ts, creating page objects, testing with locators,
  mocking network requests, visual regression testing, API testing with request fixture,
  authentication with storageState, component testing, mobile emulation, CI/CD Playwright setup,
  debugging flaky tests, generating tests with codegen, configuring reporters, parallel execution,
  sharding test runs, intercepting routes, or using Playwright assertions.
  DO NOT USE when: writing unit tests with Jest/Vitest/Mocha without a browser, Cypress tests,
  Selenium/WebDriver tests, Puppeteer-only scripts, testing CLI tools, load testing with k6/Artillery,
  or backend-only API tests without Playwright's request fixture.
---

# Playwright E2E Testing

## Architecture

Playwright controls Chromium, Firefox, and WebKit via the DevTools protocol. Key abstractions:

- **Browser**: a launched browser instance. Reused across tests via fixtures.
- **BrowserContext**: an isolated session (cookies, storage, permissions). Each test gets a fresh context by default. Equivalent to an incognito profile.
- **Page**: a single tab. Most interactions happen here.
- **Auto-waiting**: every action waits for the element to be actionable (visible, enabled, stable, not obscured) before executing. Do NOT add manual `waitForTimeout` unless absolutely required.

## Setup

Initialize a new project:

```bash
npm init playwright@latest
# Generates: playwright.config.ts, tests/, tests-examples/, .github/workflows/playwright.yml
```

Install browsers:

```bash
npx playwright install --with-deps
```

### playwright.config.ts

```ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: [['html', { open: 'never' }], ['list']],
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
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

## Locators

Prefer user-facing locators. Priority: `getByRole` > `getByLabel` > `getByPlaceholder` > `getByText` > `getByTestId` > `locator` (CSS) > `locator` (XPath).

```ts
page.getByRole('button', { name: 'Submit' })   // ARIA role + accessible name
page.getByLabel('Email')                        // associated <label>
page.getByPlaceholder('Search...')              // placeholder text
page.getByText('Welcome back')                  // visible text
page.getByTestId('nav-menu')                    // data-testid attribute
page.locator('.card >> nth=0')                  // CSS selector
page.locator('xpath=//div[@class="item"]')      // XPath — last resort

// Chaining and filtering
const row = page.getByRole('row').filter({ hasText: 'John' });
await row.getByRole('button', { name: 'Edit' }).click();
await page.getByRole('listitem').nth(2).click();
const card = page.locator('.card').filter({ has: page.getByText('Premium') });
```

## Actions

```ts
await page.getByRole('button', { name: 'Submit' }).click();
await page.getByLabel('Email').fill('user@test.com');    // clears then types
await page.getByLabel('Name').clear();
await page.getByRole('checkbox', { name: 'Agree' }).check();
await page.getByLabel('Country').selectOption('US');
await page.keyboard.press('Enter');
await page.getByText('Menu').hover();
await page.getByText('Drag me').dragTo(page.getByText('Drop here'));
await page.getByLabel('Avatar').setInputFiles('photo.png');
```

## Assertions

All web-first assertions auto-retry until timeout. Use `expect(locator)` not `expect(await locator.textContent())`.

### Locator Assertions

```ts
await expect(page.getByText('Success')).toBeVisible();
await expect(page.getByRole('button')).toBeEnabled();
await expect(page.getByRole('checkbox')).toBeChecked();
await expect(page.getByLabel('Name')).toHaveValue('Alice');
await expect(page.getByRole('heading')).toHaveText('Dashboard');
await expect(page.getByRole('alert')).toContainText('saved');
await expect(page.getByRole('listitem')).toHaveCount(5);
await expect(page.getByTestId('status')).toHaveAttribute('data-state', 'active');
await expect(page.getByTestId('box')).toHaveClass(/highlight/);
```

### Page Assertions

```ts
await expect(page).toHaveURL(/\/dashboard/);
await expect(page).toHaveTitle('My App - Dashboard');
```

### Soft Assertions

```ts
await expect.soft(page.getByTestId('status')).toHaveText('Active');
await expect.soft(page.getByTestId('count')).toHaveText('5');
```

## Test Fixtures

Built-in: `page` (isolated page), `context` (isolated browser context), `browser` (shared instance), `request` (API context, no browser), `browserName` (string).

### Custom Fixtures

```ts
// fixtures.ts
import { test as base, expect } from '@playwright/test';
import { TodoPage } from './pages/todo-page';

type MyFixtures = {
  todoPage: TodoPage;
  apiToken: string;
};

export const test = base.extend<MyFixtures>({
  todoPage: async ({ page }, use) => {
    const todoPage = new TodoPage(page);
    await todoPage.goto();
    await use(todoPage);
    // teardown: runs after test
  },
  apiToken: async ({ request }, use) => {
    const res = await request.post('/api/auth', { data: { user: 'test' } });
    const { token } = await res.json();
    await use(token);
  },
});

export { expect };
```

Use in tests:

```ts
import { test, expect } from './fixtures';

test('add todo', async ({ todoPage }) => {
  await todoPage.addItem('Buy milk');
  await expect(todoPage.items).toHaveCount(1);
});
```

## Page Object Model

```ts
// pages/login-page.ts
import { type Page, type Locator, expect } from '@playwright/test';

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
    await this.page.waitForURL('/dashboard');
  }
}
```

## API Testing

Use the `request` fixture for browserless API tests:

```ts
import { test, expect } from '@playwright/test';

test.describe('API', () => {
  test('create and fetch user', async ({ request }) => {
    const createRes = await request.post('/api/users', {
      data: { name: 'Alice', email: 'alice@test.com' },
    });
    expect(createRes.ok()).toBeTruthy();
    expect(createRes.status()).toBe(201);

    const user = await createRes.json();
    expect(user).toHaveProperty('id');

    const getRes = await request.get(`/api/users/${user.id}`);
    expect(await getRes.json()).toMatchObject({ name: 'Alice' });
  });
});
```

## Authentication with storageState

### Setup Project Pattern (Recommended)

```ts
// tests/auth.setup.ts
import { test as setup, expect } from '@playwright/test';

const authFile = 'playwright/.auth/user.json';

setup('authenticate', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('admin@test.com');
  await page.getByLabel('Password').fill('password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('/dashboard');
  await page.context().storageState({ path: authFile });
});
```

Add to config:

```ts
projects: [
  { name: 'setup', testMatch: /.*\.setup\.ts/ },
  {
    name: 'chromium',
    use: { ...devices['Desktop Chrome'], storageState: 'playwright/.auth/user.json' },
    dependencies: ['setup'],
  },
],
```

Add `playwright/.auth/` to `.gitignore`.

## Visual Comparison

```ts
// Screenshot comparison — creates baseline on first run
await expect(page).toHaveScreenshot('homepage.png');

// Element screenshot
await expect(page.getByTestId('chart')).toHaveScreenshot('chart.png', {
  maxDiffPixelRatio: 0.05,
});

// Snapshot testing for non-visual data
expect(await page.getByTestId('table').textContent()).toMatchSnapshot('table.txt');
```

Update baselines: `npx playwright test --update-snapshots`

## Network Interception

```ts
// Mock an API endpoint
await page.route('**/api/users', async (route) => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify([{ id: 1, name: 'Mock User' }]),
  });
});

// Modify a response
await page.route('**/api/settings', async (route) => {
  const response = await route.fetch();
  const json = await response.json();
  json.featureFlag = true;
  await route.fulfill({ response, body: JSON.stringify(json) });
});

// Abort requests (block images, analytics)
await page.route('**/*.{png,jpg,jpeg}', (route) => route.abort());

// Wait for a specific request
const responsePromise = page.waitForResponse('**/api/data');
await page.getByRole('button', { name: 'Load' }).click();
const response = await responsePromise;
expect(response.status()).toBe(200);
```

## Parallelism and Sharding

```ts
// playwright.config.ts — file-level parallelism is default
export default defineConfig({
  fullyParallel: true,  // also parallelize tests within files
  workers: process.env.CI ? 4 : undefined,
});

// Serial execution for dependent tests
test.describe.configure({ mode: 'serial' });
```

Shard across CI machines:

```bash
# Machine 1              # Machine 2
npx playwright test --shard=1/2    npx playwright test --shard=2/2
```

## Reporters

```ts
// playwright.config.ts
reporter: [
  ['list'],                          // console output
  ['html', { open: 'never' }],      // HTML report at playwright-report/
  ['json', { outputFile: 'results.json' }],
  ['junit', { outputFile: 'results.xml' }],  // CI integration
],
```

View HTML report: `npx playwright show-report`

## CI/CD — GitHub Actions

```yaml
name: Playwright Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx playwright install --with-deps
      - run: npx playwright test
      - uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: playwright-report
          path: playwright-report/
```

Docker: `FROM mcr.microsoft.com/playwright:v1.52.0-noble`

## Debugging

```bash
npx playwright test --debug              # step-through debugger
npx playwright test --ui                 # interactive UI mode
npx playwright test --trace on           # record traces for all tests
npx playwright show-trace trace.zip      # open trace viewer
npx playwright codegen http://localhost:3000  # generate test code by recording
```

Use `page.pause()` in test code to pause execution and open the inspector.

Set `PWDEBUG=1` to auto-pause on every action.

## Component Testing (Experimental)

```bash
npm init playwright@latest -- --ct
# Installs @playwright/experimental-ct-react (or vue/svelte)
```

```ts
// Button.spec.tsx
import { test, expect } from '@playwright/experimental-ct-react';
import { Button } from './Button';

test('renders with text', async ({ mount }) => {
  const component = await mount(<Button label="Click me" />);
  await expect(component).toContainText('Click me');
  await component.click();
  await expect(component).toHaveClass(/active/);
});
```

## Mobile Emulation

```ts
// In config projects
{ name: 'mobile', use: { ...devices['iPhone 14'] } },
{ name: 'tablet', use: { ...devices['iPad Pro 11'] } },

// Or per-test
test('mobile nav', async ({ browser }) => {
  const context = await browser.newContext({
    ...devices['Pixel 7'],
    locale: 'en-US',
    geolocation: { latitude: 37.7749, longitude: -122.4194 },
    permissions: ['geolocation'],
  });
  const page = await context.newPage();
  await page.goto('/');
  await expect(page.getByRole('button', { name: 'Menu' })).toBeVisible();
});
```

## Common Pitfalls

1. **Never use `waitForTimeout`** — rely on auto-waiting locators and assertions instead.
2. **Never use `page.$()` or `page.evaluate` for assertions** — use `expect(locator)` for auto-retry.
3. **Do not chain `await locator.textContent()` into `expect()`** — use `toHaveText` / `toContainText`.
4. **Avoid CSS/XPath when `getByRole`/`getByLabel`/`getByText` work** — user-facing locators resist refactors.
5. **Don't share state between tests** — each test gets a fresh context. Use fixtures for setup.
6. **Don't forget `await`** — missing await causes flaky, non-deterministic failures.
7. **Don't hardcode viewport sizes** — use device descriptors from `devices` map.
8. **Store `storageState` outside source control** — add auth files to `.gitignore`.
9. **Use `webServer` in config** — let Playwright manage dev server lifecycle, don't start it manually.
10. **Use `test.describe.configure({ mode: 'serial' })` sparingly** — parallel-by-default is faster and catches coupling bugs.

## Quick Reference: Test Lifecycle

```
Browser (shared per worker)
  └─ BrowserContext (fresh per test)
       └─ Page (fresh per test)
            ├─ beforeEach hooks
            ├─ test body
            ├─ afterEach hooks
            └─ context.close() (automatic)
```

## Additional Resources

### References (`references/`)

- **[advanced-patterns.md](references/advanced-patterns.md)** — Custom fixtures (scoped, auto, option), parameterization, data-driven tests, global setup/teardown, project dependencies, multi-page testing, iframes, shadow DOM, downloads/uploads, clipboard, web/service workers, a11y (axe-core), performance
- **[troubleshooting.md](references/troubleshooting.md)** — Flaky test diagnosis, auto-waiting gaps, strict mode violations, timeout tuning, detached elements, navigation races, dialogs, iframe issues, CI problems (headless, Docker, GitHub Actions), screenshot diffs, trace analysis
- **[ci-integration.md](references/ci-integration.md)** — GitHub Actions (caching, sharding, report merging), GitLab CI, Docker, parallel strategies, test splitting, retries, artifact collection, custom reporters, merge queue testing

### Scripts (`scripts/`)

- **[setup-project.sh](scripts/setup-project.sh)** — Initialize Playwright: install browsers, generate config, CI workflow, directory structure, example tests
- **[generate-pom.sh](scripts/generate-pom.sh)** — Generate Page Object Model class from a URL by scraping interactive elements
- **[run-tests.sh](scripts/run-tests.sh)** — Smart test runner with retry, sharding, tag filtering, headed/debug/UI mode, reporting

### Assets (`assets/`)

- **[playwright.config.ts](assets/playwright.config.ts)** — Production-ready config with projects, retries, reporters, webServer
- **[page-object-template.ts](assets/page-object-template.ts)** — Base POM class with navigation, form, table, dialog helpers
- **[auth-setup.ts](assets/auth-setup.ts)** — Auth setup fixture with storageState (UI, API, and OAuth patterns)
- **[github-actions-playwright.yml](assets/github-actions-playwright.yml)** — CI workflow with browser caching, 4-way sharding, merged reports

## Example: Full Test File

```ts
// tests/checkout.spec.ts
import { test, expect } from '@playwright/test';

test.describe('Checkout flow', () => {
  test('add item and complete purchase', async ({ page }) => {
    await page.goto('/products');
    await page.getByRole('button', { name: 'Add to Cart' }).first().click();
    await expect(page.getByTestId('cart-count')).toHaveText('1');
    await page.getByRole('link', { name: 'Cart' }).click();
    await expect(page).toHaveURL(/\/cart/);
    await page.getByLabel('Address').fill('123 Main St');
    await page.getByLabel('City').fill('Springfield');
    await page.getByRole('button', { name: 'Place Order' }).click();
    await expect(page.getByRole('heading')).toHaveText('Order Confirmed');
  });
});
```

<!-- tested: pass -->
