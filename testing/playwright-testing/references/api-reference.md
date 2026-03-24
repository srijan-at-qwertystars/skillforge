# Playwright API Reference

## Table of Contents

- [Page](#page)
- [BrowserContext](#browsercontext)
- [Locator](#locator)
- [expect (Assertions)](#expect-assertions)
- [Route](#route)
- [Frame](#frame)
- [Dialog](#dialog)
- [Download](#download)
- [FileChooser](#filechooser)
- [Mouse](#mouse)
- [Keyboard](#keyboard)
- [Touchscreen](#touchscreen)

---

## Page

The `Page` class represents a single tab or popup. It provides methods for navigation, interaction, and evaluation.

### Navigation

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `goto` | `goto(url, options?)` | `Promise<Response \| null>` | Navigate to URL |
| `goBack` | `goBack(options?)` | `Promise<Response \| null>` | Navigate back |
| `goForward` | `goForward(options?)` | `Promise<Response \| null>` | Navigate forward |
| `reload` | `reload(options?)` | `Promise<Response \| null>` | Reload page |
| `waitForURL` | `waitForURL(url, options?)` | `Promise<void>` | Wait for URL match |

Options common to navigation: `{ timeout?, waitUntil?: 'load' | 'domcontentloaded' | 'networkidle' | 'commit' }`

```ts
await page.goto('https://example.com', { waitUntil: 'domcontentloaded' });
await page.waitForURL('**/dashboard', { timeout: 10000 });
```

### Locator Methods

| Method | Signature | Returns |
|--------|-----------|---------|
| `locator` | `locator(selector, options?)` | `Locator` |
| `getByRole` | `getByRole(role, options?)` | `Locator` |
| `getByText` | `getByText(text, options?)` | `Locator` |
| `getByLabel` | `getByLabel(text, options?)` | `Locator` |
| `getByPlaceholder` | `getByPlaceholder(text, options?)` | `Locator` |
| `getByTestId` | `getByTestId(testId)` | `Locator` |
| `getByAltText` | `getByAltText(text, options?)` | `Locator` |
| `getByTitle` | `getByTitle(text, options?)` | `Locator` |

```ts
page.getByRole('button', { name: 'Submit', exact: true });
page.getByText(/welcome/i);
page.getByLabel('Email', { exact: false });
page.locator('css=.card >> text=Read more');
```

### Waiting

| Method | Signature | Returns |
|--------|-----------|---------|
| `waitForSelector` | `waitForSelector(selector, options?)` | `Promise<ElementHandle \| null>` |
| `waitForLoadState` | `waitForLoadState(state?, options?)` | `Promise<void>` |
| `waitForEvent` | `waitForEvent(event, optionsOrPredicate?)` | `Promise<T>` |
| `waitForFunction` | `waitForFunction(fn, arg?, options?)` | `Promise<JSHandle>` |
| `waitForResponse` | `waitForResponse(urlOrPredicate, options?)` | `Promise<Response>` |
| `waitForRequest` | `waitForRequest(urlOrPredicate, options?)` | `Promise<Request>` |
| `waitForTimeout` | `waitForTimeout(timeout)` | `Promise<void>` |

```ts
await page.waitForLoadState('networkidle');
const response = await page.waitForResponse(resp =>
  resp.url().includes('/api/data') && resp.status() === 200
);
await page.waitForFunction(() => document.fonts.ready);
```

### Evaluation

| Method | Signature | Returns |
|--------|-----------|---------|
| `evaluate` | `evaluate(fn, arg?)` | `Promise<T>` |
| `evaluateHandle` | `evaluateHandle(fn, arg?)` | `Promise<JSHandle>` |
| `addScriptTag` | `addScriptTag(options)` | `Promise<ElementHandle>` |
| `addStyleTag` | `addStyleTag(options)` | `Promise<ElementHandle>` |

```ts
const title = await page.evaluate(() => document.title);
const dimensions = await page.evaluate(() => ({
  width: window.innerWidth,
  height: window.innerHeight,
}));
```

### Screenshots and Content

| Method | Signature | Returns |
|--------|-----------|---------|
| `screenshot` | `screenshot(options?)` | `Promise<Buffer>` |
| `content` | `content()` | `Promise<string>` |
| `setContent` | `setContent(html, options?)` | `Promise<void>` |
| `title` | `title()` | `Promise<string>` |
| `url` | `url()` | `string` |

```ts
await page.screenshot({ path: 'screenshot.png', fullPage: true });
await page.setContent('<h1>Test</h1>');
```

### Network

| Method | Signature | Returns |
|--------|-----------|---------|
| `route` | `route(url, handler, options?)` | `Promise<void>` |
| `unroute` | `unroute(url, handler?)` | `Promise<void>` |
| `routeFromHAR` | `routeFromHAR(har, options?)` | `Promise<void>` |

```ts
await page.route('**/api/users', route =>
  route.fulfill({ body: JSON.stringify([]) })
);
```

### Events

| Event | Payload | Description |
|-------|---------|-------------|
| `'close'` | `Page` | Page is closed |
| `'console'` | `ConsoleMessage` | Console message logged |
| `'dialog'` | `Dialog` | Dialog (alert/confirm/prompt) opened |
| `'download'` | `Download` | Download started |
| `'filechooser'` | `FileChooser` | File chooser opened |
| `'pageerror'` | `Error` | Uncaught exception in page |
| `'popup'` | `Page` | New popup window opened |
| `'request'` | `Request` | Request issued |
| `'response'` | `Response` | Response received |
| `'frameattached'` | `Frame` | Frame attached |
| `'framedetached'` | `Frame` | Frame detached |

```ts
page.on('console', msg => console.log(msg.type(), msg.text()));
page.on('pageerror', err => console.error(err));
```

---

## BrowserContext

A `BrowserContext` is an isolated browser session (cookies, storage, cache).

### Creation

```ts
const context = await browser.newContext({
  viewport: { width: 1280, height: 720 },
  locale: 'en-US',
  timezoneId: 'America/New_York',
  geolocation: { latitude: 40.7, longitude: -74.0 },
  permissions: ['geolocation'],
  colorScheme: 'dark',
  userAgent: 'custom-agent',
  storageState: 'auth.json',
  httpCredentials: { username: 'user', password: 'pass' },
  extraHTTPHeaders: { 'X-Custom': 'value' },
  ignoreHTTPSErrors: true,
  recordHar: { path: 'network.har' },
  recordVideo: { dir: 'videos/', size: { width: 1280, height: 720 } },
});
```

### Key Methods

| Method | Signature | Returns |
|--------|-----------|---------|
| `newPage` | `newPage()` | `Promise<Page>` |
| `pages` | `pages()` | `Page[]` |
| `cookies` | `cookies(urls?)` | `Promise<Cookie[]>` |
| `addCookies` | `addCookies(cookies)` | `Promise<void>` |
| `clearCookies` | `clearCookies(options?)` | `Promise<void>` |
| `storageState` | `storageState(options?)` | `Promise<StorageState>` |
| `grantPermissions` | `grantPermissions(perms, options?)` | `Promise<void>` |
| `clearPermissions` | `clearPermissions()` | `Promise<void>` |
| `setGeolocation` | `setGeolocation(geolocation)` | `Promise<void>` |
| `route` | `route(url, handler)` | `Promise<void>` |
| `unroute` | `unroute(url, handler?)` | `Promise<void>` |
| `close` | `close()` | `Promise<void>` |

```ts
await context.addCookies([{
  name: 'session', value: 'abc123',
  domain: '.example.com', path: '/',
}]);
await context.storageState({ path: 'auth.json' });
```

### Events

| Event | Payload | Description |
|-------|---------|-------------|
| `'page'` | `Page` | New page created in context |
| `'close'` | `BrowserContext` | Context closed |
| `'request'` | `Request` | Request from any page |
| `'response'` | `Response` | Response on any page |

```ts
context.on('page', async (page) => {
  await page.waitForLoadState();
  console.log('New page:', page.url());
});
```

---

## Locator

Locators are the primary way to find and interact with elements. They auto-wait and auto-retry.

### Actions

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `click` | `click(options?)` | `Promise<void>` | Click element |
| `dblclick` | `dblclick(options?)` | `Promise<void>` | Double-click |
| `fill` | `fill(value, options?)` | `Promise<void>` | Clear and type |
| `pressSequentially` | `pressSequentially(text, options?)` | `Promise<void>` | Type key-by-key |
| `press` | `press(key, options?)` | `Promise<void>` | Press keyboard key |
| `check` | `check(options?)` | `Promise<void>` | Check checkbox |
| `uncheck` | `uncheck(options?)` | `Promise<void>` | Uncheck checkbox |
| `selectOption` | `selectOption(values, options?)` | `Promise<string[]>` | Select dropdown |
| `setInputFiles` | `setInputFiles(files, options?)` | `Promise<void>` | Upload files |
| `hover` | `hover(options?)` | `Promise<void>` | Hover over element |
| `focus` | `focus(options?)` | `Promise<void>` | Focus element |
| `dragTo` | `dragTo(target, options?)` | `Promise<void>` | Drag to target |
| `scrollIntoViewIfNeeded` | `scrollIntoViewIfNeeded(options?)` | `Promise<void>` | Scroll into view |
| `screenshot` | `screenshot(options?)` | `Promise<Buffer>` | Element screenshot |
| `tap` | `tap(options?)` | `Promise<void>` | Tap (touch) |

Click options: `{ button?: 'left' | 'right' | 'middle', clickCount?, delay?, force?, modifiers?, position?, timeout?, trial? }`

```ts
await locator.click({ button: 'right' });
await locator.fill('hello');
await locator.selectOption({ label: 'Option A' });
await locator.press('Enter');
await locator.setInputFiles({ name: 'f.txt', mimeType: 'text/plain', buffer: Buffer.from('hi') });
```

### Querying

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `count` | `count()` | `Promise<number>` | Number of matches |
| `first` | `first()` | `Locator` | First match |
| `last` | `last()` | `Locator` | Last match |
| `nth` | `nth(index)` | `Locator` | Match at index |
| `filter` | `filter(options)` | `Locator` | Filter by conditions |
| `locator` | `locator(selectorOrLocator)` | `Locator` | Scoped sub-locator |
| `getByRole` | `getByRole(role, options?)` | `Locator` | Sub-role locator |
| `getByText` | `getByText(text, options?)` | `Locator` | Sub-text locator |
| `getByLabel` | `getByLabel(text, options?)` | `Locator` | Sub-label locator |
| `getByTestId` | `getByTestId(testId)` | `Locator` | Sub-testid locator |
| `and` | `and(locator)` | `Locator` | Intersection |
| `or` | `or(locator)` | `Locator` | Union |

Filter options: `{ has?, hasNot?, hasText?, hasNotText? }`

```ts
const row = page.getByRole('row').filter({ hasText: 'Alice' });
await row.getByRole('button', { name: 'Edit' }).click();

const visible = page.locator('.item').and(page.locator(':visible'));
const errorOrWarning = page.getByText('Error').or(page.getByText('Warning'));
```

### Reading State (Non-Retrying)

| Method | Signature | Returns |
|--------|-----------|---------|
| `innerText` | `innerText(options?)` | `Promise<string>` |
| `innerHTML` | `innerHTML(options?)` | `Promise<string>` |
| `textContent` | `textContent(options?)` | `Promise<string \| null>` |
| `inputValue` | `inputValue(options?)` | `Promise<string>` |
| `getAttribute` | `getAttribute(name, options?)` | `Promise<string \| null>` |
| `isVisible` | `isVisible(options?)` | `Promise<boolean>` |
| `isHidden` | `isHidden(options?)` | `Promise<boolean>` |
| `isEnabled` | `isEnabled(options?)` | `Promise<boolean>` |
| `isDisabled` | `isDisabled(options?)` | `Promise<boolean>` |
| `isChecked` | `isChecked(options?)` | `Promise<boolean>` |
| `isEditable` | `isEditable(options?)` | `Promise<boolean>` |
| `boundingBox` | `boundingBox(options?)` | `Promise<BoundingBox \| null>` |
| `all` | `all()` | `Promise<Locator[]>` |

> **Note:** These methods return a snapshot. For assertions, prefer `expect(locator).toBeVisible()` etc.

```ts
const text = await page.getByTestId('price').innerText();
const items = await page.getByRole('listitem').all();
for (const item of items) {
  console.log(await item.textContent());
}
```

### Frame Locators

| Method | Signature | Returns |
|--------|-----------|---------|
| `frameLocator` | `frameLocator(selector)` | `FrameLocator` |
| `contentFrame` | `contentFrame()` | `FrameLocator` |

```ts
const iframe = page.frameLocator('#embed');
await iframe.getByRole('button', { name: 'Play' }).click();
```

---

## expect (Assertions)

All Playwright assertions auto-retry until timeout (default 5s). Use `expect` from `@playwright/test`.

### Page Assertions

| Assertion | Signature |
|-----------|-----------|
| `toHaveURL` | `expect(page).toHaveURL(url, options?)` |
| `toHaveTitle` | `expect(page).toHaveTitle(title, options?)` |
| `toHaveScreenshot` | `expect(page).toHaveScreenshot(name?, options?)` |

```ts
await expect(page).toHaveURL(/\/dashboard/);
await expect(page).toHaveTitle('My App');
await expect(page).toHaveScreenshot('home.png', { maxDiffPixelRatio: 0.01 });
```

### Locator Assertions

| Assertion | Signature |
|-----------|-----------|
| `toBeVisible` | `expect(locator).toBeVisible(options?)` |
| `toBeHidden` | `expect(locator).toBeHidden(options?)` |
| `toBeEnabled` | `expect(locator).toBeEnabled(options?)` |
| `toBeDisabled` | `expect(locator).toBeDisabled(options?)` |
| `toBeChecked` | `expect(locator).toBeChecked(options?)` |
| `toBeEditable` | `expect(locator).toBeEditable(options?)` |
| `toBeFocused` | `expect(locator).toBeFocused(options?)` |
| `toBeEmpty` | `expect(locator).toBeEmpty(options?)` |
| `toBeAttached` | `expect(locator).toBeAttached(options?)` |
| `toBeInViewport` | `expect(locator).toBeInViewport(options?)` |
| `toHaveText` | `expect(locator).toHaveText(text, options?)` |
| `toContainText` | `expect(locator).toContainText(text, options?)` |
| `toHaveValue` | `expect(locator).toHaveValue(value, options?)` |
| `toHaveValues` | `expect(locator).toHaveValues(values, options?)` |
| `toHaveAttribute` | `expect(locator).toHaveAttribute(name, value?, options?)` |
| `toHaveCSS` | `expect(locator).toHaveCSS(name, value, options?)` |
| `toHaveClass` | `expect(locator).toHaveClass(expected, options?)` |
| `toHaveId` | `expect(locator).toHaveId(id, options?)` |
| `toHaveCount` | `expect(locator).toHaveCount(count, options?)` |
| `toHaveScreenshot` | `expect(locator).toHaveScreenshot(name?, options?)` |

```ts
await expect(page.getByRole('alert')).toBeVisible();
await expect(page.getByRole('button')).toBeEnabled();
await expect(page.getByLabel('Agree')).toBeChecked();
await expect(page.getByRole('heading')).toHaveText('Welcome');
await expect(page.getByRole('listitem')).toHaveCount(3);
await expect(page.locator('.card')).toHaveClass(/highlighted/);
```

### Negation and Soft Assertions

```ts
await expect(page.getByText('Error')).not.toBeVisible();
await expect.soft(page.getByTestId('count')).toHaveText('5');
```

### Polling Assertions

```ts
await expect.poll(async () => {
  const response = await page.request.get('/api/status');
  return (await response.json()).state;
}, { timeout: 30000, intervals: [1000, 2000, 5000] }).toBe('ready');
```

### Snapshot Assertions

```ts
expect(await page.content()).toMatchSnapshot('page.html');
expect(data).toMatchSnapshot('api-response.json');
```

---

## Route

Intercept and modify network requests.

### Methods

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `fulfill` | `fulfill(options?)` | `Promise<void>` | Provide mock response |
| `continue` | `continue(options?)` | `Promise<void>` | Continue with modifications |
| `abort` | `abort(errorCode?)` | `Promise<void>` | Abort request |
| `fetch` | `fetch(options?)` | `Promise<APIResponse>` | Fetch actual response |
| `fallback` | `fallback(options?)` | `Promise<void>` | Fall through to next handler |
| `request` | `request()` | `Request` | Get request being routed |

Fulfill options: `{ status?, headers?, contentType?, body?, json?, path?, response? }`

```ts
await page.route('**/api/users', async (route) => {
  await route.fulfill({
    status: 200,
    json: [{ id: 1, name: 'Alice' }],
  });
});

await page.route('**/api/data', async (route) => {
  const response = await route.fetch();
  const json = await response.json();
  json.modified = true;
  await route.fulfill({ response, json });
});

await page.route('**/*.{png,jpg}', route => route.abort());

await page.route('**/api/**', async (route) => {
  const headers = { ...route.request().headers(), 'X-Test': '1' };
  await route.continue({ headers });
});
```

### Request Object

| Property/Method | Returns | Description |
|-----------------|---------|-------------|
| `url()` | `string` | Request URL |
| `method()` | `string` | HTTP method |
| `headers()` | `Record<string, string>` | Request headers |
| `postData()` | `string \| null` | POST body as string |
| `postDataJSON()` | `any` | POST body parsed as JSON |
| `resourceType()` | `string` | Resource type |
| `isNavigationRequest()` | `boolean` | Is navigation |
| `redirectedFrom()` | `Request \| null` | Redirect source |
| `redirectedTo()` | `Request \| null` | Redirect target |
| `response()` | `Promise<Response \| null>` | Associated response |

---

## Frame

A `Frame` represents an iframe within a page. Access via `page.frame()` or `page.frames()`.

### Key Methods

| Method | Signature | Returns |
|--------|-----------|---------|
| `locator` | `locator(selector)` | `Locator` |
| `getByRole` | `getByRole(role, options?)` | `Locator` |
| `getByText` | `getByText(text, options?)` | `Locator` |
| `getByLabel` | `getByLabel(text, options?)` | `Locator` |
| `getByTestId` | `getByTestId(testId)` | `Locator` |
| `goto` | `goto(url, options?)` | `Promise<Response \| null>` |
| `url` | `url()` | `string` |
| `name` | `name()` | `string` |
| `content` | `content()` | `Promise<string>` |
| `evaluate` | `evaluate(fn, arg?)` | `Promise<T>` |
| `parentFrame` | `parentFrame()` | `Frame \| null` |
| `childFrames` | `childFrames()` | `Frame[]` |
| `isDetached` | `isDetached()` | `boolean` |
| `waitForLoadState` | `waitForLoadState(state?, options?)` | `Promise<void>` |

```ts
const frame = page.frame({ name: 'editor' });
const frame2 = page.frame({ url: /third-party/ });
await frame?.locator('#save').click();

// Prefer frameLocator for most use cases
const fl = page.frameLocator('iframe.payment');
await fl.getByLabel('Card').fill('4242...');
```

---

## Dialog

Handles JavaScript dialogs: `alert()`, `confirm()`, `prompt()`, `beforeunload`.

### Properties and Methods

| Member | Type | Description |
|--------|------|-------------|
| `type` | `string` | `'alert'`, `'confirm'`, `'prompt'`, `'beforeunload'` |
| `message` | `string` | Dialog message text |
| `defaultValue` | `string` | Default prompt value |
| `accept(promptText?)` | `Promise<void>` | Accept dialog |
| `dismiss()` | `Promise<void>` | Dismiss dialog |

```ts
page.on('dialog', async (dialog) => {
  console.log(dialog.type(), dialog.message());
  if (dialog.type() === 'confirm') {
    await dialog.accept();
  } else if (dialog.type() === 'prompt') {
    await dialog.accept('my input');
  } else {
    await dialog.dismiss();
  }
});
```

Auto-dismiss (default behavior): Dialogs are automatically dismissed unless a handler is registered.

```ts
// One-time dialog handling
page.once('dialog', dialog => dialog.accept());
await page.getByRole('button', { name: 'Delete' }).click();
```

---

## Download

Represents a file download triggered by the page.

### Properties and Methods

| Member | Type | Description |
|--------|------|-------------|
| `suggestedFilename()` | `string` | Suggested file name |
| `url()` | `string` | Download URL |
| `saveAs(path)` | `Promise<void>` | Save to path |
| `path()` | `Promise<string \| null>` | Temp file path |
| `createReadStream()` | `Promise<Readable>` | File as stream |
| `failure()` | `Promise<string \| null>` | Error string or null |
| `cancel()` | `Promise<void>` | Cancel download |
| `delete()` | `Promise<void>` | Delete temp file |
| `page()` | `Page` | Owning page |

```ts
const downloadPromise = page.waitForEvent('download');
await page.getByRole('link', { name: 'Export CSV' }).click();
const download = await downloadPromise;

expect(download.suggestedFilename()).toBe('report.csv');
await download.saveAs('./downloads/report.csv');
expect(await download.failure()).toBeNull();
```

---

## FileChooser

Represents a file chooser dialog (triggered by `<input type="file">`).

### Properties and Methods

| Member | Type | Description |
|--------|------|-------------|
| `isMultiple()` | `boolean` | Whether multiple files allowed |
| `page()` | `Page` | Owning page |
| `element()` | `Locator` | The input element |
| `setFiles(files, options?)` | `Promise<void>` | Set files to upload |

```ts
const chooserPromise = page.waitForEvent('filechooser');
await page.getByRole('button', { name: 'Upload' }).click();
const chooser = await chooserPromise;

if (chooser.isMultiple()) {
  await chooser.setFiles(['file1.png', 'file2.png']);
} else {
  await chooser.setFiles('file.png');
}
```

---

## Mouse

Low-level mouse control via `page.mouse`.

### Methods

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `click` | `click(x, y, options?)` | `Promise<void>` | Click at coordinates |
| `dblclick` | `dblclick(x, y, options?)` | `Promise<void>` | Double-click |
| `move` | `move(x, y, options?)` | `Promise<void>` | Move to coordinates |
| `down` | `down(options?)` | `Promise<void>` | Press mouse button |
| `up` | `up(options?)` | `Promise<void>` | Release mouse button |
| `wheel` | `wheel(deltaX, deltaY)` | `Promise<void>` | Scroll wheel |

Options: `{ button?: 'left' | 'right' | 'middle', clickCount? }`

```ts
// Draw a line on a canvas
await page.mouse.move(100, 100);
await page.mouse.down();
await page.mouse.move(200, 200, { steps: 10 });
await page.mouse.up();

// Scroll down
await page.mouse.wheel(0, 500);

// Right-click at position
await page.mouse.click(150, 150, { button: 'right' });
```

---

## Keyboard

Low-level keyboard control via `page.keyboard`.

### Methods

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `press` | `press(key, options?)` | `Promise<void>` | Press and release key |
| `down` | `down(key)` | `Promise<void>` | Press key |
| `up` | `up(key)` | `Promise<void>` | Release key |
| `type` | `type(text, options?)` | `Promise<void>` | Type text character by character |
| `insertText` | `insertText(text)` | `Promise<void>` | Insert text directly |

Key names: `'Enter'`, `'Tab'`, `'Escape'`, `'Backspace'`, `'Delete'`, `'ArrowUp'`, `'ArrowDown'`, `'ArrowLeft'`, `'ArrowRight'`, `'Home'`, `'End'`, `'PageUp'`, `'PageDown'`, `'F1'`..`'F12'`, `'a'`..`'z'`, `'0'`..`'9'`

Modifiers: `'Shift'`, `'Control'`, `'Alt'`, `'Meta'`

```ts
// Keyboard shortcuts
await page.keyboard.press('Control+A');
await page.keyboard.press('Control+C');
await page.keyboard.press('Control+V');

// Hold Shift while pressing arrows
await page.keyboard.down('Shift');
await page.keyboard.press('ArrowRight');
await page.keyboard.press('ArrowRight');
await page.keyboard.up('Shift');

// Type slowly (for autocomplete triggers)
await page.keyboard.type('hello world', { delay: 100 });

// Insert text without key events (faster)
await page.keyboard.insertText('pasted text');
```

---

## Touchscreen

Touch input via `page.touchscreen`. Requires a context with `hasTouch: true`.

### Methods

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `tap` | `tap(x, y)` | `Promise<void>` | Tap at coordinates |

```ts
const context = await browser.newContext({
  hasTouch: true,
  viewport: { width: 375, height: 812 },
});
const page = await context.newPage();
await page.goto('/mobile-app');
await page.touchscreen.tap(187, 400);
```

For element-level tap, use `locator.tap()`:

```ts
// Higher-level API (preferred)
await page.getByRole('button', { name: 'Next' }).tap();
```

For swipe gestures, combine with mouse:

```ts
// Simulate swipe left
await page.touchscreen.tap(300, 400);
await page.mouse.move(300, 400);
await page.mouse.down();
await page.mouse.move(50, 400, { steps: 20 });
await page.mouse.up();
```
