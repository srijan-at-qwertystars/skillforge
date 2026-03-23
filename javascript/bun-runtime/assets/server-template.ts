/**
 * Production Bun.serve Template
 *
 * Features:
 * - Structured routing with method dispatch
 * - Middleware-style request processing
 * - WebSocket support with typed data
 * - CORS handling
 * - Request logging
 * - Graceful error handling
 * - Health check endpoint
 *
 * Usage:
 *   bun run server-template.ts
 *   bun --watch server-template.ts   # development
 */

// ── Types ───────────────────────────────────────────────────────

interface WsData {
  userId: string;
  connectedAt: number;
}

type Handler = (req: Request) => Response | Promise<Response>;
type RouteMap = Record<string, Record<string, Handler>>;

// ── Configuration ───────────────────────────────────────────────

const PORT = Number(Bun.env.PORT) || 3000;
const HOST = Bun.env.HOST || "0.0.0.0";
const CORS_ORIGIN = Bun.env.CORS_ORIGIN || "*";

// ── Routes ──────────────────────────────────────────────────────

const routes: RouteMap = {
  "/": {
    GET: () => Response.json({ name: "my-api", version: "1.0.0" }),
  },

  "/health": {
    GET: () =>
      Response.json({
        status: "ok",
        uptime: process.uptime(),
        timestamp: new Date().toISOString(),
        memory: {
          rss: `${(process.memoryUsage().rss / 1024 / 1024).toFixed(1)} MB`,
          heap: `${(process.memoryUsage().heapUsed / 1024 / 1024).toFixed(1)} MB`,
        },
      }),
  },

  "/api/echo": {
    POST: async (req) => {
      const body = await req.json();
      return Response.json({ echo: body });
    },
  },
};

// ── Middleware ───────────────────────────────────────────────────

function corsHeaders(): HeadersInit {
  return {
    "Access-Control-Allow-Origin": CORS_ORIGIN,
    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
  };
}

function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(corsHeaders())) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function logRequest(req: Request, status: number, startTime: number): void {
  const duration = (performance.now() - startTime).toFixed(1);
  const method = req.method.padEnd(6);
  const url = new URL(req.url).pathname;
  console.log(`${method} ${url} → ${status} (${duration}ms)`);
}

// ── Server ──────────────────────────────────────────────────────

const server = Bun.serve<WsData>({
  port: PORT,
  hostname: HOST,
  idleTimeout: 30,
  maxRequestBodySize: 10 * 1024 * 1024, // 10 MB

  async fetch(req, server) {
    const startTime = performance.now();
    const url = new URL(req.url);

    try {
      // CORS preflight
      if (req.method === "OPTIONS") {
        const res = new Response(null, { status: 204, headers: corsHeaders() });
        logRequest(req, 204, startTime);
        return res;
      }

      // WebSocket upgrade
      if (url.pathname === "/ws") {
        const userId = url.searchParams.get("userId") || "anonymous";
        const upgraded = server.upgrade(req, {
          data: { userId, connectedAt: Date.now() },
        });
        if (upgraded) return undefined as unknown as Response;
        const res = withCors(new Response("WebSocket upgrade failed", { status: 400 }));
        logRequest(req, 400, startTime);
        return res;
      }

      // Route matching
      const route = routes[url.pathname];
      if (route) {
        const handler = route[req.method];
        if (handler) {
          const res = withCors(await handler(req));
          logRequest(req, res.status, startTime);
          return res;
        }
        const res = withCors(
          new Response("Method Not Allowed", {
            status: 405,
            headers: { Allow: Object.keys(route).join(", ") },
          })
        );
        logRequest(req, 405, startTime);
        return res;
      }

      // 404
      const res = withCors(Response.json({ error: "Not Found" }, { status: 404 }));
      logRequest(req, 404, startTime);
      return res;
    } catch (err) {
      console.error("Request error:", err);
      const res = withCors(
        Response.json({ error: "Internal Server Error" }, { status: 500 })
      );
      logRequest(req, 500, startTime);
      return res;
    }
  },

  // ── WebSocket handlers ──────────────────────────────────────

  websocket: {
    open(ws) {
      console.log(`WS connected: ${ws.data.userId}`);
      ws.subscribe("broadcast");
      ws.send(JSON.stringify({ type: "connected", userId: ws.data.userId }));
    },

    message(ws, message) {
      const msg = typeof message === "string" ? message : new TextDecoder().decode(message);
      ws.publish("broadcast", JSON.stringify({
        type: "message",
        from: ws.data.userId,
        data: msg,
        timestamp: Date.now(),
      }));
    },

    close(ws, code, reason) {
      console.log(`WS disconnected: ${ws.data.userId} (${code})`);
      ws.unsubscribe("broadcast");
    },

    perMessageDeflate: true,
    maxPayloadLength: 1024 * 1024, // 1 MB
    idleTimeout: 120,
  },

  // ── Error handler ─────────────────────────────────────────────

  error(err) {
    console.error("Server error:", err);
    return new Response("Internal Server Error", { status: 500 });
  },
});

console.log(`🚀 Server running at http://${HOST}:${PORT}`);
console.log(`   WebSocket at ws://${HOST}:${PORT}/ws`);
console.log(`   Health check: http://${HOST}:${PORT}/health`);
