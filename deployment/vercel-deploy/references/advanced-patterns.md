# Advanced Vercel Patterns

## Table of Contents
- [Edge Middleware Patterns](#edge-middleware-patterns)
  - [Geo-Routing](#geo-routing)
  - [Authentication & Authorization](#authentication--authorization)
  - [A/B Testing](#ab-testing)
  - [Bot Protection & Rate Limiting](#bot-protection--rate-limiting)
  - [Request Rewriting & Proxying](#request-rewriting--proxying)
- [ISR / SSR / SSG Strategies by Framework](#isr--ssr--ssg-strategies-by-framework)
  - [Next.js App Router](#nextjs-app-router)
  - [Next.js Pages Router](#nextjs-pages-router)
  - [SvelteKit](#sveltekit)
  - [Nuxt 3](#nuxt-3)
  - [Astro](#astro)
  - [Remix](#remix)
- [Cron Jobs with Vercel](#cron-jobs-with-vercel)
- [Image Optimization Configuration](#image-optimization-configuration)
- [Monorepo Build Optimization](#monorepo-build-optimization)
- [Custom Build Commands and Output](#custom-build-commands-and-output)
- [Multi-Region Deployment](#multi-region-deployment)
- [Org / Team Project Management](#org--team-project-management)
- [Vercel Firewall and DDoS Protection](#vercel-firewall-and-ddos-protection)

---

## Edge Middleware Patterns

Edge middleware runs before the request reaches your application. It executes on Vercel's Edge Network (V8 isolates) with <50ms cold starts. Place `middleware.ts` at the project root (Next.js) or use framework-specific equivalents.

### Geo-Routing

Route users based on geographic location. Vercel injects `request.geo` with country, city, region, latitude, longitude.

```ts
// middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

const COUNTRY_LOCALE_MAP: Record<string, string> = {
  DE: 'de', FR: 'fr', ES: 'es', JP: 'ja', BR: 'pt-BR',
};

export function middleware(request: NextRequest) {
  const country = request.geo?.country || 'US';
  const locale = COUNTRY_LOCALE_MAP[country] || 'en';
  const { pathname } = request.nextUrl;

  // Skip if already localized or is an asset
  if (pathname.startsWith(`/${locale}`) || pathname.startsWith('/_next')) {
    return NextResponse.next();
  }

  // Rewrite to localized path (URL stays the same for user)
  const url = request.nextUrl.clone();
  url.pathname = `/${locale}${pathname}`;
  return NextResponse.rewrite(url);
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|api/).*)'],
};
```

**Region-based backend routing** — route API calls to the nearest backend:
```ts
export function middleware(request: NextRequest) {
  const region = request.geo?.region || 'us-east-1';
  const backends: Record<string, string> = {
    'us-east-1': 'https://api-us.example.com',
    'eu-west-1': 'https://api-eu.example.com',
    'ap-southeast-1': 'https://api-ap.example.com',
  };
  const closest = Object.entries(backends).reduce((best, [key, url]) => {
    return key.startsWith(region.slice(0, 2)) ? url : best;
  }, backends['us-east-1']);

  if (request.nextUrl.pathname.startsWith('/api/proxy')) {
    const dest = request.nextUrl.pathname.replace('/api/proxy', '');
    return NextResponse.rewrite(new URL(dest, closest));
  }
  return NextResponse.next();
}
```

### Authentication & Authorization

Validate JWTs, session tokens, or API keys at the edge before reaching your application.

```ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { jwtVerify } from 'jose'; // Works in Edge runtime

const JWT_SECRET = new TextEncoder().encode(process.env.JWT_SECRET!);

const PUBLIC_PATHS = ['/login', '/signup', '/api/auth', '/_next', '/favicon.ico'];

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Skip public paths
  if (PUBLIC_PATHS.some(p => pathname.startsWith(p))) {
    return NextResponse.next();
  }

  const token = request.cookies.get('auth-token')?.value;
  if (!token) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  try {
    const { payload } = await jwtVerify(token, JWT_SECRET);

    // Role-based access control
    if (pathname.startsWith('/admin') && payload.role !== 'admin') {
      return NextResponse.redirect(new URL('/unauthorized', request.url));
    }

    // Forward user info to the application via headers
    const response = NextResponse.next();
    response.headers.set('x-user-id', payload.sub as string);
    response.headers.set('x-user-role', payload.role as string);
    return response;
  } catch {
    // Token expired or invalid
    const response = NextResponse.redirect(new URL('/login', request.url));
    response.cookies.delete('auth-token');
    return response;
  }
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
```

**API key validation for API routes:**
```ts
if (pathname.startsWith('/api/') && !pathname.startsWith('/api/public')) {
  const apiKey = request.headers.get('x-api-key');
  if (!apiKey || !validApiKeys.has(apiKey)) {
    return NextResponse.json({ error: 'Invalid API key' }, { status: 401 });
  }
}
```

### A/B Testing

Use Edge Config or cookies for consistent experiment assignment without client-side flicker.

```ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { get } from '@vercel/edge-config';

interface Experiment {
  name: string;
  variants: { slug: string; weight: number }[];
}

export async function middleware(request: NextRequest) {
  // Read experiment config from Edge Config (<1ms)
  const experiments = await get<Experiment[]>('active-experiments');
  if (!experiments?.length) return NextResponse.next();

  const response = NextResponse.next();

  for (const exp of experiments) {
    const cookieName = `exp-${exp.name}`;
    let variant = request.cookies.get(cookieName)?.value;

    if (!variant) {
      // Assign variant based on weights
      const rand = Math.random();
      let cumulative = 0;
      for (const v of exp.variants) {
        cumulative += v.weight;
        if (rand < cumulative) {
          variant = v.slug;
          break;
        }
      }
      variant = variant || exp.variants[0].slug;
      // Persist assignment in cookie (30 days)
      response.cookies.set(cookieName, variant, {
        maxAge: 60 * 60 * 24 * 30,
        httpOnly: true,
        sameSite: 'lax',
      });
    }

    // Pass variant to app via header (read in Server Components)
    response.headers.set(`x-experiment-${exp.name}`, variant);
  }

  return response;
}
```

**Page-level A/B testing with rewrites:**
```ts
// Serve different pages based on variant
if (pathname === '/pricing') {
  const variant = request.cookies.get('exp-pricing')?.value || 'control';
  return NextResponse.rewrite(new URL(`/pricing/${variant}`, request.url));
}
```

### Bot Protection & Rate Limiting

```ts
import { ipAddress } from '@vercel/functions';

const RATE_LIMIT_WINDOW = 60_000; // 1 minute
const MAX_REQUESTS = 100;
const ipRequestCounts = new Map<string, { count: number; resetAt: number }>();

export function middleware(request: NextRequest) {
  const ip = ipAddress(request) || 'unknown';

  // Simple bot detection
  const ua = request.headers.get('user-agent') || '';
  if (!ua || /bot|crawler|spider|curl|wget/i.test(ua)) {
    if (request.nextUrl.pathname.startsWith('/api/')) {
      return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
    }
  }

  // In-memory rate limiting (resets per isolate — use Upstash Redis for production)
  const now = Date.now();
  const record = ipRequestCounts.get(ip);
  if (record && record.resetAt > now) {
    if (record.count >= MAX_REQUESTS) {
      return NextResponse.json(
        { error: 'Rate limit exceeded' },
        { status: 429, headers: { 'Retry-After': '60' } }
      );
    }
    record.count++;
  } else {
    ipRequestCounts.set(ip, { count: 1, resetAt: now + RATE_LIMIT_WINDOW });
  }
  return NextResponse.next();
}
```

**Production rate limiting with Upstash Redis:**
```ts
import { Ratelimit } from '@upstash/ratelimit';
import { Redis } from '@upstash/redis';

const ratelimit = new Ratelimit({
  redis: Redis.fromEnv(),
  limiter: Ratelimit.slidingWindow(100, '1 m'),
  analytics: true,
});

export async function middleware(request: NextRequest) {
  const ip = ipAddress(request) || '127.0.0.1';
  const { success, limit, remaining, reset } = await ratelimit.limit(ip);
  if (!success) {
    return NextResponse.json({ error: 'Rate limited' }, {
      status: 429,
      headers: {
        'X-RateLimit-Limit': limit.toString(),
        'X-RateLimit-Remaining': remaining.toString(),
        'X-RateLimit-Reset': reset.toString(),
      },
    });
  }
  return NextResponse.next();
}
```

### Request Rewriting & Proxying

```ts
// Multi-tenant routing: subdomain → path rewrite
export function middleware(request: NextRequest) {
  const hostname = request.headers.get('host') || '';
  const subdomain = hostname.split('.')[0];

  // Skip main domain and special subdomains
  if (['www', 'app', 'api'].includes(subdomain)) return NextResponse.next();

  // Rewrite tenant.example.com/page → /tenants/[tenant]/page
  const url = request.nextUrl.clone();
  url.pathname = `/tenants/${subdomain}${url.pathname}`;
  return NextResponse.rewrite(url);
}
```

---

## ISR / SSR / SSG Strategies by Framework

### Decision Matrix

| Strategy | Build Time | Request Time | Freshness | Cost | Use Case |
|----------|-----------|-------------|-----------|------|----------|
| SSG | Generates HTML | Serves from CDN | Stale until rebuild | Lowest | Marketing, docs, blogs |
| ISR | Initial build | CDN + background regen | Configurable (seconds) | Low | Product pages, feeds |
| SSR | None | Generates on request | Always fresh | Highest | Dashboards, user-specific |
| Edge SSR | None | Generates at edge | Always fresh | Medium | Personalized, low-latency |

### Next.js App Router

```ts
// SSG — static at build time (default for pages without dynamic data)
export default function Page() { return <div>Static</div>; }

// ISR — revalidate every 60 seconds
export const revalidate = 60;
export default async function Page() {
  const data = await fetch('https://api.example.com/products');
  return <ProductList data={data} />;
}

// On-demand ISR — revalidate via API call
// app/api/revalidate/route.ts
import { revalidatePath, revalidateTag } from 'next/cache';
export async function POST(request: Request) {
  const { path, tag, secret } = await request.json();
  if (secret !== process.env.REVALIDATION_SECRET) {
    return Response.json({ error: 'Invalid secret' }, { status: 401 });
  }
  if (tag) revalidateTag(tag);
  if (path) revalidatePath(path);
  return Response.json({ revalidated: true });
}

// SSR — opt out of caching
export const dynamic = 'force-dynamic';
export default async function Dashboard() {
  const data = await fetch('https://api.example.com/user', { cache: 'no-store' });
  return <DashboardView data={data} />;
}
```

### Next.js Pages Router

```ts
// SSG
export async function getStaticProps() {
  return { props: { data }, revalidate: false };
}

// ISR
export async function getStaticProps() {
  return { props: { data }, revalidate: 60 };
}

// SSR
export async function getServerSideProps(context) {
  return { props: { data } };
}
```

### SvelteKit

```ts
// +page.ts or +page.server.ts
// SSG — prerender at build time
export const prerender = true;

// SSR (default) — renders on each request
export async function load({ fetch }) {
  const res = await fetch('/api/data');
  return { data: await res.json() };
}

// ISR-like with Vercel adapter
// svelte.config.js
import adapter from '@sveltejs/adapter-vercel';
export default {
  kit: {
    adapter: adapter({
      isr: { expiration: 60 }, // global ISR
      // or per-route in +page.server.ts:
      // export const config = { isr: { expiration: 60 } };
    }),
  },
};
```

### Nuxt 3

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  routeRules: {
    '/':            { prerender: true },              // SSG
    '/blog/**':     { isr: 3600 },                    // ISR: 1 hour
    '/dashboard':   { ssr: true },                    // SSR (default)
    '/admin/**':    { ssr: false },                   // SPA / CSR
    '/api/**':      { cors: true, cache: { maxAge: 60 } },
  },
});
```

### Astro

```ts
// astro.config.mjs
import vercel from '@astrojs/vercel';
export default defineConfig({
  output: 'hybrid',  // Default static, opt-in SSR per page
  adapter: vercel({
    imageService: true,
    isr: { expiration: 60 }, // ISR for SSR pages
  }),
});

// src/pages/dynamic.astro — opt into SSR
export const prerender = false;
```

### Remix

Remix is SSR-first on Vercel. Use `headers` export for caching:
```ts
// app/routes/products.$id.tsx
export function headers() {
  return {
    'Cache-Control': 's-maxage=60, stale-while-revalidate=600',
  };
}
export async function loader({ params }: LoaderFunctionArgs) {
  return json(await getProduct(params.id));
}
```

---

## Cron Jobs with Vercel

Cron jobs invoke serverless functions on a schedule. Available on **Pro and Enterprise** plans.

```jsonc
// vercel.json
{
  "crons": [
    { "path": "/api/cron/daily-digest", "schedule": "0 9 * * *" },
    { "path": "/api/cron/cleanup", "schedule": "0 */6 * * *" },
    { "path": "/api/cron/weekly-report", "schedule": "0 10 * * 1" }
  ]
}
```

**Secure your cron endpoint** — Vercel sends an `Authorization: Bearer <CRON_SECRET>` header:
```ts
// app/api/cron/daily-digest/route.ts
export async function GET(request: Request) {
  const authHeader = request.headers.get('authorization');
  if (authHeader !== `Bearer ${process.env.CRON_SECRET}`) {
    return Response.json({ error: 'Unauthorized' }, { status: 401 });
  }

  // Your cron logic here
  await sendDailyDigestEmails();
  return Response.json({ success: true });
}
```

**Cron schedule syntax:** `minute hour day-of-month month day-of-week`
- `0 * * * *` — every hour
- `*/15 * * * *` — every 15 minutes
- `0 0 * * 0` — every Sunday at midnight
- `0 9 1 * *` — 1st of each month at 9 AM

Limits: Pro = 2 crons max (40/day each), Enterprise = 40 crons.

---

## Image Optimization Configuration

```js
// next.config.js — comprehensive image configuration
module.exports = {
  images: {
    // Remote image sources
    remotePatterns: [
      { protocol: 'https', hostname: '**.example.com' },
      { protocol: 'https', hostname: 'cdn.shopify.com', pathname: '/s/files/**' },
      { protocol: 'https', hostname: 'images.unsplash.com' },
    ],
    // Supported output formats (avif is smaller but slower to encode)
    formats: ['image/avif', 'image/webp'],
    // Custom device breakpoints
    deviceSizes: [640, 750, 828, 1080, 1200, 1920, 2048, 3840],
    // Custom image widths for `sizes` prop
    imageSizes: [16, 32, 48, 64, 96, 128, 256, 384],
    // Minimum cache TTL in seconds (default 60)
    minimumCacheTTL: 2592000, // 30 days
    // Content-Disposition header
    contentDispositionType: 'inline',
    // Dangerously allow SVG (potential XSS — ensure trusted sources)
    dangerouslyAllowSVG: false,
    // Quality (1-100, default 75)
    quality: 80,
  },
};
```

**Vercel image optimization limits by plan:**
- Hobby: 1,000 source images/month
- Pro: 5,000 source images/month
- Enterprise: Custom

For non-Next.js frameworks, use the `/_vercel/image` endpoint:
```html
<img src="/_vercel/image?url=https://example.com/photo.jpg&w=640&q=75" />
```

Configure in `vercel.json`:
```jsonc
{
  "images": {
    "sizes": [640, 750, 828, 1080, 1200],
    "domains": ["example.com", "cdn.example.com"],
    "minimumCacheTTL": 86400
  }
}
```

---

## Monorepo Build Optimization

### Remote Caching with Turborepo

```bash
# Enable remote caching (automatic when linked to Vercel)
npx turbo login
npx turbo link
```

```jsonc
// turbo.json — optimized caching config
{
  "$schema": "https://turbo.build/schema.json",
  "globalDependencies": ["tsconfig.json", ".env.production"],
  "globalEnv": ["VERCEL_ENV", "CI", "NODE_ENV"],
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": [".next/**", "!.next/cache/**", "dist/**", "build/**"],
      "env": ["DATABASE_URL", "NEXT_PUBLIC_*"]
    },
    "test": {
      "dependsOn": ["^build"],
      "outputs": ["coverage/**"],
      "env": ["DATABASE_URL"]
    },
    "lint": {
      "dependsOn": ["^build"],
      "outputs": []
    }
  }
}
```

### Ignored Build Step Strategies

```bash
#!/bin/bash
# .vercel/ignore-build.sh — custom ignore logic
# Return exit code 0 to skip, 1 to build

# Method 1: Use turbo-ignore (recommended)
npx turbo-ignore

# Method 2: Check if specific paths changed
git diff --quiet HEAD^ HEAD -- apps/web/ packages/shared/
# Exit 0 = no changes = skip build

# Method 3: Skip deploys on docs-only changes
CHANGES=$(git diff --name-only HEAD^ HEAD)
if echo "$CHANGES" | grep -qvE '\.md$|\.txt$|docs/'; then
  exit 1  # Non-doc changes: build
fi
exit 0    # Only docs changed: skip
```

### Workspace Package Resolution

```jsonc
// apps/web/package.json — reference workspace packages
{
  "dependencies": {
    "@acme/ui": "workspace:*",
    "@acme/utils": "workspace:*",
    "@acme/db": "workspace:*"
  }
}
```

Vercel resolves `workspace:*` via your package manager. Ensure the lockfile is committed.

---

## Custom Build Commands and Output

### Custom Build Pipeline

```jsonc
// vercel.json
{
  "buildCommand": "pnpm run generate && pnpm run build",
  "installCommand": "pnpm install --frozen-lockfile",
  "outputDirectory": "dist",
  "framework": null,  // Disable framework detection for custom builds
  "build": {
    "env": {
      "GENERATE_SOURCEMAP": "false",
      "NODE_OPTIONS": "--max-old-space-size=4096"
    }
  }
}
```

### Static File Output (no framework)

```jsonc
// For plain HTML/CSS/JS sites
{
  "buildCommand": "npm run build",
  "outputDirectory": "public",
  "cleanUrls": true,        // Remove .html extensions
  "trailingSlash": false     // Remove trailing slashes
}
```

### Vercel Build Output API (advanced)

For custom frameworks, output to `.vercel/output/`:
```
.vercel/output/
├── config.json          # Route configuration
├── static/              # Static assets → CDN
│   ├── index.html
│   └── assets/
└── functions/           # Serverless functions
    └── api/
        └── hello.func/
            ├── .vc-config.json
            └── index.js
```

```jsonc
// .vercel/output/config.json
{
  "version": 3,
  "routes": [
    { "src": "/api/(.*)", "dest": "/api/$1" },
    { "handle": "filesystem" },
    { "src": "/(.*)", "dest": "/index.html" }
  ]
}
```

---

## Multi-Region Deployment

### Function Regions

```jsonc
// vercel.json — deploy functions to specific regions
{
  "regions": ["iad1", "cdg1", "hnd1"],  // US East, EU, Japan
  "functions": {
    "api/user/**": { "regions": ["iad1"] },      // User data near primary DB
    "api/cdn/**":  { "regions": ["iad1", "cdg1", "hnd1"] }  // Global
  }
}
```

**Available regions:**
| Code | Location |
|------|----------|
| `arn1` | Stockholm |
| `bom1` | Mumbai |
| `cdg1` | Paris |
| `cle1` | Cleveland |
| `cpt1` | Cape Town |
| `dub1` | Dublin |
| `fra1` | Frankfurt |
| `gru1` | São Paulo |
| `hkg1` | Hong Kong |
| `hnd1` | Tokyo |
| `iad1` | Washington, D.C. |
| `icn1` | Seoul |
| `kix1` | Osaka |
| `lhr1` | London |
| `pdx1` | Portland |
| `sfo1` | San Francisco |
| `sin1` | Singapore |
| `syd1` | Sydney |

### Edge Functions — Automatic Global Distribution

Edge functions run on all PoPs by default. No region configuration needed.

### Database Proximity

Place your serverless functions in the same region as your database:
```jsonc
{
  "regions": ["iad1"],  // Match your Vercel Postgres / PlanetScale / Neon region
  "functions": {
    "api/**": { "regions": ["iad1"] }
  }
}
```

---

## Org / Team Project Management

### Team Structure

```bash
# Switch between personal and team scope
vercel switch                         # Interactive team selection
vercel --scope my-team deploy         # Deploy under team scope
vercel link --scope my-team           # Link project to team

# List team members
vercel teams ls

# Invite member
vercel teams invite user@example.com
```

### Project Transfer

```bash
# Transfer project between scopes
vercel project move <project-name> --scope <target-team>
```

### Environment Variable Scoping

Team-level secrets are shared across projects via integrations. Per-project env vars are set in project settings.

```bash
# Set env var for a specific project in a team
vercel env add API_KEY production --scope my-team
```

### Access Control (Enterprise)

- **Roles:** Owner, Member, Viewer, Billing
- **Deployment Protection:** Restrict preview access to team members
- **Audit Logs:** Track team activity via Dashboard → Settings → Audit Log
- **SAML SSO:** Configure in Dashboard → Settings → Security
- **IP Allow Lists:** Restrict access from specific IP ranges

---

## Vercel Firewall and DDoS Protection

### Built-in Protection

All Vercel deployments include:
- **DDoS mitigation** — Automatic L3/L4 protection across the Edge Network
- **Managed challenge pages** — Automatic bot detection
- **SSL/TLS** — Automatic certificate provisioning and renewal

### Vercel Firewall (WAF) — Enterprise

```jsonc
// vercel.json — IP blocking
{
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "X-Content-Type-Options", "value": "nosniff" },
        { "key": "X-Frame-Options", "value": "DENY" },
        { "key": "X-XSS-Protection", "value": "1; mode=block" },
        { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" },
        { "key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=()" },
        {
          "key": "Content-Security-Policy",
          "value": "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' https:;"
        },
        {
          "key": "Strict-Transport-Security",
          "value": "max-age=63072000; includeSubDomains; preload"
        }
      ]
    }
  ]
}
```

### Security Headers in Middleware

```ts
export function middleware(request: NextRequest) {
  const nonce = crypto.randomUUID();
  const csp = `
    default-src 'self';
    script-src 'self' 'nonce-${nonce}';
    style-src 'self' 'unsafe-inline';
    img-src 'self' data: https:;
    connect-src 'self' https://api.example.com;
    frame-ancestors 'none';
  `.replace(/\n/g, ' ').trim();

  const response = NextResponse.next();
  response.headers.set('Content-Security-Policy', csp);
  response.headers.set('x-nonce', nonce);
  return response;
}
```

### Attack Surface Reduction

- **Hide source maps:** Set `productionBrowserSourceMaps: false` in `next.config.js`
- **Disable directory listing:** Automatic on Vercel
- **Function source protection:** Set `"public": false` in `vercel.json`
- **Deployment Protection:** Enable in Dashboard → Settings → Deployment Protection
- **Trusted IPs:** Enterprise feature to restrict access to specific CIDR ranges
