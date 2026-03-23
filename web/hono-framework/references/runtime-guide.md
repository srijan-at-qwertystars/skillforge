# Hono Runtime Deployment Guide

## Table of Contents

- [Cloudflare Workers](#cloudflare-workers)
- [Bun](#bun)
- [Deno](#deno)
- [Node.js](#nodejs)
- [AWS Lambda](#aws-lambda)
- [Vercel](#vercel)
- [Fastly Compute](#fastly-compute)
- [Runtime-Specific Env/Bindings Access](#runtime-specific-envbindings-access)
- [Performance Comparison](#performance-comparison)

---

## Cloudflare Workers

### Project Setup

```bash
npm create hono@latest my-app -- --template cloudflare-workers
cd my-app && npm install
```

### wrangler.toml Configuration

```toml
name = "my-hono-app"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[vars]
API_VERSION = "v1"

[[kv_namespaces]]
binding = "MY_KV"
id = "abc123"

[[d1_databases]]
binding = "DB"
database_name = "my-db"
database_id = "def456"

[[r2_buckets]]
binding = "BUCKET"
bucket_name = "my-bucket"
```

### Typed Bindings

```ts
import { Hono } from 'hono'

type Bindings = {
  MY_KV: KVNamespace
  DB: D1Database
  BUCKET: R2Bucket
  API_VERSION: string
}

const app = new Hono<{ Bindings: Bindings }>()

// KV operations
app.get('/kv/:key', async (c) => {
  const value = await c.env.MY_KV.get(c.req.param('key'))
  if (!value) return c.notFound()
  return c.json({ value })
})

app.put('/kv/:key', async (c) => {
  const body = await c.req.text()
  await c.env.MY_KV.put(c.req.param('key'), body, { expirationTtl: 3600 })
  return c.json({ stored: true })
})

// D1 (SQLite) operations
app.get('/users', async (c) => {
  const { results } = await c.env.DB.prepare('SELECT * FROM users LIMIT 50').all()
  return c.json(results)
})

app.get('/users/:id', async (c) => {
  const user = await c.env.DB
    .prepare('SELECT * FROM users WHERE id = ?')
    .bind(c.req.param('id'))
    .first()
  if (!user) return c.notFound()
  return c.json(user)
})

// R2 (object storage) operations
app.get('/files/:key', async (c) => {
  const object = await c.env.BUCKET.get(c.req.param('key'))
  if (!object) return c.notFound()
  c.header('Content-Type', object.httpMetadata?.contentType ?? 'application/octet-stream')
  return c.body(object.body)
})

app.put('/files/:key', async (c) => {
  const body = await c.req.arrayBuffer()
  await c.env.BUCKET.put(c.req.param('key'), body, {
    httpMetadata: { contentType: c.req.header('Content-Type') ?? 'application/octet-stream' },
  })
  return c.json({ uploaded: true })
})

export default app
```

### Deployment

```bash
npx wrangler dev                # Local development (Miniflare)
npx wrangler deploy             # Deploy to production
npx wrangler deploy --env staging  # Deploy to staging environment
npx wrangler tail               # Stream live logs
```

### Durable Objects with Hono

```ts
import { Hono } from 'hono'

export class Counter {
  state: DurableObjectState
  app: Hono

  constructor(state: DurableObjectState) {
    this.state = state
    this.app = new Hono()
    this.app.get('/value', async (c) => {
      const val = (await this.state.storage.get<number>('count')) ?? 0
      return c.json({ count: val })
    })
    this.app.post('/increment', async (c) => {
      const val = ((await this.state.storage.get<number>('count')) ?? 0) + 1
      await this.state.storage.put('count', val)
      return c.json({ count: val })
    })
  }

  fetch(request: Request) {
    return this.app.fetch(request)
  }
}
```

---

## Bun

### Project Setup

```bash
npm create hono@latest my-app -- --template bun
cd my-app && bun install
```

### Server Configuration

```ts
import { Hono } from 'hono'

const app = new Hono()

app.get('/', (c) => c.text('Hello from Bun!'))

// Option 1: export default (simplest)
export default {
  fetch: app.fetch,
  port: 3000,
}

// Option 2: Bun.serve (more control)
Bun.serve({
  fetch: app.fetch,
  port: parseInt(process.env.PORT ?? '3000'),
  development: process.env.NODE_ENV !== 'production',
  // TLS support
  // tls: {
  //   cert: Bun.file('./cert.pem'),
  //   key: Bun.file('./key.pem'),
  // },
})
```

### Bun-Specific Features

```ts
import { serveStatic } from 'hono/bun'

// Serve static files from ./public
app.use('/static/*', serveStatic({ root: './' }))

// File operations with Bun APIs
app.post('/upload', async (c) => {
  const body = await c.req.parseBody()
  const file = body['file'] as File
  await Bun.write(`./uploads/${file.name}`, file)
  return c.json({ uploaded: file.name })
})

// SQLite with Bun's built-in driver
import { Database } from 'bun:sqlite'
const db = new Database('app.db')

app.get('/items', (c) => {
  const items = db.query('SELECT * FROM items').all()
  return c.json(items)
})
```

### Running and Building

```bash
bun run src/index.ts            # Development
bun run --hot src/index.ts      # Hot reload
bun build src/index.ts --target=bun --outdir=./dist  # Bundle
```

---

## Deno

### Project Setup

```bash
npm create hono@latest my-app -- --template deno
cd my-app
```

### Server Configuration

```ts
import { Hono } from 'npm:hono'
// or with import map / deno.json:
// import { Hono } from 'hono'

const app = new Hono()

app.get('/', (c) => c.text('Hello from Deno!'))

Deno.serve({ port: 3000 }, app.fetch)

// With TLS
// Deno.serve({
//   port: 443,
//   cert: await Deno.readTextFile('./cert.pem'),
//   key: await Deno.readTextFile('./key.pem'),
// }, app.fetch)
```

### deno.json Configuration

```json
{
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read --allow-env src/index.ts",
    "start": "deno run --allow-net --allow-read --allow-env src/index.ts"
  },
  "imports": {
    "hono": "npm:hono@^4",
    "@hono/zod-validator": "npm:@hono/zod-validator@^0.4",
    "zod": "npm:zod@^3"
  },
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "npm:hono/jsx"
  }
}
```

### Deno-Specific Features

```ts
import { serveStatic } from 'hono/deno'

app.use('/static/*', serveStatic({ root: './' }))

// Deno KV
const kv = await Deno.openKv()

app.get('/kv/:key', async (c) => {
  const entry = await kv.get(['data', c.req.param('key')])
  if (!entry.value) return c.notFound()
  return c.json(entry.value)
})

app.put('/kv/:key', async (c) => {
  const body = await c.req.json()
  await kv.set(['data', c.req.param('key')], body)
  return c.json({ stored: true })
})
```

### Deploy to Deno Deploy

```bash
# Install deployctl
deno install -A jsr:@deno/deployctl

# Deploy
deployctl deploy --project=my-app src/index.ts
```

---

## Node.js

### Project Setup

```bash
npm create hono@latest my-app -- --template nodejs
cd my-app && npm install
```

### Server Configuration

```ts
import { serve } from '@hono/node-server'
import { Hono } from 'hono'
import { serveStatic } from '@hono/node-server/serve-static'

const app = new Hono()

app.use('/static/*', serveStatic({ root: './' }))
app.get('/', (c) => c.text('Hello from Node.js!'))

serve({
  fetch: app.fetch,
  port: parseInt(process.env.PORT ?? '3000'),
  hostname: '0.0.0.0',
}, (info) => {
  console.log(`Server running at http://localhost:${info.port}`)
})
```

### Node.js with HTTP/2

```ts
import { createServer } from 'node:http2'
import { readFileSync } from 'node:fs'
import { serve } from '@hono/node-server'

serve({
  fetch: app.fetch,
  port: 3000,
  createServer,
  serverOptions: {
    key: readFileSync('./key.pem'),
    cert: readFileSync('./cert.pem'),
  },
})
```

### Environment Variables

```ts
// Node.js uses process.env (not c.env)
app.get('/config', (c) => {
  return c.json({
    dbUrl: process.env.DATABASE_URL,
    nodeEnv: process.env.NODE_ENV,
  })
})

// Or use Hono's env() helper for cross-runtime compatibility
import { env } from 'hono/adapter'

app.get('/config', (c) => {
  const { DATABASE_URL } = env<{ DATABASE_URL: string }>(c)
  return c.json({ dbUrl: DATABASE_URL })
})
```

### Dockerfile

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package.json ./
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

---

## AWS Lambda

### Project Setup

```bash
npm create hono@latest my-app -- --template aws-lambda
cd my-app && npm install
```

### Handler Setup

```ts
import { Hono } from 'hono'
import { handle } from 'hono/aws-lambda'
// For API Gateway v1, use:
// import { handle } from 'hono/aws-lambda'
// The handler auto-detects API Gateway v1, v2, and ALB events.

const app = new Hono()

app.get('/', (c) => c.json({ message: 'Hello from Lambda!' }))
app.get('/users/:id', (c) => c.json({ id: c.req.param('id') }))

export const handler = handle(app)
```

### Accessing Lambda Context and Event

```ts
import { handle, LambdaContext, LambdaEvent } from 'hono/aws-lambda'

app.get('/info', (c) => {
  const lambdaContext = c.env.lambdaContext as LambdaContext
  return c.json({
    functionName: lambdaContext.functionName,
    requestId: lambdaContext.awsRequestId,
    memoryLimit: lambdaContext.memoryLimitInMB,
  })
})
```

### SAM Template (template.yaml)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31

Globals:
  Function:
    Timeout: 30
    Runtime: nodejs20.x
    MemorySize: 256

Resources:
  HonoFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: dist/index.handler
      Events:
        Api:
          Type: HttpApi
          Properties:
            Path: /{proxy+}
            Method: ANY
```

---

## Vercel

### Project Setup

```bash
npm create hono@latest my-app -- --template vercel
cd my-app && npm install
```

### Handler Setup

```ts
// api/index.ts
import { Hono } from 'hono'
import { handle } from 'hono/vercel'

const app = new Hono().basePath('/api')

app.get('/hello', (c) => c.json({ message: 'Hello from Vercel!' }))

// For Vercel Edge Functions
export const runtime = 'edge'
// For Vercel Serverless Functions (Node.js)
// export const runtime = 'nodejs'

export const GET = handle(app)
export const POST = handle(app)
export const PUT = handle(app)
export const DELETE = handle(app)
```

### vercel.json

```json
{
  "rewrites": [
    { "source": "/api/(.*)", "destination": "/api" }
  ]
}
```

---

## Fastly Compute

### Project Setup

```bash
npm create hono@latest my-app -- --template fastly
cd my-app && npm install
```

### Handler

```ts
import { Hono } from 'hono'

const app = new Hono()

app.get('/', (c) => c.text('Hello from Fastly Compute!'))

app.fire()  // Fastly uses app.fire() instead of export default
```

### Build and Deploy

```bash
npx @fastly/cli compute build
npx @fastly/cli compute deploy
```

---

## Runtime-Specific Env/Bindings Access

| Runtime | Env Access | Example |
|---------|-----------|---------|
| Cloudflare Workers | `c.env.BINDING` | `c.env.MY_KV.get('key')` |
| Bun | `process.env.VAR` or `Bun.env.VAR` | `process.env.DATABASE_URL` |
| Deno | `Deno.env.get('VAR')` | `Deno.env.get('DATABASE_URL')` |
| Node.js | `process.env.VAR` | `process.env.DATABASE_URL` |
| AWS Lambda | `process.env.VAR` + `c.env.lambdaContext` | `process.env.TABLE_NAME` |
| Vercel | `process.env.VAR` | `process.env.POSTGRES_URL` |

### Cross-Runtime Environment Access

```ts
import { env } from 'hono/adapter'

// Works on ALL runtimes
app.get('/config', (c) => {
  const { DATABASE_URL, API_KEY } = env<{
    DATABASE_URL: string
    API_KEY: string
  }>(c)
  return c.json({ dbUrl: DATABASE_URL })
})
```

### Runtime Detection

```ts
import { getRuntimeKey } from 'hono/adapter'

app.get('/runtime', (c) => {
  const runtime = getRuntimeKey()
  // Returns: 'workerd' | 'deno' | 'bun' | 'node' | 'fastly' | 'edge-light' | ...
  return c.json({ runtime })
})
```

---

## Performance Comparison

Approximate request/sec benchmarks (simple JSON response, single core):

| Runtime | Requests/sec | Latency (avg) | Cold Start |
|---------|-------------|---------------|------------|
| Bun | ~130,000–150,000 | ~0.07ms | N/A (server) |
| Deno | ~80,000–100,000 | ~0.10ms | N/A (server) |
| Cloudflare Workers | ~50,000+ | ~0.5ms (edge) | <5ms |
| Node.js (@hono/node-server) | ~40,000–60,000 | ~0.15ms | N/A (server) |
| AWS Lambda | Varies | 5–50ms | 100–500ms |
| Vercel Edge | Similar to CF Workers | ~1ms (edge) | <5ms |
| Fastly Compute | ~30,000+ | ~0.5ms (edge) | <10ms |

**Notes:**
- Bun is fastest for raw throughput due to JavaScriptCore engine optimizations
- Edge runtimes (CF Workers, Vercel Edge) excel at global latency due to CDN distribution
- Lambda cold starts can be mitigated with provisioned concurrency
- Node.js performance is competitive with `@hono/node-server` using native HTTP
- All runtimes benefit from Hono's RegExpRouter (O(1) route matching for static paths)
