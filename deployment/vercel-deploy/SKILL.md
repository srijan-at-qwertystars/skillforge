---
name: vercel-deploy
description: >
  Vercel deployment, configuration, and platform patterns. USE when: deploying to Vercel,
  configuring vercel.json, writing Edge or Serverless Functions, setting up preview deployments,
  managing environment variables/secrets, configuring custom domains/DNS, using Vercel CLI
  (vercel deploy/env/pull/link), setting up Turborepo monorepos on Vercel, configuring middleware
  or rewrites/redirects, integrating Vercel storage (KV, Blob, Postgres, Edge Config), optimizing
  builds and caching, adding Analytics/Speed Insights, or integrating CI/CD with GitHub/GitLab.
  DO NOT USE for: AWS/GCP/Azure deployment, Docker/Kubernetes orchestration, Netlify configuration,
  self-hosted infrastructure, Cloudflare Workers/Pages (unless comparing), or general frontend
  development unrelated to deployment.
---

# Vercel Deployment & Platform Patterns

## Project Setup & Configuration

### Initial Setup
```bash
# Install CLI globally
npm i -g vercel

# Link local project to Vercel
vercel link

# Pull env vars and project settings locally
vercel pull

# Local development with Vercel runtime
vercel dev
```

### vercel.json — Core Configuration
Place at project root. Use `$schema` for IDE autocomplete:
```jsonc
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "version": 2,
  "framework": "nextjs",
  "buildCommand": "npm run build",
  "installCommand": "npm install",
  "outputDirectory": ".next",
  "regions": ["iad1", "sfo1"],
  "functions": {
    "api/**/*.ts": { "memory": 1024, "maxDuration": 30 }
  },
  "crons": [
    { "path": "/api/cron/cleanup", "schedule": "0 3 * * *" }
  ]
}
```

Key properties:
- `framework`: Auto-detected. Override with `nextjs`, `svelte`, `nuxt`, `astro`, `remix`, `vite`.
- `buildCommand` / `installCommand` / `devCommand`: Override package manager defaults.
- `outputDirectory`: Framework-specific build output (`.next`, `build`, `dist`, `.output`).
- `regions`: Deploy functions to specific regions. Use `["iad1"]` for US East, `["cdg1"]` for EU.
- `functions`: Per-route memory (128–3008 MB), maxDuration (up to 300s on Pro), runtime.
- `crons`: Scheduled serverless function invocations (Pro/Enterprise).
- `public`: Set `false` to hide source and logs.

### Rewrites, Redirects, Headers
Configure in `vercel.json` or framework config (`next.config.js`):
```jsonc
{
  "redirects": [
    { "source": "/old-page", "destination": "/new-page", "permanent": true }
  ],
  "rewrites": [
    { "source": "/api/proxy/:path*", "destination": "https://backend.example.com/:path*" }
  ],
  "headers": [
    {
      "source": "/api/(.*)",
      "headers": [
        { "key": "Access-Control-Allow-Origin", "value": "*" },
        { "key": "Cache-Control", "value": "s-maxage=86400" }
      ]
    }
  ]
}
```

Order of evaluation: Headers → Redirects → Middleware → Rewrites → Filesystem/Routes.
Limit: 2048 redirects in `vercel.json`. For more, use middleware or a database-backed function.

## Framework-Specific Deployment

### Next.js (App Router)
```jsonc
// vercel.json — usually no config needed; auto-detected
{ "framework": "nextjs" }
```
- ISR, SSR, streaming, image optimization work automatically.
- `next.config.js` rewrites/redirects/headers are preferred over `vercel.json` equivalents.
- App Router `route.ts` files become Serverless Functions automatically.

### SvelteKit
```jsonc
{ "framework": "svelte", "outputDirectory": "build" }
```
Install `@sveltejs/adapter-vercel`. Configure in `svelte.config.js`:
```js
import adapter from '@sveltejs/adapter-vercel';
export default { kit: { adapter: adapter({ runtime: 'nodejs22.x' }) } };
```

### Nuxt 3
```jsonc
{ "framework": "nuxt" }
```
Nitro auto-detects Vercel. Set preset explicitly if needed in `nuxt.config.ts`:
```ts
export default defineNuxtConfig({ nitro: { preset: 'vercel' } });
```

