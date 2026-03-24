# Cypress Troubleshooting Guide

## Table of Contents
1. [Flaky Tests](#1-flaky-tests)
2. [Element Detached from DOM](#2-element-detached-from-dom)
3. [cy.intercept Not Matching](#3-cyintercept-not-matching)
4. [CORS Issues](#4-cors-issues)
5. [Iframe Access Problems](#5-iframe-access-problems)
6. [Memory Leaks in Long Specs](#6-memory-leaks-in-long-specs)
7. [Slow Test Execution](#7-slow-test-execution)
8. [CI Failures](#8-ci-failures)
9. [Screenshots/Videos Debugging](#9-screenshotsvideos-debugging)
10. [Cypress vs App State Conflicts](#10-cypress-vs-app-state-conflicts)
---
## 1. Flaky Tests
**Problem:** Tests pass intermittently—succeed locally, fail in CI, or pass only on retry.

**Root Cause:** Race conditions between the test runner and application state. Animations delay element interactability, network responses arrive unpredictably, and elements exist in the DOM but are not yet visible or enabled.

**Solution:**
```javascript
// BAD — arbitrary wait is still a race condition
cy.wait(3000);
cy.get('.dashboard').should('be.visible');

// GOOD — Cypress retries the assertion until it passes or times out
cy.get('.dashboard', { timeout: 10000 }).should('be.visible');
```
Wait for network requests with aliases instead of timers:
```javascript
cy.intercept('GET', '/api/users').as('getUsers');
cy.visit('/users');
cy.wait('@getUsers').its('response.statusCode').should('eq', 200);
cy.get('[data-testid="user-list"] li').should('have.length.greaterThan', 0);
```
Disable CSS animations globally to eliminate transition-based flakiness:
```javascript
// cypress/support/e2e.js
beforeEach(() => {
  cy.document().then((doc) => {
    const style = doc.createElement('style');
    style.textContent = `*, *::before, *::after {
      transition-duration: 0s !important; animation-duration: 0s !important;
      transition-delay: 0s !important; animation-delay: 0s !important;
    }`;
    doc.head.appendChild(style);
  });
});
```
Ensure elements are actionable before interacting:
```javascript
cy.get('[data-testid="submit-btn"]').should('be.visible').and('not.be.disabled').click();
```
Stub unreliable endpoints to stabilize network-dependent flows:
```javascript
cy.intercept('GET', '/api/recommendations', {
  statusCode: 200, body: { items: [{ id: 1, name: 'Item A' }] }, delay: 0,
}).as('recommendations');
cy.visit('/home');
cy.wait('@recommendations');
```

**Prevention:** Never use `cy.wait(ms)` for application state. Set `defaultCommandTimeout` globally (e.g., 8000). Enable retries as a safety net (`retries: { runMode: 2, openMode: 0 }`). Use `data-testid` attributes for resilient selectors.
---
## 2. Element Detached from DOM
**Problem:** `CypressError: cy.click() failed because this element is detached from the DOM.`

**Root Cause:** React/Vue/Angular tear down and re-create DOM nodes on re-render. If Cypress grabs a reference and the framework re-renders before the action executes, the original node is orphaned. Triggers include state updates between `cy.get()` and `.click()`, API responses causing re-renders, or parent components remounting children.

**Solution:**
```javascript
// BAD — stores a reference that goes stale after re-render
cy.get('.item').then(($el) => { cy.wrap($el).click(); });

// GOOD — .should() forces Cypress to re-query on each retry
cy.get('.item').should('be.visible').click();
```
Never store and reuse element references across interactions:
```javascript
// BAD — alias goes stale after first click triggers re-render
cy.get('[data-testid="toggle"]').as('toggle');
cy.get('@toggle').click();
cy.get('@toggle').click(); // DETACHED

// GOOD — always query fresh
cy.get('[data-testid="toggle"]').click();
cy.get('[data-testid="toggle"]').click();
```
Wait for re-renders to settle before interacting with the next element:
```javascript
cy.get('[data-testid="save-btn"]').click();
cy.get('[data-testid="status"]').should('contain', 'Saved');
cy.get('[data-testid="next-step-btn"]').should('be.visible').click();
```
Custom guard command:
```javascript
// cypress/support/commands.js
Cypress.Commands.add('safeClick', { prevSubject: 'element' }, (subject) => {
  const selector = subject.attr('data-testid')
    ? `[data-testid="${subject.attr('data-testid')}"]` : subject.selector;
  cy.get(selector).should('be.visible').click();
});
```

**Prevention:** Always chain assertions before actions. Avoid `.then()` for storing references across re-render boundaries. Prefer `cy.contains('Submit').click()` which re-queries naturally.
---
## 3. cy.intercept Not Matching
**Problem:** `cy.intercept()` is set up but requests pass through unintercepted. `cy.wait('@alias')` times out.

**Root Cause:** URL pattern doesn't match the actual request URL, method is wrong (defaults to matching all but can confuse ordering), later intercepts shadow earlier ones, or the intercept was registered after the request fired.

**Solution — Debug with a catch-all:**
```javascript
cy.intercept('**', (req) => { console.log(`${req.method} ${req.url}`); }).as('allRequests');
```
Fix URL pattern mistakes:
```javascript
// BAD — forgot query strings are part of the URL
cy.intercept('GET', '/api/users').as('getUsers'); // misses /api/users?page=1

// GOOD — wildcard captures query strings
cy.intercept('GET', '/api/users*').as('getUsers');
// GOOD — use ** to ignore host differences between environments
cy.intercept('GET', '**/api/users**').as('getUsers');
// GOOD — regex for complex patterns
cy.intercept('GET', /\/api\/users(\?.*)?$/).as('getUsers');
```
Be explicit about HTTP methods:
```javascript
cy.intercept('POST', '/api/users').as('createUser');
cy.intercept('DELETE', '/api/users/*').as('deleteUser');
```
Route ordering — last match wins:
```javascript
cy.intercept('GET', '/api/users*', { body: [] }).as('emptyUsers');
cy.intercept('GET', '/api/users*', { body: [{ id: 1 }] }).as('oneUser');
// Second intercept wins — response will be [{ id: 1 }]
```
Register intercepts BEFORE the triggering action:
```javascript
// BAD — intercept registered after cy.visit fires the request
cy.visit('/dashboard');
cy.intercept('GET', '/api/stats').as('stats'); // Too late!

// GOOD
cy.intercept('GET', '/api/stats').as('stats');
cy.visit('/dashboard');
cy.wait('@stats');
```
Modify requests and responses:
```javascript
cy.intercept('POST', '/api/orders', (req) => {
  req.headers['X-Test'] = 'true';
  req.continue();
});
cy.intercept('GET', '/api/products', (req) => {
  req.continue((res) => { res.body = res.body.slice(0, 5); });
});
```

**Prevention:** Register intercepts before `cy.visit()`. Check the Command Log for route badges—missing badges mean no match. Use `**/path` to ignore host differences.
---
## 4. CORS Issues
**Problem:** `Access to XMLHttpRequest blocked by CORS policy` or `cy.visit() failed...different origin`.

**Root Cause:** Browsers enforce Same-Origin Policy. Cypress runs inside the browser and is subject to the same restrictions—it restricts test commands to a single origin by default.

**Solution:**
```javascript
// cypress.config.js — disable browser same-origin enforcement (Chromium only)
module.exports = defineConfig({
  e2e: { chromeWebSecurity: false },
});
```
For multi-domain flows use `cy.origin()` (Cypress 12+):
```javascript
cy.visit('/login');
cy.get('[data-testid="login-with-google"]').click();
cy.origin('https://accounts.google.com', () => {
  cy.get('input[type="email"]').type('user@example.com');
  cy.get('#next').click();
});
cy.url().should('include', '/dashboard');
```
Pass data into `cy.origin()`:
```javascript
const creds = { email: 'user@test.com', password: 's3cret' };
cy.origin('https://auth.example.com', { args: creds }, ({ email, password }) => {
  cy.get('#email').type(email);
  cy.get('#password').type(password);
  cy.get('form').submit();
});
```
Configure a dev server proxy to avoid CORS entirely:
```javascript
// vite.config.js
export default { server: { proxy: { '/api': { target: 'https://api.example.com', changeOrigin: true } } } };
```
Prevent cross-origin errors from failing tests:
```javascript
Cypress.on('uncaught:exception', (err) => {
  if (err.message.includes('cross-origin')) return false;
});
```

**Prevention:** Use a dev server proxy so app and API share an origin. Stub cross-origin APIs with `cy.intercept()`. Use `cy.request()` for API calls—it bypasses CORS entirely.
---
## 5. Iframe Access Problems
**Problem:** `cy.get()` cannot find elements inside `<iframe>` tags. The iframe's document is separate from the main document Cypress operates on.

**Root Cause:** Iframes create a separate browsing context. Cypress queries the top-level document by default. Cross-origin iframes are blocked by browser security entirely.

**Solution — Custom command for same-origin iframes:**
```javascript
Cypress.Commands.add('getIframeBody', (selector) => {
  return cy.get(selector, { timeout: 10000 })
    .its('0.contentDocument').should('exist')
    .its('body').should('not.be.empty')
    .then(cy.wrap);
});
cy.getIframeBody('#my-iframe').find('[data-testid="iframe-button"]').click();
```
Wait for the iframe to fully load:
```javascript
Cypress.Commands.add('waitForIframe', (selector) => {
  return cy.get(selector)
    .should(($iframe) => {
      expect($iframe[0].contentDocument).to.not.be.null;
      expect($iframe[0].contentDocument.readyState).to.eq('complete');
    })
    .then(($iframe) => cy.wrap($iframe[0].contentDocument.body));
});
```
Handle nested iframes:
```javascript
Cypress.Commands.add('getNestedIframeBody', (outer, inner) => {
  return cy.getIframeBody(outer).find(inner)
    .its('0.contentDocument.body').should('not.be.empty').then(cy.wrap);
});
```
Cross-origin iframes with `cy.origin()`:
```javascript
cy.get('#cross-origin-iframe').invoke('attr', 'src').then((src) => {
  cy.origin(new URL(src).origin, () => { cy.get('button.accept').click(); });
});
```
Stub third-party iframe content:
```javascript
cy.intercept('GET', 'https://third-party.com/widget*', {
  statusCode: 200, headers: { 'content-type': 'text/html' },
  body: '<html><body><button id="mock-btn">OK</button></body></html>',
});
```

**Prevention:** Always wait for `readyState === 'complete'`. Serve iframe content from the same origin when possible. Stub third-party iframes to remove external dependencies.
---
## 6. Memory Leaks in Long Specs
**Problem:** Tests get progressively slower or the browser crashes with "Out of Memory." The Cypress UI becomes unresponsive during long suites.

**Root Cause:** Cypress stores DOM snapshots for every command for time-travel debugging. Hundreds of tests accumulate enormous snapshot data. Intercepted request/response bodies also consume memory.

**Solution:**
```javascript
// cypress.config.js
module.exports = defineConfig({
  e2e: {
    experimentalMemoryManagement: true, // Aggressive GC of completed test snapshots
    numTestsKeptInMemory: 5,            // Default is 50; use 0 in CI
  },
});
```
Split large spec files — each spec runs in a fresh browser context:
```
# BAD: cypress/e2e/everything.cy.js (200 tests)
# GOOD:
cypress/e2e/auth/login.cy.js          # 15 tests
cypress/e2e/auth/registration.cy.js    # 12 tests
cypress/e2e/dashboard/overview.cy.js   # 10 tests
cypress/e2e/settings/profile.cy.js     # 9 tests
```
Minimize stored response bodies in intercepts:
```javascript
cy.intercept('GET', '/api/large-dataset', (req) => {
  req.continue((res) => { delete res.body; });
});
```
Run specs sequentially with fresh browser instances via the Module API:
```javascript
const cypress = require('cypress');
const specs = ['cypress/e2e/auth/**/*.cy.js', 'cypress/e2e/dashboard/**/*.cy.js'];
(async () => { for (const spec of specs) await cypress.run({ spec }); })();
```

**Prevention:** Keep specs under 30 tests / 500 lines. Set `numTestsKeptInMemory: 0` in CI. Monitor CI memory and split specs proactively.
---
## 7. Slow Test Execution
**Problem:** Suite runtime is too long, making CI feedback loops unacceptable.

**Root Cause:** Repeated `cy.visit()` reloads the app per test, full login UI flow runs for every test instead of using `cy.session()`, real network requests add latency, and large specs can't be parallelized.

**Solution — Cache auth with `cy.session()`:**
```javascript
Cypress.Commands.add('login', (username, password) => {
  cy.session([username, password], () => {
    cy.visit('/login');
    cy.get('[data-testid="username"]').type(username);
    cy.get('[data-testid="password"]').type(password);
    cy.get('[data-testid="login-btn"]').click();
    cy.url().should('include', '/dashboard');
  }, {
    validate() { cy.request('/api/me').its('status').should('eq', 200); },
  });
});
beforeEach(() => { cy.login('testuser', 'pass123'); cy.visit('/dashboard'); });
```
Reduce `cy.visit()` calls for read-only checks:
```javascript
describe('Dashboard (read-only)', () => {
  before(() => { cy.login('testuser', 'pass123'); cy.visit('/dashboard'); });
  it('shows header', () => { cy.get('h1').should('contain', 'Dashboard'); });
  it('shows sidebar', () => { cy.get('nav').should('be.visible'); });
});
```
Stub network requests to eliminate latency:
```javascript
beforeEach(() => {
  cy.intercept('GET', '/api/dashboard/stats', { fixture: 'dashboard-stats.json' });
  cy.intercept('GET', '/api/notifications', { fixture: 'notifications.json' });
  cy.visit('/dashboard');
});
```
Use API shortcuts for test setup instead of UI interactions:
```javascript
// BAD — slow UI-based setup
beforeEach(() => { cy.visit('/admin'); cy.get('#name').type('User'); cy.get('form').submit(); });
// GOOD — fast API-based setup
beforeEach(() => { cy.request('POST', '/api/users', { name: 'User' }); });
```
Parallel execution with GitHub Actions:
```yaml
jobs:
  cypress:
    strategy:
      matrix:
        container: [1, 2, 3, 4]
    steps:
      - uses: cypress-io/github-action@v6
        with:
          record: true
          parallel: true
          group: 'e2e-tests'
        env:
          CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
```

**Prevention:** Use `cy.session()` for authentication. Seed data via `cy.request()` / `cy.task()`, not the UI. Stub external APIs by default.
---
## 8. CI Failures
**Problem:** Tests pass locally but fail in CI due to missing dependencies, headless rendering differences, or environment mismatches.

**Root Cause:** Missing browser/system libraries, no display server, different fonts/resolution, stale caches, or missing Cypress binary.

**Solution — Use official Docker images:**
```yaml
jobs:
  cypress:
    runs-on: ubuntu-latest
    container:
      image: cypress/browsers:node-20.18.0-chrome-130.0.6723.69-1-ff-131.0.3-edge-130.0.2849.52-1
    steps:
      - uses: actions/checkout@v4
      - uses: cypress-io/github-action@v6
        with:
          browser: chrome
```
Install dependencies on bare Ubuntu:
```yaml
- run: |
    sudo apt-get update && sudo apt-get install -y \
      libgtk2.0-0 libgtk-3-0 libgbm-dev libnotify-dev libnss3 \
      libxss1 libasound2 libxtst6 xauth xvfb fonts-liberation
```
Cache node_modules and Cypress binary separately:
```yaml
- uses: actions/cache@v4
  with:
    path: node_modules
    key: node-modules-${{ hashFiles('package-lock.json') }}
- uses: actions/cache@v4
  with:
    path: ~/.cache/Cypress
    key: cypress-binary-${{ hashFiles('package-lock.json') }}
- run: npm ci && npx cypress verify
```
Handle Xvfb for headless mode:
```yaml
- run: Xvfb :99 -screen 0 1280x720x24 &
- run: npx cypress run --browser chrome
  env:
    DISPLAY: ':99'
```
Upload failure artifacts:
```yaml
- uses: cypress-io/github-action@v6
- if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: cypress-screenshots
    path: cypress/screenshots
- if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: cypress-videos
    path: cypress/videos
```
GitHub Actions tips:
```yaml
- uses: cypress-io/github-action@v6
  with:
    config: defaultCommandTimeout=15000,pageLoadTimeout=60000
    wait-on: 'http://localhost:3000'
    wait-on-timeout: 120
```

**Prevention:** Match Node.js versions between local and CI. Pin Cypress version in `package.json`. Run `npx cypress verify` in CI. Use `cypress-io/github-action` which handles Xvfb and caching.
---
## 9. Screenshots/Videos Debugging
**Problem:** Failure screenshots are blank/unhelpful, videos are too large, or artifacts are missing from CI.

**Root Cause:** Default screenshot timing may capture post-cleanup state, compression settings are wrong, or CI artifact upload only runs on success.

**Solution — Configure capture:**
```javascript
// cypress.config.js
module.exports = defineConfig({
  e2e: {
    screenshotOnRunFailure: true,
    screenshotsFolder: 'cypress/screenshots',
    video: true,
    videosFolder: 'cypress/videos',
    videoCompression: 32, // 0 = none, 32 = default, false = disable video
  },
});
```
Take targeted screenshots during execution:
```javascript
cy.get('[data-testid="error-message"]').should('be.visible');
cy.screenshot('error-state', { capture: 'viewport' });
// Options: 'fullPage' (scrolls), 'viewport' (visible area), or element-level:
cy.get('[data-testid="chart"]').screenshot('chart-element');
```
Custom debug screenshot command:
```javascript
Cypress.Commands.add('debugScreenshot', (label) => {
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  cy.screenshot(`debug/${label}-${ts}`, { capture: 'viewport', overwrite: false });
});
```
Log failure details for screenshot correlation:
```javascript
Cypress.on('test:after:run', (test, runnable) => {
  if (test.state === 'failed') {
    const title = runnable.titlePath().join(' > ');
    console.log(`FAILED: ${Cypress.spec.name} > ${title}`);
  }
});
```
CI artifact upload (use `if: failure()` or `if: always()`):
```yaml
- if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: cypress-screenshots-${{ github.run_id }}
    path: cypress/screenshots
    retention-days: 7
- if: always()
  uses: actions/upload-artifact@v4
  with:
    name: cypress-videos-${{ github.run_id }}
    path: cypress/videos
    retention-days: 3
    if-no-files-found: ignore
```

**Prevention:** Always use `if: failure()` for artifact uploads. Set `retention-days`. Use `videoCompression: 32` for balanced size/quality. Disable video in CI when only screenshots suffice.
---
## 10. Cypress vs App State Conflicts
**Problem:** Tests pass individually but fail when run together. Test B sees stale state from Test A.

**Root Cause:** localStorage/sessionStorage persist between tests within a spec, cookies survive, IndexedDB is not cleared by default cleanup, service workers cache stale responses, and `before()` vs `beforeEach()` misuse shares mutable state.

**Solution — Enable test isolation (default in Cypress 12+):**
```javascript
// cypress.config.js
module.exports = defineConfig({ e2e: { testIsolation: true } });
```
Explicit cleanup in beforeEach:
```javascript
beforeEach(() => {
  cy.clearLocalStorage();
  cy.clearCookies();
  cy.window().then((win) => win.sessionStorage.clear());
});
```
Clear IndexedDB:
```javascript
Cypress.Commands.add('clearIndexedDB', () => {
  cy.window().then((win) => new Cypress.Promise((resolve) => {
    if (win.indexedDB?.databases) {
      win.indexedDB.databases().then((dbs) => {
        Promise.all(dbs.map((db) =>
          new Promise((r) => { const req = win.indexedDB.deleteDatabase(db.name); req.onsuccess = r; req.onerror = r; })
        )).then(resolve);
      });
    } else resolve();
  }));
});
```
Unregister service workers and clear Cache API:
```javascript
Cypress.Commands.add('unregisterServiceWorkers', () => {
  cy.window().then((win) => {
    if (win.navigator?.serviceWorker)
      win.navigator.serviceWorker.getRegistrations().then((regs) => regs.forEach((r) => r.unregister()));
  });
});
Cypress.Commands.add('clearCacheStorage', () => {
  cy.window().then((win) => {
    if (win.caches) win.caches.keys().then((names) => names.forEach((n) => win.caches.delete(n)));
  });
});
```
Understand `before()` vs `beforeEach()`:
```javascript
// BAD — `before` runs ONCE; mutations in test A affect test B
describe('User profile', () => {
  before(() => { cy.request('POST', '/api/users', { name: 'Test User' }); });
  it('updates name', () => { cy.request('PATCH', '/api/users/1', { name: 'Changed' }); });
  it('shows original', () => {
    cy.visit('/users/1');
    cy.get('h1').should('contain', 'Test User'); // FAILS — state mutated
  });
});
// GOOD — `beforeEach` ensures fresh state per test
describe('User profile', () => {
  beforeEach(() => { cy.request('POST', '/api/test/reset'); });
  it('updates name', () => { /* ... */ });
  it('shows original', () => { /* passes */ });
});
```
Full reset command combining all strategies:
```javascript
Cypress.Commands.add('fullReset', () => {
  cy.clearLocalStorage();
  cy.clearCookies();
  cy.window().then((win) => win.sessionStorage.clear());
  cy.clearIndexedDB();
  cy.unregisterServiceWorkers();
  cy.clearCacheStorage();
});
beforeEach(() => { cy.fullReset(); });
```
Isolate test data with unique identifiers:
```javascript
beforeEach(() => {
  const uid = `test-${Date.now()}-${Cypress._.random(1000)}`;
  cy.request('POST', '/api/users', { name: `User ${uid}`, email: `${uid}@test.com` })
    .then((res) => cy.wrap(res.body.id).as('userId'));
  cy.wrap(uid).as('testId');
});
```

**Prevention:** Use `beforeEach()` for setup (not `before()` for mutable state). Keep `testIsolation: true`. Create a `cy.fullReset()` command. Generate unique test data per test.
---
## Quick Reference: Error → Fix

| Error | § | Fix |
|---|---|---|
| `element is detached from the DOM` | [2](#2-element-detached-from-dom) | Re-query with `cy.get()` + `.should()` |
| `cy.visit() failed...different origin` | [4](#4-cors-issues) | `cy.origin()` or `chromeWebSecurity: false` |
| `Timed out retrying after 4000ms` | [1](#1-flaky-tests) | Add `.should()` assertions; increase timeout |
| `cy.wait() timed out...@alias` | [3](#3-cyintercept-not-matching) | Verify URL pattern and HTTP method |
| `Cannot access contentDocument` | [5](#5-iframe-access-problems) | Wait for iframe load; check same-origin |
| `Out of memory` / Page crash | [6](#6-memory-leaks-in-long-specs) | Split specs; `numTestsKeptInMemory: 0` |
| `No binary found` / `ENOENT` | [8](#8-ci-failures) | `npx cypress install && npx cypress verify` |
| Test isolation violation | [10](#10-cypress-vs-app-state-conflicts) | `cy.fullReset()` in `beforeEach` |

## Further Resources
- [Cypress Best Practices](https://docs.cypress.io/guides/references/best-practices)
- [Cypress Retry-ability](https://docs.cypress.io/guides/core-concepts/retry-ability)
- [Cypress Network Requests](https://docs.cypress.io/guides/guides/network-requests)
- [Cypress CI Configuration](https://docs.cypress.io/guides/continuous-integration/introduction)
