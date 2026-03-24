---
name: cypress-testing
description: >
  Guide for writing and maintaining Cypress end-to-end and component tests.
  TRIGGER when: user mentions Cypress, Cypress E2E tests, Cypress component testing,
  cy.intercept, cy.get, cy.contains, Cypress custom commands, Cypress fixtures,
  Cypress CI integration, cypress.config, Cypress Cloud, Cypress selectors,
  data-cy attributes, Cypress debugging, Cypress flaky tests, or Cypress setup.
  DO NOT TRIGGER when: user asks about Playwright, Selenium, Puppeteer, WebDriver,
  general unit testing with Jest or Vitest without Cypress context, pure API testing
  without UI, React Testing Library alone, or browser automation unrelated to Cypress.
---

# Cypress Testing Skill

## Architecture

Cypress runs inside the browser alongside the application — no WebDriver, no network latency between test commands and the DOM. This enables synchronous-looking code, automatic waiting, real-time reloading, and time-travel debugging. All commands are enqueued and retried automatically until assertions pass or timeout expires.

## Project Setup

Install and initialize:

```bash
npm install -D cypress typescript
npx cypress open          # scaffolds cypress/ directory
```

### cypress.config.ts

```ts
import { defineConfig } from 'cypress';

export default defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',
    specPattern: 'cypress/e2e/**/*.cy.{js,ts}',
    supportFile: 'cypress/support/e2e.ts',
    viewportWidth: 1280,
    viewportHeight: 720,
    video: false,
    screenshotOnRunFailure: true,
    retries: { runMode: 2, openMode: 0 },
    setupNodeEvents(on, config) {
      // register plugins here
      return config;
    },
  },
  component: {
    devServer: {
      framework: 'react',    // or 'vue', 'angular', 'svelte'
      bundler: 'vite',       // or 'webpack'
    },
    specPattern: 'src/**/*.cy.{js,ts,jsx,tsx}',
  },
});
```

### TypeScript tsconfig (cypress/tsconfig.json)

```json
{
  "compilerOptions": {
    "target": "es6",
    "types": ["cypress"],
    "baseUrl": "..",
    "strict": true
  },
  "include": ["**/*.ts", "../node_modules/cypress"]
}
```

## Directory Structure

```
cypress/
├── e2e/               # E2E test specs (.cy.ts)
├── fixtures/          # Static test data (JSON)
├── support/
│   ├── commands.ts    # Custom commands
│   ├── e2e.ts         # E2E support file (runs before each spec)
│   └── component.ts   # Component test support file
├── downloads/         # Downloaded files during tests
└── screenshots/       # Failure screenshots
src/
└── components/
    └── Button.cy.tsx  # Component test co-located with source
```

## Test Structure

```ts
describe('Login Flow', () => {
  beforeEach(() => {
    cy.intercept('POST', '/api/auth/login', { fixture: 'login-success.json' }).as('loginReq');
    cy.visit('/login');
  });

  it('logs in with valid credentials', () => {
    cy.get('[data-cy=email-input]').type('user@example.com');
    cy.get('[data-cy=password-input]').type('securePass123');
    cy.get('[data-cy=login-button]').click();
    cy.wait('@loginReq').its('request.body').should('deep.include', { email: 'user@example.com' });
    cy.url().should('include', '/dashboard');
    cy.get('[data-cy=welcome-message]').should('contain', 'Welcome');
  });

  it('shows error on invalid credentials', () => {
    cy.intercept('POST', '/api/auth/login', { statusCode: 401, body: { error: 'Invalid' } }).as('loginFail');
    cy.get('[data-cy=email-input]').type('bad@example.com');
    cy.get('[data-cy=password-input]').type('wrong');
    cy.get('[data-cy=login-button]').click();
    cy.wait('@loginFail');
    cy.get('[data-cy=error-alert]').should('be.visible').and('contain', 'Invalid');
  });
});
```

