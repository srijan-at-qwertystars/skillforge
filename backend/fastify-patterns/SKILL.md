---
name: fastify-patterns
description: >
  Fastify v5 web framework patterns for Node.js. Use when: building Fastify routes, plugin architecture, schema validation with JSON Schema or Zod via fastify-type-provider-zod, hooks lifecycle (onRequest, preHandler, preSerialization), decorators, serialization, Fastify TypeScript type providers, request/response validation, error handling with setErrorHandler, pino logging, testing with inject, rate limiting, CORS, multipart uploads, WebSocket, authentication with @fastify/jwt, database integration, @fastify/autoload plugin loading. Do NOT use for: Express.js middleware patterns (app.use), Koa context or middleware chains, Hapi server configuration or plugins, NestJS decorators or modules, general HTTP concepts without Fastify context, Connect-style middleware, non-Fastify Node.js frameworks.
---

# Fastify v5 Patterns

## Installation & Setup

```bash
npm i fastify @fastify/autoload @fastify/sensible
npm i -D typescript @types/node tsx
npm i fastify-type-provider-zod zod  # Zod validation
```

```typescript
import Fastify from 'fastify';
const app = Fastify({
  logger: { level: 'info' },  // pino built-in
  // loggerInstance: customPinoLogger,  // v5: use loggerInstance for custom loggers
});
app.get('/health', async () => ({ status: 'ok' }));
app.listen({ port: 3000, host: '0.0.0.0' }, (err) => {
  if (err) { app.log.error(err); process.exit(1); }
});
```

tsconfig.json: `{ "compilerOptions": { "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext", "strict": true, "outDir": "dist" } }`

## Project Structure & Autoload

```
src/
  app.ts           # Fastify instance factory (no listen — enables testing)
  server.ts        # Calls app.listen — entry point
  plugins/         # Autoloaded: db, auth, cors (loaded first)
  routes/          # Autoloaded: each file exports route plugin
    users/index.ts       # GET/POST /users
    users/_id/index.ts   # GET/PUT/DELETE /users/:id (_id → :id param)
  schemas/         # Shared JSON Schema / Zod schemas
```

```typescript
// src/app.ts — separate factory for testability
import Fastify from 'fastify';
import autoLoad from '@fastify/autoload';
import path from 'node:path';

export function buildApp(opts = {}) {
  const app = Fastify(opts);
  app.register(autoLoad, { dir: path.join(__dirname, 'plugins') });
  app.register(autoLoad, {
    dir: path.join(__dirname, 'routes'),
    dirNameRoutePrefix: true,  // folder names become route prefixes
  });
  return app;
}

// src/server.ts
import { buildApp } from './app.js';
const app = buildApp({ logger: true });
await app.listen({ port: 3000, host: '0.0.0.0' });
```

## Route Definition

```typescript
import { FastifyPluginAsync } from 'fastify';

const userRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.get('/', async () => fastify.db.query('SELECT * FROM users'));

  fastify.post<{ Body: { name: string; email: string } }>('/', {
    schema: {
      body: {
        type: 'object', required: ['name', 'email'],
        properties: { name: { type: 'string', minLength: 1 }, email: { type: 'string', format: 'email' } },
      },
      response: { 201: { type: 'object', properties: { id: { type: 'integer' }, name: { type: 'string' } } } },
    },
  }, async (request, reply) => {
    const user = await fastify.db.insert(request.body);
    reply.code(201).send(user);
  });

  fastify.get<{ Params: { id: string } }>('/:id', async (req) => fastify.db.findById(req.params.id));
};
export default userRoutes;
```

## Plugin System

Every `register()` creates an encapsulated context. Use `fastify-plugin` (fp) to break encapsulation.

