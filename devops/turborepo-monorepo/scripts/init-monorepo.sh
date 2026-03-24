#!/usr/bin/env bash
# =============================================================================
# init-monorepo.sh — Scaffold a new Turborepo monorepo
# =============================================================================
# Usage:
#   ./init-monorepo.sh <project-name> [--org <org-scope>] [--pm pnpm|npm|yarn]
#
# Examples:
#   ./init-monorepo.sh my-platform
#   ./init-monorepo.sh my-platform --org myorg
#   ./init-monorepo.sh my-platform --org myorg --pm pnpm
#
# Creates:
#   <project-name>/
#   ├── apps/
#   │   └── web/              # Starter Next.js-style app stub
#   ├── packages/
#   │   ├── ui/               # Shared UI component library
#   │   ├── utils/            # Shared utilities
#   │   ├── config-eslint/    # Shared ESLint config
#   │   └── config-typescript/# Shared TypeScript configs
#   ├── turbo.json
#   ├── package.json
#   ├── pnpm-workspace.yaml
#   ├── .gitignore
#   ├── .npmrc
#   └── tsconfig.json
# =============================================================================
set -euo pipefail

# --- Defaults ---
PROJECT_NAME=""
ORG_SCOPE="myorg"
PACKAGE_MANAGER="pnpm"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --org)
      ORG_SCOPE="$2"
      shift 2
      ;;
    --pm)
      PACKAGE_MANAGER="$2"
      shift 2
      ;;
    -h|--help)
      head -20 "$0" | grep "^#" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      PROJECT_NAME="$1"
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Error: Project name is required."
  echo "Usage: $0 <project-name> [--org <org-scope>] [--pm pnpm|npm|yarn]"
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Creating Turborepo monorepo: $PROJECT_NAME"
echo "   Org scope: @${ORG_SCOPE}"
echo "   Package manager: ${PACKAGE_MANAGER}"
echo ""

# --- Create directory structure ---
mkdir -p "$PROJECT_NAME"/{apps/web/src,packages/{ui/src,utils/src,config-eslint,config-typescript}}

cd "$PROJECT_NAME"

# --- Root package.json ---
cat > package.json << EOF
{
  "name": "${PROJECT_NAME}",
  "private": true,
  "workspaces": ["apps/*", "packages/*"],
  "scripts": {
    "build": "turbo run build",
    "dev": "turbo run dev",
    "lint": "turbo run lint",
    "test": "turbo run test",
    "typecheck": "turbo run typecheck",
    "format": "prettier --write \"**/*.{ts,tsx,js,jsx,md,json}\"",
    "clean": "turbo run clean && rm -rf node_modules"
  },
  "devDependencies": {
    "prettier": "^3.3.0",
    "turbo": "^2.0.0",
    "typescript": "^5.5.0"
  },
  "packageManager": "pnpm@9.0.0",
  "engines": {
    "node": ">=20"
  }
}
EOF

# --- turbo.json ---
cat > turbo.json << 'EOF'
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": ["dist/**", ".next/**", "!.next/cache/**"],
      "env": ["NODE_ENV"]
    },
    "lint": {
      "dependsOn": ["^build"],
      "inputs": ["src/**/*.ts", "src/**/*.tsx", ".eslintrc.*", "eslint.config.*"],
      "outputs": []
    },
    "test": {
      "dependsOn": ["^build"],
      "outputs": ["coverage/**"],
      "env": ["CI", "NODE_ENV"]
    },
    "typecheck": {
      "dependsOn": ["^build"],
      "outputs": []
    },
    "dev": {
      "cache": false,
      "persistent": true
    },
    "clean": {
      "cache": false
    }
  },
  "globalDependencies": ["tsconfig.json"],
  "globalEnv": ["NODE_ENV", "CI"]
}
EOF

# --- pnpm-workspace.yaml ---
cat > pnpm-workspace.yaml << 'EOF'
packages:
  - "apps/*"
  - "packages/*"
