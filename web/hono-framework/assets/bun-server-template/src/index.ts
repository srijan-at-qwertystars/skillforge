import { Hono } from 'hono'
import { logger } from 'hono/logger'
import { cors } from 'hono/cors'
import { secureHeaders } from 'hono/secure-headers'
import { prettyJSON } from 'hono/pretty-json'
import { serveStatic } from 'hono/bun'
import { HTTPException } from 'hono/http-exception'

const app = new Hono()

// Global middleware
app.use('*', logger())
app.use('*', cors())
app.use('*', secureHeaders())
app.use('*', prettyJSON())

// Serve static files from ./public
app.use('/static/*', serveStatic({ root: './' }))

// Health check
app.get('/health', (c) => {
  return c.json({
    status: 'ok',
    runtime: 'bun',
    version: Bun.version,
  })
})

// Example API routes
const api = new Hono()
  .get('/hello', (c) => c.json({ message: 'Hello from Bun!' }))
  .get('/users', (c) => {
    return c.json({
      users: [
        { id: '1', name: 'Alice' },
        { id: '2', name: 'Bob' },
      ],
    })
  })
  .get('/users/:id', (c) => {
    return c.json({ id: c.req.param('id'), name: 'User' })
  })

app.route('/api', api)

// Error handling
app.onError((err, c) => {
  if (err instanceof HTTPException) return err.getResponse()
  console.error('Unhandled error:', err)
  return c.json({ error: 'Internal Server Error' }, 500)
})

app.notFound((c) => c.json({ error: 'Not Found' }, 404))

// Export for Bun
const port = parseInt(process.env.PORT ?? '3000')
console.log(`🔥 Hono server running on http://localhost:${port}`)

export default {
  fetch: app.fetch,
  port,
}
