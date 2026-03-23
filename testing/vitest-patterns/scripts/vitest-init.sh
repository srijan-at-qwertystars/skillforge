#!/usr/bin/env bash
# vitest-init.sh — Initialize Vitest in an existing project.
# Detects framework (React, Vue, Svelte, Node) and generates appropriate config.
# Usage: ./vitest-init.sh [--force]

set -euo pipefail

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

# Check for package.json
if [[ ! -f "package.json" ]]; then
  error "No package.json found. Run from project root."
  exit 1
fi

# Check if vitest is already installed
if grep -q '"vitest"' package.json 2>/dev/null && [[ "$FORCE" != true ]]; then
  warn "Vitest is already in package.json. Use --force to reinitialize."
  exit 0
fi

# Detect package manager
detect_pm() {
  if [[ -f "bun.lockb" ]] || [[ -f "bun.lock" ]]; then
    echo "bun"
  elif [[ -f "pnpm-lock.yaml" ]]; then
    echo "pnpm"
  elif [[ -f "yarn.lock" ]]; then
    echo "yarn"
  else
    echo "npm"
  fi
}

PM=$(detect_pm)
info "Detected package manager: $PM"

install_dev() {
  case "$PM" in
    bun)  bun add -d "$@" ;;
    pnpm) pnpm add -D "$@" ;;
    yarn) yarn add -D "$@" ;;
    npm)  npm install -D "$@" ;;
  esac
}

# Detect framework
FRAMEWORK="node"
ENVIRONMENT="node"
EXTRA_DEPS=()
EXTRA_CONFIG=""
SETUP_CONTENT=""

if grep -qE '"react"|"react-dom"' package.json 2>/dev/null; then
  FRAMEWORK="react"
  ENVIRONMENT="jsdom"
  EXTRA_DEPS+=("jsdom" "@testing-library/react" "@testing-library/jest-dom")
  info "Detected framework: React"
elif grep -qE '"vue"|"@vue/core"' package.json 2>/dev/null; then
  FRAMEWORK="vue"
  ENVIRONMENT="jsdom"
  EXTRA_DEPS+=("jsdom" "@testing-library/vue" "@testing-library/jest-dom")
  info "Detected framework: Vue"
elif grep -qE '"svelte"' package.json 2>/dev/null; then
  FRAMEWORK="svelte"
  ENVIRONMENT="jsdom"
  EXTRA_DEPS+=("jsdom" "@testing-library/svelte" "@testing-library/jest-dom")
  info "Detected framework: Svelte"
else
  info "Detected framework: Node.js (no UI framework found)"
fi

# Install dependencies
info "Installing vitest and dependencies..."
install_dev vitest @vitest/coverage-v8 "${EXTRA_DEPS[@]}"
ok "Dependencies installed"

# Create test setup directory
mkdir -p test

# Generate vitest.config.ts
if [[ -f "vitest.config.ts" ]] && [[ "$FORCE" != true ]]; then
  warn "vitest.config.ts already exists. Skipping. Use --force to overwrite."
else
  info "Generating vitest.config.ts..."

  PLUGINS_IMPORT=""
  PLUGINS_ARRAY=""

  if [[ "$FRAMEWORK" == "react" ]] && grep -q '"@vitejs/plugin-react"' package.json 2>/dev/null; then
    PLUGINS_IMPORT="import react from '@vitejs/plugin-react';"
    PLUGINS_ARRAY="  plugins: [react()],"
  elif [[ "$FRAMEWORK" == "vue" ]] && grep -q '"@vitejs/plugin-vue"' package.json 2>/dev/null; then
    PLUGINS_IMPORT="import vue from '@vitejs/plugin-vue';"
    PLUGINS_ARRAY="  plugins: [vue()],"
  fi

  cat > vitest.config.ts <<EOF
import { defineConfig } from 'vitest/config';
${PLUGINS_IMPORT}

export default defineConfig({
${PLUGINS_ARRAY}
  test: {
    include: ['src/**/*.{test,spec}.{ts,tsx,js,jsx}'],
    exclude: ['node_modules', 'dist', 'e2e'],
    environment: '${ENVIRONMENT}',
    globals: false,
    setupFiles: ['./test/setup.ts'],
    testTimeout: 5000,
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html', 'lcov'],
      include: ['src/**/*.{ts,tsx,js,jsx}'],
      exclude: [
        'src/**/*.{test,spec}.{ts,tsx,js,jsx}',
        'src/**/*.d.ts',
      ],
      thresholds: {
        lines: 80,
        functions: 80,
        branches: 75,
        statements: 80,
      },
    },
  },
});
EOF
  ok "Created vitest.config.ts"
fi

# Generate test setup file
if [[ -f "test/setup.ts" ]] && [[ "$FORCE" != true ]]; then
  warn "test/setup.ts already exists. Skipping."
else
  info "Generating test/setup.ts..."

  if [[ "$FRAMEWORK" == "react" ]]; then
    cat > test/setup.ts <<'EOF'
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach, vi } from 'vitest';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
EOF
  elif [[ "$FRAMEWORK" == "vue" ]]; then
    cat > test/setup.ts <<'EOF'
import '@testing-library/jest-dom/vitest';
import { afterEach, vi } from 'vitest';

afterEach(() => {
  vi.restoreAllMocks();
});
EOF
  elif [[ "$FRAMEWORK" == "svelte" ]]; then
    cat > test/setup.ts <<'EOF'
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/svelte';
import { afterEach, vi } from 'vitest';

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
EOF
  else
    cat > test/setup.ts <<'EOF'
import { afterEach, vi } from 'vitest';

afterEach(() => {
  vi.restoreAllMocks();
});
EOF
  fi
  ok "Created test/setup.ts"
fi

# Create example test
EXAMPLE_DIR="src"
[[ ! -d "$EXAMPLE_DIR" ]] && mkdir -p "$EXAMPLE_DIR"

if [[ ! -f "src/example.test.ts" ]]; then
  cat > src/example.test.ts <<'EOF'
import { describe, it, expect } from 'vitest';

describe('Example', () => {
  it('should pass', () => {
    expect(1 + 1).toBe(2);
  });
});
EOF
  ok "Created src/example.test.ts"
fi

# Update package.json scripts
info "Updating package.json scripts..."
if command -v node > /dev/null 2>&1; then
  node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
    pkg.scripts = pkg.scripts || {};
    pkg.scripts['test'] = 'vitest run';
    pkg.scripts['test:watch'] = 'vitest';
    pkg.scripts['test:coverage'] = 'vitest run --coverage';
    pkg.scripts['test:ui'] = 'vitest --ui';
    fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
  "
  ok "Updated package.json scripts"
else
  warn "Node.js not found — update package.json scripts manually:"
  echo '  "test": "vitest run"'
  echo '  "test:watch": "vitest"'
  echo '  "test:coverage": "vitest run --coverage"'
fi

echo ""
ok "Vitest initialized for ${FRAMEWORK} project!"
echo ""
info "Next steps:"
echo "  1. Run tests:     ${PM} test"
echo "  2. Watch mode:    ${PM} run test:watch"
echo "  3. Coverage:      ${PM} run test:coverage"
echo "  4. Remove Jest:   ${PM} uninstall jest ts-jest babel-jest @types/jest"
