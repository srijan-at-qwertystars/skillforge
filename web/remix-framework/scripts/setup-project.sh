#!/usr/bin/env bash
# setup-project.sh — Bootstrap a new React Router v7 (framework mode) project
#
# Usage:
#   ./setup-project.sh <project-name> [--no-tailwind] [--no-test] [--docker]
#
# Creates a project with:
#   - React Router v7 framework mode (SSR)
#   - TypeScript (strict)
#   - Tailwind CSS v4
#   - Vitest + Testing Library
#   - ESLint + Prettier
#   - Optional Docker setup
#
# Requires: node >= 20, npm

set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# --- Parse arguments ---
PROJECT_NAME=""
WITH_TAILWIND=true
WITH_TEST=true
WITH_DOCKER=false

for arg in "$@"; do
  case "$arg" in
    --no-tailwind) WITH_TAILWIND=false ;;
    --no-test)     WITH_TEST=false ;;
    --docker)      WITH_DOCKER=true ;;
    --help|-h)
      head -15 "$0" | tail -13
      exit 0
      ;;
    *)
      if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME="$arg"
      else
        fail "Unexpected argument: $arg"
      fi
      ;;
  esac
done

[[ -z "$PROJECT_NAME" ]] && fail "Project name is required.\nUsage: $0 <project-name>"

# --- Check prerequisites ---
command -v node >/dev/null 2>&1 || fail "Node.js is required (v20+)"
command -v npm  >/dev/null 2>&1 || fail "npm is required"

NODE_MAJOR=$(node -e "console.log(process.versions.node.split('.')[0])")
[[ "$NODE_MAJOR" -ge 20 ]] || fail "Node.js v20+ required (found v${NODE_MAJOR})"

if [[ -d "$PROJECT_NAME" ]]; then
  fail "Directory '$PROJECT_NAME' already exists"
fi

# --- Create project ---
info "Creating React Router v7 project: $PROJECT_NAME"
npx --yes create-react-router@latest "$PROJECT_NAME" --yes
cd "$PROJECT_NAME"
ok "Project scaffolded"

# --- Tailwind CSS ---
if $WITH_TAILWIND; then
  info "Installing Tailwind CSS v4..."
  npm install -D tailwindcss @tailwindcss/vite

  # Add Tailwind plugin to vite.config.ts if not already present
  if ! grep -q "tailwindcss" vite.config.ts 2>/dev/null; then
    cat > vite.config.ts << 'VITE_EOF'
import { reactRouter } from "@react-router/dev/vite";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [tailwindcss(), reactRouter(), tsconfigPaths()],
});
VITE_EOF
  fi

  # Create app.css with Tailwind import if missing
  if [[ -f "app/app.css" ]] && ! grep -q "tailwindcss" app/app.css; then
    echo '@import "tailwindcss";' | cat - app/app.css > /tmp/_app_css && mv /tmp/_app_css app/app.css
  fi
  ok "Tailwind CSS configured"
fi

# --- Testing ---
if $WITH_TEST; then
  info "Installing Vitest + Testing Library..."
  npm install -D vitest @testing-library/react @testing-library/jest-dom \
    @testing-library/user-event jsdom @vitejs/plugin-react

  # Create vitest config
  cat > vitest.config.ts << 'VITEST_EOF'
import { defineConfig } from "vitest/config";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [tsconfigPaths()],
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./test/setup.ts"],
    include: ["app/**/*.test.{ts,tsx}", "test/**/*.test.{ts,tsx}"],
  },
});
VITEST_EOF

  # Create test setup
  mkdir -p test
  cat > test/setup.ts << 'SETUP_EOF'
import "@testing-library/jest-dom/vitest";
SETUP_EOF

  # Create example test
  cat > test/example.test.ts << 'EXAMPLE_EOF'
import { describe, it, expect } from "vitest";

describe("example", () => {
  it("works", () => {
    expect(1 + 1).toBe(2);
  });
});
EXAMPLE_EOF

  # Add test script to package.json
  npm pkg set scripts.test="vitest run"
  npm pkg set scripts.test:watch="vitest"
  ok "Testing configured (Vitest + Testing Library)"
fi

# --- ESLint + Prettier ---
info "Installing ESLint + Prettier..."
npm install -D prettier eslint-config-prettier

cat > .prettierrc << 'PRETTIER_EOF'
{
  "semi": true,
  "singleQuote": false,
  "tabWidth": 2,
  "trailingComma": "all",
  "printWidth": 100
}
PRETTIER_EOF

npm pkg set scripts.lint="eslint app/"
npm pkg set scripts.format="prettier --write 'app/**/*.{ts,tsx,css}'"
ok "ESLint + Prettier configured"

# --- TypeScript strict mode ---
if [[ -f "tsconfig.json" ]]; then
  info "Enabling strict TypeScript..."
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('tsconfig.json', 'utf8'));
    cfg.compilerOptions = cfg.compilerOptions || {};
    cfg.compilerOptions.strict = true;
    cfg.compilerOptions.noUncheckedIndexedAccess = true;
    fs.writeFileSync('tsconfig.json', JSON.stringify(cfg, null, 2) + '\n');
  "
  ok "TypeScript strict mode enabled"
fi

# --- Docker ---
if $WITH_DOCKER; then
  info "Creating Docker setup..."

  cat > Dockerfile << 'DOCKER_EOF'
FROM node:20-slim AS base
WORKDIR /app

FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci

FROM base AS build
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM base AS production
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/build ./build
COPY --from=build /app/package.json ./
EXPOSE 3000
CMD ["npm", "start"]
DOCKER_EOF

  cat > .dockerignore << 'IGNORE_EOF'
node_modules
build
.react-router
*.log
.git
IGNORE_EOF

  ok "Docker setup created"
fi

# --- Generate types ---
info "Generating route types..."
npx react-router typegen 2>/dev/null || warn "typegen skipped (run manually: npx react-router typegen)"

# --- Summary ---
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Project '$PROJECT_NAME' is ready!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  cd $PROJECT_NAME"
echo "  npm run dev          # Start dev server"
$WITH_TEST && echo "  npm test             # Run tests"
echo "  npm run build        # Production build"
echo "  npm start            # Serve production build"
echo "  npm run lint         # Lint code"
echo "  npm run format       # Format code"
echo ""
