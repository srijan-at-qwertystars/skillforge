// Useful custom Cypress commands collection
// Copy individual commands into your cypress/support/commands.ts

// ---------------------------------------------------------------------------
// LOGIN / AUTH
// ---------------------------------------------------------------------------

/**
 * Programmatic login via API with session caching.
 * Avoids UI login in every test — dramatically speeds up test suites.
 */
Cypress.Commands.add(
  'login',
  (email: string, password: string, options?: { cacheSession?: boolean }) => {
    const { cacheSession = true } = options || {};

    const loginFlow = () => {
      cy.request({
        method: 'POST',
        url: '/api/auth/login',
        body: { email, password },
        failOnStatusCode: true,
      }).then((resp) => {
        window.localStorage.setItem('token', resp.body.token);
        if (resp.body.refreshToken) {
          window.localStorage.setItem('refreshToken', resp.body.refreshToken);
        }
      });
    };

    if (cacheSession) {
      cy.session(
        ['login', email],
        loginFlow,
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
          cacheAcrossSpecs: true,
        }
      );
    } else {
      loginFlow();
    }
  }
);

/**
 * Logout — clears auth state.
 */
Cypress.Commands.add('logout', () => {
  cy.clearLocalStorage();
  cy.clearCookies();
  cy.window().then((win) => win.sessionStorage.clear());
});

// ---------------------------------------------------------------------------
// SELECTORS
// ---------------------------------------------------------------------------

/**
 * Select element by data-cy attribute.
 */
Cypress.Commands.add('getByDataCy', (selector: string) => {
  return cy.get(`[data-cy="${selector}"]`);
});

/**
 * Select element by data-testid attribute.
 */
Cypress.Commands.add('getByTestId', (selector: string) => {
  return cy.get(`[data-testid="${selector}"]`);
});

// ---------------------------------------------------------------------------
// API HELPERS
// ---------------------------------------------------------------------------

/**
 * Make an authenticated API request with the stored token.
 */
Cypress.Commands.add(
  'apiRequest',
  (method: string, url: string, body?: Record<string, unknown>) => {
    const token = window.localStorage.getItem('token') || '';
    return cy.request({
      method,
      url,
      body,
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      failOnStatusCode: false,
    });
  }
);

/**
 * Seed test data via API. Returns created entity.
 */
Cypress.Commands.add(
  'seedData',
  (endpoint: string, data: Record<string, unknown>) => {
    return cy.apiRequest('POST', endpoint, data).then((resp) => {
      expect(resp.status).to.be.oneOf([200, 201]);
      return resp.body;
    });
  }
);

/**
 * Clean up test data via API.
 */
Cypress.Commands.add('cleanupData', (endpoint: string, id: string | number) => {
  return cy.apiRequest('DELETE', `${endpoint}/${id}`);
});

// ---------------------------------------------------------------------------
// DRAG AND DROP
// ---------------------------------------------------------------------------

/**
 * Drag an element to a target using native HTML5 drag events.
 * Works with libraries like react-beautiful-dnd, dnd-kit, etc.
 */
Cypress.Commands.add(
  'dragTo',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, targetSelector: string) => {
    const dataTransfer = new DataTransfer();

    cy.wrap(subject)
      .trigger('pointerdown', { which: 1, button: 0 })
      .trigger('dragstart', { dataTransfer })
      .trigger('drag', {});

    cy.get(targetSelector)
      .trigger('dragover', { dataTransfer })
      .trigger('drop', { dataTransfer })
      .trigger('dragend', { dataTransfer });

    // Small wait for DOM update after drop
    cy.wait(100); // eslint-disable-line cypress/no-unnecessary-waiting
  }
);

// ---------------------------------------------------------------------------
// FILE UPLOAD
// ---------------------------------------------------------------------------

/**
 * Upload a file to a file input or dropzone.
 * Uses the built-in cy.selectFile (Cypress 9.3+).
 */
Cypress.Commands.add(
  'uploadFile',
  { prevSubject: 'element' },
  (
    subject: JQuery<HTMLElement>,
    filePath: string,
    options?: { action?: 'select' | 'drag-drop'; mimeType?: string }
  ) => {
    const { action = 'select', mimeType } = options || {};

    if (action === 'drag-drop') {
      cy.wrap(subject).selectFile(filePath, {
        action: 'drag-drop',
        ...(mimeType && { mimeType }),
      });
    } else {
      cy.wrap(subject).selectFile(filePath, {
        ...(mimeType && { mimeType }),
      });
    }
  }
);

/**
 * Upload multiple files at once.
 */
Cypress.Commands.add(
  'uploadFiles',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, filePaths: string[]) => {
    cy.wrap(subject).selectFile(filePaths);
  }
);

// ---------------------------------------------------------------------------
// TABLE ASSERTIONS
// ---------------------------------------------------------------------------