```typescript
import fp from 'fastify-plugin';

// fp() breaks encapsulation — decorator visible to parent & siblings
export default fp(async (fastify, opts) => {
  const pool = createPool(opts.connectionString);
  fastify.decorate('db', pool);
  fastify.addHook('onClose', async () => pool.end());
}, { name: 'db-plugin' });

// Without fp() — encapsulated (hooks/routes stay scoped to this plugin)
export default async function privateRoutes(fastify, opts) {
  fastify.addHook('onRequest', fastify.authenticate);
  fastify.get('/me', async (req) => req.user);
}

// Prefix routes
app.register(adminRoutes, { prefix: '/api/v1/admin' });
```

## Schema Validation

### JSON Schema (default Ajv — v5 requires full schemas, no shorthand)

```typescript
const schema = {
  body: {
    type: 'object', required: ['title'],
    properties: {
      title: { type: 'string', maxLength: 200 },
      tags: { type: 'array', items: { type: 'string' }, maxItems: 10 },
    },
    additionalProperties: false,
  },
  querystring: {
    type: 'object',
    properties: { page: { type: 'integer', minimum: 1, default: 1 }, limit: { type: 'integer', minimum: 1, maximum: 100, default: 20 } },
  },
  params: { type: 'object', properties: { id: { type: 'string', format: 'uuid' } }, required: ['id'] },
  response: {
    200: { type: 'object', properties: { id: { type: 'string' }, title: { type: 'string' } } },
  },
};
```

### Zod Integration (fastify-type-provider-zod)

```typescript
import { serializerCompiler, validatorCompiler, ZodTypeProvider } from 'fastify-type-provider-zod';
import { z } from 'zod';

const app = Fastify();
app.setValidatorCompiler(validatorCompiler);
app.setSerializerCompiler(serializerCompiler);

app.withTypeProvider<ZodTypeProvider>().route({
  method: 'POST', url: '/items',
  schema: {
    body: z.object({ name: z.string().min(1), price: z.number().positive() }),
    response: { 201: z.object({ id: z.string().uuid(), name: z.string() }) },
  },
  handler: async (req, reply) => {
    // req.body fully typed as { name: string; price: number }
    reply.code(201).send(await createItem(req.body));
  },
});
// POST /items {"name":"Widget","price":9.99} → 201 {"id":"uuid","name":"Widget"}
// POST /items {"name":"","price":-1} → 400 validation error
```

## Hooks Lifecycle

Order: `onRequest → preParsing → preValidation → preHandler → [handler] → preSerialization → onSend → onResponse`

```typescript
fastify.addHook('onRequest', async (request, reply) => {
  request.startTime = Date.now();
});

// Route-level hook
fastify.get('/data', {
  preHandler: async (request, reply) => {
    if (!request.headers['x-api-key']) reply.code(401).send({ error: 'Missing API key' });
  },
}, handler);

// Modify payload before serialization
fastify.addHook('preSerialization', async (request, reply, payload) => {
  return { ...payload, timestamp: new Date().toISOString() };
});

// After serialization — add headers
fastify.addHook('onSend', async (request, reply, payload) => {
  reply.header('X-Response-Time', Date.now() - request.startTime);
  return payload;
});

// After response sent — metrics/logging
fastify.addHook('onResponse', async (request, reply) => {
  request.log.info({ responseTime: reply.elapsedTime }, 'request completed');
});
```

## Decorators

Always use `decorate*` API — never assign properties directly (causes V8 deoptimization).

```typescript
fastify.decorate('config', { jwtSecret: process.env.JWT_SECRET });
fastify.decorateRequest('user', null);  // set per-request in hook
fastify.decorateReply('sendSuccess', function (data: unknown) {
  return this.code(200).send({ success: true, data });
});

// TypeScript: extend interfaces via declaration merging
declare module 'fastify' {
  interface FastifyInstance { config: { jwtSecret: string } }
  interface FastifyRequest { user: { id: string; role: string } | null }
  interface FastifyReply { sendSuccess(data: unknown): void }
}
```

## Serialization

Response schemas enable `fast-json-stringify` (2-3x faster than JSON.stringify). Unlisted properties are stripped (security).

