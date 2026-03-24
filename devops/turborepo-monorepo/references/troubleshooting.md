# Turborepo Troubleshooting Guide

## Table of Contents

- [Cache Misses](#cache-misses)
- [Task Dependency Issues](#task-dependency-issues)
- [Circular Dependencies](#circular-dependencies)
- [Environment Variable Leaks](#environment-variable-leaks)
- [Remote Cache Failures](#remote-cache-failures)
- [Docker Build Problems](#docker-build-problems)
- [pnpm Workspace Issues](#pnpm-workspace-issues)
- [Version Conflicts](#version-conflicts)
- [Turbo Daemon Issues](#turbo-daemon-issues)
- [Performance Issues](#performance-issues)
- [Common Error Messages](#common-error-messages)

---

## Cache Misses

### Diagnosing Cache Misses with `--dry` and `--summarize`

```bash
# Preview what would run and why (no execution)
turbo run build --dry=json

# Run with summary (after execution)
turbo run build --summarize
```

The summary output shows per-task cache status. Look for `"cacheStatus": "MISS"`.

### Comparing Cache Inputs Between Runs

```bash
# Run build with summary, save the output
turbo run build --summarize 2>&1 | tee build-summary-1.txt

# Make changes, run again
turbo run build --summarize 2>&1 | tee build-summary-2.txt

# Compare
diff build-summary-1.txt build-summary-2.txt
```

### Common Causes of Unexpected Cache Misses

| Cause | Symptom | Fix |
|---|---|---|
| Unlisted env var changes | Cache misses after env change | Add variable to `env` in turbo.json |
| Timestamp-based files | Cache misses every run | Add file to `.gitignore` or exclude with `inputs` |
| Generated files in workspace | Hash changes unpredictably | Move generated files to `outputs`, add source to `inputs` |
| Missing `outputs` declaration | Cache restores but files are missing | Declare all output directories in `outputs` |
| `globalDependencies` changed | Every task misses | Check if `tsconfig.json`, lockfile, or `.env` changed |
| Different Node.js version | Misses between local and CI | Standardize Node version with `.nvmrc` or `engines` |
| OS-specific line endings | Misses between Windows/Mac/Linux | Configure `.gitattributes` with `* text=auto eol=lf` |
| Lockfile churn | Miss when deps haven't really changed | Pin exact versions; avoid `^` ranges for internal deps |

### Using `--verbosity` for Deeper Debug

```bash
# Maximum verbosity
turbo run build --verbosity=2

# Check the hash inputs in the dry run JSON
turbo run build --dry=json 2>/dev/null | jq '.tasks[] | {package, taskId, hash, hashOfExternalDependencies, environmentVariables}'
```

### Force Rebuild to Confirm Caching Works

```bash
# Force full rebuild (ignore cache)
turbo run build --force

# Immediately run again (should be full cache hit)
turbo run build --summarize
```

If the second run is NOT a full cache hit, you have non-deterministic inputs.

---

## Task Dependency Issues

### Task Never Runs

**Symptom:** `turbo run build` skips a workspace.

**Causes and fixes:**

1. **No `build` script in `package.json`** — Turborepo only runs tasks that exist as scripts
   ```bash
   # Check which workspaces have the script
   turbo run build --dry=json | jq '.tasks[].package'
   ```

2. **`--filter` excluding the package** — Verify filter includes it
   ```bash
   turbo run build --filter=@myorg/ui --dry
   ```

3. **Package not in workspace** — Verify `pnpm-workspace.yaml` or root `package.json` workspaces field includes the directory

### Task Runs Too Early

**Symptom:** Build fails because a dependency hasn't been built yet.

**Fix:** Ensure `^build` in `dependsOn`:

```json
{
  "tasks": {
    "build": {
      "dependsOn": ["^build"]
    }
  }
}
```

Without `^`, `dependsOn: ["build"]` means "run MY build task first" (same package), not "run dependency builds first."

### Task Graph Visualization

```bash
# Generate a DOT graph file
turbo run build --graph=graph.dot

# Or generate SVG directly (requires graphviz)
turbo run build --graph=graph.svg

# Interactive graph in the browser
turbo run build --graph
```

### Deadlocked Tasks

**Symptom:** Tasks hang indefinitely.

**Causes:**
- `persistent: true` task listed as dependency of another task
- Circular `dependsOn` references

```json
// WRONG: dev is persistent but lint depends on it
{
  "tasks": {
    "dev": { "persistent": true },
    "lint": { "dependsOn": ["dev"] }  // Will never complete!
  }
}
```

**Fix:** Never make non-persistent tasks depend on persistent tasks.

---

## Circular Dependencies

### Detecting Circular Dependencies

```bash
# Turborepo will error on circular task dependencies
turbo run build --dry 2>&1 | grep -i "circular"

# For workspace (package) circular dependencies, use pnpm
pnpm ls --depth 0 -r 2>&1 | grep -i "circular"

# Or use madge for TypeScript import cycles
npx madge --circular --extensions ts,tsx apps/web/src/
```

### Common Circular Dependency Patterns

**Pattern 1: Two packages importing each other**

```
@myorg/auth → imports from → @myorg/database
@myorg/database → imports from → @myorg/auth  ← CIRCULAR
```

**Fix:** Extract shared types/interfaces into a third package:

```
@myorg/auth → @myorg/types ← @myorg/database
```

**Pattern 2: Type-only circular deps**

If the cycle is only through type imports, extract a shared types package:

```typescript
// packages/types/src/index.ts
export interface User { id: string; email: string; }
export interface Session { userId: string; token: string; }
```

**Pattern 3: Runtime function circular deps**

Use dependency injection or events to break the cycle:

```typescript
// Instead of direct import, accept the dependency as a parameter
export function createAuthService(db: DatabaseClient) { ... }
```

### Preventing Circular Dependencies in CI

```bash
# Add to CI pipeline
npx madge --circular --extensions ts,tsx packages/ apps/
# Exit code 1 if cycles found
```

---

## Environment Variable Leaks

### Problem: Unlisted Env Vars Causing Stale Cache

If a task depends on an env var not listed in `env`, cache hits may return stale results.

**Detection:**

```bash
# See which env vars Turbo is tracking for a task
turbo run build --dry=json | jq '.tasks[] | select(.package == "@myorg/web") | .environmentVariables'
```

**Fix:** List ALL env vars that affect build output:

```json
{
  "tasks": {
    "build": {
      "env": [
        "NODE_ENV",
        "NEXT_PUBLIC_*",
        "API_URL",
        "DATABASE_URL"
      ]
    }
  }
}
```

### Problem: Sensitive Vars in Cache

If secrets are baked into build output and cached, they could leak.

**Fix:** Use `passThroughEnv` for secrets that shouldn't affect cache key:

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

Or disable caching entirely for tasks that use secrets.

### Framework-Specific Env Var Patterns

| Framework | Auto-inlined vars | Turbo config |
|---|---|---|
| Next.js | `NEXT_PUBLIC_*` | `"env": ["NEXT_PUBLIC_*"]` |
| Vite | `VITE_*` | `"env": ["VITE_*"]` |
| Create React App | `REACT_APP_*` | `"env": ["REACT_APP_*"]` |
| Remix | (none by default) | List explicitly |

### Strict Env Mode

Turborepo v2 introduced strict env mode. Unknown env vars cause task failures:

```json
{
  "globalPassThroughEnv": ["PATH", "HOME", "SHELL"],
  "tasks": {
    "build": {
      "env": ["NODE_ENV", "API_URL"],
      "passThroughEnv": ["CI"]
    }
  }
}
```

---

## Remote Cache Failures

### Authentication Issues

```bash
# Re-authenticate
turbo logout
turbo login

# Verify authentication
turbo link
```

For CI, ensure env vars are set:

```bash
echo "TURBO_TOKEN is set: ${TURBO_TOKEN:+yes}"
echo "TURBO_TEAM is set: ${TURBO_TEAM:+yes}"
```

### Cache Upload/Download Failures

**Symptom:** `WARN  Failed to upload artifact` or `WARN  Failed to download artifact`

**Causes:**
- Network timeout — increase with `TURBO_API_TIMEOUT` (milliseconds)
- Artifact too large — check if outputs include unnecessary files
- Rate limiting — Vercel free tier has limits

```bash
# Increase timeout
export TURBO_API_TIMEOUT=60000

# Debug remote cache connectivity
curl -H "Authorization: Bearer $TURBO_TOKEN" \
  "https://vercel.com/api/v8/artifacts/status"
```

### Self-Hosted Cache Server Issues

```bash
# Verify server is reachable
curl -v "$TURBO_API/v8/artifacts/status" \
  -H "Authorization: Bearer $TURBO_TOKEN"

# Check server logs for errors
# Common issues: disk full, permission errors, token mismatch
```

### Disabling Remote Cache Temporarily

```bash
# Skip remote cache for this run
turbo run build --remote-cache-read-only
# Or
turbo run build --no-cache
```

---

## Docker Build Problems

### `turbo prune` Output Issues

**Symptom:** `turbo prune` includes too many or too few packages.

```bash
# Preview what prune will include
turbo prune @myorg/api --docker --dry
# This is not a real flag — instead, inspect the output directory
turbo prune @myorg/api --docker
ls -la out/json/ out/full/
```

**Common issues:**
- Missing packages in output → workspace dependency not declared in `package.json`
- Too many packages → unintended transitive dependency; audit with `turbo run build --filter=@myorg/api... --dry`

### Lockfile Mismatch After Prune

**Symptom:** `pnpm install --frozen-lockfile` fails inside Docker after `turbo prune`.

**Fix:** Ensure the lockfile in `out/` matches. Common causes:
- Different pnpm version between local and Docker
- Lockfile not committed to git
- `.npmrc` not copied into Docker

```dockerfile
# Copy .npmrc alongside pruned lockfile
COPY --from=pruner /app/out/pnpm-lock.yaml .
COPY --from=pruner /app/.npmrc .  # If you have one
RUN pnpm install --frozen-lockfile
```

### Multi-Stage Build Failures

**Symptom:** Build succeeds locally but fails in Docker.

**Checklist:**
1. Are ALL workspace dependencies included in `out/full/`?
2. Is the correct package manager installed in the Docker image?
3. Are native dependencies (node-gyp) supported in the base image?
4. Are env vars available at build time?

```dockerfile
# Pass build-time env vars
ARG NODE_ENV=production
ARG API_URL
ENV NODE_ENV=$NODE_ENV
ENV API_URL=$API_URL
```

### Docker Build Cache Invalidation

**Problem:** Changing ANY source file invalidates the `pnpm install` layer.

**Fix:** Use `turbo prune --docker` to separate `json/` and `full/`:

```dockerfile
# This layer ONLY changes when package.json files change
COPY --from=pruner /app/out/json/ .
RUN pnpm install --frozen-lockfile

# This layer changes when source code changes
COPY --from=pruner /app/out/full/ .
RUN pnpm turbo run build --filter=@myorg/api
```

---

## pnpm Workspace Issues

### "Cannot find module" Errors

**Symptom:** Package can't resolve an internal dependency.

**Fixes:**

1. Ensure workspace protocol in `package.json`:
   ```json
   { "dependencies": { "@myorg/utils": "workspace:*" } }
   ```

2. Run `pnpm install` to update symlinks:
   ```bash
   pnpm install
   ```

3. Check that the target package's `main`/`exports` points to the correct file:
   ```json
   { "main": "./src/index.ts", "exports": { ".": "./src/index.ts" } }
   ```

### Hoisting Issues

**Symptom:** Package works in dev but fails in production, or phantom dependencies.

**Fix:** Configure `.npmrc`:

```ini
# .npmrc
shamefully-hoist=false
strict-peer-dependencies=true
auto-install-peers=true
```

### Workspace Protocol in Dependencies

`workspace:*` is replaced with the actual version during `pnpm publish`. For private packages (never published), this doesn't matter.

```json
// During development:
{ "@myorg/utils": "workspace:*" }

// After pnpm publish transforms:
{ "@myorg/utils": "^1.2.3" }
```

### pnpm Catalogs (pnpm v9+)

Centralize dependency versions across workspaces:

```yaml
# pnpm-workspace.yaml
packages:
  - "apps/*"
  - "packages/*"
catalogs:
  default:
    react: "^18.3.0"
    typescript: "^5.5.0"
```

```json
// Any package.json
{ "dependencies": { "react": "catalog:" } }
```

---

## Version Conflicts

### Multiple Versions of Same Dependency

**Symptom:** Bundle size bloat, runtime errors from version mismatches (e.g., two Reacts).

**Detection:**

```bash
# pnpm
pnpm why react
pnpm ls react --depth 10

# Check for duplicates
pnpm ls --depth 1 -r | grep "react@" | sort | uniq -c | sort -rn
```

**Fixes:**

1. **pnpm overrides** in root `package.json`:
   ```json
   { "pnpm": { "overrides": { "react": "^18.3.0" } } }
   ```

2. **Catalog** (pnpm v9+): centralize versions in `pnpm-workspace.yaml`

3. **Dedicated deps package**:
   ```json
   // packages/deps/package.json
   {
     "name": "@myorg/deps",
     "dependencies": { "react": "^18.3.0", "react-dom": "^18.3.0" }
   }
   ```

### TypeScript Version Conflicts

**Symptom:** Different TypeScript versions produce incompatible declarations.

**Fix:** Use a single TypeScript version via root `package.json`:

```json
// root package.json
{
  "devDependencies": { "typescript": "^5.5.0" }
}
```

And extend shared `tsconfig` from `packages/config-typescript/`.

---

## Turbo Daemon Issues

### Daemon Won't Start / Stale Daemon

```bash
# Check daemon status
turbo daemon status

# Stop the daemon
turbo daemon stop

# Force restart by stopping and running a task
turbo daemon stop && turbo run build

# Clear daemon state
rm -rf .turbo/daemon
```

### Daemon Using Too Much Memory

**Symptom:** System slows down; daemon process consuming excessive RAM.

```bash
# Check daemon process
ps aux | grep "turbo daemon"

# Restart daemon
turbo daemon stop
turbo daemon start
```

### File Watching Issues

**Symptom:** Daemon doesn't detect file changes (stale results in interactive mode).

**Fixes:**
- Increase file watcher limit: `echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p`
- Restart daemon: `turbo daemon stop`
- Verify `.gitignore` isn't overly broad (daemon uses git to track files)

---

## Performance Issues

### Slow First Run After Cache Clear

Expected behavior — Turborepo must build everything. Subsequent runs use cache.

### Task Concurrency Tuning

```bash
# Default: uses all CPU cores
turbo run build

# Limit to prevent OOM on large monorepos
turbo run build --concurrency=4
turbo run build --concurrency=50%

# For memory-heavy tasks (e.g., Next.js builds)
turbo run build --concurrency=2
```

### Large Monorepo Optimization

- Use `inputs` to limit hash computation to relevant files
- Split large packages into smaller, focused packages
- Use `--filter` in CI to only build/test affected packages
- Enable remote caching to share across CI runs and developers

### Profiling Turbo Execution

```bash
# Generate a performance profile
turbo run build --profile=profile.json

# Open in Chrome DevTools: chrome://tracing
# Or Perfetto: https://ui.perfetto.dev/
```

---

## Common Error Messages

| Error | Cause | Fix |
|---|---|---|
| `"pipeline" is no longer supported` | Using v1 config with v2 binary | Run `npx @turbo/codemod migrate-to-turbo-v2` |
| `Could not find turbo.json` | turbo.json missing from repo root | Create `turbo.json` in project root |
| `No tasks found in turbo.json` | Empty `tasks` object | Define at least one task |
| `ERROR  run failed: error preparing engine: Invalid task dependency` | Invalid `dependsOn` syntax | Check `^` usage and task names |
| `WARN  no packages matched the provided filter` | `--filter` doesn't match any package | Verify package name or path |
| `x]INTERNAL ERROR: failed to resolve packages` | Workspace config issue | Check `pnpm-workspace.yaml` / root `package.json` workspaces |
| `command not found: turbo` | turbo not installed | `pnpm add turbo -Dw` and use `npx turbo` or `pnpm turbo` |
| `WARN cache miss, executing <hash>` | Cache miss (maybe expected) | Run with `--summarize` to diagnose |
| `unauthorized: forbidden` (remote cache) | Invalid token or team | Re-run `turbo login && turbo link` |
| `failed to contact remote cache` | Network or server issue | Check `TURBO_API`, `TURBO_TOKEN` env vars |
