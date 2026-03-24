# Advanced Playwright Patterns

## Table of Contents

- [Page Object Model with Fixtures](#page-object-model-with-fixtures)
- [Custom Test Fixtures](#custom-test-fixtures)
- [Worker Fixtures](#worker-fixtures)
- [API Testing Alongside UI](#api-testing-alongside-ui)
- [Parallel Execution Strategies](#parallel-execution-strategies)
- [Test Sharding Across CI Workers](#test-sharding-across-ci-workers)
- [Custom Reporter Development](#custom-reporter-development)
- [Multiple Browser Projects](#multiple-browser-projects)
- [Authenticated Test Suites](#authenticated-test-suites)
- [Iframe Handling](#iframe-handling)
- [Shadow DOM](#shadow-dom)
- [Web Component Testing](#web-component-testing)
- [Accessibility Testing with axe-core](#accessibility-testing-with-axe-core)
- [Performance Metrics Collection](#performance-metrics-collection)
- [HAR Recording and Replay](#har-recording-and-replay)

---

## Page Object Model with Fixtures

Combine POM classes with Playwright fixtures for clean, reusable test code.
Fixtures handle instantiation and lifecycle so tests stay focused on behavior.

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

### Using POM Fixtures in Tests

```ts
// tests/dashboard.spec.ts
import { test, expect } from '../fixtures';

test('dashboard shows user stats', async ({ dashboardPage }) => {
  await dashboardPage.goto();
  const revenue = await dashboardPage.getStatValue('Revenue');
  expect(revenue).toBeTruthy();
});

test('logout redirects to login', async ({ dashboardPage }) => {
  await dashboardPage.goto();
  await dashboardPage.logout();
});
```

---

## Custom Test Fixtures

Fixtures are the recommended way to share setup, state, and utilities across tests.
Each test gets its own fixture instance — isolation is guaranteed.

### Basic Custom Fixture

```ts
import { test as base } from '@playwright/test';

type TestFixtures = {
  todoPage: TodoPage;
  apiClient: APIClient;
};

export const test = base.extend<TestFixtures>({
  // Fixture with setup and teardown
  todoPage: async ({ page }, use) => {
    const todoPage = new TodoPage(page);
    await todoPage.goto();
    await todoPage.addTodo('Initial item');

    await use(todoPage); // test runs here

    // Teardown: clean up after test
    await todoPage.clearAll();
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

### Fixture Options

```ts
// Define configurable fixtures with default values
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

// Override in config per-project
export default defineConfig({
  projects: [
    {
      name: 'admin',
      use: { defaultUser: { email: 'admin@co.com', password: 'admin' } },
    },
  ],
});
```

### Automatic Fixtures

Fixtures that run for every test without being requested:

```ts
export const test = base.extend<{}, { autoMockAnalytics: void }>({
  // auto: true means it runs for all tests using this fixture set
  autoMockAnalytics: [async ({ page }, use) => {
    await page.route('**/analytics/**', route => route.abort());
    await use();
  }, { auto: true }],
});
```

---

## Worker Fixtures

Worker fixtures are shared across all tests running in the same worker process.
Use for expensive one-time setup like database seeding or server startup.

```ts
import { test as base } from '@playwright/test';

type WorkerFixtures = {
  dbConnection: DatabaseConnection;
  testServer: TestServer;
};

export const test = base.extend<{}, WorkerFixtures>({
  // Worker-scoped: created once per worker, shared across tests
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

Worker fixtures receive `workerInfo` with `workerIndex` for unique port allocation.

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

## Parallel Execution Strategies

### File-Level Parallelism (Default)

Each test file runs in its own worker. Tests within a file run sequentially.

```ts
export default defineConfig({
  workers: process.env.CI ? 4 : undefined, // auto-detect locally
});
```

### Full Parallelism

Every test runs in parallel, even within the same file:

```ts
export default defineConfig({
  fullyParallel: true,
  workers: '50%', // use half of available CPUs
});
```

### Per-File Control

```ts
// This specific file runs tests serially
test.describe.configure({ mode: 'serial' });

// Or parallel within this describe block
test.describe.configure({ mode: 'parallel' });
```

### Serial with Dependency

```ts
test.describe.serial('purchase flow', () => {
  test('add item to cart', async ({ page }) => { /* ... */ });
  test('checkout', async ({ page }) => { /* ... */ });
  test('verify order', async ({ page }) => { /* ... */ });
  // If 'checkout' fails, 'verify order' is skipped
});
```

---

## Test Sharding Across CI Workers

Split tests across multiple CI machines for faster pipelines.

### CLI Usage

```bash
# Machine 1 of 4
npx playwright test --shard=1/4

# Machine 2 of 4
npx playwright test --shard=2/4
```

### GitHub Actions Matrix Sharding

```yaml
jobs:
  test:
    strategy:
      matrix:
        shardIndex: [1, 2, 3, 4]
        shardTotal: [4]
    steps:
      - run: npx playwright test --shard=${{ matrix.shardIndex }}/${{ matrix.shardTotal }}
```

### Merge Sharded Reports

```bash
# After all shards complete, merge blob reports
npx playwright merge-reports --reporter=html ./all-blob-reports
```

Configure blob reporter for sharding:

```ts
export default defineConfig({
  reporter: process.env.CI ? 'blob' : 'html',
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

## Accessibility Testing with axe-core

Install: `npm install -D @axe-core/playwright`

```ts
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test.describe('accessibility', () => {
  test('homepage has no a11y violations', async ({ page }) => {
    await page.goto('/');
    const results = await new AxeBuilder({ page }).analyze();
    expect(results.violations).toEqual([]);
  });

  test('scan specific region', async ({ page }) => {
    await page.goto('/dashboard');
    const results = await new AxeBuilder({ page })
      .include('#main-content')
      .exclude('#third-party-widget')
      .analyze();
    expect(results.violations).toEqual([]);
  });

  test('check specific WCAG rules', async ({ page }) => {
    await page.goto('/form');
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21aa'])
      .analyze();
    expect(results.violations).toEqual([]);
  });

  test('disable specific rules', async ({ page }) => {
    await page.goto('/legacy');
    const results = await new AxeBuilder({ page })
      .disableRules(['color-contrast', 'region'])
      .analyze();
    expect(results.violations).toEqual([]);
  });
});
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
