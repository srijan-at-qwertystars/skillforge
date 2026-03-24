---
name: turborepo-monorepo
description: >
  Manage Turborepo monorepos: turbo.json configuration, task pipelines, workspace dependencies,
  remote caching, turbo run, turbo prune, and CI/CD integration. Use when user mentions Turborepo,
  turbo.json, monorepo build orchestration, turbo run, turbo prune, remote caching with Vercel,
  monorepo task pipeline, workspace dependencies, topological ordering, or internal packages pattern.
  Do NOT use for Nx monorepo, Lerna, single-package repos, Bazel build system, Rush monorepo,
  Moon build system, or non-Turborepo monorepo tooling.
---

# Turborepo Monorepo Management

## Project Structure

Standard Turborepo monorepo layout:

```
my-monorepo/
├── apps/
│   ├── web/                # Deployable app (Next.js, Remix, etc.)
│   │   └── package.json
│   └── api/                # Deployable service
│       └── package.json
├── packages/
│   ├── ui/                 # Shared component library
│   │   └── package.json
│   ├── utils/              # Shared utilities
│   │   └── package.json
│   └── config/             # Shared configs (tsconfig, eslint)
│       └── package.json
├── turbo.json
├── package.json            # Root package.json
└── pnpm-workspace.yaml     # Or .npmrc / .yarnrc.yml
```

## Initialization

Create new Turborepo monorepo:
```bash
npx create-turbo@latest my-monorepo
```

Add Turborepo to existing monorepo:
```bash
npm install turbo --save-dev   # or pnpm add turbo -Dw / yarn add turbo -DW
```

Root `package.json` must define workspaces:
```json
{
  "name": "my-monorepo",
  "private": true,
  "workspaces": ["apps/*", "packages/*"],
  "devDependencies": {
    "turbo": "^2"
  },
  "scripts": {
    "build": "turbo run build",
    "dev": "turbo run dev",
    "lint": "turbo run lint",
    "test": "turbo run test"
  }
}
```

For pnpm, create `pnpm-workspace.yaml`:
```yaml
packages:
  - "apps/*"
  - "packages/*"
```

## turbo.json Configuration (v2 — use `tasks`, not `pipeline`)

Turborepo v2 renamed `pipeline` to `tasks`. Always use `tasks`.

```json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": ["dist/**", ".next/**", "!.next/cache/**"],
      "env": ["NODE_ENV", "API_URL"]
    },
    "lint": {
      "dependsOn": ["^build"],
      "outputs": []
    },
    "test": {
      "dependsOn": ["^build"],
      "outputs": ["coverage/**"],
      "env": ["CI", "NODE_ENV"]
    },
    "dev": {
      "cache": false,
      "persistent": true
    },
    "typecheck": {
      "dependsOn": ["^build"],
      "outputs": []
    }
  },
  "globalDependencies": ["tsconfig.json"],
  "globalEnv": ["NODE_ENV", "CI"]
}
```

### Package-Level turbo.json (Overrides)

Place a `turbo.json` inside any package to extend or override root config:
```json
{
  "extends": ["//"],
  "tasks": {
    "build": {
      "outputs": [".next/**", "!.next/cache/**"]
    }
  }
}
```
`"//"` refers to the root `turbo.json`.

## Task Dependencies and Topological Ordering

| Syntax | Meaning |
|---|---|
| `"dependsOn": ["^build"]` | Run `build` in all workspace dependencies first (topological) |
| `"dependsOn": ["build"]` | Run `build` in the SAME package first |
| `"dependsOn": ["^build", "typecheck"]` | Combine: deps' build + own typecheck first |
| `"dependsOn": []` | No dependencies; run immediately in parallel |

`^` prefix = topological dependency (upstream packages first). Without `^` = same-package task ordering.

Example: `apps/web` depends on `packages/ui`. Running `turbo run build`:
1. `packages/ui#build` runs first (topological via `^build`)
2. `apps/web#build` runs after `packages/ui#build` completes

Use `--dry` to visualize the task graph:
```bash
turbo run build --dry=json
# Or human-readable:
turbo run build --graph
```

## Remote Caching

### Vercel Remote Cache (Managed)

Authenticate:
```bash
npx turbo login
npx turbo link
```

For CI, set environment variables instead:
```bash
export TURBO_TOKEN=<vercel-token>
export TURBO_TEAM=<team-slug>
```

