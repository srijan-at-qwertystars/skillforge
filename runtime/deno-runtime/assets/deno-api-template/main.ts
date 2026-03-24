/**
 * Deno REST API Template — Hono-based
 *
 * Run:   deno task dev
 * Test:  deno task test
 * Build: deno compile --allow-net --allow-env --allow-read --output=server main.ts
 */

import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";

// ── Types ──

interface User {
  id: string;
  name: string;
  email: string;
  createdAt: string;
}

interface CreateUserBody {
  name: string;
  email: string;
}

interface ErrorResponse {
  error: string;
  message: string;
}

// ── In-memory store (replace with DB in production) ──

const users = new Map<string, User>();

// ── App ──

const app = new Hono();

// Middleware
app.use("*", cors());
app.use("*", logger());

// Health check
app.get("/health", (c) => {
  return c.json({
    status: "ok",
    timestamp: new Date().toISOString(),
    uptime: performance.now(),
  });
});

// List users
app.get("/api/users", (c) => {
  const limit = parseInt(c.req.query("limit") ?? "50");
  const offset = parseInt(c.req.query("offset") ?? "0");
  const allUsers = Array.from(users.values());
  return c.json({
    data: allUsers.slice(offset, offset + limit),
    total: allUsers.length,
    limit,
    offset,
  });
});

// Get user by ID
app.get("/api/users/:id", (c) => {
  const user = users.get(c.req.param("id"));
  if (!user) {
    return c.json<ErrorResponse>({ error: "NOT_FOUND", message: "User not found" }, 404);
  }
  return c.json(user);
});

// Create user
app.post("/api/users", async (c) => {
  const body = await c.req.json<CreateUserBody>();

  if (!body.name || !body.email) {
    return c.json<ErrorResponse>(
      { error: "VALIDATION_ERROR", message: "name and email are required" },
      400,
    );
  }

  // Check duplicate email
  for (const u of users.values()) {
    if (u.email === body.email) {
      return c.json<ErrorResponse>(
        { error: "DUPLICATE", message: "Email already in use" },
        409,
      );
    }
  }

  const user: User = {
    id: crypto.randomUUID(),
    name: body.name,
    email: body.email,
    createdAt: new Date().toISOString(),
  };

  users.set(user.id, user);
  return c.json(user, 201);
});

// Delete user
app.delete("/api/users/:id", (c) => {
  const id = c.req.param("id");
  if (!users.has(id)) {
    return c.json<ErrorResponse>({ error: "NOT_FOUND", message: "User not found" }, 404);
  }
  users.delete(id);
  return c.json({ deleted: true });
});

// Global error handler
app.onError((err, c) => {
  console.error(`[ERROR] ${err.message}`);
  return c.json<ErrorResponse>(
    { error: "INTERNAL_ERROR", message: "Internal server error" },
    500,
  );
});

// 404 handler
app.notFound((c) => {
  return c.json<ErrorResponse>(
    { error: "NOT_FOUND", message: `Route not found: ${c.req.method} ${c.req.path}` },
    404,
  );
});

// ── Start server ──

const port = parseInt(Deno.env.get("PORT") ?? "8000");

Deno.serve({ port }, app.fetch);
