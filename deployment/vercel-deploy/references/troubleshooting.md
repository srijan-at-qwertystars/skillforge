# Vercel Troubleshooting Guide

## Table of Contents
- [Build Failures by Framework](#build-failures-by-framework)
  - [Next.js](#nextjs-build-failures)
  - [SvelteKit](#sveltekit-build-failures)
  - [Nuxt 3](#nuxt-3-build-failures)
  - [Astro](#astro-build-failures)
  - [Vite / React SPA](#vite--react-spa-build-failures)
  - [General Build Failures](#general-build-failures)
- [Function Timeout and Memory Issues](#function-timeout-and-memory-issues)
- [Cold Start Optimization](#cold-start-optimization)
- [Environment Variable Not Available](#environment-variable-not-available)
- [Preview Deployment Issues](#preview-deployment-issues)
- [Custom Domain DNS Propagation](#custom-domain-dns-propagation)
- [CORS and Headers Configuration](#cors-and-headers-configuration)
- [Monorepo Root Directory Issues](#monorepo-root-directory-issues)
- [Deployment Stuck or Failing](#deployment-stuck-or-failing)
- [Storage Issues](#storage-issues)
- [Performance Degradation](#performance-degradation)

---

## Build Failures by Framework

### Next.js Build Failures

**Error: `out of memory` / `JavaScript heap out of memory`**
```
FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed - JavaScript heap out of memory
```
Fix:
```jsonc
// vercel.json
{
  "build": {
    "env": { "NODE_OPTIONS": "--max-old-space-size=4096" }
  }
}
```
Also check for: circular dependencies, large static imports, unoptimized images in `public/`.

**Error: `Module not found` in production but works locally**
- Check case sensitivity: Linux (Vercel) is case-sensitive, macOS is not.
  ```bash
  # Find case mismatches
  git config core.ignorecase false
  git ls-files | sort -f | uniq -di
  ```
- Verify `tsconfig.json` paths aliases match `next.config.js` webpack config.
- Check that dependencies are in `dependencies`, not just `devDependencies`.

**Error: `Dynamic server usage` / `opted into dynamic rendering`**
```
Error: Dynamic server usage: headers
```
Fix: This is expected. The page uses `headers()`, `cookies()`, or `searchParams`. It cannot be statically generated. Either:
1. Accept SSR: remove `export const dynamic = 'force-static'`
2. Move dynamic logic to client components or API routes

**Error: `generateStaticParams` timeout**
```
Error: Collecting page data timed out after 60s
```
Fix: Reduce the number of paths or increase timeout:
```js
// next.config.js
module.exports = { staticPageGenerationTimeout: 300 }; // 5 minutes
```

**Error: `Image Optimization` failures**
```
Error: Unable to optimize image
```
Fix:
- Ensure `remotePatterns` in `next.config.js` includes the image domain
- Check image URL is accessible from Vercel's servers
- Verify image format is supported (JPEG, PNG, WebP, AVIF, GIF, TIFF)

### SvelteKit Build Failures

**Error: `adapter-vercel` not installed**
```
Error: @sveltejs/adapter-vercel is not installed
```
Fix:
```bash
npm install -D @sveltejs/adapter-vercel
```
```js
// svelte.config.js
import adapter from '@sveltejs/adapter-vercel';
export default { kit: { adapter: adapter() } };
```

**Error: Prerendering failures**
```
Error: 500 /some-page (Error: fetch failed)
```
Fix: Pages marked `export const prerender = true` must not call APIs that don't exist at build time. Use `prerender = false` for dynamic pages or provide fallback data.

### Nuxt 3 Build Failures

**Error: Nitro preset not detected**
```
Error: Cannot find module '.output/server/index.mjs'
```
Fix: Explicitly set the preset:
```ts
// nuxt.config.ts
export default defineNuxtConfig({ nitro: { preset: 'vercel' } });
```

**Error: `ENOENT` on `.output` directory**
Ensure `outputDirectory` is not set in `vercel.json` for Nuxt. Nuxt/Nitro uses Build Output API and writes directly to `.vercel/output/`.

### Astro Build Failures

**Error: No adapter configured for SSR**
```
Error: Cannot use `output: 'server'` without an adapter
```
Fix:
```bash
npx astro add vercel
```
```js
// astro.config.mjs
import vercel from '@astrojs/vercel';
export default defineConfig({
  output: 'hybrid', // or 'server'
  adapter: vercel(),
});
```

### Vite / React SPA Build Failures

**Error: 404 on client-side routes after deploy**
Vite SPAs need a catch-all rewrite:
```jsonc
// vercel.json
{
  "rewrites": [
    { "source": "/(.*)", "destination": "/index.html" }
  ]
}
```

**Error: Environment variables not available in client code**
Vite requires `VITE_` prefix. Vercel env vars without this prefix are server-only:
```bash
# Dashboard or CLI — must use VITE_ prefix
VITE_API_URL=https://api.example.com
```

### General Build Failures

**Error: `npm ERR! ERESOLVE` peer dependency conflicts**
Fix:
```jsonc
// vercel.json
{ "installCommand": "npm install --legacy-peer-deps" }
```
Or use `--force` for pnpm/yarn equivalents.

**Error: Build exceeds max duration (45 min)**
- Optimize build: reduce static page count, use ISR instead of SSG for large datasets
- Split monorepo builds with `turbo-ignore`
- Use `--frozen-lockfile` to skip lockfile generation

**Error: `ENOSPC: no space left on device`**
The build environment has limited disk space. Solutions:
- Remove unnecessary files from the repo
- Use `.vercelignore` to exclude large files:
  ```
  # .vercelignore
  docs/
  tests/
  *.psd
  *.sketch
  ```
- Clean build cache: deploy with `vercel deploy --force`

---

## Function Timeout and Memory Issues

### Timeout Errors

**Error: `FUNCTION_INVOCATION_TIMEOUT`**
```
Error: Task timed out after 10.00 seconds
```

Plan limits:
| Plan | Serverless Max Duration | Edge Max Duration |
|------|------------------------|-------------------|
| Hobby | 10s | 25s (initial response) |
| Pro | 60s (default), up to 300s | 25s |
| Enterprise | Up to 900s | 25s |

Fix in `vercel.json`:
```jsonc
{
  "functions": {
    "api/long-task.ts": { "maxDuration": 60 }
  }
}
```

In Next.js App Router:
```ts
// app/api/long-task/route.ts
export const maxDuration = 60; // seconds
```

**Strategies for long-running tasks:**
1. **Background processing:** Return immediately, process via queue (Upstash QStash)
2. **Streaming:** Use `ReadableStream` for incremental responses
3. **Split work:** Break into smaller functions called sequentially
4. **Fluid compute:** Enable in project settings for automatic function splitting

### Memory Errors

**Error: `FUNCTION_INVOCATION_FAILED` with OOM**

Default memory: 1024 MB. Maximum: 3008 MB.

```jsonc
{
  "functions": {
    "api/heavy.ts": { "memory": 3008 }
  }
}
```

**Reduce memory usage:**
- Avoid loading entire files into memory; use streams
- Lazy-load heavy dependencies with dynamic imports
- Move large data processing to external services
- Use Edge functions (lighter runtime) where possible

---

## Cold Start Optimization

### Diagnosis

Cold starts occur when a new serverless function instance spins up. Typical ranges:
- Edge Functions: <50ms (V8 isolates)
- Node.js Functions: 250ms–2s depending on bundle size

### Optimization Strategies

**1. Reduce function bundle size**
```bash
# Analyze bundle size
ANALYZE=true next build  # Next.js with @next/bundle-analyzer
```

```js
// next.config.js
const withBundleAnalyzer = require('@next/bundle-analyzer')({
  enabled: process.env.ANALYZE === 'true',
});
module.exports = withBundleAnalyzer({ /* config */ });
```

**2. Use Edge runtime for latency-sensitive routes**
```ts
export const runtime = 'edge'; // <50ms cold start
```

**3. Dynamic imports for heavy dependencies**
```ts
export async function POST(request: Request) {
  // Only load sharp when needed — not at function init
  const sharp = await import('sharp');
  const buffer = await request.arrayBuffer();
  const resized = await sharp(Buffer.from(buffer)).resize(800).toBuffer();
  return new Response(resized);
}
```

**4. Minimize top-level execution**
```ts
// BAD: runs on every cold start
const db = new Database(process.env.DATABASE_URL);
const schema = await db.introspect(); // Expensive!

// GOOD: lazy initialization
let db: Database | null = null;
function getDb() {
  if (!db) db = new Database(process.env.DATABASE_URL);
  return db;
}
```

**5. Enable Fluid Compute (Pro+)**
Dashboard → Project Settings → Functions → Fluid Compute. This reuses function instances across requests, reducing cold starts.

**6. Use fewer dependencies**
Each `import` adds to bundle. Prefer lightweight alternatives:
- `date-fns` → native `Intl.DateTimeFormat`
- `lodash` → `lodash-es` with tree-shaking, or native methods
- `axios` → native `fetch`
- `uuid` → `crypto.randomUUID()`

---

## Environment Variable Not Available

### Diagnostic Checklist

1. **Check environment target:**
   ```bash
   vercel env ls
   ```
   Ensure the variable is set for the correct environment (Production / Preview / Development).

2. **Client vs server variables:**
   - Next.js: `NEXT_PUBLIC_` prefix for client access
   - Vite: `VITE_` prefix for client access
   - Nuxt: `NUXT_PUBLIC_` or `runtimeConfig.public` in `nuxt.config.ts`
   - SvelteKit: `PUBLIC_` prefix for client access
   - Without prefix, variables are server-only (API routes, SSR)

3. **Build time vs runtime:**
   - Variables available at build time are baked into the bundle
   - For runtime-only variables, use `process.env.VAR` in server code (not during build)
   - Edge Config is the recommended way for runtime configuration

4. **Turbo caching issues:**
   If using Turborepo, declare all env vars in `turbo.json`:
   ```jsonc
   {
     "tasks": {
       "build": {
         "env": ["DATABASE_URL", "NEXT_PUBLIC_API_URL"]
       }
     }
   }
   ```
   Missing env var declarations cause stale cached builds.

5. **`.env.local` not loaded in production:**
   `.env.local` is for local development only. Set production variables via Dashboard or `vercel env add`.

6. **Redeployment needed:**
   After changing env vars, redeploy the application. Env var changes don't apply to existing deployments.

### Common Patterns

**Variable available in `vercel dev` but not in deployment:**
- Likely a client/server mismatch. Add the correct prefix.
- Run `vercel env pull` to sync and verify.

**Variable available in build logs but undefined at runtime:**
- The variable is being inlined at build time. For dynamic runtime values, access via API route or Edge Config.

---

## Preview Deployment Issues

### Preview URL not working

**Symptoms:** Preview deployment shows 404 or wrong content.

**Fixes:**
1. Check build logs in Dashboard → Deployments → click the deployment
2. Verify the correct branch is being deployed
3. Check if `.vercelignore` or `Ignored Build Step` is skipping the build
4. Ensure PR is against a branch connected to the Vercel project

### Preview environment variables

Preview deployments use **Preview** environment variables. If a variable is only set for Production, it won't be available in previews.

```bash
# Set for both environments
vercel env add API_URL production preview
```

### Preview deployment protection

If previews return 401/403:
- Check Dashboard → Settings → Deployment Protection
- Vercel Authentication may be enabled, requiring login
- Share the deployment URL (not the preview alias) with stakeholders
- Use `?token=<bypass-token>` for CI/CD testing

### Comments bot not posting

- Verify GitHub App permissions: the Vercel GitHub App needs write access to PRs
- Check if the bot is disabled in project settings
- For forked PRs, the bot may not have permissions

---

## Custom Domain DNS Propagation

### DNS records not resolving

**Timeline:** DNS changes can take 1–48 hours to propagate globally. Most resolve within 1–4 hours.

**Verification:**
```bash
# Check current DNS resolution
dig example.com A +short
dig www.example.com CNAME +short
nslookup example.com

# Check from different DNS servers
dig @8.8.8.8 example.com A +short      # Google DNS
dig @1.1.1.1 example.com A +short      # Cloudflare DNS
```

### Common DNS issues

**Apex domain (example.com):**
- Must use A record pointing to `76.76.21.21`
- Some registrars don't support ALIAS/ANAME records for apex — use Vercel nameservers instead:
  ```
  ns1.vercel-dns.com
  ns2.vercel-dns.com
  ```

**Subdomain (www.example.com):**
- Use CNAME pointing to `cname.vercel-dns.com`

**Wildcard (*.example.com):**
- Requires Vercel nameservers (cannot use external DNS for wildcards)

**SSL certificate not provisioning:**
- DNS must resolve correctly first
- Check for CAA records blocking Let's Encrypt: `dig example.com CAA`
- If using Cloudflare: set DNS to "DNS only" (gray cloud), not "Proxied" (orange cloud)

**Domain showing "Invalid Configuration":**
1. Verify DNS records match Vercel's recommendations exactly
2. Wait for propagation
3. Click "Refresh" in Domain settings
4. If persists, remove and re-add the domain

---

## CORS and Headers Configuration

### CORS errors on API routes

**Error:** `Access to fetch at '...' has been blocked by CORS policy`

**Fix in vercel.json (applies to all frameworks):**
```jsonc
{
  "headers": [
    {
      "source": "/api/(.*)",
      "headers": [
        { "key": "Access-Control-Allow-Credentials", "value": "true" },
        { "key": "Access-Control-Allow-Origin", "value": "https://app.example.com" },
        { "key": "Access-Control-Allow-Methods", "value": "GET,POST,PUT,DELETE,OPTIONS" },
        { "key": "Access-Control-Allow-Headers", "value": "Content-Type, Authorization, X-Requested-With" }
      ]
    }
  ]
}
```

**Fix in Next.js API route (per-route):**
```ts
// app/api/data/route.ts
export async function GET(request: Request) {
  const data = await getData();
  return Response.json(data, {
    headers: {
      'Access-Control-Allow-Origin': 'https://app.example.com',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    },
  });
}

// Handle preflight
export async function OPTIONS() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': 'https://app.example.com',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Max-Age': '86400',
    },
  });
}
```

### CORS on preview deployments

Preview URLs change per deployment. Use a dynamic origin check:
```ts
export function middleware(request: NextRequest) {
  const origin = request.headers.get('origin') || '';
  const allowedOrigins = [
    'https://app.example.com',
    /^https:\/\/.*\.vercel\.app$/,
  ];
  const isAllowed = allowedOrigins.some(o =>
    typeof o === 'string' ? o === origin : o.test(origin)
  );
  const response = NextResponse.next();
  if (isAllowed) {
    response.headers.set('Access-Control-Allow-Origin', origin);
    response.headers.set('Access-Control-Allow-Credentials', 'true');
  }
  return response;
}
```

### Security headers not applying

- Headers in `vercel.json` apply after middleware. Middleware can override them.
- Order: `vercel.json` headers → middleware → framework headers
- Use `source` glob patterns to match routes. Test with `curl -I <url>`.

---

## Monorepo Root Directory Issues

### Build uses wrong directory

**Symptom:** Build runs in repo root instead of app directory, or vice versa.

**Fix:**
1. Set **Root Directory** in Dashboard → Project Settings → General
2. Or in `vercel.json` at repo root:
   ```jsonc
   { "rootDirectory": "apps/web" }
   ```

### Dependencies not installed

**Symptom:** `Module not found` errors for workspace packages.

**How Vercel handles monorepo installs:**
1. Detects lockfile at repo root
2. Runs `install` command from repo root (so all workspace deps are available)
3. Runs `build` command from root directory

**Fix for missing workspace packages:**
- Ensure `workspace:*` references are in `package.json`
- Verify lockfile is committed and up to date
- Check `installCommand` isn't set to something that skips workspace resolution

### Build output in wrong location

**Symptom:** Deployment succeeds but shows blank page or 404.

```jsonc
// vercel.json — verify outputDirectory is relative to rootDirectory
{
  "rootDirectory": "apps/web",
  "outputDirectory": ".next"  // Relative to apps/web/
}
```

### Environment variables not available in packages

Workspace packages (`packages/*`) inherit env vars from the app that imports them. If a shared package reads `process.env.API_URL`, ensure it's set in the importing app's Vercel project.

For Turborepo, declare cross-package env vars in `turbo.json`:
```jsonc
{
  "globalEnv": ["NODE_ENV", "VERCEL_ENV"],
  "tasks": {
    "build": {
      "env": ["API_URL", "DATABASE_URL"],
      "passThroughEnv": ["npm_package_name"]
    }
  }
}
```

---

## Deployment Stuck or Failing

### Deployment stuck in "Building"

**Possible causes:**
1. **Infinite loop in build script:** Check `buildCommand` for recursive calls
2. **Waiting for network resource:** Build-time API calls timing out
3. **Large static generation:** Thousands of pages being pre-rendered

**Actions:**
- Cancel the deployment from Dashboard → Deployments → "..." → Cancel
- Check build logs for the last output line
- Set `staticPageGenerationTimeout` for Next.js

### Deployment fails with no error

**Check:**
1. Build logs in Dashboard (may show errors not in CLI output)
2. Function logs (Dashboard → Deployments → Functions tab)
3. `vercel logs <deployment-url>` for runtime errors
4. Try local build: `vercel build` to reproduce

### Deployment succeeds but site is broken

**Checklist:**
1. Check browser console for client-side errors
2. Verify environment variables are set for Production
3. Check if API routes are returning errors (inspect Network tab)
4. Compare with preview deployment (may be a production-only issue)
5. Check if caching is serving stale content: `vercel deploy --force`
6. Verify DNS points to the correct deployment

### Rate limiting on deployments

**Error:** `429 Too Many Requests` during deploy
- Hobby: 100 deployments/day
- Pro: 6,000 deployments/day
- Reduce by: using `Ignored Build Step`, consolidating branches, disabling auto-deploy for draft PRs

### Rollback

```bash
# List recent deployments
vercel ls

# Promote a previous deployment to production
vercel promote <deployment-url>

# Or in Dashboard: Deployments → "..." → Promote to Production
```

---

## Storage Issues

### Vercel Postgres connection errors

**Error:** `too many connections`
- Use connection pooling (Vercel Postgres includes built-in pooling via `POSTGRES_URL`)
- Ensure you're using `POSTGRES_URL` (pooled) not `POSTGRES_URL_NON_POOLING` in serverless
- Set connection limits in your ORM:
  ```ts
  // Prisma
  datasource db {
    provider  = "postgresql"
    url       = env("POSTGRES_PRISMA_URL") // Uses connection pooling
    directUrl = env("POSTGRES_URL_NON_POOLING") // For migrations
  }
  ```

### Blob upload failures

**Error:** `BlobAccessError: Access denied`
- Verify `BLOB_READ_WRITE_TOKEN` env var is set
- For client uploads, ensure the `handleUploadUrl` route is correctly configured
- Check file size limits: 500 MB for Pro, 5 GB for Enterprise

### Edge Config read errors

**Error:** `EdgeConfigError: connection string not found`
- Set `EDGE_CONFIG` env var (auto-set when connected via Dashboard)
- Verify Edge Config store is connected to the project in Dashboard → Storage

---

## Performance Degradation

### Slow function responses

1. **Check function region:** Ensure functions are near your database
   ```bash
   vercel inspect <deployment-url>
   ```
2. **Check cold starts:** Look at function duration in Dashboard → Analytics
3. **Database query optimization:** Add indexes, reduce N+1 queries
4. **Enable caching:** Use `Cache-Control` headers or Upstash Redis

### Large bundle causing slow loads

```bash
# Analyze Next.js bundle
ANALYZE=true npx next build

# Check function sizes
ls -la .vercel/output/functions/
```

Reduce bundle:
- Dynamic imports for heavy components
- Tree-shake with ES modules
- Replace heavy libraries with lighter alternatives
- Use `next/dynamic` with `ssr: false` for client-only components

### High Vercel bill / usage

- Check Dashboard → Usage for bandwidth, function invocations, image optimizations
- Enable caching headers for static assets
- Use ISR instead of SSR where possible
- Optimize images before upload
- Use `vercel.json` regions to limit function regions (reduces cold starts but increases latency for distant users)