### Self-Hosted Remote Cache

Use `ducktors/turborepo-remote-cache` or implement the Turborepo HTTP cache API.

Configure `.turbo/config.json` or environment variables:
```bash
export TURBO_API="https://your-cache-server.com"
export TURBO_TOKEN="your-api-key"
export TURBO_TEAM="your-team"
```

Verify caching works:
```bash
turbo run build --summarize
# Check: "cacheStatus": "HIT" in the summary output
```

### Cache Configuration in turbo.json

```json
{
  "tasks": {
    "build": {
      "outputs": ["dist/**"],
      "cache": true
    },
    "dev": {
      "cache": false,
      "persistent": true
    }
  }
}
```

- `outputs`: files/dirs to cache and restore. Use globs. Omit or `[]` for tasks with no file output.
- `cache: false`: disable caching (use for dev servers, watch mode).
- `persistent: true`: marks long-running tasks (dev servers); prevents dependent tasks from waiting.

## Filtering and Scoping (`--filter`)

Run tasks for specific packages:
```bash
# Single package
turbo run build --filter=web
turbo run build --filter=@myorg/ui

# Package and its dependencies
turbo run build --filter=web...

# Only dependencies of a package (exclude itself)
turbo run build --filter=...web

# By directory
turbo run build --filter=./apps/web

# Changed packages since a git ref
turbo run build --filter='[HEAD^1]'
turbo run build --filter='...[origin/main...HEAD]'

# Combine filters
turbo run build --filter=web --filter=api

# Exclude a package
turbo run build --filter='!@myorg/docs'
```

Filter syntax summary:
| Pattern | Meaning |
|---|---|
| `--filter=pkg` | Exact package match |
| `--filter=pkg...` | Package + all its dependencies |
| `--filter=...pkg` | All dependents of package |
| `--filter=./path` | Package at directory path |
| `--filter='[ref]'` | Packages changed since git ref |
| `--filter='...[ref1...ref2]'` | Changed packages + their dependents |

## Workspace Configuration

### pnpm (Recommended)
```yaml
# pnpm-workspace.yaml
packages:
  - "apps/*"
  - "packages/*"
```

### npm
```json
// root package.json
{ "workspaces": ["apps/*", "packages/*"] }
```

### Yarn (v1 and v3+)
```json
// root package.json
{ "workspaces": ["apps/*", "packages/*"] }
```
For Yarn v3+ (Berry), ensure `nodeLinker: node-modules` in `.yarnrc.yml` for best compatibility.
### Internal Package Dependencies

In an app's `package.json`, reference internal packages with workspace protocol:
```json
{
  "dependencies": {
    "@myorg/ui": "workspace:*",
    "@myorg/utils": "workspace:*"
  }
}
```
For npm (no workspace protocol), use `"*"` and let workspace resolution handle it.

## Environment Variable Handling

### Task-Level `env` (Cache Key)
Variables that affect task output. Changing them causes cache miss:
```json
{
  "tasks": {
    "build": {
      "env": ["NODE_ENV", "API_URL", "DATABASE_URL"]
    }
  }
}
```

### Task-Level `passThroughEnv` (Available but Not Cached)
Variables available to the task but NOT part of cache key:
```json
{
  "tasks": {
    "deploy": {
      "passThroughEnv": ["AWS_SECRET_ACCESS_KEY", "DEPLOY_TOKEN"],
      "cache": false
    }
  }
}
```

### Global Environment Variables
```json
{
  "globalEnv": ["CI", "NODE_ENV"],
  "globalPassThroughEnv": ["GITHUB_TOKEN", "HOME"]
}
```
- `globalEnv`: changes bust ALL task caches.
- `globalPassThroughEnv`: available everywhere, no cache impact.
- Wildcard supported: `"env": ["NEXT_PUBLIC_*"]`.

