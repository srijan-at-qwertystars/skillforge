# Advanced Cypress Testing Patterns

A deep-dive reference for experienced developers covering custom commands, authentication flows, iframes, multi-domain testing, file handling, WebSockets, drag-and-drop, session management, retry internals, Shadow DOM, and visual regression.

---

## Table of Contents

1. [Custom Commands with TypeScript](#1-custom-commands-with-typescript)
   - [Type Declarations](#type-declarations)
   - [Generic Commands](#generic-commands)
   - [Command Overloading](#command-overloading)
   - [Chaining Custom Commands](#chaining-custom-commands)
   - [Dual Commands (Parent/Child)](#dual-commands-parentchild)
   - [Organizing Commands into Separate Files](#organizing-commands-into-separate-files)
2. [Testing Auth Flows](#2-testing-auth-flows)
   - [Login Once per Spec with cy.session()](#login-once-per-spec-with-cysession)
   - [Token-Based Auth](#token-based-auth)
   - [Cookie-Based Auth](#cookie-based-auth)
   - [OAuth Mocking](#oauth-mocking)
   - [Role-Based Testing](#role-based-testing)
   - [Preserving Auth Across Specs](#preserving-auth-across-specs)
3. [Handling Iframes](#3-handling-iframes)
   - [Accessing Iframe Content](#accessing-iframe-content)
   - [Cross-Origin Iframes](#cross-origin-iframes)
   - [Iframe Utilities](#iframe-utilities)
   - [Common Pitfalls](#common-pitfalls)
4. [Multi-Domain Testing (cy.origin)](#4-multi-domain-testing-cyorigin)
   - [cy.origin() Usage](#cyorigin-usage)
   - [Passing Data Between Origins](#passing-data-between-origins)
   - [SSO Flows](#sso-flows)
   - [OAuth Redirect Testing](#oauth-redirect-testing)
5. [File Uploads/Downloads](#5-file-uploadsdownloads)
   - [cy.selectFile()](#cyselectfile)
   - [Fixture-Based Uploads](#fixture-based-uploads)
   - [Drag-and-Drop File Upload](#drag-and-drop-file-upload)
   - [Verifying Downloaded Files](#verifying-downloaded-files)
   - [Reading Downloaded Content](#reading-downloaded-content)
6. [Testing WebSockets](#6-testing-websockets)
   - [Intercepting WebSocket Connections](#intercepting-websocket-connections)
   - [Testing Real-Time Updates](#testing-real-time-updates)
   - [Mocking Socket.IO](#mocking-socketio)
   - [Testing Reconnection](#testing-reconnection)
7. [Testing Drag-and-Drop](#7-testing-drag-and-drop)
   - [Using cypress-real-events](#using-cypress-real-events)
   - [HTML5 Drag and Drop](#html5-drag-and-drop)
   - [Sortable Lists](#sortable-lists)
   - [Kanban Boards](#kanban-boards)
8. [Session Management (cy.session)](#8-session-management-cysession)
   - [Caching Login State](#caching-login-state)
   - [Session Validation](#session-validation)
   - [Session Recreation](#session-recreation)
   - [Multi-User Testing](#multi-user-testing)
9. [Retry-ability Internals](#9-retry-ability-internals)
   - [How Cypress Retries Work](#how-cypress-retries-work)
   - [Which Commands Retry](#which-commands-retry)
   - [Custom Retry Logic](#custom-retry-logic)
   - [Retry vs Timeout](#retry-vs-timeout)
   - [.should() Retry Behavior](#should-retry-behavior)
10. [Testing Shadow DOM](#10-testing-shadow-dom)
    - [includeShadowDom Config](#includeshadowdom-config)
    - [cy.shadow()](#cyshadow)
    - [Targeting Shadow Elements](#targeting-shadow-elements)
    - [Web Component Testing](#web-component-testing)
11. [Visual Regression](#11-visual-regression)
    - [Percy Integration](#percy-integration)
    - [Applitools Eyes](#applitools-eyes)
    - [Screenshot Comparison](#screenshot-comparison)
    - [Responsive Visual Testing](#responsive-visual-testing)

---

## 1. Custom Commands with TypeScript

### Type Declarations

Extend the `Cypress.Chainable` interface so custom commands are recognized by TypeScript. Place declarations in `cypress/support/index.d.ts` or a dedicated `commands.d.ts`:

```typescript
// cypress/support/index.d.ts
declare namespace Cypress {
  interface Chainable<Subject = any> {
    /** Log in via API and cache the session */
    login(email: string, password: string): Chainable<void>;

    /** Select a date from a custom datepicker component */
    pickDate(selector: string, date: Date): Chainable<JQuery<HTMLElement>>;

    /** Retrieve an item from localStorage, yielding the parsed value */
    getLocalStorage<T = unknown>(key: string): Chainable<T>;
  }
}
```

Implement the commands in `cypress/support/commands.ts`:

```typescript
Cypress.Commands.add('login', (email: string, password: string) => {
  cy.session([email, password], () => {
    cy.request({
      method: 'POST',
      url: '/api/auth/login',
      body: { email, password },
    }).then((resp) => {
      window.localStorage.setItem('authToken', resp.body.token);
    });
  });
});

Cypress.Commands.add('pickDate', (selector: string, date: Date) => {
  const formatted = date.toISOString().split('T')[0];
  cy.get(selector).clear().type(formatted);
});

Cypress.Commands.add('getLocalStorage', <T>(key: string) => {
  cy.window().then((win) => {
    const raw = win.localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : undefined;
  });
});
```

### Generic Commands

Use generics when commands return different types depending on usage:

```typescript
// Declaration
declare namespace Cypress {
  interface Chainable<Subject = any> {
    apiGet<T>(endpoint: string): Chainable<T>;
    apiPost<TReq, TRes>(endpoint: string, body: TReq): Chainable<TRes>;
  }
}

// Implementation
Cypress.Commands.add('apiGet', <T>(endpoint: string) => {
  return cy.request<T>({ method: 'GET', url: `/api${endpoint}` })
    .then((resp) => resp.body);
});

Cypress.Commands.add('apiPost', <TReq, TRes>(endpoint: string, body: TReq) => {
  return cy.request<TRes>({ method: 'POST', url: `/api${endpoint}`, body })
    .then((resp) => resp.body);
});

// Usage
interface User { id: number; name: string; email: string; }
cy.apiGet<User>('/users/1').then((user) => {
  expect(user.name).to.eq('Alice');
});
```

### Command Overloading

Overloaded declarations let a single command accept different argument signatures:

```typescript
declare namespace Cypress {
  interface Chainable<Subject = any> {
    dataCy(selector: string): Chainable<JQuery<HTMLElement>>;
    dataCy(selector: string, options: Partial<Cypress.Loggable & Cypress.Timeoutable>): Chainable<JQuery<HTMLElement>>;
  }
}

Cypress.Commands.add('dataCy', (selector: string, options?: Partial<Cypress.Loggable & Cypress.Timeoutable>) => {
  return cy.get(`[data-cy="${selector}"]`, options);
});

// Both valid calls
cy.dataCy('submit-btn');
cy.dataCy('submit-btn', { timeout: 10000 });
```

### Chaining Custom Commands

Custom commands automatically chain because they return `Chainable`. Build composable pipelines:

```typescript
declare namespace Cypress {
  interface Chainable<Subject = any> {
    findByLabel(label: string): Chainable<JQuery<HTMLElement>>;
    clearAndType(text: string): Chainable<JQuery<HTMLElement>>;
  }
}

Cypress.Commands.add('findByLabel', (label: string) => {
  return cy.contains('label', label)
    .invoke('attr', 'for')
    .then((id) => cy.get(`#${id}`));
});

Cypress.Commands.add(
  'clearAndType',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, text: string) => {
    cy.wrap(subject).clear().type(text);
  }
);

// Chained usage
cy.findByLabel('Email').clearAndType('user@example.com');
cy.findByLabel('Password').clearAndType('s3cureP@ss');
```

### Dual Commands (Parent/Child)

A dual command works both as a parent command (no prior subject) and a child command (chained off a subject):

```typescript
declare namespace Cypress {
  interface Chainable<Subject = any> {
    highlight(): Chainable<JQuery<HTMLElement>>;
  }
}

Cypress.Commands.add(
  'highlight',
  { prevSubject: 'optional' },
  (subject?: JQuery<HTMLElement>) => {
    const el = subject ? cy.wrap(subject) : cy.get('body');
    el.then(($el) => {
      $el.css('outline', '3px solid red');
    });
    return el;
  }
);

// As parent — highlights body
cy.highlight();
// As child — highlights the matched element
cy.get('.card').highlight();
```

### Organizing Commands into Separate Files

Split commands by domain to keep each file small and discoverable:

```
cypress/support/
├── commands/
│   ├── auth.commands.ts      // login, logout, switchUser
│   ├── api.commands.ts       // apiGet, apiPost, apiDelete
│   ├── form.commands.ts      // fillForm, clearAndType, findByLabel
│   └── navigation.commands.ts
├── commands.ts               // barrel import
├── e2e.ts
└── index.d.ts                // all type declarations
```

```typescript
// cypress/support/commands.ts — barrel file
import './commands/auth.commands';
import './commands/api.commands';
import './commands/form.commands';
import './commands/navigation.commands';

// cypress/support/e2e.ts
import './commands';
```

---

## 2. Testing Auth Flows

### Login Once per Spec with cy.session()

`cy.session()` caches cookies, localStorage, and sessionStorage so you do not repeat login across tests:

```typescript
function loginViaUI(username: string, password: string) {
  cy.visit('/login');
  cy.get('[data-cy=email]').type(username);
  cy.get('[data-cy=password]').type(password);
  cy.get('[data-cy=submit]').click();
  cy.url().should('include', '/dashboard');
}

beforeEach(() => {
  cy.session('admin-session', () => {
    loginViaUI('admin@app.com', 'admin123');
  });
  cy.visit('/dashboard');
});
```

### Token-Based Auth

Bypass the UI entirely by hitting the login API and stashing the JWT:

```typescript
Cypress.Commands.add('loginByApi', (email: string, password: string) => {
  cy.session(['api', email], () => {
    cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
      const { accessToken, refreshToken } = resp.body;
      window.localStorage.setItem('access_token', accessToken);
      window.localStorage.setItem('refresh_token', refreshToken);
    });
  });
});

// Inject the token into all subsequent requests
beforeEach(() => {
  cy.loginByApi('user@example.com', 'password');
  cy.intercept('**/api/**', (req) => {
    const token = localStorage.getItem('access_token');
    if (token) {
      req.headers['Authorization'] = `Bearer ${token}`;
    }
  });
});
```

### Cookie-Based Auth

When the server sets an HttpOnly cookie you cannot manipulate via JS. Use `cy.request` which automatically stores response cookies:

```typescript
Cypress.Commands.add('loginByCookie', (email: string, password: string) => {
  cy.session(['cookie', email], () => {
    cy.request({
      method: 'POST',
      url: '/api/auth/login',
      body: { email, password },
      // cy.request automatically follows Set-Cookie headers
    });
  }, {
    validate() {
      cy.request('/api/auth/me').its('status').should('eq', 200);
    },
  });
});
```

### OAuth Mocking

Intercept the OAuth redirect to avoid hitting a real provider:

```typescript
it('logs in via mocked Google OAuth', () => {
  // Intercept the redirect to Google
  cy.intercept('GET', '/api/auth/google', (req) => {
    req.redirect('/api/auth/google/callback?code=mock-auth-code', 302);
  }).as('oauthRedirect');

  // Intercept the callback to supply a fake token
  cy.intercept('GET', '/api/auth/google/callback*', (req) => {
    req.reply({
      statusCode: 302,
      headers: {
        'Set-Cookie': 'session=mock-session-id; Path=/; HttpOnly',
        Location: '/dashboard',
      },
    });
  }).as('oauthCallback');

  cy.visit('/login');
  cy.get('[data-cy=google-login]').click();
  cy.url().should('include', '/dashboard');
});
```

### Role-Based Testing

Abstract roles behind a factory so tests are self-documenting:

```typescript
type Role = 'admin' | 'editor' | 'viewer';

const credentials: Record<Role, { email: string; password: string }> = {
  admin:  { email: 'admin@app.com',  password: 'admin123'  },
  editor: { email: 'editor@app.com', password: 'editor123' },
  viewer: { email: 'viewer@app.com', password: 'viewer123' },
};

Cypress.Commands.add('loginAs', (role: Role) => {
  const { email, password } = credentials[role];
  cy.session(role, () => {
    cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
      window.localStorage.setItem('access_token', resp.body.token);
    });
  });
});

// Usage
it('admin sees the settings page', () => {
  cy.loginAs('admin');
  cy.visit('/settings');
  cy.get('[data-cy=danger-zone]').should('exist');
});

it('viewer cannot see settings', () => {
  cy.loginAs('viewer');
  cy.visit('/settings');
  cy.url().should('include', '/403');
});
```

### Preserving Auth Across Specs

`cy.session()` caches within a single spec file by default. To share across spec files, keep the session ID deterministic and use `cacheAcrossSpecs`:

```typescript
Cypress.Commands.add('loginAs', (role: Role) => {
  cy.session(role, () => {
    cy.request('POST', '/api/auth/login', {
      email: credentials[role].email,
      password: credentials[role].password,
    }).then((resp) => {
      window.localStorage.setItem('access_token', resp.body.token);
    });
  }, {
    cacheAcrossSpecs: true,
    validate() {
      cy.request({ url: '/api/auth/me', failOnStatusCode: false })
        .its('status').should('eq', 200);
    },
  });
});
```

---

## 3. Handling Iframes

### Accessing Iframe Content

Cypress does not natively traverse into iframes. Use `.its('0.contentDocument.body')` to get the body:

```typescript
cy.get('iframe#payment-frame')
  .its('0.contentDocument.body')
  .should('not.be.empty')
  .then(cy.wrap)
  .find('#card-number')
  .type('4242424242424242');
```

### Cross-Origin Iframes

For cross-origin iframes, set `chromeWebSecurity: false` in `cypress.config.ts` and use `cy.origin()`:

```typescript
// cypress.config.ts
export default defineConfig({
  e2e: {
    chromeWebSecurity: false,
  },
});

// In a test
cy.get('iframe[src*="payments.stripe.com"]')
  .its('0.contentDocument.body')
  .should('not.be.empty')
  .then(cy.wrap)
  .within(() => {
    cy.get('[name="cardnumber"]').type('4242424242424242');
    cy.get('[name="exp-date"]').type('12/30');
    cy.get('[name="cvc"]').type('123');
  });
```

### Iframe Utilities

Create a reusable command to simplify iframe access:

```typescript
declare namespace Cypress {
  interface Chainable<Subject = any> {
    iframe(selector: string): Chainable<JQuery<HTMLBodyElement>>;
  }
}

Cypress.Commands.add('iframe', (selector: string) => {
  return cy.get(selector, { timeout: 10000 })
    .should(($iframe) => {
      const body = $iframe[0]?.contentDocument?.body;
      expect(body).to.not.be.undefined;
      expect(Cypress.$(body!).children()).to.have.length.greaterThan(0);
    })
    .then(($iframe) => {
      return cy.wrap($iframe[0].contentDocument!.body as HTMLBodyElement);
    });
});

// Usage
cy.iframe('#editor-frame').find('.ProseMirror').type('Hello, world!');
```

### Common Pitfalls

```typescript
// ❌ BAD — accessing the iframe before it loads
cy.get('iframe').then(($iframe) => {
  // contentDocument may be null if the iframe hasn't loaded
  cy.wrap($iframe[0].contentDocument.body); // throws
});

// ✅ GOOD — wait for a meaningful assertion on the body
cy.get('iframe')
  .its('0.contentDocument.body', { timeout: 15000 })
  .should('not.be.empty')
  .then(cy.wrap);

// ❌ BAD — cy.within() does not scope into iframes
cy.get('iframe').within(() => {
  cy.get('#inner-element'); // searches the iframe *element* attributes, not its content
});

// ✅ GOOD — get the body first, then use within
cy.iframe('#my-iframe').within(() => {
  cy.get('#inner-element').should('be.visible');
});
```

---

## 4. Multi-Domain Testing (cy.origin)

### cy.origin() Usage

`cy.origin()` lets you run commands against a secondary origin. Cypress sandboxes each origin so you can interact with pages on different domains:

```typescript
it('visits an external page and returns', () => {
  cy.visit('/');

  // Navigate to the external domain
  cy.get('a[href*="external-site.com"]').click();

  cy.origin('https://external-site.com', () => {
    cy.url().should('include', 'external-site.com');
    cy.get('h1').should('contain', 'Welcome');
    cy.get('[data-cy=accept]').click();
  });

  // Back on the original origin
  cy.url().should('include', Cypress.config('baseUrl')!);
});
```

### Passing Data Between Origins

Use the `args` option to pass serializable data into the `cy.origin()` callback. You cannot reference outer closures:

```typescript
const userData = { email: 'test@example.com', code: 'ABC123' };

cy.origin('https://auth.provider.com', { args: userData }, ({ email, code }) => {
  cy.get('#email').type(email);
  cy.get('#verification-code').type(code);
  cy.get('#submit').click();
});
```

### SSO Flows

Test a SAML/OIDC SSO redirect that goes through an identity provider:

```typescript
it('completes SSO login via IdP', () => {
  cy.visit('/login');
  cy.get('[data-cy=sso-login]').click();

  // Redirected to IdP
  cy.origin('https://idp.corporate.com', { args: { user: 'sso-user@corp.com', pass: 'sso-pass' } },
    ({ user, pass }) => {
      cy.get('#username').type(user);
      cy.get('#password').type(pass);
      cy.get('#sign-in').click();
      // IdP may show a consent screen
      cy.get('#consent-allow').click();
    }
  );

  // Redirected back to app
  cy.url().should('include', '/dashboard');
  cy.get('[data-cy=user-menu]').should('contain', 'sso-user@corp.com');
});
```

### OAuth Redirect Testing

Handle a full OAuth code-grant flow across two origins:

```typescript
it('completes GitHub OAuth flow', () => {
  cy.visit('/login');
  cy.get('[data-cy=github-login]').click();

  cy.origin('https://github.com', { args: { ghUser: Cypress.env('GH_USER'), ghPass: Cypress.env('GH_PASS') } },
    ({ ghUser, ghPass }) => {
      cy.get('#login_field').type(ghUser);
      cy.get('#password').type(ghPass);
      cy.get('[name="commit"]').click();

      // Authorize the OAuth app if prompted
      cy.get('body').then(($body) => {
        if ($body.find('#js-oauth-authorize-btn').length) {
          cy.get('#js-oauth-authorize-btn').click();
        }
      });
    }
  );

  // Back on our app after the redirect
  cy.url().should('include', '/dashboard');
  cy.getCookie('session').should('exist');
});
```

---

## 5. File Uploads/Downloads

### cy.selectFile()

The built-in `cy.selectFile()` (Cypress 9.3+) attaches files to `<input type="file">` elements:

```typescript
cy.get('input[type="file"]').selectFile('cypress/fixtures/report.pdf');

// Multiple files
cy.get('input[type="file"][multiple]').selectFile([
  'cypress/fixtures/photo1.jpg',
  'cypress/fixtures/photo2.jpg',
]);

// From a Cypress.Buffer
cy.readFile('cypress/fixtures/data.csv', null).then((buffer: Buffer) => {
  cy.get('input[type="file"]').selectFile({
    contents: buffer,
    fileName: 'upload.csv',
    mimeType: 'text/csv',
    lastModified: Date.now(),
  });
});
```

### Fixture-Based Uploads

Load fixture data and construct a `File` object to upload:

```typescript
cy.fixture('sample-image.png', 'base64').then((fileContent) => {
  const blob = Cypress.Blob.base64StringToBlob(fileContent, 'image/png');
  const testFile = new File([blob], 'sample-image.png', { type: 'image/png' });

  cy.get('input[type="file"]').selectFile({
    contents: testFile,
    fileName: 'sample-image.png',
  });
});
```

### Drag-and-Drop File Upload

For drop-zone components that do not use a visible `<input type="file">`:

```typescript
cy.get('[data-cy=dropzone]').selectFile('cypress/fixtures/document.pdf', {
  action: 'drag-drop',
});

// Verify upload progress / completion
cy.get('[data-cy=upload-status]').should('contain', 'document.pdf');
cy.get('[data-cy=upload-progress]').should('contain', '100%');
```

### Verifying Downloaded Files

Configure a known download folder and assert files arrive:

```typescript
// cypress.config.ts
import { defineConfig } from 'cypress';
import path from 'path';
import fs from 'fs';

export default defineConfig({
  e2e: {
    setupNodeEvents(on, config) {
      on('task', {
        fileExists(filePath: string) {
          return fs.existsSync(filePath);
        },
        readFileMaybe(filePath: string) {
          if (fs.existsSync(filePath)) {
            return fs.readFileSync(filePath, 'utf-8');
          }
          return null;
        },
        deleteFile(filePath: string) {
          if (fs.existsSync(filePath)) {
            fs.unlinkSync(filePath);
          }
          return null;
        },
      });
    },
  },
});

// In the test
const downloadsFolder = Cypress.config('downloadsFolder');
const filePath = `${downloadsFolder}/report.csv`;

beforeEach(() => {
  cy.task('deleteFile', filePath);
});

it('downloads a CSV report', () => {
  cy.visit('/reports');
  cy.get('[data-cy=download-csv]').click();

  // Retry until the file appears (the download is async)
  cy.readFile(filePath, { timeout: 15000 }).should('exist');
});
```

### Reading Downloaded Content

```typescript
it('downloaded CSV contains expected data', () => {
  cy.visit('/reports');
  cy.get('[data-cy=download-csv]').click();

  const filePath = `${Cypress.config('downloadsFolder')}/report.csv`;
  cy.readFile(filePath, { timeout: 15000 }).then((content: string) => {
    const lines = content.trim().split('\n');
    expect(lines[0]).to.eq('id,name,email');
    expect(lines).to.have.length.greaterThan(1);
  });
});

// Reading a downloaded JSON file
it('downloaded JSON matches expected schema', () => {
  cy.get('[data-cy=export-json]').click();
  cy.readFile(`${Cypress.config('downloadsFolder')}/export.json`).then((data: any) => {
    expect(data).to.have.property('users');
    expect(data.users).to.be.an('array').and.have.length.greaterThan(0);
    expect(data.users[0]).to.have.keys('id', 'name', 'email');
  });
});
```

---

## 6. Testing WebSockets

### Intercepting WebSocket Connections

Cypress `cy.intercept()` targets HTTP only. To test WebSockets, instrument the app or spy on the `WebSocket` constructor:

```typescript
it('captures outgoing WebSocket messages', () => {
  const messages: string[] = [];

  cy.visit('/', {
    onBeforeLoad(win) {
      const OriginalWebSocket = win.WebSocket;
      cy.stub(win, 'WebSocket').callsFake((url: string, protocols?: string | string[]) => {
        const ws = new OriginalWebSocket(url, protocols);
        const originalSend = ws.send.bind(ws);
        ws.send = (data: string | ArrayBuffer | Blob) => {
          messages.push(typeof data === 'string' ? data : '<binary>');
          originalSend(data);
        };
        return ws;
      });
    },
  });

  cy.get('[data-cy=send-message]').click();
  cy.wrap(messages).should('have.length.greaterThan', 0);
});
```

### Testing Real-Time Updates

Use a real server and assert that incoming messages render correctly:

```typescript
it('displays real-time notifications', () => {
  cy.visit('/dashboard');

  // Trigger a server-side event via API
  cy.request('POST', '/api/test/emit-notification', {
    userId: 'test-user',
    message: 'Build #42 passed',
  });

  // Assert the notification appears in the UI
  cy.get('[data-cy=notifications]', { timeout: 10000 })
    .should('contain', 'Build #42 passed');
});
```

### Mocking Socket.IO

Replace the Socket.IO client with a controllable mock:

```typescript
import { EventEmitter } from 'events';

class MockSocket extends EventEmitter {
  connected = true;
  id = 'mock-socket-id';
  connect() { this.connected = true; this.emit('connect'); return this; }
  disconnect() { this.connected = false; this.emit('disconnect'); return this; }
  // Socket.IO uses emit for sending too, so we mirror that
}

it('renders chat messages from socket events', () => {
  const mockSocket = new MockSocket();

  cy.visit('/chat', {
    onBeforeLoad(win) {
      // Replace the io() factory before the app calls it
      (win as any).io = () => mockSocket;
    },
  });

  // Simulate the server sending a message
  cy.then(() => {
    mockSocket.emit('chat:message', {
      user: 'Alice',
      text: 'Hello from mock!',
      timestamp: Date.now(),
    });
  });

  cy.get('[data-cy=message-list]').should('contain', 'Hello from mock!');
});
```

### Testing Reconnection

Verify the app handles disconnects gracefully:

```typescript
it('shows reconnection banner and recovers', () => {
  const mockSocket = new MockSocket();

  cy.visit('/chat', {
    onBeforeLoad(win) {
      (win as any).io = () => mockSocket;
    },
  });

  // Simulate a disconnect
  cy.then(() => mockSocket.emit('disconnect'));
  cy.get('[data-cy=connection-status]').should('contain', 'Reconnecting');

  // Simulate reconnection
  cy.then(() => {
    mockSocket.connected = true;
    mockSocket.emit('connect');
  });
  cy.get('[data-cy=connection-status]').should('contain', 'Connected');
});
```

---

## 7. Testing Drag-and-Drop

### Using cypress-real-events

`cypress-real-events` dispatches native browser events via Chrome DevTools Protocol, which is more reliable than simulated events:

```typescript
// npm install --save-dev cypress-real-events
// cypress/support/e2e.ts
import 'cypress-real-events';

it('drags an item using real events', () => {
  cy.visit('/kanban');
  cy.get('[data-cy=card-1]').realMouseDown({ position: 'center' });
  cy.get('[data-cy=column-done]').realMouseMove().realMouseUp();
  cy.get('[data-cy=column-done]').should('contain', 'Card 1');
});
```

### HTML5 Drag and Drop

Use the DataTransfer API for HTML5 drag-and-drop when `cypress-real-events` is not available:

```typescript
function dragAndDrop(sourceSelector: string, targetSelector: string) {
  const dataTransfer = new DataTransfer();

  cy.get(sourceSelector)
    .trigger('pointerdown', { which: 1, button: 0 })
    .trigger('dragstart', { dataTransfer })
    .trigger('drag');

  cy.get(targetSelector)
    .trigger('dragover', { dataTransfer })
    .trigger('drop', { dataTransfer });

  cy.get(sourceSelector)
    .trigger('dragend', { dataTransfer });
}

it('moves a task to the done column', () => {
  cy.visit('/board');
  dragAndDrop('[data-cy=task-3]', '[data-cy=column-done]');
  cy.get('[data-cy=column-done]').should('contain', 'Task 3');
});
```

### Sortable Lists

Test reorder in a sortable list (e.g., SortableJS, dnd-kit):

```typescript
it('reorders items in a sortable list', () => {
  cy.visit('/settings/priorities');

  // Get the third item and drag it to the first position
  cy.get('[data-cy=sortable-item]').eq(2).as('dragItem');
  cy.get('[data-cy=sortable-item]').eq(0).as('dropTarget');

  const dataTransfer = new DataTransfer();
  cy.get('@dragItem').trigger('dragstart', { dataTransfer });
  cy.get('@dropTarget').trigger('dragover', { dataTransfer }).trigger('drop', { dataTransfer });
  cy.get('@dragItem').trigger('dragend');

  // Verify the new order
  cy.get('[data-cy=sortable-item]').eq(0).should('contain', 'Priority C');
});
```

### Kanban Boards

End-to-end Kanban test moving a card through multiple columns:

```typescript
describe('Kanban Board', () => {
  beforeEach(() => cy.visit('/board'));

  it('moves a card through the full workflow', () => {
    // Backlog → In Progress
    dragAndDrop('[data-cy=card-new-feature]', '[data-cy=col-in-progress]');
    cy.get('[data-cy=col-in-progress]').should('contain', 'New Feature');

    // In Progress → Review
    dragAndDrop('[data-cy=card-new-feature]', '[data-cy=col-review]');
    cy.get('[data-cy=col-review]').should('contain', 'New Feature');

    // Review → Done
    dragAndDrop('[data-cy=card-new-feature]', '[data-cy=col-done]');
    cy.get('[data-cy=col-done]').should('contain', 'New Feature');

    // Verify card count updates
    cy.get('[data-cy=col-backlog] [data-cy^=card-]').should('have.length', 2);
    cy.get('[data-cy=col-done] [data-cy^=card-]').should('have.length', 4);
  });
});
```

---

## 8. Session Management (cy.session)

### Caching Login State

`cy.session()` snapshots and restores cookies, `localStorage`, and `sessionStorage`:

```typescript
const login = (email: string, password: string) => {
  cy.session(['login', email], () => {
    cy.request('POST', '/api/auth/login', { email, password })
      .its('body.token')
      .then((token) => {
        localStorage.setItem('auth_token', token);
      });
  });
};

describe('Dashboard', () => {
  beforeEach(() => {
    login('admin@test.com', 'admin123');
    cy.visit('/dashboard');
  });

  it('loads widgets', () => {
    cy.get('[data-cy=widget]').should('have.length.greaterThan', 0);
  });
});
```

### Session Validation

The `validate` callback runs every time a cached session is restored. If it throws or fails, the `setup` runs again:

```typescript
cy.session('authenticated', () => {
  cy.request('POST', '/api/login', { email: 'a@b.com', password: 'pass' })
    .its('body.token')
    .then((token) => localStorage.setItem('token', token));
}, {
  validate() {
    // If this request fails (e.g., token expired), setup reruns
    cy.request({
      url: '/api/me',
      headers: { Authorization: `Bearer ${localStorage.getItem('token')}` },
      failOnStatusCode: true,
    });
  },
});
```

### Session Recreation

Force a session to be recreated when external state changes (e.g., database reset):

```typescript
let dbSeed = 'seed-v1';

beforeEach(() => {
  cy.session(
    ['user', dbSeed], // changing dbSeed invalidates the cache
    () => {
      cy.task('db:seed', dbSeed);
      cy.request('POST', '/api/login', { email: 'user@test.com', password: 'pass' });
    }
  );
});
```

### Multi-User Testing

Test interactions between users by switching sessions within a single test:

```typescript
it('admin approves a request submitted by an editor', () => {
  // Step 1: Editor submits a request
  cy.session('editor', () => {
    cy.request('POST', '/api/login', { email: 'editor@app.com', password: 'ed123' });
  });
  cy.visit('/requests/new');
  cy.get('[data-cy=title]').type('Publish article');
  cy.get('[data-cy=submit]').click();
  cy.get('[data-cy=request-id]').invoke('text').as('requestId');

  // Step 2: Admin approves it
  cy.session('admin', () => {
    cy.request('POST', '/api/login', { email: 'admin@app.com', password: 'admin123' });
  });
  cy.get<string>('@requestId').then((id) => {
    cy.visit(`/requests/${id}`);
  });
  cy.get('[data-cy=approve-btn]').click();
  cy.get('[data-cy=status]').should('contain', 'Approved');
});
```

---

## 9. Retry-ability Internals

### How Cypress Retries Work

Cypress automatically retries the **last command** in a chain (before an assertion) until the assertion passes or the timeout expires. This is *not* polling—it re-queries the DOM on each retry loop iteration (~50ms intervals).

```typescript
// Cypress retries cy.get() until .should() passes or 4s timeout
cy.get('.notification').should('be.visible');

// The LAST command before .should() retries.
// Here, .find() retries, but .get() does NOT re-run:
cy.get('.list')      // runs once, yields a static reference
  .find('.item')     // retries against the previously yielded .list element
  .should('have.length', 5);
```

### Which Commands Retry

| Retries | Does NOT Retry |
|---------|----------------|
| `cy.get()` | `cy.click()` |
| `cy.find()` | `cy.type()` |
| `cy.contains()` | `cy.request()` |
| `cy.its()` | `cy.then()` |
| `cy.invoke()` | `cy.each()` |
| `cy.eq()`, `cy.first()`, `cy.last()` | `cy.task()` |
| `cy.children()`, `cy.parent()` | `cy.exec()` |

**Rule of thumb:** Query commands retry; action and side-effect commands do not.

### Custom Retry Logic

For scenarios that need custom retry logic beyond built-in retries, use recursive functions:

```typescript
function waitForJobCompletion(jobId: string, maxAttempts = 20, attempt = 0): void {
  if (attempt >= maxAttempts) {
    throw new Error(`Job ${jobId} did not complete after ${maxAttempts} attempts`);
  }

  cy.request(`/api/jobs/${jobId}`).then((resp) => {
    if (resp.body.status === 'completed') {
      return; // done
    }
    cy.wait(1000); // poll interval
    waitForJobCompletion(jobId, maxAttempts, attempt + 1);
  });
}

it('processes a background job', () => {
  cy.request('POST', '/api/jobs', { type: 'export' })
    .its('body.id')
    .then((jobId: string) => {
      waitForJobCompletion(jobId);
    });
});
```

### Retry vs Timeout

`timeout` controls how long Cypress retries a query before failing. It is *not* a sleep.

```typescript
// Retries .get() for up to 10 seconds until .should() passes
cy.get('[data-cy=results]', { timeout: 10000 }).should('have.length', 3);

// cy.wait() is a hard sleep—avoid using it for assertions
// ❌ BAD
cy.wait(5000);
cy.get('[data-cy=results]').should('have.length', 3);

// ✅ GOOD — let the retry mechanism handle timing
cy.get('[data-cy=results]', { timeout: 10000 }).should('have.length', 3);
```

### .should() Retry Behavior

`.should()` retries the *entire chain* above it up to the last query command:

```typescript
// This retries .find() (the last query) until assertion passes
cy.get('.container')
  .find('.dynamic-row')
  .should('have.length.greaterThan', 2);

// With a callback, .should() retries the callback itself
cy.get('[data-cy=price]').should(($el) => {
  const price = parseFloat($el.text().replace('$', ''));
  expect(price).to.be.greaterThan(0);
  expect(price).to.be.lessThan(1000);
});

// Chained .should() calls each retry independently
cy.get('[data-cy=status]')
  .should('be.visible')        // retries until visible
  .and('contain', 'Active');   // then retries until text matches

// ⚠️ .then() breaks retry-ability — the chain before .then() does NOT retry
cy.get('.item')
  .then(($el) => $el.text()) // if .get() found stale elements, .then() won't retry
  .should('eq', 'Hello');     // this retries .then(), but .get() already resolved
```

---

## 10. Testing Shadow DOM

### includeShadowDom Config

Enable global Shadow DOM traversal so `cy.get()` pierces shadow roots automatically:

```typescript
// cypress.config.ts
import { defineConfig } from 'cypress';

export default defineConfig({
  e2e: {
    includeShadowDom: true, // all cy.get() calls traverse shadow roots
  },
});

// Now this works even if <my-button> lives inside a shadow root
cy.get('my-button').should('be.visible').click();
```

You can also enable it per-command:

```typescript
cy.get('my-component', { includeShadowDom: true })
  .find('button')
  .click();
```

### cy.shadow()

`cy.shadow()` yields the shadow root of the subject element:

```typescript
cy.get('my-dropdown')
  .shadow()
  .find('.dropdown-list')
  .should('not.be.visible');

cy.get('my-dropdown')
  .shadow()
  .find('.dropdown-trigger')
  .click();

cy.get('my-dropdown')
  .shadow()
  .find('.dropdown-list')
  .should('be.visible')
  .contains('Option 2')
  .click();
```

### Targeting Shadow Elements

When components are nested multiple levels deep with shadow roots at each level:

```typescript
// <app-shell>
//   #shadow-root
//     <nav-bar>
//       #shadow-root
//         <menu-item>Settings</menu-item>

// With includeShadowDom: true (global)
cy.contains('menu-item', 'Settings').click();

// Without global config, chain .shadow() at each boundary
cy.get('app-shell')
  .shadow()
  .find('nav-bar')
  .shadow()
  .find('menu-item')
  .contains('Settings')
  .click();
```

### Web Component Testing

Full test for a custom element with its own shadow DOM:

```typescript
describe('<color-picker> web component', () => {
  beforeEach(() => {
    cy.visit('/components/color-picker');
  });

  it('opens the palette on click', () => {
    cy.get('color-picker').shadow().find('[data-cy=swatch]').click();
    cy.get('color-picker').shadow().find('[data-cy=palette]').should('be.visible');
  });

  it('selects a color and emits a change event', () => {
    const onChange = cy.stub().as('colorChange');

    cy.get('color-picker').then(($el) => {
      $el[0].addEventListener('color-change', (e: Event) => {
        onChange((e as CustomEvent).detail);
      });
    });

    cy.get('color-picker').shadow().find('[data-cy=swatch]').click();
    cy.get('color-picker').shadow().find('[data-color="#ff5733"]').click();

    cy.get('@colorChange').should('have.been.calledOnce');
    cy.get('@colorChange').should('have.been.calledWithMatch', { hex: '#ff5733' });
  });

  it('reflects the selected color as an attribute', () => {
    cy.get('color-picker').shadow().find('[data-cy=swatch]').click();
    cy.get('color-picker').shadow().find('[data-color="#00bcd4"]').click();
    cy.get('color-picker').should('have.attr', 'value', '#00bcd4');
  });
});
```

---

## 11. Visual Regression

### Percy Integration

Percy captures DOM snapshots and renders them in their cloud for pixel comparison:

```bash
npm install --save-dev @percy/cli @percy/cypress
```

```typescript
// cypress/support/e2e.ts
import '@percy/cypress';

// In a test
describe('Homepage visual regression', () => {
  it('matches the landing page snapshot', () => {
    cy.visit('/');
    cy.get('[data-cy=hero]').should('be.visible');
    cy.percySnapshot('Homepage - default');
  });

  it('matches the dark mode snapshot', () => {
    cy.visit('/');
    cy.get('[data-cy=theme-toggle]').click();
    cy.percySnapshot('Homepage - dark mode');
  });
});
```

Run with:

```bash
npx percy exec -- cypress run
```

### Applitools Eyes

Applitools uses AI-powered visual comparison:

```bash
npm install --save-dev @applitools/eyes-cypress
npx eyes-setup
```

```typescript
// cypress/support/e2e.ts
import '@applitools/eyes-cypress/commands';

describe('Dashboard visual tests', () => {
  beforeEach(() => {
    cy.eyesOpen({
      appName: 'My App',
      testName: Cypress.currentTest.title,
      browser: [
        { width: 1200, height: 800, name: 'chrome' },
        { width: 768, height: 1024, name: 'firefox' },
        { deviceName: 'iPhone 14', screenOrientation: 'portrait' },
      ],
    });
  });

  afterEach(() => {
    cy.eyesClose();
  });

  it('renders the dashboard correctly', () => {
    cy.visit('/dashboard');
    cy.get('[data-cy=chart]').should('be.visible');
    cy.eyesCheckWindow({
      tag: 'Dashboard - full page',
      fully: true,              // capture full scrollable page
      matchLevel: 'Layout',     // ignore minor color shifts
    });
  });

  it('renders the sidebar in collapsed state', () => {
    cy.visit('/dashboard');
    cy.get('[data-cy=sidebar-toggle]').click();
    cy.eyesCheckWindow({ tag: 'Dashboard - collapsed sidebar' });
  });
});
```

### Screenshot Comparison

Use `cypress-image-snapshot` for local, self-hosted visual diffing without a cloud service:

```bash
npm install --save-dev @simonsmith/cypress-image-snapshot
```

```typescript
// cypress.config.ts
import { addMatchImageSnapshotPlugin } from '@simonsmith/cypress-image-snapshot/plugin';

export default defineConfig({
  e2e: {
    setupNodeEvents(on) {
      addMatchImageSnapshotPlugin(on);
    },
  },
});

// cypress/support/e2e.ts
import { addMatchImageSnapshotCommand } from '@simonsmith/cypress-image-snapshot/command';
addMatchImageSnapshotCommand();

// In a test
it('matches the login page screenshot', () => {
  cy.visit('/login');
  cy.get('[data-cy=login-form]').should('be.visible');
  cy.matchImageSnapshot('login-page', {
    failureThreshold: 0.01,          // 1% pixel difference allowed
    failureThresholdType: 'percent',
    customDiffConfig: { threshold: 0.1 },
  });
});

// Snapshot a specific element, not the full page
it('button matches its snapshot', () => {
  cy.visit('/components');
  cy.get('[data-cy=primary-button]').matchImageSnapshot('primary-button');
});
```

### Responsive Visual Testing

Combine viewport changes with visual snapshots to catch responsive layout bugs:

```typescript
const viewports: Cypress.ViewportPreset[] = ['iphone-6', 'ipad-2', 'macbook-15'];

viewports.forEach((viewport) => {
  describe(`Visual regression @ ${viewport}`, () => {
    beforeEach(() => {
      cy.viewport(viewport);
      cy.visit('/');
    });

    it(`header renders correctly on ${viewport}`, () => {
      cy.get('header').should('be.visible');
      cy.percySnapshot(`Header - ${viewport}`);
    });

    it(`footer renders correctly on ${viewport}`, () => {
      cy.scrollTo('bottom');
      cy.get('footer').should('be.visible');
      cy.percySnapshot(`Footer - ${viewport}`);
    });
  });
});

// Custom viewport dimensions for specific breakpoints
const breakpoints = [
  { name: 'mobile',  width: 375,  height: 812 },
  { name: 'tablet',  width: 768,  height: 1024 },
  { name: 'desktop', width: 1440, height: 900 },
];

breakpoints.forEach(({ name, width, height }) => {
  it(`pricing page at ${name} (${width}x${height})`, () => {
    cy.viewport(width, height);
    cy.visit('/pricing');
    cy.get('[data-cy=pricing-grid]').should('be.visible');
    cy.matchImageSnapshot(`pricing-${name}`);
  });
});
```

---

> **Tip:** Combine these patterns. Use `cy.session()` to speed up auth, `cy.origin()` for OAuth redirects, `cy.intercept()` to stub APIs, and visual snapshots for layout verification — all within the same spec. Cypress is built for composability.
