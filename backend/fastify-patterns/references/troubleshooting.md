# Fastify Troubleshooting Guide

> Diagnosis and fixes for common Fastify errors, performance issues, and migration pitfalls.

## Table of Contents

- [Plugin Registration Order Errors](#plugin-registration-order-errors)
- [Decorator Scope Issues](#decorator-scope-issues)
- [Schema Compilation Failures](#schema-compilation-failures)
- [Performance Issues](#performance-issues)
- [Memory Leaks](#memory-leaks)
- [TypeScript Type Inference Problems](#typescript-type-inference-problems)
- [Migration from Express](#migration-from-express)
- [Production Debugging](#production-debugging)
- [Common Error Messages](#common-error-messages)

---

## Plugin Registration Order Errors

### Symptom: `FST_ERR_DEC_MISSING_DEPENDENCY`

```
FastifyError: The decorator 'db' is not present in Fastify
```

**Cause:** A plugin tries to access a decorator that hasn't been registered yet.

**Fix:** Ensure dependency plugins register before consumers. Use the `dependencies` option:

```typescript
// ❌ Wrong: routes load before db plugin
app.register(routes);
app.register(dbPlugin);

// ✅ Correct: db plugin loads first
app.register(dbPlugin);
app.register(routes);

// ✅ Better: explicit dependency declaration
export default fp(async (fastify) => {
  // This plugin requires 'database' to be loaded first
  const users = await fastify.db.query('SELECT 1');
}, { name: 'user-service', dependencies: ['database'] });
```

### Symptom: Autoload Order Unpredictable

**Fix:** With `@fastify/autoload`, plugins load alphabetically by filename. Control order:

```typescript
// Method 1: Prefix filenames
// plugins/
//   00-config.ts     ← loads first
//   01-database.ts
//   02-cache.ts

// Method 2: Separate autoload calls (sequential)
app.register(autoLoad, { dir: join(__dirname, 'plugins/core') });    // first
app.register(autoLoad, { dir: join(__dirname, 'plugins/services') }); // second
app.register(autoLoad, { dir: join(__dirname, 'routes') });           // last
```

### Symptom: `FST_ERR_PLUGIN_TIMEOUT`

```
Plugin did not start in time: <plugin-name>. You may have forgotten to call 'done'
```

**Cause:** Plugin took longer than `pluginTimeout` (default: 10s) or forgot `async`/`done`.

```typescript
// ❌ Missing async — Fastify waits for done() that never comes
export default fp(function dbPlugin(fastify, opts, done) {
  connectToDb().then(db => {
    fastify.decorate('db', db);
    // forgot done()!
  });
});

// ✅ Use async — no done() needed
export default fp(async function dbPlugin(fastify, opts) {
  const db = await connectToDb();
  fastify.decorate('db', db);
});

// ✅ Or increase timeout for slow startups
const app = Fastify({ pluginTimeout: 30_000 }); // 30s
```

---

## Decorator Scope Issues

### Symptom: Decorator Not Found in Sibling Plugin

```typescript
// Plugin A (encapsulated — no fp())
app.register(async (fastify) => {
  fastify.decorate('serviceA', new ServiceA());
});

// Plugin B — CANNOT see serviceA
app.register(async (fastify) => {
  console.log(fastify.serviceA); // undefined!
});
```

**Fix:** Wrap with `fastify-plugin` to break encapsulation:

```typescript
import fp from 'fastify-plugin';
export default fp(async (fastify) => {
  fastify.decorate('serviceA', new ServiceA());
}, { name: 'service-a' });
```

### Symptom: Request Decorator Has Stale Value

```typescript
// ❌ Wrong: reference type shared across requests
fastify.decorateRequest('data', { items: [] }); // same object reused!

// ✅ Correct: use null + set in hook per-request
fastify.decorateRequest('data', null);
fastify.addHook('onRequest', async (req) => {
  req.data = { items: [] }; // fresh object per request
});
```

### Symptom: V8 Deoptimization Warning

```typescript
// ❌ Never assign properties directly — breaks V8 hidden classes
fastify.addHook('onRequest', async (req) => {
  req.customProp = 'value'; // deoptimization!
});

// ✅ Always declare with decorateRequest first
fastify.decorateRequest('customProp', null);
fastify.addHook('onRequest', async (req) => {
  req.customProp = 'value'; // ok — shape declared
});
```

---

## Schema Compilation Failures

### Symptom: `FST_ERR_SCH_ALREADY_PRESENT`

```
Schema with id 'UserSchema' already present!
```

**Fix:** Each `$id` must be globally unique. Use namespaced IDs:

```typescript
// ❌ Duplicate $id across files
const schema1 = { $id: 'User', type: 'object', ... };
const schema2 = { $id: 'User', type: 'object', ... }; // collision!

// ✅ Namespace your schema IDs
const schema1 = { $id: 'urn:app:models:User', type: 'object', ... };
```

### Symptom: `FST_ERR_SCH_VALIDATION_BUILD`

**Cause:** Invalid JSON Schema syntax.

```typescript
// ❌ Common mistakes
{ type: 'object', required: 'name' }        // required must be array
{ type: 'object', properties: { age: { type: 'int' } } } // 'int' invalid, use 'integer'
{ type: 'string', pattern: '[' }            // invalid regex

// ✅ Correct
{ type: 'object', required: ['name'], properties: { age: { type: 'integer' } } }
```

### Symptom: `$ref` Not Resolving

```typescript
// Must add shared schemas BEFORE routes that reference them
app.addSchema({
  $id: 'UserModel',
  type: 'object',
  properties: { id: { type: 'string' }, name: { type: 'string' } },
});

// Now reference works
app.get('/users/:id', {
  schema: { response: { 200: { $ref: 'UserModel#' } } },
}, handler);
```

### Symptom: Zod Schema Errors with `fastify-type-provider-zod`

```typescript
// ❌ Forgot to set validator/serializer compilers
const app = Fastify();
app.withTypeProvider<ZodTypeProvider>().get('/items', {
  schema: { querystring: z.object({ q: z.string() }) },
}, handler);
// Error: schema validation failed (Ajv tries to compile Zod schema)

// ✅ Set compilers first
app.setValidatorCompiler(validatorCompiler);
app.setSerializerCompiler(serializerCompiler);
```

---

## Performance Issues

### Slow Response Times

1. **Missing response schemas** — without them, Fastify uses `JSON.stringify` instead of `fast-json-stringify`:
   ```typescript
   // ❌ No schema: ~2x slower serialization
   fastify.get('/users', async () => getUsers());

   // ✅ With schema: fast-json-stringify kicks in
   fastify.get('/users', {
     schema: { response: { 200: { type: 'array', items: { ... } } } },
   }, async () => getUsers());
   ```

2. **Heavy work in hooks** — move CPU-intensive work to workers:
   ```typescript
   import { Worker } from 'node:worker_threads';
   // Offload heavy computation to worker thread
   ```

3. **Logger overhead** — don't use `pino-pretty` in production:
   ```typescript
   // ✅ Production: JSON output (fast, pipe to pino-pretty externally)
   const app = Fastify({ logger: { level: 'info' } });
   // Run: node server.js | pino-pretty  (development only)
   ```

### Benchmark Your Routes

```bash
# Install autocannon for HTTP benchmarking
npx autocannon -c 100 -d 10 http://localhost:3000/api/users
```

### Connection Pool Exhaustion

```typescript
// Symptom: requests hang, then timeout
// Fix: tune pool size and monitor
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,           // match expected concurrency
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

// Monitor pool health
fastify.get('/health', async () => ({
  db: {
    total: pool.totalCount,
    idle: pool.idleCount,
    waiting: pool.waitingCount,
  },
}));
```

---

## Memory Leaks

### Common Causes

1. **Unbounded caches:**
   ```typescript
   // ❌ Grows forever
   const cache = new Map();
   fastify.addHook('onRequest', async (req) => {
     cache.set(req.id, { ts: Date.now(), data: req.body });
   });

   // ✅ Use LRU cache with max size
   import { LRUCache } from 'lru-cache';
   const cache = new LRUCache({ max: 1000, ttl: 1000 * 60 * 5 });
   ```

2. **Event listener accumulation:**
   ```typescript
   // ❌ Adding listeners per request — leaks!
   fastify.addHook('onRequest', async (req) => {
     process.on('someEvent', handler); // never removed!
   });

   // ✅ Add listeners once, or remove in onResponse
   fastify.addHook('onResponse', async (req) => {
     process.removeListener('someEvent', req.eventHandler);
   });
   ```

3. **Unclosed streams:**
   ```typescript
   // ❌ Stream not destroyed on client disconnect
   fastify.get('/stream', async (req, reply) => {
     const stream = createReadStream(file);
     reply.send(stream);
   });

   // ✅ Handle abort
   fastify.get('/stream', async (req, reply) => {
     const stream = createReadStream(file);
     req.raw.on('close', () => stream.destroy());
     reply.send(stream);
   });
   ```

### Diagnosing Memory Leaks

```bash
# Start with --inspect flag
node --inspect dist/server.js

# Take heap snapshots via Chrome DevTools (chrome://inspect)
# Or use clinic.js:
npx clinic doctor -- node dist/server.js
npx clinic heapprofiler -- node dist/server.js
```

---

## TypeScript Type Inference Problems

### Symptom: `Property 'X' does not exist on type 'FastifyInstance'`

**Fix:** Use declaration merging in a `.d.ts` file:

```typescript
// src/types/fastify.d.ts
import 'fastify';
declare module 'fastify' {
  interface FastifyInstance {
    config: { jwtSecret: string; dbUrl: string };
    db: import('pg').Pool;
    authenticate: (req: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
  interface FastifyRequest {
    user: { id: string; role: string } | null;
  }
}
```

Ensure this file is included in `tsconfig.json`:

```json
{
  "compilerOptions": { ... },
  "include": ["src/**/*.ts", "src/types/**/*.d.ts"]
}
```

### Symptom: Route Handler Types Not Inferred

```typescript
// ❌ Generic params not flowing
fastify.get('/:id', async (req) => {
  req.params.id; // error: Property 'id' does not exist
});

// ✅ Specify generics
fastify.get<{ Params: { id: string }; Querystring: { page: number } }>(
  '/:id',
  async (req) => {
    req.params.id;    // string ✓
    req.query.page;   // number ✓
  },
);

// ✅ Or use type providers for automatic inference
app.withTypeProvider<ZodTypeProvider>().get('/:id', {
  schema: {
    params: z.object({ id: z.string().uuid() }),
  },
}, async (req) => {
  req.params.id; // string ✓ (inferred from Zod)
});
```

### Symptom: Plugin Options Not Typed

```typescript
// ✅ Define options interface and pass to fp()
interface MyPluginOpts {
  connectionString: string;
  maxRetries?: number;
}

export default fp<MyPluginOpts>(async (fastify, opts) => {
  opts.connectionString; // typed ✓
  opts.maxRetries;       // number | undefined ✓
}, { name: 'my-plugin' });
```

---

## Migration from Express

### Key Differences

| Express | Fastify |
|---------|---------|
| `app.use(middleware)` | `app.register(plugin)` or `app.addHook()` |
| `req.body` (needs body-parser) | `req.body` (built-in parsing) |
| `res.locals` | `decorateRequest()` + hooks |
| `res.json()` | `reply.send()` (auto-detects JSON) |
| `next()` to pass control | Return from async hook / don't call `reply.send()` |
| `app.use('/path', router)` | `app.register(plugin, { prefix: '/path' })` |
| Error middleware `(err, req, res, next)` | `app.setErrorHandler()` |
| `express.static()` | `@fastify/static` |
| `express-session` | `@fastify/session` + `@fastify/cookie` |

### Migrating Middleware

```typescript
// Express middleware
app.use((req, res, next) => {
  req.startTime = Date.now();
  next();
});

// Fastify equivalent
fastify.decorateRequest('startTime', 0);
fastify.addHook('onRequest', async (req) => {
  req.startTime = Date.now();
});
```

### Using Express Middleware in Fastify (Temporary Bridge)

```typescript
import expressPlugin from '@fastify/express';

await app.register(expressPlugin);
// Now you can use Express middleware during migration
app.use(helmet());
app.use(cors());
// Gradually replace with native Fastify plugins
```

### Common Migration Mistakes

1. **Calling `reply.send()` twice** — Express allows multiple `res.write()` but Fastify errors on double `reply.send()`
2. **Using `req.query` without schema** — works but no validation; add schemas for safety
3. **Forgetting `await` on async reply** — Express ignores but Fastify may send premature response
4. **Middleware ordering** — Express is linear; Fastify uses encapsulated contexts

---

## Production Debugging

### Structured Logging

```typescript
// Always use request.log (includes reqId automatically)
fastify.addHook('onRequest', async (req) => {
  req.log.info({ headers: req.headers }, 'incoming request');
});

// Custom request ID from header (distributed tracing)
const app = Fastify({
  requestIdHeader: 'x-request-id',
  genReqId: (req) => req.headers['x-request-id'] as string || crypto.randomUUID(),
  requestIdLogLabel: 'traceId',
});
```

### Error Tracking

```typescript
fastify.setErrorHandler((error, request, reply) => {
  // Structured error logging with context
  request.log.error({
    err: error,
    url: request.url,
    method: request.method,
    params: request.params,
    query: request.query,
    userId: request.user?.id,
  }, 'request error');

  if (error.validation) {
    return reply.code(400).send({
      error: 'Validation Error',
      details: error.validation,
    });
  }

  const statusCode = error.statusCode ?? 500;
  reply.code(statusCode).send({
    error: statusCode >= 500 ? 'Internal Server Error' : error.message,
    traceId: request.id,
  });
});
```

### Diagnostic Endpoints

```typescript
fastify.get('/debug/routes', async () => {
  return fastify.printRoutes({ commonPrefix: false });
});

fastify.get('/debug/plugins', async () => {
  return fastify.printPlugins();
});

// Memory usage endpoint
fastify.get('/debug/memory', async () => {
  const mem = process.memoryUsage();
  return {
    rss: `${(mem.rss / 1024 / 1024).toFixed(1)} MB`,
    heapUsed: `${(mem.heapUsed / 1024 / 1024).toFixed(1)} MB`,
    heapTotal: `${(mem.heapTotal / 1024 / 1024).toFixed(1)} MB`,
    external: `${(mem.external / 1024 / 1024).toFixed(1)} MB`,
  };
});
```

### Node.js Diagnostic Flags

```bash
# Enable inspector for remote debugging
node --inspect=0.0.0.0:9229 dist/server.js

# Trace warnings with stack traces
node --trace-warnings dist/server.js

# Dump heap on OOM
node --max-old-space-size=512 --heapsnapshot-signal=SIGUSR2 dist/server.js

# Diagnostic report on crash
node --report-on-fatalerror --report-directory=/tmp/reports dist/server.js
```

---

## Common Error Messages

| Error Code | Message | Cause | Fix |
|-----------|---------|-------|-----|
| `FST_ERR_DEC_ALREADY_PRESENT` | Decorator already present | Duplicate `decorate()` call | Check plugin isn't registered twice |
| `FST_ERR_DEC_MISSING_DEPENDENCY` | Missing dependency | Decorator not available in scope | Use `fp()` or fix registration order |
| `FST_ERR_HOOK_INVALID_TYPE` | Invalid hook type | Typo in hook name | Check hook name spelling |
| `FST_ERR_PLUGIN_TIMEOUT` | Plugin didn't start in time | Slow init or missing `done()`/`async` | Add `async` or increase `pluginTimeout` |
| `FST_ERR_SCH_ALREADY_PRESENT` | Schema already present | Duplicate `$id` | Use unique schema IDs |
| `FST_ERR_CTP_ALREADY_PRESENT` | Content type parser exists | Duplicate parser registration | Remove before re-adding |
| `FST_ERR_REP_ALREADY_SENT` | Reply already sent | Called `reply.send()` twice | Return after first send |
| `FST_ERR_SEND_INSIDE_ONERR` | Send inside onError | Tried to send in onError hook | Use setErrorHandler instead |
| `FST_ERR_BAD_URL` | Bad URL | Malformed URL in request | Check client URL encoding |
| `FST_ERR_ROUTE_REWRITE_NOT_STR` | Rewrite not string | `rewriteUrl` returned non-string | Return string from rewriteUrl |