## Selectors — Priority Order

1. `[data-cy=...]` or `[data-testid=...]` — dedicated test attributes, immune to styling changes
2. `cy.contains('Submit')` — visible text, matches user perspective
3. `[role=...]`, `[aria-label=...]` — accessible attributes, stable
4. Avoid: CSS classes, tag names, IDs used for styling — these break on refactors

Configure a custom selector strategy globally:

```ts
// cypress/support/e2e.ts
Cypress.SelectorPlayground.defaults({
  selectorPriority: ['data-cy', 'data-testid', 'id', 'class', 'tag'],
});
```

## Assertions

Cypress bundles Chai, Sinon, and jQuery assertions:

```ts
// .should() — retries until passing or timeout
cy.get('[data-cy=items]').should('have.length', 5);
cy.get('[data-cy=status]').should('contain.text', 'Active');
cy.get('[data-cy=modal]').should('not.exist');
cy.get('[data-cy=btn]').should('be.visible').and('not.be.disabled');

// Callback form for complex assertions
cy.get('[data-cy=price]').should(($el) => {
  const price = parseFloat($el.text().replace('$', ''));
  expect(price).to.be.greaterThan(0);
});
```

## Network Interception (cy.intercept)

### Stub responses

```ts
cy.intercept('GET', '/api/users', { fixture: 'users.json' }).as('getUsers');
cy.intercept('GET', '/api/users/*', { statusCode: 404, body: { error: 'Not found' } });
```

### Spy without modifying

```ts
cy.intercept('POST', '/api/orders').as('createOrder');
cy.get('[data-cy=submit]').click();
cy.wait('@createOrder').then((interception) => {
  expect(interception.request.body).to.have.property('productId');
  expect(interception.response.statusCode).to.eq(201);
});
```

### Dynamic response handlers

```ts
let callCount = 0;
cy.intercept('GET', '/api/notifications', (req) => {
  callCount++;
  req.reply({ fixture: callCount === 1 ? 'notif-unread.json' : 'notif-empty.json' });
}).as('getNotif');
```

### Simulate delay / error

```ts
cy.intercept('GET', '/api/data', (req) => {
  req.reply({ statusCode: 500, body: 'Server Error', delay: 2000 });
});
```

## Custom Commands

Define in `cypress/support/commands.ts`:

```ts
declare global {
  namespace Cypress {
    interface Chainable {
      login(email: string, password: string): Chainable<void>;
      getByCy(selector: string): Chainable<JQuery<HTMLElement>>;
    }
  }
}

Cypress.Commands.add('login', (email, password) => {
  cy.session([email, password], () => {
    cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
      window.localStorage.setItem('token', resp.body.token);
    });
  });
});

Cypress.Commands.add('getByCy', (selector) => {
  return cy.get(`[data-cy=${selector}]`);
});
```

Usage:

```ts
cy.login('admin@test.com', 'password');
cy.visit('/dashboard');
cy.getByCy('user-menu').click();
```

Use `cy.session()` for login to cache and restore auth state across tests — dramatically speeds up suites.

## Component Testing

```tsx
// src/components/Counter.cy.tsx
import Counter from './Counter';

describe('Counter', () => {
  it('increments on click', () => {
    cy.mount(<Counter initial={0} />);
    cy.getByCy('count-display').should('have.text', '0');
    cy.getByCy('increment-btn').click();
    cy.getByCy('count-display').should('have.text', '1');
  });

  it('calls onChange prop', () => {
    const onChange = cy.stub().as('onChange');
    cy.mount(<Counter initial={5} onChange={onChange} />);
    cy.getByCy('increment-btn').click();
    cy.get('@onChange').should('have.been.calledWith', 6);
  });
});
```

Stub network requests in component tests the same way as E2E — use `cy.intercept()` before `cy.mount()`.

## Fixtures and Test Data

Store JSON fixtures in `cypress/fixtures/`:

