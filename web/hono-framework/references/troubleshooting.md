# Hono Troubleshooting Guide

## Table of Contents

- [Middleware Order Bugs](#middleware-order-bugs)
- [Runtime-Specific Gotchas](#runtime-specific-gotchas)
- [TypeScript Type Errors](#typescript-type-errors)
- [CORS Preflight Issues](#cors-preflight-issues)
- [Body Parsing Edge Cases](#body-parsing-edge-cases)
- [Streaming Failures](#streaming-failures)
- [Testing Patterns](#testing-patterns)

---

## Middleware Order Bugs

### Problem: CORS Headers Missing on Error Responses

CORS middleware must be registered **before** any middleware that might throw.

```ts
// ❌ Bug: CORS headers missing when auth throws 401
app.use('/api/*', jwt({ secret: SECRET }))
app.use('/api/*', cors())

// ✅ Fix: CORS before auth
app.use('/api/*', cors({ origin: 'https://example.com' }))
app.use('/api/*', jwt({ secret: SECRET }))
```

### Problem: Logger Doesn't Show Response Info

Logger must be the **first** middleware to wrap the entire request lifecycle.

```ts
// ❌ Bug: logger misses timing of early middleware
app.use('*', cors())
app.use('*', logger())

// ✅ Fix: logger first
app.use('*', logger())
app.use('*', cors())
```

### Problem: Middleware Runs on Wrong Routes

Wildcard `*` matches everything under that path. Be specific.

```ts
// ❌ Bug: auth runs on /api/health too
app.use('/api/*', authMiddleware)
app.get('/api/health', (c) => c.json({ ok: true }))

// ✅ Fix: register health before auth, or use specific paths
app.get('/api/health', (c) => c.json({ ok: true }))
app.use('/api/*', authMiddleware)

// Alternative: conditional middleware
app.use('/api/*', async (c, next) => {
  if (c.req.path === '/api/health') return next()
  return authMiddleware(c, next)
})
```

### Problem: `onError` Doesn't Catch Errors

`app.onError` must be registered **before** the routes that may throw.

```ts
// ❌ Bug: onError registered after routes
app.get('/fail', (c) => { throw new Error('boom') })
app.onError((err, c) => c.json({ error: err.message }, 500))

// ✅ Fix: onError before routes
app.onError((err, c) => c.json({ error: err.message }, 500))
app.get('/fail', (c) => { throw new Error('boom') })
```

### Problem: Response Modified After `next()` Has No Effect

Once `next()` returns, the response is set. You can only modify headers, not replace the body.

```ts
// ❌ Bug: trying to replace response after next()
app.use('*', async (c, next) => {
  await next()
  return c.json({ wrapped: true }) // This creates a NEW response, discarding downstream
})

// ✅ Fix: set headers after next(), or transform the response properly
app.use('*', async (c, next) => {
  await next()
  c.header('X-Processed', 'true') // This works
})
```

---

## Runtime-Specific Gotchas

### Cloudflare Workers

**Issue: `process.env` is undefined**
```ts
// ❌ Wrong: Node.js pattern doesn't work on Workers
const dbUrl = process.env.DATABASE_URL

// ✅ Fix: use c.env for bindings
app.get('/', (c) => {
  const dbUrl = c.env.DATABASE_URL
  return c.json({ dbUrl })
})
```

**Issue: Cannot use Node.js built-in modules**
```ts
// ❌ Wrong: Node.js modules not available
import fs from 'fs'
import path from 'path'

// ✅ Fix: use Web APIs or Cloudflare-specific APIs
// For file storage, use R2. For key-value, use KV. For SQL, use D1.
```

**Issue: Request body already consumed**
Workers may buffer request bodies. Don't read the body multiple times.
```ts
// ❌ Bug: double consumption
app.use('*', async (c, next) => {
  const body = await c.req.json() // consumes body
  console.log(body)
  await next()
})
app.post('/data', async (c) => {
  const body = await c.req.json() // Error: body already consumed
})

// ✅ Fix: store parsed body in context variable
app.use('*', async (c, next) => {
  if (c.req.method === 'POST') {
    const body = await c.req.json()
    c.set('parsedBody', body)
  }
  await next()
})
```

**Issue: Subrequest limits**
Workers have a limit of 50 subrequests (1000 on paid plans). Each `fetch()` call counts.

### Bun

**Issue: `serveStatic` import path**
```ts
// ❌ Wrong: generic import
import { serveStatic } from 'hono/serve-static'

// ✅ Fix: Bun-specific import
import { serveStatic } from 'hono/bun'
```

**Issue: WebSocket setup differs from other runtimes**
```ts
// ❌ Wrong: using generic upgradeWebSocket
import { upgradeWebSocket } from 'hono/cloudflare-workers'

// ✅ Fix: Bun-specific WebSocket setup
import { createBunWebSocket } from 'hono/bun'
const { upgradeWebSocket, websocket } = createBunWebSocket()

export default { fetch: app.fetch, websocket, port: 3000 }
```

### Deno

**Issue: Import specifiers**
```ts
// ❌ Wrong without import map
import { Hono } from 'hono'

// ✅ Fix: use npm: specifier or configure deno.json imports
import { Hono } from 'npm:hono'

// Or in deno.json:
// { "imports": { "hono": "npm:hono@^4" } }
```

**Issue: Permissions**
```bash
# ❌ Error: Requires net permission
deno run src/index.ts

# ✅ Fix: grant required permissions
deno run --allow-net --allow-read --allow-env src/index.ts
```

### Node.js

**Issue: Missing adapter**
```ts
// ❌ Bug: Hono doesn't run on Node without the adapter
export default app // Nothing listens

// ✅ Fix: use @hono/node-server
import { serve } from '@hono/node-server'
serve({ fetch: app.fetch, port: 3000 })
```

**Issue: `serveStatic` import**
```ts
// ❌ Wrong
import { serveStatic } from 'hono/bun'

// ✅ Fix: Node-specific static file serving
import { serveStatic } from '@hono/node-server/serve-static'
app.use('/static/*', serveStatic({ root: './' }))
```

---

## TypeScript Type Errors

### Error: Type inference lost on RPC client

```ts
// ❌ Bug: separate app.get() calls lose type info for hc
const app = new Hono()
app.get('/users', (c) => c.json([]))
app.post('/users', (c) => c.json({}))
export type AppType = typeof app // Only knows about Hono, not routes

// ✅ Fix: chain routes for type preservation
const app = new Hono()
  .get('/users', (c) => c.json([]))
  .post('/users', (c) => c.json({}))
export type AppType = typeof app // Knows about all routes
```

### Error: Generic type arguments mismatch

```ts
// ❌ Error: Type '{ Variables: { userId: string } }' not assignable
const app = new Hono<{ Bindings: Bindings }>()
app.use('*', createMiddleware<{ Variables: { userId: string } }>(async (c, next) => {
  c.set('userId', '123')
  await next()
}))

// ✅ Fix: combine types in the Hono generic
type Env = {
  Bindings: Bindings
  Variables: { userId: string }
}
const app = new Hono<Env>()
```

### Error: `c.req.valid()` type is `never`

```ts
// ❌ Bug: validator target doesn't match what you're accessing
app.post('/users', zValidator('json', schema), (c) => {
  const data = c.req.valid('query') // 'query' doesn't match 'json' → type is never
})

// ✅ Fix: match the validator target
app.post('/users', zValidator('json', schema), (c) => {
  const data = c.req.valid('json') // matches → properly typed
})
```

### Error: Complex route type causes TypeScript slowness

```ts
// ❌ Problem: too many chained routes cause TS to slow down
const app = new Hono()
  .get('/r1', h).get('/r2', h).get('/r3', h)
  // ... 50+ chained routes

// ✅ Fix: split into sub-routers and merge with .route()
const users = new Hono()
  .get('/', listUsers)
  .post('/', createUser)
  .get('/:id', getUser)

const posts = new Hono()
  .get('/', listPosts)
  .post('/', createPost)

const app = new Hono()
  .route('/users', users)
  .route('/posts', posts)

export type AppType = typeof app
```

### Error: `Property 'xxx' does not exist on type` for c.get()

```ts
// ❌ Error: Hono doesn't know about custom variables
app.get('/me', (c) => {
  const userId = c.get('userId') // Error: 'userId' not in Variables
})

// ✅ Fix: declare Variables in the Hono generic
const app = new Hono<{ Variables: { userId: string } }>()
// Or: use createMiddleware with Variables type
```

---

## CORS Preflight Issues

### Problem: OPTIONS Requests Return 404

Hono's `cors()` middleware handles OPTIONS automatically, but it must be registered correctly.

```ts
// ❌ Bug: CORS only on specific routes, missing OPTIONS handler
app.get('/api/data', cors(), handler)

// ✅ Fix: use app.use() with wildcard to cover OPTIONS preflight
app.use('/api/*', cors({
  origin: 'https://example.com',
  allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowHeaders: ['Content-Type', 'Authorization'],
  maxAge: 86400,
  credentials: true,
}))
```

### Problem: CORS Headers Missing for Specific Origins

```ts
// ❌ Bug: origin is a string but multiple origins needed
app.use('*', cors({ origin: 'https://example.com' }))

// ✅ Fix: use function for dynamic origin matching
app.use('*', cors({
  origin: (origin) => {
    const allowed = ['https://app.example.com', 'https://admin.example.com']
    return allowed.includes(origin) ? origin : ''
  },
}))

// Or allow all origins (development only)
app.use('*', cors({ origin: '*' }))
```

### Problem: Credentials with Wildcard Origin

```ts
// ❌ Bug: browsers reject wildcard origin with credentials
app.use('*', cors({ origin: '*', credentials: true }))

// ✅ Fix: use specific origin when credentials are needed
app.use('*', cors({
  origin: 'https://example.com',
  credentials: true,
}))
```

### Problem: Custom Headers Not Exposed to Browser

```ts
// ❌ Bug: browser can't read X-Request-Id from response
app.use('*', cors({ origin: 'https://example.com' }))

// ✅ Fix: expose custom headers
app.use('*', cors({
  origin: 'https://example.com',
  exposeHeaders: ['X-Request-Id', 'X-RateLimit-Remaining'],
}))
```

---

## Body Parsing Edge Cases

### Problem: Body Consumed Twice

```ts
// ❌ Bug: body is a ReadableStream — can only be read once
app.post('/data', async (c) => {
  const text = await c.req.text()
  const json = await c.req.json() // Error: body already consumed
})

// ✅ Fix: read once and parse
app.post('/data', async (c) => {
  const text = await c.req.text()
  const json = JSON.parse(text)
})

// Or: use clone for special cases
app.post('/data', async (c) => {
  const raw = c.req.raw.clone()
  const json = await c.req.json()
  const text = await raw.text() // Read from clone
})
```

### Problem: FormData with File Upload

```ts
// ❌ Bug: parseBody() doesn't handle files correctly by default
app.post('/upload', async (c) => {
  const body = await c.req.parseBody()
  // body['file'] might be a string instead of File
})

// ✅ Fix: use parseBody({ all: true }) for multi-value fields
app.post('/upload', async (c) => {
  const body = await c.req.parseBody({ all: true })
  const file = body['file'] as File
  console.log(file.name, file.size, file.type)
})
```

### Problem: Empty Body on GET Requests

```ts
// ❌ Bug: trying to parse body of GET request
app.get('/search', async (c) => {
  const body = await c.req.json() // Throws: no body on GET

  // ✅ Fix: GET requests use query params
  const query = c.req.query('q')
})
```

### Problem: Large Body Limits

```ts
// ❌ Bug: large uploads fail silently
// Some runtimes have default body size limits

// ✅ Fix: implement body size middleware
const bodyLimit = createMiddleware(async (c, next) => {
  const contentLength = parseInt(c.req.header('Content-Length') ?? '0')
  const maxSize = 10 * 1024 * 1024 // 10MB
  if (contentLength > maxSize) {
    throw new HTTPException(413, { message: 'Request body too large' })
  }
  await next()
})

// Or use Hono's built-in bodyLimit middleware
import { bodyLimit } from 'hono/body-limit'
app.post('/upload', bodyLimit({ maxSize: 10 * 1024 * 1024 }), handler)
```

---

## Streaming Failures

### Problem: Stream Closes Prematurely on Cloudflare Workers

```ts
// ❌ Bug: Worker terminates before stream completes
app.get('/stream', (c) => {
  return c.stream(async (stream) => {
    for (let i = 0; i < 100; i++) {
      await stream.write(`chunk ${i}\n`)
      await new Promise((r) => setTimeout(r, 100)) // 10s total
    }
  })
})

// ✅ Fix: Workers have 30s CPU time limit (more on paid plans)
// Keep streams under the limit, or use Durable Objects for long-running streams
```

### Problem: SSE Connection Drops

```ts
// ❌ Bug: proxy/CDN terminates idle connections
app.get('/sse', (c) => {
  return streamSSE(c, async (stream) => {
    // Long gaps between events → connection dropped
    await stream.sleep(120_000)
    await stream.writeSSE({ data: 'finally!' })
  })
})

// ✅ Fix: send keepalive comments
app.get('/sse', (c) => {
  return streamSSE(c, async (stream) => {
    const keepalive = setInterval(async () => {
      await stream.writeSSE({ data: '', event: 'keepalive' })
    }, 15_000) // Every 15s

    try {
      for await (const event of eventSource) {
        await stream.writeSSE({ data: JSON.stringify(event) })
      }
    } finally {
      clearInterval(keepalive)
    }
  })
})
```

### Problem: Client Doesn't Receive Chunks in Real-Time

```ts
// ❌ Bug: response buffered by reverse proxy
// ✅ Fix: set headers to prevent buffering
app.get('/stream', (c) => {
  c.header('X-Accel-Buffering', 'no')       // nginx
  c.header('Cache-Control', 'no-cache')      // general
  c.header('Content-Type', 'text/event-stream') // for SSE
  return c.stream(async (stream) => {
    // chunks now flow through immediately
  })
})
```

---

## Testing Patterns

### Basic Testing with `app.request()`

```ts
import { describe, it, expect } from 'vitest'
import app from './app'

describe('API', () => {
  it('GET / returns 200', async () => {
    const res = await app.request('/')
    expect(res.status).toBe(200)
  })

  it('POST /users creates user', async () => {
    const res = await app.request('/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: 'Alice', email: 'alice@example.com' }),
    })
    expect(res.status).toBe(201)
    const body = await res.json()
    expect(body.name).toBe('Alice')
  })
})
```

### Testing with Cloudflare Bindings

```ts
// Mock Cloudflare bindings in tests
const mockKV = {
  get: async (key: string) => key === 'existing' ? 'value' : null,
  put: async () => {},
  delete: async () => {},
}

const mockD1 = {
  prepare: (sql: string) => ({
    bind: (...args: any[]) => ({
      all: async () => ({ results: [{ id: 1, name: 'Test' }] }),
      first: async () => ({ id: 1, name: 'Test' }),
      run: async () => ({ success: true }),
    }),
    all: async () => ({ results: [] }),
  }),
}

it('reads from KV', async () => {
  const res = await app.request('/kv/existing', {}, { MY_KV: mockKV })
  expect(res.status).toBe(200)
})

it('queries D1', async () => {
  const res = await app.request('/users', {}, { DB: mockD1 })
  expect(res.status).toBe(200)
})
```

### Testing with Authentication

```ts
import { sign } from 'hono/jwt'

async function authHeader(payload: object) {
  const token = await sign(payload, 'test-secret')
  return { Authorization: `Bearer ${token}` }
}

it('authenticated route returns user', async () => {
  const headers = await authHeader({ sub: 'user-123', role: 'admin' })
  const res = await app.request('/api/me', { headers })
  expect(res.status).toBe(200)
  const body = await res.json()
  expect(body.userId).toBe('user-123')
})

it('unauthenticated request returns 401', async () => {
  const res = await app.request('/api/me')
  expect(res.status).toBe(401)
})
```

### Testing Bun-Specific Features

```ts
// bun:test
import { describe, it, expect } from 'bun:test'
import app from './app'

describe('Bun app', () => {
  it('serves static files', async () => {
    const res = await app.request('/static/index.html')
    expect(res.status).toBe(200)
    expect(res.headers.get('Content-Type')).toContain('text/html')
  })
})
```

### Testing Deno

```ts
// deno test
import { assertEquals } from 'https://deno.land/std/assert/mod.ts'
import app from './app.ts'

Deno.test('GET / returns hello', async () => {
  const res = await app.request('/')
  assertEquals(res.status, 200)
  const body = await res.text()
  assertEquals(body, 'Hello from Deno!')
})
```

### Testing Middleware in Isolation

```ts
import { Hono } from 'hono'

// Test middleware independently
function createTestApp() {
  const app = new Hono()
  app.use('*', myMiddleware)
  app.get('/test', (c) => c.json({ userId: c.get('userId') }))
  return app
}

it('middleware sets userId from token', async () => {
  const app = createTestApp()
  const headers = await authHeader({ sub: 'user-123' })
  const res = await app.request('/test', { headers })
  const body = await res.json()
  expect(body.userId).toBe('user-123')
})

it('middleware rejects invalid token', async () => {
  const app = createTestApp()
  const res = await app.request('/test', {
    headers: { Authorization: 'Bearer invalid-token' },
  })
  expect(res.status).toBe(401)
})
```

### Integration Testing with Real Server

```ts
import { serve } from '@hono/node-server'

let server: ReturnType<typeof serve>

beforeAll(() => {
  server = serve({ fetch: app.fetch, port: 0 }) // random port
})

afterAll(() => {
  server.close()
})

it('full integration test', async () => {
  const addr = server.address() as { port: number }
  const res = await fetch(`http://localhost:${addr.port}/api/health`)
  expect(res.status).toBe(200)
})
```

### Snapshot Testing for OpenAPI Spec

```ts
it('OpenAPI spec matches snapshot', async () => {
  const res = await app.request('/doc')
  const spec = await res.json()
  expect(spec).toMatchSnapshot()
})
```
