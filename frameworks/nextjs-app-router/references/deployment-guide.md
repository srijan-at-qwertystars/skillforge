# Next.js Deployment Guide

## Table of Contents

- [Vercel Deployment](#vercel-deployment)
- [Docker Deployment](#docker-deployment)
- [Node.js Server Deployment](#nodejs-server-deployment)
- [Static Export](#static-export)
- [CDN Strategies](#cdn-strategies)
- [Environment Variables](#environment-variables)
- [Health Checks and Graceful Shutdown](#health-checks-and-graceful-shutdown)
- [Logging and Monitoring](#logging-and-monitoring)
- [Performance Budgets](#performance-budgets)
- [Edge Runtime vs Node.js Runtime](#edge-runtime-vs-nodejs-runtime)
- [ISR on Self-Hosted](#isr-on-self-hosted)
- [Cache Handler Customization](#cache-handler-customization)

---

## Vercel Deployment

### Zero-Config Setup

Push to Git. Vercel auto-detects Next.js and configures build, output, and routing.

```bash
# Install Vercel CLI
npm i -g vercel

# Deploy
vercel

# Production deploy
vercel --prod
```

### Vercel-Specific Features

```ts
// next.config.ts — Vercel-optimized settings
const nextConfig = {
  // Image optimization handled by Vercel's Edge Network
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "cdn.example.com" },
    ],
  },
};
export default nextConfig;
```

### Edge Functions on Vercel

```tsx
// app/api/geo/route.ts
export const runtime = "edge"; // Deploy to Vercel Edge Network

export async function GET(request: Request) {
  return Response.json({
    message: "This runs at the edge, close to the user",
  });
}
```

### Vercel Analytics

```bash
npm install @vercel/analytics @vercel/speed-insights
```

```tsx
// app/layout.tsx
import { Analytics } from "@vercel/analytics/react";
import { SpeedInsights } from "@vercel/speed-insights/next";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        {children}
        <Analytics />
        <SpeedInsights />
      </body>
    </html>
  );
}
```

### Vercel Cron Jobs

```json
// vercel.json
{
  "crons": [
    {
      "path": "/api/cron/daily-digest",
      "schedule": "0 8 * * *"
    },
    {
      "path": "/api/cron/cleanup",
      "schedule": "0 0 * * 0"
    }
  ]
}
```

```tsx
// app/api/cron/daily-digest/route.ts
import { NextRequest } from "next/server";

export async function GET(request: NextRequest) {
  // Verify cron secret (Vercel sets this automatically)
  const authHeader = request.headers.get("authorization");
  if (authHeader !== `Bearer ${process.env.CRON_SECRET}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  await sendDailyDigestEmails();
  return Response.json({ success: true });
}
```

---

## Docker Deployment

### Production Dockerfile (Multi-Stage)

```dockerfile
# syntax=docker/dockerfile:1

# --- Dependencies ---
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --ignore-scripts

# --- Builder ---
FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Set build-time env vars
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL

# Disable telemetry during build
ENV NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# --- Runner ---
FROM node:20-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Create non-root user
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Copy standalone output
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1

CMD ["node", "server.js"]
```

**Required next.config.ts:**

```ts
const nextConfig = {
  output: "standalone",
};
export default nextConfig;
```

### Docker Compose for Development

```yaml
# docker-compose.yml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "3000:3000"
    environment:
      - DATABASE_URL=postgresql://postgres:postgres@db:5432/mydb
      - REDIS_URL=redis://redis:6379
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: mydb
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
```

### Docker Build Optimization

```dockerfile
# Use .dockerignore to speed up builds
# .dockerignore
node_modules
.next
.git
*.md
.env*.local
```

---

## Node.js Server Deployment

### Standalone Server (Without Docker)

```bash
# Build
npm run build

# next.config.ts must have: output: "standalone"
# Copy required files:
cp -r .next/standalone ./deploy
cp -r .next/static ./deploy/.next/static
cp -r public ./deploy/public

# Run
cd deploy
PORT=3000 HOSTNAME=0.0.0.0 node server.js
```

### PM2 Process Manager

```js
// ecosystem.config.js
module.exports = {
  apps: [
    {
      name: "nextjs-app",
      script: "server.js",
      cwd: "/app/deploy",
      instances: "max",          // use all CPU cores
      exec_mode: "cluster",
      env: {
        NODE_ENV: "production",
        PORT: 3000,
        HOSTNAME: "0.0.0.0",
      },
      max_memory_restart: "1G",
      // Graceful shutdown
      kill_timeout: 5000,
      listen_timeout: 10000,
      // Logging
      error_file: "/var/log/nextjs/error.log",
      out_file: "/var/log/nextjs/out.log",
      merge_logs: true,
    },
  ],
};
```

```bash
pm2 start ecosystem.config.js
pm2 save
pm2 startup  # auto-start on reboot
```

### Nginx Reverse Proxy

```nginx
# /etc/nginx/sites-available/nextjs
upstream nextjs {
    server 127.0.0.1:3000;
    keepalive 64;
}

server {
    listen 80;
    server_name example.com;

    # Redirect to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # Static assets — serve directly from nginx
    location /_next/static {
        alias /app/deploy/.next/static;
        expires 365d;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    location /public {
        alias /app/deploy/public;
        expires 30d;
        access_log off;
    }

    # Proxy everything else to Next.js
    location / {
        proxy_pass http://nextjs;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;

        # SSE/Streaming support
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
```

---

## Static Export

```ts
// next.config.ts
const nextConfig = {
  output: "export",
  // Required for static export if using next/image
  images: { unoptimized: true },
  // Optional: trailing slashes for static hosting
  trailingSlash: true,
};
export default nextConfig;
```

### Static Export Limitations

| Feature | Supported | Notes |
|---------|-----------|-------|
| Server Components | ✅ | Rendered at build time |
| Client Components | ✅ | Hydrated on client |
| Static Routes | ✅ | Generated as HTML files |
| Dynamic Routes + `generateStaticParams` | ✅ | Pre-rendered at build |
| API Route Handlers | ❌ | No server at runtime |
| Server Actions | ❌ | No server at runtime |
| Middleware | ❌ | No edge runtime |
| ISR / Revalidation | ❌ | No server to revalidate |
| Image Optimization | ❌ | Use `unoptimized: true` |
| `cookies()` / `headers()` | ❌ | No request context |
| Rewrites / Redirects | ❌ | Configure in hosting platform |

### Static Export Hosting

```bash
# Build
npm run build
# Output in /out directory

# Deploy to any static host
# Netlify, S3+CloudFront, GitHub Pages, Cloudflare Pages
```

---

## CDN Strategies

### Cache Headers

```ts
// next.config.ts
const nextConfig = {
  async headers() {
    return [
      {
        source: "/:all*(svg|jpg|png|webp|avif|ico)",
        headers: [
          { key: "Cache-Control", value: "public, max-age=31536000, immutable" },
        ],
      },
      {
        source: "/_next/static/:path*",
        headers: [
          { key: "Cache-Control", value: "public, max-age=31536000, immutable" },
        ],
      },
      {
        source: "/api/:path*",
        headers: [
          { key: "Cache-Control", value: "no-store, must-revalidate" },
        ],
      },
    ];
  },
};
```

### CDN + ISR Strategy

```
Client → CDN (edge cache) → Origin (Next.js server)
              ↓
    stale-while-revalidate
    CDN serves cached while
    origin refreshes in background
```

```ts
// Route-level ISR with CDN
export const revalidate = 60; // 60 second stale-while-revalidate

// API route with cache headers for CDN
export async function GET() {
  const data = await fetchData();
  return Response.json(data, {
    headers: {
      "Cache-Control": "public, s-maxage=60, stale-while-revalidate=300",
    },
  });
}
```

---

## Environment Variables

### Types of Environment Variables

| Prefix | Available In | Loaded At | Embedded In |
|--------|-------------|-----------|-------------|
| `NEXT_PUBLIC_` | Client + Server | Build time | JS bundle |
| (none) | Server only | Runtime | process.env |

### .env File Loading Order

```bash
# Loaded from lowest to highest priority:
.env                  # All environments
.env.local            # All environments (gitignored)
.env.development      # dev only
.env.development.local # dev only (gitignored)
.env.production       # prod only
.env.production.local # prod only (gitignored)
```

### Runtime Environment Variables Pattern

```tsx
// For values that must change at runtime (not build time):
// app/api/config/route.ts
export async function GET() {
  return Response.json({
    apiUrl: process.env.API_URL,       // Server-only, runtime
    featureFlags: process.env.FEATURES,
  });
}

// Use in client component:
"use client";
import { useEffect, useState } from "react";

export function useConfig() {
  const [config, setConfig] = useState(null);
  useEffect(() => {
    fetch("/api/config").then(r => r.json()).then(setConfig);
  }, []);
  return config;
}
```

### Environment Variable Validation

```ts
// lib/env.ts
import { z } from "zod";

const envSchema = z.object({
  DATABASE_URL: z.string().url(),
  NEXTAUTH_SECRET: z.string().min(32),
  NEXTAUTH_URL: z.string().url(),
  REDIS_URL: z.string().url().optional(),
  NEXT_PUBLIC_API_URL: z.string().url(),
});

// Validate at startup
export const env = envSchema.parse(process.env);
```

---

## Health Checks and Graceful Shutdown

### Health Check Endpoint

```tsx
// app/api/health/route.ts
import { db } from "@/lib/db";

export const dynamic = "force-dynamic";

export async function GET() {
  const checks: Record<string, string> = {};

  // Database check
  try {
    await db.$queryRaw`SELECT 1`;
    checks.database = "ok";
  } catch {
    checks.database = "error";
  }

  // Redis check (if applicable)
  try {
    await redis.ping();
    checks.redis = "ok";
  } catch {
    checks.redis = "error";
  }

  const healthy = Object.values(checks).every((v) => v === "ok");

  return Response.json(
    {
      status: healthy ? "healthy" : "unhealthy",
      timestamp: new Date().toISOString(),
      checks,
      version: process.env.APP_VERSION || "unknown",
    },
    { status: healthy ? 200 : 503 }
  );
}
```

### Liveness vs Readiness

```tsx
// app/api/health/live/route.ts — Is process running?
export async function GET() {
  return Response.json({ status: "alive" });
}

// app/api/health/ready/route.ts — Can it handle traffic?
export async function GET() {
  try {
    await db.$queryRaw`SELECT 1`;
    return Response.json({ status: "ready" });
  } catch {
    return Response.json({ status: "not ready" }, { status: 503 });
  }
}
```

### Kubernetes Probes

```yaml
# k8s deployment
spec:
  containers:
    - name: nextjs
      livenessProbe:
        httpGet:
          path: /api/health/live
          port: 3000
        initialDelaySeconds: 10
        periodSeconds: 30
      readinessProbe:
        httpGet:
          path: /api/health/ready
          port: 3000
        initialDelaySeconds: 5
        periodSeconds: 10
```

### Graceful Shutdown

```ts
// Custom server with graceful shutdown (if using custom server)
// server.ts
import next from "next";
import { createServer } from "http";

const app = next({ dev: false });
const handle = app.getRequestHandler();

app.prepare().then(() => {
  const server = createServer(handle);

  server.listen(3000, () => {
    console.log("Ready on port 3000");
  });

  // Graceful shutdown
  const shutdown = async (signal: string) => {
    console.log(`${signal} received. Starting graceful shutdown...`);

    // Stop accepting new connections
    server.close(() => {
      console.log("HTTP server closed");
    });

    // Close database connections
    await db.$disconnect();

    // Allow in-flight requests to complete (30s timeout)
    setTimeout(() => {
      console.log("Forcing shutdown after timeout");
      process.exit(1);
    }, 30000);
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
});
```

---

## Logging and Monitoring

### Structured Logging

```ts
// lib/logger.ts
type LogLevel = "debug" | "info" | "warn" | "error";

function log(level: LogLevel, message: string, meta?: Record<string, unknown>) {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    message,
    ...meta,
    env: process.env.NODE_ENV,
    service: "nextjs-app",
  };
  console[level](JSON.stringify(entry));
}

export const logger = {
  debug: (msg: string, meta?: Record<string, unknown>) => log("debug", msg, meta),
  info: (msg: string, meta?: Record<string, unknown>) => log("info", msg, meta),
  warn: (msg: string, meta?: Record<string, unknown>) => log("warn", msg, meta),
  error: (msg: string, meta?: Record<string, unknown>) => log("error", msg, meta),
};
```

### Instrumentation Hook

```ts
// instrumentation.ts (project root)
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    // Initialize server-side monitoring
    // e.g., OpenTelemetry, Sentry, Datadog
    const { init } = await import("./lib/monitoring");
    init();
  }
}
```

```ts
// next.config.ts
const nextConfig = {
  experimental: {
    instrumentationHook: true,
  },
};
```

### Error Tracking Integration

```ts
// lib/monitoring.ts
import * as Sentry from "@sentry/nextjs";

export function init() {
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.NODE_ENV,
    tracesSampleRate: process.env.NODE_ENV === "production" ? 0.1 : 1.0,
  });
}

// Usage in error.tsx
"use client";
import * as Sentry from "@sentry/nextjs";
import { useEffect } from "react";

export default function ErrorBoundary({ error }: { error: Error }) {
  useEffect(() => {
    Sentry.captureException(error);
  }, [error]);

  return <div>Something went wrong</div>;
}
```

---

## Performance Budgets

### Bundle Size Budgets

```ts
// next.config.ts
const nextConfig = {
  experimental: {
    // Warn when page JS exceeds threshold
    largePageDataWarning: true,
  },
};
```

### Custom Performance Monitoring

```tsx
// components/web-vitals.tsx
"use client";
import { useReportWebVitals } from "next/web-vitals";

export function WebVitals() {
  useReportWebVitals((metric) => {
    // Send to analytics
    const body = {
      name: metric.name,      // CLS, FCP, FID, INP, LCP, TTFB
      value: metric.value,
      rating: metric.rating,  // good, needs-improvement, poor
      id: metric.id,
    };

    // Beacon API for reliable delivery
    if (navigator.sendBeacon) {
      navigator.sendBeacon("/api/vitals", JSON.stringify(body));
    }
  });

  return null;
}
```

### Performance Checklist

```
Build & Bundle:
□ Bundle analyzer shows no unexpected large dependencies
□ No server-only packages in client bundle (use "server-only")
□ Dynamic imports for heavy components (charts, editors, maps)
□ Tree-shaking working (import specific functions, not entire libs)

Images:
□ next/image used for all images
□ priority set on LCP image
□ Correct sizes prop for responsive images
□ WebP/AVIF format serving configured
□ Remote patterns configured (no wildcard domains)

Caching:
□ Static pages identified and cached appropriately
□ ISR configured for semi-static content
□ API routes have correct Cache-Control headers
□ unstable_cache used for expensive non-fetch operations

Core Web Vitals Targets:
□ LCP < 2.5s
□ FID/INP < 200ms
□ CLS < 0.1
□ TTFB < 800ms
```

---

## Edge Runtime vs Node.js Runtime

| Aspect | Edge Runtime | Node.js Runtime |
|--------|-------------|-----------------|
| Cold start | ~0ms (V8 isolates) | 250ms+ (full Node.js) |
| Max execution | 30s (Vercel) | No limit |
| Max bundle | 4MB (Vercel) | No limit |
| APIs | Web APIs only | Full Node.js |
| `fs`, `net`, `child_process` | ❌ | ✅ |
| Streaming | ✅ | ✅ |
| Database drivers | Limited (HTTP-based) | All |
| Use for | Auth, redirects, geo | Heavy compute, DB |

### Choosing Runtime

```tsx
// Edge: fast, lightweight, limited APIs
// app/api/geo/route.ts
export const runtime = "edge";

// Node.js: full power, slightly slower cold start
// app/api/report/route.ts
export const runtime = "nodejs"; // default
```

### Edge-Compatible Database Access

```tsx
// ❌ Traditional driver (Node.js only)
import { Pool } from "pg"; // Won't work on Edge

// ✅ HTTP-based driver (Edge compatible)
import { neon } from "@neondatabase/serverless";
const sql = neon(process.env.DATABASE_URL!);

export const runtime = "edge";
export async function GET() {
  const rows = await sql`SELECT * FROM users LIMIT 10`;
  return Response.json(rows);
}
```

---

## ISR on Self-Hosted

ISR requires a cache that persists across requests. Default filesystem cache works for single-server.

### Single Server (Default)

Works out of the box. `.next/cache` stores revalidated pages.

```ts
// next.config.ts — no special config needed
const nextConfig = {};
```

### Multi-Server / Serverless

Need a shared cache backend (Redis, S3, DynamoDB).

```ts
// next.config.ts
const nextConfig = {
  cacheHandler: require.resolve("./cache-handler.mjs"),
  cacheMaxMemorySize: 0, // disable default in-memory cache
};
```

---

## Cache Handler Customization

### Redis Cache Handler

```js
// cache-handler.mjs
import { createClient } from "redis";

const client = createClient({ url: process.env.REDIS_URL });
const connecting = client.connect();

export default class CacheHandler {
  constructor(options) {
    this.options = options;
  }

  async get(key) {
    await connecting;
    const data = await client.get(`next:${key}`);
    if (!data) return null;

    const parsed = JSON.parse(data);
    return {
      value: parsed.value,
      lastModified: parsed.lastModified,
      tags: parsed.tags || [],
    };
  }

  async set(key, data, ctx) {
    await connecting;
    const entry = {
      value: data,
      lastModified: Date.now(),
      tags: ctx.tags || [],
    };

    const ttl = ctx.revalidate
      ? ctx.revalidate
      : 60 * 60 * 24 * 365; // 1 year default

    await client.set(`next:${key}`, JSON.stringify(entry), { EX: ttl });

    // Index by tags for tag-based revalidation
    for (const tag of ctx.tags || []) {
      await client.sAdd(`next:tag:${tag}`, key);
    }
  }

  async revalidateTag(tags) {
    await connecting;
    for (const tag of [tags].flat()) {
      const keys = await client.sMembers(`next:tag:${tag}`);
      if (keys.length > 0) {
        await client.del(keys.map((k) => `next:${k}`));
        await client.del(`next:tag:${tag}`);
      }
    }
  }
}
```

### S3 Cache Handler (for serverless/multi-region)

```js
// cache-handler.mjs
import { S3Client, GetObjectCommand, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";

const s3 = new S3Client({ region: process.env.AWS_REGION });
const BUCKET = process.env.CACHE_BUCKET;

export default class CacheHandler {
  async get(key) {
    try {
      const response = await s3.send(
        new GetObjectCommand({ Bucket: BUCKET, Key: `cache/${key}.json` })
      );
      const body = await response.Body.transformToString();
      return JSON.parse(body);
    } catch {
      return null;
    }
  }

  async set(key, data, ctx) {
    const entry = {
      value: data,
      lastModified: Date.now(),
      tags: ctx.tags || [],
    };

    await s3.send(
      new PutObjectCommand({
        Bucket: BUCKET,
        Key: `cache/${key}.json`,
        Body: JSON.stringify(entry),
        ContentType: "application/json",
      })
    );
  }

  async revalidateTag(tags) {
    // Implementation depends on your tag indexing strategy
    // Consider using DynamoDB for tag→key mapping
  }
}
```