```json
// cypress/fixtures/users.json
[
  { "id": 1, "name": "Alice", "role": "admin" },
  { "id": 2, "name": "Bob", "role": "user" }
]
```

Load in tests: `cy.fixture('users.json').then((users) => { ... })` or via `cy.intercept` with `{ fixture: 'users.json' }`.

## Environment Variables

```bash
# Command line
CYPRESS_API_URL=https://staging.api.com npx cypress run

# In cypress.config.ts
env: { apiUrl: 'http://localhost:4000' }

# In cypress.env.json (gitignored)
{ "API_KEY": "test-key-123" }
```

Access in tests: `Cypress.env('apiUrl')` or `Cypress.env('API_KEY')`.

## CI/CD Integration

### GitHub Actions

```yaml
name: Cypress CI
on: [push, pull_request]
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cypress-io/github-action@v7
        with:
          build: npm run build
          start: npm start
          wait-on: 'http://localhost:3000'
          browser: chrome
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-screenshots
          path: cypress/screenshots
```

### Parallel execution (Cypress Cloud)

```yaml
      - uses: cypress-io/github-action@v7
        with:
          record: true
          parallel: true
          group: 'e2e-chrome'
        env:
          CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
```

### GitLab CI

```yaml
cypress:
  image: cypress/browsers:latest
  stage: test
  script:
    - npm ci
    - npx cypress run --browser chrome
  artifacts:
    when: on_failure
    paths:
      - cypress/screenshots
      - cypress/videos
```

## Debugging

- `cy.pause()` — pause test execution, step through commands interactively
- `cy.debug()` — breakpoint that opens DevTools debugger
- `cy.log('message')` — print to Cypress command log
- `.then(console.log)` — inspect values in browser console
- Time-travel: click any command in the Cypress runner to inspect DOM snapshot at that point
- `DEBUG=cypress:* npx cypress run` — verbose internal logging

## Retry-ability and Flaky Test Prevention

Rules to follow:
1. Never use `cy.wait(ms)` for arbitrary delays — wait for assertions or aliases instead
2. Use `cy.intercept().as('alias')` + `cy.wait('@alias')` for network-dependent flows
3. Assert on visible state, not internal state: `.should('be.visible')`, `.should('not.exist')`
4. Each `it()` block must be independent — use `beforeEach` for setup, not shared mutable state
5. Configure `retries: { runMode: 2 }` in config to auto-retry failing tests in CI
6. Use `cy.session()` to cache auth state instead of logging in via UI every test
7. Stub external services with `cy.intercept` to eliminate network flakiness

## App Actions Pattern (Preferred over Page Objects)

Instead of Page Object classes, expose app-level actions via custom commands:

```ts
// Custom command approach (App Actions)
Cypress.Commands.add('createTodo', (title: string) => {
  cy.get('[data-cy=todo-input]').type(`${title}{enter}`);
});

// Test reads like user intent
cy.createTodo('Buy groceries');
cy.getByCy('todo-list').should('contain', 'Buy groceries');
```

Benefits over Page Objects: less indirection, better TypeScript support, leverages Cypress command chaining, no class instantiation boilerplate.

Use Page Objects only when managing highly complex multi-step wizards or pages with many stateful interactions.

## Configuration Reference

Key `cypress.config.ts` options:

| Option | Default | Purpose |
|---|---|---|
| `baseUrl` | null | Prefix for `cy.visit()` and `cy.request()` |
| `viewportWidth/Height` | 1000/660 | Browser viewport size |
| `defaultCommandTimeout` | 4000 | Timeout for DOM commands (ms) |
| `requestTimeout` | 5000 | Timeout for `cy.wait()` on routes |
| `responseTimeout` | 30000 | Timeout for server responses |
| `retries` | `{runMode:0,openMode:0}` | Auto-retry failed tests |
| `video` | false | Record video of runs (was `true` before Cypress 13) |
| `screenshotOnRunFailure` | true | Capture screenshot on failure |
| `experimentalMemoryManagement` | false | Reduce OOM in large suites |
| `testIsolation` | true | Clear state between tests |