EOF

# --- .npmrc ---
cat > .npmrc << 'EOF'
auto-install-peers=true
strict-peer-dependencies=false
EOF

# --- .gitignore ---
cat > .gitignore << 'EOF'
# Dependencies
node_modules/

# Build outputs
dist/
.next/
out/
build/
storybook-static/

# Turbo
.turbo/

# Testing
coverage/

# Environment
.env
.env.local
.env.*.local

# IDE
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Debug
npm-debug.log*
yarn-debug.log*
yarn-error.log*
pnpm-debug.log*
EOF

# --- Root tsconfig.json ---
cat > tsconfig.json << EOF
{
  "extends": "@${ORG_SCOPE}/tsconfig/base.json"
}
EOF

# --- packages/config-typescript ---
cat > packages/config-typescript/package.json << EOF
{
  "name": "@${ORG_SCOPE}/tsconfig",
  "private": true,
  "version": "0.0.0",
  "exports": {
    "./base.json": "./base.json",
    "./react-library.json": "./react-library.json",
    "./nextjs.json": "./nextjs.json"
  }
}
EOF

cat > packages/config-typescript/base.json << 'EOF'
{
  "$schema": "https://json.schemastore.org/tsconfig",
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "incremental": true
  },
  "exclude": ["node_modules", "dist", "coverage", ".next", ".turbo"]
}
EOF

cat > packages/config-typescript/react-library.json << 'EOF'
{
  "extends": "./base.json",
  "compilerOptions": {
    "jsx": "react-jsx",
    "lib": ["ES2022", "DOM", "DOM.Iterable"]
  }
}
EOF

cat > packages/config-typescript/nextjs.json << 'EOF'
{
  "extends": "./base.json",
  "compilerOptions": {
    "jsx": "preserve",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "noEmit": true,
    "plugins": [{ "name": "next" }]
  }
}
EOF

# --- packages/config-eslint ---
cat > packages/config-eslint/package.json << EOF
{
  "name": "@${ORG_SCOPE}/eslint-config",
  "private": true,
  "version": "0.0.0",
  "main": "base.js",
  "exports": {
    ".": "./base.js",
    "./react": "./react.js"
  },
  "dependencies": {
    "@typescript-eslint/eslint-plugin": "^7.0.0",
    "@typescript-eslint/parser": "^7.0.0",
    "eslint-config-prettier": "^9.0.0"
  },
  "peerDependencies": {
    "eslint": ">=8.0.0"
  }
}
EOF

cat > packages/config-eslint/base.js << 'EOF'
module.exports = {
  parser: "@typescript-eslint/parser",
  plugins: ["@typescript-eslint"],
  extends: [
    "eslint:recommended",
    "plugin:@typescript-eslint/recommended",
    "prettier",
  ],
  env: { node: true, es2022: true },
  rules: {
    "@typescript-eslint/no-unused-vars": ["warn", { argsIgnorePattern: "^_" }],
    "@typescript-eslint/no-explicit-any": "warn",
    "no-console": ["warn", { allow: ["warn", "error"] }],
  },
  ignorePatterns: ["dist/", "node_modules/", ".next/", "coverage/"],
};
EOF

cat > packages/config-eslint/react.js << 'EOF'
module.exports = {
  extends: [
    "./base.js",
    "plugin:react/recommended",
    "plugin:react-hooks/recommended",
  ],
  settings: { react: { version: "detect" } },
  rules: {
    "react/react-in-jsx-scope": "off",
    "react/prop-types": "off",
  },
};
EOF

# --- packages/utils ---
cat > packages/utils/package.json << EOF
{
  "name": "@${ORG_SCOPE}/utils",
  "private": true,
  "version": "0.0.0",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "lint": "eslint src/",
    "typecheck": "tsc --noEmit",
    "clean": "rm -rf dist .turbo"
  },
  "devDependencies": {
    "@${ORG_SCOPE}/eslint-config": "workspace:*",
    "@${ORG_SCOPE}/tsconfig": "workspace:*",
    "eslint": "^8.0.0",
    "typescript": "^5.5.0"
  }
}
EOF

