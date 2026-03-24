# Fastify API Reference

> Complete API surface for Fastify v5. Covers server instance, request/reply objects, hooks, decorators, plugins, schemas, error handling, content type parsers, and serializers.

## Table of Contents

- [Server Instance](#server-instance)
  - [Constructor Options](#constructor-options)
  - [Server Methods](#server-methods)
  - [Server Properties](#server-properties)
- [Request Object](#request-object)
- [Reply Object](#reply-object)
- [Hooks (Lifecycle)](#hooks-lifecycle)
  - [Request/Reply Hooks](#requestreply-hooks)
  - [Application Hooks](#application-hooks)
- [Decorators](#decorators)
- [Plugins](#plugins)
- [Schema Compilation](#schema-compilation)
- [Error Handling](#error-handling)
- [Not-Found Handler](#not-found-handler)
- [Content Type Parser](#content-type-parser)
- [Serializer](#serializer)

---

## Server Instance

### Constructor Options

```typescript
import Fastify, { FastifyServerOptions } from 'fastify';

const app = Fastify({
  // === Logging ===
  logger: true,                          // boolean | PinoLoggerOptions
  // loggerInstance: customPinoLogger,    // v5: provide pre-built pino instance
  disableRequestLogging: false,          // skip automatic request/response logs
  requestIdHeader: 'x-request-id',       // header to extract request ID from
  requestIdLogLabel: 'reqId',            // label for request ID in logs
  genReqId: (req) => crypto.randomUUID(),// custom request ID generator

  // === Server Behavior ===
  trustProxy: false,                     // boolean | string | string[] | number
  maxParamLength: 100,                   // max URL param length (chars)
  bodyLimit: 1048576,                    // max body size in bytes (1 MB)
  caseSensitive: true,                   // case-sensitive routing
  ignoreTrailingSlash: false,            // /foo and /foo/ are same route
  ignoreDuplicateSlashes: false,         // /foo//bar → /foo/bar
  allowUnsafeRegex: false,              // allow unsafe regex in params
  return503OnClosing: true,              // 503 while server is closing
  forceCloseConnections: false,          // force-close keep-alive on shutdown
  exposeHeadRoutes: true,               // auto-create HEAD for GET routes

  // === Timeouts ===
  connectionTimeout: 0,                 // socket inactivity timeout (ms)
  keepAliveTimeout: 72_000,             // keep-alive timeout (ms, 72s)
  requestTimeout: 0,                    // per-request timeout (ms, 0=none)
  pluginTimeout: 10_000,                // max plugin init time (ms)

  // === Security ===
  onProtoPoisoning: 'error',            // 'error' | 'remove' | 'ignore'
  onConstructorPoisoning: 'error',       // 'error' | 'remove' | 'ignore'

  // === Schema ===
  ajv: {                                // Ajv options for validation
    customOptions: { removeAdditional: false, allErrors: true },
    plugins: [],
  },
  serializerOpts: {},                    // fast-json-stringify options

  // === Advanced ===
  http2: false,                          // enable HTTP/2
  https: undefined,                      // TLS options (key, cert)
  serverFactory: undefined,              // custom server factory
  rewriteUrl: undefined,                 // (req) => string — URL rewriting
  constraints: {},                       // custom route constraint strategies
});
```

### Server Methods

```typescript
// === Routing ===
app.route(options)                       // Full route definition
app.get(url, [opts], handler)            // Shorthand for GET
app.post(url, [opts], handler)           // Shorthand for POST
app.put(url, [opts], handler)            // Shorthand for PUT
app.patch(url, [opts], handler)          // Shorthand for PATCH
app.delete(url, [opts], handler)         // Shorthand for DELETE
app.options(url, [opts], handler)        // Shorthand for OPTIONS
app.head(url, [opts], handler)           // Shorthand for HEAD
app.all(url, [opts], handler)            // All HTTP methods

// === Lifecycle ===
await app.listen({ port, host })         // Start listening
await app.ready()                        // Complete plugin loading
await app.close()                        // Graceful shutdown
await app.inject(opts)                   // In-memory request (testing)

// === Plugins ===
app.register(plugin, opts?)              // Register plugin (creates new scope)
app.after(callback?)                     // Run after current plugin queue

// === Hooks ===
app.addHook(name, hookFn)               // Add lifecycle hook

// === Decorators ===
app.decorate(name, value)               // Decorate server instance
app.decorateRequest(name, value)         // Decorate request prototype
app.decorateReply(name, value)           // Decorate reply prototype
app.hasDecorator(name)                   // Check instance decorator
app.hasRequestDecorator(name)            // Check request decorator
app.hasReplyDecorator(name)              // Check reply decorator

// === Schema ===
app.addSchema(schema)                    // Add shared schema ($id required)
app.getSchemas()                         // Get all shared schemas
app.getSchema(id)                        // Get schema by $id
app.setValidatorCompiler(compiler)       // Custom validator compiler
app.setSerializerCompiler(compiler)      // Custom serializer compiler

// === Error Handling ===
app.setErrorHandler(handler)             // Custom error handler
app.setNotFoundHandler([opts], handler)  // Custom 404 handler

// === Content Parsing ===
app.addContentTypeParser(type, opts, parser)
app.removeContentTypeParser(type)
app.removeAllContentTypeParsers()
app.hasContentTypeParser(type)
app.getDefaultJsonParser(onError, onEnd) // Get built-in JSON parser

// === Utilities ===
app.printRoutes(opts?)                   // Print route tree
app.printPlugins()                       // Print plugin tree
app.initialConfig                        // Read-only initial config
app.withTypeProvider<T>()                // Set type provider (TypeBox, Zod)
```

### Server Properties

```typescript
app.server          // Underlying Node.js http.Server
app.log             // Pino logger instance
app.prefix          // Current plugin prefix ('' for root)
app.pluginName      // Name of current plugin context
app.version         // Fastify version string
app.listeningOrigin // Server origin after listen() (e.g., 'http://127.0.0.1:3000')
app.addresses()     // Array of listening addresses
app.initialConfig   // Frozen copy of constructor options
```

---

## Request Object

```typescript
interface FastifyRequest {
  // === Parsed Input ===
  body: unknown;                    // Parsed request body
  query: unknown;                   // Parsed query string
  params: unknown;                  // URL parameters
  headers: IncomingHttpHeaders;     // Request headers

  // === Request Info ===
  id: string;                       // Request ID (from header or generated)
  url: string;                      // Request URL
  originalUrl: string;              // Original URL (before rewriteUrl)
  method: string;                   // HTTP method
  routeOptions: {                   // Route configuration
    method: string;
    url: string;
    schema: object;
    config: object;
  };

  // === Network ===
  ip: string;                       // Client IP (respects trustProxy)
  ips: string[];                    // All IPs from X-Forwarded-For
  hostname: string;                 // Hostname from Host header
  port: number;                     // Port number
  protocol: 'http' | 'https';      // Protocol (respects trustProxy)
  is404: boolean;                   // True if handled by notFound handler

  // === Internals ===
  raw: IncomingMessage;             // Raw Node.js request
  server: FastifyInstance;          // Scoped Fastify instance
  log: Logger;                      // Per-request Pino logger (includes reqId)
  signal: AbortSignal;              // Aborted when request times out/closes

  // === Validation ===
  validationError?: Error;          // Validation error (if any, in preValidation)

  // === Methods ===
  getValidationFunction(schema): ValidateFunction;
  compileValidationSchema(schema): ValidateFunction;
}
```

---

## Reply Object

```typescript
interface FastifyReply {
  // === Status ===
  code(statusCode: number): this;     // Set HTTP status (chainable)
  status(statusCode: number): this;   // Alias for code()
  statusCode: number;                 // Current status code

  // === Headers ===
  header(key: string, value: string): this;      // Set header
  headers(obj: Record<string, string>): this;    // Set multiple headers
  getHeader(key: string): string | undefined;    // Get header value
  getHeaders(): Record<string, string>;          // Get all headers
  removeHeader(key: string): this;               // Remove header
  hasHeader(key: string): boolean;               // Check header exists

  // === Body ===
  send(payload?: unknown): void;      // Send response (auto-serialized)
  type(contentType: string): this;    // Set Content-Type
  redirect(url: string): void;        // Redirect (302 default)
  redirect(statusCode: number, url: string): void;

  // === Serialization ===
  serialize(payload: unknown): string;           // Serialize using route schema
  serializer(fn: (payload: any) => string): this;// Set custom serializer
  getSerializationFunction(schema): SerializeFn;
  compileSerializationSchema(schema): SerializeFn;

  // === Utilities ===
  callNotFound(): void;               // Trigger 404 handler
  getResponseTime(): number;          // Response time in ms
  elapsedTime: number;                // Alias for response time
  sent: boolean;                      // True if reply already sent
  hijack(): void;                     // Take over raw response

  // === Internals ===
  raw: ServerResponse;                // Raw Node.js response
  server: FastifyInstance;            // Scoped Fastify instance
  log: Logger;                        // Per-request logger
  request: FastifyRequest;            // Associated request
}
```

---

## Hooks (Lifecycle)

### Request/Reply Hooks

Execution order: `onRequest → preParsing → preValidation → preHandler → [handler] → preSerialization → onSend → onResponse`

```typescript
// ── onRequest ──────────────────────────────────────────────
// Runs before body parsing. Use for: auth, timing, tenant resolution.
// Can short-circuit by calling reply.send().
app.addHook('onRequest', async (request: FastifyRequest, reply: FastifyReply) => {
  request.log.info('request received');
});

// ── preParsing ─────────────────────────────────────────────
// Access/transform raw body stream before parsing.
// Must return the (possibly modified) payload stream.
app.addHook('preParsing', async (request, reply, payload: NodeJS.ReadableStream) => {
  // Example: decompress body
  return payload; // or return a transformed stream
});

// ── preValidation ──────────────────────────────────────────
// Runs after parsing, before schema validation.
// Modify request.body here if needed before validation.
app.addHook('preValidation', async (request, reply) => {
  if (typeof request.body === 'object') {
    (request.body as any).sanitized = true;
  }
});

// ── preHandler ─────────────────────────────────────────────
// Runs after validation. Use for: authorization, business guards.
app.addHook('preHandler', async (request, reply) => {
  if (!request.user?.permissions.includes('admin')) {
    reply.code(403).send({ error: 'Forbidden' });
  }
});

// ── preSerialization ───────────────────────────────────────
// Transform the response OBJECT before serialization to string.
// Must return the (possibly modified) payload.
app.addHook('preSerialization', async (request, reply, payload: unknown) => {
  return { ...(payload as object), timestamp: Date.now() };
});

// ── onSend ─────────────────────────────────────────────────
// Modify the serialized STRING/Buffer before sending.
// Can also set final headers here.
app.addHook('onSend', async (request, reply, payload: string) => {
  reply.header('X-Response-Time', `${reply.elapsedTime}ms`);
  return payload;
});

// ── onResponse ─────────────────────────────────────────────
// After response is sent. Cannot modify response.
// Use for: logging, metrics, cleanup.
app.addHook('onResponse', async (request, reply) => {
  request.log.info({ responseTime: reply.elapsedTime }, 'request completed');
});

// ── onError ────────────────────────────────────────────────
// Called when an error is thrown. Observation-only — cannot send response.
// Runs BEFORE setErrorHandler.
app.addHook('onError', async (request, reply, error: Error) => {
  // Track errors in APM
  apm.captureError(error, { request });
});

// ── onTimeout ──────────────────────────────────────────────
// Called when request times out (requires requestTimeout option).
app.addHook('onTimeout', async (request, reply) => {
  request.log.warn('request timed out');
});

// ── onRequestAbort ─────────────────────────────────────────
// Called when client aborts the request.
app.addHook('onRequestAbort', async (request) => {
  request.log.warn('client aborted request');
});
```

### Application Hooks

```typescript
// ── onReady ────────────────────────────────────────────────
// After all plugins loaded, before server starts listening.
app.addHook('onReady', async () => {
  await runMigrations();
  app.log.info('server ready');
});

// ── onListen ───────────────────────────────────────────────
// After server starts listening. Not called with inject().
app.addHook('onListen', async () => {
  app.log.info(`listening on ${app.listeningOrigin}`);
});

// ── preClose ───────────────────────────────────────────────
// Before onClose hooks run. Use for pre-cleanup.
app.addHook('preClose', async () => {
  app.log.info('server shutting down...');
});

// ── onClose ────────────────────────────────────────────────
// During server shutdown. Clean up resources (DB, cache, etc.)
// Runs in LIFO order (last registered → first called).
app.addHook('onClose', async (instance) => {
  await instance.db.end();
});

// ── onRoute ────────────────────────────────────────────────
// Called for each route registration. Use for: route tracking, auto-docs.
app.addHook('onRoute', (routeOptions) => {
  app.log.debug({ method: routeOptions.method, url: routeOptions.url }, 'route registered');
});

// ── onRegister ─────────────────────────────────────────────
// Called for each plugin registration. Receives the new encapsulated context.
app.addHook('onRegister', (instance, opts) => {
  app.log.debug({ plugin: instance.pluginName }, 'plugin registered');
});
```

### Route-Level Hooks

```typescript
app.get('/protected', {
  onRequest: [authenticate, authorize('admin')],  // array of hooks
  preHandler: [rateLimiter],
  preSerialization: [addPagination],
  schema: { ... },
}, handler);
```

---

## Decorators

```typescript
// === Server Instance ===
app.decorate('utility', {
  hash: (s: string) => crypto.createHash('sha256').update(s).digest('hex'),
});
app.hasDecorator('utility');     // true

// === Request (prototype-level, available on all requests) ===
app.decorateRequest('startTime', 0);        // primitive → shared default
app.decorateRequest('user', null);           // null → set per-request in hook

// === Reply ===
app.decorateReply('sendSuccess', function(this: FastifyReply, data: unknown) {
  return this.code(200).send({ ok: true, data });
});
app.decorateReply('sendError', function(this: FastifyReply, code: number, msg: string) {
  return this.code(code).send({ ok: false, error: msg });
});

// === TypeScript Declaration Merging ===
declare module 'fastify' {
  interface FastifyInstance {
    utility: { hash(s: string): string };
  }
  interface FastifyRequest {
    startTime: number;
    user: { id: string; role: string } | null;
  }
  interface FastifyReply {
    sendSuccess(data: unknown): void;
    sendError(code: number, msg: string): void;
  }
}
```

### Decorator Rules

- **Always** use `decorate*()` — never assign directly to prototypes
- Decorators with reference types (objects, arrays) as default values share the **same instance** across requests — use `null` default + set in hook
- Decorator names must be unique per scope — `FST_ERR_DEC_ALREADY_PRESENT` on duplicates
- Request/reply decorators declared with `decorateRequest`/`decorateReply` preserve V8 hidden class optimization

---

## Plugins

```typescript
// === Basic Plugin ===
async function myPlugin(fastify: FastifyInstance, opts: { prefix?: string }) {
  fastify.get('/hello', async () => ({ hello: 'world' }));
}

app.register(myPlugin, { prefix: '/api' });

// === Plugin with fastify-plugin (shared scope) ===
import fp from 'fastify-plugin';

export default fp<{ connectionString: string }>(
  async (fastify, opts) => {
    const pool = new Pool({ connectionString: opts.connectionString });
    fastify.decorate('db', pool);
    fastify.addHook('onClose', () => pool.end());
  },
  {
    name: 'database',              // unique name (required for deps)
    dependencies: ['config'],       // must load after 'config'
    fastify: '5.x',                // semver compatibility
    encapsulate: false,             // v5: explicit (same as using fp)
  },
);

// === Plugin Registration Options ===
app.register(plugin, {
  prefix: '/api/v1',               // route prefix
  logLevel: 'warn',                // override log level for this scope
  // ...any custom opts passed to plugin function
});

// === Plugin Metadata ===
// In v5, use Symbol.for('plugin-meta') or fastify-plugin options
// to declare name, version, dependencies
```

---

## Schema Compilation

```typescript
// === Add Shared Schemas (reusable via $ref) ===
app.addSchema({
  $id: 'User',
  type: 'object',
  properties: {
    id: { type: 'string', format: 'uuid' },
    name: { type: 'string', minLength: 1 },
    email: { type: 'string', format: 'email' },
  },
  required: ['id', 'name', 'email'],
});

app.addSchema({
  $id: 'PaginatedResponse',
  type: 'object',
  properties: {
    data: { type: 'array' },
    total: { type: 'integer' },
    page: { type: 'integer' },
    limit: { type: 'integer' },
  },
});

// === Reference Shared Schemas ===
app.get('/users', {
  schema: {
    response: {
      200: {
        type: 'object',
        properties: {
          data: { type: 'array', items: { $ref: 'User#' } },
          total: { type: 'integer' },
        },
      },
    },
  },
}, handler);

// === Custom Validator Compiler ===
app.setValidatorCompiler(({ schema, method, url, httpPart }) => {
  // httpPart: 'body' | 'querystring' | 'params' | 'headers'
  // Return a validation function
  const validate = ajv.compile(schema);
  return (data: unknown) => {
    const valid = validate(data);
    if (!valid) return { error: new Error(ajv.errorsText(validate.errors)) };
    return { value: data };
  };
});

// === Custom Serializer Compiler ===
app.setSerializerCompiler(({ schema, method, url, httpStatus }) => {
  // Return a serialization function
  return (data: unknown) => JSON.stringify(data);
});

// === Route Schema Sections ===
app.route({
  method: 'POST',
  url: '/items',
  schema: {
    body: { ... },              // Validate request body
    querystring: { ... },       // Validate query parameters
    params: { ... },            // Validate URL parameters
    headers: { ... },           // Validate request headers
    response: {                 // Serialize responses (also strips extra fields)
      200: { ... },
      201: { ... },
      '4xx': { ... },           // Catch-all for 4xx
      '5xx': { ... },           // Catch-all for 5xx
    },
  },
  handler: async (req, reply) => { ... },
});
```

---

## Error Handling

```typescript
// === Global Error Handler ===
app.setErrorHandler((error, request, reply) => {
  // error.validation → schema validation error (array of Ajv errors)
  // error.statusCode → HTTP status code (if set)
  // error.code → Fastify error code (FST_ERR_*)

  request.log.error({ err: error }, 'request error');

  if (error.validation) {
    return reply.code(400).send({
      error: 'Validation Error',
      message: error.message,
      details: error.validation,
    });
  }

  const statusCode = error.statusCode ?? 500;
  reply.code(statusCode).send({
    error: statusCode >= 500 ? 'Internal Server Error' : error.message,
    requestId: request.id,
  });
});

// === Scoped Error Handler (per-plugin) ===
app.register(async (fastify) => {
  fastify.setErrorHandler((error, request, reply) => {
    // Only handles errors from routes in this scope
    reply.code(500).send({ error: 'API Error', detail: error.message });
  });
  fastify.get('/api/data', handler);
});

// === Throwing Errors ===
// Option 1: throw standard Error (becomes 500)
throw new Error('Something broke');

// Option 2: throw with statusCode
const err = new Error('Not found');
(err as any).statusCode = 404;
throw err;

// Option 3: @fastify/sensible httpErrors
throw fastify.httpErrors.notFound('User not found');
throw fastify.httpErrors.forbidden('Access denied');
throw fastify.httpErrors.badRequest('Invalid input');
throw fastify.httpErrors.createError(429, 'Rate limit exceeded');
```

---

## Not-Found Handler

```typescript
// === Basic ===
app.setNotFoundHandler((request, reply) => {
  reply.code(404).send({
    error: 'Not Found',
    message: `Route ${request.method} ${request.url} not found`,
    statusCode: 404,
  });
});

// === With Prehandler and Schema ===
app.setNotFoundHandler({
  preHandler: [authenticate],
  preValidation: [rateLimiter],
}, (request, reply) => {
  reply.code(404).send({ error: 'Not Found' });
});

// === Scoped Not-Found Handler ===
app.register(async (fastify) => {
  fastify.setNotFoundHandler((request, reply) => {
    reply.code(404).send({ error: 'API endpoint not found' });
  });
}, { prefix: '/api' });
```

---

## Content Type Parser

```typescript
// === Add Custom Parser ===
app.addContentTypeParser(
  'application/yaml',
  { parseAs: 'string', bodyLimit: 1024 * 1024 },
  (req, body, done) => {
    try {
      done(null, yaml.parse(body as string));
    } catch (err) {
      done(err as Error, undefined);
    }
  },
);

// === Async Parser ===
app.addContentTypeParser(
  'application/protobuf',
  { parseAs: 'buffer' },
  async (req, body) => {
    return ProtobufMessage.decode(body as Buffer);
  },
);

// === Catch-All Parser ===
app.addContentTypeParser('*', { parseAs: 'buffer' }, async (req, body) => body);

// === Remove and Replace ===
app.removeContentTypeParser('application/json');
app.removeAllContentTypeParsers();
app.addContentTypeParser('application/json', { parseAs: 'string' }, async (req, body) => {
  return JSON.parse(body as string);
});

// === Check Parser Exists ===
app.hasContentTypeParser('application/xml'); // boolean
```

---

## Serializer

### Response Schema Serialization

Fastify uses `fast-json-stringify` when a response schema is provided. This is 2-3x faster than `JSON.stringify` and strips unlisted properties (security benefit).

```typescript
// Automatic fast-json-stringify when response schema present
app.get('/users', {
  schema: {
    response: {
      200: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            id: { type: 'integer' },
            name: { type: 'string' },
            // passwordHash NOT listed → stripped from response
          },
        },
      },
    },
  },
}, async () => db.query('SELECT * FROM users'));

// === Per-Reply Custom Serializer ===
app.get('/custom', async (req, reply) => {
  reply.serializer((payload) => msgpack.encode(payload));
  reply.type('application/msgpack');
  reply.send({ data: 'value' });
});

// === Global Serializer Compiler ===
app.setSerializerCompiler(({ schema, method, url, httpStatus }) => {
  // Return serialization function
  return (data) => JSON.stringify(data);
});
```

### Serialization Options

```typescript
const app = Fastify({
  serializerOpts: {
    rounding: 'ceil',        // Number rounding mode
    ajv: customAjv,          // Custom Ajv instance for $ref resolution
    mode: 'standalone',      // Generate standalone serializer code
  },
});
```