### Astro
```jsonc
{ "framework": "astro", "outputDirectory": "dist" }
```
Install `@astrojs/vercel`. In `astro.config.mjs`:
```js
import vercel from '@astrojs/vercel';
export default defineConfig({ adapter: vercel({ imageService: true }) });
```

### Remix
```jsonc
{ "framework": "remix" }
```
Use `@vercel/remix` adapter. No additional `vercel.json` usually needed.

## Edge Functions vs Serverless Functions

### When to Use Each
| Aspect | Edge Functions | Serverless (Node.js) |
|---|---|---|
| Cold start | <50ms (V8 isolates) | 250ms–1s (containers) |
| APIs | Web Standards only | Full Node.js |
| Code size | 1–4 MB | Up to 50 MB |
| Duration | Initial response <25s | Up to 5–15 min |
| Distribution | Global (all edge PoPs) | Regional |
| DB access | HTTP-based only | Any driver (native) |
| Use cases | Auth, geo, A/B, redirects | APIs, heavy compute, DB |

### Selecting Runtime
In Next.js App Router route handlers or pages:
```ts
// Edge Function
export const runtime = 'edge';

// Serverless (default)
export const runtime = 'nodejs';
```

In `vercel.json` for non-framework functions:
```jsonc
{
  "functions": {
    "api/fast.ts": { "runtime": "edge" },
    "api/heavy.ts": { "runtime": "nodejs22.x", "memory": 1024, "maxDuration": 60 }
  }
}
```

### Middleware (Edge by Default)
Create `middleware.ts` at project root (Next.js):
```ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
  // Geo-based routing
  const country = request.geo?.country || 'US';
  if (country === 'DE') {
    return NextResponse.rewrite(new URL('/de' + request.nextUrl.pathname, request.url));
  }
  // Add security headers
  const response = NextResponse.next();
  response.headers.set('X-Frame-Options', 'DENY');
  return response;
}

export const config = { matcher: ['/((?!_next/static|favicon.ico).*)'] };
```

## Environment Variables & Secrets

### Environments
Vercel supports three environments: **Production**, **Preview**, **Development**.

```bash
# Add a variable (interactive — prompts for value and target environments)
vercel env add DATABASE_URL

# Add non-interactively
echo "postgresql://..." | vercel env add DATABASE_URL production

# List all variables
vercel env ls

# Pull to local .env.local
vercel env pull .env.local

# Remove a variable
vercel env rm DATABASE_URL production
```

### In vercel.json
```jsonc
{
  "env": {
    "NEXT_PUBLIC_API_URL": "https://api.example.com",
    "DATABASE_URL": "@database-url"
  }
}
```
- Prefix `@` references a secret stored via `vercel secrets` (legacy) or environment variables.
- `NEXT_PUBLIC_` prefix exposes to client bundle (Next.js).

### Best Practices
- Never commit `.env.local`. Add to `.gitignore`.
- Use separate values per environment (Production vs Preview).
- Sensitive secrets: set via Dashboard or CLI, never in `vercel.json`.
- In Turborepo: declare in `turbo.json` under `globalEnv` or per-task `env` for correct caching.

## Preview Deployments & Branch Management

### Automatic Previews
- Every push to a non-production branch creates a preview deployment.
- Each PR gets a unique URL: `<project>-<hash>-<scope>.vercel.app`.
- Comment bot posts preview URL on PR automatically.

### Branch-Specific Domains
Assign preview domains in Dashboard → Settings → Domains:
- `staging.example.com` → `staging` branch
- `*.preview.example.com` → wildcard for all preview branches

### CLI Deployment Workflow
```bash
# Preview deployment (default)
vercel deploy

# Production deployment
vercel deploy --prod

# Alias a specific deployment to a custom domain
vercel alias <deployment-url> staging.example.com
```

### Protection
- Enable Vercel Authentication for preview deployments (Dashboard → Settings → Deployment Protection).
- Use `VERCEL_ENV` env var to detect environment: `production`, `preview`, `development`.

## Custom Domains & DNS

### Adding Domains
```bash
vercel domains add example.com
vercel domains add www.example.com
```

