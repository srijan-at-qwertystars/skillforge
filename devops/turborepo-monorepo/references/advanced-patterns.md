# Turborepo Advanced Patterns

## Table of Contents

- [Advanced Caching Strategies](#advanced-caching-strategies)
- [Custom Hash Inputs](#custom-hash-inputs)
- [Transit Nodes](#transit-nodes)
- [Codemods](#codemods)
- [Generator System](#generator-system)
- [Boundary Enforcement](#boundary-enforcement)
- [Workspace Versioning](#workspace-versioning)
- [Shared Configurations](#shared-configurations)
- [Publishing Internal Packages](#publishing-internal-packages)
- [Monorepo Architecture Patterns](#monorepo-architecture-patterns)

---

## Advanced Caching Strategies

### Output Fingerprinting

Turborepo hashes inputs to determine cache keys. Understanding what constitutes an input is critical:

- **Source files**: All tracked files in the workspace (respects `.gitignore`)
- **Dependencies**: Resolved versions from lockfile
- **Task definition**: The `tasks` entry in `turbo.json`
- **Environment variables**: Listed in `env` and `globalEnv`
- **`globalDependencies`**: Root files that affect all tasks (e.g., `tsconfig.json`)

### Granular Output Declarations

```json
{
  "tasks": {
    "build": {
      "outputs": [
        "dist/**",
        ".next/**",
        "!.next/cache/**",
        "storybook-static/**"
      ]
    }
  }
}
```

**Rules:**
- Use negation (`!`) to exclude volatile subdirectories (e.g., `.next/cache/`)
- Always declare `outputs` — omitting it means nothing is cached/restored
- Empty array `[]` means "task has no file outputs" (useful for lint, typecheck)
- Globs are relative to the workspace root of each package

### Framework-Specific Output Patterns

| Framework | Recommended `outputs` |
|---|---|
| Next.js | `[".next/**", "!.next/cache/**"]` |
| Vite / React | `["dist/**"]` |
| Remix | `["build/**", "public/build/**"]` |
| Storybook | `["storybook-static/**"]` |
| tsup / esbuild | `["dist/**"]` |
| tsc (declaration only) | `["dist/**/*.d.ts", "dist/**/*.d.ts.map"]` |
| Jest coverage | `["coverage/**"]` |
| Astro | `["dist/**", ".astro/**"]` |

### Scoped Task Caching

Override caching behavior per-workspace with package-level `turbo.json`:

```json
// apps/web/turbo.json
{
  "extends": ["//"],
  "tasks": {
    "build": {
      "outputs": [".next/**", "!.next/cache/**"],
      "env": ["NEXT_PUBLIC_*", "VERCEL_*"]
    }
  }
}
```

### Cache Boundaries with `inputs`

Restrict which files contribute to the cache hash for a task. By default Turborepo hashes all files in the workspace. Use `inputs` to narrow it:

```json
{
  "tasks": {
    "lint": {
      "inputs": ["src/**/*.ts", "src/**/*.tsx", ".eslintrc.*", "tsconfig.json"],
      "outputs": []
    },
    "test": {
      "inputs": [
        "src/**/*.ts",
        "src/**/*.tsx",
        "tests/**",
        "jest.config.*",
        "tsconfig.json"
      ],
      "outputs": ["coverage/**"]
    }
  }
}
```

**When to use `inputs`:**
- `lint` tasks: only re-lint when source or config changes (not when README changes)
- `test` tasks: only re-test when source, test files, or test config changes
- Documentation builds: only rebuild when `.md` files change

### Multi-Tier Caching

```json
{
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": ["dist/**"],
      "cache": true
    },
    "build:production": {
      "dependsOn": ["^build"],
      "outputs": ["dist/**"],
      "env": ["NODE_ENV", "SENTRY_DSN", "API_URL"],
      "cache": true
    }
  }
}
```

Separate task names for different build modes ensures production env vars don't pollute dev cache keys.

---

## Custom Hash Inputs

### `globalDependencies`

Files that, when changed, invalidate ALL task caches across the entire monorepo:

```json
{
  "globalDependencies": [
    "tsconfig.json",
    ".env",
    "pnpm-lock.yaml",
    "turbo.json"
  ],
  "globalEnv": ["CI", "NODE_ENV"]
}
```

**Choose wisely** — every global dependency change triggers full rebuilds.

### `globalPassThroughEnv`

Environment variables that are available to all tasks but do NOT affect cache keys:

```json
{
  "globalPassThroughEnv": [
    "HOME",
    "PATH",
    "GITHUB_TOKEN",
    "NPM_TOKEN",
    "SSH_AUTH_SOCK"
  ]
}
```

Use for credentials, auth tokens, and system variables that shouldn't bust caches.

### Environment Variable Wildcards

```json
{
  "tasks": {
    "build": {
      "env": [
        "NEXT_PUBLIC_*",
        "VITE_*",
        "REACT_APP_*"
      ]
    }
  }
}
```

Wildcards capture all matching env vars as cache inputs. Critical for frameworks that inline env vars at build time.

### `inputs` for Surgical Cache Control

```json
{
  "tasks": {
    "generate-api-client": {
      "inputs": ["openapi.yaml", "scripts/generate-client.ts"],
      "outputs": ["src/generated/**"],
      "dependsOn": []
    }
  }
}
```

Only re-runs when the OpenAPI spec or generator script changes.

---

## Transit Nodes

Transit nodes are workspace packages that exist solely to group dependencies or re-export from other packages. They have no build step themselves but participate in the dependency graph.

### Pattern: Hub Package

```json
// packages/platform/package.json
{
  "name": "@myorg/platform",
  "private": true,
  "main": "./src/index.ts",
  "dependencies": {
    "@myorg/auth": "workspace:*",
    "@myorg/database": "workspace:*",
    "@myorg/logger": "workspace:*"
  }
}
```

```typescript
// packages/platform/src/index.ts
export { createAuth } from "@myorg/auth";
export { createDatabase } from "@myorg/database";
export { createLogger } from "@myorg/logger";
```

Apps depend on `@myorg/platform` instead of individual packages. The transit node simplifies dependency management.

### turbo.json for Transit Nodes

If transit packages have no build step, ensure they don't block the pipeline:

```json
// packages/platform/turbo.json
{
  "extends": ["//"],
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": []
    }
  }
}
```

Or omit the `build` script from `package.json` entirely — Turborepo skips tasks that don't exist in a workspace.

---

## Codemods

Turborepo provides codemods to automate migrations between major versions.

### Running Codemods

```bash
# List available codemods
npx @turbo/codemod --list

# Migrate from Turborepo v1 to v2 (pipeline → tasks)
npx @turbo/codemod migrate-to-turbo-v2

# Specific codemods
npx @turbo/codemod rename-pipeline    # Rename pipeline to tasks
npx @turbo/codemod add-package-manager  # Add packageManager field
npx @turbo/codemod set-default-outputs  # Add default outputs

# Dry run
npx @turbo/codemod migrate-to-turbo-v2 --dry
```

### Common v1 → v2 Migration Changes

| v1 | v2 |
|---|---|
| `"pipeline": { ... }` | `"tasks": { ... }` |
| `"outputMode": "full"` | `"outputLogs": "full"` |
| `"globalDependencies"` at task level | Moved to root level |
| `--scope` flag | `--filter` flag |

### Post-Migration Verification

```bash
# Verify turbo.json is valid
turbo run build --dry=json

# Check for any deprecated config
turbo run build --summarize 2>&1 | grep -i "deprecated\|warning"
```

---

## Generator System

Turborepo includes a code generator (`turbo gen`) for scaffolding new workspaces and code.

### Built-in Generators

```bash
# Create a new workspace (interactive)
turbo gen workspace

# Create a new workspace non-interactively
turbo gen workspace --name @myorg/new-lib --type package

# Copy an existing workspace as template
turbo gen workspace --copy --source=packages/ui --name @myorg/new-ui
```

### Custom Generators

Create `.turbo/generators/config.ts`:

```typescript
import type { PlopTypes } from "@turbo/gen";

export default function generator(plop: PlopTypes.NodePlopAPI): void {
  plop.setGenerator("react-component", {
    description: "Create a new React component in the UI library",
    prompts: [
      {
        type: "input",
        name: "name",
        message: "Component name (PascalCase):",
      },
      {
        type: "confirm",
        name: "withTests",
        message: "Include test file?",
        default: true,
      },
    ],
    actions: (answers) => {
      const actions: PlopTypes.ActionType[] = [
        {
          type: "add",
          path: "packages/ui/src/{{pascalCase name}}/{{pascalCase name}}.tsx",
          templateFile: ".turbo/generators/templates/component.tsx.hbs",
        },
        {
          type: "add",
          path: "packages/ui/src/{{pascalCase name}}/index.ts",
          templateFile: ".turbo/generators/templates/component-index.ts.hbs",
        },
        {
          type: "append",
          path: "packages/ui/src/index.ts",
          template: 'export * from "./{{pascalCase name}}";',
        },
      ];

      if (answers?.withTests) {
        actions.push({
          type: "add",
          path: "packages/ui/src/{{pascalCase name}}/{{pascalCase name}}.test.tsx",
          templateFile: ".turbo/generators/templates/component-test.tsx.hbs",
        });
      }

      return actions;
    },
  });
}
```

### Handlebars Templates

```handlebars
{{!-- .turbo/generators/templates/component.tsx.hbs --}}
import React from "react";

export interface {{pascalCase name}}Props {
  children?: React.ReactNode;
  className?: string;
}

export function {{pascalCase name}}({ children, className }: {{pascalCase name}}Props) {
  return (
    <div className={className}>
      {children}
    </div>
  );
}
```

### Running Custom Generators

```bash
turbo gen react-component
# or non-interactively:
turbo gen react-component -- --name Button --withTests
```

---

## Boundary Enforcement

Enforce architectural boundaries so that packages don't depend on things they shouldn't.

### Using `dependsOn` for Enforcement

Structure your dependency graph intentionally:
- `apps/*` can depend on `packages/*`
- `packages/*` should NOT depend on `apps/*`
- Layer violations should be caught in CI

### Package Dependency Linting with `depcheck` or `eslint-plugin-import`

```json
// packages/utils/package.json — should have ZERO internal dependencies
{
  "name": "@myorg/utils",
  "private": true,
  "dependencies": {}
}
```

### Boundary Script

```bash
#!/usr/bin/env bash
# Ensure no package in packages/ depends on apps/
set -euo pipefail

for pkg_json in packages/*/package.json; do
  if grep -q '"@myorg/web"\|"@myorg/api"\|"@myorg/admin"' "$pkg_json"; then
    echo "BOUNDARY VIOLATION: $pkg_json depends on an app!"
    exit 1
  fi
done
echo "All boundaries respected."
```

### Using Turborepo's `--filter` for Validation

```bash
# Detect circular or unexpected dependency chains
turbo run build --filter=@myorg/utils... --dry=json | jq '.tasks[].package' | sort -u

# If apps appear in the output, utils has an unintended dependency on an app
```

---

## Workspace Versioning

### Independent Versioning with Changesets

```bash
pnpm add -Dw @changesets/cli
npx changeset init
```

Configure `.changeset/config.json`:

```json
{
  "$schema": "https://unpkg.com/@changesets/config@3.0.0/schema.json",
  "changelog": "@changesets/cli/changelog",
  "commit": false,
  "fixed": [],
  "linked": [["@myorg/ui", "@myorg/ui-icons"]],
  "access": "restricted",
  "baseBranch": "main",
  "updateInternalDependencies": "patch",
  "ignore": ["@myorg/web", "@myorg/api"]
}
```

- `linked`: packages that always share the same version
- `fixed`: packages that always bump together
- `ignore`: private apps that are never published

### Version Workflow

```bash
# Developer creates a changeset
npx changeset
# → Select packages, bump type (patch/minor/major), write summary

# CI or release manager bumps versions
npx changeset version
# → Updates package.json versions and CHANGELOGs

# Publish to npm
npx changeset publish
# → Publishes changed packages with correct versions
```

### Turbo + Changesets Integration

```json
// turbo.json
{
  "tasks": {
    "publish-packages": {
      "dependsOn": ["build", "test"],
      "cache": false
    }
  }
}
```

```json
// root package.json
{
  "scripts": {
    "publish-packages": "changeset publish",
    "version-packages": "changeset version"
  }
}
```

---

## Shared Configurations

### Shared ESLint Configuration

```
packages/
└── config-eslint/
    ├── package.json
    ├── base.js
    ├── react.js
    └── next.js
```

```json
// packages/config-eslint/package.json
{
  "name": "@myorg/eslint-config",
  "private": true,
  "version": "0.0.0",
  "main": "base.js",
  "exports": {
    ".": "./base.js",
    "./react": "./react.js",
    "./next": "./next.js"
  },
  "dependencies": {
    "@typescript-eslint/eslint-plugin": "^7.0.0",
    "@typescript-eslint/parser": "^7.0.0",
    "eslint-config-prettier": "^9.0.0",
    "eslint-plugin-react": "^7.0.0",
    "eslint-plugin-react-hooks": "^4.0.0"
  },
  "peerDependencies": {
    "eslint": ">=8.0.0"
  }
}
```

```javascript
// packages/config-eslint/base.js
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
```

Consumer usage:

```javascript
// apps/web/.eslintrc.js
module.exports = {
  root: true,
  extends: ["@myorg/eslint-config/next"],
};
```

### Shared TypeScript Configuration

```
packages/
└── config-typescript/
    ├── package.json
    ├── base.json
    ├── react-library.json
    └── nextjs.json
```

```json
// packages/config-typescript/base.json
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
  "exclude": ["node_modules", "dist", "coverage"]
}
```

```json
// packages/config-typescript/react-library.json
{
  "extends": "./base.json",
  "compilerOptions": {
    "jsx": "react-jsx",
    "lib": ["ES2022", "DOM", "DOM.Iterable"]
  }
}
```

Consumer usage:

```json
// packages/ui/tsconfig.json
{
  "extends": "@myorg/tsconfig/react-library.json",
  "compilerOptions": {
    "outDir": "dist"
  },
  "include": ["src"]
}
```

### Shared Prettier Configuration

```json
// packages/config-prettier/package.json
{
  "name": "@myorg/prettier-config",
  "private": true,
  "version": "0.0.0",
  "main": "index.json",
  "peerDependencies": {
    "prettier": ">=3.0.0"
  }
}
```

```json
// packages/config-prettier/index.json
{
  "semi": true,
  "singleQuote": false,
  "tabWidth": 2,
  "trailingComma": "all",
  "printWidth": 100,
  "bracketSpacing": true,
  "arrowParens": "always",
  "endOfLine": "lf"
}
```

Consumer usage in `package.json`:

```json
{
  "prettier": "@myorg/prettier-config"
}
```

---

## Publishing Internal Packages

### Just-in-Time (JIT) Packages — No Build Step

The simplest pattern. The consuming app's bundler transpiles the package:

```json
// packages/ui/package.json
{
  "name": "@myorg/ui",
  "private": true,
  "exports": {
    ".": "./src/index.ts",
    "./*": "./src/*/index.ts"
  },
  "main": "./src/index.ts",
  "types": "./src/index.ts"
}
```

**Requirements:** The consuming app must handle transpilation (e.g., Next.js `transpilePackages`, Vite handles it natively).

### Built Packages — With tsup/unbuild

For packages consumed by multiple frameworks or needing CJS/ESM dual output:

```json
// packages/utils/package.json
{
  "name": "@myorg/utils",
  "private": true,
  "main": "./dist/index.cjs",
  "module": "./dist/index.mjs",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.mjs",
      "require": "./dist/index.cjs",
      "types": "./dist/index.d.ts"
    }
  },
  "scripts": {
    "build": "tsup src/index.ts --format cjs,esm --dts --clean"
  },
  "devDependencies": {
    "tsup": "^8.0.0"
  }
}
```

### Publishing to npm Registry

For packages intended for external consumption:

```json
// packages/sdk/package.json
{
  "name": "@myorg/sdk",
  "version": "1.0.0",
  "private": false,
  "license": "MIT",
  "publishConfig": {
    "access": "public",
    "registry": "https://registry.npmjs.org/"
  },
  "files": ["dist", "README.md", "LICENSE"],
  "exports": {
    ".": {
      "import": "./dist/index.mjs",
      "require": "./dist/index.cjs",
      "types": "./dist/index.d.ts"
    }
  }
}
```

---

## Monorepo Architecture Patterns

### Layered Architecture

```
Layer 3 (Apps):     apps/web, apps/api, apps/admin
                         ↓
Layer 2 (Features): packages/auth, packages/payments
                         ↓
Layer 1 (Core):     packages/ui, packages/utils, packages/database
                         ↓
Layer 0 (Config):   packages/config-eslint, packages/config-typescript
```

**Rules:**
- Higher layers depend on lower layers, never the reverse
- Same-layer dependencies are allowed but should be minimized
- Config packages (Layer 0) have no internal dependencies

### Feature Package Pattern

Group related functionality into feature packages rather than splitting by technical concern:

```
packages/
├── auth/           # Auth logic, components, hooks, types
│   ├── src/
│   │   ├── components/
│   │   ├── hooks/
│   │   ├── utils/
│   │   └── types.ts
│   └── package.json
├── billing/        # Billing logic, components, hooks, types
└── notifications/  # Notification logic, components, hooks, types
```

### Shared Types Pattern

```json
// packages/types/package.json
{
  "name": "@myorg/types",
  "private": true,
  "exports": {
    ".": "./src/index.ts",
    "./api": "./src/api.ts",
    "./database": "./src/database.ts"
  }
}
```

Use this package for types shared across apps (API contracts, database schemas, shared enums). Import types with `import type` to ensure they're erased at build time and don't create runtime dependencies.
