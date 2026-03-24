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

```bash
npx create-turbo@latest my-monorepo                     # New monorepo
npm install turbo --save-dev                              # Add to existing (or pnpm/yarn)
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

Use `ducktors/turborepo-remote-cache` or implement the Turborepo HTTP cache API:
```bash
export TURBO_API="https://your-cache-server.com"
export TURBO_TOKEN="your-api-key"
export TURBO_TEAM="your-team"
turbo run build --summarize  # Verify: "cacheStatus": "HIT"
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

### npm / Yarn
```json
{ "workspaces": ["apps/*", "packages/*"] }
```
For Yarn v3+ (Berry), set `nodeLinker: node-modules` in `.yarnrc.yml`.

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
Variables that affect task output — changing them causes cache miss:
```json
{ "tasks": { "build": { "env": ["NODE_ENV", "API_URL", "DATABASE_URL"] } } }
```

### Task-Level `passThroughEnv` (Available but Not Cached)
Variables available to the task but NOT part of cache key:
```json
{ "tasks": { "deploy": { "passThroughEnv": ["AWS_SECRET_ACCESS_KEY"], "cache": false } } }
```

### Global Environment Variables
```json
{
  "globalEnv": ["CI", "NODE_ENV"],
  "globalPassThroughEnv": ["GITHUB_TOKEN", "HOME"]
}
```
- `globalEnv`: changes bust ALL task caches
- `globalPassThroughEnv`: available everywhere, no cache impact
- Wildcard supported: `"env": ["NEXT_PUBLIC_*"]`

## CI/CD Integration (GitHub Actions)

Basic CI setup (see `assets/github-actions.yml` for production-grade template):

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

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
          fetch-depth: 0
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

Affected-only CI for PRs:
```bash
pnpm turbo run build test --filter='...[origin/main...HEAD]'
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
| Using `pipeline` key | Rename to `tasks` (v2+) |
| `"dependsOn": ["^build"]` on `dev` | Use `"cache": false, "persistent": true`, no topological deps |
| Caching dev/watch tasks | `"cache": false` on persistent tasks |
| Missing `outputs` on build | Always specify `outputs` for cache restore |
| Unlisted env vars | List all output-affecting env vars in `env` |
| `fetch-depth: 1` in CI | Use `fetch-depth: 0` for git-based `--filter` |
| Apps importing other apps | Create shared `packages/` instead |
| Publishing internal packages | Mark `"private": true`; use `workspace:*` |
| All config in root turbo.json | Use package-level turbo.json with `"extends": ["//"]` |
| `--parallel` for builds | Only for independent tasks (lint, format) |

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

## Reference Documents

Deep-dive guides for advanced usage and troubleshooting:

| Document | Contents |
|---|---|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Caching strategies, custom hash inputs, transit nodes, codemods, `turbo gen` generators, boundary enforcement, workspace versioning with Changesets, shared configs (ESLint, TypeScript, Prettier), publishing internal packages, architecture patterns |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Cache miss debugging (`--dry`, `--summarize`), task dependency issues, circular dependencies, env variable leaks, remote cache failures, Docker build problems, pnpm workspace issues, version conflicts, turbo daemon issues, common error messages |
| [`references/ci-optimization.md`](references/ci-optimization.md) | GitHub Actions matrix strategies, remote caching in CI, artifact caching, parallelization, pruned installs, Docker layer caching with `turbo prune`, Vercel deployment, preview deployments per package, reusable workflows, release pipelines |

## Scripts

Helper scripts in `scripts/` for common monorepo operations:

| Script | Purpose |
|---|---|
| [`scripts/init-monorepo.sh`](scripts/init-monorepo.sh) | Scaffold a complete Turborepo monorepo with apps/, packages/, shared configs, turbo.json. Usage: `./init-monorepo.sh my-project --org myorg` |
| [`scripts/add-package.sh`](scripts/add-package.sh) | Add a new package or app workspace with proper config. Templates: `lib`, `react`, `node-service`. Usage: `./add-package.sh auth --type package --template react` |
| [`scripts/analyze-cache.sh`](scripts/analyze-cache.sh) | Analyze cache hit rates, identify tasks with poor caching, show diagnostics. Usage: `./analyze-cache.sh --verbose` |

## Assets (Templates)

Production-ready config templates in `assets/`:

| Asset | Description |
|---|---|
| [`assets/turbo.json`](assets/turbo.json) | Comprehensive `turbo.json` with tasks for build, lint, typecheck, test, e2e, dev, deploy, db:migrate, storybook, with proper `inputs`, `outputs`, `env`, and `passThroughEnv` |
| [`assets/github-actions.yml`](assets/github-actions.yml) | GitHub Actions workflow with remote caching, affected-only PR builds, parallel lint/test/build jobs, Docker image build, pnpm store caching |
| [`assets/tsconfig.base.json`](assets/tsconfig.base.json) | Strict shared TypeScript config for monorepo packages with `bundler` module resolution, `verbatimModuleSyntax`, incremental builds |