### DNS Records
| Type | Name | Value | Use Case |
|---|---|---|---|
| A | `@` | `76.76.21.21` | Apex domain |
| CNAME | `www` | `cname.vercel-dns.com` | Subdomain |
| CNAME | `*` | `cname.vercel-dns.com` | Wildcard previews |

- Apex + www: configure both, Vercel auto-redirects one to the other.
- SSL certificates are provisioned automatically (Let's Encrypt).
- For wildcard subdomains, use Vercel nameservers for full support.

## Vercel Storage

### Upstash Redis (replaces Vercel KV)
```bash
npm install @upstash/redis
```
```ts
import { Redis } from '@upstash/redis';
const redis = Redis.fromEnv(); // reads UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN
await redis.set('user:123', JSON.stringify(data), { ex: 3600 });
const user = await redis.get('user:123');
```
Use for: session state, rate limiting, caching, ephemeral data. Works in Edge and Node.js.

### Vercel Blob
```bash
npm install @vercel/blob
```
```ts
import { put, del, list } from '@vercel/blob';
// Server-side upload
const blob = await put('avatars/user-123.png', file, { access: 'public' });
console.log(blob.url); // https://<store>.public.blob.vercel-storage.com/avatars/user-123.png

// Client-side upload (requires token from API route)
import { upload } from '@vercel/blob/client';
const blob = await upload('photo.jpg', file, {
  access: 'public',
  handleUploadUrl: '/api/upload',
});
```
Use for: images, videos, documents, user-generated content.

### Vercel Postgres
```bash
npm install @vercel/postgres
```
```ts
import { sql } from '@vercel/postgres';
const { rows } = await sql`SELECT * FROM users WHERE id = ${userId}`;
```
Or use with Prisma/Drizzle via `POSTGRES_URL` env var. Use connection pooling for serverless.

### Edge Config
```bash
npm install @vercel/edge-config
```
```ts
import { get } from '@vercel/edge-config';
const isMaintenanceMode = await get('maintenance'); // <1ms read
```
Use for: feature flags, A/B tests, maintenance mode, dynamic redirects. Reads are global, ultra-low latency.

## Monorepo Deployment (Turborepo)

### Structure
```
/
├── apps/
│   ├── web/          ← Vercel project 1 (root: apps/web)
│   └── admin/        ← Vercel project 2 (root: apps/admin)
├── packages/
│   ├── ui/
│   └── utils/
├── turbo.json
└── package.json
```

### Setup
1. Create separate Vercel projects per app.
2. Set **Root Directory** to `apps/web` or `apps/admin` in each project's settings.
3. Vercel installs deps from repo root (detects lockfile), builds from root directory.

### Ignored Build Step
Prevent unnecessary builds when only unrelated packages changed:
```bash
# In Vercel → Settings → General → Ignored Build Step
npx turbo-ignore
```

### turbo.json Environment Variables
```jsonc
{
  "$schema": "https://turbo.build/schema.json",
  "globalEnv": ["VERCEL_ENV", "CI"],
  "tasks": {
    "build": {
      "env": ["DATABASE_URL", "NEXT_PUBLIC_API_URL"],
      "outputs": [".next/**", "dist/**"]
    }
  }
}
```
Declare all env vars used in each task for correct remote caching.

## Performance & Caching

### Build Caching
- Vercel caches `node_modules` and build outputs automatically.
- Turborepo remote caching is built-in when linked to Vercel.
- Force clean build: `vercel deploy --force`.

### Output Caching (CDN)
Set `Cache-Control` headers for static assets:
```jsonc
{
  "headers": [
    {
      "source": "/static/(.*)",
      "headers": [{ "key": "Cache-Control", "value": "public, max-age=31536000, immutable" }]
    }
  ]
}
```

For ISR in Next.js, use `revalidate` in page/route config:
```ts
export const revalidate = 60; // Revalidate every 60 seconds
```

### Image Optimization
Next.js `<Image>` component uses Vercel's built-in optimizer. Configure in `next.config.js`:
```js
module.exports = {
  images: {
    remotePatterns: [{ protocol: 'https', hostname: '**.example.com' }],
    formats: ['image/avif', 'image/webp'],
  },
};
```

### Analytics & Speed Insights
```bash
npm install @vercel/analytics @vercel/speed-insights
```
```tsx
// app/layout.tsx
import { Analytics } from '@vercel/analytics/react';
import { SpeedInsights } from '@vercel/speed-insights/next';

export default function RootLayout({ children }) {
  return (
    <html><body>
      {children}
      <Analytics />
      <SpeedInsights />
    </body></html>
  );
}
```
Analytics: page views, custom events. Speed Insights: Core Web Vitals (LCP, FID, CLS).

## CI/CD Integration

### GitHub Integration (Default)
- Connect repo in Vercel Dashboard. Auto-deploys on push.
- Production branch configurable (default: `main`).
- PR comments with preview URLs are automatic.
- Use **Ignored Build Step** to skip builds for irrelevant changes.

### GitHub Actions / GitLab CI
Use the Vercel CLI in CI for full control. See `assets/github-actions-vercel.yml` for a complete workflow.

Required secrets (`vercel link` → `.vercel/project.json`):
- `VERCEL_TOKEN` — from vercel.com/account/tokens
- `VERCEL_ORG_ID` — `orgId` from project.json
- `VERCEL_PROJECT_ID` — `projectId` from project.json

CI deploy pattern (works in any CI):
```bash
npm i -g vercel
vercel pull --yes --environment=production --token=$VERCEL_TOKEN
vercel build --prod --token=$VERCEL_TOKEN
vercel deploy --prebuilt --prod --token=$VERCEL_TOKEN
```

## Troubleshooting Quick Reference

| Issue | Solution |
|---|---|
| Build fails with OOM | Increase `functions.memory` in vercel.json or reduce bundle |
| Cold starts too slow | Use Edge runtime, reduce function size, enable fluid compute |
| 404 on client routes (SPA) | Add rewrite: `{ "source": "/(.*)", "destination": "/index.html" }` |
| Env var missing at runtime | Check environment target (Production/Preview/Development) |
| CORS errors on preview | Set `Access-Control-Allow-Origin` header or use custom preview domain |
| Monorepo builds everything | Add `npx turbo-ignore` as Ignored Build Step |
| Function timeout | Increase `maxDuration` in vercel.json (up to plan limit) |
| Domain not resolving | Verify DNS records; allow up to 48h for propagation |

See `references/troubleshooting.md` for detailed diagnostics and solutions per framework.

## References

Detailed guides in `references/`:
- **`advanced-patterns.md`** — Edge middleware (auth, geo-routing, A/B testing), ISR/SSR/SSG strategies per framework, cron jobs, image optimization, monorepo build optimization, multi-region deployment, org/team management, Vercel Firewall/DDoS protection.
- **`troubleshooting.md`** — Build failures by framework (Next.js, SvelteKit, Nuxt, Astro, Vite), function timeouts and memory, cold start optimization, env var issues, preview deployments, DNS propagation, CORS, monorepo root directory, stuck deployments.
- **`api-reference.md`** — Vercel REST API (deployments, projects, domains, env vars, teams), CLI commands reference, deploy hooks and webhooks, GitHub/GitLab CI integration, `@vercel/sdk` for programmatic deployments, Edge Config API, storage APIs (KV, Blob, Postgres).

## Scripts

Executable helpers in `scripts/`:
- **`setup-vercel.sh`** — Detects framework, creates `vercel.json` with optimal settings, generates `.env.example` template, configures monorepo if needed. Usage: `./scripts/setup-vercel.sh [--framework nextjs] [--monorepo] [--dry-run]`
- **`vercel-env-sync.sh`** — Pull/push/diff/sync environment variables between local and Vercel. Usage: `./scripts/vercel-env-sync.sh <pull|push|diff|sync|list> [--env production] [--file .env.local]`

## Assets

Templates and config files in `assets/`:
- **`vercel.json`** — Comprehensive annotated template covering all `vercel.json` options (functions, crons, redirects, rewrites, headers, regions, images).
- **`middleware.ts`** — Edge middleware template with toggleable patterns: auth, geo-routing, A/B testing, rate limiting, bot protection, maintenance mode, multi-tenant routing.
- **`github-actions-vercel.yml`** — Full GitHub Actions workflow: lint → build → deploy (preview/production), PR comment with preview URL, smoke test, optional Slack notification.
<!-- tested: needs-fix -->
