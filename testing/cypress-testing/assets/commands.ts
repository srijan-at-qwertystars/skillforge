// cypress/support/commands.ts — Custom Cypress commands
// Import this in cypress/support/e2e.ts and cypress/support/component.ts

// ─── Type Declarations ──────────────────────────────────────────
declare global {
  namespace Cypress {
    interface Chainable {
      /** Select element by data-cy attribute */
      getByCy(selector: string): Chainable<JQuery<HTMLElement>>;

      /** Select element by data-testid attribute */
      getByTestId(selector: string): Chainable<JQuery<HTMLElement>>;

      /** Login via API and cache session with cy.session() */
      login(email: string, password: string): Chainable<void>;

      /** Login as a specific role (admin, user, editor) */
      loginAs(role: 'admin' | 'user' | 'editor'): Chainable<void>;

      /** Make authenticated API request */
      apiRequest(
        method: string,
        url: string,
        body?: Record<string, unknown>
      ): Chainable<Cypress.Response<unknown>>;

      /** Assert element has specific CSS property */
      shouldHaveCss(
        property: string,
        value: string
      ): Chainable<JQuery<HTMLElement>>;

      /** Wait for loading spinner to disappear */
      waitForLoad(): Chainable<void>;

      /** Paste text into focused element (bypasses typing) */
      paste(text: string): Chainable<JQuery<HTMLElement>>;
    }
  }
}

// ─── Selector Commands ──────────────────────────────────────────

Cypress.Commands.add('getByCy', (selector: string) => {
  return cy.get(`[data-cy="${selector}"]`);
});

Cypress.Commands.add('getByTestId', (selector: string) => {
  return cy.get(`[data-testid="${selector}"]`);
});

// ─── Authentication Commands ────────────────────────────────────

Cypress.Commands.add('login', (email: string, password: string) => {
  cy.session(
    [email, password],
    () => {
      cy.request({
        method: 'POST',
        url: '/api/auth/login',
        body: { email, password },
      }).then((resp) => {
        expect(resp.status).to.eq(200);
        window.localStorage.setItem('token', resp.body.token);
        if (resp.body.refreshToken) {
          window.localStorage.setItem('refreshToken', resp.body.refreshToken);
        }
      });
    },
    {
      validate() {
        cy.request({
          url: '/api/auth/me',
          headers: {
            Authorization: `Bearer ${window.localStorage.getItem('token')}`,
          },
          failOnStatusCode: false,
        }).its('status').should('eq', 200);
      },
    }
  );
});

const TEST_USERS = {
  admin: { email: 'admin@test.com', password: 'admin-pass-123' },
  user: { email: 'user@test.com', password: 'user-pass-123' },
  editor: { email: 'editor@test.com', password: 'editor-pass-123' },
} as const;

Cypress.Commands.add('loginAs', (role: 'admin' | 'user' | 'editor') => {
  const { email, password } = TEST_USERS[role];
  cy.login(email, password);
});

// ─── API Helper Commands ────────────────────────────────────────

Cypress.Commands.add(
  'apiRequest',
  (method: string, url: string, body?: Record<string, unknown>) => {
    const token = window.localStorage.getItem('token');
    return cy.request({
      method,
      url,
      body,
      headers: {
        Authorization: token ? `Bearer ${token}` : '',
        'Content-Type': 'application/json',
      },
    });
  }
);

// ─── Assertion Commands ─────────────────────────────────────────

Cypress.Commands.add(
  'shouldHaveCss',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, property: string, value: string) => {
    cy.wrap(subject).should('have.css', property, value);
  }
);

// ─── Utility Commands ───────────────────────────────────────────

Cypress.Commands.add('waitForLoad', () => {
  // Wait for any loading indicators to disappear
  cy.get('[data-cy="loading"], .loading-spinner, [aria-busy="true"]', {
    timeout: 1000,
  })
    .should('not.exist')
    .then(() => {}, () => {
      // Element never appeared — page loaded without spinner
    });
});

Cypress.Commands.add(
  'paste',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, text: string) => {
    const clipboardData = new DataTransfer();
    clipboardData.setData('text/plain', text);
    const pasteEvent = new ClipboardEvent('paste', {
      bubbles: true,
      cancelable: true,
      clipboardData,
    });
    subject[0].dispatchEvent(pasteEvent);
    return cy.wrap(subject);
  }
);

export {};
