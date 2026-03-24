import { chromium, type FullConfig } from '@playwright/test';

/**
 * Global setup for Playwright test suites.
 *
 * Authenticates as a default user and saves browser storage state
 * (cookies, localStorage, sessionStorage) to a JSON file.
 * Tests then reuse this state via storageState in playwright.config.ts,
 * eliminating the need to log in before each test.
 *
 * Usage in playwright.config.ts:
 *   globalSetup: require.resolve('./global-setup'),
 *   use: { storageState: 'playwright/.auth/user.json' },
 *
 * Environment variables:
 *   TEST_USER_EMAIL    — Login email (default: test@example.com)
 *   TEST_USER_PASSWORD — Login password (default: password)
 *   BASE_URL           — Application base URL (default: http://localhost:3000)
 */

const AUTH_FILE = 'playwright/.auth/user.json';

async function globalSetup(config: FullConfig) {
  const baseURL = config.projects[0]?.use?.baseURL
    || process.env.BASE_URL
    || 'http://localhost:3000';

  const email = process.env.TEST_USER_EMAIL || 'test@example.com';
  const password = process.env.TEST_USER_PASSWORD || 'password';

  const browser = await chromium.launch();
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    // Navigate to login page
    await page.goto(`${baseURL}/login`);

    // Fill credentials and submit
    await page.getByLabel('Email').fill(email);
    await page.getByLabel('Password').fill(password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();

    // Wait for successful authentication
    await page.waitForURL('**/dashboard', { timeout: 15_000 });

    // Save authenticated state
    await context.storageState({ path: AUTH_FILE });
    console.log(`✓ Auth state saved to ${AUTH_FILE}`);
  } catch (error) {
    console.error('Global setup authentication failed:', error);
    throw error;
  } finally {
    await browser.close();
  }
}

export default globalSetup;
