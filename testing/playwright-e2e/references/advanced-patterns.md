# Advanced Playwright Patterns

## Table of Contents

- [Custom Fixtures Deep Dive](#custom-fixtures-deep-dive)
- [Test Parameterization](#test-parameterization)
- [Data-Driven Tests](#data-driven-tests)
- [Global Setup and Teardown](#global-setup-and-teardown)
- [Project Dependencies](#project-dependencies)
- [Multi-Page Testing](#multi-page-testing)
- [Iframe Handling](#iframe-handling)
- [Shadow DOM](#shadow-dom)
- [File Downloads and Uploads](#file-downloads-and-uploads)
- [Clipboard Operations](#clipboard-operations)
- [Web Workers](#web-workers)
- [Service Workers](#service-workers)
- [Accessibility Testing with axe-core](#accessibility-testing-with-axe-core)
- [Performance Testing](#performance-testing)

---

## Custom Fixtures Deep Dive

### Scoped Fixtures (Worker vs Test)

```ts
// Worker-scoped: shared across all tests in a worker (expensive resources)
type WorkerFixtures = { dbConnection: DatabaseClient };

export const test = base.extend<{}, WorkerFixtures>({
  dbConnection: [async ({}, use) => {
    const db = await DatabaseClient.connect(process.env.DB_URL!);
    await use(db);
    await db.disconnect();
  }, { scope: 'worker' }],
});
```

### Auto Fixtures

Fixtures with `auto: true` activate for every test without explicit reference:

```ts
export const test = base.extend<{ trackConsoleErrors: void }>({
  trackConsoleErrors: [async ({ page }, use) => {
    const errors: string[] = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') errors.push(msg.text());
    });
    await use();
    expect(errors, 'Console errors detected').toEqual([]);
  }, { auto: true }],
});
```

### Fixture Composition

Combine multiple fixture files by merging `test` exports:

```ts
// fixtures/index.ts
import { mergeTests } from '@playwright/test';
import { test as dbTest } from './db-fixtures';
import { test as authTest } from './auth-fixtures';
import { test as pageTest } from './page-fixtures';

export const test = mergeTests(dbTest, authTest, pageTest);
export { expect } from '@playwright/test';
```

### Option Fixtures

Configurable per-project options:

```ts
type Options = { locale: string; apiVersion: string };

export const test = base.extend<Options>({
  locale: ['en-US', { option: true }],
  apiVersion: ['v2', { option: true }],
});

// playwright.config.ts
projects: [
  { name: 'en', use: { locale: 'en-US', apiVersion: 'v2' } },
  { name: 'fr', use: { locale: 'fr-FR', apiVersion: 'v2' } },
],
```

---

## Test Parameterization

### Using `test.describe` with Loops

```ts
const viewports = [
  { name: 'desktop', width: 1280, height: 720 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'mobile', width: 375, height: 812 },
];

for (const vp of viewports) {
  test.describe(`${vp.name} viewport`, () => {
    test.use({ viewport: { width: vp.width, height: vp.height } });

    test('navigation renders correctly', async ({ page }) => {
      await page.goto('/');
      await expect(page.getByRole('navigation')).toBeVisible();
    });
  });
}
```

### Project-Based Parameterization

```ts
// playwright.config.ts — test the same suite against multiple environments
projects: [
  { name: 'staging', use: { baseURL: 'https://staging.app.com' } },
  { name: 'production', use: { baseURL: 'https://app.com' } },
],
```

---

## Data-Driven Tests

### CSV/JSON Test Data

```ts
import fs from 'fs';

interface TestUser { email: string; role: string; expectedPage: string }
const users: TestUser[] = JSON.parse(fs.readFileSync('./test-data/users.json', 'utf-8'));

for (const user of users) {
  test(`login as ${user.role}`, async ({ page }) => {
    await page.goto('/login');
    await page.getByLabel('Email').fill(user.email);
    await page.getByLabel('Password').fill('test-password');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(new RegExp(user.expectedPage));
  });
}
```

### Inline Data Tables

```ts
const testCases = [
  { input: '',           error: 'Email is required' },
  { input: 'not-email',  error: 'Invalid email format' },
  { input: 'a@b',        error: 'Invalid email format' },
  { input: 'user@ok.com', error: null },
] as const;

for (const { input, error } of testCases) {
  test(`email validation: "${input}"`, async ({ page }) => {
    await page.goto('/register');
    await page.getByLabel('Email').fill(input);
    await page.getByRole('button', { name: 'Submit' }).click();
    if (error) {
      await expect(page.getByRole('alert')).toHaveText(error);
    } else {
      await expect(page.getByRole('alert')).not.toBeVisible();
    }
  });
}
```

---

## Global Setup and Teardown

### globalSetup / globalTeardown

```ts
// global-setup.ts
import { chromium, type FullConfig } from '@playwright/test';

async function globalSetup(config: FullConfig) {
  // Seed database
  await seedDatabase();

  // Create shared auth state
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto(`${config.projects[0].use.baseURL}/login`);
  await page.getByLabel('Email').fill('admin@test.com');
  await page.getByLabel('Password').fill('password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.context().storageState({ path: './playwright/.auth/admin.json' });
  await browser.close();
}

export default globalSetup;
```

```ts
// playwright.config.ts
export default defineConfig({
  globalSetup: require.resolve('./global-setup'),
  globalTeardown: require.resolve('./global-teardown'),
});
```

### Prefer Setup Projects Over globalSetup

Setup projects are more flexible — they support tracing, retries, and parallelism:

```ts
projects: [
  { name: 'db-seed', testMatch: /db\.setup\.ts/ },
  { name: 'auth', testMatch: /auth\.setup\.ts/, dependencies: ['db-seed'] },
  { name: 'tests', dependencies: ['auth'] },
],
```

---

## Project Dependencies

Chain projects for ordered execution:

```ts
projects: [
  { name: 'seed',    testMatch: /seed\.setup\.ts/ },
  { name: 'auth',    testMatch: /auth\.setup\.ts/, dependencies: ['seed'] },
  { name: 'chromium', use: { ...devices['Desktop Chrome'],
    storageState: 'playwright/.auth/user.json' }, dependencies: ['auth'] },
  { name: 'cleanup', testMatch: /cleanup\.teardown\.ts/, dependencies: ['chromium'] },
],
```

Teardown projects run after dependents complete:

```ts
{ name: 'seed', testMatch: /seed\.setup\.ts/, teardown: 'cleanup' },
{ name: 'cleanup', testMatch: /cleanup\.teardown\.ts/ },
```

---

## Multi-Page Testing

### Multiple Tabs in One Context

```ts
test('open link in new tab', async ({ context, page }) => {
  await page.goto('/dashboard');

  const [newPage] = await Promise.all([
    context.waitForEvent('page'),
    page.getByRole('link', { name: 'Open Report' }).click(),
  ]);

  await newPage.waitForLoadState();
  await expect(newPage).toHaveURL(/\/report/);
  await expect(newPage.getByRole('heading')).toHaveText('Report');

  // Interact across both tabs
  await page.bringToFront();
  await expect(page.getByText('Report opened')).toBeVisible();
});
```

### Multiple Browser Contexts (Isolated Sessions)

```ts
test('two users collaborate', async ({ browser }) => {
  const adminContext = await browser.newContext({ storageState: 'auth/admin.json' });
  const userContext = await browser.newContext({ storageState: 'auth/user.json' });

  const adminPage = await adminContext.newPage();
  const userPage = await userContext.newPage();

  await adminPage.goto('/shared-doc');
  await adminPage.getByLabel('Title').fill('Updated Title');
  await adminPage.getByRole('button', { name: 'Save' }).click();

  await userPage.goto('/shared-doc');
  await expect(userPage.getByLabel('Title')).toHaveValue('Updated Title');

  await adminContext.close();
  await userContext.close();
});
```

---

## Iframe Handling

```ts
// By frame name or URL
const frame = page.frame({ name: 'payment-iframe' });
const frame2 = page.frame({ url: /stripe\.com/ });

// Using frameLocator (preferred — supports auto-waiting)
const stripe = page.frameLocator('#payment-frame');
await stripe.getByLabel('Card number').fill('4242424242424242');
await stripe.getByRole('button', { name: 'Pay' }).click();

// Nested iframes
const nested = page.frameLocator('#outer').frameLocator('#inner');
await nested.getByText('Content').click();
```

---

## Shadow DOM

Playwright pierces open shadow DOM by default with CSS locators:

```ts
// Pierces shadow DOM automatically
await page.locator('my-component').getByRole('button', { name: 'Click' }).click();

// Explicit shadow DOM traversal
await page.locator('my-component >> internal:shadow=button.submit').click();

// getByRole/getByText also pierce shadow DOM
await page.getByRole('button', { name: 'Shadow Button' }).click();
```

---

## File Downloads and Uploads

### Downloads

```ts
test('download report', async ({ page }) => {
  const downloadPromise = page.waitForEvent('download');
  await page.getByRole('link', { name: 'Export CSV' }).click();
  const download = await downloadPromise;

  expect(download.suggestedFilename()).toBe('report.csv');
  const path = await download.path();           // temp path
  await download.saveAs('./downloads/report.csv'); // save permanently

  const content = fs.readFileSync('./downloads/report.csv', 'utf-8');
  expect(content).toContain('Name,Email');
});
```

### Uploads

```ts
// Single file
await page.getByLabel('Upload').setInputFiles('test-data/document.pdf');

// Multiple files
await page.getByLabel('Upload').setInputFiles([
  'test-data/photo1.png',
  'test-data/photo2.png',
]);

// Clear file input
await page.getByLabel('Upload').setInputFiles([]);

// Drag-and-drop upload (non-input file upload)
const [fileChooser] = await Promise.all([
  page.waitForEvent('filechooser'),
  page.getByText('Drop files here').click(),
]);
await fileChooser.setFiles('test-data/document.pdf');
```

---

## Clipboard Operations

```ts
test('copy and paste', async ({ page, context }) => {
  // Grant clipboard permissions
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);

  await page.goto('/editor');
  await page.getByRole('button', { name: 'Copy Link' }).click();

  const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
  expect(clipboardText).toMatch(/https:\/\//);

  // Paste via keyboard
  await page.getByLabel('URL').focus();
  await page.keyboard.press('ControlOrMeta+V');
  await expect(page.getByLabel('URL')).toHaveValue(clipboardText);
});
```

---

## Web Workers

```ts
test('web worker processes data', async ({ page }) => {
  await page.goto('/processor');

  // Wait for worker to appear
  const worker = await page.waitForEvent('worker');
  console.log('Worker URL:', worker.url());

  // Evaluate inside the worker
  const result = await worker.evaluate(() => {
    return (self as any).processedCount;
  });
  expect(result).toBeGreaterThan(0);
});
```

---

## Service Workers

```ts
test('service worker caches resources', async ({ page, context }) => {
  // Wait for the SW to be active
  const sw = await context.waitForEvent('serviceworker');
  expect(sw.url()).toContain('sw.js');

  // Navigate offline — SW should serve cached content
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByText('Offline Mode')).toBeVisible();
});
```

---

## Accessibility Testing with axe-core

Install: `npm install -D @axe-core/playwright`

```ts
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

test.describe('accessibility', () => {
  test('home page has no a11y violations', async ({ page }) => {
    await page.goto('/');

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .exclude('#third-party-widget')
      .analyze();

    expect(results.violations).toEqual([]);
  });

  test('form has accessible labels', async ({ page }) => {
    await page.goto('/register');

    const results = await new AxeBuilder({ page })
      .include('#registration-form')
      .withRules(['label', 'color-contrast'])
      .analyze();

    expect(results.violations).toEqual([]);
  });
});
```

### Attach Violations to Test Report

```ts
test('accessible page', async ({ page }, testInfo) => {
  await page.goto('/');
  const results = await new AxeBuilder({ page }).analyze();

  await testInfo.attach('a11y-results', {
    body: JSON.stringify(results.violations, null, 2),
    contentType: 'application/json',
  });

  expect(results.violations).toEqual([]);
});
```

---

## Performance Testing

### Navigation Timing

```ts
test('page loads within budget', async ({ page }) => {
  await page.goto('/dashboard');

  const timing = await page.evaluate(() => {
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming;
    return {
      domContentLoaded: nav.domContentLoadedEventEnd - nav.startTime,
      load: nav.loadEventEnd - nav.startTime,
      ttfb: nav.responseStart - nav.requestStart,
    };
  });

  expect(timing.ttfb).toBeLessThan(500);
  expect(timing.domContentLoaded).toBeLessThan(2000);
  expect(timing.load).toBeLessThan(5000);
});
```

### Core Web Vitals

```ts
test('LCP is within budget', async ({ page }) => {
  await page.goto('/');

  const lcp = await page.evaluate(() => {
    return new Promise<number>((resolve) => {
      new PerformanceObserver((list) => {
        const entries = list.getEntries();
        resolve(entries[entries.length - 1].startTime);
      }).observe({ type: 'largest-contentful-paint', buffered: true });
    });
  });

  expect(lcp).toBeLessThan(2500);
});
```

### Network Request Counting

```ts
test('dashboard makes reasonable number of requests', async ({ page }) => {
  const requests: string[] = [];
  page.on('request', (req) => requests.push(req.url()));

  await page.goto('/dashboard');
  await page.waitForLoadState('networkidle');

  const apiCalls = requests.filter((url) => url.includes('/api/'));
  expect(apiCalls.length).toBeLessThan(15);
});
```
