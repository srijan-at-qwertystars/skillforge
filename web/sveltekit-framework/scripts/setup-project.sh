#!/usr/bin/env bash
# setup-project.sh — Bootstrap a SvelteKit project with Svelte 5, Tailwind CSS,
# TypeScript, testing (Vitest + Playwright), and recommended configuration.
#
# Usage:
#   ./setup-project.sh <project-name> [directory]
#
# Examples:
#   ./setup-project.sh my-app
#   ./setup-project.sh my-app ./projects/my-app
#
# Creates a new SvelteKit project with:
#   - Svelte 5 + SvelteKit 2
#   - TypeScript (strict)
#   - Tailwind CSS 4
#   - Vitest for unit tests
#   - Playwright for E2E tests
#   - ESLint + Prettier
#   - Recommended project structure

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

usage() {
    echo "Usage: $0 <project-name> [directory]"
    echo ""
    echo "Arguments:"
    echo "  project-name   Name of the project (used for package.json)"
    echo "  directory       Target directory (default: ./<project-name>)"
    exit 1
}

# --- Argument Validation ---
if [[ $# -lt 1 ]]; then
    error "Missing required argument: project-name"
    usage
fi

PROJECT_NAME="$1"
PROJECT_DIR="${2:-./$PROJECT_NAME}"

if [[ "$PROJECT_NAME" =~ [^a-zA-Z0-9_-] ]]; then
    error "Project name must contain only alphanumeric characters, hyphens, and underscores."
    exit 1
fi

if [[ -d "$PROJECT_DIR" ]]; then
    error "Directory '$PROJECT_DIR' already exists. Remove it or choose a different name."
    exit 1
fi

# --- Check Prerequisites ---
for cmd in node npm npx; do
    if ! command -v "$cmd" &>/dev/null; then
        error "'$cmd' is required but not found. Install Node.js 18+ first."
        exit 1
    fi
done

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [[ "$NODE_VERSION" -lt 18 ]]; then
    error "Node.js 18+ is required (found v${NODE_VERSION})."
    exit 1
fi

log "Creating SvelteKit project: $PROJECT_NAME"
log "Directory: $PROJECT_DIR"

# --- Scaffold with sv create ---
log "Scaffolding with npx sv create..."
npx --yes sv create "$PROJECT_DIR" \
    --template minimal \
    --types ts \
    --no-install \
    --no-add-ons

cd "$PROJECT_DIR"

# --- Install Core Dependencies ---
log "Installing dependencies..."
npm install

# --- Add Tailwind CSS via sv add ---
log "Adding Tailwind CSS..."
npx --yes sv add tailwindcss --no-install

# --- Add Testing ---
log "Adding Vitest and Playwright..."
npm install -D vitest @testing-library/svelte @testing-library/jest-dom jsdom
npm install -D @playwright/test

# --- Add Linting / Formatting ---
log "Adding ESLint and Prettier..."
npx --yes sv add eslint --no-install
npx --yes sv add prettier --no-install
npm install

# --- Create Recommended Directory Structure ---
log "Creating project structure..."
mkdir -p src/lib/components
mkdir -p src/lib/server
mkdir -p src/lib/stores
mkdir -p src/lib/utils
mkdir -p src/lib/types
mkdir -p tests

# --- Create vitest config ---
if [[ ! -f vitest.config.ts ]]; then
    cat > vitest.config.ts << 'VITEST_EOF'
import { defineConfig } from 'vitest/config';
import { sveltekit } from '@sveltejs/kit/vite';

export default defineConfig({
    plugins: [sveltekit()],
    test: {
        include: ['src/**/*.test.ts'],
        environment: 'jsdom',
        setupFiles: [],
    },
});
VITEST_EOF
    log "Created vitest.config.ts"
fi

# --- Create example test ---
cat > src/lib/utils/index.ts << 'UTILS_EOF'
/**
 * Format a date string to a human-readable format.
 */
export function formatDate(date: string | Date): string {
    return new Intl.DateTimeFormat('en-US', {
        year: 'numeric',
        month: 'long',
        day: 'numeric',
    }).format(new Date(date));
}
UTILS_EOF

cat > src/lib/utils/index.test.ts << 'TEST_EOF'
import { describe, it, expect } from 'vitest';
import { formatDate } from './index';

describe('formatDate', () => {
    it('formats an ISO date string', () => {
        expect(formatDate('2024-01-15')).toBe('January 15, 2024');
    });

    it('formats a Date object', () => {
        expect(formatDate(new Date('2024-06-01'))).toBe('June 1, 2024');
    });
});
TEST_EOF
log "Created example utility and test"

# --- Create example Playwright test ---
cat > tests/home.test.ts << 'E2E_EOF'
import { test, expect } from '@playwright/test';

test('homepage has expected content', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle(/./);
});
E2E_EOF
log "Created example E2E test"

# --- Add npm scripts ---
log "Updating package.json scripts..."
npx --yes json -I -f package.json \
    -e 'this.scripts.test = "vitest run"' \
    -e 'this.scripts["test:watch"] = "vitest"' \
    -e 'this.scripts["test:e2e"] = "playwright test"' \
    -e 'this.scripts["test:all"] = "vitest run && playwright test"' \
    2>/dev/null || {
    warn "Could not auto-update package.json scripts. Add test scripts manually."
}

# --- Final install to ensure lockfile is consistent ---
npm install

# --- Summary ---
echo ""
log "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "  cd $PROJECT_DIR"
echo "  npm run dev         # Start dev server"
echo "  npm run build       # Production build"
echo "  npm run test        # Run unit tests"
echo "  npm run test:e2e    # Run E2E tests"
echo "  npm run lint        # Lint code"
echo "  npm run format      # Format code"
echo ""
