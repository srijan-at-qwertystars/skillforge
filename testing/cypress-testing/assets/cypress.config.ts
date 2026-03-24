import { defineConfig } from 'cypress';

export default defineConfig({
  // ─── E2E Testing ───────────────────────────────────────────────
  e2e: {
    baseUrl: process.env.CYPRESS_BASE_URL || 'http://localhost:3000',
    specPattern: 'cypress/e2e/**/*.cy.{js,ts}',
    supportFile: 'cypress/support/e2e.ts',

    // Viewport
    viewportWidth: 1280,
    viewportHeight: 720,

    // Timeouts
    defaultCommandTimeout: 10000,
    requestTimeout: 10000,
    responseTimeout: 30000,
    pageLoadTimeout: 60000,

    // Retries (CI gets retries, local dev does not)
    retries: {
      runMode: 2,   // `cypress run` (CI)
      openMode: 0,  // `cypress open` (dev)
    },

    // Media
    video: false,
    screenshotOnRunFailure: true,
    screenshotsFolder: 'cypress/screenshots',
    videosFolder: 'cypress/videos',
    downloadsFolder: 'cypress/downloads',

    // Test isolation
    testIsolation: true,

    // Performance
    experimentalMemoryManagement: true,
    numTestsKeptInMemory: 5,

    // Security — disable if testing cross-origin
    chromeWebSecurity: true,

    // Environment variables (override via CLI or cypress.env.json)
    env: {
      apiUrl: 'http://localhost:4000/api',
      coverage: false,
    },

    setupNodeEvents(on, config) {
      // Code coverage
      // require('@cypress/code-coverage/task')(on, config);

      // Log browser console to terminal
      on('task', {
        log(message: string) {
          console.log(message);
          return null;
        },
        table(message: string) {
          console.table(message);
          return null;
        },
      });

      // Load env-specific config
      const envFile = config.env.configFile || 'development';
      try {
        const envConfig = require(`./cypress/config/${envFile}.json`);
        return { ...config, ...envConfig };
      } catch {
        return config;
      }
    },
  },

  // ─── Component Testing ─────────────────────────────────────────
  component: {
    devServer: {
      framework: 'react',
      bundler: 'vite',
    },
    specPattern: 'src/**/*.cy.{js,ts,jsx,tsx}',
    supportFile: 'cypress/support/component.ts',

    // Component tests use smaller viewport
    viewportWidth: 500,
    viewportHeight: 500,

    // Faster timeouts for isolated components
    defaultCommandTimeout: 5000,

    retries: {
      runMode: 1,
      openMode: 0,
    },
  },
});
