---
name: hono-framework
description: >
  Use this skill when building web APIs, HTTP servers, or edge functions with the Hono framework
  (import from 'hono', hono.dev, create-hono, Hono class, c.json, c.text, c.html, hono/jwt,
  hono/cors, @hono/zod-validator, hono/client hc). Triggers on Cloudflare Workers with Hono,
  Bun/Deno/Node.js Hono servers, Hono middleware, Hono RPC client, hono/jsx SSR, or any
  wrangler.toml + Hono project. DO NOT use for Express.js, Fastify, Koa, Nest.js, Next.js API
  routes, or non-Hono frameworks. DO NOT use for general TypeScript questions unrelated to Hono.
  DO NOT use for React/Vue/Svelte frontend-only code. DO NOT use for plain Cloudflare Workers
  without Hono imports.
---

# Hono Framework — Claude Code Skill

## Architecture

Hono is an ultralight (<14KB), multi-runtime web framework built on Web Standards (Request/Response/fetch). It runs unmodified on Cloudflare Workers, Deno, Bun, Node.js, AWS Lambda, Vercel, Fastly Compute, and Netlify Edge. Zero dependencies. TypeScript-first with full type inference.

Key design: every handler receives a Context object `c`. Middleware uses `async (c, next) => {}` pattern. Routing uses a high-performance RegExpRouter (trie-based).

## Project Setup

```bash
# Interactive scaffolding (picks runtime + template)
npm create hono@latest my-app

# Runtime-specific starters
npm create hono@latest my-app -- --template cloudflare-workers
npm create hono@latest my-app -- --template bun
npm create hono@latest my-app -- --template deno
npm create hono@latest my-app -- --template nodejs
npm create hono@latest my-app -- --template aws-lambda
```

Minimal app:

```ts
import { Hono } from 'hono'
const app = new Hono()
app.get('/', (c) => c.text('Hello Hono'))
export default app // Cloudflare Workers / Bun
```

For Node.js, use `@hono/node-server`:

```ts
import { serve } from '@hono/node-server'
import { Hono } from 'hono'
const app = new Hono()
app.get('/', (c) => c.text('Hello'))
serve({ fetch: app.fetch, port: 3000 })
```

## Routing

### Basic Routes

```ts
app.get('/users', (c) => c.json([]))
app.post('/users', (c) => c.json({ created: true }, 201))
app.put('/users/:id', (c) => c.json({ updated: true }))
app.delete('/users/:id', (c) => c.text('Deleted', 204))
```

### Path Parameters

```ts
app.get('/users/:id', (c) => c.json({ id: c.req.param('id') }))
app.get('/posts/:postId/comments/:commentId', (c) => {
  const { postId, commentId } = c.req.param()  // all params as object
  return c.json({ postId, commentId })
})
app.get('/files/*', (c) => c.text(`File: ${c.req.param('*')}`))     // wildcard
app.get('/page/:slug{[a-z0-9-]+}', (c) => c.text(c.req.param('slug'))) // regex
```

### Route Groups

```ts
const api = new Hono()
api.get('/users', (c) => c.json([]))
api.get('/posts', (c) => c.json([]))
app.route('/api/v1', api)  // GET /api/v1/users, GET /api/v1/posts
```

### Method Chaining

```ts
app
  .get('/items', (c) => c.json([]))
  .post('/items', (c) => c.json({ created: true }, 201))
  .get('/items/:id', (c) => c.json({ id: c.req.param('id') }))
```

## Context Object (`c`)

### Response Helpers

```ts
c.json({ key: 'value' })           // application/json
c.json({ error: 'fail' }, 400)     // JSON with status
c.text('plain text')                // text/plain
c.html('<h1>Hello</h1>')           // text/html
c.redirect('/new-path')            // 302 redirect
c.redirect('/new-path', 301)       // 301 redirect
c.body(arrayBuffer)                // Raw body
c.notFound()                       // 404 response
c.header('X-Custom', 'value')      // Set response header
c.status(201)                      // Set status code

### Request Data

```ts
const id = c.req.param('id')              // Path param
const q = c.req.query('q')               // Single query param
const tags = c.req.queries('tag')         // Repeated query params as array
const auth = c.req.header('Authorization')
const body = await c.req.json()           // Parse JSON body
const form = await c.req.parseBody()      // Parse form/multipart
const text = await c.req.text()           // Raw text body
const url = c.req.url                     // Full URL
const method = c.req.method               // HTTP method
const raw = c.req.raw                     // Original Request object
```

### Environment and Variables

```ts
// Cloudflare Workers bindings
type Bindings = { MY_KV: KVNamespace; DB: D1Database }
const app = new Hono<{ Bindings: Bindings }>()
app.get('/kv', async (c) => c.json({ value: await c.env.MY_KV.get('key') }))

