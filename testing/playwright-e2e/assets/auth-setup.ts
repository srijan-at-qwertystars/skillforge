import { test as setup, expect } from '@playwright/test';

/**
 * Authentication setup fixture using storageState.
 *
 * This file runs as a "setup" project before browser-specific test projects.
 * It performs login and saves the authenticated session to a JSON file,
 * which other projects load via `storageState` in their config.
 *
 * Config requirement (playwright.config.ts):
 *   projects: [
 *     { name: 'setup', testMatch: /.*\.setup\.ts/ },
 *     {
 *       name: 'chromium',
 *       use: { storageState: 'playwright/.auth/user.json' },
 *       dependencies: ['setup'],
 *     },
 *   ]
 *
 * Remember to add `playwright/.auth/` to .gitignore.
 */

// ---------------------------------------------------------------------------
// Configuration — adjust these for your application
// ---------------------------------------------------------------------------

const AUTH_FILE = 'playwright/.auth/user.json';

// Default credentials (override via environment variables)
const DEFAULT_EMAIL = process.env.TEST_USER_EMAIL || 'testuser@example.com';
const DEFAULT_PASSWORD = process.env.TEST_USER_PASSWORD || 'test-password-123';

// ---------------------------------------------------------------------------
// Standard user authentication
// ---------------------------------------------------------------------------

setup('authenticate as standard user', async ({ page }) => {
  // 1. Navigate to login page
  await page.goto('/login');

  // 2. Fill credentials
  await page.getByLabel('Email').fill(DEFAULT_EMAIL);
  await page.getByLabel('Password').fill(DEFAULT_PASSWORD);

  // 3. Submit login form
  await page.getByRole('button', { name: /sign in|log in/i }).click();

  // 4. Wait for successful authentication
  //    Adjust the URL pattern to match your app's post-login redirect
  await expect(page).toHaveURL(/\/(dashboard|home|app)/, { timeout: 15_000 });

  // 5. Verify authentication succeeded
  //    Add checks specific to your app (e.g., user avatar, welcome message)
  // await expect(page.getByTestId('user-menu')).toBeVisible();

  // 6. Save authenticated state
  await page.context().storageState({ path: AUTH_FILE });
});

// ---------------------------------------------------------------------------
// Admin user authentication (optional — use a separate storageState file)
// ---------------------------------------------------------------------------

/*
const ADMIN_AUTH_FILE = 'playwright/.auth/admin.json';

setup('authenticate as admin', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill(process.env.TEST_ADMIN_EMAIL || 'admin@example.com');
  await page.getByLabel('Password').fill(process.env.TEST_ADMIN_PASSWORD || 'admin-password');
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).toHaveURL(/\/admin/, { timeout: 15_000 });
  await page.context().storageState({ path: ADMIN_AUTH_FILE });
});
*/

// ---------------------------------------------------------------------------
// API-based authentication (faster — no browser rendering)
// ---------------------------------------------------------------------------

/*
setup('authenticate via API', async ({ request }) => {
  const response = await request.post('/api/auth/login', {
    data: {
      email: DEFAULT_EMAIL,
      password: DEFAULT_PASSWORD,
    },
  });

  expect(response.ok()).toBeTruthy();

  // If your API returns a token, you may need to save it differently.
  // For cookie-based auth, the request context already has the cookies.
  await request.storageState({ path: AUTH_FILE });
});
*/

// ---------------------------------------------------------------------------
// OAuth / SSO authentication (bypass with API token)
// ---------------------------------------------------------------------------

/*
setup('authenticate with OAuth bypass', async ({ page }) => {
  // For OAuth flows, you typically:
  // 1. Call an API to create a test session directly
  // 2. Set cookies/localStorage manually
  // 3. Or use a test-only login endpoint

  const response = await page.request.post('/api/test/create-session', {
    data: { userId: 'test-user-id', role: 'user' },
  });

  const { sessionToken } = await response.json();

  // Set the session cookie
  await page.context().addCookies([{
    name: 'session',
    value: sessionToken,
    domain: 'localhost',
    path: '/',
  }]);

  // Verify it works
  await page.goto('/dashboard');
  await expect(page).toHaveURL(/\/dashboard/);

  await page.context().storageState({ path: AUTH_FILE });
});
*/
