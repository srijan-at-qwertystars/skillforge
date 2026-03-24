#!/usr/bin/env bash
# setup-cypress-project.sh — Set up Cypress in an existing Node.js project
# Usage: ./setup-cypress-project.sh [--component] [--framework react|vue|angular|svelte] [--bundler vite|webpack]
set -euo pipefail

# --- Defaults ---
COMPONENT=false
FRAMEWORK="react"
BUNDLER="vite"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --component) COMPONENT=true; shift ;;
    --framework) FRAMEWORK="$2"; shift 2 ;;
    --bundler) BUNDLER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--component] [--framework react|vue|angular|svelte] [--bundler vite|webpack]"
      echo ""
      echo "Options:"
      echo "  --component    Enable component testing setup"
      echo "  --framework    Frontend framework (default: react)"
      echo "  --bundler      Bundler to use (default: vite)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Verify prerequisites ---
if ! command -v node &>/dev/null; then
  echo "❌ Node.js is required. Install it first."
  exit 1
fi

if [ ! -f "package.json" ]; then
  echo "❌ No package.json found. Run this from your project root."
  exit 1
fi

echo "🔧 Setting up Cypress in $(pwd)"
echo "   Framework: $FRAMEWORK | Bundler: $BUNDLER | Component testing: $COMPONENT"

# --- Install dependencies ---
echo ""
echo "📦 Installing Cypress and TypeScript..."
npm install --save-dev cypress typescript @types/node

if [ "$COMPONENT" = true ]; then
  echo "📦 Installing component testing dependencies..."
  case "$FRAMEWORK" in
    react) npm install --save-dev @cypress/react ;;
    vue) npm install --save-dev @cypress/vue ;;
    angular) npm install --save-dev @cypress/angular ;;
    svelte) npm install --save-dev @cypress/svelte ;;
  esac
fi

# --- Create directory structure ---
echo ""
echo "📁 Creating directory structure..."
mkdir -p cypress/e2e
mkdir -p cypress/fixtures
mkdir -p cypress/support
mkdir -p cypress/downloads

# --- Create cypress.config.ts ---
echo ""
echo "📝 Creating cypress.config.ts..."

COMPONENT_CONFIG=""
if [ "$COMPONENT" = true ]; then
  COMPONENT_CONFIG="
  component: {
    devServer: {
      framework: '${FRAMEWORK}',
      bundler: '${BUNDLER}',
    },
    specPattern: 'src/**/*.cy.{js,ts,jsx,tsx}',
    supportFile: 'cypress/support/component.ts',
  },"
fi

cat > cypress.config.ts << CYCONFIG
import { defineConfig } from 'cypress';

export default defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',
    specPattern: 'cypress/e2e/**/*.cy.{js,ts}',
    supportFile: 'cypress/support/e2e.ts',
    viewportWidth: 1280,
    viewportHeight: 720,
    video: false,
    screenshotOnRunFailure: true,
    retries: { runMode: 2, openMode: 0 },
    defaultCommandTimeout: 10000,
    requestTimeout: 10000,
    setupNodeEvents(on, config) {
      return config;
    },
  },${COMPONENT_CONFIG}
});
CYCONFIG

# --- Create TypeScript config for Cypress ---
echo "📝 Creating cypress/tsconfig.json..."
cat > cypress/tsconfig.json << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2020",
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "types": ["cypress"],
    "baseUrl": "..",
    "strict": true,
    "moduleResolution": "node",
    "esModuleInterop": true,
    "jsx": "react-jsx",
    "skipLibCheck": true
  },
  "include": ["**/*.ts", "**/*.tsx", "../node_modules/cypress"]
}
TSCONFIG

# --- Create support files ---
echo "📝 Creating support files..."

cat > cypress/support/e2e.ts << 'E2ESUPPORT'
import './commands';

