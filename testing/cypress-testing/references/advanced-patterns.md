# Advanced Cypress Patterns

## Table of Contents

- [Custom Commands vs Queries](#custom-commands-vs-queries)
- [Page Object Model](#page-object-model)
- [App Actions](#app-actions)
- [cy.intercept Advanced Usage](#cyintercept-advanced-usage)
  - [Dynamic Responses](#dynamic-responses)
  - [Response Delays](#response-delays)
  - [Error Simulation](#error-simulation)
  - [Conditional Intercepts](#conditional-intercepts)
- [cy.session for Auth](#cysession-for-auth)
- [Test Isolation](#test-isolation)
- [Clock and Timer Manipulation](#clock-and-timer-manipulation)
- [Shadow DOM Testing](#shadow-dom-testing)
- [Iframe Handling](#iframe-handling)
- [Multi-Domain Testing with cy.origin](#multi-domain-testing-with-cyorigin)
- [Cypress Component Testing Architecture](#cypress-component-testing-architecture)
  - [Mount Configuration](#mount-configuration)
  - [Provider Wrapping](#provider-wrapping)
  - [Stubbing Child Components](#stubbing-child-components)

---

## Custom Commands vs Queries

### Commands (`Cypress.Commands.add`)

Commands are the traditional extension mechanism. They execute once and return a chainable:

```ts
Cypress.Commands.add('login', (email: string, password: string) => {
  cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
    window.localStorage.setItem('token', resp.body.token);
  });
});

// Usage
cy.login('admin@test.com', 'pass123');
```

Commands do **not** retry. If the underlying assertion fails, Cypress does not re-run the command body.

### Queries (`Cypress.Commands.addQuery`) — Cypress 12+

Queries are retry-able. Cypress re-invokes the returned function on each retry tick until the downstream assertion passes or the timeout expires:

```ts
Cypress.Commands.addQuery('getByDataCy', (selector: string) => {
  const getFn = cy.now('get', `[data-cy="${selector}"]`) as () => JQuery;
  return (subject?: JQuery) => {
    const el = getFn();
    // Optional: filter within subject
    return subject ? subject.find(`[data-cy="${selector}"]`) : el;
  };
});

// Usage — retries until element appears and is visible
cy.getByDataCy('submit-btn').should('be.visible');
```

### When to Use Which

| Use Case | Command | Query |
|----------|---------|-------|
| Side effects (API calls, localStorage) | ✅ | ❌ |
| DOM lookups that should retry | ❌ | ✅ |
| Wrapping `cy.get` / `cy.contains` | ❌ | ✅ |
| Multi-step setup (seed data, navigate) | ✅ | ❌ |
| Chained after another query | ❌ | ✅ |

### Overwriting Built-in Commands

```ts
Cypress.Commands.overwrite('type', (originalFn, element, text, options) => {
  // Log the typed text for debugging
  Cypress.log({ name: 'type', message: text });
  return originalFn(element, text, options);
});
```

---

## Page Object Model

Page objects encapsulate selectors and actions for a page or component:

```ts
// cypress/pages/LoginPage.ts
export class LoginPage {
  // Selectors as getters — always fresh references
  get emailInput() { return cy.get('[data-cy="email"]'); }
  get passwordInput() { return cy.get('[data-cy="password"]'); }
  get submitButton() { return cy.get('[data-cy="submit"]'); }
  get errorMessage() { return cy.get('[data-cy="error-message"]'); }

  visit() {
    cy.visit('/login');
    return this;
  }

  fillEmail(email: string) {
    this.emailInput.clear().type(email);
    return this;
  }

  fillPassword(password: string) {
    this.passwordInput.clear().type(password);
    return this;
  }

  submit() {
    this.submitButton.click();
    return this;
  }

  login(email: string, password: string) {
    this.fillEmail(email).fillPassword(password).submit();
    return this;
  }

  assertError(message: string) {
    this.errorMessage.should('contain', message);
    return this;
  }
}
```

```ts
// cypress/e2e/login.cy.ts
import { LoginPage } from '../pages/LoginPage';

const loginPage = new LoginPage();

describe('Login', () => {
  beforeEach(() => loginPage.visit());

  it('logs in successfully', () => {
    loginPage.login('user@test.com', 'password');
    cy.url().should('include', '/dashboard');
  });

  it('shows error for invalid credentials', () => {
    loginPage.login('bad@test.com', 'wrong');
    loginPage.assertError('Invalid credentials');
  });
});
```

### Page Object Guidelines

- Return `this` from action methods for chaining.
- Use getters (not stored references) to avoid stale element issues.
- Keep assertions in the test, not the page object (except assertion helpers like `assertError`).
- Compose page objects for shared components (e.g., `NavBar` used across pages).

---

## App Actions

App actions bypass the UI to set application state directly, making tests faster and more reliable:

```ts
// In your app's entry point (e.g., main.tsx)
if (window.Cypress) {
  window.appActions = {
    setUser: (user) => store.dispatch(setUser(user)),
    resetState: () => store.dispatch(resetAll()),
    getState: () => store.getState(),
    seedDatabase: async (data) => {
      await fetch('/api/test/seed', {
        method: 'POST',
        body: JSON.stringify(data),
      });
    },
  };
}
```

```ts
// cypress/support/commands.ts
Cypress.Commands.add('appAction', (action: string, ...args: any[]) => {
  return cy.window().then((win) => {
    return (win as any).appActions[action](...args);
  });
});

// Usage in test
it('shows user profile after login', () => {
  cy.appAction('setUser', { id: 1, name: 'Alice', role: 'admin' });
  cy.visit('/profile');
  cy.get('[data-cy="user-name"]').should('contain', 'Alice');
});
```

### App Actions vs cy.request vs UI

| Approach | Speed | Reliability | Realism |
|----------|-------|-------------|---------|
| UI interaction | Slow | Flaky | High |
| `cy.request` (API) | Fast | Reliable | Medium |
| App actions (direct state) | Fastest | Most reliable | Low |

Use app actions for test setup; reserve UI interaction for the actual behavior under test.

---

## cy.intercept Advanced Usage

### Dynamic Responses

Return different responses based on request content:

```ts
let callCount = 0;

cy.intercept('GET', '/api/status', (req) => {
  callCount++;
  if (callCount === 1) {
    req.reply({ status: 'pending' });
  } else {
    req.reply({ status: 'complete' });
  }
}).as('getStatus');
```

Respond based on request body:

```ts
cy.intercept('POST', '/api/search', (req) => {
  const { query } = req.body;
  if (query === 'empty') {
    req.reply({ results: [], total: 0 });
  } else {
    req.reply({ fixture: `search-${query}.json` });
  }
}).as('search');
```

### Response Delays

Simulate slow networks to test loading states:

```ts
cy.intercept('GET', '/api/data', (req) => {
  req.reply({
    statusCode: 200,
    body: { items: [1, 2, 3] },
    delay: 3000, // 3 second delay
  });
}).as('slowData');

cy.visit('/dashboard');
cy.get('[data-cy="loading-spinner"]').should('be.visible');
cy.wait('@slowData');
cy.get('[data-cy="loading-spinner"]').should('not.exist');
cy.get('[data-cy="data-list"]').should('have.length', 3);
```

### Error Simulation

Test error handling with various failure modes:

```ts
// HTTP errors
cy.intercept('GET', '/api/resource', {
  statusCode: 500,
  body: { error: 'Internal Server Error' },
}).as('serverError');

// Network failures
cy.intercept('GET', '/api/resource', { forceNetworkError: true }).as('networkError');

// Timeout simulation
cy.intercept('GET', '/api/resource', (req) => {
  req.destroy(); // aborts the request
}).as('timeout');

// Rate limiting
cy.intercept('POST', '/api/submit', {
  statusCode: 429,
  body: { error: 'Too Many Requests' },
  headers: { 'Retry-After': '60' },
}).as('rateLimited');
```

### Conditional Intercepts

Intercept based on query parameters, headers, or body:

```ts
// Match by query params
cy.intercept({
  method: 'GET',
  url: '/api/users',
  query: { role: 'admin' },
}, { fixture: 'admin-users.json' }).as('getAdmins');

// Match by headers
cy.intercept({
  method: 'GET',
  url: '/api/data',
  headers: { 'Accept-Language': 'fr' },
}, { fixture: 'data-fr.json' }).as('frenchData');

// Modify response on the fly
cy.intercept('GET', '/api/feature-flags', (req) => {
  req.continue((res) => {
    res.body.newFeature = true; // override a flag
    res.send();
  });
}).as('featureFlags');
```

---

## cy.session for Auth

`cy.session` caches and restores browser state (cookies, localStorage, sessionStorage) across tests:

```ts
Cypress.Commands.add('loginViaUI', (email: string, password: string) => {
  cy.session(
    // Unique cache key
    ['loginViaUI', email],
    // Setup: runs only on first call or cache miss
    () => {
      cy.visit('/login');
      cy.get('[data-cy="email"]').type(email);
      cy.get('[data-cy="password"]').type(password);
      cy.get('[data-cy="submit"]').click();
      cy.url().should('include', '/dashboard');
    },
    // Options
    {
      // Validate: re-runs on cache hit to ensure session is still valid
      validate() {
        cy.request('/api/auth/me').its('status').should('eq', 200);
      },
      // Cache across specs (Cypress 12.4+)
      cacheAcrossSpecs: true,
    }
  );
});
```

### Session Strategies

```ts
// API-based session (fastest)
Cypress.Commands.add('loginByApi', (email: string, password: string) => {
  cy.session(['api', email], () => {
    cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
      window.localStorage.setItem('token', resp.body.token);
    });
  });
});

// OAuth/SSO mock session
Cypress.Commands.add('loginByOAuth', (provider: string) => {
  cy.session(['oauth', provider], () => {
    cy.request({
      method: 'POST',
      url: '/api/test/create-session',
      body: { provider, userId: 'test-user-1' },
    }).then((resp) => {
      // Set the session cookie directly
      cy.setCookie('session', resp.body.sessionId);
    });
  });
});
```

---

## Test Isolation

Cypress 12+ enables `testIsolation: true` by default: each `it()` starts with a blank page (`about:blank`), cleared cookies, localStorage, and sessionStorage.

```ts
// cypress.config.ts
export default defineConfig({
  e2e: {
    testIsolation: true, // default
  },
});

// Per-suite override (use sparingly)
describe('Dashboard', { testIsolation: false }, () => {
  it('loads page', () => { cy.visit('/dashboard'); });
  it('shows sidebar', () => {
    // page from previous test is still loaded
    cy.get('[data-cy="sidebar"]').should('be.visible');
  });
});
```

### Isolation Best Practices

- Keep `testIsolation: true` in all new projects.
- Never share state between `it()` blocks via variables — use `beforeEach` to set up.
- Use `cy.session()` to avoid repeating expensive auth flows with isolation on.
- If disabling isolation for speed, accept the risk of order-dependent failures.

---

## Clock and Timer Manipulation

Control `Date`, `setTimeout`, `setInterval`, and `requestAnimationFrame`:

```ts
// Freeze time
it('displays correct date', () => {
  const now = new Date(2024, 0, 15, 10, 30); // Jan 15, 2024 10:30
  cy.clock(now.getTime());
  cy.visit('/dashboard');
  cy.get('[data-cy="date"]').should('contain', 'January 15, 2024');
});

// Fast-forward timers
it('shows timeout warning after 5 minutes', () => {
  cy.clock();
  cy.visit('/app');
  cy.tick(5 * 60 * 1000); // advance 5 minutes
  cy.get('[data-cy="timeout-warning"]').should('be.visible');
});

// Selective clock control
it('freezes Date but not setTimeout', () => {
  cy.clock(Date.now(), ['Date']); // only mock Date, leave timers intact
  cy.visit('/app');
});

// Restore clock mid-test
it('restores real timers', () => {
  cy.clock();
  cy.visit('/app');
  cy.tick(1000);
  cy.clock().then((clock) => clock.restore());
  // Real timers resume
});
```

### Animation Testing with Clock

```ts
it('completes progress animation', () => {
  cy.clock();
  cy.visit('/upload');
  cy.get('[data-cy="upload-btn"]').click();

  // Advance through animation frames
  for (let i = 0; i <= 100; i += 10) {
    cy.tick(100);
    cy.get('[data-cy="progress"]').should('have.attr', 'aria-valuenow', String(i));
  }
});
```

---

## Shadow DOM Testing

Cypress can pierce shadow DOM boundaries with `includeShadowDom`:

```ts
// Global config
export default defineConfig({
  e2e: {
    includeShadowDom: true, // applies to all cy.get/cy.find
  },
});

// Per-command
cy.get('my-web-component').shadow().find('.internal-button').click();

// With includeShadowDom on, no .shadow() needed:
cy.get('my-web-component .internal-button').click();
```

### Nested Shadow DOM

```ts
// Multiple levels of shadow DOM
cy.get('outer-component')
  .shadow()
  .find('inner-component')
  .shadow()
  .find('button.action')
  .click();
```

### Shadow DOM with Custom Queries

```ts
Cypress.Commands.addQuery('shadowGet', (hostSelector: string, innerSelector: string) => {
  return () => {
    const host = Cypress.$(hostSelector);
    if (!host.length || !host[0].shadowRoot) {
      throw new Error(`Shadow host not found: ${hostSelector}`);
    }
    return Cypress.$(host[0].shadowRoot.querySelectorAll(innerSelector));
  };
});

// Usage
cy.shadowGet('my-dropdown', '.option-item').should('have.length', 5);
```

---

## Iframe Handling

### Basic Iframe Access

```ts
Cypress.Commands.add('getIframeBody', (iframeSelector: string) => {
  return cy
    .get(iframeSelector)
    .its('0.contentDocument.body')
    .should('not.be.empty')
    .then(cy.wrap);
});

// Usage
cy.getIframeBody('[data-cy="editor-iframe"]')
  .find('[data-cy="toolbar"]')
  .should('be.visible');
```

### Waiting for Iframe Load

```ts
Cypress.Commands.add('waitForIframe', (selector: string) => {
  return cy
    .get(selector)
    .should(($iframe) => {
      const body = $iframe[0]?.contentDocument?.body;
      expect(body).to.not.be.undefined;
      expect(body?.children.length).to.be.greaterThan(0);
    })
    .its('0.contentDocument.body')
    .then(cy.wrap);
});
```

### Cross-Origin Iframes

Cross-origin iframes cannot be accessed directly due to browser security. Options:
1. Use `cy.origin()` for multi-domain flows.
2. Mock the iframe content with `cy.intercept`.
3. Test the iframe content in a separate spec against its own URL.

---

## Multi-Domain Testing with cy.origin

`cy.origin` (Cypress 12+) allows interacting with pages on different domains:

```ts
it('completes OAuth login flow', () => {
  cy.visit('/login');
  cy.get('[data-cy="oauth-login"]').click();

  // Redirected to auth provider
  cy.origin('https://auth.provider.com', () => {
    cy.get('#username').type('testuser');
    cy.get('#password').type('testpass');
    cy.get('#login-btn').click();
  });

  // Back on original domain
  cy.url().should('include', '/dashboard');
  cy.get('[data-cy="user-name"]').should('contain', 'testuser');
});
```

### Passing Data to cy.origin

```ts
const credentials = { user: 'admin', pass: 'secret' };

cy.origin('https://sso.example.com', { args: credentials }, ({ user, pass }) => {
  cy.get('#email').type(user);
  cy.get('#password').type(pass);
  cy.get('#submit').click();
});
```

### Limitations of cy.origin

- Cannot share Cypress aliases across `cy.origin` blocks.
- Custom commands defined outside the block are not available inside — re-import or redefine them.
- `cy.intercept` routes defined outside do not apply inside `cy.origin`.
- The callback is serialized; closures over outer variables won't work (use `args`).

---

## Cypress Component Testing Architecture

### Mount Configuration

Create a custom `mount` that wraps components with required providers:

```tsx
// cypress/support/component.tsx
import { mount } from 'cypress/react18';
import { BrowserRouter } from 'react-router-dom';
import { ThemeProvider } from '@mui/material';
import { QueryClientProvider, QueryClient } from '@tanstack/react-query';
import theme from '../../src/theme';

type MountOptions = Parameters<typeof mount>[1] & {
  routerProps?: { initialEntries?: string[] };
  queryClient?: QueryClient;
};

function customMount(component: React.ReactNode, options?: MountOptions) {
  const { routerProps, queryClient, ...mountOptions } = options || {};
  const client = queryClient || new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });

  const wrapped = (
    <QueryClientProvider client={client}>
      <ThemeProvider theme={theme}>
        <BrowserRouter {...routerProps}>
          {component}
        </BrowserRouter>
      </ThemeProvider>
    </QueryClientProvider>
  );

  return mount(wrapped, mountOptions);
}

Cypress.Commands.add('mount', customMount);
```

### Provider Wrapping

```tsx
// Test with custom providers
it('renders with Redux store', () => {
  const store = configureStore({
    reducer: rootReducer,
    preloadedState: { user: { name: 'Alice', role: 'admin' } },
  });

  cy.mount(
    <Provider store={store}>
      <UserProfile />
    </Provider>
  );

  cy.get('[data-cy="user-name"]').should('contain', 'Alice');
});
```

### Stubbing Child Components

```tsx
// Stub expensive/external child components
it('renders without map component', () => {
  // Intercept the Map component import
  cy.stub(MapModule, 'MapView').returns(<div data-cy="map-stub">Map Stub</div>);

  cy.mount(<LocationPicker />);
  cy.get('[data-cy="map-stub"]').should('exist');
  cy.get('[data-cy="location-input"]').type('New York');
});
```

### Component Testing vs E2E Testing

| Aspect | Component Test | E2E Test |
|--------|---------------|----------|
| Scope | Single component | Full app flow |
| Speed | ~50ms per test | ~2-10s per test |
| Network | Stubbed | Real or intercepted |
| Routing | Mocked/wrapped | Real |
| State | Direct injection | Via UI/API |
| Best for | UI logic, visual states | User journeys, integration |

Use component tests for thorough coverage of component states (loading, error, empty, full). Use E2E tests for critical user paths.
