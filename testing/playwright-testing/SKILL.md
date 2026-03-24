---
name: playwright-testing
description: >
  End-to-end browser testing with Playwright. Use when: setting up Playwright,
  writing e2e/integration tests, cross-browser testing, browser automation,
  page object model design, visual regression testing, test fixtures, authentication
  flows, network mocking, mobile emulation, CI/CD integration with GitHub Actions,
  debugging with trace viewer, test generation with codegen, multi-tab/multi-browser
  scenarios, parallel execution, selector strategies.
  Do NOT use for: unit tests without a browser, API-only testing without UI,
  Selenium-specific or Cypress-specific questions, performance/load testing,
  accessibility-only audits unrelated to e2e flows.
---

# Playwright End-to-End Testing

## Installation & Setup

```bash
# Initialize new project (creates config, example tests, GitHub Actions workflow)
npm init playwright@latest

# Or add to existing project
npm install -D @playwright/test
npx playwright install --with-deps  # installs browsers + OS deps
```

Recommended project structure:
```
├── playwright.config.ts
├── tests/
│   ├── auth.setup.ts
│   ├── home.spec.ts
│   └── checkout.spec.ts
├── pages/
│   ├── HomePage.ts
│   └── CheckoutPage.ts
├── fixtures/
│   └── test-fixtures.ts
└── test-results/
```

## Configuration (playwright.config.ts)

```typescript
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? '50%' : undefined,
  reporter: [
    ['html', { open: 'never' }],
    ['junit', { outputFile: 'test-results/results.xml' }],
  ],
  use: {
    baseURL: process.env.BASE_URL || 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 10_000,
    navigationTimeout: 30_000,
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
    {
      name: 'mobile-chrome',
      use: { ...devices['Pixel 7'] },
      dependencies: ['setup'],
    },
    {
      name: 'mobile-safari',
      use: { ...devices['iPhone 14'] },
      dependencies: ['setup'],
    },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
  },
});
```

Key config options:
- `fullyParallel`: run tests in parallel across and within files.
- `webServer`: auto-start dev server before tests.
- `projects[].dependencies`: chain setup projects (auth) before test projects.
- `retries`: set >0 in CI to handle flakiness.

## Writing Tests

```typescript
import { test, expect } from '@playwright/test';

test.describe('Shopping Cart', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/products');
  });

  test('add item to cart', async ({ page }) => {
    await page.getByRole('button', { name: 'Add to Cart' }).first().click();
    await expect(page.getByTestId('cart-count')).toHaveText('1');
  });

  test('remove item from cart', async ({ page }) => {
    await page.getByRole('button', { name: 'Add to Cart' }).first().click();
    await page.getByRole('link', { name: 'Cart' }).click();
    await page.getByRole('button', { name: 'Remove' }).click();
    await expect(page.getByTestId('cart-count')).toHaveText('0');
  });
});
```

## Locators (Selector Strategy)

Prefer semantic locators in this priority:

```typescript
// 1. Role-based (BEST — resilient, accessible)
page.getByRole('button', { name: 'Submit' })
page.getByRole('heading', { level: 2 })
page.getByRole('link', { name: /sign in/i })

// 2. Label/placeholder/text
page.getByLabel('Email address')
page.getByPlaceholder('Search...')
page.getByText('Welcome back')

// 3. Test ID (stable, decoupled from UI text)
page.getByTestId('submit-btn')

// 4. CSS/XPath (LAST RESORT)
page.locator('.card >> nth=0')
```

Chaining and filtering:
```typescript
page.getByRole('listitem').filter({ hasText: 'Product A' })
page.getByRole('listitem').filter({ has: page.getByRole('button', { name: 'Buy' }) })
page.getByRole('listitem').nth(2)
page.locator('.sidebar').getByRole('link', { name: 'Settings' })
```

## Assertions

