import { Hono } from 'hono'
import { logger } from 'hono/logger'
import { cors } from 'hono/cors'
import { secureHeaders } from 'hono/secure-headers'
import { prettyJSON } from 'hono/pretty-json'
import { cache } from 'hono/cache'
import { etag } from 'hono/etag'
import { HTTPException } from 'hono/http-exception'

// Type your Cloudflare bindings here
type Bindings = {
  ENVIRONMENT: string
  // KV: KVNamespace
  // DB: D1Database
  // BUCKET: R2Bucket
}

const app = new Hono<{ Bindings: Bindings }>()

// Global middleware
app.use('*', logger())
app.use('*', cors())
app.use('*', secureHeaders())
app.use('*', prettyJSON())
app.use('*', etag())

// Cache static assets
app.use('/static/*', cache({ cacheName: 'static-assets', cacheControl: 'max-age=86400' }))

// Health check
app.get('/health', (c) => {
  return c.json({
    status: 'ok',
    environment: c.env.ENVIRONMENT,
    runtime: 'cloudflare-workers',
  })
})

// Example API routes
const api = new Hono<{ Bindings: Bindings }>()

api.get('/hello', (c) => c.json({ message: 'Hello from Cloudflare Workers!' }))

// KV example (uncomment after enabling KV in wrangler.toml)
// api.get('/kv/:key', async (c) => {
//   const value = await c.env.KV.get(c.req.param('key'))
//   if (!value) return c.notFound()
//   return c.json({ key: c.req.param('key'), value })
// })

// api.put('/kv/:key', async (c) => {
//   const body = await c.req.text()
//   await c.env.KV.put(c.req.param('key'), body, { expirationTtl: 3600 })
//   return c.json({ stored: true })
// })

app.route('/api', api)

// Error handling
app.onError((err, c) => {
  if (err instanceof HTTPException) return err.getResponse()
  console.error('Unhandled error:', err)
  return c.json({ error: 'Internal Server Error' }, 500)
})

app.notFound((c) => c.json({ error: 'Not Found' }, 404))

export default app
