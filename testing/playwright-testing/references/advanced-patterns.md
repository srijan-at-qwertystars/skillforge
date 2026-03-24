# Advanced Playwright Patterns

## Table of Contents

- [Page Object Model In Depth](#page-object-model-in-depth)
  - [Core POM Principles](#core-pom-principles)
  - [Component Objects and Composition](#component-objects-and-composition)
  - [POM Inheritance Hierarchy](#pom-inheritance-hierarchy)
  - [Navigation Returns New Page Objects](#navigation-returns-new-page-objects)
- [Fixtures Composition](#fixtures-composition)
  - [Wiring POM into Fixtures](#wiring-pom-into-fixtures)
  - [Custom Test Fixtures](#custom-test-fixtures)
  - [Fixture Options and Overrides](#fixture-options-and-overrides)
  - [Automatic Fixtures](#automatic-fixtures)
  - [Worker Fixtures](#worker-fixtures)
  - [Fixture Composition Chains](#fixture-composition-chains)
- [Test Parallelization Strategies](#test-parallelization-strategies)
  - [File-Level vs Full Parallelism](#file-level-vs-full-parallelism)
  - [Serial Mode and Dependencies](#serial-mode-and-dependencies)
  - [Worker Count Tuning](#worker-count-tuning)
- [Sharding](#sharding)
  - [CLI Sharding](#cli-sharding)
  - [GitHub Actions Matrix Sharding](#github-actions-matrix-sharding)
  - [Merging Sharded Reports](#merging-sharded-reports)
  - [Balancing Shards](#balancing-shards)
- [Worker Reuse and Isolation](#worker-reuse-and-isolation)
- [Custom Matchers](#custom-matchers)
  - [expect.extend Basics](#expectextend-basics)
  - [Async Custom Matchers](#async-custom-matchers)
  - [Polling with toPass](#polling-with-topass)
- [Parameterized Tests](#parameterized-tests)
  - [Array-Driven Parameterization](#array-driven-parameterization)
  - [Data-Driven from External Sources](#data-driven-from-external-sources)
  - [Describe-Level Parameterization](#describe-level-parameterization)
- [Visual Regression Workflows](#visual-regression-workflows)
  - [Screenshot Assertions](#screenshot-assertions)
  - [Masking Dynamic Content](#masking-dynamic-content)
  - [Baseline Management](#baseline-management)
  - [CI Visual Testing with Docker](#ci-visual-testing-with-docker)
- [Accessibility Testing with @axe-core/playwright](#accessibility-testing-with-axe-coreplwywright)
  - [Basic Setup](#basic-setup)
  - [Scoped Scanning](#scoped-scanning)
  - [WCAG Compliance Tags](#wcag-compliance-tags)
  - [Custom a11y Fixture](#custom-a11y-fixture)
  - [Violation Reporting](#violation-reporting)
- [API Testing Alongside UI](#api-testing-alongside-ui)
- [Custom Reporter Development](#custom-reporter-development)
- [Multiple Browser Projects](#multiple-browser-projects)
- [Authenticated Test Suites](#authenticated-test-suites)
- [Iframe Handling](#iframe-handling)
- [Shadow DOM](#shadow-dom)
- [Web Component Testing](#web-component-testing)
- [Performance Metrics Collection](#performance-metrics-collection)
- [HAR Recording and Replay](#har-recording-and-replay)

---

## Page Object Model In Depth

### Core POM Principles

1. **Encapsulate selectors**: all locators defined as class properties in the constructor
2. **Actions as methods**: each user interaction is a named method
3. **No assertions in POMs**: page objects describe what a page *can do*, not what it *should be*
4. **Return type signals navigation**: methods that navigate return the target page object
5. **Stateless**: POMs hold locators, not test state

```ts
// pages/LoginPage.ts
import { type Page, type Locator } from '@playwright/test';
import { DashboardPage } from './DashboardPage';

export class LoginPage {
  readonly emailInput: Locator;
  readonly passwordInput: Locator;
  readonly submitButton: Locator;
  readonly errorMessage: Locator;
  readonly forgotPasswordLink: Locator;

  constructor(private readonly page: Page) {
    this.emailInput = page.getByLabel('Email');
    this.passwordInput = page.getByLabel('Password');
    this.submitButton = page.getByRole('button', { name: 'Sign in' });
    this.errorMessage = page.getByRole('alert');
    this.forgotPasswordLink = page.getByRole('link', { name: /forgot password/i });
  }

  async goto() {
    await this.page.goto('/login');
  }

  async login(email: string, password: string): Promise<DashboardPage> {
    await this.emailInput.fill(email);
    await this.passwordInput.fill(password);
    await this.submitButton.click();
    return new DashboardPage(this.page);
  }

  async loginExpectingError(email: string, password: string) {
    await this.emailInput.fill(email);
    await this.passwordInput.fill(password);
    await this.submitButton.click();
  }
}
```

### Component Objects and Composition

For shared UI elements (nav bars, modals, sidebars), extract **component objects**:

```ts
// components/NavigationBar.ts
export class NavigationBar {
  constructor(private readonly page: Page) {}

  readonly searchInput = this.page.getByRole('searchbox');
  readonly userMenu = this.page.getByTestId('user-menu');

  async search(query: string) {
    await this.searchInput.fill(query);
    await this.searchInput.press('Enter');
  }

  async openUserMenu() {
    await this.userMenu.click();
  }

  async logout() {
    await this.openUserMenu();
    await this.page.getByRole('menuitem', { name: 'Logout' }).click();
  }
}

// pages/DashboardPage.ts — composed with NavigationBar
export class DashboardPage {
  readonly nav: NavigationBar;
  readonly statsPanel: Locator;

  constructor(private readonly page: Page) {
    this.nav = new NavigationBar(page);
    this.statsPanel = page.getByTestId('stats-panel');
  }
}
```

### POM Inheritance Hierarchy

Use a base page class for common helpers shared across all page objects:

```ts
export abstract class BasePage {
  constructor(protected readonly page: Page) {}

  async waitForPageLoad() {
    await this.page.waitForLoadState('domcontentloaded');
  }

  async screenshot(name: string) {
    return this.page.screenshot({ path: `screenshots/${name}.png`, fullPage: true });
  }

  get currentURL() { return this.page.url(); }
}

export class ProductPage extends BasePage {
  readonly addToCartButton: Locator;

  constructor(page: Page) {
    super(page);
    this.addToCartButton = page.getByRole('button', { name: 'Add to Cart' });
  }

  async goto(productId: string) {
    await this.page.goto(`/products/${productId}`);
    await this.waitForPageLoad();
  }
}
```

### Navigation Returns New Page Objects

When an action causes navigation, return the destination POM:

```ts
// In CheckoutPage
async placeOrder(): Promise<OrderConfirmationPage> {
  await this.placeOrderButton.click();
  await this.page.waitForURL('**/order-confirmation/**');
  return new OrderConfirmationPage(this.page);
}

// Usage in test
const confirmPage = await checkoutPage.placeOrder();
await expect(confirmPage.orderNumber).toBeVisible();
```

---

## Fixtures Composition

### Wiring POM into Fixtures

```ts
// fixtures.ts
import { test as base } from '@playwright/test';
import { LoginPage } from './pages/LoginPage';
import { DashboardPage } from './pages/DashboardPage';
import { SettingsPage } from './pages/SettingsPage';

type Pages = {
  loginPage: LoginPage;
  dashboardPage: DashboardPage;
  settingsPage: SettingsPage;
};

export const test = base.extend<Pages>({
  loginPage: async ({ page }, use) => {
    await use(new LoginPage(page));
  },
  dashboardPage: async ({ page }, use) => {
    await use(new DashboardPage(page));
  },
  settingsPage: async ({ page }, use) => {
    await use(new SettingsPage(page));
  },
});

export { expect } from '@playwright/test';
```

### Custom Test Fixtures

Fixtures handle setup, teardown, and dependency injection. Each test gets its own instance.

```ts
import { test as base } from '@playwright/test';

type TestFixtures = {
  todoPage: TodoPage;
  apiClient: APIClient;
};

export const test = base.extend<TestFixtures>({
  todoPage: async ({ page }, use) => {
    const todoPage = new TodoPage(page);
    await todoPage.goto();
    await todoPage.addTodo('Initial item');
    await use(todoPage);         // test runs here
    await todoPage.clearAll();   // teardown
  },

  // Fixture depending on another fixture
  apiClient: async ({ baseURL }, use) => {
    const client = new APIClient(baseURL!);
    await client.authenticate();
    await use(client);
    await client.dispose();
  },
});
```

### Fixture Options and Overrides

```ts
type FixtureOptions = {
  defaultUser: { email: string; password: string };
};

export const test = base.extend<TestFixtures & FixtureOptions>({
  defaultUser: [{ email: 'test@test.com', password: 'pass' }, { option: true }],

  authenticatedPage: async ({ page, defaultUser }, use) => {
    await page.goto('/login');
    await page.getByLabel('Email').fill(defaultUser.email);
    await page.getByLabel('Password').fill(defaultUser.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await use(page);
  },
});

// Override per-project in config
projects: [
  { name: 'admin', use: { defaultUser: { email: 'admin@co.com', password: 'admin' } } },
]
```

### Automatic Fixtures

Run for every test without being explicitly requested:

```ts
export const test = base.extend<{}, { autoMockAnalytics: void }>({
  autoMockAnalytics: [async ({ page }, use) => {
    await page.route('**/analytics/**', route => route.abort());
    await use();
  }, { auto: true }],
});
```

### Worker Fixtures

Shared across all tests in the same worker. Use for expensive setup (DB, server):

```ts
export const test = base.extend<{}, WorkerFixtures>({
  dbConnection: [async ({}, use) => {
    const db = await DatabaseConnection.create();
    await db.migrate();
    await db.seed();
    await use(db);
    await db.close();
  }, { scope: 'worker' }],

  testServer: [async ({}, use, workerInfo) => {
    const port = 3000 + workerInfo.workerIndex;
    const server = await TestServer.start(port);
    await use(server);
    await server.stop();
  }, { scope: 'worker' }],
});
```

### Fixture Composition Chains

Fixtures can depend on other custom fixtures to build complex test environments:

```ts
export const test = base.extend<{
  db: TestDB;
  seededDB: TestDB;
  authenticatedPage: Page;
}>({
  db: async ({}, use) => {
    const db = await TestDB.connect();
    await use(db);
    await db.disconnect();
  },

  seededDB: async ({ db }, use) => {
    await db.seed('fixtures/test-data.sql');
    await use(db);
    await db.truncateAll();
  },

  authenticatedPage: async ({ page, seededDB }, use) => {
    const user = await seededDB.getUser('testuser');
    await page.goto('/login');
    await page.getByLabel('Email').fill(user.email);
    await page.getByLabel('Password').fill(user.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await use(page);
  },
});
```

---

## API Testing Alongside UI

Playwright can make direct API calls without a browser via `request` context.

### API-Only Tests

```ts
import { test, expect } from '@playwright/test';

test.describe('API tests', () => {
  test('create user via API', async ({ request }) => {
    const response = await request.post('/api/users', {
      data: { name: 'Alice', email: 'alice@test.com' },
    });
    expect(response.ok()).toBeTruthy();
    expect(response.status()).toBe(201);
    const body = await response.json();
    expect(body.name).toBe('Alice');
  });

  test('list users', async ({ request }) => {
    const response = await request.get('/api/users');
    const users = await response.json();
    expect(users.length).toBeGreaterThan(0);
  });
});
```

### Hybrid: API Setup + UI Verification

```ts
test('user created via API appears in UI', async ({ page, request }) => {
  // Create user via API (fast)
  await request.post('/api/users', {
    data: { name: 'Bob', role: 'editor' },
  });

  // Verify in UI
  await page.goto('/admin/users');
  await expect(page.getByRole('cell', { name: 'Bob' })).toBeVisible();
});
```

### Shared API Request Context with Auth

```ts
export const test = base.extend<{ authedRequest: APIRequestContext }>({
  authedRequest: async ({ playwright }, use) => {
    const context = await playwright.request.newContext({
      baseURL: 'http://localhost:3000',
      extraHTTPHeaders: {
        Authorization: `Bearer ${process.env.API_TOKEN}`,
      },
    });
    await use(context);
    await context.dispose();
  },
});
```

---

## Test Parallelization Strategies

### File-Level vs Full Parallelism

```ts
// File-level (default): each file in its own worker, tests within a file are sequential
export default defineConfig({
  workers: process.env.CI ? 4 : undefined,
});

// Full parallelism: every test runs in parallel, even within the same file
export default defineConfig({
  fullyParallel: true,
  workers: '50%', // use half of available CPUs
});
```

### Serial Mode and Dependencies

```ts
// Force sequential within a describe block
test.describe.configure({ mode: 'serial' });

// Or parallel within a specific describe
test.describe.configure({ mode: 'parallel' });

// Serial with dependency — if one fails, rest are skipped
test.describe.serial('purchase flow', () => {
  test('add item to cart', async ({ page }) => { /* ... */ });
  test('checkout', async ({ page }) => { /* ... */ });
  test('verify order', async ({ page }) => { /* ... */ });
});
```

### Worker Count Tuning

| Scenario | Setting | Notes |
|----------|---------|-------|
| Local dev | `workers: undefined` | Auto-detect CPUs |
| CI (small runner) | `workers: 1` or `workers: 2` | Prevent resource contention |
| CI (large runner) | `workers: '50%'` | Half available CPUs |
| CI (dedicated runner) | `workers: '75%'` | Leave headroom for OS |

---

## Sharding

### CLI Sharding

```bash
npx playwright test --shard=1/4   # machine 1 of 4
npx playwright test --shard=2/4   # machine 2 of 4
```

With `fullyParallel: true`, sharding distributes at test level. Without it, distribution is file-level — keep test files similarly sized.

### GitHub Actions Matrix Sharding

```yaml
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        shardIndex: [1, 2, 3, 4]
        shardTotal: [4]
    steps:
      - run: npx playwright test --shard=${{ matrix.shardIndex }}/${{ matrix.shardTotal }}
```

### Merging Sharded Reports

Configure blob reporter for sharding, then merge:

```ts
// playwright.config.ts
reporter: process.env.CI ? 'blob' : 'html',
```

```bash
# After all shards complete
npx playwright merge-reports --reporter=html ./all-blob-reports
```

### Balancing Shards

- Use `fullyParallel: true` for best distribution
- Monitor per-shard duration; rebalance by splitting large test files
- If one shard is consistently slower, it has too many heavy tests — redistribute

---

## Worker Reuse and Isolation

Each worker reuses the same browser instance but creates a **fresh BrowserContext per test**. This means:

- Cookies, localStorage, and sessionStorage are isolated per test
- Browser-level cache is shared within a worker (small speedup)
- Worker fixtures persist across tests in the same worker

To force full isolation (new browser per test), don't use `fullyParallel` and set `workers: 1`.

---

## Custom Matchers

### expect.extend Basics

```ts
import { expect } from '@playwright/test';

expect.extend({
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling;
    return {
      pass,
      message: () => `expected ${received} to be within range ${floor}–${ceiling}`,
    };
  },
});

// Usage
expect(price).toBeWithinRange(10, 50);
```

### Async Custom Matchers

```ts
expect.extend({
  async toHaveResponseStatus(response: APIResponse, expected: number) {
    const status = response.status();
    return {
      pass: status === expected,
      message: () => `expected status ${expected}, got ${status}`,
    };
  },
});

// Usage
const resp = await request.get('/api/health');
await expect(resp).toHaveResponseStatus(200);
```

### Polling with toPass

`expect.toPass()` retries a block until it succeeds:

```ts
await expect(async () => {
  const response = await page.request.get('/api/status');
  const json = await response.json();
  expect(json.ready).toBe(true);
}).toPass({
  intervals: [1_000, 2_000, 5_000],
  timeout: 30_000,
});
```

---

## Parameterized Tests

### Array-Driven Parameterization

```ts
const testCases = [
  { role: 'admin', canDelete: true },
  { role: 'editor', canDelete: false },
  { role: 'viewer', canDelete: false },
];

for (const { role, canDelete } of testCases) {
  test(`${role} ${canDelete ? 'can' : 'cannot'} delete items`, async ({ page }) => {
    await loginAs(page, role);
    await page.goto('/items/1');
    if (canDelete) {
      await expect(page.getByRole('button', { name: 'Delete' })).toBeVisible();
    } else {
      await expect(page.getByRole('button', { name: 'Delete' })).not.toBeVisible();
    }
  });
}
```

### Data-Driven from External Sources

```ts
import testData from './fixtures/users.json';

for (const user of testData) {
  test(`user ${user.name} sees correct dashboard`, async ({ page }) => {
    await page.goto(`/dashboard?user=${user.id}`);
    await expect(page.getByRole('heading')).toHaveText(`Welcome, ${user.name}`);
  });
}
```

### Describe-Level Parameterization

```ts
const browsers = ['chromium', 'firefox', 'webkit'] as const;
const viewports = [
  { name: 'desktop', width: 1280, height: 720 },
  { name: 'mobile', width: 375, height: 667 },
];

for (const vp of viewports) {
  test.describe(`${vp.name} viewport`, () => {
    test.use({ viewport: { width: vp.width, height: vp.height } });

    test('navigation is visible', async ({ page }) => {
      await page.goto('/');
      await expect(page.getByRole('navigation')).toBeVisible();
    });
  });
}
```

---

## Visual Regression Workflows

### Screenshot Assertions

```ts
test('homepage visual', async ({ page }) => {
  await page.goto('/');
  // Full page
  await expect(page).toHaveScreenshot('homepage.png', { fullPage: true });
  // Component-level
  await expect(page.locator('.hero')).toHaveScreenshot('hero-section.png');
});
```

### Masking Dynamic Content

```ts
await expect(page).toHaveScreenshot('dashboard.png', {
  mask: [
    page.getByTestId('current-time'),
    page.getByTestId('user-avatar'),
    page.locator('.ad-banner'),
  ],
  maxDiffPixelRatio: 0.02,
});
```

### Baseline Management

```bash
# Generate/update baselines
npx playwright test --update-snapshots

# Baselines stored per-platform:
# tests/__snapshots__/test-name-chromium-linux.png
# tests/__snapshots__/test-name-chromium-darwin.png
```

Config for snapshot tolerance:

```ts
expect: {
  toHaveScreenshot: {
    maxDiffPixelRatio: 0.01,  // allow 1% pixel difference
    threshold: 0.2,           // per-pixel color threshold (0-1)
    animations: 'disabled',   // freeze CSS animations
  },
},
```

### CI Visual Testing with Docker

Run in Playwright Docker image for consistent font rendering across environments:

```bash
docker run --rm --ipc=host \
  -v $(pwd):/work -w /work \
  mcr.microsoft.com/playwright:v1.52.0-noble \
  npx playwright test --update-snapshots
```

---

## Accessibility Testing with @axe-core/playwright

### Basic Setup

```bash
npm install -D @axe-core/playwright
```

```ts
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test('homepage has no a11y violations', async ({ page }) => {
  await page.goto('/');
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});
```

### Scoped Scanning

```ts
test('scan specific region', async ({ page }) => {
  await page.goto('/dashboard');
  const results = await new AxeBuilder({ page })
    .include('#main-content')
    .exclude('#third-party-widget')
    .analyze();
  expect(results.violations).toEqual([]);
});
```

### WCAG Compliance Tags

```ts
const results = await new AxeBuilder({ page })
  .withTags(['wcag2a', 'wcag2aa', 'wcag21aa'])  // WCAG 2.1 AA
  .analyze();

// Disable specific rules for known issues
const results2 = await new AxeBuilder({ page })
  .disableRules(['color-contrast', 'region'])
  .analyze();
```

### Custom a11y Fixture

```ts
export const test = base.extend<{ makeAxeBuilder: () => AxeBuilder }>({
  makeAxeBuilder: async ({ page }, use) => {
    await use(() =>
      new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa'])
        .exclude('#known-issue')
    );
  },
});

// Usage
test('form is accessible', async ({ page, makeAxeBuilder }) => {
  await page.goto('/form');
  const results = await makeAxeBuilder().analyze();
  expect(results.violations).toEqual([]);
});
```

### Violation Reporting

```ts
test('a11y check with detailed reporting', async ({ page }) => {
  await page.goto('/');
  const results = await new AxeBuilder({ page }).analyze();

  // Generate readable report on failure
  const violationReport = results.violations.map(v => ({
    id: v.id,
    impact: v.impact,
    description: v.description,
    nodes: v.nodes.length,
    targets: v.nodes.map(n => n.target).flat(),
  }));

  expect(results.violations, JSON.stringify(violationReport, null, 2)).toEqual([]);
});
```

---

## Custom Reporter Development

Build reporters implementing Playwright's `Reporter` interface.

```ts
// reporters/slack-reporter.ts
import type {
  Reporter, FullConfig, Suite, TestCase, TestResult, FullResult
} from '@playwright/test/reporter';

class SlackReporter implements Reporter {
  private passed = 0;
  private failed = 0;
  private skipped = 0;

  onBegin(config: FullConfig, suite: Suite): void {
    console.log(`Running ${suite.allTests().length} tests`);
  }

  onTestEnd(test: TestCase, result: TestResult): void {
    switch (result.status) {
      case 'passed': this.passed++; break;
      case 'failed': this.failed++; break;
      case 'skipped': this.skipped++; break;
    }
  }

  async onEnd(result: FullResult): Promise<void> {
    const message = [
      `*Playwright Results*: ${result.status}`,
      `✅ Passed: ${this.passed}`,
      `❌ Failed: ${this.failed}`,
      `⏭️ Skipped: ${this.skipped}`,
      `⏱️ Duration: ${(result.duration / 1000).toFixed(1)}s`,
    ].join('\n');

    await fetch(process.env.SLACK_WEBHOOK_URL!, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: message }),
    });
  }

  onStdOut(chunk: string | Buffer, test?: TestCase): void {
    // Handle stdout from tests
  }

  onStdErr(chunk: string | Buffer, test?: TestCase): void {
    // Handle stderr from tests
  }
}

export default SlackReporter;
```

Register in config:

```ts
export default defineConfig({
  reporter: [
    ['html'],
    ['./reporters/slack-reporter.ts'],
    ['junit', { outputFile: 'results.xml' }],
  ],
});
```

---

## Multiple Browser Projects

Projects allow running the same tests across different browsers and configurations.

```ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  projects: [
    // Desktop browsers
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },

    // Mobile viewports
    { name: 'mobile-chrome', use: { ...devices['Pixel 7'] } },
    { name: 'mobile-safari', use: { ...devices['iPhone 14'] } },

    // Branded browsers
    { name: 'edge', use: { ...devices['Desktop Edge'], channel: 'msedge' } },
    { name: 'chrome', use: { ...devices['Desktop Chrome'], channel: 'chrome' } },

    // Custom configuration
    {
      name: 'high-dpi',
      use: {
        viewport: { width: 2560, height: 1440 },
        deviceScaleFactor: 2,
      },
    },
  ],
});
```

### Running Specific Projects

```bash
npx playwright test --project=chromium --project=firefox
```

### Project Dependencies

```ts
export default defineConfig({
  projects: [
    { name: 'setup', testMatch: /global\.setup\.ts/ },
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        storageState: './auth/state.json',
      },
      dependencies: ['setup'],
    },
  ],
});
```

---

## Authenticated Test Suites

### Global Setup/Teardown with storageState

```ts
// global-setup.ts
import { chromium, type FullConfig } from '@playwright/test';

async function globalSetup(config: FullConfig) {
  const { baseURL, storageState } = config.projects[0].use;
  const browser = await chromium.launch();
  const page = await browser.newPage();

  await page.goto(baseURL + '/login');
  await page.getByLabel('Username').fill(process.env.TEST_USER!);
  await page.getByLabel('Password').fill(process.env.TEST_PASSWORD!);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('**/dashboard');

  await page.context().storageState({ path: storageState as string });
  await browser.close();
}

export default globalSetup;
```

### Multiple Auth Roles

```ts
// auth.setup.ts — using project dependencies (modern approach)
import { test as setup, expect } from '@playwright/test';

const adminFile = 'playwright/.auth/admin.json';
const userFile = 'playwright/.auth/user.json';

setup('authenticate as admin', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('admin@company.com');
  await page.getByLabel('Password').fill(process.env.ADMIN_PASS!);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('/admin');
  await page.context().storageState({ path: adminFile });
});

setup('authenticate as user', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('user@company.com');
  await page.getByLabel('Password').fill(process.env.USER_PASS!);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('/home');
  await page.context().storageState({ path: userFile });
});
```

Config with role-based projects:

```ts
export default defineConfig({
  projects: [
    { name: 'auth-setup', testMatch: /auth\.setup\.ts/ },
    {
      name: 'admin-tests',
      testMatch: /.*\.admin\.spec\.ts/,
      use: { storageState: 'playwright/.auth/admin.json' },
      dependencies: ['auth-setup'],
    },
    {
      name: 'user-tests',
      testMatch: /.*\.user\.spec\.ts/,
      use: { storageState: 'playwright/.auth/user.json' },
      dependencies: ['auth-setup'],
    },
    {
      name: 'guest-tests',
      testMatch: /.*\.guest\.spec\.ts/,
      use: { storageState: { cookies: [], origins: [] } },
    },
  ],
});
```

---

## Iframe Handling

```ts
// Access iframe by frame locator (preferred)
const frame = page.frameLocator('#payment-iframe');
await frame.getByLabel('Card number').fill('4242424242424242');
await frame.getByRole('button', { name: 'Pay' }).click();

// Nested iframes
const nested = page
  .frameLocator('#outer-frame')
  .frameLocator('#inner-frame');
await nested.getByText('Content').click();

// Access frame by name or URL
const namedFrame = page.frame({ name: 'editor' });
const urlFrame = page.frame({ url: /third-party\.com/ });
if (namedFrame) {
  await namedFrame.locator('#editor-input').fill('text');
}

// Wait for iframe to load
const frameHandle = await page.waitForEvent('frameattached');
await frameHandle.waitForLoadState();
```

---

## Shadow DOM

Playwright automatically pierces open shadow DOM. Use `locator()` as normal:

```ts
// Automatic piercing — works through shadow roots
await page.locator('my-component').getByText('Hello').click();

// Target elements inside shadow DOM
await page.locator('custom-input input').fill('value');

// For closed shadow DOM, evaluate in page context
const value = await page.evaluate(() => {
  const host = document.querySelector('my-element');
  const shadowRoot = host?.shadowRoot;
  return shadowRoot?.querySelector('span')?.textContent;
});
```

---

## Web Component Testing

```ts
test('custom element renders slots', async ({ page }) => {
  await page.setContent(`
    <my-card>
      <span slot="title">Card Title</span>
      <p slot="content">Card content here</p>
    </my-card>
  `);

  await expect(page.locator('my-card')).toBeVisible();
  await expect(page.getByText('Card Title')).toBeVisible();
  await expect(page.getByText('Card content here')).toBeVisible();
});

test('custom element fires events', async ({ page }) => {
  await page.setContent('<my-button></my-button>');

  const eventPromise = page.evaluate(() =>
    new Promise<string>(resolve => {
      document.querySelector('my-button')!
        .addEventListener('custom-click', (e: any) => resolve(e.detail));
    })
  );

  await page.locator('my-button').click();
  const detail = await eventPromise;
  expect(detail).toBe('clicked');
});
```

---

## Performance Metrics Collection

```ts
test('measure page performance', async ({ page }) => {
  await page.goto('/');
  const metrics = await page.evaluate(() => {
    const perf = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming;
    return {
      domContentLoaded: perf.domContentLoadedEventEnd - perf.startTime,
      load: perf.loadEventEnd - perf.startTime,
      ttfb: perf.responseStart - perf.startTime,
    };
  });
  expect(metrics.ttfb).toBeLessThan(800);
  expect(metrics.load).toBeLessThan(5000);
});

// CDP-based metrics (Chromium only)
test('collect CDP performance metrics', async ({ page, browserName }) => {
  test.skip(browserName !== 'chromium', 'CDP only available in Chromium');
  const client = await page.context().newCDPSession(page);
  await client.send('Performance.enable');
  await page.goto('/');
  const { metrics } = await client.send('Performance.getMetrics');

  const jsHeap = metrics.find(m => m.name === 'JSHeapUsedSize');
  expect(jsHeap!.value).toBeLessThan(50 * 1024 * 1024); // 50MB
});
```

---

## HAR Recording and Replay

### Recording HAR Files

```ts
// Record all network traffic to a HAR file
const context = await browser.newContext({
  recordHar: {
    path: './network/login-flow.har',
    urlFilter: '**/api/**', // only API calls
  },
});

const page = await context.newPage();
await page.goto('/login');
await page.getByLabel('Email').fill('user@test.com');
await page.getByRole('button', { name: 'Sign in' }).click();

await context.close(); // HAR is saved on close
```

### Replaying from HAR (Mock Network)

```ts
test('replay from HAR', async ({ page }) => {
  // Route all matching requests from HAR file
  await page.routeFromHAR('./network/login-flow.har', {
    url: '**/api/**',
    update: false, // set true to re-record if requests change
  });

  await page.goto('/login');
  // API responses come from the HAR file
  await page.getByLabel('Email').fill('user@test.com');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL('/dashboard');
});
```

### HAR with Update Mode

```ts
// First run records; subsequent runs replay. Re-record by deleting HAR.
await page.routeFromHAR('./hars/api-responses.har', {
  url: '**/api/**',
  update: true, // records if HAR missing, replays if present
});
```

### CLI HAR Recording

```bash
# Record HAR via CLI
npx playwright open --save-har=demo.har --save-har-glob="**/api/**" https://example.com
```
