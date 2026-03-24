import { type Page, type Locator, expect } from '@playwright/test';

/**
 * Base Page Object Model class with common helpers.
 *
 * Extend this class for each page in your application:
 *
 *   export class LoginPage extends BasePage {
 *     readonly emailInput: Locator;
 *     constructor(page: Page) {
 *       super(page);
 *       this.emailInput = page.getByLabel('Email');
 *     }
 *     async goto() { await this.navigateTo('/login'); }
 *   }
 */
export abstract class BasePage {
  constructor(protected readonly page: Page) {}

  // --- Navigation ---

  /** Navigate to a path relative to baseURL */
  protected async navigateTo(path: string): Promise<void> {
    await this.page.goto(path);
  }

  /** Wait for the page URL to match a pattern */
  async waitForURL(url: string | RegExp): Promise<void> {
    await expect(this.page).toHaveURL(url);
  }

  /** Go back to previous page and wait for load */
  async goBack(): Promise<void> {
    await this.page.goBack({ waitUntil: 'domcontentloaded' });
  }

  /** Reload the current page */
  async reload(): Promise<void> {
    await this.page.reload({ waitUntil: 'domcontentloaded' });
  }

  // --- Screenshots ---

  /** Take a full-page screenshot */
  async screenshot(name?: string): Promise<Buffer> {
    return await this.page.screenshot({
      path: name ? `screenshots/${name}.png` : undefined,
      fullPage: true,
    });
  }

  /** Take a screenshot of a specific element */
  async screenshotElement(locator: Locator, name?: string): Promise<Buffer> {
    return await locator.screenshot({
      path: name ? `screenshots/${name}.png` : undefined,
    });
  }

  // --- Test ID Utilities ---

  /** Get a locator by data-testid attribute */
  getByTestId(testId: string): Locator {
    return this.page.getByTestId(testId);
  }

  /** Get text content from an element by test ID */
  async getTextByTestId(testId: string): Promise<string> {
    return await this.page.getByTestId(testId).innerText();
  }

  /** Assert element with test ID is visible */
  async expectTestIdVisible(testId: string): Promise<void> {
    await expect(this.page.getByTestId(testId)).toBeVisible();
  }

  /** Assert element with test ID has specific text */
  async expectTestIdText(testId: string, text: string | RegExp): Promise<void> {
    await expect(this.page.getByTestId(testId)).toHaveText(text);
  }

  // --- Waiting Helpers ---

  /** Wait for a loading indicator to disappear */
  async waitForLoading(
    selector: string = '[data-testid="loading"]',
    timeout: number = 10_000,
  ): Promise<void> {
    const spinner = this.page.locator(selector);
    if (await spinner.isVisible()) {
      await spinner.waitFor({ state: 'hidden', timeout });
    }
  }

  /** Wait for a network response matching the URL pattern */
  async waitForAPI(urlPattern: string | RegExp): Promise<Response> {
    const response = await this.page.waitForResponse(
      resp => typeof urlPattern === 'string'
        ? resp.url().includes(urlPattern)
        : urlPattern.test(resp.url()),
    );
    return response as unknown as Response;
  }

  // --- Assertions ---

  /** Assert the page title matches expected text */
  async expectTitle(title: string | RegExp): Promise<void> {
    await expect(this.page).toHaveTitle(title);
  }

  /** Assert an element with the given role is visible */
  async expectRoleVisible(
    role: Parameters<Page['getByRole']>[0],
    options?: Parameters<Page['getByRole']>[1],
  ): Promise<void> {
    await expect(this.page.getByRole(role, options)).toBeVisible();
  }

  /** Assert text is visible on the page */
  async expectTextVisible(text: string | RegExp): Promise<void> {
    await expect(this.page.getByText(text)).toBeVisible();
  }

  /** Assert text is NOT visible on the page */
  async expectTextHidden(text: string | RegExp): Promise<void> {
    await expect(this.page.getByText(text)).not.toBeVisible();
  }

  // --- Interaction Helpers ---

  /** Click a button by its accessible name */
  async clickButton(name: string | RegExp): Promise<void> {
    await this.page.getByRole('button', { name }).click();
  }

  /** Click a link by its accessible name */
  async clickLink(name: string | RegExp): Promise<void> {
    await this.page.getByRole('link', { name }).click();
  }

  /** Fill a form field by its label */
  async fillByLabel(label: string | RegExp, value: string): Promise<void> {
    await this.page.getByLabel(label).fill(value);
  }

  /** Select an option from a dropdown by its label */
  async selectByLabel(
    label: string | RegExp,
    value: string | string[],
  ): Promise<void> {
    await this.page.getByLabel(label).selectOption(value);
  }

  /** Check a checkbox by its label */
  async checkByLabel(label: string | RegExp): Promise<void> {
    await this.page.getByLabel(label).check();
  }

  /** Uncheck a checkbox by its label */
  async uncheckByLabel(label: string | RegExp): Promise<void> {
    await this.page.getByLabel(label).uncheck();
  }

  // --- Network Helpers ---

  /** Mock an API endpoint with a JSON response */
  async mockAPI(
    urlPattern: string,
    response: { status?: number; body: unknown },
  ): Promise<void> {
    await this.page.route(urlPattern, (route) =>
      route.fulfill({
        status: response.status ?? 200,
        contentType: 'application/json',
        body: JSON.stringify(response.body),
      }),
    );
  }

  /** Block requests matching a pattern (analytics, ads, etc.) */
  async blockRequests(...patterns: string[]): Promise<void> {
    for (const pattern of patterns) {
      await this.page.route(pattern, (route) => route.abort());
    }
  }

  // --- Debug ---

  /** Pause execution and open the Playwright inspector */
  async pause(): Promise<void> {
    await this.page.pause();
  }

  /** Get the current page URL */
  get currentURL(): string {
    return this.page.url();
  }
}
