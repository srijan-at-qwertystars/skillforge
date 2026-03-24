// Hono application template for Cloudflare Workers
// Features: typed bindings, middleware chain, CORS, error handling, CRUD API
//
// Install: npm install hono @hono/zod-validator zod

import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { secureHeaders } from "hono/secure-headers";
import { timing } from "hono/timing";
import { prettyJSON } from "hono/pretty-json";
import { HTTPException } from "hono/http-exception";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";

// --- Binding types ---
type Bindings = {
  DB: D1Database;
  KV: KVNamespace;
  BUCKET: R2Bucket;
  AI: Ai;
  JWT_SECRET: string;
  ENVIRONMENT: string;
};

type Variables = {
  requestId: string;
  userId: string;
};

type AppEnv = { Bindings: Bindings; Variables: Variables };

// --- App ---
const app = new Hono<AppEnv>();

// --- Global middleware ---
app.use("*", logger());
app.use("*", secureHeaders());
app.use("*", timing());
app.use("*", prettyJSON());

app.use("*", cors({
  origin: (origin) => {
    const allowed = ["https://app.example.com", "https://staging.example.com"];
    return allowed.includes(origin) ? origin : "";
  },
  allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization"],
  credentials: true,
  maxAge: 86400,
}));

// Request ID middleware
app.use("*", async (c, next) => {
  c.set("requestId", c.req.header("X-Request-Id") ?? crypto.randomUUID());
  c.header("X-Request-Id", c.get("requestId"));
  await next();
});

// --- Error handling ---
app.onError((err, c) => {
  const requestId = c.get("requestId");

  if (err instanceof HTTPException) {
    return c.json({ error: err.message, requestId }, err.status);
  }

  console.error(JSON.stringify({
    level: "error",
    msg: err.message,
    stack: err.stack,
    requestId,
    path: c.req.path,
  }));

  return c.json({
    error: c.env.ENVIRONMENT === "production" ? "Internal server error" : err.message,
    requestId,
  }, 500);
});

app.notFound((c) =>
  c.json({ error: "Not found", path: c.req.path }, 404)
);

// --- Health check ---
app.get("/health", (c) =>
  c.json({ status: "healthy", environment: c.env.ENVIRONMENT, timestamp: new Date().toISOString() })
);

// --- Schemas ---
const CreateItemSchema = z.object({
  name: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  tags: z.array(z.string()).max(10).default([]),
});

const UpdateItemSchema = CreateItemSchema.partial();

const ListQuerySchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
  search: z.string().optional(),
});

const IdParamSchema = z.object({
  id: z.coerce.number().int().positive(),
});

// --- CRUD Routes ---
const api = new Hono<AppEnv>();

// List items
api.get("/items",
  zValidator("query", ListQuerySchema),
  async (c) => {
    const { page, limit, search } = c.req.valid("query");
    const offset = (page - 1) * limit;

    let query = "SELECT * FROM items";
    const params: (string | number)[] = [];

    if (search) {
      query += " WHERE name LIKE ?";
      params.push(`%${search}%`);
    }

    query += " ORDER BY created_at DESC LIMIT ? OFFSET ?";
    params.push(limit, offset);

    const { results } = await c.env.DB.prepare(query).bind(...params).all();

    // Get total count
    let countQuery = "SELECT COUNT(*) as total FROM items";
    if (search) {
      countQuery += " WHERE name LIKE ?";
    }
    const countResult = await c.env.DB.prepare(countQuery)
      .bind(...(search ? [`%${search}%`] : []))
      .first<{ total: number }>();

    return c.json({
      items: results,
      pagination: {
        page,
        limit,
        total: countResult?.total ?? 0,
        pages: Math.ceil((countResult?.total ?? 0) / limit),
      },
    });
  }
);

// Get item by ID
api.get("/items/:id",
  zValidator("param", IdParamSchema),
  async (c) => {
    const { id } = c.req.valid("param");
    const item = await c.env.DB.prepare("SELECT * FROM items WHERE id = ?")
      .bind(id).first();

    if (!item) throw new HTTPException(404, { message: "Item not found" });
    return c.json({ item });
  }
);

// Create item
api.post("/items",
  zValidator("json", CreateItemSchema),
  async (c) => {
    const data = c.req.valid("json");
    const result = await c.env.DB.prepare(
      "INSERT INTO items (name, description, tags, created_at) VALUES (?, ?, ?, datetime('now')) RETURNING *"
    ).bind(data.name, data.description ?? null, JSON.stringify(data.tags)).first();

    return c.json({ item: result }, 201);
  }
);

// Update item
api.put("/items/:id",
  zValidator("param", IdParamSchema),
  zValidator("json", UpdateItemSchema),
  async (c) => {
    const { id } = c.req.valid("param");
    const data = c.req.valid("json");

    const sets: string[] = [];
    const params: (string | number | null)[] = [];

    if (data.name !== undefined) { sets.push("name = ?"); params.push(data.name); }
    if (data.description !== undefined) { sets.push("description = ?"); params.push(data.description); }
    if (data.tags !== undefined) { sets.push("tags = ?"); params.push(JSON.stringify(data.tags)); }

    if (sets.length === 0) throw new HTTPException(400, { message: "No fields to update" });

    sets.push("updated_at = datetime('now')");
    params.push(id);

    const result = await c.env.DB.prepare(
      `UPDATE items SET ${sets.join(", ")} WHERE id = ? RETURNING *`
    ).bind(...params).first();

    if (!result) throw new HTTPException(404, { message: "Item not found" });
    return c.json({ item: result });
  }
);

// Delete item
api.delete("/items/:id",
  zValidator("param", IdParamSchema),
  async (c) => {
    const { id } = c.req.valid("param");
    const result = await c.env.DB.prepare("DELETE FROM items WHERE id = ? RETURNING id")
      .bind(id).first();

    if (!result) throw new HTTPException(404, { message: "Item not found" });
    return c.json({ deleted: true });
  }
);

// Mount API routes
app.route("/api", api);

// Export typed app for Hono RPC client
export type AppType = typeof app;
export default app;