```typescript
fastify.get('/users', {
  schema: {
    response: { 200: {
      type: 'array', items: {
        type: 'object', properties: { id: { type: 'integer' }, name: { type: 'string' } },
      },
    }},
  },
}, async () => db.getUsers());
// DB returns { id, name, passwordHash } → response sends only { id, name }
```

## Error Handling

```typescript
fastify.setErrorHandler((error, request, reply) => {
  request.log.error({ err: error }, 'request error');
  if (error.validation) return reply.code(400).send({ error: 'Validation failed', details: error.validation });
  const status = error.statusCode ?? 500;
  reply.code(status).send({ error: status >= 500 ? 'Internal Server Error' : error.message });
});

fastify.setNotFoundHandler((request, reply) => {
  reply.code(404).send({ error: 'Route not found', path: request.url });
});

// @fastify/sensible provides httpErrors helpers
app.register(sensible);
// In handler: throw app.httpErrors.notFound('User not found');
```

## Logging (Pino)

```typescript
const app = Fastify({
  logger: {
    level: process.env.LOG_LEVEL || 'info',
    transport: process.env.NODE_ENV !== 'production'
      ? { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss' } }
      : undefined,
    serializers: {
      req(request) { return { method: request.method, url: request.url }; },
    },
  },
});

// In handlers — request.log adds reqId automatically
request.log.info({ userId: 123 }, 'fetching user data');
// → {"reqId":"xxx","userId":123,"msg":"fetching user data"}
```

## TypeScript Type Providers

```typescript
import { TypeBoxTypeProvider } from '@fastify/type-provider-typebox';
import { Type } from '@sinclair/typebox';

const app = Fastify().withTypeProvider<TypeBoxTypeProvider>();
app.get('/items', {
  schema: {
    querystring: Type.Object({ q: Type.String(), page: Type.Integer({ minimum: 1 }) }),
    response: { 200: Type.Array(Type.Object({ id: Type.String(), name: Type.String() })) },
  },
}, async (req) => searchItems(req.query.q, req.query.page));
// req.query fully typed: { q: string; page: number }
```

v5 splits type providers into `ValidatorSchema` and `SerializerSchema` for finer control.

## Authentication (JWT)

```typescript
import fastifyJwt from '@fastify/jwt';
import fp from 'fastify-plugin';

export default fp(async (fastify) => {
  fastify.register(fastifyJwt, { secret: process.env.JWT_SECRET! });
  fastify.decorate('authenticate', async (request, reply) => {
    try { await request.jwtVerify(); }
    catch { reply.code(401).send({ error: 'Unauthorized' }); }
  });
});

// Protect routes
fastify.get('/me', { onRequest: [fastify.authenticate] }, async (req) => req.user);

// Sign tokens
fastify.post('/login', async (req, reply) => {
  const user = await validateCredentials(req.body);
  reply.send({ token: fastify.jwt.sign({ id: user.id, role: user.role }, { expiresIn: '1h' }) });
});

// Multi-strategy with @fastify/auth
fastify.register(auth);
fastify.route({
  method: 'GET', url: '/resource',
  preHandler: fastify.auth([fastify.verifyJwt, fastify.verifyApiKey]),
  handler: async (req) => ({ data: 'protected' }),
});
```

## Testing (inject)

`app.inject()` sends in-memory requests — no network needed.

```typescript
import { buildApp } from '../src/app.js';
import { test, describe } from 'node:test';
import assert from 'node:assert';

describe('User API', () => {
  test('GET /users returns 200', async () => {
    const app = buildApp({ logger: false });
    const res = await app.inject({ method: 'GET', url: '/users' });
    assert.strictEqual(res.statusCode, 200);
    assert.ok(Array.isArray(res.json()));
  });

  test('POST /users validates body', async () => {
    const app = buildApp({ logger: false });
    const res = await app.inject({ method: 'POST', url: '/users', payload: { name: '' } });
    assert.strictEqual(res.statusCode, 400);
  });

  test('authenticated route with JWT', async () => {
    const app = buildApp({ logger: false });
    await app.ready();
    const token = app.jwt.sign({ id: '1', role: 'admin' });
    const res = await app.inject({
      method: 'GET', url: '/me',
      headers: { authorization: `Bearer ${token}` },
    });
    assert.strictEqual(res.statusCode, 200);
  });
});
```

