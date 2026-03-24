---
name: cypress-testing
description: >
  Guide for Cypress E2E testing, component testing, browser automation, and API testing.
  Use when writing or debugging Cypress tests, cy.intercept stubs, fixtures, custom commands,
  cy.session auth, component mounting, visual regression, or CI/CD pipeline config for Cypress.
  Use for Cypress selectors (data-cy), assertion chains (.should), retry-ability, flake fixes,
  Cypress Cloud setup, and GitHub Actions integration.
  Do NOT use for Playwright or Selenium tests, unit testing with Jest or Vitest,
  React Testing Library (non-Cypress), mobile/native app testing, or multi-browser parallel
  testing outside Cypress Cloud orchestration.
---

# Cypress Testing

## Installation and Project Setup

Install Cypress as a dev dependency and open the launchpad:

```bash
npm install cypress --save-dev
npx cypress open
```

Generate default config by running `npx cypress open` once. Cypress creates:
- `cypress.config.js` (or `.ts`) — central configuration
- `cypress/e2e/` — E2E spec files
- `cypress/fixtures/` — static test data
- `cypress/support/` — commands and global hooks

Minimal `cypress.config.js`:

```js
const { defineConfig } = require('cypress');

module.exports = defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',
    viewportWidth: 1280,
    viewportHeight: 720,
    defaultCommandTimeout: 10000,
    video: false,
    screenshotOnRunFailure: true,
    setupNodeEvents(on, config) {
      // register plugins here
    },
  },
});
```

Use TypeScript by adding `cypress/tsconfig.json` with `"types": ["cypress"]` in `compilerOptions`.

## E2E Test Structure

Use `describe` for grouping, `it` for individual tests, `beforeEach` for setup:

```js
describe('Login Flow', () => {
  beforeEach(() => {
    cy.visit('/login');
  });

  it('should display login form', () => {
    cy.get('[data-cy="login-form"]').should('be.visible');
  });

  it('should login with valid credentials', () => {
    cy.get('[data-cy="email"]').type('user@example.com');
    cy.get('[data-cy="password"]').type('password123');
    cy.get('[data-cy="submit"]').click();
    cy.url().should('include', '/dashboard');
  });

  it('should show error on invalid login', () => {
    cy.get('[data-cy="email"]').type('bad@example.com');
    cy.get('[data-cy="password"]').type('wrong');
    cy.get('[data-cy="submit"]').click();
    cy.get('[data-cy="error-message"]').should('contain', 'Invalid credentials');
  });
});
```

Use `context` as an alias for nested `describe` to group related scenarios.

## Selectors and Best Practices

Prefer `data-cy` attributes over CSS classes, IDs, or tag names:

```html
<!-- Good -->
<button data-cy="submit-order">Place Order</button>
<!-- Avoid -->
<button class="btn btn-primary" id="submitBtn">Place Order</button>
```

Selector priority (most to least stable):
1. `[data-cy="name"]` — dedicated test attribute, immune to styling changes
2. `[data-testid="name"]` — common alternative
3. `[aria-label="name"]` — doubles as accessibility
4. Never rely on CSS classes, nth-child, or DOM structure

Use `cy.contains()` for text-based selection when appropriate:

```js
cy.contains('button', 'Submit').click();
```

## Assertions and Should Chains

Chain `.should()` for implicit assertions with automatic retries:

```js
cy.get('[data-cy="items"]').should('have.length', 3);
cy.get('[data-cy="status"]').should('contain', 'Active').and('be.visible');
cy.get('[data-cy="price"]').should('have.text', '$29.99');
cy.get('[data-cy="input"]').should('have.value', 'hello');
cy.get('[data-cy="modal"]').should('not.exist');
```

Use `.then()` for complex assertions:

```js
cy.get('[data-cy="total"]').then(($el) => {
  const total = parseFloat($el.text().replace('$', ''));
  expect(total).to.be.greaterThan(0);
});
```

## Network Interception (cy.intercept)

Stub API responses to isolate frontend tests from backend:

```js
// Stub a GET request with fixture data
cy.intercept('GET', '/api/users', { fixture: 'users.json' }).as('getUsers');
cy.visit('/users');
cy.wait('@getUsers');
cy.get('[data-cy="user-list"]').should('have.length', 3);

// Stub with inline body
cy.intercept('POST', '/api/orders', {
  statusCode: 201,
  body: { id: 'order-123', status: 'created' },
}).as('createOrder');

// Spy without stubbing (observe real requests)
cy.intercept('GET', '/api/products').as('getProducts');
cy.visit('/products');
cy.wait('@getProducts').its('response.statusCode').should('eq', 200);

// Modify request before it reaches server
cy.intercept('POST', '/api/data', (req) => {
  req.headers['Authorization'] = 'Bearer test-token';
  req.continue();
});

// Simulate network errors
cy.intercept('GET', '/api/health', { forceNetworkError: true }).as('healthFail');

// Delay response for loading state testing
cy.intercept('GET', '/api/slow', (req) => {
  req.reply({ delay: 2000, body: { data: 'delayed' } });
});
```

