# Cypress Troubleshooting Guide

## Table of Contents

- [Flaky Tests](#flaky-tests)
  - [Common Causes](#common-causes)
  - [Fixes and Prevention](#fixes-and-prevention)
- [Detached DOM Elements](#detached-dom-elements)
- [Race Conditions](#race-conditions)
- [cy.intercept Not Matching](#cyintercept-not-matching)
- [CORS Issues](#cors-issues)
- [Iframe Access Problems](#iframe-access-problems)
- [Slow Tests Optimization](#slow-tests-optimization)
- [Memory Leaks in Long Test Suites](#memory-leaks-in-long-test-suites)
- [CI-Specific Failures](#ci-specific-failures)
  - [Missing Dependencies](#missing-dependencies)
  - [Headless Browser Issues](#headless-browser-issues)
  - [Docker Troubleshooting](#docker-troubleshooting)
- [Cypress vs Playwright Decision Matrix](#cypress-vs-playwright-decision-matrix)

---

## Flaky Tests

### Common Causes

1. **Timing dependencies** — tests assume elements appear instantly.
2. **Shared state** — tests rely on state from previous tests.
3. **Unstubbed network** — real API responses vary between runs.
4. **Animation interference** — clicks land on animating elements.
5. **Viewport differences** — elements hidden at certain screen sizes.
6. **Third-party scripts** — analytics/chat widgets interfere with selectors.

### Fixes and Prevention

**Replace hard waits with assertions:**

```ts
// ❌ Flaky
cy.wait(3000);
cy.get('[data-cy="result"]').click();

// ✅ Reliable
cy.get('[data-cy="result"]').should('be.visible').click();
```

**Wait for network requests explicitly:**

```ts
cy.intercept('GET', '/api/data').as('getData');
cy.visit('/page');
cy.wait('@getData');
cy.get('[data-cy="data-table"]').should('exist');
```

**Disable animations in test mode:**

```css
/* cypress/support/disable-animations.css */
*, *::before, *::after {
  animation-duration: 0s !important;
  animation-delay: 0s !important;
  transition-duration: 0s !important;
  transition-delay: 0s !important;
}
```

```ts
// cypress/support/e2e.ts
import './disable-animations.css';
```

**Use `cy.session()` for deterministic auth:**

```ts
beforeEach(() => {
  cy.loginByApi('user@test.com', 'password');
  cy.visit('/dashboard');
});
```

**Configure retries for CI:**

```ts
// cypress.config.ts
export default defineConfig({
  retries: {
    runMode: 2,   // CI retries
    openMode: 0,  // local — see failures immediately
  },
});
```

---

## Detached DOM Elements

**Symptom:** `cy.click()` fails with "element is detached from the DOM."

**Cause:** React/Vue/Angular re-renders replace the element between Cypress finding it and acting on it.

**Fixes:**

```ts
// ❌ Element may detach between .then() and .click()
cy.get('[data-cy="item"]').then(($el) => {
  // ... some logic
  cy.wrap($el).click(); // $el may be stale
});

// ✅ Re-query after any operation that may trigger re-render
cy.get('[data-cy="item"]').click(); // Cypress auto-retries the query

// ✅ For complex scenarios, guard with should
cy.get('[data-cy="item"]')
  .should('be.visible')
  .and('not.be.disabled')
  .click();

// ✅ Use an alias and re-query
cy.get('[data-cy="list"]').find('li').first().as('firstItem');
cy.get('@firstItem').should('exist'); // re-queries from alias
```

**When elements intentionally detach (e.g., modal closes, list re-sorts):**

```ts
// Wait for the re-render to complete
cy.get('[data-cy="sort-btn"]').click();
// Don't reuse old references — re-query
cy.get('[data-cy="list-item"]').first().should('contain', 'Alpha');
```

---

## Race Conditions

### Problem: Action Before Page Ready

```ts
// ❌ Page may not be fully loaded
cy.visit('/dashboard');
cy.get('[data-cy="chart"]').click();

// ✅ Wait for a specific readiness indicator
cy.visit('/dashboard');
cy.get('[data-cy="chart"]').should('be.visible').click();
```

### Problem: Multiple Rapid Clicks

```ts
// ❌ Double-submit
cy.get('[data-cy="submit"]').click();
cy.get('[data-cy="submit"]').click();

// ✅ Verify state between actions
cy.get('[data-cy="submit"]').click();
cy.get('[data-cy="submit"]').should('be.disabled');
```

### Problem: Intercepted Routes Not Ready

```ts
// ❌ intercept registered after visit — misses the request
cy.visit('/page');
cy.intercept('GET', '/api/data', { fixture: 'data.json' }).as('getData');

// ✅ Register intercepts BEFORE triggering the request
cy.intercept('GET', '/api/data', { fixture: 'data.json' }).as('getData');
cy.visit('/page');
cy.wait('@getData');
```

### Problem: Assertion on Element That Updates

```ts
// ❌ May catch intermediate state
cy.get('[data-cy="count"]').should('have.text', '5');

// ✅ Use a function assertion for complex checks
cy.get('[data-cy="count"]').should(($el) => {
  const count = parseInt($el.text(), 10);
  expect(count).to.eq(5);
});
```

---

## cy.intercept Not Matching

### Debugging Steps

```ts
// 1. Log all outgoing requests to find the actual URL
cy.intercept('*', (req) => {
  console.log(`${req.method} ${req.url}`);
  req.continue();
});

// 2. Use a broader pattern, then narrow down
cy.intercept('/api/**').as('anyApi');
```

### Common Causes and Fixes

**URL mismatch (relative vs absolute):**

```ts
// ❌ Won't match if baseUrl is set
cy.intercept('GET', 'http://localhost:3000/api/users', ...);

// ✅ Use path-only patterns
cy.intercept('GET', '/api/users', ...);

// ✅ Use glob or regex for dynamic segments
cy.intercept('GET', '/api/users/*', ...);
cy.intercept('GET', /\/api\/users\/\d+/, ...);
```

**Query parameters:**

```ts
// ❌ Query params in the URL string are ignored
cy.intercept('GET', '/api/users?role=admin', ...);

// ✅ Use the query option
cy.intercept({ method: 'GET', url: '/api/users', query: { role: 'admin' } }, ...).as('getAdmins');
```

**Intercept order (last wins):**

```ts
// The LAST matching intercept takes priority
cy.intercept('GET', '/api/users', { body: [] });       // overridden
cy.intercept('GET', '/api/users', { body: [{ id: 1 }] }); // this one wins
```

**Request already fired:**

```ts
// ❌ cy.visit triggers the request before intercept is registered
cy.visit('/users');
cy.intercept('GET', '/api/users', ...).as('getUsers');

// ✅ Always register intercepts first
cy.intercept('GET', '/api/users', ...).as('getUsers');
cy.visit('/users');
cy.wait('@getUsers');
```

**POST body matching:**

```ts
// Filter by request body
cy.intercept('POST', '/api/search', (req) => {
  if (req.body.query === 'specific') {
    req.reply({ results: ['found'] });
  } else {
    req.continue();
  }
}).as('search');
```

---

## CORS Issues

**Symptom:** `cy.request()` returns a CORS error or `cy.visit()` shows a blank page for cross-origin resources.

### Fixes

**For `cy.request` — bypass CORS entirely:**
`cy.request` does NOT go through the browser — it uses Node.js HTTP. If you're getting CORS errors with `cy.request`, the issue is likely on the server (preflight failure). Check the server allows the origin.

**For `cy.visit` with chromeWebSecurity:**

```ts
// cypress.config.ts
export default defineConfig({
  e2e: {
    chromeWebSecurity: false, // disables same-origin policy in Chrome
  },
});
```

> ⚠️ Only works in Chromium browsers. Firefox ignores this setting.

**For cross-origin API calls from the app:**

```ts
// Proxy through Cypress
// cypress.config.ts
export default defineConfig({
  e2e: {
    setupNodeEvents(on, config) {
      // configure a proxy or use cy.intercept to stub cross-origin calls
    },
  },
});

// Or intercept and stub the cross-origin call
cy.intercept('GET', 'https://external-api.com/**', { fixture: 'external-data.json' });
```

---

## Iframe Access Problems

**Symptom:** `cy.get('iframe').find(...)` returns nothing or errors.

### Same-Origin Iframes

```ts
// ❌ find() doesn't cross iframe boundaries
cy.get('iframe').find('button');

// ✅ Access the iframe's document body
cy.get('iframe')
  .its('0.contentDocument.body')
  .should('not.be.empty')
  .then(cy.wrap)
  .find('button')
  .click();
```

### Cross-Origin Iframes

Cross-origin iframes cannot be accessed directly. Options:

```ts
// Option 1: Disable web security (Chrome only)
// cypress.config.ts: chromeWebSecurity: false

// Option 2: Stub the iframe content
cy.intercept('GET', 'https://external.com/widget', {
  body: '<html><body><button id="pay">Pay</button></body></html>',
  headers: { 'content-type': 'text/html' },
});

// Option 3: Test the iframe content separately
// Create a separate spec that visits the iframe URL directly
```

### Iframe Load Timing

```ts
// Wait for iframe to fully load
cy.get('iframe[data-cy="editor"]', { timeout: 15000 })
  .should(($iframe) => {
    const body = $iframe[0].contentDocument?.body;
    expect(body).to.exist;
    expect(body.children.length).to.be.greaterThan(0);
  })
  .its('0.contentDocument.body')
  .then(cy.wrap)
  .find('.editor-content')
  .should('be.visible');
```

---

## Slow Tests Optimization

### Diagnosis

```bash
# Find slow specs
npx cypress run --reporter cypress-multi-reporters --reporter-options \
  configFile=reporter-config.json

# Use Cypress Cloud for timing breakdowns
npx cypress run --record
```

### Optimization Strategies

**1. Use `cy.session()` — biggest single improvement:**

```ts
// Before: 2-5s per test for UI login
beforeEach(() => { loginViaUI(); }); // each test: login + navigate

// After: ~50ms per test (cached)
beforeEach(() => {
  cy.session('admin', () => { loginViaUI(); });
  cy.visit('/dashboard');
});
```

**2. Use API seeding instead of UI setup:**

```ts
// ❌ Slow: create test data through UI (10+ seconds)
cy.visit('/admin/products');
cy.get('[data-cy="add"]').click();
cy.get('[data-cy="name"]').type('Widget');
cy.get('[data-cy="save"]').click();

// ✅ Fast: API call (~100ms)
cy.request('POST', '/api/products', { name: 'Widget' });
```

**3. Parallelize with Cypress Cloud:**

```yaml
# GitHub Actions
strategy:
  matrix:
    containers: [1, 2, 3, 4]
steps:
  - uses: cypress-io/github-action@v6
    with:
      record: true
      parallel: true
```

**4. Limit video recording:**

```ts
// Only record on failure
export default defineConfig({
  video: false, // or true only in CI
  screenshotOnRunFailure: true,
});
```

**5. Optimize spec file size:**
- Keep specs under 20 tests each.
- Group related tests by feature, not by type.
- Use `describe.only` / `it.only` during development.

**6. Stub external services:**

```ts
// Stub slow third-party APIs
cy.intercept('GET', 'https://api.stripe.com/**', { fixture: 'stripe-response.json' });
cy.intercept('GET', 'https://maps.googleapis.com/**', { body: {} });
```

---

## Memory Leaks in Long Test Suites

### Symptoms

- Tests pass individually but fail in a full suite run.
- Browser becomes unresponsive after 50+ tests.
- "Out of memory" errors in CI.

### Causes and Fixes

**1. Snapshot accumulation:**

```ts
// Cypress stores a DOM snapshot per command; large DOMs + many commands = OOM
// Reduce numTestsKeptInMemory
export default defineConfig({
  numTestsKeptInMemory: 5, // default: 50 (interactive), 0 (run mode)
});
```

**2. Large fixture files:**

```ts
// ❌ Loading 10MB fixture per test
cy.fixture('huge-dataset.json').then((data) => { ... });

// ✅ Use smaller, focused fixtures
cy.fixture('dataset-page1.json').then((data) => { ... });

// ✅ Generate minimal test data inline
const items = Array.from({ length: 10 }, (_, i) => ({ id: i, name: `Item ${i}` }));
```

**3. Uncleaned event listeners / intervals:**

```ts
afterEach(() => {
  // Clean up if your app attaches listeners to window
  cy.window().then((win) => {
    win.dispatchEvent(new Event('test-cleanup'));
  });
});
```

**4. Video recording memory impact:**

```ts
// Disable video for large suites
export default defineConfig({
  video: false,
  // Or compress aggressively
  videoCompression: 32,
});
```

**5. Split large suites:**

```bash
# Run subsets of specs
npx cypress run --spec "cypress/e2e/auth/**"
npx cypress run --spec "cypress/e2e/dashboard/**"
```

---

## CI-Specific Failures

### Missing Dependencies

**Symptom:** `Cypress failed to start` or missing shared library errors.

```bash
# Ubuntu/Debian — install required system dependencies
apt-get install -y \
  libgtk2.0-0 libgtk-3-0 libgbm-dev libnotify-dev \
  libnss3 libxss1 libasound2 libxtst6 xauth xvfb

# Or use Cypress Docker images (recommended)
FROM cypress/browsers:node-20.14.0-chrome-126.0.6478.114-1-ff-127.0.1-edge-126.0.2592.61-1
```

**Cypress binary cache:**

```bash
# Verify Cypress is installed
npx cypress verify

# Clear and reinstall
npx cypress cache clear
npx cypress install

# CI caching — cache ~/.cache/Cypress
# GitHub Actions:
- uses: actions/cache@v4
  with:
    path: ~/.cache/Cypress
    key: cypress-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
```

### Headless Browser Issues

**Symptom:** Tests pass locally (headed) but fail in CI (headless).

**Common causes:**

1. **Viewport differences:**

```ts
// Set explicit viewport in config
export default defineConfig({
  e2e: {
    viewportWidth: 1280,
    viewportHeight: 720,
  },
});
```

2. **Font rendering differences:**

```ts
// Use tolerance in visual regression tests
cy.matchImageSnapshot('component', { failureThreshold: 0.05 });
```

3. **Timing — CI machines are slower:**

```ts
// Increase timeouts for CI
export default defineConfig({
  e2e: {
    defaultCommandTimeout: process.env.CI ? 15000 : 10000,
    responseTimeout: process.env.CI ? 30000 : 20000,
  },
});
```

4. **GPU/rendering issues:**

```bash
# Run with specific browser flags
npx cypress run --browser chrome --config '{"chromeWebSecurity":false}' \
  -- --disable-gpu --no-sandbox
```

### Docker Troubleshooting

```dockerfile
# Recommended Dockerfile for Cypress in CI
FROM cypress/included:13.6.0

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .

# Run tests
CMD ["npx", "cypress", "run"]
```

```yaml
# docker-compose.yml for testing with services
services:
  app:
    build: .
    ports: ["3000:3000"]

  cypress:
    image: cypress/included:13.6.0
    depends_on:
      app:
        condition: service_healthy
    environment:
      - CYPRESS_baseUrl=http://app:3000
    volumes:
      - .:/e2e
    working_dir: /e2e
    command: npx cypress run
```

---

## Cypress vs Playwright Decision Matrix

| Criteria | Cypress | Playwright |
|----------|---------|------------|
| **Language support** | JavaScript/TypeScript only | JS/TS, Python, Java, C# |
| **Browser support** | Chrome, Firefox, Edge, Electron | Chromium, Firefox, WebKit (Safari) |
| **Architecture** | Runs inside browser (same-origin) | Controls browser via CDP/protocol |
| **Multi-tab/window** | ❌ Not supported | ✅ Native support |
| **Multi-domain** | ✅ via `cy.origin()` (Cypress 12+) | ✅ Native support |
| **Parallel execution** | Via Cypress Cloud (paid) or CI matrix | Built-in, free |
| **Auto-waiting** | ✅ Implicit (command queue) | ✅ Implicit (locator-based) |
| **Network stubbing** | ✅ `cy.intercept()` | ✅ `page.route()` |
| **Component testing** | ✅ Built-in | ✅ Experimental |
| **Visual testing** | Via plugins (Percy, Applitools) | Built-in screenshot comparison |
| **API testing** | ✅ `cy.request()` | ✅ `request` context |
| **Debugging** | Time-travel UI, Cypress Studio | Trace viewer, codegen |
| **iframes** | Manual handling required | ✅ `frame()` / `frameLocator()` |
| **Mobile emulation** | Viewport only | Full device emulation |
| **Test isolation** | Per-test (Cypress 12+) | Per-test by default |
| **Community/ecosystem** | Larger, more plugins | Growing rapidly |
| **Learning curve** | Lower (jQuery-like API) | Moderate (async/await) |
| **CI cost** | Free runner + paid Cloud for parallelization | Fully free parallelization |
| **Best for** | Frontend-heavy apps, component testing, teams familiar with jQuery-style API | Multi-browser/multi-platform, complex multi-page flows, teams wanting free parallel execution |

### When to Choose Cypress

- Your team already uses JavaScript/TypeScript exclusively.
- You need robust component testing integrated with E2E.
- The app is a single-page application with primarily same-origin interactions.
- You value the time-travel debugger and interactive test runner.
- Budget allows for Cypress Cloud for parallelization.

### When to Choose Playwright

- You need Safari/WebKit testing.
- The app involves multi-tab workflows or complex multi-domain flows.
- You need free, built-in parallel execution.
- Your team uses Python, Java, or C# in addition to JavaScript.
- You need full mobile device emulation (not just viewport resizing).
