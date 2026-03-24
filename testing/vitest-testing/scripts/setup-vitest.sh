#!/usr/bin/env bash
# setup-vitest.sh — Initialize Vitest in an existing project
#
# Usage:
#   ./setup-vitest.sh [project-dir]
#
# Features:
#   - Detects package manager (npm/yarn/pnpm/bun)
#   - Detects frontend framework (React, Vue, Svelte, or plain TS/JS)
#   - Installs Vitest + relevant deps
#   - Generates vitest.config.ts
#   - Adds test scripts to package.json
#   - Creates vitest.setup.ts if needed
#
# If no project-dir is provided, uses the current directory.

set -euo pipefail

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✖${NC} $*"; exit 1; }

# ── Detect package manager ──────────────────────────────────────────
detect_pm() {
  if [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then echo "bun"
  elif [ -f "pnpm-lock.yaml" ]; then echo "pnpm"
  elif [ -f "yarn.lock" ]; then echo "yarn"
  else echo "npm"
  fi
}

PM=$(detect_pm)
info "Package manager: $PM"

install_dev() {
  case "$PM" in
    bun)  bun add -d "$@" ;;
    pnpm) pnpm add -D "$@" ;;
    yarn) yarn add -D "$@" ;;
    npm)  npm install -D "$@" ;;
  esac
}

# ── Validate project ────────────────────────────────────────────────
[ -f "package.json" ] || err "No package.json found in $(pwd). Run from a JS/TS project root."

# ── Detect framework ────────────────────────────────────────────────
FRAMEWORK="none"
HAS_TS=false

if grep -qE '"react"|"react-dom"' package.json 2>/dev/null; then
  FRAMEWORK="react"
elif grep -qE '"vue"' package.json 2>/dev/null; then
  FRAMEWORK="vue"
elif grep -qE '"svelte"' package.json 2>/dev/null; then
  FRAMEWORK="svelte"
fi

if grep -qE '"typescript"' package.json 2>/dev/null || [ -f "tsconfig.json" ]; then
  HAS_TS=true
fi

info "Detected framework: $FRAMEWORK"
info "TypeScript: $HAS_TS"

# ── Install dependencies ────────────────────────────────────────────
DEPS=("vitest" "@vitest/coverage-v8" "@vitest/ui")

case "$FRAMEWORK" in
  react)
    DEPS+=("@testing-library/react" "@testing-library/jest-dom" "@testing-library/user-event" "jsdom")
    info "Adding React Testing Library + jsdom"
    ;;
  vue)
    DEPS+=("@testing-library/vue" "@testing-library/jest-dom" "@testing-library/user-event" "jsdom")
    info "Adding Vue Testing Library + jsdom"
    ;;
  svelte)
    DEPS+=("@testing-library/svelte" "@testing-library/jest-dom" "@testing-library/user-event" "jsdom")
    info "Adding Svelte Testing Library + jsdom"
    ;;
  *)
    info "No framework detected — installing base Vitest"
    ;;
esac

info "Installing: ${DEPS[*]}"
install_dev "${DEPS[@]}"
ok "Dependencies installed"

# ── Determine environment ───────────────────────────────────────────
ENV="node"
if [ "$FRAMEWORK" != "none" ]; then
  ENV="jsdom"
fi

# ── Generate vitest.config.ts ───────────────────────────────────────
CONFIG_FILE="vitest.config.ts"
if [ -f "$CONFIG_FILE" ]; then
  warn "$CONFIG_FILE already exists — skipping generation"
else
  SETUP_LINE=""
  if [ "$FRAMEWORK" != "none" ]; then
    SETUP_LINE="    setupFiles: ['./vitest.setup.ts'],"
  fi

  cat > "$CONFIG_FILE" << CONFIGEOF
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: true,
    environment: '${ENV}',
${SETUP_LINE}
    include: ['**/*.{test,spec}.{ts,tsx,js,jsx}'],
    exclude: ['node_modules', 'dist', 'build', 'e2e'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html', 'lcov'],
      include: ['src/**/*.{ts,tsx,js,jsx}'],
      exclude: ['**/*.test.*', '**/*.spec.*', '**/*.d.ts', '**/index.{ts,js}'],
    },
  },
})
CONFIGEOF
  ok "Created $CONFIG_FILE"
fi

# ── Generate vitest.setup.ts ────────────────────────────────────────
if [ "$FRAMEWORK" != "none" ] && [ ! -f "vitest.setup.ts" ]; then
  case "$FRAMEWORK" in
    react)
      cat > vitest.setup.ts << 'SETUPEOF'
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'

afterEach(() => {
  cleanup()
})
SETUPEOF
      ;;
    vue)
      cat > vitest.setup.ts << 'SETUPEOF'
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/vue'
import { afterEach } from 'vitest'

afterEach(() => {
  cleanup()
})
SETUPEOF
      ;;
    svelte)
      cat > vitest.setup.ts << 'SETUPEOF'
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/svelte'
import { afterEach } from 'vitest'

afterEach(() => {
  cleanup()
})
SETUPEOF
      ;;
  esac
  ok "Created vitest.setup.ts"
fi

# ── Add TypeScript globals type ─────────────────────────────────────
if [ "$HAS_TS" = true ] && [ -f "tsconfig.json" ]; then
  if ! grep -q '"vitest/globals"' tsconfig.json 2>/dev/null; then
    warn "Add \"vitest/globals\" to compilerOptions.types in tsconfig.json for global type support"
  fi
fi

# ── Add scripts to package.json ─────────────────────────────────────
add_script() {
  local name="$1" cmd="$2"
  if ! grep -q "\"$name\"" package.json 2>/dev/null; then
    # Use node to safely modify package.json
    node -e "
      const fs = require('fs');
      const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
      pkg.scripts = pkg.scripts || {};
      if (!pkg.scripts['$name']) {
        pkg.scripts['$name'] = '$cmd';
      }
      fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
    "
  fi
}

add_script "test"          "vitest"
add_script "test:run"      "vitest run"
add_script "test:coverage" "vitest run --coverage"
add_script "test:ui"       "vitest --ui"
ok "Added test scripts to package.json"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━ Vitest setup complete! ━━━${NC}"
echo ""
echo "  Run tests:      $PM run test"
echo "  Single run:     $PM run test:run"
echo "  With coverage:  $PM run test:coverage"
echo "  UI mode:        $PM run test:ui"
echo ""
echo "  Config:  $CONFIG_FILE"
[ "$FRAMEWORK" != "none" ] && echo "  Setup:   vitest.setup.ts"
echo ""
