/**
 * E2E Test Spec Template
 *
 * Best practices applied:
 * - Uses data-cy selectors for stability
 * - Intercepts API calls to control data and timing
 * - Each test is independent (no shared mutable state)
 * - Uses cy.session() for auth caching
 * - Assertions use .should() for automatic retries
 */

describe('Feature: [Feature Name]', () => {
  // ─── Setup ──────────────────────────────────────────────────────
  beforeEach(() => {
    // Authenticate (cached across tests via cy.session)
    cy.login('user@test.com', 'password');

    // Stub API responses for deterministic data
    cy.intercept('GET', '/api/items', { fixture: 'items.json' }).as('getItems');
    cy.intercept('GET', '/api/user/profile', { fixture: 'profile.json' }).as('getProfile');

    // Visit the page under test
    cy.visit('/items');
    cy.wait(['@getItems', '@getProfile']);
  });

  // ─── Happy Path ─────────────────────────────────────────────────
  describe('when viewing the item list', () => {
    it('displays all items from the API', () => {
      cy.getByCy('item-list').should('be.visible');
      cy.getByCy('item-card').should('have.length.greaterThan', 0);
    });

    it('shows item details when clicking an item', () => {
      cy.intercept('GET', '/api/items/*', { fixture: 'item-detail.json' }).as('getDetail');

      cy.getByCy('item-card').first().click();
      cy.wait('@getDetail');

      cy.getByCy('item-detail-panel').should('be.visible');
      cy.getByCy('item-title').should('not.be.empty');
      cy.getByCy('item-description').should('be.visible');
    });
  });

  // ─── User Actions ──────────────────────────────────────────────
  describe('when creating a new item', () => {
    beforeEach(() => {
      cy.intercept('POST', '/api/items', {
        statusCode: 201,
        body: { id: 'new-1', title: 'Test Item', status: 'active' },
      }).as('createItem');
    });

    it('submits the form and shows success message', () => {
      cy.getByCy('create-button').click();

      // Fill the form
      cy.getByCy('title-input').type('Test Item');
      cy.getByCy('description-input').type('A test item description');
      cy.getByCy('category-select').select('General');

      // Submit
      cy.getByCy('submit-button').click();

      // Verify API call
      cy.wait('@createItem').then((interception) => {
        expect(interception.request.body).to.deep.include({
          title: 'Test Item',
          description: 'A test item description',
        });
      });

      // Verify UI feedback
      cy.getByCy('success-toast').should('be.visible').and('contain', 'created');
    });

    it('validates required fields before submission', () => {
      cy.getByCy('create-button').click();
      cy.getByCy('submit-button').click();

      cy.getByCy('field-error').should('be.visible');
      cy.get('@createItem.all').should('have.length', 0); // API not called
    });
  });

  // ─── Error Handling ────────────────────────────────────────────
  describe('when the API returns an error', () => {
    it('shows error message on server failure', () => {
      cy.intercept('GET', '/api/items', {
        statusCode: 500,
        body: { error: 'Internal Server Error' },
      }).as('getItemsFail');

      cy.visit('/items');
      cy.wait('@getItemsFail');

      cy.getByCy('error-message')
        .should('be.visible')
        .and('contain', 'Something went wrong');
      cy.getByCy('retry-button').should('be.visible');
    });

    it('retries on user request', () => {
      let callCount = 0;
      cy.intercept('GET', '/api/items', (req) => {
        callCount++;
        if (callCount === 1) {
          req.reply({ statusCode: 500, body: { error: 'fail' } });
        } else {
          req.reply({ fixture: 'items.json' });
        }
      }).as('getItemsRetry');

      cy.visit('/items');
      cy.wait('@getItemsRetry');
      cy.getByCy('retry-button').click();
      cy.wait('@getItemsRetry');

      cy.getByCy('item-list').should('be.visible');
      cy.getByCy('error-message').should('not.exist');
    });
  });

  // ─── Edge Cases ────────────────────────────────────────────────
  describe('edge cases', () => {
    it('handles empty state gracefully', () => {
      cy.intercept('GET', '/api/items', { body: [] }).as('getEmpty');

      cy.visit('/items');
      cy.wait('@getEmpty');

      cy.getByCy('empty-state').should('be.visible');
      cy.getByCy('empty-state-cta').should('contain', 'Create your first item');
    });

    it('handles slow network gracefully', () => {
      cy.intercept('GET', '/api/items', {
        fixture: 'items.json',
        delay: 3000,
      }).as('slowItems');

      cy.visit('/items');

      // Loading state should appear
      cy.getByCy('loading-skeleton').should('be.visible');

      cy.wait('@slowItems');

      // Loading state should disappear, content appears
      cy.getByCy('loading-skeleton').should('not.exist');
      cy.getByCy('item-list').should('be.visible');
    });
  });
});