Always alias intercepted routes with `.as()` and synchronize with `cy.wait('@alias')`.

## Fixtures and Test Data

Store JSON fixtures in `cypress/fixtures/`:

```json
// cypress/fixtures/users.json
[
  { "id": 1, "name": "Alice", "email": "alice@example.com" },
  { "id": 2, "name": "Bob", "email": "bob@example.com" }
]
```

Load fixtures in tests:

```js
cy.fixture('users.json').then((users) => {
  cy.intercept('GET', '/api/users', users).as('getUsers');
});

// Or use shorthand in intercept
cy.intercept('GET', '/api/users', { fixture: 'users.json' });
```

Use `beforeEach` with `cy.fixture` and alias for shared access:

```js
beforeEach(() => {
  cy.fixture('users.json').as('usersData');
});

it('uses fixture data', function () {
  // Access via this context (requires function keyword, not arrow)
  expect(this.usersData).to.have.length(2);
});
```

## Custom Commands and Queries

Define reusable commands in `cypress/support/commands.js`:

```js
Cypress.Commands.add('login', (email, password) => {
  cy.session([email, password], () => {
    cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
      window.localStorage.setItem('token', resp.body.token);
    });
  });
});

Cypress.Commands.add('getByDataCy', (selector) => {
  return cy.get(`[data-cy="${selector}"]`);
});
```

Add TypeScript definitions in `cypress/support/index.d.ts`:

```ts
declare namespace Cypress {
  interface Chainable {
    login(email: string, password: string): Chainable<void>;
    getByDataCy(selector: string): Chainable<JQuery<HTMLElement>>;
  }
}
```

Use custom queries (Cypress 12+) for retry-able lookups:

```js
Cypress.Commands.addQuery('getByDataCy', (selector) => {
  const getFn = cy.now('get', `[data-cy="${selector}"]`);
  return () => getFn();
});
```

## Component Testing Setup

Install the framework-specific dev server. For React + Vite:

```bash
npm install --save-dev @cypress/react @cypress/vite-dev-server
```

Add component testing config to `cypress.config.js`:

```js
const { defineConfig } = require('cypress');

module.exports = defineConfig({
  component: {
    devServer: {
      framework: 'react',
      bundler: 'vite',
    },
    specPattern: 'src/**/*.cy.{js,jsx,ts,tsx}',
  },
});
```

For Vue + Vite, set `framework: 'vue'`. For Next.js, use `framework: 'next'`.

Write a component test co-located with the component:

```jsx
// src/components/Button.cy.jsx
import Button from './Button';

describe('Button', () => {
  it('renders with label', () => {
    cy.mount(<Button label="Click me" />);
    cy.contains('Click me').should('be.visible');
  });

  it('calls onClick handler', () => {
    const onClick = cy.stub().as('clickHandler');
    cy.mount(<Button label="Submit" onClick={onClick} />);
    cy.contains('Submit').click();
    cy.get('@clickHandler').should('have.been.calledOnce');
  });
});
```

Run component tests: `npx cypress run --component`.

## Authentication Patterns

Use `cy.session()` for programmatic login to avoid UI login in every test:

```js
Cypress.Commands.add('loginByApi', (username, password) => {
  cy.session(
    [username, password],
    () => {
      cy.request({
        method: 'POST',
        url: '/api/auth/login',
        body: { username, password },
      }).then(({ body }) => {
        window.localStorage.setItem('authToken', body.token);
      });
    },
    {
      validate() {
        cy.request({
          url: '/api/auth/me',
          headers: {
            Authorization: `Bearer ${window.localStorage.getItem('authToken')}`,
          },
        }).its('status').should('eq', 200);
      },
    }
  );
});
```

Usage: call `cy.loginByApi('admin@test.com', 'pass')` in `beforeEach`. For cookie-based auth, `cy.session` preserves cookies automatically.

## File Uploads, Downloads, and Iframes

File upload using `cy.selectFile()` (built-in since Cypress 9.3):

```js
cy.get('[data-cy="file-input"]').selectFile('cypress/fixtures/document.pdf');
// Drag and drop
cy.get('[data-cy="dropzone"]').selectFile('cypress/fixtures/image.png', {
  action: 'drag-drop',
});
// Multiple files
cy.get('[data-cy="file-input"]').selectFile([
  'cypress/fixtures/file1.txt',
  'cypress/fixtures/file2.txt',
]);
```

File download verification:

```js
cy.get('[data-cy="download-btn"]').click();
const downloadsFolder = Cypress.config('downloadsFolder');
cy.readFile(`${downloadsFolder}/report.csv`).should('contain', 'header1');
```

Iframe interaction:

```js
cy.get('iframe[data-cy="embed"]')
  .its('0.contentDocument.body')
  .should('not.be.empty')
  .then(cy.wrap)
  .find('[data-cy="iframe-button"]')
  .click();
```