cat > packages/utils/tsconfig.json << EOF
{
  "extends": "@${ORG_SCOPE}/tsconfig/base.json",
  "compilerOptions": {
    "outDir": "dist"
  },
  "include": ["src"]
}
EOF

cat > packages/utils/src/index.ts << 'EOF'
export function cn(...classes: (string | undefined | null | false)[]): string {
  return classes.filter(Boolean).join(" ");
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function invariant(
  condition: unknown,
  message: string,
): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}
EOF

# --- packages/ui ---
cat > packages/ui/package.json << EOF
{
  "name": "@${ORG_SCOPE}/ui",
  "private": true,
  "version": "0.0.0",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "lint": "eslint src/",
    "typecheck": "tsc --noEmit",
    "clean": "rm -rf dist .turbo"
  },
  "devDependencies": {
    "@${ORG_SCOPE}/eslint-config": "workspace:*",
    "@${ORG_SCOPE}/tsconfig": "workspace:*",
    "eslint": "^8.0.0",
    "typescript": "^5.5.0"
  },
  "dependencies": {
    "@${ORG_SCOPE}/utils": "workspace:*"
  }
}
EOF

cat > packages/ui/tsconfig.json << EOF
{
  "extends": "@${ORG_SCOPE}/tsconfig/react-library.json",
  "compilerOptions": {
    "outDir": "dist"
  },
  "include": ["src"]
}
EOF

cat > packages/ui/src/index.ts << 'EOF'
export function Button({
  label,
  onClick,
}: {
  label: string;
  onClick?: () => void;
}) {
  return { type: "button", props: { label, onClick } };
}

export function Card({ title, children }: { title: string; children?: unknown }) {
  return { type: "card", props: { title, children } };
}
EOF

# --- apps/web ---
cat > apps/web/package.json << EOF
{
  "name": "@${ORG_SCOPE}/web",
  "private": true,
  "version": "0.0.0",
  "scripts": {
    "dev": "echo 'Starting dev server...'",
    "build": "echo 'Building web app...' && mkdir -p dist && echo '{}' > dist/index.js",
    "lint": "eslint src/",
    "typecheck": "tsc --noEmit",
    "clean": "rm -rf dist .next .turbo"
  },
  "dependencies": {
    "@${ORG_SCOPE}/ui": "workspace:*",
    "@${ORG_SCOPE}/utils": "workspace:*"
  },
  "devDependencies": {
    "@${ORG_SCOPE}/eslint-config": "workspace:*",
    "@${ORG_SCOPE}/tsconfig": "workspace:*",
    "eslint": "^8.0.0",
    "typescript": "^5.5.0"
  }
}
EOF

cat > apps/web/tsconfig.json << EOF
{
  "extends": "@${ORG_SCOPE}/tsconfig/nextjs.json",
  "compilerOptions": {
    "outDir": "dist"
  },
  "include": ["src"]
}
EOF

cat > apps/web/src/index.ts << EOF
import { Button } from "@${ORG_SCOPE}/ui";
import { cn } from "@${ORG_SCOPE}/utils";

console.log("Web app running");
console.log(Button({ label: "Click me" }));
console.log(cn("foo", "bar"));
EOF

echo ""
echo "✅ Monorepo scaffolded at ./${PROJECT_NAME}"
echo ""
echo "Next steps:"
echo "  cd ${PROJECT_NAME}"
echo "  ${PACKAGE_MANAGER} install"
echo "  ${PACKAGE_MANAGER} turbo run build"
echo "  ${PACKAGE_MANAGER} turbo run dev --filter=@${ORG_SCOPE}/web"
echo ""
echo "To enable remote caching:"
echo "  npx turbo login"
echo "  npx turbo link"
