import { defineConfig, devices } from '@playwright/test';

/**
 * Production-ready Playwright configuration.
 *
 * Features:
 * - Multiple browser projects (desktop + mobile)
 * - Retries with trace capture on first retry
 * - HTML reporter with open-on-failure
 * - Web server auto-start
 * - Screenshot on failure
 * - Sensible timeouts for CI and local dev
 *
 * @see https://playwright.dev/docs/test-configuration
 */
export default defineConfig({
  /* Directory containing test files */
  testDir: './tests',

  /* Maximum time one test can run */
  timeout: 30_000,

  /* Assertion-level timeout */
  expect: {
    timeout: 5_000,
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.01,
    },
  },

  /* Run tests in files in parallel */
  fullyParallel: true,

  /* Fail the build on CI if test.only is left in source */
  forbidOnly: !!process.env.CI,

  /* Retry failed tests — 2 times on CI, 0 locally */
  retries: process.env.CI ? 2 : 0,

  /* Limit parallel workers on CI for stability */
  workers: process.env.CI ? 1 : undefined,

  /* Reporter configuration */
  reporter: process.env.CI
    ? [
        ['blob'],
        ['html', { open: 'never' }],
        ['junit', { outputFile: 'test-results/junit.xml' }],
      ]
    : [['html', { open: 'on-failure' }]],

  /* Shared settings for all projects */
  use: {
    /* Base URL for page.goto('/path') */
    baseURL: process.env.BASE_URL || 'http://localhost:3000',

    /* Collect trace on first retry for debugging */
    trace: 'on-first-retry',

    /* Screenshot on failure */
    screenshot: 'only-on-failure',

    /* Video on first retry */
    video: 'on-first-retry',

    /* Timeout for each action (click, fill, etc.) */
    actionTimeout: 10_000,

    /* Timeout for page navigations */
    navigationTimeout: 15_000,
  },

  /* Browser projects */
  projects: [
    /* --- Desktop Browsers --- */
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'firefox',
      use: { ...devices['Desktop Firefox'] },
    },
    {
      name: 'webkit',
      use: { ...devices['Desktop Safari'] },
    },

    /* --- Mobile Viewports --- */
    {
      name: 'mobile-chrome',
      use: { ...devices['Pixel 7'] },
    },
    {
      name: 'mobile-safari',
      use: { ...devices['iPhone 14'] },
    },
  ],

  /* Run local dev server before tests */
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