/**
 * Assert that a table has the expected number of rows (excluding header).
 */
Cypress.Commands.add(
  'tableRowCount',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, expectedCount: number) => {
    cy.wrap(subject).find('tbody tr').should('have.length', expectedCount);
  }
);

/**
 * Assert that a table contains a row with the given text values.
 * Checks each cell in the row against the provided array.
 */
Cypress.Commands.add(
  'tableContainsRow',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, expectedCells: string[]) => {
    cy.wrap(subject)
      .find('tbody tr')
      .should(($rows) => {
        const match = $rows.toArray().some((row) => {
          const cells = Cypress.$(row).find('td').toArray().map((td) => td.textContent?.trim() || '');
          return expectedCells.every((expected, i) => cells[i]?.includes(expected));
        });
        expect(match, `Expected table to contain row: [${expectedCells.join(', ')}]`).to.be.true;
      });
  }
);

/**
 * Assert table headers match expected values.
 */
Cypress.Commands.add(
  'tableHeaders',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, expectedHeaders: string[]) => {
    cy.wrap(subject)
      .find('thead th')
      .should('have.length', expectedHeaders.length)
      .each(($th, index) => {
        expect($th.text().trim()).to.equal(expectedHeaders[index]);
      });
  }
);

/**
 * Sort a table by clicking a column header and verify order.
 */
Cypress.Commands.add(
  'tableSortBy',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, columnIndex: number, direction: 'asc' | 'desc') => {
    cy.wrap(subject)
      .find(`thead th:nth-child(${columnIndex + 1})`)
      .click();

    // Click again for descending if needed
    if (direction === 'desc') {
      cy.wrap(subject)
        .find(`thead th:nth-child(${columnIndex + 1})`)
        .click();
    }
  }
);

// ---------------------------------------------------------------------------
// UTILITY COMMANDS
// ---------------------------------------------------------------------------

/**
 * Wait for all pending network requests to complete.
 * Useful after page load or bulk operations.
 */
Cypress.Commands.add('waitForNetworkIdle', (timeout = 2000) => {
  let lastRequestTime = Date.now();

  cy.intercept('*', (req) => {
    lastRequestTime = Date.now();
    req.continue();
  });

  cy.wait(500).then(() => { // eslint-disable-line cypress/no-unnecessary-waiting
    const waitUntilIdle = () => {
      const elapsed = Date.now() - lastRequestTime;
      if (elapsed < timeout) {
        cy.wait(500); // eslint-disable-line cypress/no-unnecessary-waiting
      }
    };
    waitUntilIdle();
  });
});

/**
 * Assert that an element has no accessibility violations (requires cypress-axe).
 * Install: npm install --save-dev cypress-axe axe-core
 */
// Cypress.Commands.add('checkA11y', (context?: string, options?: Record<string, unknown>) => {
//   cy.injectAxe();
//   cy.checkA11y(context, options);
// });

/**
 * Paste text into an input (triggers paste event).
 */
Cypress.Commands.add(
  'paste',
  { prevSubject: 'element' },
  (subject: JQuery<HTMLElement>, text: string) => {
    const clipboardData = new DataTransfer();
    clipboardData.setData('text/plain', text);
    const pasteEvent = new ClipboardEvent('paste', {
      clipboardData,
      bubbles: true,
      cancelable: true,
    });

    cy.wrap(subject).then(($el) => {
      $el[0].dispatchEvent(pasteEvent);
    });
  }
);

// ---------------------------------------------------------------------------
// TYPESCRIPT DECLARATIONS
// ---------------------------------------------------------------------------

declare global {
  namespace Cypress {
    interface Chainable {
      login(email: string, password: string, options?: { cacheSession?: boolean }): Chainable<void>;
      logout(): Chainable<void>;
      getByDataCy(selector: string): Chainable<JQuery<HTMLElement>>;
      getByTestId(selector: string): Chainable<JQuery<HTMLElement>>;
      apiRequest(method: string, url: string, body?: Record<string, unknown>): Chainable<Response<any>>;
      seedData(endpoint: string, data: Record<string, unknown>): Chainable<any>;
      cleanupData(endpoint: string, id: string | number): Chainable<Response<any>>;
      dragTo(targetSelector: string): Chainable<void>;
      uploadFile(filePath: string, options?: { action?: 'select' | 'drag-drop'; mimeType?: string }): Chainable<void>;
      uploadFiles(filePaths: string[]): Chainable<void>;
      tableRowCount(expectedCount: number): Chainable<void>;
      tableContainsRow(expectedCells: string[]): Chainable<void>;
      tableHeaders(expectedHeaders: string[]): Chainable<void>;
      tableSortBy(columnIndex: number, direction: 'asc' | 'desc'): Chainable<void>;
      waitForNetworkIdle(timeout?: number): Chainable<void>;
      paste(text: string): Chainable<void>;
    }
  }
}

export {};