## Retry-ability and Flake Prevention

Rules to prevent flaky tests:
- Never use `cy.wait(milliseconds)` for timing. Use `cy.wait('@alias')` for network.
- Use `.should()` assertions that auto-retry instead of `.then()` with manual checks.
- Ensure test isolation: each test must set up its own state via `beforeEach`.
- Never depend on test execution order.
- Use `cy.session()` to cache auth instead of logging in via UI each time.
- Set `{ testIsolation: true }` (default in Cypress 12+) to clear state between tests.
- Use `retries` config for CI flake tolerance.

Configure retries in `cypress.config.js`:

```js
module.exports = defineConfig({
  retries: { runMode: 2, openMode: 0 },
});
```

Guard against detached DOM elements:

```js
// Bad — element may detach between get and click
cy.get('[data-cy="btn"]').then(($btn) => $btn.click());
// Good — Cypress retries the full chain
cy.get('[data-cy="btn"]').click();
```

## CI/CD Integration (GitHub Actions)

```yaml
name: Cypress Tests
on: [push, pull_request]
jobs:
  e2e:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        containers: [1, 2, 3]
    steps:
      - uses: actions/checkout@v4
      - uses: cypress-io/github-action@v6
        with:
          build: npm run build
          start: npm run start
          wait-on: 'http://localhost:3000'
          record: true
          parallel: true
          group: 'e2e-tests'
        env:
          CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-screenshots-${{ matrix.containers }}
          path: cypress/screenshots
```

Key `cypress-io/github-action` options: `build`, `start`, `wait-on`, `record`, `parallel`, `browser` (`chrome`|`firefox`|`electron`), `spec`.

## Cypress Cloud and Dashboard

Set `projectId` in `cypress.config.js` and record with `npx cypress run --record --key <key>`.

Cypress Cloud provides: test replay with time-travel debugging, flake detection, parallelization orchestration (spec balancing across CI machines), screenshots/video artifacts, and Git integration showing test status on PRs. Store the record key as `CYPRESS_RECORD_KEY` env var — never commit it.

## Visual Regression Testing

Use `@percy/cypress` for cloud-based visual diffs or `cypress-image-snapshot` for local-only comparisons. Install with `npm install --save-dev @percy/cli @percy/cypress` and call `cy.percySnapshot('Name')` in tests. Run via `npx percy exec -- cypress run`.

## Environment Variables and Configuration

Set env vars (highest to lowest priority):
1. CLI: `npx cypress run --env apiUrl=http://localhost:4000`
2. `cypress.env.json` (gitignored): `{ "apiUrl": "http://localhost:4000" }`
3. OS environment prefixed with `CYPRESS_`: `CYPRESS_API_URL=http://localhost:4000`
4. `cypress.config.js` `env` block

Access in tests: `Cypress.env('apiUrl')`.

## API Testing with cy.request

Use `cy.request()` for direct API testing without browser rendering. Chain with `cy.intercept` to seed data before E2E flows. See `assets/commands.ts` for reusable API helper commands.

## References

Deep-dive guides for advanced topics:

- **[Advanced Patterns](references/advanced-patterns.md)** — Custom commands vs queries, page object model, app actions, cy.intercept advanced usage (dynamic responses, delays, error simulation), cy.session, test isolation, clock/timer manipulation, shadow DOM, iframes, multi-domain testing with cy.origin, and component testing architecture.
- **[Troubleshooting](references/troubleshooting.md)** — Flaky tests (causes and fixes), detached DOM elements, race conditions, cy.intercept not matching, CORS issues, iframe access, slow test optimization, memory leaks, CI-specific failures, and Cypress vs Playwright decision matrix.
- **[CI Integration](references/ci-integration.md)** — GitHub Actions setup with caching, parallel runs with Cypress Cloud, Docker-based testing, recording and artifacts, retry strategies, test splitting, dashboard integration, and cost optimization.

## Scripts

Automation scripts for common Cypress workflows:

- **[setup-cypress.sh](scripts/setup-cypress.sh)** — Sets up Cypress in an existing project: installs dependencies, creates config, folder structure, and example specs. Supports `--typescript`, `--component`, and `--ci` flags.
- **[generate-command.sh](scripts/generate-command.sh)** — Generates a new custom Cypress command with TypeScript declarations. Usage: `./generate-command.sh <commandName> <description>`.

## Assets

Ready-to-use templates and configurations:

- **[cypress.config.ts](assets/cypress.config.ts)** — Production-ready Cypress config template with E2E and component testing setup, CI-aware settings, and memory optimization.
- **[commands.ts](assets/commands.ts)** — Collection of custom commands: login/auth with session caching, API helpers, drag-and-drop, file upload, table assertions, paste, and network idle detection.
- **[github-actions.yml](assets/github-actions.yml)** — GitHub Actions workflow with dependency caching, parallel runs, path filtering, component and E2E test jobs, artifact upload, and a summary gate job.
