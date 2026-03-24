import { type Page, type Locator, expect } from '@playwright/test';

/**
 * Page Object Model Template
 *
 * Usage:
 *   1. Copy and rename this file to match your page (e.g., LoginPage.ts)
 *   2. Replace placeholder locators with your actual page elements
 *   3. Add action methods for user interactions
 *   4. Wire into fixtures for dependency injection
 *
 * Rules:
 *   - Define all locators in the constructor
 *   - Actions as methods, never raw selectors in tests
 *   - No assertions in page objects (assertions belong in tests)
 *   - Navigation methods return the destination page object
 *   - Use getByRole/getByLabel/getByTestId, never CSS selectors
 */

// Optional: extend a shared BasePage class for common helpers
// import { BasePage } from './BasePage';

export class ExamplePage /* extends BasePage */ {
  // ── Locators ────────────────────────────────────────────────
  readonly heading: Locator;
  readonly submitButton: Locator;
  readonly errorMessage: Locator;

  // Form fields
  readonly nameInput: Locator;
  readonly emailInput: Locator;

  // Navigation elements
  readonly navHome: Locator;
  readonly navSettings: Locator;

  constructor(private readonly page: Page) {
    // super(page);  // if extending BasePage

    // Prefer semantic locators in this order:
    // 1. getByRole (best — resilient, accessible)
    // 2. getByLabel / getByPlaceholder
    // 3. getByTestId (stable, decoupled from UI text)
    // 4. getByText (readable but fragile to copy changes)
    // 5. locator() with CSS (last resort)
    this.heading = page.getByRole('heading', { level: 1 });
    this.submitButton = page.getByRole('button', { name: 'Submit' });
    this.errorMessage = page.getByRole('alert');

    this.nameInput = page.getByLabel('Name');
    this.emailInput = page.getByLabel('Email');

    this.navHome = page.getByRole('link', { name: 'Home' });
    this.navSettings = page.getByRole('link', { name: 'Settings' });
  }

  // ── Navigation ──────────────────────────────────────────────

  async goto(): Promise<void> {
    await this.page.goto('/example');
    await this.waitForPageLoad();
  }

  async waitForPageLoad(): Promise<void> {
    await expect(this.heading).toBeVisible();
  }

  // ── Actions ─────────────────────────────────────────────────

  async fillForm(data: { name: string; email: string }): Promise<void> {
    await this.nameInput.fill(data.name);
    await this.emailInput.fill(data.email);
  }

  async submitForm(): Promise<void> {
    await this.submitButton.click();
  }

  /**
   * Fill and submit the form.
   * Returns a new page object if submission navigates to a new page.
   */
  async fillAndSubmit(data: { name: string; email: string }): Promise<void> {
    await this.fillForm(data);
    await this.submitForm();
    // If this navigates to a confirmation page:
    // return new ConfirmationPage(this.page);
  }

  // ── Navigation Actions (return destination POM) ─────────────

  // async goToSettings(): Promise<SettingsPage> {
  //   await this.navSettings.click();
  //   return new SettingsPage(this.page);
  // }

  // ── Data Extraction ─────────────────────────────────────────

  async getHeadingText(): Promise<string> {
    return await this.heading.innerText();
  }

  async getErrorText(): Promise<string | null> {
    if (await this.errorMessage.isVisible()) {
      return await this.errorMessage.innerText();
    }
    return null;
  }
}