// Set/get custom variables across middleware chain
app.use('*', async (c, next) => { c.set('requestId', crypto.randomUUID()); await next() })
app.get('/', (c) => c.json({ requestId: c.get('requestId') }))
```

## Middleware

### Built-in Middleware

```ts
import { cors } from 'hono/cors'
import { logger } from 'hono/logger'
import { jwt } from 'hono/jwt'
import { compress } from 'hono/compress'
import { cache } from 'hono/cache'
import { etag } from 'hono/etag'
import { secureHeaders } from 'hono/secure-headers'

app.use('*', logger())
app.use('*', cors({ origin: 'https://example.com' }))
app.use('*', secureHeaders())
app.use('/api/*', compress())

// JWT auth — payload available via c.get('jwtPayload')
app.use('/api/*', jwt({ secret: 'mySecretKey' }))
app.get('/api/me', (c) => c.json(c.get('jwtPayload')))

// Caching (Cloudflare Workers)
app.use('/static/*', cache({ cacheName: 'my-app', cacheControl: 'max-age=3600' }))
```

### Custom Middleware

```ts
import { createMiddleware } from 'hono/factory'

// Simple timing middleware
const requestTimer = async (c, next) => {
  const start = Date.now()
  await next()
  c.header('X-Response-Time', `${Date.now() - start}ms`)
}
app.use('*', requestTimer)

// Typed middleware with createMiddleware
const authMiddleware = createMiddleware<{
  Variables: { userId: string }
}>(async (c, next) => {
  const token = c.req.header('Authorization')?.replace('Bearer ', '')
  if (!token) throw new HTTPException(401, { message: 'No token' })
  c.set('userId', decodeToken(token))
  await next()
})
```

## Validation

Use `@hono/zod-validator` (most popular), `@hono/valibot-validator`, or `@hono/typebox-validator`.

```bash
npm install @hono/zod-validator zod
```

```ts
import { zValidator } from '@hono/zod-validator'
import { z } from 'zod'

const createUserSchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
})

// Validate JSON body
app.post('/users', zValidator('json', createUserSchema), (c) => {
  const data = c.req.valid('json') // fully typed: { name: string, email: string }
  return c.json({ user: data }, 201)
})

// Validate query params
const querySchema = z.object({ page: z.coerce.number().default(1) })
app.get('/items', zValidator('query', querySchema), (c) => {
  const { page } = c.req.valid('query')
  return c.json({ page })
})

// Validate path params
const paramSchema = z.object({ id: z.string().uuid() })
app.get('/users/:id', zValidator('param', paramSchema), (c) => {
  const { id } = c.req.valid('param')
  return c.json({ id })
})

// Custom error handler for validation
app.post('/strict',
  zValidator('json', createUserSchema, (result, c) => {
    if (!result.success) {
      return c.json({ errors: result.error.flatten() }, 422)
    }
  }),
  (c) => c.json(c.req.valid('json'))
)
```

Validation targets: `'json'`, `'query'`, `'param'`, `'header'`, `'cookie'`, `'form'`.

## RPC Client (`hc`)

End-to-end type-safe client with zero codegen. Server types flow to client automatically.

### Server — export route types

```ts
// server.ts
import { Hono } from 'hono'
import { zValidator } from '@hono/zod-validator'
import { z } from 'zod'

const app = new Hono()
  .get('/posts', (c) => c.json({ posts: [{ id: 1, title: 'Hello' }] }))
  .post('/posts',
    zValidator('json', z.object({ title: z.string() })),
    (c) => {
      const { title } = c.req.valid('json')
      return c.json({ id: 2, title }, 201)
    }
  )

export type AppType = typeof app
export default app
```

### Client — consume with full type inference

```ts
// client.ts
import { hc } from 'hono/client'
import type { AppType } from './server'

const client = hc<AppType>('http://localhost:3000')

// Fully typed — IDE autocompletes paths, methods, body, and response
const res = await client.posts.$get()
const data = await res.json()  // { posts: { id: number, title: string }[] }

