# Hono Framework on Cloudflare Workers

## Table of Contents

- [Setup and Project Structure](#setup-and-project-structure)
- [Typed Bindings](#typed-bindings)
- [Routing](#routing)
- [Middleware](#middleware)
- [Validation with Zod](#validation-with-zod)
- [OpenAPI Generation](#openapi-generation)
- [RPC Mode (Type-Safe Client)](#rpc-mode-type-safe-client)
- [JWT Auth Middleware](#jwt-auth-middleware)
- [Rate Limiting](#rate-limiting)
- [Error Handling](#error-handling)
- [Testing with app.request()](#testing-with-apprequest)
- [Monorepo Patterns](#monorepo-patterns)

---

## Setup and Project Structure

```bash
npm create hono@latest my-worker -- --template cloudflare-workers
cd my-worker
npm install
```

Recommended structure:
```
src/
├── index.ts          # App entry, exports default app
├── routes/
│   ├── users.ts      # User routes
│   ├── posts.ts      # Post routes
│   └── admin.ts      # Admin routes
├── middleware/
│   ├── auth.ts       # JWT/bearer auth
│   ├── rateLimit.ts  # Rate limiting
│   └── logger.ts     # Request logging
├── services/
│   ├── userService.ts
│   └── postService.ts
├── types.ts          # Env bindings, shared types
└── lib/
    ├── errors.ts     # Custom error classes
    └── validation.ts # Shared Zod schemas
```

---

## Typed Bindings

Define your Cloudflare bindings type once, use everywhere:

```ts
// src/types.ts
type Bindings = {
  DB: D1Database;
  CACHE: KVNamespace;
  BUCKET: R2Bucket;
  RATE_LIMITER: DurableObjectNamespace;
  AUTH_SERVICE: Fetcher;
  AI: Ai;
  JWT_SECRET: string;
  ENVIRONMENT: string;
};

// Variables set by middleware (e.g., auth)
type Variables = {
  userId: string;
  userRole: "admin" | "user";
  requestId: string;
};

// Re-export for use in routes
export type AppEnv = { Bindings: Bindings; Variables: Variables };
```

```ts
// src/index.ts
import { Hono } from "hono";
import type { AppEnv } from "./types";
import { userRoutes } from "./routes/users";
import { postRoutes } from "./routes/posts";

const app = new Hono<AppEnv>();

// Mount routes
app.route("/api/users", userRoutes);
app.route("/api/posts", postRoutes);

export default app;
```

```ts
// src/routes/users.ts — bindings are fully typed
import { Hono } from "hono";
import type { AppEnv } from "../types";

export const userRoutes = new Hono<AppEnv>();

userRoutes.get("/:id", async (c) => {
  // c.env.DB is typed as D1Database
  const user = await c.env.DB.prepare("SELECT * FROM users WHERE id = ?")
    .bind(c.req.param("id"))
    .first();
  return user ? c.json(user) : c.json({ error: "Not found" }, 404);
});
```

---

## Routing

```ts
import { Hono } from "hono";

const app = new Hono<AppEnv>();

// Basic routes
app.get("/", (c) => c.text("Hello"));
app.post("/items", async (c) => { /* ... */ });
app.put("/items/:id", async (c) => { /* ... */ });
app.delete("/items/:id", async (c) => { /* ... */ });

// Path parameters
app.get("/users/:userId/posts/:postId", (c) => {
  const { userId, postId } = c.req.param();
  return c.json({ userId, postId });
});

// Wildcards
app.get("/files/*", (c) => {
  const path = c.req.path.replace("/files/", "");
  return c.text(`File: ${path}`);
});

// Optional parameters
app.get("/api/:version?/users", (c) => {
  const version = c.req.param("version") ?? "v1";
  return c.text(`API ${version}`);
});

// Query parameters
app.get("/search", (c) => {
  const q = c.req.query("q");
  const page = parseInt(c.req.query("page") ?? "1");
  const tags = c.req.queries("tag"); // ?tag=a&tag=b → ["a", "b"]
  return c.json({ q, page, tags });
});

// Route groups with shared middleware
const admin = new Hono<AppEnv>();
admin.use("/*", adminAuthMiddleware);
admin.get("/stats", (c) => { /* ... */ });
admin.post("/users/ban/:id", (c) => { /* ... */ });
app.route("/admin", admin);

// Method chaining
app
  .get("/health", (c) => c.json({ status: "ok" }))
  .get("/version", (c) => c.json({ version: "1.0.0" }));
```

---

## Middleware

```ts
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { secureHeaders } from "hono/secure-headers";
import { timing, startTime, endTime } from "hono/timing";
import { prettyJSON } from "hono/pretty-json";
import { compress } from "hono/compress";

const app = new Hono<AppEnv>();

// Built-in middleware
app.use("*", logger());                  // Request logging
app.use("*", secureHeaders());           // Security headers
app.use("*", timing());                  // Server-Timing header
app.use("*", prettyJSON());              // ?pretty for formatted JSON
app.use("*", compress());                // gzip/brotli compression

// CORS — configure per-route or globally
app.use("/api/*", cors({
  origin: ["https://app.example.com", "https://staging.example.com"],
  allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization"],
  credentials: true,
  maxAge: 86400,
}));

// Custom middleware: request ID
app.use("*", async (c, next) => {
  const requestId = c.req.header("X-Request-Id") ?? crypto.randomUUID();
  c.set("requestId", requestId);
  c.header("X-Request-Id", requestId);
  await next();
});

// Custom middleware: timing
app.use("*", async (c, next) => {
  startTime(c, "db");
  await next();
  endTime(c, "db");
});

// Middleware on specific routes
app.use("/api/admin/*", async (c, next) => {
  const role = c.get("userRole");
  if (role !== "admin") return c.json({ error: "Forbidden" }, 403);
  await next();
});

// Conditional middleware
app.use("*", async (c, next) => {
  if (c.env.ENVIRONMENT === "production") {
    // Only in production
    await rateLimitMiddleware(c, next);
  } else {
    await next();
  }
});
```

---

## Validation with Zod

```ts
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";

const app = new Hono<AppEnv>();

// Request body validation
const CreateUserSchema = z.object({
  name: z.string().min(1).max(100),
  email: z.string().email(),
  role: z.enum(["admin", "user"]).default("user"),
  metadata: z.record(z.string()).optional(),
});

app.post("/users",
  zValidator("json", CreateUserSchema),
  async (c) => {
    const data = c.req.valid("json"); // Fully typed: { name: string, email: string, role: "admin"|"user", ... }
    const result = await c.env.DB.prepare(
      "INSERT INTO users (name, email, role) VALUES (?, ?, ?) RETURNING *"
    ).bind(data.name, data.email, data.role).first();
    return c.json(result, 201);
  }
);

// Query parameter validation
const ListQuerySchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  sort: z.enum(["name", "created_at", "email"]).default("created_at"),
  order: z.enum(["asc", "desc"]).default("desc"),
  search: z.string().optional(),
});

app.get("/users",
  zValidator("query", ListQuerySchema),
  async (c) => {
    const { page, limit, sort, order, search } = c.req.valid("query");
    const offset = (page - 1) * limit;
    // Build query...
    return c.json({ results: [], page, limit });
  }
);

// Path parameter validation
const UserIdSchema = z.object({
  id: z.string().uuid(),
});

app.get("/users/:id",
  zValidator("param", UserIdSchema),
  async (c) => {
    const { id } = c.req.valid("param");
    return c.json({ id });
  }
);

// Header validation
const AuthHeaderSchema = z.object({
  authorization: z.string().startsWith("Bearer "),
});

app.use("/api/*", zValidator("header", AuthHeaderSchema));

// Custom validation error handler
app.post("/strict",
  zValidator("json", CreateUserSchema, (result, c) => {
    if (!result.success) {
      return c.json({
        error: "Validation failed",
        details: result.error.issues.map(i => ({
          path: i.path.join("."),
          message: i.message,
        })),
      }, 422);
    }
  }),
  async (c) => {
    const data = c.req.valid("json");
    return c.json(data);
  }
);
```

---

## OpenAPI Generation

Use `@hono/zod-openapi` for automatic OpenAPI spec generation:

```ts
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";

const app = new OpenAPIHono<AppEnv>();

// Define schemas
const UserSchema = z.object({
  id: z.string().uuid().openapi({ example: "123e4567-e89b-12d3-a456-426614174000" }),
  name: z.string().openapi({ example: "Alice" }),
  email: z.string().email().openapi({ example: "alice@example.com" }),
  createdAt: z.string().datetime(),
}).openapi("User");

const CreateUserSchema = z.object({
  name: z.string().min(1).max(100),
  email: z.string().email(),
}).openapi("CreateUser");

const ErrorSchema = z.object({
  error: z.string(),
  details: z.array(z.object({ path: z.string(), message: z.string() })).optional(),
}).openapi("Error");

// Define route with full OpenAPI metadata
const createUserRoute = createRoute({
  method: "post",
  path: "/users",
  tags: ["Users"],
  summary: "Create a new user",
  request: {
    body: { content: { "application/json": { schema: CreateUserSchema } } },
  },
  responses: {
    201: {
      description: "User created",
      content: { "application/json": { schema: UserSchema } },
    },
    422: {
      description: "Validation error",
      content: { "application/json": { schema: ErrorSchema } },
    },
  },
});

app.openapi(createUserRoute, async (c) => {
  const data = c.req.valid("json");
  // ... create user
  return c.json(user, 201);
});

// Serve OpenAPI spec
app.doc("/openapi.json", {
  openapi: "3.1.0",
  info: { title: "My API", version: "1.0.0" },
  servers: [
    { url: "https://api.example.com", description: "Production" },
    { url: "https://staging-api.example.com", description: "Staging" },
  ],
});

// Serve Swagger UI
app.get("/docs", (c) => {
  return c.html(`
    <!DOCTYPE html>
    <html><head><title>API Docs</title>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
    </head><body>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
    <script>SwaggerUIBundle({ url: "/openapi.json", dom_id: "#swagger-ui" })</script>
    </body></html>
  `);
});

export default app;
```

---

## RPC Mode (Type-Safe Client)

Hono RPC enables type-safe API calls from client code — types are inferred from route definitions:

```ts
// src/index.ts (server)
import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";

const app = new Hono<AppEnv>()
  .get("/users", async (c) => {
    const users = await c.env.DB.prepare("SELECT * FROM users").all();
    return c.json({ users: users.results });
  })
  .get("/users/:id", async (c) => {
    const user = await c.env.DB.prepare("SELECT * FROM users WHERE id = ?")
      .bind(c.req.param("id")).first();
    return c.json({ user });
  })
  .post("/users",
    zValidator("json", z.object({ name: z.string(), email: z.string().email() })),
    async (c) => {
      const data = c.req.valid("json");
      const user = await c.env.DB.prepare(
        "INSERT INTO users (name, email) VALUES (?, ?) RETURNING *"
      ).bind(data.name, data.email).first();
      return c.json({ user }, 201);
    }
  )
  .delete("/users/:id", async (c) => {
    await c.env.DB.prepare("DELETE FROM users WHERE id = ?")
      .bind(c.req.param("id")).run();
    return c.json({ success: true });
  });

export type AppType = typeof app;
export default app;
```

```ts
// client.ts (frontend or another Worker)
import { hc } from "hono/client";
import type { AppType } from "../server/src/index";

const client = hc<AppType>("https://api.example.com");

// Fully typed — autocomplete on routes, params, body, response
const listRes = await client.users.$get();
const { users } = await listRes.json(); // users is typed

const getRes = await client.users[":id"].$get({ param: { id: "123" } });
const { user } = await getRes.json();

const createRes = await client.users.$post({
  json: { name: "Alice", email: "alice@example.com" }, // Type-checked body
});
const { user: newUser } = await createRes.json();

const deleteRes = await client.users[":id"].$delete({ param: { id: "123" } });
```

**Key RPC rules:**
- Routes must be chained (not `app.get(...)` separately — use `const app = new Hono().get(...).post(...)`).
- Export `typeof app` for the client to consume.
- Works across Workers via service bindings too.

---

## JWT Auth Middleware

```ts
import { jwt } from "hono/jwt";
import { createMiddleware } from "hono/factory";
import type { AppEnv } from "./types";

// Basic JWT middleware using Hono's built-in
app.use("/api/*", (c, next) => {
  const jwtMiddleware = jwt({ secret: c.env.JWT_SECRET });
  return jwtMiddleware(c, next);
});

// Access payload in routes
app.get("/api/me", (c) => {
  const payload = c.get("jwtPayload");
  return c.json({ userId: payload.sub, role: payload.role });
});

// Custom JWT middleware with role checking
const requireRole = (...roles: string[]) =>
  createMiddleware<AppEnv>(async (c, next) => {
    const payload = c.get("jwtPayload");
    if (!roles.includes(payload.role)) {
      return c.json({ error: "Insufficient permissions" }, 403);
    }
    c.set("userId", payload.sub);
    c.set("userRole", payload.role);
    await next();
  });

app.use("/api/admin/*", requireRole("admin"));
app.use("/api/*", requireRole("admin", "user"));

// Token generation endpoint
import { sign } from "hono/jwt";

app.post("/auth/login", async (c) => {
  const { email, password } = await c.req.json();
  const user = await authenticate(email, password, c.env);
  if (!user) return c.json({ error: "Invalid credentials" }, 401);

  const now = Math.floor(Date.now() / 1000);
  const token = await sign(
    { sub: user.id, role: user.role, iat: now, exp: now + 3600 },
    c.env.JWT_SECRET
  );

  return c.json({ token, expiresIn: 3600 });
});
```

---

## Rate Limiting

```ts
import { createMiddleware } from "hono/factory";
import type { AppEnv } from "./types";

// KV-based rate limiting (simple, eventually consistent)
const rateLimit = (limit: number, windowSeconds: number) =>
  createMiddleware<AppEnv>(async (c, next) => {
    const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
    const key = `rl:${ip}:${Math.floor(Date.now() / (windowSeconds * 1000))}`;

    const current = parseInt(await c.env.CACHE.get(key) ?? "0");
    if (current >= limit) {
      return c.json(
        { error: "Rate limit exceeded" },
        { status: 429, headers: { "Retry-After": String(windowSeconds) } }
      );
    }

    await c.env.CACHE.put(key, String(current + 1), { expirationTtl: windowSeconds });
    c.header("X-RateLimit-Limit", String(limit));
    c.header("X-RateLimit-Remaining", String(limit - current - 1));
    await next();
  });

// Apply: 100 requests per minute
app.use("/api/*", rateLimit(100, 60));

// Stricter for auth endpoints
app.use("/auth/*", rateLimit(10, 60));

// DO-based rate limiting (precise, strongly consistent)
const precisRateLimit = (limit: number, windowMs: number) =>
  createMiddleware<AppEnv>(async (c, next) => {
    const ip = c.req.header("CF-Connecting-IP") ?? "unknown";
    const id = c.env.RATE_LIMITER.idFromName(ip);
    const stub = c.env.RATE_LIMITER.get(id);

    const resp = await stub.fetch(new Request("https://rl/check", {
      method: "POST",
      body: JSON.stringify({ key: c.req.path, limit, windowMs }),
    }));

    const result = await resp.json<{ allowed: boolean; remaining: number }>();
    if (!result.allowed) {
      return c.json({ error: "Rate limit exceeded" }, 429);
    }

    c.header("X-RateLimit-Remaining", String(result.remaining));
    await next();
  });
```

---

## Error Handling

```ts
import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";

const app = new Hono<AppEnv>();

// Global error handler
app.onError((err, c) => {
  const requestId = c.get("requestId") ?? "unknown";

  if (err instanceof HTTPException) {
    return c.json({
      error: err.message,
      status: err.status,
      requestId,
    }, err.status);
  }

  // Zod validation errors
  if (err.name === "ZodError") {
    return c.json({
      error: "Validation failed",
      details: (err as any).issues,
      requestId,
    }, 422);
  }

  // Unexpected errors — log and return 500
  console.error(JSON.stringify({
    error: err.message,
    stack: err.stack,
    requestId,
    path: c.req.path,
  }));

  return c.json({
    error: c.env.ENVIRONMENT === "production"
      ? "Internal server error"
      : err.message,
    requestId,
  }, 500);
});

// 404 handler
app.notFound((c) => {
  return c.json({
    error: "Not found",
    path: c.req.path,
    method: c.req.method,
  }, 404);
});

// Throwing HTTP exceptions in routes
app.get("/users/:id", async (c) => {
  const user = await c.env.DB.prepare("SELECT * FROM users WHERE id = ?")
    .bind(c.req.param("id")).first();

  if (!user) {
    throw new HTTPException(404, { message: "User not found" });
  }

  return c.json(user);
});

// Custom error classes
class AppError extends HTTPException {
  constructor(
    status: number,
    public code: string,
    message: string,
  ) {
    super(status, { message });
  }
}

// Usage
throw new AppError(409, "DUPLICATE_EMAIL", "Email already exists");
```

---

## Testing with app.request()

```ts
import { describe, it, expect, beforeAll } from "vitest";
import { env } from "cloudflare:test";
import app from "../src/index";

describe("User API", () => {
  beforeAll(async () => {
    // Seed test data using real D1 binding from vitest-pool-workers
    await env.DB.exec(`
      CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);
      INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');
    `);
  });

  it("GET /api/users returns list", async () => {
    const res = await app.request("/api/users", {}, env);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.users).toHaveLength(1);
    expect(body.users[0].name).toBe("Alice");
  });

  it("POST /api/users creates user", async () => {
    const res = await app.request("/api/users", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: "Bob", email: "bob@example.com" }),
    }, env);
    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body.user.name).toBe("Bob");
  });

  it("POST /api/users validates input", async () => {
    const res = await app.request("/api/users", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: "", email: "not-an-email" }),
    }, env);
    expect(res.status).toBe(422);
  });

  it("GET /api/users/:id returns 404 for missing user", async () => {
    const res = await app.request("/api/users/9999", {}, env);
    expect(res.status).toBe(404);
  });

  it("authenticated endpoint requires JWT", async () => {
    const res = await app.request("/api/me", {}, env);
    expect(res.status).toBe(401);
  });

  it("authenticated endpoint works with valid JWT", async () => {
    const { sign } = await import("hono/jwt");
    const token = await sign(
      { sub: "user-1", role: "admin", exp: Math.floor(Date.now() / 1000) + 3600 },
      env.JWT_SECRET
    );
    const res = await app.request("/api/me", {
      headers: { Authorization: `Bearer ${token}` },
    }, env);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.userId).toBe("user-1");
  });
});
```

---

## Monorepo Patterns

Structure for multiple Workers sharing code:

```
monorepo/
├── packages/
│   ├── shared/              # Shared types, utils, validation
│   │   ├── src/
│   │   │   ├── types.ts     # Shared TypeScript types
│   │   │   ├── schemas.ts   # Shared Zod schemas
│   │   │   └── utils.ts     # Shared utilities
│   │   ├── package.json     # { "name": "@myapp/shared" }
│   │   └── tsconfig.json
│   ├── api-worker/          # Main API Worker
│   │   ├── src/index.ts
│   │   ├── wrangler.toml
│   │   └── package.json     # depends on @myapp/shared
│   ├── auth-worker/         # Auth service Worker
│   │   ├── src/index.ts
│   │   ├── wrangler.toml
│   │   └── package.json
│   └── cron-worker/         # Scheduled tasks Worker
│       ├── src/index.ts
│       ├── wrangler.toml
│       └── package.json
├── package.json             # Workspace root
├── turbo.json               # Turborepo config
└── tsconfig.base.json       # Shared TS config
```

**Root package.json:**
```json
{
  "private": true,
  "workspaces": ["packages/*"],
  "scripts": {
    "dev": "turbo dev",
    "deploy": "turbo deploy",
    "test": "turbo test",
    "typecheck": "turbo typecheck"
  },
  "devDependencies": {
    "turbo": "^2.0.0"
  }
}
```

**turbo.json:**
```json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "dev": { "persistent": true, "cache": false },
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**"] },
    "deploy": { "dependsOn": ["build", "test"] },
    "test": { "dependsOn": ["^build"] },
    "typecheck": { "dependsOn": ["^build"] }
  }
}
```

**Shared package usage:**
```ts
// packages/shared/src/schemas.ts
import { z } from "zod";

export const UserSchema = z.object({
  id: z.string().uuid(),
  name: z.string().min(1).max(100),
  email: z.string().email(),
});
export type User = z.infer<typeof UserSchema>;

// packages/api-worker/src/index.ts
import { UserSchema, type User } from "@myapp/shared";
```

**Service bindings between monorepo Workers:**
```toml
# packages/api-worker/wrangler.toml
[[services]]
binding = "AUTH_SERVICE"
service = "auth-worker"
```

**Type-safe service bindings with Hono RPC:**
```ts
// packages/auth-worker/src/index.ts
export type AuthAppType = typeof app;

// packages/api-worker/src/index.ts
import { hc } from "hono/client";
import type { AuthAppType } from "@myapp/auth-worker";

// Use RPC client via service binding
const authClient = hc<AuthAppType>("https://auth", {
  fetch: c.env.AUTH_SERVICE.fetch.bind(c.env.AUTH_SERVICE),
});
const res = await authClient.verify.$post({ json: { token } });
```