Cypress.on('uncaught:exception', (err) => {
  // Return false to prevent Cypress from failing the test on uncaught exceptions
  // Remove or modify this handler based on your needs
  if (err.message.includes('ResizeObserver loop')) {
    return false;
  }
});

Cypress.SelectorPlayground.defaults({
  selectorPriority: ['data-cy', 'data-testid', 'id', 'class', 'tag'],
});
E2ESUPPORT

cat > cypress/support/commands.ts << 'COMMANDS'
declare global {
  namespace Cypress {
    interface Chainable {
      /**
       * Select element by data-cy attribute
       * @example cy.getByCy('submit-button')
       */
      getByCy(selector: string): Chainable<JQuery<HTMLElement>>;

      /**
       * Login via API and cache session
       * @example cy.login('user@test.com', 'password')
       */
      login(email: string, password: string): Chainable<void>;
    }
  }
}

Cypress.Commands.add('getByCy', (selector: string) => {
  return cy.get(`[data-cy="${selector}"]`);
});

Cypress.Commands.add('login', (email: string, password: string) => {
  cy.session(
    [email, password],
    () => {
      cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
        window.localStorage.setItem('token', resp.body.token);
      });
    },
    {
      validate() {
        cy.request({
          url: '/api/auth/me',
          headers: { Authorization: `Bearer ${window.localStorage.getItem('token')}` },
        }).its('status').should('eq', 200);
      },
    }
  );
});

export {};
COMMANDS

if [ "$COMPONENT" = true ]; then
  cat > cypress/support/component.ts << 'COMPSUPPORT'
import './commands';

// Import global styles if needed
// import '../../src/index.css';

// Augment the Cypress namespace to include mount
declare global {
  namespace Cypress {
    interface Chainable {
      mount: typeof import('cypress/react18')['mount'];
    }
  }
}
COMPSUPPORT
fi

# --- Create fixture ---
echo "📝 Creating sample fixture..."
cat > cypress/fixtures/example.json << 'FIXTURE'
{
  "id": 1,
  "name": "Test User",
  "email": "test@example.com",
  "role": "admin"
}
FIXTURE

# --- Create first E2E spec ---
echo "📝 Creating first E2E spec..."
cat > cypress/e2e/smoke.cy.ts << 'SPEC'
describe('Smoke Test', () => {
  it('loads the home page', () => {
    cy.visit('/');
    cy.get('body').should('be.visible');
  });
});
SPEC

# --- Add npm scripts ---
echo ""
echo "📝 Adding npm scripts..."
npx --yes json -I -f package.json -e '
  this.scripts = this.scripts || {};
  this.scripts["cy:open"] = "cypress open";
  this.scripts["cy:run"] = "cypress run";
  this.scripts["cy:run:chrome"] = "cypress run --browser chrome";
  this.scripts["cy:run:headed"] = "cypress run --headed";
' 2>/dev/null || {
  echo "⚠️  Could not auto-add scripts. Add these to package.json manually:"
  echo '  "cy:open": "cypress open"'
  echo '  "cy:run": "cypress run"'
}

# --- Add cypress.env.json to .gitignore ---
if [ -f .gitignore ]; then
  if ! grep -q "cypress.env.json" .gitignore; then
    echo "" >> .gitignore
    echo "# Cypress" >> .gitignore
    echo "cypress.env.json" >> .gitignore
    echo "cypress/screenshots" >> .gitignore
    echo "cypress/videos" >> .gitignore
    echo "cypress/downloads" >> .gitignore
    echo "📝 Updated .gitignore"
  fi
fi

echo ""
echo "✅ Cypress setup complete!"
echo ""
echo "Next steps:"
echo "  1. npm run cy:open        — Open Cypress interactive runner"
echo "  2. npm run cy:run          — Run tests headlessly"
echo "  3. Edit cypress/e2e/smoke.cy.ts to add your first real test"
echo "  4. Add data-cy attributes to your app's elements"
echo ""