const created = await client.posts.$post({ json: { title: 'New Post' } })
const newPost = await created.json() // { id: number, title: string }
```

## JSX / TSX Support

Hono includes a built-in JSX engine for server-side rendering. No React required.

### tsconfig.json

```json
{
  "compilerOptions": {
    "jsx": "react-jsx",
    "jsxImportSource": "hono/jsx"
  }
}
```

### Components and Rendering

```tsx
import { Hono } from 'hono'
import type { FC } from 'hono/jsx'

const Layout: FC = ({ children }) => (
  <html><body>{children}</body></html>
)

const UserList: FC<{ users: { name: string }[] }> = ({ users }) => (
  <Layout><ul>{users.map((u) => <li>{u.name}</li>)}</ul></Layout>
)

app.get('/', (c) => c.html(<UserList users={[{ name: 'Alice' }]} />))
```

### Streaming SSR with Suspense

```tsx
import { Suspense } from 'hono/jsx'
import { jsxRenderer } from 'hono/jsx-renderer'

app.use('*', jsxRenderer(({ children }) => (
  <html><body>{children}</body></html>
), { stream: true }))

app.get('/stream', (c) => c.render(
  <Suspense fallback={<div>Loading...</div>}><AsyncData /></Suspense>
))
```

## Testing

Use `app.request()` for in-memory testing — no server needed. Works with Vitest, Jest, or any test runner.

```ts
const app = new Hono()
app.get('/hello', (c) => c.json({ message: 'Hello' }))

// Test
const res = await app.request('/hello')
expect(res.status).toBe(200)
expect(await res.json()).toEqual({ message: 'Hello' })

// POST with body
const res2 = await app.request('/echo', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ foo: 'bar' }),
})
```

`app.request(path, init?, env?)` — `init` follows `RequestInit`. Pass `env` for Cloudflare bindings in tests.

## Error Handling

### HTTPException

```ts
import { HTTPException } from 'hono/http-exception'

app.get('/protected', (c) => {
  if (!c.req.header('Authorization')) {
    throw new HTTPException(401, { message: 'Token required' })
  }
  return c.json({ data: 'secret' })
})
```

### Global Error Handler

```ts
app.onError((err, c) => {
  if (err instanceof HTTPException) {
    return err.getResponse()
  }
  console.error(err)
  return c.json({ error: 'Internal Server Error' }, 500)
})