## Rate Limiting

```typescript
import rateLimit from '@fastify/rate-limit';
app.register(rateLimit, {
  max: 100, timeWindow: '1 minute',
  keyGenerator: (request) => request.ip,
  errorResponseBuilder: (req, ctx) => ({ statusCode: 429, error: 'Too Many Requests', retryAfter: ctx.ttl }),
});
// Per-route: fastify.post('/login', { config: { rateLimit: { max: 5, timeWindow: '5 min' } } }, handler);
```

## CORS

```typescript
import cors from '@fastify/cors';
app.register(cors, {
  origin: ['https://app.example.com', /\.example\.com$/],
  methods: ['GET', 'POST', 'PUT', 'DELETE'],
  credentials: true, maxAge: 86400,
});
```

## Multipart Uploads

```typescript
import multipart from '@fastify/multipart';
app.register(multipart, { limits: { fileSize: 10 * 1024 * 1024 } }); // 10MB

app.post('/upload', async (request, reply) => {
  const file = await request.file();
  if (!file) return reply.code(400).send({ error: 'No file' });
  const buffer = await file.toBuffer();
  reply.send({ filename: file.filename, mimetype: file.mimetype, size: buffer.length });
});

// Multiple files
app.post('/upload-many', async (request) => {
  const results = [];
  for await (const part of request.files()) {
    results.push({ filename: part.filename, size: (await part.toBuffer()).length });
  }
  return results;
});
```

## WebSocket

```typescript
import websocket from '@fastify/websocket';
app.register(websocket);

app.get('/ws', { websocket: true }, (socket, request) => {
  // Attach handlers BEFORE any async work to avoid missing messages
  socket.on('message', (msg) => {
    const data = JSON.parse(msg.toString());
    socket.send(JSON.stringify({ echo: data, ts: Date.now() }));
  });
  socket.on('close', () => request.log.info('client disconnected'));
});
// WS {"text":"hello"} → {"echo":{"text":"hello"},"ts":1234567890}
```

## Database Integration

```typescript
import fp from 'fastify-plugin';
import pg from 'pg';

// PostgreSQL with connection pool
export default fp(async (fastify) => {
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
  await pool.query('SELECT 1');  // verify at startup
  fastify.decorate('db', pool);
  fastify.addHook('onClose', async () => pool.end());
}, { name: 'postgres' });

// Drizzle ORM
import { drizzle } from 'drizzle-orm/node-postgres';
export default fp(async (fastify) => {
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
  fastify.decorate('db', drizzle(pool));
  fastify.addHook('onClose', async () => pool.end());
});

// Prisma
import { PrismaClient } from '@prisma/client';
export default fp(async (fastify) => {
  const prisma = new PrismaClient();
  await prisma.$connect();
  fastify.decorate('prisma', prisma);
  fastify.addHook('onClose', async () => prisma.$disconnect());
});
```

## Deployment

```typescript
const app = buildApp({
  logger: { level: 'info' },  // JSON logs in production — no pino-pretty
  trustProxy: true,            // behind reverse proxy (nginx, ALB)
});
await app.listen({ port: parseInt(process.env.PORT || '3000'), host: '0.0.0.0' });

// Graceful shutdown
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    app.log.info(`${signal} received, shutting down`);
    await app.close();
    process.exit(0);
  });
}
```

**Dockerfile:**
```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
FROM node:22-alpine
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY package*.json ./
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "dist/server.js"]
```

Bind `0.0.0.0` (not localhost). Set `trustProxy` behind load balancers. Use PM2/systemd/Docker for process management. Node.js v20+ required for Fastify v5.
