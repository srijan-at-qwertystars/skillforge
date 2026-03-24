/**
 * Bun.serve template — Production-ready HTTP server
 *
 * Features:
 * - WebSocket support with pub/sub
 * - Static file serving
 * - CORS handling
 * - Graceful shutdown
 * - Health check endpoint
 * - Request logging
 * - Error handling
 *
 * Usage:
 *   bun run server.ts
 *   bun --hot run server.ts  (development with hot reload)
 */

// ─── Configuration ──────────────────────────────────────────────

const PORT = Number(Bun.env.PORT) || 3000;
const HOST = Bun.env.HOST || "0.0.0.0";
const CORS_ORIGIN = Bun.env.CORS_ORIGIN || "*";
const PUBLIC_DIR = Bun.env.PUBLIC_DIR || "./public";

// ─── Types ──────────────────────────────────────────────────────

interface WebSocketData {
  userId: string;
  room: string;
  connectedAt: number;
}

// ─── CORS Headers ───────────────────────────────────────────────

const corsHeaders = {
  "Access-Control-Allow-Origin": CORS_ORIGIN,
  "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Request-ID",
  "Access-Control-Max-Age": "86400",
};

function withCors(response: Response): Response {
  for (const [key, value] of Object.entries(corsHeaders)) {
    response.headers.set(key, value);
  }
  return response;
}

// ─── Request Logging ────────────────────────────────────────────

function logRequest(req: Request, status: number, startTime: number) {
  const duration = (performance.now() - startTime).toFixed(1);
  const method = req.method.padEnd(6);
  const url = new URL(req.url).pathname;
  console.log(`${method} ${url} → ${status} (${duration}ms)`);
}

// ─── Route Handler ──────────────────────────────────────────────

async function handleRequest(req: Request, server: any): Promise<Response> {
  const url = new URL(req.url);
  const { pathname } = url;

  // Health check
  if (pathname === "/health") {
    return Response.json({
      status: "ok",
      uptime: process.uptime(),
      timestamp: new Date().toISOString(),
    });
  }

  // WebSocket upgrade
  if (pathname === "/ws") {
    const room = url.searchParams.get("room") ?? "general";
    const userId = url.searchParams.get("userId") ?? crypto.randomUUID();

    const upgraded = server.upgrade<WebSocketData>(req, {
      data: { userId, room, connectedAt: Date.now() },
    });

    if (upgraded) return undefined as any; // Upgrade successful
    return new Response("WebSocket upgrade failed", { status: 400 });
  }

  // API routes
  if (pathname.startsWith("/api/")) {
    return handleApi(req, url);
  }

  // Static file serving
  if (pathname !== "/" && !pathname.startsWith("/api")) {
    const filePath = `${PUBLIC_DIR}${pathname}`;
    const file = Bun.file(filePath);
    if (await file.exists()) {
      return new Response(file);
    }
  }

  // Default: serve index.html
  const indexFile = Bun.file(`${PUBLIC_DIR}/index.html`);
  if (await indexFile.exists()) {
    return new Response(indexFile, {
      headers: { "Content-Type": "text/html" },
    });
  }

  return Response.json({ error: "Not Found" }, { status: 404 });
}

// ─── API Routes ─────────────────────────────────────────────────

async function handleApi(req: Request, url: URL): Promise<Response> {
  const { pathname } = url;

  // GET /api/hello
  if (pathname === "/api/hello" && req.method === "GET") {
    const name = url.searchParams.get("name") ?? "World";
    return Response.json({ message: `Hello, ${name}!` });
  }

  // POST /api/echo
  if (pathname === "/api/echo" && req.method === "POST") {
    const body = await req.json();
    return Response.json({ echo: body, receivedAt: new Date().toISOString() });
  }

  return Response.json({ error: "Not Found" }, { status: 404 });
}

// ─── Server ─────────────────────────────────────────────────────

const server = Bun.serve<WebSocketData>({
  port: PORT,
  hostname: HOST,

  async fetch(req, server) {
    const startTime = performance.now();

    // CORS preflight
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    try {
      const response = await handleRequest(req, server);
      if (!response) return undefined as any; // WebSocket upgrade
      const corsResponse = withCors(response);
      logRequest(req, corsResponse.status, startTime);
      return corsResponse;
    } catch (err) {
      console.error("Request error:", err);
      logRequest(req, 500, startTime);
      return withCors(
        Response.json({ error: "Internal Server Error" }, { status: 500 })
      );
    }
  },

  websocket: {
    open(ws) {
      const { userId, room } = ws.data;
      ws.subscribe(room);
      server.publish(
        room,
        JSON.stringify({ type: "system", text: `${userId} joined`, room })
      );
      console.log(`WS: ${userId} joined room '${room}'`);
    },

    message(ws, message) {
      const { userId, room } = ws.data;
      const payload = JSON.stringify({
        type: "message",
        userId,
        text: String(message),
        timestamp: Date.now(),
      });
      // Broadcast to room (excluding sender)
      ws.publish(room, payload);
      // Echo back to sender
      ws.send(payload);
    },

    close(ws, code, reason) {
      const { userId, room } = ws.data;
      ws.unsubscribe(room);
      server.publish(
        room,
        JSON.stringify({ type: "system", text: `${userId} left`, room })
      );
      console.log(`WS: ${userId} left room '${room}' (${code})`);
    },
  },

  error(err) {
    console.error("Server error:", err);
    return Response.json(
      { error: "Internal Server Error" },
      { status: 500 }
    );
  },
});

// ─── Graceful Shutdown ──────────────────────────────────────────

let isShuttingDown = false;

async function shutdown(signal: string) {
  if (isShuttingDown) return;
  isShuttingDown = true;

  console.log(`\n${signal} received — shutting down gracefully...`);

  // Stop accepting new connections
  server.stop();

  // Add cleanup logic here:
  // - Close database connections
  // - Flush logs / metrics
  // - Finish background jobs

  console.log("Server stopped");
  process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ─── Startup ────────────────────────────────────────────────────

console.log(`🚀 Server running at http://${HOST}:${PORT}`);
console.log(`   WebSocket: ws://${HOST}:${PORT}/ws`);
console.log(`   Health:    http://${HOST}:${PORT}/health`);
console.log(`   Press Ctrl+C to stop\n`);