// 404 handler
app.notFound((c) => c.json({ error: 'Not Found' }, 404))
```

## Runtime Adapters and Deployment

### Cloudflare Workers

```ts
// Just export default — runs natively
export default app
// Deploy: npx wrangler deploy
```

### Deno

```ts
Deno.serve(app.fetch)
// Run: deno run --allow-net server.ts
```

### Bun

```ts
export default { fetch: app.fetch, port: 3000 }
// Or: Bun.serve({ fetch: app.fetch, port: 3000 })
// Run: bun run server.ts
```

### Node.js

```ts
import { serve } from '@hono/node-server'
serve({ fetch: app.fetch, port: 3000 })
// Run: npx tsx server.ts
```

### AWS Lambda

```ts
import { handle } from 'hono/aws-lambda'
export const handler = handle(app)
```

### Runtime detection helper

```ts
import { getRuntimeKey } from 'hono/adapter'
app.get('/runtime', (c) => c.text(getRuntimeKey())) // 'workerd'|'deno'|'bun'|'node'|...
```

## Hono vs Express / Fastify

| Feature | Hono | Express | Fastify |
|---------|------|---------|---------|
| Size | <14KB | ~200KB+ | ~100KB+ |
| Multi-runtime | Yes (CF, Deno, Bun, Node, Lambda) | Node only | Node only |
| TypeScript | Native, full inference | Bolt-on @types | Good support |
| Web Standards | Request/Response native | req/res custom | req/res custom |
| RPC client | Built-in `hc` | None | None |
| Perf (Bun) | ~150k req/s | ~25k req/s | ~60k req/s |
| Middleware | Composable async | callback-based | plugin system |

Migrate from Express: `req/res` → `c`, `res.json()` → `c.json()`, `req.params` → `c.req.param()`, `req.query` → `c.req.query()`.

## Common Pitfalls

1. **Forgetting `await next()`** — middleware must call `await next()` or the chain stops. Always await it.
2. **Returning after `next()`** — if you return a new Response after `await next()`, it replaces the downstream response. Set headers instead.
3. **Body consumed twice** — `c.req.json()` consumes the body stream. Call it once and store the result. Do not call both `c.req.json()` and `c.req.text()` on the same request.
4. **Missing `@hono/node-server`** — Hono doesn't run on Node without this adapter. Use `serve()` from it.
5. **Type export for RPC** — always chain routes on the same `Hono()` instance or use `.route()` to preserve types. Separate `app.get(...)` calls lose type inference for `hc`. Use `const route = app.get(...)` pattern.
6. **Cloudflare bindings** — access via `c.env.BINDING_NAME`, not `process.env`. Type them with `Hono<{ Bindings: { ... } }>`.
7. **Validator target mismatch** — `zValidator('json', schema)` validates JSON body. Use `'query'` for query params, `'param'` for path params. Mismatched targets silently pass.
8. **Middleware order** — middleware runs in registration order. Place `cors()` and `logger()` before route-specific middleware. Place `onError` handler before routes that throw.

## Reference Documents

### `references/advanced-patterns.md`
Deep dive into advanced Hono features: RPC client (`hc`) type inference, `InferRequestType`/`InferResponseType`, middleware composition (`every`/`some` from `hono/combine`), custom middleware authoring with `createMiddleware`, OpenAPI integration (`@hono/zod-openapi` + Swagger UI), WebSocket support (per-runtime `upgradeWebSocket`), streaming responses (`c.stream`, `c.streamText`), Server-Sent Events (`streamSSE`), session management (cookies, signed cookies), rate limiting patterns (in-memory, KV-backed), authentication (JWT, API keys, OAuth2), and multi-tenant patterns (subdomain, header, path-based).

### `references/runtime-guide.md`
Per-runtime deployment and configuration: Cloudflare Workers (wrangler.toml, KV, D1, R2 bindings, Durable Objects), Bun (`Bun.serve`, static files, SQLite), Deno (`Deno.serve`, Deno KV, deno.json imports), Node.js (`@hono/node-server`, HTTP/2, Dockerfile), AWS Lambda (`hono/aws-lambda`, SAM template), Vercel (edge/serverless, `hono/vercel`), Fastly Compute (`app.fire()`). Cross-runtime env access with `env()` helper and `getRuntimeKey()`. Performance comparison table.

### `references/troubleshooting.md`
Common issues and fixes: middleware ordering bugs (CORS before auth, logger first, `onError` placement), runtime-specific gotchas (CF Workers `c.env` vs `process.env`, Bun WebSocket setup, Deno permissions, Node adapter requirement), TypeScript type errors (RPC type loss, generics mismatch, `c.req.valid()` returning `never`, TS slowness with large chains), CORS preflight (OPTIONS 404, multi-origin, credentials), body parsing (double consumption, FormData files, `bodyLimit`), streaming failures (Worker CPU limits, SSE keepalive, proxy buffering), testing patterns per runtime (mocking CF bindings, auth helpers, middleware isolation, integration tests).

## Scripts

### `scripts/create-hono-app.sh`
Scaffold a Hono project with runtime selection, TypeScript config, common middleware, test file, and runtime-specific entry point. Supports `--with-openapi` and `--with-auth` flags.

```bash
./scripts/create-hono-app.sh my-api --runtime bun --with-openapi
```

### `scripts/openapi-scaffold.sh`
Generate `@hono/zod-openapi` route files from an OpenAPI 3.x spec (JSON or YAML). Creates typed route definitions, Zod schemas, and Swagger UI endpoint.

```bash
./scripts/openapi-scaffold.sh api-spec.yaml --output ./src/routes
```

### `scripts/hono-benchmark.sh`
Benchmark a running Hono app using `wrk` or `autocannon`. Supports multiple endpoints, custom methods/bodies, warmup, and connection tuning.

```bash
./scripts/hono-benchmark.sh -u http://localhost:3000 -e / -e /api/users -d 30
```

## Assets

### `assets/cloudflare-worker-template/`
Ready-to-deploy Cloudflare Workers template: `wrangler.toml` with KV/D1/R2 binding stubs + `src/index.ts` with typed bindings, middleware stack, and error handling.

### `assets/bun-server-template/`
Bun server template: `package.json` with dev/build/test scripts + `src/index.ts` with static file serving, API routes, and hot reload support.

### `assets/docker-compose.yml`
Docker Compose for Hono Node.js app with Postgres 16 and Redis 7. Includes health checks, volume persistence, and a Dockerfile example in comments.
<!-- tested: pass -->
