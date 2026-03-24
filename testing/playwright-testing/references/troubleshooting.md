# Playwright Troubleshooting Guide

## Table of Contents

- [Flaky Test Diagnosis](#flaky-test-diagnosis)
- [Strict Mode Violations](#strict-mode-violations)
- [Timing and Race Conditions](#timing-and-race-conditions)
- [Stale Element Issues](#stale-element-issues)
- [Selector Strategies That Avoid Flakiness](#selector-strategies-that-avoid-flakiness)
- [Debugging Tools](#debugging-tools)
- [CI-Specific Issues](#ci-specific-issues)
- [Actionability Checks](#actionability-checks)
- [Auto-Waiting Pitfalls](#auto-waiting-pitfalls)
- [Navigation Race Conditions](#navigation-race-conditions)
- [File Download Edge Cases](#file-download-edge-cases)
- [File Upload Edge Cases](#file-upload-edge-cases)
- [Geolocation and Permissions Mocking](#geolocation-and-permissions-mocking)

---

## Flaky Test Diagnosis

Flaky tests pass and fail inconsistently. Common causes and solutions:

### Identifying Flaky Tests

```bash
# Run tests multiple times to detect flakiness
npx playwright test --repeat-each=5

# Run only previously failed tests
npx playwright test --last-failed

# Use retries to surface flaky tests (they pass on retry)
npx playwright test --retries=3
```

### Common Flakiness Patterns

**1. Animation/transition interference:**

```ts
// BAD: clicking during animation
await page.getByRole('button', { name: 'Menu' }).click();
await page.getByRole('menuitem', { name: 'Settings' }).click(); // may fail

// GOOD: wait for animation to complete
await page.getByRole('button', { name: 'Menu' }).click();
const menuItem = page.getByRole('menuitem', { name: 'Settings' });
await menuItem.waitFor({ state: 'visible' });
await menuItem.click();
```

**2. Non-deterministic data ordering:**

```ts
// BAD: depends on specific row order
await page.getByRole('row').nth(2).click();

// GOOD: find by content
await page.getByRole('row').filter({ hasText: 'Alice' }).click();
```

**3. Shared state between tests:**

```ts
// BAD: test depends on previous test's state
test('create item', async ({ page }) => { /* creates item */ });
test('verify item exists', async ({ page }) => { /* checks item */ });

// GOOD: each test sets up its own state
test('verify item exists', async ({ page, request }) => {
  await request.post('/api/items', { data: { name: 'Test' } });
  await page.goto('/items');
  await expect(page.getByText('Test')).toBeVisible();
});
```

**4. Time-dependent tests:**

```ts
// BAD: depends on real time
await expect(page.getByText('Just now')).toBeVisible();

// GOOD: mock the clock
await page.clock.install({ time: new Date('2024-01-15T10:00:00') });
await page.goto('/feed');
await expect(page.getByText('Jan 15, 2024')).toBeVisible();
```

---

## Strict Mode Violations

Error: `strict mode violation: getByRole('button') resolved to N elements`

This occurs when a locator matches multiple elements and Playwright expects one.

### Solutions

```ts
// BAD: matches all buttons
await page.getByRole('button').click();

// GOOD: be specific with name
await page.getByRole('button', { name: 'Submit' }).click();

// GOOD: use .first(), .last(), or .nth() when multiple matches are expected
await page.getByRole('listitem').first().click();

// GOOD: filter to narrow down
const section = page.getByTestId('checkout-section');
await section.getByRole('button', { name: 'Continue' }).click();

// GOOD: use filter with hasText
await page.getByRole('button').filter({ hasText: 'Delete' }).click();

// Check how many elements match
const count = await page.getByRole('button', { name: 'Save' }).count();
console.log(`Found ${count} Save buttons`);
```

### Scoping to Containers

```ts
// Instead of page-wide selectors, scope to a container
const modal = page.getByRole('dialog');
await modal.getByRole('button', { name: 'Confirm' }).click();

const form = page.locator('form#registration');
await form.getByLabel('Name').fill('Alice');
```

---

## Timing and Race Conditions

### Waiting for Network Requests

```ts
// BAD: no wait for API response
await page.getByRole('button', { name: 'Save' }).click();
await expect(page.getByText('Saved!')).toBeVisible(); // may fail

// GOOD: wait for the API response that triggers the UI update
const saveResponse = page.waitForResponse(
  resp => resp.url().includes('/api/save') && resp.status() === 200
);
await page.getByRole('button', { name: 'Save' }).click();
await saveResponse;
await expect(page.getByText('Saved!')).toBeVisible();
```

### Waiting for Navigation

```ts
// BAD: checking URL immediately after click
await page.getByRole('link', { name: 'Profile' }).click();
expect(page.url()).toContain('/profile'); // non-retrying

// GOOD: use auto-retrying assertion
await page.getByRole('link', { name: 'Profile' }).click();
await expect(page).toHaveURL(/\/profile/);
```

### Waiting for Elements to Disappear

```ts
// Wait for loading spinner to go away
await page.getByTestId('loading-spinner').waitFor({ state: 'hidden' });

// Wait for element to be detached from DOM entirely
await page.getByTestId('splash-screen').waitFor({ state: 'detached' });
```

### Avoiding Hard Waits

```ts
// ❌ NEVER DO THIS (brittle, slow)
await page.waitForTimeout(3000);

// ✅ Wait for a specific condition
await page.waitForFunction(() => document.fonts.ready);
await page.waitForLoadState('networkidle');
await page.getByTestId('chart').waitFor({ state: 'visible' });
```

---

## Stale Element Issues

Playwright locators re-query the DOM on each action, so stale elements are rare.
However, issues can arise with `elementHandle()` or `evaluate()`.

```ts
// BAD: storing element handle (can go stale)
const handle = await page.getByRole('button', { name: 'Next' }).elementHandle();
// ... page navigates or re-renders ...
await handle!.click(); // May fail with stale element

// GOOD: use locators (always re-query)
const nextBtn = page.getByRole('button', { name: 'Next' });
// ... page navigates or re-renders ...
await nextBtn.click(); // Always finds current element
```

### Dynamic Content

```ts
// For content that updates dynamically, use polling assertions
await expect(page.getByTestId('counter')).toHaveText('5', { timeout: 10000 });

// For lists that load incrementally
await expect(page.getByRole('listitem')).toHaveCount(20, { timeout: 15000 });

// Use expect.poll for non-locator values
await expect.poll(async () => {
  const resp = await page.request.get('/api/status');
  return (await resp.json()).ready;
}, { timeout: 30000 }).toBeTruthy();
```

---

## Selector Strategies That Avoid Flakiness

### Priority Order (Most to Least Stable)

1. **Role-based** — mirrors how users/assistive tech see the page:
   ```ts
   page.getByRole('button', { name: 'Submit' })
   page.getByRole('heading', { name: 'Welcome', level: 1 })
   page.getByRole('link', { name: 'Sign up' })
   ```

2. **Label-based** — tied to form semantics:
   ```ts
   page.getByLabel('Email address')
   page.getByLabel(/password/i)
   ```

3. **Test ID** — stable, developer-controlled:
   ```ts
   page.getByTestId('checkout-button')
   // Configure custom attribute:
   // use: { testIdAttribute: 'data-cy' }
   ```

4. **Text-based** — readable but fragile to copy changes:
   ```ts
   page.getByText('Add to cart')
   page.getByText(/total: \$\d+/i) // regex for dynamic text
   ```

5. **CSS/XPath** — last resort, tightly coupled to DOM structure:
   ```ts
   page.locator('.btn-primary >> visible=true')
   page.locator('css=article >> text=Read more')
   ```

### Anti-Patterns

```ts
// ❌ Fragile selectors — break on any DOM change
page.locator('div > div:nth-child(3) > span.text')
page.locator('#app > main > section:first-of-type button')

// ❌ Auto-generated class names (CSS modules, Tailwind JIT)
page.locator('.css-1a2b3c')
page.locator('[class*="styles_button__"]')

// ✅ Resilient alternatives
page.getByRole('button', { name: 'Add to cart' })
page.getByTestId('add-to-cart')
```

---

## Debugging Tools

### Trace Viewer

The most powerful debugging tool. Captures DOM snapshots, network, console, and screenshots at each step.

```ts
// playwright.config.ts — capture traces on failure
export default defineConfig({
  use: {
    trace: 'on-first-retry',      // only on retry (saves CI time)
    // trace: 'retain-on-failure', // keep on any failure
    // trace: 'on',                // always (expensive)
  },
});
```

```bash
# View a trace file
npx playwright show-trace test-results/test-name/trace.zip

# Open trace from a URL
npx playwright show-trace https://your-ci.com/artifacts/trace.zip
```

### UI Mode

Interactive test runner with time-travel debugging:

```bash
npx playwright test --ui
```

Features: watch mode, step-through, DOM inspector, network tab, locator picker.

### Headed Mode and Slow Motion

```bash
# See the browser while tests run
npx playwright test --headed

# Slow down actions for visual debugging
npx playwright test --headed -- --slow-mo=500
```

Or in config:

```ts
use: {
  headless: false,
  launchOptions: { slowMo: 500 },
}
```

### Inspector / Debug Mode

```bash
# Pause at the start of each test
npx playwright test --debug

# Pause at a specific line in test code
```

```ts
test('debug this', async ({ page }) => {
  await page.goto('/');
  await page.pause(); // opens inspector
  await page.getByRole('button').click();
});
```

### VS Code Extension

- Install "Playwright Test for VS Code"
- Click gutter icons to run individual tests
- "Show Browser" checkbox for headed mode
- "Pick Locator" to generate selectors from the live page
- Step-through debugger with breakpoints

### Console Logging

```ts
// Capture browser console
page.on('console', msg => {
  if (msg.type() === 'error') console.log('Browser error:', msg.text());
});

// Capture page errors (uncaught exceptions)
page.on('pageerror', error => {
  console.log('Page error:', error.message);
});
```

---

## CI-Specific Issues

### Missing Dependencies on Linux

```bash
# Install system dependencies for all browsers
npx playwright install --with-deps

# For specific browser only
npx playwright install chromium --with-deps
```

Ubuntu/Debian packages needed (auto-installed by `--with-deps`):
`libatk1.0-0`, `libatk-bridge2.0-0`, `libcups2`, `libdrm2`, `libxkbcommon0`, `libxdamage1`, `libgbm1`, `libpango-1.0-0`, `libcairo2`, `libasound2`, `libnspr4`, `libnss3`

### Docker Issues

```dockerfile
# Use official Playwright Docker image
FROM mcr.microsoft.com/playwright:v1.52.0-noble

# If building custom image, install deps
RUN npx playwright install --with-deps
```

Common Docker pitfalls:
- Run as non-root: `--user 1001` or `USER pwuser` in Dockerfile
- Shared memory: `--ipc=host` or `--shm-size=2gb` to avoid crashes
- Missing fonts: install `fonts-noto` for consistent text rendering

### Screenshot Differences Across OS

Screenshots differ between Linux, macOS, and Windows due to font rendering.

```ts
// Platform-specific snapshots (auto-managed)
await expect(page).toHaveScreenshot('homepage.png', {
  maxDiffPixelRatio: 0.02, // allow 2% difference
});
// Snapshots stored in: tests/__snapshots__/test-name-chromium-linux.png
```

Solutions:
- Run screenshot tests in Docker for consistency
- Use `maxDiffPixelRatio` or `maxDiffPixels` for tolerance
- Use `mask` to hide dynamic content:
  ```ts
  await expect(page).toHaveScreenshot({
    mask: [page.getByTestId('date'), page.getByTestId('avatar')],
  });
  ```

### CI Timeouts

```ts
// Increase timeouts for slower CI machines
export default defineConfig({
  timeout: 60_000,        // per-test timeout (default 30s)
  expect: {
    timeout: 10_000,      // assertion timeout (default 5s)
  },
  use: {
    actionTimeout: 15_000, // per-action timeout (default none)
    navigationTimeout: 30_000,
  },
});
```

### GitHub Actions Artifacts

Always upload reports on failure:

```yaml
- uses: actions/upload-artifact@v4
  if: ${{ !cancelled() }}
  with:
    name: playwright-report
    path: playwright-report/
    retention-days: 14
```

---

## Actionability Checks

Before performing actions, Playwright checks that elements are:

| Check | Actions |
|-------|---------|
| Visible | All actions |
| Stable (not animating) | All actions |
| Enabled | `click`, `fill`, `check`, `selectOption` |
| Editable | `fill`, `selectOption`, `press` |
| Receives events | `click` (no overlay blocking) |

### Force-Skipping Actionability

```ts
// Skip all checks (use sparingly — only when you know element is covered)
await page.getByRole('button').click({ force: true });

// Common scenario: clicking a button behind a cookie banner
await page.getByTestId('cookie-dismiss').click();
await page.getByRole('button', { name: 'Continue' }).click();
```

### Handling Overlays and Tooltips

```ts
// Dismiss overlay before interacting
await page.getByRole('button', { name: 'Close' }).click();

// Or wait for overlay to disappear
await page.getByTestId('overlay').waitFor({ state: 'hidden' });
await page.getByRole('button', { name: 'Submit' }).click();
```

### Element Covered by Another Element

Error: `element is not visible or is covered by another element`

```ts
// Scroll element into view first
await page.getByRole('button', { name: 'Load More' }).scrollIntoViewIfNeeded();
await page.getByRole('button', { name: 'Load More' }).click();

// Or use force click as escape hatch
await page.getByRole('button').click({ force: true });
```

---

## Auto-Waiting Pitfalls

### When Auto-Wait Does NOT Apply

```ts
// ❌ Non-retrying methods — check once, not auto-waited
const text = await page.locator('.status').innerText(); // snapshot
const html = await page.locator('.box').innerHTML();     // snapshot
const visible = await page.locator('.modal').isVisible(); // snapshot

// ✅ Use retrying assertions instead
await expect(page.locator('.status')).toHaveText('Done');
await expect(page.locator('.modal')).toBeVisible();
```

### evaluate() Does Not Auto-Wait

```ts
// BAD: may run before element exists
const value = await page.evaluate(() =>
  document.querySelector('#result')?.textContent
);

// GOOD: wait for element first
await page.locator('#result').waitFor();
const value = await page.locator('#result').innerText();

// BEST: use auto-retrying assertion
await expect(page.locator('#result')).toHaveText('42');
```

### Assertions That Don't Auto-Retry

```ts
// ❌ expect without locator — runs once
const count = await page.locator('.item').count();
expect(count).toBe(5); // snapshot, no retry

// ✅ Locator assertion — retries
await expect(page.locator('.item')).toHaveCount(5);
```

---

## Navigation Race Conditions

### Click Triggers Navigation

```ts
// BAD: navigation might complete before waitForURL is registered
await page.getByRole('link', { name: 'Dashboard' }).click();
await page.waitForURL('/dashboard'); // might miss the navigation

// GOOD: use auto-retrying URL assertion
await page.getByRole('link', { name: 'Dashboard' }).click();
await expect(page).toHaveURL('/dashboard');

// GOOD: for complex scenarios, set up wait before action
const navigation = page.waitForURL('/dashboard');
await page.getByRole('link', { name: 'Dashboard' }).click();
await navigation;
```

### Form Submission with Redirect

```ts
// Wait for redirect after form submit
const responsePromise = page.waitForResponse(
  resp => resp.url().includes('/api/submit') && resp.ok()
);
await page.getByRole('button', { name: 'Submit' }).click();
await responsePromise;
await expect(page).toHaveURL('/success');
```

### SPA Navigation (Client-Side Routing)

```ts
// SPA doesn't trigger traditional navigation events
// Use URL assertion which polls
await page.getByRole('link', { name: 'About' }).click();
await expect(page).toHaveURL('/about');

// Or wait for specific content to appear
await page.getByRole('link', { name: 'About' }).click();
await expect(page.getByRole('heading', { name: 'About Us' })).toBeVisible();
```

---

## File Download Edge Cases

```ts
// Basic download
const downloadPromise = page.waitForEvent('download');
await page.getByRole('link', { name: 'Download Report' }).click();
const download = await downloadPromise;

// Save to specific path
await download.saveAs('./downloads/' + download.suggestedFilename());

// Read download content without saving
const stream = await download.createReadStream();
// ... process stream

// Verify download filename and failure status
expect(download.suggestedFilename()).toBe('report.pdf');
expect(await download.failure()).toBeNull(); // null means success
```

### Downloads in CI

```ts
// Configure download directory
const context = await browser.newContext({
  acceptDownloads: true,
});
```

### Blob URL Downloads

```ts
// Some apps use blob: URLs for downloads
const downloadPromise = page.waitForEvent('download');
await page.evaluate(() => {
  const blob = new Blob(['CSV data'], { type: 'text/csv' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'data.csv';
  a.click();
});
const download = await downloadPromise;
```

---

## File Upload Edge Cases

```ts
// Single file
await page.getByLabel('Upload').setInputFiles('path/to/file.pdf');

// Multiple files
await page.getByLabel('Upload').setInputFiles(['a.png', 'b.png', 'c.png']);

// Clear file input
await page.getByLabel('Upload').setInputFiles([]);

// Upload via buffer (no file on disk)
await page.getByLabel('Upload').setInputFiles({
  name: 'data.csv',
  mimeType: 'text/csv',
  buffer: Buffer.from('name,email\nAlice,a@b.com'),
});
```

### Non-Input File Uploads (Drag-and-Drop)

```ts
// For drag-and-drop zones without <input type="file">
const fileChooserPromise = page.waitForEvent('filechooser');
await page.getByTestId('drop-zone').click();
const fileChooser = await fileChooserPromise;
await fileChooser.setFiles('test-file.png');
```

### File Chooser Events

```ts
// Listen for file chooser dialog
page.on('filechooser', async (fileChooser) => {
  await fileChooser.setFiles('default-file.txt');
});

// Or handle explicitly
const fileChooserPromise = page.waitForEvent('filechooser');
await page.getByRole('button', { name: 'Attach' }).click();
const fileChooser = await fileChooserPromise;
expect(fileChooser.isMultiple()).toBe(false);
await fileChooser.setFiles('document.pdf');
```

---

## Geolocation and Permissions Mocking

### Geolocation

```ts
// Set geolocation in context
const context = await browser.newContext({
  geolocation: { latitude: 40.7128, longitude: -74.0060 },
  permissions: ['geolocation'],
});

// Or in config
use: {
  geolocation: { latitude: 51.5074, longitude: -0.1278 },
  permissions: ['geolocation'],
}
```

```ts
// Change geolocation during test
await context.setGeolocation({ latitude: 35.6762, longitude: 139.6503 });
await page.reload();
await expect(page.getByText('Tokyo')).toBeVisible();
```

### Permissions

```ts
// Grant permissions
const context = await browser.newContext({
  permissions: ['geolocation', 'notifications', 'camera', 'microphone'],
});

// Grant per-origin
await context.grantPermissions(['clipboard-read'], {
  origin: 'https://example.com',
});

// Revoke all permissions
await context.clearPermissions();
```

### Clipboard

```ts
// Grant clipboard access and test copy/paste
const context = await browser.newContext({
  permissions: ['clipboard-read', 'clipboard-write'],
});
const page = await context.newPage();

await page.goto('/editor');
await page.getByRole('button', { name: 'Copy' }).click();

const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
expect(clipboardText).toBe('Copied content');
```

### Timezone and Locale

```ts
const context = await browser.newContext({
  locale: 'de-DE',
  timezoneId: 'Europe/Berlin',
});

// Verify locale-specific formatting
await page.goto('/settings');
await expect(page.getByText('Sprache')).toBeVisible(); // German UI
```

### Color Scheme / Dark Mode

```ts
const context = await browser.newContext({
  colorScheme: 'dark',
});

// Change mid-test
await page.emulateMedia({ colorScheme: 'light' });
await expect(page.locator('body')).toHaveCSS('background-color', 'rgb(255, 255, 255)');
```
