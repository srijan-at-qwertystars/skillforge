# Playwright Troubleshooting Guide

## Table of Contents

- [Flaky Test Diagnosis](#flaky-test-diagnosis)
- [Auto-Waiting Issues](#auto-waiting-issues)
- [Strict Mode Violations](#strict-mode-violations)
- [Timeout Tuning](#timeout-tuning)
- [Element Detached Errors](#element-detached-errors)
- [Navigation Race Conditions](#navigation-race-conditions)
- [Pop-up and Dialog Handling](#pop-up-and-dialog-handling)
- [Iframe Issues](#iframe-issues)
- [CI-Specific Problems](#ci-specific-problems)
- [Screenshot Comparison Failures](#screenshot-comparison-failures)
- [Trace File Analysis](#trace-file-analysis)

---

## Flaky Test Diagnosis

### Identifying Flaky Tests

```bash
# Run tests multiple times to surface flakiness
npx playwright test --repeat-each=5

# Run only previously failed tests
npx playwright test --last-failed

# Use retries to confirm flakiness (passes on retry = flaky)
npx playwright test --retries=3
```

### Common Causes and Fixes

**1. Race condition with data loading**

```ts
// BAD: checking before data arrives
await page.goto('/dashboard');
await expect(page.getByTestId('count')).toHaveText('42');

// GOOD: assertion auto-retries, but ensure the page is ready
await page.goto('/dashboard');
await expect(page.getByTestId('count')).toHaveText('42', { timeout: 10000 });
```

**2. Animation interference**

```ts
// Disable animations globally in config
use: {
  // Reduce motion to avoid animation timing issues
  contextOptions: {
    reducedMotion: 'reduce',
  },
},
```

**3. Test ordering dependency**

```bash
# Randomize test order to find coupling
npx playwright test --shard=1/1  # already randomized within shard
```

**4. Date/time sensitivity**

```ts
// Use clock API to freeze time
await page.clock.install({ time: new Date('2024-01-15T10:00:00') });
await page.goto('/dashboard');
await expect(page.getByText('January 15, 2024')).toBeVisible();
```

### Flaky Test Annotations

```ts
// Mark a test as known-flaky with a tracking issue
test('intermittent network test', {
  annotation: { type: 'issue', description: 'https://github.com/org/repo/issues/123' },
}, async ({ page }) => {
  // ...
});

// Retry only specific tests
test('flaky external API', { tag: '@flaky' }, async ({ page }) => {
  // ...
});
// Config: retries: process.env.CI ? 2 : 0
```

---

## Auto-Waiting Issues

### When Auto-Waiting Is Not Enough

Auto-waiting checks: visible, stable, enabled, receives events. It does NOT wait for:
- Network requests to complete
- Animations to finish
- Third-party scripts to load
- Custom JavaScript state changes

### Solving Auto-Wait Gaps

```ts
// Wait for network idle after complex interactions
await page.getByRole('button', { name: 'Load Data' }).click();
await page.waitForLoadState('networkidle');

// Wait for a specific API response
const responsePromise = page.waitForResponse('**/api/data');
await page.getByRole('button', { name: 'Refresh' }).click();
await responsePromise;

// Wait for a specific condition
await page.waitForFunction(() => {
  return document.querySelector('#chart')?.getAttribute('data-loaded') === 'true';
});

// Wait for element state beyond actionability
await page.getByTestId('modal').waitFor({ state: 'hidden' });
await page.getByTestId('spinner').waitFor({ state: 'detached' });
```

### Never Use `waitForTimeout`

```ts
// BAD: arbitrary wait — fragile and slow
await page.waitForTimeout(3000);

// GOOD: wait for the actual condition
await expect(page.getByRole('status')).toHaveText('Ready');
```

---

## Strict Mode Violations

### The Error

```
Error: locator.click: Error: strict mode violation:
  getByRole('button') resolved to 3 elements
```

### Fixes

```ts
// 1. Be more specific with the locator
await page.getByRole('button', { name: 'Submit' }).click();

// 2. Use .first() / .last() / .nth() when multiple are expected
await page.getByRole('listitem').first().click();

// 3. Narrow scope with chaining
const form = page.getByTestId('login-form');
await form.getByRole('button', { name: 'Submit' }).click();

// 4. Use filter to narrow results
await page.getByRole('row')
  .filter({ hasText: 'Alice' })
  .getByRole('button', { name: 'Edit' })
  .click();

// 5. Check how many elements match (debugging)
const count = await page.getByRole('button').count();
console.log(`Found ${count} buttons`);
```

---

## Timeout Tuning

### Timeout Hierarchy

```ts
// playwright.config.ts
export default defineConfig({
  timeout: 30_000,        // per-test timeout (default: 30s)
  expect: {
    timeout: 5_000,       // assertion timeout (default: 5s)
  },
  use: {
    actionTimeout: 10_000,  // click/fill/etc timeout (default: no limit)
    navigationTimeout: 15_000,  // goto/reload timeout (default: no limit)
  },
});
```

### Per-Test Overrides

```ts
// Slow test gets more time
test('large file upload', async ({ page }) => {
  test.setTimeout(120_000);
  // ...
});

// Slow assertion
await expect(page.getByText('Processing complete')).toBeVisible({
  timeout: 60_000,
});

// Mark entire describe as slow (3x default timeout)
test.describe('heavy integration', () => {
  test.slow();
  // ...
});
```

### Debugging Timeout Failures

```bash
# See exactly where time was spent
npx playwright test --trace on
# Then open the trace:
npx playwright show-trace test-results/*/trace.zip
```

In trace viewer, look at the timeline bar — long gaps indicate waits. The "Action" tab shows what condition wasn't met.

---

## Element Detached Errors

### The Error

```
Error: locator.click: Target element was detached from the DOM
```

### Causes and Fixes

**React/Vue re-rendering replaces elements during interaction:**

```ts
// BAD: element reference may go stale between lines
const button = page.getByRole('button', { name: 'Save' });
await page.getByLabel('Name').fill('Alice');  // triggers re-render
await button.click();  // button may have been replaced

// GOOD: use fresh locator (Playwright re-queries automatically)
await page.getByLabel('Name').fill('Alice');
await page.getByRole('button', { name: 'Save' }).click();
```

**Dynamic lists that re-sort or filter:**

```ts
// Wait for the list to stabilize before interacting
await expect(page.getByRole('listitem')).toHaveCount(5);
await page.getByRole('listitem').first().click();
```

**Content loaded via AJAX replaces DOM nodes:**

```ts
// Wait for the final content to appear
await expect(page.getByTestId('user-profile')).toBeVisible();
await page.getByTestId('user-profile').getByRole('button', { name: 'Edit' }).click();
```

---

## Navigation Race Conditions

### Common Pattern: Click Triggers Navigation

```ts
// BAD: navigation might complete before waitForURL registers
await page.getByRole('link', { name: 'Dashboard' }).click();
await page.waitForURL('/dashboard');

// GOOD: use Promise.all for simultaneous wait + action
await Promise.all([
  page.waitForURL('/dashboard'),
  page.getByRole('link', { name: 'Dashboard' }).click(),
]);

// ALSO GOOD: expect-based (auto-retries)
await page.getByRole('link', { name: 'Dashboard' }).click();
await expect(page).toHaveURL(/\/dashboard/);
```

### SPA Client-Side Navigation

SPAs don't trigger traditional navigation events:

```ts
// Don't use waitForNavigation — use URL assertion
await page.getByRole('link', { name: 'Settings' }).click();
await expect(page).toHaveURL(/\/settings/);
await expect(page.getByRole('heading')).toHaveText('Settings');
```

### Redirect Chains

```ts
// Login redirects through /auth/callback → /dashboard
await page.getByRole('button', { name: 'Sign in' }).click();
// Wait for the final destination, not intermediate redirects
await expect(page).toHaveURL(/\/dashboard/, { timeout: 15000 });
```

---

## Pop-up and Dialog Handling

### JavaScript Dialogs (alert, confirm, prompt)

Dialogs must be handled BEFORE the action that triggers them:

```ts
// Register handler before triggering the dialog
page.on('dialog', async (dialog) => {
  expect(dialog.type()).toBe('confirm');
  expect(dialog.message()).toContain('Are you sure?');
  await dialog.accept();
});
await page.getByRole('button', { name: 'Delete' }).click();

// One-time handler using once
page.once('dialog', (dialog) => dialog.accept());
await page.getByRole('button', { name: 'Reset' }).click();

// Prompt dialog — provide input
page.once('dialog', (dialog) => dialog.accept('My Answer'));
await page.getByRole('button', { name: 'Rename' }).click();
```

### Browser Pop-ups (window.open)

```ts
const [popup] = await Promise.all([
  page.waitForEvent('popup'),
  page.getByRole('link', { name: 'Open Preview' }).click(),
]);

await popup.waitForLoadState();
await expect(popup).toHaveURL(/\/preview/);
await expect(popup.getByRole('heading')).toHaveText('Preview');
await popup.close();
```

### Permission Prompts

```ts
// Grant permissions at context level
const context = await browser.newContext({
  permissions: ['geolocation', 'notifications'],
  geolocation: { latitude: 40.7128, longitude: -74.0060 },
});
```

---

## Iframe Issues

### Common Mistakes

```ts
// BAD: trying to use page locator inside iframe
await page.getByLabel('Card number').fill('4242...');  // won't find it

// GOOD: use frameLocator
await page.frameLocator('#payment-iframe').getByLabel('Card number').fill('4242...');
```

### Waiting for Iframe Content

```ts
// Frame may load asynchronously
const frame = page.frameLocator('#dynamic-frame');
await expect(frame.getByText('Loaded')).toBeVisible({ timeout: 10000 });
```

### Cross-Origin Iframes

```ts
// Playwright handles cross-origin iframes, but they require the frame to be attached
const frame = page.frameLocator('iframe[src*="external-widget.com"]');
await frame.getByRole('button', { name: 'Accept' }).click();
```

### Debugging: List All Frames

```ts
for (const frame of page.frames()) {
  console.log(`Frame: ${frame.name()} — ${frame.url()}`);
}
```

---

## CI-Specific Problems

### Headless Mode Differences

Some elements behave differently headless. Force consistent rendering:

```ts
// playwright.config.ts
use: {
  headless: true,
  launchOptions: {
    args: ['--disable-gpu', '--no-sandbox'],
  },
  viewport: { width: 1280, height: 720 },  // consistent viewport
},
```

### Docker Issues

```dockerfile
# Use official Playwright image — includes all browser deps
FROM mcr.microsoft.com/playwright:v1.52.0-noble

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx playwright install --with-deps
CMD ["npx", "playwright", "test"]
```

Common Docker issues:
- **Missing browser dependencies**: Always use `--with-deps` or the official image
- **Shared memory too small**: Add `--shm-size=2gb` or `--ipc=host` to `docker run`
- **Font rendering differences**: Install fonts or use the official image

### GitHub Actions Troubleshooting

```yaml
# Common fixes for CI failures
- name: Install Playwright
  run: npx playwright install --with-deps

# Increase shared memory for browser stability
- name: Run tests
  run: npx playwright test
  env:
    # Helps with browser crashes in CI
    PLAYWRIGHT_BROWSERS_PATH: 0
```

**Artifacts for debugging CI failures:**

```yaml
- uses: actions/upload-artifact@v4
  if: ${{ !cancelled() }}
  with:
    name: test-results
    path: |
      playwright-report/
      test-results/
    retention-days: 7
```

### CI Resource Constraints

```ts
// Reduce resource usage for CI
workers: process.env.CI ? 2 : undefined,  // limit parallelism
retries: process.env.CI ? 2 : 0,          // retry for transient failures
use: {
  trace: 'on-first-retry',   // only trace retries (saves disk)
  video: 'retain-on-failure', // only keep failure videos
},
```

---

## Screenshot Comparison Failures

### Understanding the Error

```
Error: Screenshot comparison failed:
  244 pixels (0.02% of all image pixels) are different.
```

### Fixing Comparison Issues

```ts
// Increase threshold for minor rendering differences
await expect(page).toHaveScreenshot('hero.png', {
  maxDiffPixelRatio: 0.05,  // allow 5% pixel difference
  threshold: 0.3,           // per-pixel color threshold (0-1)
});

// Mask dynamic content (timestamps, avatars, ads)
await expect(page).toHaveScreenshot('dashboard.png', {
  mask: [
    page.getByTestId('timestamp'),
    page.getByTestId('avatar'),
    page.locator('.ad-banner'),
  ],
});

// Hide animated elements
await expect(page).toHaveScreenshot('page.png', {
  animations: 'disabled',
  caret: 'hide',
});
```

### Updating Baselines

```bash
# Update all snapshots
npx playwright test --update-snapshots

# Update snapshots for specific tests
npx playwright test dashboard.spec.ts --update-snapshots
```

### Cross-Platform Baseline Differences

Screenshots differ across OS/browser. Use platform-specific baselines:

```ts
// playwright.config.ts
snapshotPathTemplate: '{testDir}/__screenshots__/{testFilePath}/{arg}{-projectName}{-snapshotSuffix}{ext}',
```

Run snapshot updates on CI (Linux) to ensure consistent baselines — don't use macOS-generated baselines on Linux CI.

---

## Trace File Analysis

### Capturing Traces

```ts
// playwright.config.ts
use: {
  trace: 'on-first-retry',   // default: capture trace on first retry
  // Other options: 'on', 'off', 'retain-on-failure', 'on-all-retries'
},
```

```bash
# Force traces for a specific run
npx playwright test --trace on
```

### Viewing Traces

```bash
# Open local trace file
npx playwright show-trace test-results/my-test/trace.zip

# Open trace from URL (CI artifacts)
npx playwright show-trace https://example.com/trace.zip
```

### What to Look for in Trace Viewer

1. **Timeline**: Shows wall-clock time for each action — find long gaps
2. **Actions**: Each locator action with before/after screenshots
3. **Network**: All requests/responses — check for failed or slow requests
4. **Console**: JavaScript console output and errors
5. **Source**: Test source code linked to each action
6. **Metadata**: Browser, viewport, OS info

### Attaching Traces to Test Reports

```ts
test('checkout flow', async ({ page }, testInfo) => {
  await page.context().tracing.start({ screenshots: true, snapshots: true });

  // ... test steps ...

  await page.context().tracing.stop({
    path: testInfo.outputPath('trace.zip'),
  });
  await testInfo.attach('trace', {
    path: testInfo.outputPath('trace.zip'),
    contentType: 'application/zip',
  });
});
```

### Programmatic Trace Analysis

```ts
// Extract trace info for custom reporting
import { parseTrace } from '@playwright/test';

// In globalTeardown or a custom reporter
const trace = await parseTrace('test-results/trace.zip');
for (const action of trace.actions) {
  if (action.duration > 5000) {
    console.warn(`Slow action: ${action.type} took ${action.duration}ms`);
  }
}
```
