# Hono Advanced Patterns Reference

## Table of Contents

- [RPC Client Deep Dive](#rpc-client-deep-dive)
- [Middleware Composition](#middleware-composition)
- [Custom Middleware Authoring](#custom-middleware-authoring)
- [OpenAPI Integration](#openapi-integration)
- [WebSocket Support](#websocket-support)
- [Streaming Responses](#streaming-responses)
- [Server-Sent Events](#server-sent-events)
- [Session Management](#session-management)
- [Rate Limiting Patterns](#rate-limiting-patterns)
- [Authentication Patterns](#authentication-patterns)
- [Multi-Tenant Patterns](#multi-tenant-patterns)

---

## RPC Client Deep Dive

### Basic `hc` Usage

The `hc` function creates a fully type-safe client from your Hono app's type. Zero codegen — types flow directly from server to client through TypeScript inference.

```ts
import { hc } from 'hono/client'
import type { AppType } from './server'

const client = hc<AppType>('http://localhost:3000')

// Typed path access — IDE autocompletes routes, methods, bodies, responses
const res = await client.api.users.$get()
const users = await res.json() // Fully typed response
```

### Preserving Type Inference with Chaining

**Critical**: You must chain routes on the same Hono instance or use `.route()` to preserve types for the RPC client.

```ts
// ✅ Correct — chained, types preserved
const app = new Hono()
  .get('/users', (c) => c.json({ users: [] }))
  .post('/users', zValidator('json', createSchema), (c) => {
    return c.json(c.req.valid('json'), 201)
  })

export type AppType = typeof app

// ❌ Wrong — separate calls lose type inference
const app = new Hono()
app.get('/users', (c) => c.json({ users: [] }))  // type lost
app.post('/users', ...)                            // type lost
```

### Route Groups with Type Preservation

```ts
// routes/users.ts
const users = new Hono()
  .get('/', (c) => c.json({ users: [] }))
  .get('/:id', (c) => c.json({ id: c.req.param('id') }))
  .post('/', zValidator('json', createUserSchema), (c) => {
    return c.json(c.req.valid('json'), 201)
  })

// routes/posts.ts
const posts = new Hono()
  .get('/', (c) => c.json({ posts: [] }))

// app.ts — mount with .route() to preserve types
const app = new Hono()
  .route('/api/users', users)
  .route('/api/posts', posts)

export type AppType = typeof app
```

### Client with Custom Fetch and Headers

```ts
const client = hc<AppType>('http://localhost:3000', {
  headers: {
    Authorization: `Bearer ${token}`,
    'X-Custom-Header': 'value',
  },
  // Custom fetch for interceptors, retries, etc.
  fetch: (input, init) => {
    console.log(`Fetching: ${input}`)
    return fetch(input, { ...init, credentials: 'include' })
  },
})
```

### Using `$url()` for URL Construction

```ts
// Get typed URL without making a request
const url = client.api.users[':id'].$url({ param: { id: '123' } })
// URL { href: 'http://localhost:3000/api/users/123' }
```

### InferRequestType and InferResponseType

```ts
import type { InferRequestType, InferResponseType } from 'hono/client'

type CreateUserRequest = InferRequestType<typeof client.api.users.$post>
// { json: { name: string; email: string } }

type UsersResponse = InferResponseType<typeof client.api.users.$get>
// { users: { id: string; name: string }[] }

// Extract response type for a specific status code
type Created = InferResponseType<typeof client.api.users.$post, 201>
```

### Shared Types Between Monorepo Packages

```ts
// packages/api/src/index.ts
export type AppType = typeof app

// packages/web/src/api-client.ts
import { hc } from 'hono/client'
import type { AppType } from '@myorg/api'

export const apiClient = hc<AppType>(import.meta.env.VITE_API_URL)
```

---

## Middleware Composition

### Ordering Rules

Middleware executes in registration order. The request flows top-down, and the response flows bottom-up (like an onion).

```ts
app.use('*', logger())          // 1st: logs request → ... → logs response (last)
app.use('*', cors())            // 2nd: sets CORS headers
app.use('*', secureHeaders())   // 3rd: sets security headers
app.use('/api/*', compress())   // 4th: only for /api/* routes
app.use('/api/*', jwt({ secret: SECRET }))  // 5th: auth for /api/*
```

### Conditional Middleware

```ts
import { every, some } from 'hono/combine'

// Apply middleware only if ALL conditions match
app.use('/api/*', every(
  cors(),
  jwt({ secret: SECRET }),
  rateLimiter({ limit: 100 })
))

// Apply if ANY condition matches (first match wins)
app.use('/auth/*', some(
  jwt({ secret: SECRET }),
  basicAuth({ username: 'admin', password: 'pass' })
))
```

### Scoped Middleware with `app.use()`

```ts
// Global — all routes
app.use('*', logger())

// Path prefix — /api and all sub-paths
app.use('/api/*', authMiddleware)

// Exact path
app.use('/health', cacheMiddleware)

// Multiple paths
app.use('/api/*', '/webhook/*', rateLimiter())
```

### Middleware Factories

```ts
function requireRole(...roles: string[]) {
  return createMiddleware<{ Variables: { userId: string; role: string } }>(
    async (c, next) => {
      const role = c.get('role')
      if (!roles.includes(role)) {
        throw new HTTPException(403, { message: `Requires role: ${roles.join('|')}` })
      }
      await next()
    }
  )
}

app.use('/admin/*', authMiddleware)
app.use('/admin/*', requireRole('admin', 'superadmin'))
```

---

## Custom Middleware Authoring

### Basic Pattern

```ts
import { createMiddleware } from 'hono/factory'

const requestId = createMiddleware(async (c, next) => {
  const id = crypto.randomUUID()
  c.set('requestId', id)
  c.header('X-Request-Id', id)
  await next()
})
```

### Typed Middleware with Variables

```ts
type AuthEnv = {
  Variables: {
    userId: string
    role: 'admin' | 'user'
  }
}

const auth = createMiddleware<AuthEnv>(async (c, next) => {
  const token = c.req.header('Authorization')?.replace('Bearer ', '')
  if (!token) throw new HTTPException(401, { message: 'Unauthorized' })

  const payload = await verifyJwt(token)
  c.set('userId', payload.sub)
  c.set('role', payload.role)
  await next()
})

// Downstream handlers get typed access
app.use('/api/*', auth)
app.get('/api/me', (c) => {
  const userId = c.get('userId')   // string
  const role = c.get('role')       // 'admin' | 'user'
  return c.json({ userId, role })
})
```

### Middleware with Options (Factory Pattern)

```ts
interface CacheOptions {
  maxAge?: number
  scope?: 'public' | 'private'
  varyBy?: string[]
}

function cacheControl(opts: CacheOptions = {}) {
  const { maxAge = 3600, scope = 'public', varyBy = [] } = opts
  return createMiddleware(async (c, next) => {
    await next()
    c.header('Cache-Control', `${scope}, max-age=${maxAge}`)
    if (varyBy.length) c.header('Vary', varyBy.join(', '))
  })
}

app.use('/static/*', cacheControl({ maxAge: 86400, scope: 'public' }))
app.use('/api/*', cacheControl({ maxAge: 0, scope: 'private' }))
```

### Error-Handling Middleware

```ts
const errorBoundary = createMiddleware(async (c, next) => {
  try {
    await next()
  } catch (err) {
    if (err instanceof HTTPException) throw err // re-throw HTTP errors
    console.error('Unhandled error:', err)
    return c.json({ error: 'Internal Server Error' }, 500)
  }
})
```

### Response-Transforming Middleware

```ts
const addPagination = createMiddleware(async (c, next) => {
  await next()
  // Modify the response after downstream handlers
  const body = await c.res.json()
  c.res = c.json({
    data: body,
    meta: {
      timestamp: new Date().toISOString(),
      requestId: c.get('requestId'),
    },
  })
})
```

---

## OpenAPI Integration

### Setup with `@hono/zod-openapi`

```bash
npm install @hono/zod-openapi
```

```ts
import { OpenAPIHono, createRoute, z } from '@hono/zod-openapi'

const app = new OpenAPIHono()

// Define route with OpenAPI schema
const getUserRoute = createRoute({
  method: 'get',
  path: '/users/{id}',
  request: {
    params: z.object({
      id: z.string().openapi({ param: { name: 'id', in: 'path' }, example: '123' }),
    }),
  },
  responses: {
    200: {
      content: { 'application/json': { schema: z.object({
        id: z.string(),
        name: z.string(),
        email: z.string().email(),
      }).openapi('User') }},
      description: 'User found',
    },
    404: {
      content: { 'application/json': { schema: z.object({
        error: z.string(),
      }) }},
      description: 'User not found',
    },
  },
})

// Register handler — fully typed from the route definition
app.openapi(getUserRoute, (c) => {
  const { id } = c.req.valid('param')
  return c.json({ id, name: 'Alice', email: 'alice@example.com' }, 200)
})
```

### Swagger UI Integration

```ts
import { swaggerUI } from '@hono/swagger-ui'

// Serve OpenAPI spec
app.doc('/doc', {
  openapi: '3.1.0',
  info: { title: 'My API', version: '1.0.0' },
})

// Serve Swagger UI
app.get('/ui', swaggerUI({ url: '/doc' }))
```

### OpenAPI with Multiple Tags and Security

```ts
const createPostRoute = createRoute({
  method: 'post',
  path: '/posts',
  tags: ['Posts'],
  security: [{ Bearer: [] }],
  request: {
    body: {
      content: { 'application/json': { schema: z.object({
        title: z.string().min(1),
        content: z.string(),
      }).openapi('CreatePost') }},
      required: true,
    },
  },
  responses: {
    201: {
      content: { 'application/json': { schema: z.object({
        id: z.number(),
        title: z.string(),
        content: z.string(),
      }).openapi('Post') }},
      description: 'Post created',
    },
  },
})

// Register security scheme
app.doc('/doc', {
  openapi: '3.1.0',
  info: { title: 'My API', version: '1.0.0' },
  security: [{ Bearer: [] }],
  components: {
    securitySchemes: {
      Bearer: {
        type: 'http',
        scheme: 'bearer',
        bearerFormat: 'JWT',
      },
    },
  },
})
```

---

## WebSocket Support

### Cloudflare Workers WebSocket

```ts
import { Hono } from 'hono'
import { upgradeWebSocket } from 'hono/cloudflare-workers'

const app = new Hono()

app.get('/ws', upgradeWebSocket((c) => ({
  onMessage(event, ws) {
    console.log(`Message: ${event.data}`)
    ws.send(`Echo: ${event.data}`)
  },
  onOpen(event, ws) {
    ws.send('Connected!')
  },
  onClose(event, ws) {
    console.log('Connection closed')
  },
  onError(event, ws) {
    console.error('WebSocket error:', event)
  },
})))
```

### Bun WebSocket

```ts
import { createBunWebSocket } from 'hono/bun'

const { upgradeWebSocket, websocket } = createBunWebSocket()

app.get('/ws', upgradeWebSocket((c) => ({
  onMessage(event, ws) { ws.send(`Echo: ${event.data}`) },
  onOpen(_, ws) { ws.send('Connected!') },
})))

// Include websocket handler in Bun.serve
export default { fetch: app.fetch, websocket, port: 3000 }
```

### Deno WebSocket

```ts
import { upgradeWebSocket } from 'hono/deno'

app.get('/ws', upgradeWebSocket((c) => ({
  onMessage(event, ws) { ws.send(`Echo: ${event.data}`) },
})))
```

---

## Streaming Responses

### Basic Streaming

```ts
app.get('/stream', (c) => {
  return c.streamText(async (stream) => {
    for (let i = 0; i < 10; i++) {
      await stream.writeln(`Line ${i}`)
      await stream.sleep(100) // 100ms delay
    }
  })
})
```

### Streaming with `c.stream()`

```ts
app.get('/download', (c) => {
  return c.stream(async (stream) => {
    // Pipe from a ReadableStream
    const response = await fetch('https://example.com/large-file')
    await stream.pipe(response.body!)
  })
})
```

### Streaming JSON (NDJSON)

```ts
app.get('/events', (c) => {
  return c.stream(async (stream) => {
    for await (const record of database.cursor()) {
      await stream.write(JSON.stringify(record) + '\n')
    }
  })
})
```

### AI/LLM Streaming Pattern

```ts
app.post('/chat', async (c) => {
  const { message } = await c.req.json()
  return c.streamText(async (stream) => {
    const completion = await openai.chat.completions.create({
      model: 'gpt-4',
      messages: [{ role: 'user', content: message }],
      stream: true,
    })
    for await (const chunk of completion) {
      const text = chunk.choices[0]?.delta?.content
      if (text) await stream.write(text)
    }
  })
})
```

---

## Server-Sent Events

```ts
import { streamSSE } from 'hono/streaming'

app.get('/sse', (c) => {
  return streamSSE(c, async (stream) => {
    let id = 0
    while (true) {
      await stream.writeSSE({
        data: JSON.stringify({ time: new Date().toISOString() }),
        event: 'tick',
        id: String(id++),
      })
      await stream.sleep(1000)
    }
  })
})
```

### SSE with Retry and Custom Events

```ts
app.get('/notifications', (c) => {
  return streamSSE(c, async (stream) => {
    // Set retry interval for client reconnection
    await stream.writeSSE({ data: '', retry: 3000 })

    const subscription = eventBus.subscribe('notification')
    try {
      for await (const event of subscription) {
        await stream.writeSSE({
          data: JSON.stringify(event.payload),
          event: event.type, // 'message', 'alert', 'update'
          id: event.id,
        })
      }
    } finally {
      subscription.unsubscribe()
    }
  })
})
```

---

## Session Management

### Cookie-Based Sessions

```ts
import { getCookie, setCookie, deleteCookie } from 'hono/cookie'

app.post('/login', async (c) => {
  const { username, password } = await c.req.json()
  const user = await authenticate(username, password)
  if (!user) throw new HTTPException(401)

  const sessionId = crypto.randomUUID()
  await sessionStore.set(sessionId, { userId: user.id, role: user.role })

  setCookie(c, 'session', sessionId, {
    httpOnly: true,
    secure: true,
    sameSite: 'Lax',
    maxAge: 60 * 60 * 24, // 24 hours
    path: '/',
  })
  return c.json({ success: true })
})

// Session middleware
const sessionMiddleware = createMiddleware(async (c, next) => {
  const sessionId = getCookie(c, 'session')
  if (!sessionId) throw new HTTPException(401)
  const session = await sessionStore.get(sessionId)
  if (!session) {
    deleteCookie(c, 'session')
    throw new HTTPException(401)
  }
  c.set('session', session)
  await next()
})
```

### Signed Cookies

```ts
import { getSignedCookie, setSignedCookie } from 'hono/cookie'

const SECRET = 'my-cookie-secret'

app.post('/preferences', async (c) => {
  const prefs = await c.req.json()
  await setSignedCookie(c, 'prefs', JSON.stringify(prefs), SECRET, {
    httpOnly: true,
    maxAge: 60 * 60 * 24 * 30,
  })
  return c.json({ saved: true })
})

app.get('/preferences', async (c) => {
  const raw = await getSignedCookie(c, SECRET, 'prefs')
  return c.json(raw ? JSON.parse(raw) : {})
})
```

---

## Rate Limiting Patterns

### In-Memory Rate Limiter

```ts
interface RateLimitEntry { count: number; resetAt: number }

function rateLimiter(opts: { limit: number; windowMs: number }) {
  const store = new Map<string, RateLimitEntry>()

  return createMiddleware(async (c, next) => {
    const key = c.req.header('CF-Connecting-IP') ??
                c.req.header('X-Forwarded-For') ?? 'unknown'
    const now = Date.now()
    const entry = store.get(key)

    if (!entry || now > entry.resetAt) {
      store.set(key, { count: 1, resetAt: now + opts.windowMs })
    } else if (entry.count >= opts.limit) {
      c.header('Retry-After', String(Math.ceil((entry.resetAt - now) / 1000)))
      throw new HTTPException(429, { message: 'Too many requests' })
    } else {
      entry.count++
    }

    c.header('X-RateLimit-Limit', String(opts.limit))
    c.header('X-RateLimit-Remaining', String(
      opts.limit - (store.get(key)?.count ?? 0)
    ))
    await next()
  })
}

app.use('/api/*', rateLimiter({ limit: 100, windowMs: 60_000 }))
```

### Cloudflare Workers Rate Limiter with KV

```ts
type Bindings = { RATE_LIMIT: KVNamespace }

function cfRateLimiter(opts: { limit: number; windowSec: number }) {
  return createMiddleware<{ Bindings: Bindings }>(async (c, next) => {
    const ip = c.req.header('CF-Connecting-IP') ?? 'unknown'
    const key = `ratelimit:${ip}`
    const current = parseInt(await c.env.RATE_LIMIT.get(key) ?? '0')

    if (current >= opts.limit) {
      throw new HTTPException(429, { message: 'Rate limit exceeded' })
    }

    await c.env.RATE_LIMIT.put(key, String(current + 1), {
      expirationTtl: opts.windowSec,
    })
    await next()
  })
}
```

---

## Authentication Patterns

### JWT Authentication

```ts
import { jwt, sign, verify } from 'hono/jwt'

const SECRET = 'your-secret-key'

// Login — issue JWT
app.post('/auth/login', async (c) => {
  const { email, password } = await c.req.json()
  const user = await authenticateUser(email, password)
  if (!user) throw new HTTPException(401)

  const token = await sign(
    { sub: user.id, role: user.role, exp: Math.floor(Date.now() / 1000) + 3600 },
    SECRET
  )
  return c.json({ token })
})

// Protect routes — payload in c.get('jwtPayload')
app.use('/api/*', jwt({ secret: SECRET }))
app.get('/api/me', (c) => {
  const { sub, role } = c.get('jwtPayload')
  return c.json({ userId: sub, role })
})
```

### API Key Authentication

```ts
function apiKeyAuth(opts: { header?: string; queryParam?: string }) {
  return createMiddleware(async (c, next) => {
    const key = c.req.header(opts.header ?? 'X-API-Key') ??
                c.req.query(opts.queryParam ?? 'api_key')
    if (!key) throw new HTTPException(401, { message: 'API key required' })

    const client = await validateApiKey(key)
    if (!client) throw new HTTPException(403, { message: 'Invalid API key' })

    c.set('apiClient', client)
    await next()
  })
}

app.use('/api/v1/*', apiKeyAuth({ header: 'X-API-Key' }))
```

### OAuth2 Pattern (GitHub Example)

```ts
app.get('/auth/github', (c) => {
  const params = new URLSearchParams({
    client_id: c.env.GITHUB_CLIENT_ID,
    redirect_uri: `${c.env.BASE_URL}/auth/github/callback`,
    scope: 'user:email',
  })
  return c.redirect(`https://github.com/login/oauth/authorize?${params}`)
})

app.get('/auth/github/callback', async (c) => {
  const code = c.req.query('code')
  if (!code) throw new HTTPException(400)

  const tokenRes = await fetch('https://github.com/login/oauth/access_token', {
    method: 'POST',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: c.env.GITHUB_CLIENT_ID,
      client_secret: c.env.GITHUB_CLIENT_SECRET,
      code,
    }),
  })
  const { access_token } = await tokenRes.json()

  const userRes = await fetch('https://api.github.com/user', {
    headers: { Authorization: `Bearer ${access_token}` },
  })
  const githubUser = await userRes.json()

  const jwt = await sign({ sub: githubUser.id, name: githubUser.login }, SECRET)
  setCookie(c, 'token', jwt, { httpOnly: true, secure: true })
  return c.redirect('/')
})
```

---

## Multi-Tenant Patterns

### Subdomain-Based Tenancy

```ts
type TenantEnv = {
  Variables: { tenantId: string; tenantConfig: TenantConfig }
}

const tenantMiddleware = createMiddleware<TenantEnv>(async (c, next) => {
  const host = c.req.header('Host') ?? ''
  const subdomain = host.split('.')[0]

  if (!subdomain || subdomain === 'www') {
    throw new HTTPException(400, { message: 'Tenant not specified' })
  }

  const config = await getTenantConfig(subdomain)
  if (!config) throw new HTTPException(404, { message: 'Tenant not found' })

  c.set('tenantId', subdomain)
  c.set('tenantConfig', config)
  await next()
})

app.use('/api/*', tenantMiddleware)
app.get('/api/data', (c) => {
  const tenantId = c.get('tenantId')
  return c.json({ tenant: tenantId })
})
```

### Header-Based Tenancy

```ts
const headerTenant = createMiddleware(async (c, next) => {
  const tenantId = c.req.header('X-Tenant-Id')
  if (!tenantId) throw new HTTPException(400, { message: 'X-Tenant-Id header required' })
  c.set('tenantId', tenantId)
  await next()
})
```

### Path-Based Tenancy with Basepath

```ts
function createTenantApp(tenantId: string) {
  const tenant = new Hono()
  tenant.use('*', async (c, next) => {
    c.set('tenantId', tenantId)
    await next()
  })
  tenant.get('/dashboard', (c) => c.json({ tenant: c.get('tenantId') }))
  return tenant
}

// Mount per-tenant apps
app.route('/t/:tenantId', createTenantApp('dynamic'))
```

### Tenant-Scoped Database Connections

```ts
const tenantDb = createMiddleware(async (c, next) => {
  const tenantId = c.get('tenantId')
  const dbUrl = await getConnectionString(tenantId) // e.g., per-tenant schema or DB
  const db = createDbClient(dbUrl)
  c.set('db', db)
  await next()
  await db.close()
})
```
