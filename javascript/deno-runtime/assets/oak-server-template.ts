// Oak middleware server template for Deno
//
// Usage:
//   deno run --allow-net --allow-read --allow-env oak-server-template.ts
//
// Dependencies (add to deno.json imports):
//   "oak": "jsr:@oak/oak@^17"

import { Application, Context, Next, Router, Status } from "oak";

// ─── Types ──────────────────────────────────────────────────────────────

interface AppState {
  requestId: string;
  startTime: number;
}

// ─── Middleware: Request ID ─────────────────────────────────────────────

async function requestIdMiddleware(ctx: Context<AppState>, next: Next) {
  ctx.state.requestId = crypto.randomUUID();
  ctx.response.headers.set("X-Request-ID", ctx.state.requestId);
  await next();
}

// ─── Middleware: Timing ─────────────────────────────────────────────────

async function timingMiddleware(ctx: Context<AppState>, next: Next) {
  ctx.state.startTime = performance.now();
  await next();
  const ms = (performance.now() - ctx.state.startTime).toFixed(1);
  ctx.response.headers.set("X-Response-Time", `${ms}ms`);
  console.log(
    `[${ctx.state.requestId?.slice(0, 8)}] ${ctx.request.method} ${ctx.request.url.pathname} → ${ctx.response.status} (${ms}ms)`,
  );
}

// ─── Middleware: Error Handler ──────────────────────────────────────────

async function errorHandler(ctx: Context<AppState>, next: Next) {
  try {
    await next();
  } catch (err) {
    const status = err instanceof Error && "status" in err
      ? (err as Error & { status: number }).status
      : 500;
    const message = err instanceof Error ? err.message : "Internal Server Error";

    console.error(`[${ctx.state.requestId?.slice(0, 8)}] Error:`, message);

    ctx.response.status = status;
    ctx.response.body = {
      error: message,
      requestId: ctx.state.requestId,
    };
  }
}

// ─── Middleware: CORS ───────────────────────────────────────────────────

async function corsMiddleware(ctx: Context<AppState>, next: Next) {
  ctx.response.headers.set("Access-Control-Allow-Origin", "*");
  ctx.response.headers.set(
    "Access-Control-Allow-Methods",
    "GET, POST, PUT, DELETE, OPTIONS",
  );
  ctx.response.headers.set(
    "Access-Control-Allow-Headers",
    "Content-Type, Authorization",
  );

  if (ctx.request.method === "OPTIONS") {
    ctx.response.status = 204;
    return;
  }

  await next();
}

// ─── Routes ─────────────────────────────────────────────────────────────

const router = new Router<AppState>();

// Health check
router.get("/api/health", (ctx) => {
  ctx.response.body = {
    status: "ok",
    timestamp: new Date().toISOString(),
    uptime: performance.now(),
  };
});

// CRUD example: Items
interface Item {
  id: string;
  name: string;
  createdAt: string;
}

const items = new Map<string, Item>();

router.get("/api/items", (ctx) => {
  const result = Array.from(items.values());
  ctx.response.body = result;
});

router.get("/api/items/:id", (ctx) => {
  const item = items.get(ctx.params.id!);
  if (!item) {
    ctx.response.status = Status.NotFound;
    ctx.response.body = { error: "Item not found" };
    return;
  }
  ctx.response.body = item;
});

router.post("/api/items", async (ctx) => {
  const body = await ctx.request.body.json();
  const item: Item = {
    id: crypto.randomUUID(),
    name: body.name,
    createdAt: new Date().toISOString(),
  };
  items.set(item.id, item);
  ctx.response.status = Status.Created;
  ctx.response.body = item;
});

router.put("/api/items/:id", async (ctx) => {
  const existing = items.get(ctx.params.id!);
  if (!existing) {
    ctx.response.status = Status.NotFound;
    ctx.response.body = { error: "Item not found" };
    return;
  }
  const body = await ctx.request.body.json();
  const updated = { ...existing, ...body, id: existing.id };
  items.set(updated.id, updated);
  ctx.response.body = updated;
});

router.delete("/api/items/:id", (ctx) => {
  const deleted = items.delete(ctx.params.id!);
  if (!deleted) {
    ctx.response.status = Status.NotFound;
    ctx.response.body = { error: "Item not found" };
    return;
  }
  ctx.response.status = Status.NoContent;
});

// ─── Application Setup ─────────────────────────────────────────────────

const app = new Application<AppState>();

// Register middleware (order matters)
app.use(errorHandler);
app.use(requestIdMiddleware);
app.use(timingMiddleware);
app.use(corsMiddleware);

// Register routes
app.use(router.routes());
app.use(router.allowedMethods());

// 404 fallback
app.use((ctx) => {
  ctx.response.status = Status.NotFound;
  ctx.response.body = { error: "Not Found" };
});

// ─── Start Server ───────────────────────────────────────────────────────

const port = Number(Deno.env.get("PORT") ?? 8000);
console.log(`🦕 Oak server running on http://localhost:${port}`);
await app.listen({ port });
