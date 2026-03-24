import { defineConfig } from 'cypress';

export default defineConfig({
  // Cypress Cloud (optional — set projectId from cloud.cypress.io)
  // projectId: 'your-project-id',

  e2e: {
    baseUrl: process.env.CYPRESS_BASE_URL || 'http://localhost:3000',
    specPattern: 'cypress/e2e/**/*.cy.{js,jsx,ts,tsx}',
    supportFile: 'cypress/support/e2e.ts',

    // Viewport
    viewportWidth: 1280,
    viewportHeight: 720,

    // Timeouts
    defaultCommandTimeout: 10000,
    requestTimeout: 15000,
    responseTimeout: 30000,
    pageLoadTimeout: 60000,

    // Test isolation (Cypress 12+ default)
    testIsolation: true,

    // Retries
    retries: {
      runMode: 2,  // CI retries
      openMode: 0, // no retries in interactive mode
    },

    // Media
    video: !!process.env.CI,
    videoCompression: 32,
    screenshotOnRunFailure: true,
    trashAssetsBeforeRuns: true,

    // Experimental features
    experimentalRunAllSpecs: true,

    // Environment variables
    env: {
      apiUrl: process.env.API_URL || 'http://localhost:4000/api',
    },

    setupNodeEvents(on, config) {
      // Task for logging from tests
      on('task', {
        log(message: string) {
          console.log(message);
          return null;
        },
        table(data: Record<string, unknown>[]) {
          console.table(data);
          return null;
        },
      });

      // Code coverage (uncomment if using @cypress/code-coverage)
      // require('@cypress/code-coverage/task')(on, config);

      return config;
    },
  },

  component: {
    // Uncomment and configure for your framework:
    devServer: {
      framework: 'react',
      bundler: 'vite',
      // For webpack:
      // bundler: 'webpack',
      // webpackConfig: require('./webpack.config.js'),
    },
    specPattern: 'src/**/*.cy.{js,jsx,ts,tsx}',
    supportFile: 'cypress/support/component.ts',

    // Component-specific settings
    viewportWidth: 500,
    viewportHeight: 500,
    video: false,
  },

  // Folders
  downloadsFolder: 'cypress/downloads',
  fixturesFolder: 'cypress/fixtures',
  screenshotsFolder: 'cypress/screenshots',
  videosFolder: 'cypress/videos',

  // Memory optimization for large test suites
  numTestsKeptInMemory: process.env.CI ? 0 : 50,

  // Chrome flags for CI stability
  ...(process.env.CI && {
    chromeWebSecurity: false,
  }),
});