```typescript
// Element state
await expect(page.getByRole('button')).toBeVisible();
await expect(page.getByRole('button')).toBeEnabled();
await expect(page.locator('.modal')).toBeHidden();

// Text and values
await expect(page.getByRole('heading')).toHaveText('Dashboard');
await expect(page.getByRole('heading')).toContainText('Dash');
await expect(page.locator('input')).toHaveValue('hello');

// Count
await expect(page.getByRole('listitem')).toHaveCount(5);

// Page-level
await expect(page).toHaveURL(/.*dashboard/);
await expect(page).toHaveTitle(/My App/);

// Visual comparison
await expect(page).toHaveScreenshot('dashboard.png');

// Negation
await expect(page.locator('.error')).not.toBeVisible();

// Soft assertions (don't stop test on failure)
await expect.soft(page.getByTestId('status')).toHaveText('Active');
```

All `expect` assertions auto-wait and retry. Never use `page.waitForTimeout()`.

## Custom Fixtures

```typescript
// fixtures/test-fixtures.ts
import { test as base } from '@playwright/test';
import { HomePage } from '../pages/HomePage';
import { CheckoutPage } from '../pages/CheckoutPage';

type MyFixtures = {
  homePage: HomePage;
  checkoutPage: CheckoutPage;
};

export const test = base.extend<MyFixtures>({
  homePage: async ({ page }, use) => {
    const homePage = new HomePage(page);
    await homePage.goto();
    await use(homePage);
  },
  checkoutPage: async ({ page }, use) => {
    await use(new CheckoutPage(page));
  },
});
export { expect } from '@playwright/test';
```

Usage:
```typescript
import { test, expect } from '../fixtures/test-fixtures';

test('search products', async ({ homePage }) => {
  await homePage.search('laptop');
  await expect(homePage.resultCount).toHaveText(/\d+ results/);
});
```

## Page Object Model

```typescript
// pages/LoginPage.ts
import { type Page, type Locator } from '@playwright/test';

export class LoginPage {
  readonly emailInput: Locator;
  readonly passwordInput: Locator;
  readonly submitButton: Locator;
  readonly errorMessage: Locator;

  constructor(private page: Page) {
    this.emailInput = page.getByLabel('Email');
    this.passwordInput = page.getByLabel('Password');
    this.submitButton = page.getByRole('button', { name: 'Sign in' });
    this.errorMessage = page.getByRole('alert');
  }

  async goto() { await this.page.goto('/login'); }

  async login(email: string, password: string) {
    await this.emailInput.fill(email);
    await this.passwordInput.fill(password);
    await this.submitButton.click();
  }
}
```

POM rules: define locators in constructor, actions as methods. Never put assertions in page objects. Return new page objects from navigation methods.

## Authentication Handling

```typescript
// tests/auth.setup.ts
import { test as setup } from '@playwright/test';
const authFile = 'playwright/.auth/user.json';

setup('authenticate', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('user@example.com');
  await page.getByLabel('Password').fill('password123');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('/dashboard');
  await page.context().storageState({ path: authFile });
});
```

Config reference:
```typescript
{
  name: 'chromium',
  use: { ...devices['Desktop Chrome'], storageState: 'playwright/.auth/user.json' },
  dependencies: ['setup'],
}
```

For multi-role testing, create separate setup projects per role with distinct `storageState` files.

## Visual Comparison

```typescript
test('visual regression', async ({ page }) => {
  await page.goto('/dashboard');
  await expect(page).toHaveScreenshot('full-page.png', {
    fullPage: true,
    maxDiffPixelRatio: 0.02,
  });
  await expect(page.locator('.sidebar')).toHaveScreenshot('sidebar.png');
});
```

Update baselines: `npx playwright test --update-snapshots`

## Network Mocking & Interception

```typescript
test('mock API response', async ({ page }) => {
  await page.route('**/api/products', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify([{ id: 1, name: 'Mock Product', price: 9.99 }]),
    });
  });
  await page.goto('/products');
  await expect(page.getByText('Mock Product')).toBeVisible();
});

test('modify response', async ({ page }) => {
  await page.route('**/api/user', async (route) => {
    const response = await route.fetch();
    const json = await response.json();
    json.name = 'Modified Name';
    await route.fulfill({ response, body: JSON.stringify(json) });
  });
  await page.goto('/profile');
});

test('abort requests', async ({ page }) => {
  await page.route('**/*.{png,jpg}', (route) => route.abort());
  await page.goto('/gallery');
});

// Wait for specific API call
test('wait for API', async ({ page }) => {
  const responsePromise = page.waitForResponse('**/api/data');
  await page.getByRole('button', { name: 'Load' }).click();
  const response = await responsePromise;
  expect(response.status()).toBe(200);
});
```

