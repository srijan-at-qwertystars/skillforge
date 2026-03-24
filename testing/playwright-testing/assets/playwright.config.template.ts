import { defineConfig, devices } from '@playwright/test';

/**
 * Production-ready Playwright configuration template.
 *
 * Features:
 * - Cross-browser projects: Chromium, Firefox, WebKit
 * - CI detection with adjusted retries, workers, and reporters
 * - Auth setup project with storageState
 * - Trace/screenshot/video capture on failures
 * - Web server auto-start
 * - Sensible timeout hierarchy
 *
 * Usage:
 *   1. Copy to your project root as playwright.config.ts
 *   2. Update baseURL, webServer command, and auth paths
 *   3. Adjust browser projects as needed
 *
 * @see https://playwright.dev/docs/test-configuration
 */
export default defineConfig({
  /* ── Test Discovery ──────────────────────────────────────── */
  testDir: './tests',
  testIgnore: ['**/fixtures/**', '**/helpers/**'],

  /* ── Timeouts ────────────────────────────────────────────── */
  timeout: 30_000,
  expect: {
    timeout: 5_000,
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.01,
      animations: 'disabled',
    },
    toMatchSnapshot: {
      maxDiffPixelRatio: 0.01,
    },
  },

  /* ── Execution ───────────────────────────────────────────── */
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,

  /* ── Reporters ───────────────────────────────────────────── */
  reporter: process.env.CI
    ? [
        ['blob'],
        ['html', { open: 'never' }],
        ['junit', { outputFile: 'test-results/junit.xml' }],
      ]
    : [['html', { open: 'on-failure' }]],

  /* ── Shared Settings ─────────────────────────────────────── */
  use: {
    baseURL: process.env.BASE_URL || 'http://localhost:3000',

    /* Artifact capture */
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'on-first-retry',

    /* Action timeouts */
    actionTimeout: 10_000,
    navigationTimeout: 15_000,

    /* Locale and timezone (uncomment to customize) */
    // locale: 'en-US',
    // timezoneId: 'America/New_York',
    // colorScheme: 'light',
  },

  /* ── Projects ────────────────────────────────────────────── */
  projects: [
    /* Auth setup — runs before browser projects */
    {
      name: 'setup',
      testMatch: /.*\.setup\.ts/,
    },

    /* Desktop browsers */
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        storageState: 'playwright/.auth/user.json',
      },
      dependencies: ['setup'],
    },
    {
      name: 'firefox',
      use: {
        ...devices['Desktop Firefox'],
        storageState: 'playwright/.auth/user.json',
      },
      dependencies: ['setup'],
    },
    {
      name: 'webkit',
      use: {
        ...devices['Desktop Safari'],
        storageState: 'playwright/.auth/user.json',
      },
      dependencies: ['setup'],
    },

    /* Mobile viewports (uncomment as needed) */
    // {
    //   name: 'mobile-chrome',
    //   use: {
    //     ...devices['Pixel 7'],
    //     storageState: 'playwright/.auth/user.json',
    //   },
    //   dependencies: ['setup'],
    // },
    // {
    //   name: 'mobile-safari',
    //   use: {
    //     ...devices['iPhone 14'],
    //     storageState: 'playwright/.auth/user.json',
    //   },
    //   dependencies: ['setup'],
    // },

    /* Branded browsers (uncomment as needed) */
    // {
    //   name: 'edge',
    //   use: { ...devices['Desktop Edge'], channel: 'msedge' },
    //   dependencies: ['setup'],
    // },
    // {
    //   name: 'chrome',
    //   use: { ...devices['Desktop Chrome'], channel: 'chrome' },
    //   dependencies: ['setup'],
    // },

    /* Guest/unauthenticated tests (no storageState) */
    // {
    //   name: 'guest-tests',
    //   testMatch: /.*\.guest\.spec\.ts/,
    //   use: { ...devices['Desktop Chrome'], storageState: { cookies: [], origins: [] } },
    // },
  ],

  /* ── Web Server ──────────────────────────────────────────── */
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: 'pipe',
    stderr: 'pipe',
  },
});
