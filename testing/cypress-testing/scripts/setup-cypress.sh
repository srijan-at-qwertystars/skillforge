#!/usr/bin/env bash
set -euo pipefail

# setup-cypress.sh — Sets up Cypress in an existing project.
# Usage: ./setup-cypress.sh [--typescript] [--component] [--ci]
#
# Options:
#   --typescript   Use TypeScript configuration (default: JavaScript)
#   --component    Include component testing setup
#   --ci           Add GitHub Actions workflow for Cypress

TYPESCRIPT=false
COMPONENT=false
CI_SETUP=false

for arg in "$@"; do
  case "$arg" in
    --typescript) TYPESCRIPT=true ;;
    --component)  COMPONENT=true ;;
    --ci)         CI_SETUP=true ;;
    -h|--help)
      echo "Usage: $0 [--typescript] [--component] [--ci]"
      echo ""
      echo "Sets up Cypress in an existing project."
      echo ""
      echo "Options:"
      echo "  --typescript   Use TypeScript configuration"
      echo "  --component    Include component testing setup"
      echo "  --ci           Add GitHub Actions workflow"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# Check for package.json
if [ ! -f "package.json" ]; then
  echo "Error: No package.json found. Run this from your project root."
  exit 1
fi

echo "🔧 Setting up Cypress..."

# Detect package manager
if [ -f "pnpm-lock.yaml" ]; then
  PM="pnpm"
  INSTALL_CMD="pnpm add -D"
elif [ -f "yarn.lock" ]; then
  PM="yarn"
  INSTALL_CMD="yarn add -D"
else
  PM="npm"
  INSTALL_CMD="npm install --save-dev"
fi

echo "📦 Using $PM as package manager"

# Install Cypress
echo "📥 Installing Cypress..."
$INSTALL_CMD cypress

if [ "$TYPESCRIPT" = true ]; then
  echo "📥 Installing TypeScript dependencies..."
  $INSTALL_CMD typescript @types/node
fi

# Create directory structure
echo "📁 Creating directory structure..."
mkdir -p cypress/e2e
mkdir -p cypress/fixtures
mkdir -p cypress/support
mkdir -p cypress/downloads

# Create Cypress config
if [ "$TYPESCRIPT" = true ]; then
  CONFIG_FILE="cypress.config.ts"
  cat > "$CONFIG_FILE" << 'EOF'
import { defineConfig } from 'cypress';

export default defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',
    viewportWidth: 1280,
    viewportHeight: 720,
    defaultCommandTimeout: 10000,
    video: false,
    screenshotOnRunFailure: true,
    retries: {
      runMode: 2,
      openMode: 0,
    },
    setupNodeEvents(on, config) {
      // Register plugins here
      return config;
    },
  },
});
EOF
else
  CONFIG_FILE="cypress.config.js"
  cat > "$CONFIG_FILE" << 'EOF'
const { defineConfig } = require('cypress');

module.exports = defineConfig({
  e2e: {
    baseUrl: 'http://localhost:3000',
    viewportWidth: 1280,
    viewportHeight: 720,
    defaultCommandTimeout: 10000,
    video: false,
    screenshotOnRunFailure: true,
    retries: {
      runMode: 2,
      openMode: 0,
    },
    setupNodeEvents(on, config) {
      // Register plugins here
      return config;
    },
  },
});
EOF
fi

echo "✅ Created $CONFIG_FILE"

# Create support files
if [ "$TYPESCRIPT" = true ]; then
  cat > cypress/support/e2e.ts << 'EOF'
// Support file for E2E tests — loaded before every spec
import './commands';
EOF

  cat > cypress/support/commands.ts << 'EOF'
// Custom commands
// See: https://on.cypress.io/custom-commands

Cypress.Commands.add('getByDataCy', (selector: string) => {
  return cy.get(`[data-cy="${selector}"]`);
});

Cypress.Commands.add('login', (email: string, password: string) => {
  cy.session([email, password], () => {
    cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
      window.localStorage.setItem('token', resp.body.token);
    });
  });
});

// TypeScript declarations
declare global {
  namespace Cypress {
    interface Chainable {
      getByDataCy(selector: string): Chainable<JQuery<HTMLElement>>;
      login(email: string, password: string): Chainable<void>;
    }
  }
}

export {};
EOF

  cat > cypress/tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "types": ["cypress"],
    "moduleResolution": "node",
    "strict": true,
    "esModuleInterop": true
  },
  "include": ["**/*.ts"]
}
EOF

  echo "✅ Created TypeScript support files"
else
  cat > cypress/support/e2e.js << 'EOF'
