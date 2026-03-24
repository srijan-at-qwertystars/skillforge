/**
 * Component Test Spec Template (React)
 *
 * Best practices applied:
 * - Tests component in isolation with cy.mount()
 * - Uses cy.stub() for callback props
 * - Intercepts internal API calls
 * - Tests accessibility attributes
 * - Tests responsive behavior
 * - Tests loading, error, and empty states
 */

import React from 'react';
// import { ItemCard } from './ItemCard';
// import { AppProviders } from '../test-utils/providers';

// ─── Example Component Interface ─────────────────────────────────
interface ItemCardProps {
  id: string;
  title: string;
  description: string;
  status: 'active' | 'archived';
  onEdit?: (id: string) => void;
  onDelete?: (id: string) => void;
}

// ─── Test Helpers ─────────────────────────────────────────────────
const defaultProps: ItemCardProps = {
  id: 'item-1',
  title: 'Test Item',
  description: 'A description for testing purposes',
  status: 'active',
};

/**
 * Custom mount with providers.
 * Wrap with Router, Theme, Store providers as needed.
 */
function mountItemCard(props: Partial<ItemCardProps> = {}) {
  const merged = { ...defaultProps, ...props };
  // cy.mount(
  //   <AppProviders>
  //     <ItemCard {...merged} />
  //   </AppProviders>
  // );
  // Uncomment above when component is available
}

// ─── Tests ────────────────────────────────────────────────────────
describe('ItemCard Component', () => {
  // ─── Rendering ────────────────────────────────────────────────
  describe('rendering', () => {
    it('renders title and description', () => {
      mountItemCard();

      cy.getByCy('item-title').should('have.text', 'Test Item');
      cy.getByCy('item-description').should('contain', 'A description');
    });

    it('renders active status badge', () => {
      mountItemCard({ status: 'active' });

      cy.getByCy('status-badge')
        .should('have.text', 'Active')
        .and('have.class', 'badge-active');
    });

    it('renders archived status badge', () => {
      mountItemCard({ status: 'archived' });

      cy.getByCy('status-badge')
        .should('have.text', 'Archived')
        .and('have.class', 'badge-archived');
    });
  });

  // ─── Props & Callbacks ────────────────────────────────────────
  describe('callbacks', () => {
    it('calls onEdit with item id when edit button clicked', () => {
      const onEdit = cy.stub().as('onEdit');
      mountItemCard({ onEdit });

      cy.getByCy('edit-button').click();
      cy.get('@onEdit').should('have.been.calledOnceWith', 'item-1');
    });

    it('calls onDelete with confirmation', () => {
      const onDelete = cy.stub().as('onDelete');
      mountItemCard({ onDelete });

      cy.getByCy('delete-button').click();

      // Confirmation dialog should appear
      cy.getByCy('confirm-dialog').should('be.visible');
      cy.getByCy('confirm-yes').click();

      cy.get('@onDelete').should('have.been.calledOnceWith', 'item-1');
    });

    it('does not call onDelete when cancelled', () => {
      const onDelete = cy.stub().as('onDelete');
      mountItemCard({ onDelete });

      cy.getByCy('delete-button').click();
      cy.getByCy('confirm-no').click();

      cy.get('@onDelete').should('not.have.been.called');
      cy.getByCy('confirm-dialog').should('not.exist');
    });

    it('hides edit/delete buttons when callbacks not provided', () => {
      mountItemCard({ onEdit: undefined, onDelete: undefined });

      cy.getByCy('edit-button').should('not.exist');
      cy.getByCy('delete-button').should('not.exist');
    });
  });

  // ─── API Interactions ─────────────────────────────────────────
  describe('with API calls', () => {
    it('fetches additional data on expand', () => {
      cy.intercept('GET', '/api/items/item-1/details', {
        body: { tags: ['urgent', 'frontend'], comments: 3 },
      }).as('getDetails');

      mountItemCard();

      cy.getByCy('expand-button').click();
      cy.wait('@getDetails');

      cy.getByCy('tag-list').should('contain', 'urgent');
      cy.getByCy('comment-count').should('have.text', '3');
    });

    it('handles API error on expand', () => {
      cy.intercept('GET', '/api/items/item-1/details', {
        statusCode: 500,
      }).as('getDetailsFail');

      mountItemCard();

      cy.getByCy('expand-button').click();
      cy.wait('@getDetailsFail');

      cy.getByCy('detail-error').should('be.visible');
    });
  });

  // ─── Accessibility ────────────────────────────────────────────
  describe('accessibility', () => {
    it('has correct ARIA roles and labels', () => {
      mountItemCard();

      cy.getByCy('item-card').should('have.attr', 'role', 'article');
      cy.getByCy('edit-button').should('have.attr', 'aria-label', 'Edit Test Item');
      cy.getByCy('delete-button').should('have.attr', 'aria-label', 'Delete Test Item');
    });

    it('is keyboard navigable', () => {
      mountItemCard();

      cy.getByCy('item-card').focus();
      cy.focused().should('have.attr', 'data-cy', 'item-card');

      // Tab to edit button
      cy.realPress('Tab');
      cy.focused().should('have.attr', 'data-cy', 'edit-button');

      // Tab to delete button
      cy.realPress('Tab');
      cy.focused().should('have.attr', 'data-cy', 'delete-button');
    });
  });

  // ─── Responsive Behavior ──────────────────────────────────────
  describe('responsive', () => {
    it('shows compact layout on small viewport', () => {
      cy.viewport(375, 667);
      mountItemCard();

      cy.getByCy('item-card').should('have.class', 'compact');
      cy.getByCy('item-description').should('not.be.visible');
    });

    it('shows full layout on large viewport', () => {
      cy.viewport(1280, 720);
      mountItemCard();

      cy.getByCy('item-card').should('not.have.class', 'compact');
      cy.getByCy('item-description').should('be.visible');
    });
  });

  // ─── Snapshot / Visual Regression ─────────────────────────────
  describe('visual', () => {
    it('matches visual snapshot (active state)', () => {
      mountItemCard({ status: 'active' });

      // With Percy:
      // cy.percySnapshot('ItemCard - Active');

      // With Cypress screenshot comparison:
      cy.getByCy('item-card').should('be.visible');
      // cy.getByCy('item-card').matchImageSnapshot('item-card-active');
    });
  });
});
