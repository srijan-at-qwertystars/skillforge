# Fastify Advanced Patterns

> Dense reference for advanced Fastify v5 patterns. Each section includes working code.

## Table of Contents

- [Plugin Encapsulation Deep-Dive](#plugin-encapsulation-deep-dive)
- [Dependency Injection](#dependency-injection)
- [Graceful Shutdown](#graceful-shutdown)
- [Custom Serializers](#custom-serializers)
- [Content Type Parsers](#content-type-parsers)
- [Route Constraints](#route-constraints)
- [API Versioning](#api-versioning)
- [Multitenancy Patterns](#multitenancy-patterns)
- [Streaming Responses](#streaming-responses)
- [Server-Sent Events (SSE)](#server-sent-events-sse)
- [Request Lifecycle Flow](#request-lifecycle-flow)

---

## Plugin Encapsulation Deep-Dive

Every `register()` call creates a new **encapsulated context** — an isolated child scope with its own hooks, decorators, and routes. The parent cannot see child decorators/hooks, but children inherit from parents.

```
Root
├── register(pluginA)      ← gets its own context
│   ├── pluginA's hooks    ← only apply to pluginA's routes
│   └── pluginA's routes
├── register(pluginB)      ← separate context, can't see pluginA's decorators
│   └── pluginB's routes
└── root hooks             ← apply to ALL routes (inherited)
```

### Breaking Encapsulation with `fastify-plugin`

```typescript
import fp from 'fastify-plugin';

// WITHOUT fp: decorator stays inside this plugin's scope
export default async function localPlugin(fastify: FastifyInstance) {
  fastify.decorate('localThing', 'only visible here and in children');
}

// WITH fp: decorator is visible to parent and siblings
export default fp(async (fastify: FastifyInstance) => {
  fastify.decorate('sharedThing', 'visible everywhere after registration');
}, {
  name: 'shared-plugin',           // required for dependency tracking
  dependencies: ['other-plugin'],  // ensures other-plugin loads first
  encapsulate: false,              // v5: explicit opt-out (default for fp)
});
```

### Encapsulation Rules

| Scenario | Visible to parent? | Visible to siblings? | Visible to children? |
|----------|-------------------|---------------------|---------------------|
| Without `fp()` | ❌ | ❌ | ✅ |
| With `fp()` | ✅ | ✅ | ✅ |
| Route-level hooks | ❌ | ❌ | ❌ (route only) |

### Nested Plugin Scoping

```typescript
app.register(async function outerPlugin(fastify) {
  fastify.decorate('outerVal', 42);

  fastify.register(async function innerPlugin(fastify) {
    // Can access outerVal (inherited from parent)
    console.log(fastify.outerVal); // 42
    fastify.decorate('innerVal', 99);
  });

  // Cannot access innerVal here — encapsulated in inner
});
```

---

## Dependency Injection

Fastify's plugin system **is** the DI container. Plugins decorate the instance; downstream plugins consume those decorators.

### Pattern: Service Layer DI

```typescript
// plugins/config.ts — loaded first
export default fp(async (fastify) => {
  const config = {
    db: { host: process.env.DB_HOST!, port: parseInt(process.env.DB_PORT || '5432') },
    redis: { url: process.env.REDIS_URL! },
    jwt: { secret: process.env.JWT_SECRET! },
  };
  fastify.decorate('config', config);
}, { name: 'config' });

// plugins/database.ts — depends on config
export default fp(async (fastify) => {
  const pool = new Pool(fastify.config.db);
  fastify.decorate('db', pool);
  fastify.addHook('onClose', () => pool.end());
}, { name: 'database', dependencies: ['config'] });

// plugins/cache.ts — depends on config
export default fp(async (fastify) => {
  const redis = createClient({ url: fastify.config.redis.url });
  await redis.connect();
  fastify.decorate('cache', redis);
  fastify.addHook('onClose', () => redis.quit());
}, { name: 'cache', dependencies: ['config'] });

// routes/users.ts — consumes db + cache (auto-available)
export default async function userRoutes(fastify: FastifyInstance) {
  fastify.get('/users/:id', async (req) => {
    const cached = await fastify.cache.get(`user:${req.params.id}`);
    if (cached) return JSON.parse(cached);
    const user = await fastify.db.query('SELECT * FROM users WHERE id = $1', [req.params.id]);
    await fastify.cache.setEx(`user:${req.params.id}`, 300, JSON.stringify(user.rows[0]));
    return user.rows[0];
  });
}
```

### Pattern: Repository Injection

```typescript
export default fp(async (fastify) => {
  fastify.decorate('repos', {
    users: new UserRepository(fastify.db),
    orders: new OrderRepository(fastify.db),
    products: new ProductRepository(fastify.db),
  });
}, { name: 'repositories', dependencies: ['database'] });
```

---

## Graceful Shutdown

### Production-Grade Shutdown

```typescript
import Fastify from 'fastify';
import { once } from 'node:events';

const app = Fastify({
  logger: true,
  forceCloseConnections: true, // force-close keep-alive connections on shutdown
});

// Register cleanup hooks in plugins via onClose
// They run in LIFO order (last registered = first closed)

async function start() {
  await app.listen({ port: 3000, host: '0.0.0.0' });

  async function shutdown(signal: string) {
    app.log.info({ signal }, 'shutdown signal received');
    // Stop accepting new connections, drain existing ones
    await app.close();
    app.log.info('server closed');
    process.exit(0);
  }

  // Handle multiple signals
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGUSR2'] as const) {
    process.once(signal, () => shutdown(signal));
  }

  // Handle uncaught exceptions in production
  process.on('uncaughtException', (err) => {
    app.log.fatal(err, 'uncaught exception');
    shutdown('uncaughtException');
  });

  process.on('unhandledRejection', (reason) => {
    app.log.fatal({ reason }, 'unhandled rejection');
    shutdown('unhandledRejection');
  });
}

start();
```

### Shutdown with Health Check Drain

```typescript
let isShuttingDown = false;

app.get('/health', async (req, reply) => {
  if (isShuttingDown) {
    reply.code(503).send({ status: 'draining' });
    return;
  }
  reply.send({ status: 'ok' });
});

async function shutdown(signal: string) {
  isShuttingDown = true;
  // Wait for load balancer to detect unhealthy (drain period)
  await new Promise(resolve => setTimeout(resolve, 5000));
  await app.close();
  process.exit(0);
}
```

### onClose Hook Order

```typescript
// Hooks run LIFO — register dependencies first so they close last
app.register(databasePlugin);   // closes last  (registered first)
app.register(cachePlugin);      // closes second
app.register(sessionPlugin);    // closes first  (registered last)
```

---

## Custom Serializers

### Per-Route Serializer

```typescript
fastify.get('/cbor-data', {
  schema: { response: { 200: { type: 'object', properties: { id: { type: 'string' } } } } },
}, async (req, reply) => {
  const data = await getData();
  reply
    .serializer((payload) => cbor.encode(payload))
    .type('application/cbor')
    .send(data);
});
```

### Custom Serializer Compiler (Global)

```typescript
import Fastify from 'fastify';

const app = Fastify();

// Replace fast-json-stringify with a custom serializer compiler
app.setSerializerCompiler(({ schema, method, url, httpStatus }) => {
  // Return a function that serializes the data
  return (data) => {
    // Add envelope to all responses
    return JSON.stringify({
      success: httpStatus < 400,
      data,
      meta: { url, timestamp: Date.now() },
    });
  };
});
```

### Response Schema Stripping (Security)

```typescript
// Response schemas strip unlisted properties — prevent data leaks
fastify.get('/user/:id', {
  schema: {
    response: {
      200: {
        type: 'object',
        properties: {
          id: { type: 'integer' },
          name: { type: 'string' },
          email: { type: 'string' },
          // passwordHash, internalNotes NOT listed → stripped from response
        },
      },
    },
  },
}, async (req) => db.getUserById(req.params.id));
```

---

## Content Type Parsers

### Parse Custom Content Types

```typescript
// XML parser
import { XMLParser } from 'fast-xml-parser';

fastify.addContentTypeParser('application/xml', { parseAs: 'string' }, (req, body, done) => {
  try {
    const parsed = new XMLParser().parse(body as string);
    done(null, parsed);
  } catch (err) {
    done(err as Error, undefined);
  }
});

// MessagePack parser
fastify.addContentTypeParser('application/msgpack', { parseAs: 'buffer' }, (req, body, done) => {
  try {
    done(null, msgpack.decode(body as Buffer));
  } catch (err) {
    done(err as Error, undefined);
  }
});

// Catch-all parser for unknown content types
fastify.addContentTypeParser('*', { parseAs: 'buffer' }, (req, body, done) => {
  done(null, body);
});
```

### Remove Built-in Parsers

```typescript
// Remove default JSON parser and replace with custom
fastify.removeContentTypeParser('application/json');
fastify.addContentTypeParser('application/json', { parseAs: 'string' }, (req, body, done) => {
  try {
    const json = JSON.parse(body as string);
    // Add custom validation/transformation
    done(null, json);
  } catch (err) {
    done(err as Error, undefined);
  }
});
```

---

## Route Constraints

### Built-in Version Constraint

```typescript
// Client sends Accept-Version header
fastify.get('/api/users', {
  constraints: { version: '1.0.0' },
}, async () => ({ format: 'v1', users: await getUsersV1() }));

fastify.get('/api/users', {
  constraints: { version: '2.0.0' },
}, async () => ({ format: 'v2', users: await getUsersV2(), pagination: {} }));
// curl -H "Accept-Version: 2.0.0" /api/users → v2 response
```

### Built-in Host Constraint

```typescript
fastify.get('/dashboard', {
  constraints: { host: 'admin.example.com' },
}, async () => ({ dashboard: 'admin' }));

fastify.get('/dashboard', {
  constraints: { host: 'user.example.com' },
}, async () => ({ dashboard: 'user' }));
```

### Custom Constraint Strategy

```typescript
import Fastify from 'fastify';

const app = Fastify({
  constraints: {
    tenantId: {
      name: 'tenantId',
      storage() {
        const map = new Map<string, { handler: Function }>();
        return {
          get(key: string) { return map.get(key); },
          set(key: string, store: any) { map.set(key, store); },
          del(key: string) { map.delete(key); },
          empty() { map.clear(); },
        };
      },
      validate(value: unknown) { return typeof value === 'string'; },
      deriveConstraint(req: any) {
        return req.headers['x-tenant-id'] as string;
      },
    },
  },
});

app.get('/data', { constraints: { tenantId: 'acme' } }, async () => ({ tenant: 'acme' }));
app.get('/data', { constraints: { tenantId: 'globex' } }, async () => ({ tenant: 'globex' }));
```

---

## API Versioning

### Prefix-Based Versioning (Simple)

```typescript
app.register(async function v1Routes(fastify) {
  fastify.get('/users', async () => getUsersV1());
}, { prefix: '/api/v1' });

app.register(async function v2Routes(fastify) {
  fastify.get('/users', async () => getUsersV2());
}, { prefix: '/api/v2' });
```

### Header-Based Versioning (Built-in)

```typescript
fastify.route({
  method: 'GET',
  url: '/api/users',
  constraints: { version: '1.0.0' },
  handler: async () => getUsersV1(),
});

fastify.route({
  method: 'GET',
  url: '/api/users',
  constraints: { version: '2.0.0' },
  handler: async () => getUsersV2(),
});
// Semver ranges supported: constraints: { version: '1.x' }
```

### URL Param Versioning (Custom)

```typescript
app.get('/api/:version/users', async (req) => {
  const handlers: Record<string, () => Promise<any>> = {
    v1: getUsersV1,
    v2: getUsersV2,
  };
  const handler = handlers[req.params.version];
  if (!handler) throw app.httpErrors.notFound('Unknown API version');
  return handler();
});
```

---

## Multitenancy Patterns

### Per-Tenant Database via Request Decoration

```typescript
export default fp(async (fastify) => {
  const pools = new Map<string, Pool>();

  fastify.decorateRequest('tenantDb', null);

  fastify.addHook('onRequest', async (req) => {
    const tenantId = req.headers['x-tenant-id'] as string;
    if (!tenantId) throw fastify.httpErrors.badRequest('Missing x-tenant-id');

    if (!pools.has(tenantId)) {
      const connStr = await getTenantConnectionString(tenantId);
      pools.set(tenantId, new Pool({ connectionString: connStr }));
    }
    req.tenantDb = pools.get(tenantId)!;
  });

  fastify.addHook('onClose', async () => {
    for (const pool of pools.values()) await pool.end();
  });
}, { name: 'tenant-db' });

// In routes — each request uses its own tenant's DB
fastify.get('/items', async (req) => {
  return req.tenantDb.query('SELECT * FROM items');
});
```

### Per-Tenant Plugin Registration

```typescript
const tenants = ['acme', 'globex', 'initech'];

for (const tenant of tenants) {
  app.register(async (fastify) => {
    const db = new Pool({ connectionString: getDbUrl(tenant) });
    fastify.decorate('db', db);
    fastify.register(tenantRoutes);
    fastify.addHook('onClose', () => db.end());
  }, { prefix: `/tenant/${tenant}` });
}
// GET /tenant/acme/users → acme's DB
// GET /tenant/globex/users → globex's DB
```

---

## Streaming Responses

### Stream a File

```typescript
import { createReadStream } from 'node:fs';

fastify.get('/download/:filename', async (req, reply) => {
  const stream = createReadStream(`/files/${req.params.filename}`);
  reply.type('application/octet-stream').send(stream);
  // Fastify handles backpressure and error propagation automatically
});
```

### Stream from Database Cursor

```typescript
import { Readable } from 'node:stream';

fastify.get('/export/users', async (req, reply) => {
  const cursor = fastify.db.query(new Cursor('SELECT * FROM users'));

  const stream = new Readable({
    objectMode: true,
    async read(size) {
      const rows = await cursor.read(size);
      if (rows.length === 0) {
        this.push(null);
        cursor.close();
        return;
      }
      for (const row of rows) this.push(JSON.stringify(row) + '\n');
    },
  });

  reply.type('application/x-ndjson').send(stream);
});
```

### Async Iterator Streaming

```typescript
import { Readable } from 'node:stream';

fastify.get('/stream/data', async (req, reply) => {
  async function* generateData() {
    for (let i = 0; i < 1000; i++) {
      yield JSON.stringify({ id: i, ts: Date.now() }) + '\n';
      await new Promise(r => setTimeout(r, 10));
    }
  }
  reply.type('application/x-ndjson').send(Readable.from(generateData()));
});
```

---

## Server-Sent Events (SSE)

### Manual SSE Implementation

```typescript
fastify.get('/events', async (req, reply) => {
  reply.raw.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no', // disable nginx buffering
  });

  let eventId = 0;

  const interval = setInterval(() => {
    const data = JSON.stringify({ time: new Date().toISOString(), id: eventId });
    reply.raw.write(`id: ${eventId}\nevent: tick\ndata: ${data}\n\n`);
    eventId++;
  }, 1000);

  // Clean up on client disconnect
  req.raw.on('close', () => {
    clearInterval(interval);
    reply.raw.end();
  });
});
```

### SSE with Named Events and Retry

```typescript
function sendSSE(reply: FastifyReply, event: string, data: unknown, id?: string) {
  let msg = '';
  if (id) msg += `id: ${id}\n`;
  msg += `event: ${event}\n`;
  msg += `data: ${JSON.stringify(data)}\n\n`;
  reply.raw.write(msg);
}

fastify.get('/notifications', async (req, reply) => {
  reply.raw.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
  });

  // Set retry interval for client reconnection
  reply.raw.write('retry: 5000\n\n');

  const unsubscribe = eventBus.subscribe('notification', (event) => {
    sendSSE(reply, 'notification', event, event.id);
  });

  req.raw.on('close', () => {
    unsubscribe();
    reply.raw.end();
  });
});
```

---

## Request Lifecycle Flow

Complete lifecycle for every request, in execution order:

```
Incoming Request
       │
       ▼
 ┌─────────────┐
 │  onRequest   │  Auth checks, request timing, tenant resolution
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │  preParsing  │  Modify raw stream before body parsing (decompress, decrypt)
 └──────┬──────┘
        ▼
   [Body Parsing]  ← Content-Type parser runs here
        │
        ▼
 ┌──────────────┐
 │ preValidation │  Transform body before schema validation
 └──────┬───────┘
        ▼
   [Schema Validation]  ← Ajv/Zod validates body, querystring, params, headers
        │
        ▼
 ┌─────────────┐
 │  preHandler  │  Business logic guards (authorization, rate limiting)
 └──────┬──────┘
        ▼
   [Route Handler]  ← Your business logic
        │
        ▼
 ┌──────────────────┐
 │ preSerialization  │  Transform payload object before serialization
 └──────┬───────────┘
        ▼
   [Serialization]  ← fast-json-stringify via response schema
        │
        ▼
 ┌─────────────┐
 │   onSend     │  Modify serialized string/buffer, set headers
 └──────┬──────┘
        ▼
   [Response Sent to Client]
        │
        ▼
 ┌─────────────┐
 │  onResponse  │  Logging, metrics (response already sent, no modifications)
 └─────────────┘

Error at any point:
        │
        ▼
 ┌─────────────┐
 │   onError    │  Observe errors before error handler (cannot modify response)
 └──────┬──────┘
        ▼
 [setErrorHandler]  ← Formats error response
        │
        ▼
    onSend → onResponse (normal flow)
```

### Hook Signatures

```typescript
// Hooks that can short-circuit (send early response):
onRequest:       (request, reply) => void
preParsing:      (request, reply, payload: stream) => stream | void
preValidation:   (request, reply) => void
preHandler:      (request, reply) => void

// Hooks that transform payload:
preSerialization: (request, reply, payload: object) => object
onSend:           (request, reply, payload: string) => string

// Observation-only hooks:
onResponse:      (request, reply) => void
onError:         (request, reply, error) => void
onTimeout:       (request, reply) => void
onRequestAbort:  (request, reply) => void
```