// Support file for E2E tests — loaded before every spec
import './commands';
EOF

  cat > cypress/support/commands.js << 'EOF'
// Custom commands
// See: https://on.cypress.io/custom-commands

Cypress.Commands.add('getByDataCy', (selector) => {
  return cy.get(`[data-cy="${selector}"]`);
});

Cypress.Commands.add('login', (email, password) => {
  cy.session([email, password], () => {
    cy.request('POST', '/api/auth/login', { email, password }).then((resp) => {
      window.localStorage.setItem('token', resp.body.token);
    });
  });
});
EOF

  echo "✅ Created JavaScript support files"
fi

# Create example fixture
cat > cypress/fixtures/example.json << 'EOF'
{
  "users": [
    { "id": 1, "name": "Alice", "email": "alice@example.com" },
    { "id": 2, "name": "Bob", "email": "bob@example.com" }
  ]
}
EOF

echo "✅ Created example fixture"

# Create example E2E spec
EXT=$( [ "$TYPESCRIPT" = true ] && echo "ts" || echo "js" )

cat > "cypress/e2e/home.cy.$EXT" << EOF
describe('Home Page', () => {
  beforeEach(() => {
    cy.visit('/');
  });

  it('should load the home page', () => {
    cy.url().should('include', '/');
  });

  it('should display the main heading', () => {
    cy.get('h1').should('be.visible');
  });
});
EOF

echo "✅ Created example spec: cypress/e2e/home.cy.$EXT"

# Component testing setup
if [ "$COMPONENT" = true ]; then
  echo "🧩 Setting up component testing..."

  if [ "$TYPESCRIPT" = true ]; then
    cat > cypress/support/component.ts << 'EOF'
import './commands';

// Component testing support
// Uncomment and configure for your framework:
// import { mount } from 'cypress/react18';
// Cypress.Commands.add('mount', mount);
//
// declare global {
//   namespace Cypress {
//     interface Chainable {
//       mount: typeof mount;
//     }
//   }
// }
EOF
  else
    cat > cypress/support/component.js << 'EOF'
import './commands';

// Component testing support
// Uncomment and configure for your framework:
// import { mount } from 'cypress/react18';
// Cypress.Commands.add('mount', mount);
EOF
  fi

  echo "✅ Created component testing support file"
  echo "⚠️  Uncomment and configure the mount command for your framework (React, Vue, etc.)"
fi

# GitHub Actions CI setup
if [ "$CI_SETUP" = true ]; then
  echo "🚀 Setting up GitHub Actions..."
  mkdir -p .github/workflows

  cat > .github/workflows/cypress.yml << 'EOF'
name: Cypress Tests
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  cypress:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Cache Cypress binary
        uses: actions/cache@v4
        with:
          path: ~/.cache/Cypress
          key: cypress-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

      - uses: cypress-io/github-action@v6
        with:
          build: npm run build
          start: npm run start
          wait-on: 'http://localhost:3000'
          browser: chrome

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-screenshots
          path: cypress/screenshots
          retention-days: 7

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-videos
          path: cypress/videos
          retention-days: 7
EOF

  echo "✅ Created .github/workflows/cypress.yml"
fi

# Add scripts to package.json (using node for JSON manipulation)
echo "📝 Adding npm scripts..."
node -e "
  const pkg = require('./package.json');
  pkg.scripts = pkg.scripts || {};
  pkg.scripts['cy:open'] = pkg.scripts['cy:open'] || 'cypress open';
  pkg.scripts['cy:run'] = pkg.scripts['cy:run'] || 'cypress run';
  pkg.scripts['cy:run:chrome'] = pkg.scripts['cy:run:chrome'] || 'cypress run --browser chrome';
  require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
" 2>/dev/null || echo "⚠️  Could not add scripts to package.json (manual step needed)"

# Update .gitignore
if [ -f ".gitignore" ]; then
  if ! grep -q "cypress/videos" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Cypress" >> .gitignore
    echo "cypress/videos" >> .gitignore
    echo "cypress/screenshots" >> .gitignore
    echo "cypress/downloads" >> .gitignore
    echo "✅ Updated .gitignore"
  fi
fi

echo ""
echo "✨ Cypress setup complete!"
echo ""
echo "Next steps:"
echo "  1. Open Cypress:    $PM run cy:open"
echo "  2. Run tests:       $PM run cy:run"
echo "  3. Edit config:     $CONFIG_FILE"
echo "  4. Add tests in:    cypress/e2e/"
echo "  5. Add commands in: cypress/support/commands.$EXT"