## Plugins and Extensions

- **cypress-axe** — accessibility testing: `cy.injectAxe(); cy.checkA11y();`
- **@percy/cypress** — visual regression testing with Percy snapshots
- **cypress-real-events** — native browser events (hover, press)
- **cypress-file-upload** — file upload testing
- **@testing-library/cypress** — Testing Library queries in Cypress (`cy.findByRole()`)
- **cypress-grep** — filter tests by tag or title substring

## When to Choose Cypress vs Playwright

Choose **Cypress** when:
- Team is JavaScript/TypeScript-only and values fast onboarding
- Testing SPAs (React, Vue, Angular) with rich interactive UIs
- Need powerful network stubbing and time-travel debugging
- Existing Cypress test suite to maintain

Choose **Playwright** instead when:
- Need cross-browser coverage including Safari/WebKit
- Need multi-tab, multi-origin, or mobile device emulation
- Require free parallel execution without a cloud service
- Team uses Python, C#, or Java alongside JS

## References

In-depth guides in `references/`:

| Document | Topics |
|---|---|
| [advanced-patterns.md](references/advanced-patterns.md) | Custom commands with TypeScript, auth flows, iframes, cy.origin, file uploads/downloads, WebSockets, drag-and-drop, cy.session, retry-ability internals, shadow DOM, visual regression (Percy/Applitools) |
| [troubleshooting.md](references/troubleshooting.md) | Flaky tests, detached DOM elements, cy.intercept mismatches, CORS, iframe issues, memory leaks, slow tests, CI failures (Docker/headless), screenshot/video debugging, app state conflicts |
| [component-testing-guide.md](references/component-testing-guide.md) | Component testing setup for React/Vue/Angular/Svelte, mounting with providers, mocking props/stores/APIs, testing hooks, styled components, code coverage, Storybook comparison |

## Scripts

Executable helpers in `scripts/`:

| Script | Purpose |
|---|---|
| [setup-cypress-project.sh](scripts/setup-cypress-project.sh) | Bootstrap Cypress in an existing project — installs deps, creates config, scaffolds folders, adds TypeScript, creates first spec. Flags: `--component`, `--framework`, `--bundler` |
| [cypress-ci-setup.sh](scripts/cypress-ci-setup.sh) | Generate CI workflow for GitHub Actions, GitLab CI, or CircleCI with caching, parallelization, and artifact upload. Flags: `--provider`, `--parallel` |
| [cleanup-test-data.sh](scripts/cleanup-test-data.sh) | Remove screenshots, videos, coverage reports, and optionally reset test DB. Flags: `--all`, `--artifacts`, `--db`, `--cache`, `--dry-run` |

## Assets

Reusable templates in `assets/`:

| Asset | Description |
|---|---|
| [cypress.config.ts](assets/cypress.config.ts) | Production-ready config with retries, timeouts, env vars, memory management, code coverage hooks |
| [commands.ts](assets/commands.ts) | Custom commands: `getByCy`, `getByTestId`, `login`, `loginAs`, `apiRequest`, `waitForLoad`, `paste`, `shouldHaveCss` |
| [github-actions-cypress.yml](assets/github-actions-cypress.yml) | GitHub Actions workflow with parallel E2E (3 containers), component tests, caching, artifact upload, status check |
| [e2e-spec-template.cy.ts](assets/e2e-spec-template.cy.ts) | E2E spec template: auth setup, API stubbing, happy path, error handling, edge cases, retry patterns |
| [component-spec-template.cy.tsx](assets/component-spec-template.cy.tsx) | React component test template: rendering, callbacks, API interactions, a11y, responsive, visual snapshots |

<!-- tested: pass -->