## Multi-Tab & Multi-Browser

```typescript
// Multi-tab (same context shares cookies)
test('multi-tab', async ({ page, context }) => {
  const [newPage] = await Promise.all([
    context.waitForEvent('page'),
    page.getByRole('link', { name: 'Open in new tab' }).click(),
  ]);
  await newPage.waitForLoadState();
  await expect(newPage).toHaveTitle(/New Tab/);
});

// Multi-browser (isolated contexts, e.g., chat between users)
test('chat between users', async ({ browser }) => {
  const ctx1 = await browser.newContext();
  const ctx2 = await browser.newContext();
  const page1 = await ctx1.newPage();
  const page2 = await ctx2.newPage();

  await page1.goto('/chat');
  await page2.goto('/chat');
  await page1.getByPlaceholder('Message').fill('Hello');
  await page1.getByRole('button', { name: 'Send' }).click();
  await expect(page2.getByText('Hello')).toBeVisible();

  await ctx1.close();
  await ctx2.close();
});
```

## Mobile Emulation

Built into config via `devices`. Custom viewports:
```typescript
{
  name: 'custom-mobile',
  use: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true },
}
```

Geolocation and permissions:
```typescript
test('geolocation', async ({ context, page }) => {
  await context.grantPermissions(['geolocation']);
  await context.setGeolocation({ latitude: 40.7128, longitude: -74.006 });
  await page.goto('/store-locator');
  await expect(page.getByText('New York')).toBeVisible();
});
```

## Parallel Execution

- `fullyParallel: true` in config runs all tests in parallel.
- Each test gets its own isolated browser context.
- Control workers: `workers: 4` or `workers: '50%'`.
- Shard across CI machines: `npx playwright test --shard=1/4`.

```yaml
strategy:
  matrix:
    shard: [1/4, 2/4, 3/4, 4/4]
steps:
  - run: npx playwright test --shard=${{ matrix.shard }}
```

## CI/CD (GitHub Actions)

```yaml
name: Playwright Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: lts/*
      - run: npm ci
      - run: npx playwright install --with-deps
      - run: npx playwright test
      - uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 14
```

## Debugging

```bash
npx playwright test --headed              # see the browser
npx playwright test --debug               # step-through inspector
npx playwright test tests/login.spec.ts   # single file
npx playwright test --grep "add item"     # filter by title
npx playwright show-trace trace.zip       # view trace from failure
npx playwright show-report                # open HTML report
npx playwright test --ui                  # interactive UI mode
```

Set `trace: 'on'` in config to always capture. Trace viewer shows: snapshots, console logs, network requests, action timeline, source code.

## Test Generation (Codegen)

```bash
npx playwright codegen http://localhost:3000
npx playwright codegen --device="iPhone 14" http://localhost:3000
npx playwright codegen --load-storage=auth.json http://localhost:3000
npx playwright codegen --output=tests/generated.spec.ts http://localhost:3000
```

Codegen produces idiomatic code using `getByRole`, `getByLabel`, etc. Refactor output into page objects for maintainability.

## CLI Reference

```bash
npx playwright test                          # run all tests
npx playwright test --project=chromium       # single browser
npx playwright test --retries=3              # override retries
npx playwright test --update-snapshots       # update visual baselines
npx playwright test --shard=1/3              # CI sharding
npx playwright install                       # install browsers
```

## Anti-Patterns

- **Never use `page.waitForTimeout()`** — use auto-waiting locators/assertions.
- **Never use `page.$()` / `page.$$()`** — use `page.locator()`.
- **Avoid CSS class selectors** — use roles, labels, test IDs instead.
- **Don't share state between tests** — each test must be independent.
- **Don't put assertions in page objects** — page objects are action containers.
- **Avoid `force: true`** on clicks — it hides real UI bugs.
