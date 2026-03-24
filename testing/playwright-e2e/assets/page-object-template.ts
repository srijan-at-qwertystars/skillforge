import { type Page, type Locator, expect } from '@playwright/test';

/**
 * Base class for all Page Object Model classes.
 *
 * Provides common navigation, waiting, and assertion utilities.
 * Extend this class for each page in your application.
 *
 * Usage:
 *   export class LoginPage extends BasePage {
 *     readonly url = '/login';
 *     readonly emailInput: Locator;
 *     constructor(page: Page) {
 *       super(page);
 *       this.emailInput = page.getByLabel('Email');
 *     }
 *   }
 */
export abstract class BasePage {
  /**
   * The URL path for this page (relative to baseURL).
   * Override in subclasses.
   */
  abstract readonly url: string;

  constructor(protected readonly page: Page) {}

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /** Navigate to this page's URL. */
  async goto() {
    await this.page.goto(this.url);
  }

  /** Navigate to this page and wait for network idle. */
  async gotoAndWaitForLoad() {
    await this.page.goto(this.url, { waitUntil: 'networkidle' });
  }

  /** Assert that the browser is on this page's URL. */
  async expectToBeOnPage() {
    await expect(this.page).toHaveURL(new RegExp(this.url));
  }

  // ---------------------------------------------------------------------------
  // Common interactions
  // ---------------------------------------------------------------------------

  /** Get the page title. */
  async getTitle(): Promise<string> {
    return this.page.title();
  }

  /** Take a screenshot and attach to test results. */
  async screenshot(name: string) {
    return this.page.screenshot({ path: `test-results/screenshots/${name}.png` });
  }

  /** Wait for a loading spinner/overlay to disappear. */
  async waitForLoadingToComplete(locator?: Locator) {
    const spinner = locator ?? this.page.getByTestId('loading-spinner');
    await spinner.waitFor({ state: 'hidden', timeout: 15_000 });
  }

  // ---------------------------------------------------------------------------
  // Toast / notification helpers
  // ---------------------------------------------------------------------------

  /** Assert a success toast is visible with the given message. */
  async expectSuccessToast(message: string | RegExp) {
    await expect(this.page.getByRole('status')).toContainText(message);
  }

  /** Assert an error alert is visible with the given message. */
  async expectErrorAlert(message: string | RegExp) {
    await expect(this.page.getByRole('alert')).toContainText(message);
  }

  // ---------------------------------------------------------------------------
  // Table helpers
  // ---------------------------------------------------------------------------

  /** Get all rows in a table, optionally filtered by text. */
  getTableRows(tableLocator?: Locator, filterText?: string) {
    const table = tableLocator ?? this.page.getByRole('table');
    const rows = table.getByRole('row');
    return filterText ? rows.filter({ hasText: filterText }) : rows;
  }

  /** Assert the number of rows in a table (excluding header). */
  async expectRowCount(count: number, tableLocator?: Locator) {
    const table = tableLocator ?? this.page.getByRole('table');
    // Subtract 1 for header row
    await expect(table.getByRole('row')).toHaveCount(count + 1);
  }

  // ---------------------------------------------------------------------------
  // Form helpers
  // ---------------------------------------------------------------------------

  /**
   * Fill multiple form fields at once.
   * Keys should match the accessible label of each field.
   */
  async fillForm(fields: Record<string, string>) {
    for (const [label, value] of Object.entries(fields)) {
      await this.page.getByLabel(label).fill(value);
    }
  }

  /** Submit the form by clicking a submit button. */
  async submitForm(buttonName = 'Submit') {
    await this.page.getByRole('button', { name: buttonName }).click();
  }

  // ---------------------------------------------------------------------------
  // Dialog helpers
  // ---------------------------------------------------------------------------

  /** Accept the next JavaScript dialog (alert/confirm/prompt). */
  async acceptNextDialog(inputText?: string) {
    this.page.once('dialog', async (dialog) => {
      if (inputText !== undefined) {
        await dialog.accept(inputText);
      } else {
        await dialog.accept();
      }
    });
  }

  /** Dismiss the next JavaScript dialog. */
  async dismissNextDialog() {
    this.page.once('dialog', async (dialog) => {
      await dialog.dismiss();
    });
  }
}

// =============================================================================
// Example subclass — copy and adapt for your pages
// =============================================================================

/*
export class LoginPage extends BasePage {
  readonly url = '/login';

  readonly emailInput: Locator;
  readonly passwordInput: Locator;
  readonly signInButton: Locator;
  readonly errorMessage: Locator;

  constructor(page: Page) {
    super(page);
    this.emailInput = page.getByLabel('Email');
    this.passwordInput = page.getByLabel('Password');
    this.signInButton = page.getByRole('button', { name: 'Sign in' });
    this.errorMessage = page.getByRole('alert');
  }

  async login(email: string, password: string) {
    await this.emailInput.fill(email);
    await this.passwordInput.fill(password);
    await this.signInButton.click();
  }

  async expectLoginError(message: string) {
    await expect(this.errorMessage).toContainText(message);
  }

  async expectRedirectToDashboard() {
    await expect(this.page).toHaveURL(/\/dashboard/);
  }
}
*/
