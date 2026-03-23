# Astro Deployment Guide

## Table of Contents

- [Static (SSG) Deployment](#static-ssg-deployment)
  - [GitHub Pages](#github-pages)
  - [AWS S3 + CloudFront](#aws-s3--cloudfront)
  - [Cloudflare Pages (Static)](#cloudflare-pages-static)
- [SSR Deployment](#ssr-deployment)
  - [Node.js Adapter (Standalone)](#nodejs-adapter-standalone)
  - [Vercel](#vercel)
  - [Cloudflare Workers](#cloudflare-workers)
  - [Netlify](#netlify)
  - [Deno](#deno)
- [Hybrid Rendering](#hybrid-rendering)
  - [Per-Route Configuration](#per-route-configuration)
  - [Hybrid with Vercel](#hybrid-with-vercel)
  - [Hybrid with Cloudflare](#hybrid-with-cloudflare)
- [Docker Deployment](#docker-deployment)
  - [Multi-Stage Dockerfile](#multi-stage-dockerfile)
  - [Docker Compose](#docker-compose)
  - [Health Checks](#health-checks)
- [Edge Deployment Patterns](#edge-deployment-patterns)
  - [Edge Middleware](#edge-middleware)
  - [Edge API Routes](#edge-api-routes)
  - [Regional Execution](#regional-execution)
- [CI/CD Pipelines for Astro](#cicd-pipelines-for-astro)
  - [GitHub Actions](#github-actions)
  - [GitLab CI](#gitlab-ci)
  - [General CI Best Practices](#general-ci-best-practices)

---

## Static (SSG) Deployment

Static output (`output: 'static'`, the default) generates a fully pre-rendered site in `dist/`. Deploy to any static hosting provider.

```bash
# Build the site
npm run build
# Output: dist/
```

### GitHub Pages

**astro.config.mjs:**

```js
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://<username>.github.io',
  base: '/<repo-name>',  // omit if using custom domain or user/org site
});
```

**GitHub Actions workflow (`.github/workflows/deploy.yml`):**

```yaml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run build
      - uses: actions/upload-pages-artifact@v3
        with:
          path: dist/

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

Enable GitHub Pages in repo settings → Pages → Source: GitHub Actions.

### AWS S3 + CloudFront

```bash
# Build
npm run build

# Sync to S3
aws s3 sync dist/ s3://my-bucket --delete

# Invalidate CloudFront cache
aws cloudfront create-invalidation \
  --distribution-id E1234567890 \
  --paths "/*"
```

**astro.config.mjs:**

```js
export default defineConfig({
  site: 'https://www.example.com',
  build: {
    format: 'directory',  // /about/index.html instead of /about.html
  },
});
```

S3 bucket policy for static hosting:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::my-bucket/*"
  }]
}
```

### Cloudflare Pages (Static)

```bash
# Install Wrangler
npm install -g wrangler

# Build and deploy
npm run build
npx wrangler pages deploy dist/
```

Or connect your Git repository in Cloudflare Dashboard:
- Build command: `npm run build`
- Build output directory: `dist`
- Environment variable: `NODE_VERSION=20`

---

## SSR Deployment

SSR requires an adapter and `output: 'server'` (or `'hybrid'`).

### Node.js Adapter (Standalone)

```bash
npx astro add node
```

```js
// astro.config.mjs
import node from '@astrojs/node';

export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'standalone' }),
});
```

Build and run:

```bash
npm run build
# Start the server
HOST=0.0.0.0 PORT=4321 node dist/server/entry.mjs
```

For production, use a process manager:

```bash
# PM2
npm install -g pm2
pm2 start dist/server/entry.mjs --name astro-app -i max

# Or systemd service
```

Reverse proxy with Nginx:

```nginx
server {
    listen 80;
    server_name example.com;

    location / {
        proxy_pass http://127.0.0.1:4321;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
```

### Vercel

```bash
npx astro add vercel
```

```js
// astro.config.mjs
import vercel from '@astrojs/vercel';

export default defineConfig({
  output: 'server',
  adapter: vercel({
    // Optional configuration
    imageService: true,       // Use Vercel Image Optimization
    maxDuration: 30,          // Function timeout in seconds
    isr: {                    // Incremental Static Regeneration
      expiration: 60,         // Revalidate every 60 seconds
    },
  }),
});
```

Deploy:

```bash
# Install Vercel CLI
npm i -g vercel

# Deploy (auto-detects Astro)
vercel

# Production deployment
vercel --prod
```

Per-page ISR:

```astro
---
// Revalidate this page every 5 minutes
export const prerender = false;
Astro.response.headers.set('CDN-Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
---
```

### Cloudflare Workers

```bash
npx astro add cloudflare
```

```js
// astro.config.mjs
import cloudflare from '@astrojs/cloudflare';

export default defineConfig({
  output: 'server',
  adapter: cloudflare({
    platformProxy: {
      enabled: true,  // enable Cloudflare bindings in dev
    },
  }),
});
```

`wrangler.toml`:

```toml
name = "my-astro-site"
compatibility_date = "2024-01-01"
compatibility_flags = ["nodejs_compat"]

[site]
bucket = "./dist/client"

[[kv_namespaces]]
binding = "MY_KV"
id = "abc123"
```

Deploy:

```bash
npm run build
npx wrangler deploy
```

### Netlify

```bash
npx astro add netlify
```

```js
// astro.config.mjs
import netlify from '@astrojs/netlify';

export default defineConfig({
  output: 'server',
  adapter: netlify({
    edgeMiddleware: true,  // Run middleware on Netlify Edge
  }),
});
```

`netlify.toml`:

```toml
[build]
  command = "npm run build"
  publish = "dist"

[build.environment]
  NODE_VERSION = "20"

[[headers]]
  for = "/assets/*"
  [headers.values]
    Cache-Control = "public, max-age=31536000, immutable"
```

Deploy:

```bash
# Install Netlify CLI
npm i -g netlify-cli

# Deploy preview
netlify deploy

# Production
netlify deploy --prod
```

### Deno

```bash
npx astro add deno
```

```js
// astro.config.mjs
import deno from '@astrojs/deno';

export default defineConfig({
  output: 'server',
  adapter: deno(),
});
```

Run with Deno:

```bash
npm run build
deno run --allow-net --allow-read --allow-env dist/server/entry.mjs
```

Deploy to Deno Deploy:

```bash
# Install deployctl
deno install -A --no-check -r -f https://deno.land/x/deploy/deployctl.ts

# Deploy
deployctl deploy --project=my-astro-site dist/server/entry.mjs
```

---

## Hybrid Rendering

Hybrid mode (`output: 'hybrid'`) renders pages statically by default, with opt-in SSR per page.

### Per-Route Configuration

```js
// astro.config.mjs
export default defineConfig({
  output: 'hybrid',   // static by default
  adapter: vercel(),  // needed for SSR pages
});
```

```astro
---
// src/pages/about.astro
// Static by default in hybrid mode — no special config needed
---
<h1>About Us</h1>
```

```astro
---
// src/pages/dashboard.astro
export const prerender = false;  // opt into SSR
const user = Astro.locals.user;
---
<h1>Welcome, {user.name}</h1>
```

```ts
// src/pages/api/comments.ts
export const prerender = false;  // API routes need SSR

export const GET: APIRoute = async ({ url }) => {
  const comments = await db.getComments(url.searchParams.get('postId'));
  return Response.json(comments);
};
```

### Hybrid with Vercel

Static pages deploy as edge-cached static files. SSR pages deploy as serverless functions:

```js
import vercel from '@astrojs/vercel';

export default defineConfig({
  output: 'hybrid',
  adapter: vercel({
    isr: { expiration: 300 },  // ISR for SSR pages
  }),
});
```

### Hybrid with Cloudflare

```js
import cloudflare from '@astrojs/cloudflare';

export default defineConfig({
  output: 'hybrid',
  adapter: cloudflare(),
});
```

Static pages are served from Cloudflare's CDN edge cache. SSR pages run in Workers.

---

## Docker Deployment

### Multi-Stage Dockerfile

```dockerfile
# Stage 1: Build
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Production
FROM node:20-alpine AS runtime
WORKDIR /app

# Install sharp dependencies for image optimization
RUN apk add --no-cache vips-dev

# Copy built output
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./

ENV HOST=0.0.0.0
ENV PORT=4321
EXPOSE 4321

USER node
CMD ["node", "dist/server/entry.mjs"]
```

### Docker Compose

```yaml
# docker-compose.yml
services:
  astro:
    build: .
    ports:
      - "4321:4321"
    environment:
      - HOST=0.0.0.0
      - PORT=4321
      - DATABASE_URL=postgresql://user:pass@db:5432/app
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4321/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: pass
      POSTGRES_DB: app
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U user"]
      interval: 10s
      timeout: 5s
      retries: 5

  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
      - ./certs:/etc/nginx/certs
    depends_on:
      - astro
    restart: unless-stopped

volumes:
  pgdata:
```

### Health Checks

Create a health endpoint:

```ts
// src/pages/api/health.ts
export const prerender = false;

export const GET = () => {
  return Response.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
  });
};
```

Docker health check:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -q --spider http://localhost:4321/api/health || exit 1
```

---

## Edge Deployment Patterns

### Edge Middleware

Run middleware at the edge for lowest latency:

```js
// Vercel
export default defineConfig({
  output: 'hybrid',
  adapter: vercel({
    edgeMiddleware: true,  // middleware runs on Vercel Edge
  }),
});

// Netlify
export default defineConfig({
  output: 'hybrid',
  adapter: netlify({
    edgeMiddleware: true,
  }),
});
```

Edge-compatible middleware (no Node.js APIs):

```ts
// src/middleware.ts
import { defineMiddleware } from 'astro:middleware';

export const onRequest = defineMiddleware(async (context, next) => {
  // Geolocation (available at the edge)
  const country = context.request.headers.get('x-vercel-ip-country') || 'US';

  // A/B testing at the edge
  const bucket = context.cookies.get('ab_bucket')?.value
    || (Math.random() > 0.5 ? 'a' : 'b');

  context.cookies.set('ab_bucket', bucket, { path: '/', maxAge: 86400 * 30 });
  context.locals.abBucket = bucket;
  context.locals.country = country;

  return next();
});
```

### Edge API Routes

On Vercel, mark specific routes for edge runtime:

```ts
// src/pages/api/geo.ts
export const prerender = false;

export const GET: APIRoute = async ({ request }) => {
  const country = request.headers.get('x-vercel-ip-country');
  const city = request.headers.get('x-vercel-ip-city');

  return Response.json({ country, city });
};
```

### Regional Execution

Vercel regional configuration:

```js
export default defineConfig({
  adapter: vercel({
    functionPerRoute: true,  // each route in its own function
  }),
});
```

Cloudflare Smart Placement:

```toml
# wrangler.toml
[placement]
mode = "smart"  # Cloudflare auto-places near your data
```

---

## CI/CD Pipelines for Astro

### GitHub Actions

**Full pipeline with testing, preview deploys, and production:**

```yaml
# .github/workflows/ci.yml
name: CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  NODE_VERSION: 20

jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npm run check        # astro check (TypeScript)
      - run: npm run test         # if tests exist

  build:
    needs: lint-and-test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: npm
      - run: npm ci
      - run: npm run build
        env:
          PUBLIC_SITE_URL: ${{ vars.SITE_URL }}
      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/

  lighthouse:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: dist
          path: dist/
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ env.NODE_VERSION }}
      - run: npx serve dist/ &
      - run: sleep 3
      - run: |
          npx @lhci/cli autorun \
            --collect.url=http://localhost:3000 \
            --assert.preset=lighthouse:recommended

  deploy-preview:
    if: github.event_name == 'pull_request'
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: dist
          path: dist/
      - uses: amondnet/vercel-action@v25
        with:
          vercel-token: ${{ secrets.VERCEL_TOKEN }}
          vercel-org-id: ${{ secrets.VERCEL_ORG_ID }}
          vercel-project-id: ${{ secrets.VERCEL_PROJECT_ID }}
          working-directory: dist/

  deploy-production:
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    needs: [build, lighthouse]
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: dist
          path: dist/
      - uses: amondnet/vercel-action@v25
        with:
          vercel-token: ${{ secrets.VERCEL_TOKEN }}
          vercel-org-id: ${{ secrets.VERCEL_ORG_ID }}
          vercel-project-id: ${{ secrets.VERCEL_PROJECT_ID }}
          vercel-args: '--prod'
          working-directory: dist/
```

### GitLab CI

```yaml
# .gitlab-ci.yml
stages:
  - test
  - build
  - deploy

variables:
  NODE_VERSION: "20"

.node-setup:
  image: node:${NODE_VERSION}-alpine
  cache:
    key: ${CI_COMMIT_REF_SLUG}
    paths:
      - node_modules/
  before_script:
    - npm ci

lint:
  extends: .node-setup
  stage: test
  script:
    - npm run lint
    - npm run check

build:
  extends: .node-setup
  stage: build
  script:
    - npm run build
  artifacts:
    paths:
      - dist/
    expire_in: 1 hour

deploy_preview:
  stage: deploy
  image: node:${NODE_VERSION}-alpine
  script:
    - npx wrangler pages deploy dist/ --project-name=$CF_PROJECT --branch=$CI_COMMIT_REF_NAME
  environment:
    name: preview/$CI_COMMIT_REF_SLUG
    url: https://$CI_COMMIT_REF_SLUG.$CF_PROJECT.pages.dev
  only:
    - merge_requests

deploy_production:
  stage: deploy
  image: node:${NODE_VERSION}-alpine
  script:
    - npx wrangler pages deploy dist/ --project-name=$CF_PROJECT --branch=main
  environment:
    name: production
    url: https://$CF_PROJECT.pages.dev
  only:
    - main
```

### General CI Best Practices

**1. Cache dependencies:**

```yaml
# GitHub Actions
- uses: actions/setup-node@v4
  with:
    cache: npm  # or pnpm, yarn

# Or manual cache
- uses: actions/cache@v4
  with:
    path: node_modules
    key: ${{ runner.os }}-node-${{ hashFiles('package-lock.json') }}
```

**2. Run `astro check` for TypeScript validation:**

```bash
npx astro check  # validates .astro files and content collections
```

**3. Preview before deploy:**

```bash
npm run build
npm run preview  # starts local preview server on port 4321
```

**4. Environment-specific builds:**

```bash
# Use different env files per environment
ASTRO_ENV=production npm run build

# Or pass variables directly
PUBLIC_API_URL=https://api.prod.com npm run build
```

**5. Content collection validation in CI:**

```bash
# astro check validates content schemas
npx astro check
# Exits non-zero if any collection entry fails schema validation
```

**6. Lighthouse budgets:**

```json
// lighthouserc.json
{
  "ci": {
    "assert": {
      "assertions": {
        "categories:performance": ["error", { "minScore": 0.9 }],
        "categories:accessibility": ["error", { "minScore": 0.95 }],
        "categories:best-practices": ["error", { "minScore": 0.9 }],
        "categories:seo": ["error", { "minScore": 0.9 }]
      }
    }
  }
}
```
