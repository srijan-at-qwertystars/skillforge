# Turborepo CI/CD Optimization

## Table of Contents

- [GitHub Actions Matrix Strategies](#github-actions-matrix-strategies)
- [Remote Caching in CI](#remote-caching-in-ci)
- [Artifact Caching](#artifact-caching)
- [Parallelization Strategies](#parallelization-strategies)
- [Pruned Installs](#pruned-installs)
- [Docker Layer Caching with turbo prune](#docker-layer-caching-with-turbo-prune)
- [Vercel Deployment](#vercel-deployment)
- [Preview Deployments Per Package](#preview-deployments-per-package)
- [Advanced CI Patterns](#advanced-ci-patterns)
- [CI Performance Checklist](#ci-performance-checklist)

---

## GitHub Actions Matrix Strategies

### Task-Based Matrix

Split CI tasks (build, test, lint) across parallel jobs:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  ci:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        task: [build, test, lint, typecheck]
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
      - run: pnpm turbo run ${{ matrix.task }}
```

### Package-Based Matrix

Run all tasks per package, useful when packages have significantly different CI needs:

```yaml
jobs:
  detect-packages:
    runs-on: ubuntu-latest
    outputs:
      packages: ${{ steps.detect.outputs.packages }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: detect
        run: |
          # Get changed packages using turbo
          PACKAGES=$(npx turbo run build --filter='...[origin/main...HEAD]' --dry=json 2>/dev/null \
            | jq -c '[.packages[] | select(. != "//")]')
          echo "packages=$PACKAGES" >> $GITHUB_OUTPUT

  ci:
    needs: detect-packages
    if: needs.detect-packages.outputs.packages != '[]'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        package: ${{ fromJson(needs.detect-packages.outputs.packages) }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build test lint --filter=${{ matrix.package }}
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}
```

### OS + Node Version Matrix

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, windows-latest, macos-latest]
    node: [18, 20, 22]
    exclude:
      - os: windows-latest
        node: 18
```

---

## Remote Caching in CI

### Vercel Remote Cache Setup

```yaml
env:
  TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
  TURBO_TEAM: ${{ vars.TURBO_TEAM }}
  # Optional: increase timeout for slow networks
  TURBO_API_TIMEOUT: 60000
```

**Creating the token:**
1. Go to Vercel → Settings → Tokens
2. Create a token with scope "turbo" or full account access
3. Add as `TURBO_TOKEN` in GitHub repo secrets
4. Add team slug as `TURBO_TEAM` in GitHub repo variables

### Self-Hosted Remote Cache in CI

```yaml
env:
  TURBO_TOKEN: ${{ secrets.TURBO_CACHE_TOKEN }}
  TURBO_TEAM: my-team
  TURBO_API: ${{ vars.TURBO_CACHE_URL }}
```

Popular self-hosted options:
- [`ducktors/turborepo-remote-cache`](https://github.com/ducktors/turborepo-remote-cache) — Node.js server with S3/GCS/Azure backend
- [`fox1t/turborepo-remote-cache`](https://github.com/fox1t/turborepo-remote-cache) — Fastify-based, supports multiple storage backends

### Remote Cache with Read-Only Mode

For pull requests from forks (untrusted), use read-only cache:

```yaml
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build test
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}
          TURBO_REMOTE_CACHE_READ_ONLY: ${{ github.event.pull_request.head.repo.fork && 'true' || 'false' }}
```

---

## Artifact Caching

### Caching `node_modules` with pnpm Store

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: 20
    cache: pnpm  # Built-in pnpm caching via setup-node

- run: pnpm install --frozen-lockfile
```

This caches the pnpm store (`~/.local/share/pnpm/store`). It's fast because pnpm hard-links from store to `node_modules`.

### Manual Cache for Custom Directories

```yaml
- uses: actions/cache@v4
  with:
    path: |
      node_modules
      apps/*/node_modules
      packages/*/node_modules
    key: node-modules-${{ runner.os }}-${{ hashFiles('pnpm-lock.yaml') }}
    restore-keys: |
      node-modules-${{ runner.os }}-
```

### Caching Turbo Local Cache

If NOT using remote cache, you can cache `.turbo` locally:

```yaml
- uses: actions/cache@v4
  with:
    path: .turbo
    key: turbo-${{ runner.os }}-${{ github.sha }}
    restore-keys: |
      turbo-${{ runner.os }}-
```

**Note:** This is redundant if using Vercel remote cache. Choose one approach.

### Caching Build Outputs for Downstream Jobs

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build
      - uses: actions/upload-artifact@v4
        with:
          name: build-output
          path: |
            apps/*/dist
            apps/*/.next
            packages/*/dist
          retention-days: 1

  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: build-output
      - run: pnpm turbo run test
```

---

## Parallelization Strategies

### Turbo's Built-in Parallelization

Turborepo parallelizes tasks automatically based on the dependency graph. No manual configuration needed for most cases.

```bash
# Default: uses all available CPU cores
turbo run build test lint

# Task execution order:
# 1. Independent tasks (lint on all packages) — parallel
# 2. Leaf packages build — parallel
# 3. Dependent packages build — after their deps
# 4. Tests — after builds complete
```

### Splitting Across GitHub Actions Jobs

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run lint typecheck
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run test
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}

  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}
```

Each job runs independently. Remote cache prevents duplicate work — if `build` finishes first, `test` will use cached build artifacts via remote cache.

### Affected-Only CI

Only run tasks for packages changed in a PR:

```yaml
- run: pnpm turbo run build test lint --filter='...[origin/main...HEAD]'
```

This dramatically reduces CI time for large monorepos. The `...` prefix means "also run on dependents of changed packages."

---

## Pruned Installs

### Reducing Install Time with `turbo prune`

Instead of installing ALL workspace dependencies, prune to only what's needed:

```yaml
jobs:
  build-api:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - name: Prune workspace
        run: npx turbo prune @myorg/api --docker
      - name: Install pruned dependencies
        run: |
          cd out
          pnpm install --frozen-lockfile
      - name: Build
        run: |
          cd out
          pnpm turbo run build --filter=@myorg/api
```

**Savings:** A 50-package monorepo where `@myorg/api` only depends on 5 packages installs ~90% fewer dependencies.

### Pruned Install Script for CI

```bash
#!/usr/bin/env bash
# Prune and install for a specific package
set -euo pipefail

PACKAGE=${1:?Usage: prune-install.sh <package-name>}

npx turbo prune "$PACKAGE" --docker
cd out
pnpm install --frozen-lockfile
pnpm turbo run build --filter="$PACKAGE"
```

---

## Docker Layer Caching with turbo prune

### Optimized Multi-Stage Dockerfile

```dockerfile
# ---- Base ----
FROM node:20-slim AS base
RUN corepack enable && corepack prepare pnpm@9 --activate
WORKDIR /app

# ---- Pruner ----
FROM base AS pruner
COPY . .
RUN pnpm turbo prune @myorg/api --docker

# ---- Dependencies ----
FROM base AS deps
# Copy ONLY package.json files (changes rarely → cached layer)
COPY --from=pruner /app/out/json/ .
# Copy pnpm files
COPY --from=pruner /app/out/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=pruner /app/out/pnpm-workspace.yaml ./pnpm-workspace.yaml
# Install deps (cached unless package.json changes)
RUN pnpm install --frozen-lockfile --prod=false

# ---- Builder ----
FROM base AS builder
COPY --from=deps /app/ .
# Copy full source (changes often → this layer rebuilds)
COPY --from=pruner /app/out/full/ .
RUN pnpm turbo run build --filter=@myorg/api
# Remove dev dependencies
RUN pnpm prune --prod

# ---- Runner ----
FROM node:20-slim AS runner
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 appuser
WORKDIR /app

COPY --from=builder --chown=appuser:nodejs /app/apps/api/dist ./dist
COPY --from=builder --chown=appuser:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:nodejs /app/apps/api/package.json ./package.json

USER appuser
EXPOSE 3000
CMD ["node", "dist/server.js"]
```

### Docker Build with GitHub Actions

```yaml
jobs:
  docker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: ${{ github.ref == 'refs/heads/main' }}
          tags: ghcr.io/${{ github.repository }}/api:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          build-args: |
            NODE_ENV=production
```

### Layer Caching Strategy

```
Layer 1: Base image (node:20-slim)          → rarely changes
Layer 2: Package manager (pnpm)              → rarely changes
Layer 3: package.json files (from json/)     → changes when deps change
Layer 4: pnpm install                        → changes when deps change
Layer 5: Source code (from full/)            → changes every commit
Layer 6: turbo run build                     → changes every commit
Layer 7: Prune to production                 → changes when deps change
Layer 8: Copy to runner                      → changes every commit
```

The key insight: separating `json/` (package.json files) from `full/` (source code) means the expensive `pnpm install` layer is only invalidated when dependencies change, not on every source code change.

---

## Vercel Deployment

### Monorepo on Vercel

Vercel natively supports Turborepo monorepos. Each app gets its own Vercel project:

1. **Import repo** to Vercel
2. **Set root directory** to the app (e.g., `apps/web`)
3. **Framework preset** is auto-detected
4. **Build command**: `cd ../.. && pnpm turbo run build --filter=@myorg/web`
5. **Output directory**: `.next` (or `dist`)

### `vercel.json` for Monorepo Apps

```json
// apps/web/vercel.json
{
  "buildCommand": "cd ../.. && pnpm turbo run build --filter=@myorg/web",
  "installCommand": "cd ../.. && pnpm install --frozen-lockfile",
  "framework": "nextjs",
  "outputDirectory": ".next"
}
```

### Remote Cache in Vercel

Vercel automatically enables remote caching for Turborepo projects. No additional configuration needed when deploying to Vercel.

For non-Vercel deployments that still want Vercel's remote cache:

```yaml
# In CI
env:
  TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
  TURBO_TEAM: ${{ vars.TURBO_TEAM }}
```

### Ignored Build Step

Skip Vercel rebuilds when the app's code hasn't changed:

```bash
# vercel-ignore.sh — set as "Ignored Build Step" in Vercel project settings
#!/bin/bash
# Check if this app or its dependencies changed
npx turbo-ignore @myorg/web
```

`turbo-ignore` exits 0 (skip build) if no relevant changes, exits 1 (proceed) if changes detected. Saves build minutes.

---

## Preview Deployments Per Package

### Per-App Preview Deployments on Vercel

Each app can have its own Vercel project. PRs automatically get preview URLs per app.

### Custom Preview Deployments with GitHub Actions

```yaml
name: Preview Deploy
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      web: ${{ steps.changes.outputs.web }}
      docs: ${{ steps.changes.outputs.docs }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: changes
        run: |
          # Check if web app or its deps changed
          if npx turbo run build --filter=@myorg/web...[origin/main...HEAD] --dry=json 2>/dev/null | jq -e '.tasks | length > 0' > /dev/null; then
            echo "web=true" >> $GITHUB_OUTPUT
          else
            echo "web=false" >> $GITHUB_OUTPUT
          fi
          # Check docs
          if npx turbo run build --filter=@myorg/docs...[origin/main...HEAD] --dry=json 2>/dev/null | jq -e '.tasks | length > 0' > /dev/null; then
            echo "docs=true" >> $GITHUB_OUTPUT
          else
            echo "docs=false" >> $GITHUB_OUTPUT
          fi

  deploy-web-preview:
    needs: detect-changes
    if: needs.detect-changes.outputs.web == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build --filter=@myorg/web
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}
      - name: Deploy preview
        id: deploy
        run: |
          # Deploy to your hosting provider (e.g., Vercel, Netlify, Cloudflare)
          URL=$(npx vercel deploy apps/web --prebuilt --token=${{ secrets.VERCEL_TOKEN }})
          echo "url=$URL" >> $GITHUB_OUTPUT
      - name: Comment PR
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `🚀 Web preview deployed: ${{ steps.deploy.outputs.url }}`
            })

  deploy-docs-preview:
    needs: detect-changes
    if: needs.detect-changes.outputs.docs == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... similar to web preview
```

### Cleanup Preview Deployments

```yaml
name: Cleanup Previews
on:
  pull_request:
    types: [closed]

jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - name: Delete preview deployments
        run: |
          # Clean up preview environments for the closed PR
          echo "Cleaning up previews for PR #${{ github.event.pull_request.number }}"
          # Add your cleanup logic here (delete Vercel deployments, Cloudflare previews, etc.)
```

---

## Advanced CI Patterns

### Conditional Job Execution Based on Changes

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      has-app-changes: ${{ steps.filter.outputs.apps }}
      has-pkg-changes: ${{ steps.filter.outputs.packages }}
      has-infra-changes: ${{ steps.filter.outputs.infra }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            apps:
              - 'apps/**'
            packages:
              - 'packages/**'
            infra:
              - 'infra/**'
              - 'terraform/**'
              - 'docker/**'

  build-and-test:
    needs: changes
    if: needs.changes.outputs.has-app-changes == 'true' || needs.changes.outputs.has-pkg-changes == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build test lint --filter='...[origin/main...HEAD]'
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}

  deploy-infra:
    needs: changes
    if: needs.changes.outputs.has-infra-changes == 'true' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      # ... infrastructure deployment
```

### Release Pipeline

```yaml
name: Release
on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.BOT_TOKEN }}  # Token with push permissions
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: pnpm
          registry-url: https://registry.npmjs.org/
      - run: pnpm install --frozen-lockfile
      - run: pnpm turbo run build test
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ vars.TURBO_TEAM }}
      - name: Create release PR or publish
        uses: changesets/action@v1
        with:
          publish: pnpm changeset publish
          version: pnpm changeset version
          commit: "ci: version packages"
          title: "ci: version packages"
        env:
          GITHUB_TOKEN: ${{ secrets.BOT_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### Reusable Workflow for Monorepo

```yaml
# .github/workflows/reusable-ci.yml
name: Reusable CI
on:
  workflow_call:
    inputs:
      filter:
        type: string
        default: ''
      tasks:
        type: string
        default: 'build test lint'
    secrets:
      TURBO_TOKEN:
        required: true
      TURBO_TEAM:
        required: true

jobs:
  ci:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: |
          FILTER="${{ inputs.filter }}"
          pnpm turbo run ${{ inputs.tasks }} ${FILTER:+--filter="$FILTER"}
        env:
          TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
          TURBO_TEAM: ${{ secrets.TURBO_TEAM }}
```

Usage:

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  all:
    uses: ./.github/workflows/reusable-ci.yml
    secrets:
      TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
      TURBO_TEAM: ${{ vars.TURBO_TEAM }}

  affected:
    uses: ./.github/workflows/reusable-ci.yml
    with:
      filter: '...[origin/main...HEAD]'
    secrets:
      TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
      TURBO_TEAM: ${{ vars.TURBO_TEAM }}
```

---

## CI Performance Checklist

| Optimization | Impact | Effort |
|---|---|---|
| Enable remote caching | ⬆⬆⬆ | Low |
| Use `--filter='...[origin/main...HEAD]'` for PRs | ⬆⬆⬆ | Low |
| Cache `node_modules` / pnpm store | ⬆⬆ | Low |
| Use `pnpm install --frozen-lockfile` | ⬆ | Low |
| Fetch full git history (`fetch-depth: 0`) | Required for git filters | Low |
| Split CI into parallel jobs | ⬆⬆ | Medium |
| Use `inputs` to narrow cache hash scope | ⬆⬆ | Medium |
| Use `turbo prune` for Docker builds | ⬆⬆ | Medium |
| Use `turbo-ignore` for Vercel | ⬆ | Low |
| Docker BuildKit layer caching (`cache-from: type=gha`) | ⬆⬆ | Medium |
| Dynamic matrix based on affected packages | ⬆⬆ | High |
| Reusable workflows for consistency | Maintenance | Medium |
| Set `timeout-minutes` on all jobs | Safety | Low |
| Use `fail-fast: false` in matrix | Debugging | Low |

### Typical CI Times for a 20-Package Monorepo

| Scenario | Without Turbo | With Turbo (cold) | With Turbo (warm cache) |
|---|---|---|---|
| Full build + test + lint | 15-25 min | 8-12 min | 1-3 min |
| PR (affected only) | 15-25 min | 3-5 min | 30s-2 min |
| Docker image build | 10-15 min | 5-8 min | 2-4 min |