## CI/CD Integration (GitHub Actions)

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize]

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    env:
      TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
      TURBO_TEAM: ${{ vars.TURBO_TEAM }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Full history for --filter with git refs
      - uses: pnpm/action-setup@v4
        with:
          version: 9
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build lint test --summarize
```

For affected-only CI:
```yaml
      - run: pnpm turbo run build test --filter='...[origin/main...HEAD]'
```

## Internal Packages Pattern

Create shared packages that are NOT published to npm:

```json
// packages/ui/package.json
{
  "name": "@myorg/ui",
  "private": true,
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "build": "tsup src/index.ts --format cjs,esm --dts",
    "lint": "eslint src/"
  }
}
```

For "just-in-time" packages (transpiled by consuming app, no build step):
```json
{
  "name": "@myorg/utils",
  "private": true,
  "main": "./src/index.ts",
  "types": "./src/index.ts"
}
```
Configure the consuming app's bundler (Next.js `transpilePackages`, Vite `optimizeDeps`) to handle these.

Next.js `next.config.js`:
```js
module.exports = {
  transpilePackages: ["@myorg/ui", "@myorg/utils"],
};
```

## Pruning for Docker Deployments

`turbo prune` creates a sparse monorepo with only the target app and its dependencies:

```bash
turbo prune @myorg/api --docker
```

Output structure in `./out/`:
```
out/
├── json/          # Only package.json files (for dependency install layer)
│   ├── apps/api/package.json
│   └── packages/utils/package.json
├── full/          # Full source code of pruned packages
│   ├── apps/api/
│   └── packages/utils/
└── pnpm-lock.yaml # Pruned lockfile
```

### Multi-Stage Dockerfile

```dockerfile
FROM node:20-slim AS base
RUN npm install -g pnpm@9

# Stage 1: Prune
FROM base AS pruner
WORKDIR /app
COPY . .
RUN pnpm turbo prune @myorg/api --docker

# Stage 2: Install dependencies (cached layer)
FROM base AS deps
WORKDIR /app
COPY --from=pruner /app/out/json/ .
RUN pnpm install --frozen-lockfile --prod

# Stage 3: Build
FROM base AS builder
WORKDIR /app
COPY --from=pruner /app/out/full/ .
COPY --from=deps /app/node_modules ./node_modules
RUN pnpm turbo run build --filter=@myorg/api

# Stage 4: Run
FROM node:20-slim AS runner
WORKDIR /app
COPY --from=builder /app/apps/api/dist ./dist
COPY --from=deps /app/node_modules ./node_modules
CMD ["node", "dist/server.js"]
```

Key: separate `json/` and `full/` copies to maximize Docker layer caching.

## Common Patterns

### Parallelism Control

```bash
turbo run build --concurrency=4       # Max 4 parallel tasks
turbo run build --concurrency=50%     # Use 50% of CPU cores
turbo run lint test --parallel        # Ignore task dependencies (use cautiously)
```

### Cache Debugging

```bash
turbo run build --summarize           # Run summary with cache stats
turbo run build --dry=json            # Preview without executing
turbo run build --force               # Bypass cache
```

## Anti-Patterns

| Anti-Pattern | Fix |
|---|---|
| Using `pipeline` key in turbo.json | Rename to `tasks` (Turborepo v2+) |
| `"dependsOn": ["^build"]` on `dev` task | Use `"cache": false, "persistent": true` with no topological deps for dev |
| Caching dev/watch tasks | Set `"cache": false` on persistent/long-running tasks |
| Missing `outputs` on build tasks | Always specify `outputs` so cache restores build artifacts |
| Not listing env vars in `env` | Explicitly list all env vars that affect task output to avoid stale caches |
| `fetch-depth: 1` in CI with git-based filters | Use `fetch-depth: 0` for `--filter='[ref]'` to work |
| Importing between apps directly | Create shared `packages/` instead; apps should never depend on other apps |
| Publishing internal packages to npm | Mark as `"private": true`; use workspace protocol for resolution |
| Putting all config in root turbo.json | Use package-level `turbo.json` with `"extends": ["//"]` for overrides |
| Using `--parallel` for builds | Only use `--parallel` for tasks with no inter-dependencies (lint, format) |

## Quick Reference

```bash
# Core commands
turbo run build                          # Build all packages
turbo run build --filter=web             # Build single package
turbo run build test lint                # Run multiple tasks
turbo run dev --filter=web               # Dev server for one app

# Caching
turbo login                              # Authenticate with Vercel
turbo link                               # Link repo to remote cache
turbo run build --force                  # Skip cache
turbo run build --summarize              # Show cache hit/miss stats

# Docker
turbo prune @myorg/api --docker          # Prune for Docker build

# Debugging
turbo run build --dry=json               # Preview task graph
turbo run build --graph                  # Generate graph visualization
turbo daemon status                      # Check turbo daemon
turbo daemon stop                        # Stop background daemon
```
