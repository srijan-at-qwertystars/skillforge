/**
 * Production WebSocket Server — TypeScript
 *
 * Features:
 *   - Room management (join/leave/broadcast)
 *   - Heartbeat with automatic dead connection cleanup
 *   - Authentication middleware (JWT)
 *   - Message validation with typed envelopes
 *   - Rate limiting per connection
 *   - Graceful shutdown on SIGTERM/SIGINT
 *   - Health check HTTP endpoint
 *   - Metrics exposure
 *
 * Dependencies:
 *   npm install ws jsonwebtoken express
 *   npm install -D @types/ws @types/jsonwebtoken @types/express typescript
 *
 * Usage:
 *   JWT_SECRET=your-secret-key npx ts-node ws-server.ts
 */

import http from 'http';
import express from 'express';
import { WebSocketServer, WebSocket, RawData } from 'ws';
import jwt from 'jsonwebtoken';
import { IncomingMessage } from 'http';

// ── Configuration ──────────────────────────────────────

const config = {
  port: parseInt(process.env.PORT || '3000'),
  jwtSecret: process.env.JWT_SECRET || 'change-me-in-production',
  heartbeatIntervalMs: 30_000,
  heartbeatTimeoutMs: 10_000,
  maxPayloadBytes: 1024 * 1024, // 1MB
  maxConnectionsPerIp: 10,
  maxMessagesPerMinute: 120,
  maxConnections: 10_000,
};

// ── Types ──────────────────────────────────────────────

interface UserPayload {
  userId: string;
  name: string;
  roles?: string[];
}

interface AuthenticatedWebSocket extends WebSocket {
  isAlive: boolean;
  user: UserPayload;
  clientId: string;
  rooms: Set<string>;
  ip: string;
  connectedAt: number;
  messageCount: number;
  messageCountResetAt: number;
}

interface WSMessage {
  type: string;
  id?: string;
  payload?: Record<string, unknown>;
}

interface WSResponse {
  type: string;
  id?: string;
  payload?: unknown;
  error?: string;
  timestamp: number;
}

// ── Room Manager ───────────────────────────────────────

class RoomManager {
  private rooms = new Map<string, Set<AuthenticatedWebSocket>>();

  join(ws: AuthenticatedWebSocket, roomId: string): string[] {
    if (!this.rooms.has(roomId)) {
      this.rooms.set(roomId, new Set());
    }
    this.rooms.get(roomId)!.add(ws);
    ws.rooms.add(roomId);
    return this.getMembers(roomId);
  }

  leave(ws: AuthenticatedWebSocket, roomId: string): void {
    this.rooms.get(roomId)?.delete(ws);
    ws.rooms.delete(roomId);
    if (this.rooms.get(roomId)?.size === 0) {
      this.rooms.delete(roomId);
    }
  }

  leaveAll(ws: AuthenticatedWebSocket): void {
    for (const roomId of ws.rooms) {
      this.leave(ws, roomId);
    }
  }

  broadcast(roomId: string, data: WSResponse, exclude?: AuthenticatedWebSocket): void {
    const msg = JSON.stringify(data);
    this.rooms.get(roomId)?.forEach((client) => {
      if (client !== exclude && client.readyState === WebSocket.OPEN) {
        client.send(msg);
      }
    });
  }

  getMembers(roomId: string): string[] {
    const members: string[] = [];
    this.rooms.get(roomId)?.forEach((ws) => {
      members.push(ws.user.userId);
    });
    return members;
  }

  getRoomCount(): number {
    return this.rooms.size;
  }

  getRoomSizes(): Record<string, number> {
    const sizes: Record<string, number> = {};
    this.rooms.forEach((members, roomId) => {
      sizes[roomId] = members.size;
    });
    return sizes;
  }
}

// ── Rate Limiter ───────────────────────────────────────

function checkRateLimit(ws: AuthenticatedWebSocket): boolean {
  const now = Date.now();
  if (now - ws.messageCountResetAt > 60_000) {
    ws.messageCount = 0;
    ws.messageCountResetAt = now;
  }
  ws.messageCount++;
  return ws.messageCount <= config.maxMessagesPerMinute;
}

// ── IP Tracking ────────────────────────────────────────

const connectionsPerIp = new Map<string, number>();

function trackIpConnect(ip: string): boolean {
  const count = (connectionsPerIp.get(ip) || 0) + 1;
  connectionsPerIp.set(ip, count);
  return count <= config.maxConnectionsPerIp;
}

function trackIpDisconnect(ip: string): void {
  const count = (connectionsPerIp.get(ip) || 1) - 1;
  if (count <= 0) {
    connectionsPerIp.delete(ip);
  } else {
    connectionsPerIp.set(ip, count);
  }
}

// ── Authentication ─────────────────────────────────────

function authenticateRequest(req: IncomingMessage): UserPayload {
  // Try Authorization header first
  const authHeader = req.headers.authorization;
  if (authHeader?.startsWith('Bearer ')) {
    const token = authHeader.slice(7);
    return jwt.verify(token, config.jwtSecret) as UserPayload;
  }

  // Try Sec-WebSocket-Protocol header (for browsers that can't set headers)
  const protocol = req.headers['sec-websocket-protocol'];
  if (protocol) {
    const parts = protocol.split(', ');
    const tokenPart = parts.find((p) => p.startsWith('auth.'));
    if (tokenPart) {
      const token = tokenPart.slice(5);
      return jwt.verify(token, config.jwtSecret) as UserPayload;
    }
  }

  // Try query parameter (least secure — token may be logged)
  const url = new URL(req.url || '/', `http://${req.headers.host}`);
  const token = url.searchParams.get('token');
  if (token) {
    return jwt.verify(token, config.jwtSecret) as UserPayload;
  }

  throw new Error('No authentication token provided');
}

// ── Message Validation ─────────────────────────────────

const validMessageTypes = new Set([
  'join', 'leave', 'message', 'ping',
  'broadcast', 'direct', 'room:list',
]);

function validateMessage(raw: RawData): WSMessage {
  const str = raw.toString();
  if (str.length > config.maxPayloadBytes) {
    throw new Error('Message too large');
  }

  const msg = JSON.parse(str) as WSMessage;

  if (!msg.type || typeof msg.type !== 'string') {
    throw new Error('Missing or invalid message type');
  }

  if (!validMessageTypes.has(msg.type)) {
    throw new Error(`Unknown message type: ${msg.type}`);
  }

  return msg;
}

// ── Server Setup ───────────────────────────────────────

const app = express();
const server = http.createServer(app);
const roomManager = new RoomManager();

const wss = new WebSocketServer({
  server,
  maxPayload: config.maxPayloadBytes,
  clientTracking: true,
});

// Metrics
const metrics = {
  totalConnections: 0,
  totalMessages: 0,
  totalErrors: 0,
  startTime: Date.now(),
};

// Health check
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    connections: wss.clients.size,
    rooms: roomManager.getRoomCount(),
    uptime: Math.floor((Date.now() - metrics.startTime) / 1000),
  });
});

// Metrics endpoint
app.get('/metrics', (_req, res) => {
  res.json({
    connections: {
      active: wss.clients.size,
      total: metrics.totalConnections,
      maxAllowed: config.maxConnections,
    },
    rooms: roomManager.getRoomSizes(),
    messages: {
      total: metrics.totalMessages,
    },
    errors: metrics.totalErrors,
    uptime: Math.floor((Date.now() - metrics.startTime) / 1000),
    memory: {
      rss: `${Math.round(process.memoryUsage().rss / 1024 / 1024)}MB`,
      heap: `${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`,
    },
  });
});

// ── Connection Handler ─────────────────────────────────

function sendResponse(ws: WebSocket, response: WSResponse): void {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(response));
  }
}

function makeResponse(type: string, payload?: unknown, id?: string): WSResponse {
  return { type, payload: payload ?? undefined, id, timestamp: Date.now() };
}

wss.on('connection', (rawWs: WebSocket, req: IncomingMessage) => {
  const ws = rawWs as AuthenticatedWebSocket;
  const ip = (req.headers['x-forwarded-for'] as string)?.split(',')[0]?.trim()
    || req.socket.remoteAddress || 'unknown';

  // Check max connections
  if (wss.clients.size > config.maxConnections) {
    ws.close(1013, 'Server at capacity');
    return;
  }

  // Check IP rate limit
  if (!trackIpConnect(ip)) {
    ws.close(1008, 'Too many connections from this IP');
    return;
  }

  // Authenticate
  let user: UserPayload;
  try {
    user = authenticateRequest(req);
  } catch (err) {
    ws.close(1008, 'Authentication failed');
    trackIpDisconnect(ip);
    return;
  }

  // Initialize connection state
  ws.isAlive = true;
  ws.user = user;
  ws.clientId = `${user.userId}-${Date.now().toString(36)}`;
  ws.rooms = new Set();
  ws.ip = ip;
  ws.connectedAt = Date.now();
  ws.messageCount = 0;
  ws.messageCountResetAt = Date.now();

  metrics.totalConnections++;

  console.log(`[+] ${ws.clientId} connected from ${ip} (total: ${wss.clients.size})`);

  // Send welcome
  sendResponse(ws, makeResponse('welcome', {
    clientId: ws.clientId,
    userId: user.userId,
    name: user.name,
  }));

  // Heartbeat
  ws.on('pong', () => {
    ws.isAlive = true;
  });

  // Message handler
  ws.on('message', (raw: RawData) => {
    // Rate limit
    if (!checkRateLimit(ws)) {
      sendResponse(ws, makeResponse('error', { message: 'Rate limit exceeded' }));
      return;
    }

    let msg: WSMessage;
    try {
      msg = validateMessage(raw);
    } catch (err) {
      metrics.totalErrors++;
      sendResponse(ws, makeResponse('error', {
        message: err instanceof Error ? err.message : 'Invalid message',
      }));
      return;
    }

    metrics.totalMessages++;

    switch (msg.type) {
      case 'join': {
        const roomId = msg.payload?.room as string;
        if (!roomId || typeof roomId !== 'string') {
          sendResponse(ws, makeResponse('error', { message: 'Room ID required' }, msg.id));
          return;
        }
        const members = roomManager.join(ws, roomId);
        sendResponse(ws, makeResponse('joined', { room: roomId, members }, msg.id));
        roomManager.broadcast(roomId, makeResponse('room:joined', {
          userId: ws.user.userId, room: roomId, members,
        }), ws);
        break;
      }

      case 'leave': {
        const roomId = msg.payload?.room as string;
        if (!roomId) {
          sendResponse(ws, makeResponse('error', { message: 'Room ID required' }, msg.id));
          return;
        }
        roomManager.leave(ws, roomId);
        sendResponse(ws, makeResponse('left', { room: roomId }, msg.id));
        roomManager.broadcast(roomId, makeResponse('room:left', {
          userId: ws.user.userId, room: roomId,
        }));
        break;
      }

      case 'message': {
        const roomId = msg.payload?.room as string;
        const text = msg.payload?.text as string;
        if (!text) {
          sendResponse(ws, makeResponse('error', { message: 'Text required' }, msg.id));
          return;
        }
        const outgoing = makeResponse('message', {
          from: ws.user.userId,
          name: ws.user.name,
          text,
          room: roomId || null,
        });
        if (roomId) {
          roomManager.broadcast(roomId, outgoing, ws);
        } else {
          const broadcastMsg = JSON.stringify(outgoing);
          wss.clients.forEach((client) => {
            if (client !== ws && client.readyState === WebSocket.OPEN) {
              client.send(broadcastMsg);
            }
          });
        }
        sendResponse(ws, makeResponse('message:ack', { id: msg.id }, msg.id));
        break;
      }

      case 'ping':
        sendResponse(ws, makeResponse('pong', { serverTime: Date.now() }, msg.id));
        break;

      case 'room:list':
        sendResponse(ws, makeResponse('room:list', {
          rooms: roomManager.getRoomSizes(),
          myRooms: [...ws.rooms],
        }, msg.id));
        break;

      default:
        sendResponse(ws, makeResponse('error', { message: `Unhandled: ${msg.type}` }, msg.id));
    }
  });

  // Cleanup on disconnect
  ws.on('close', (code: number, reason: Buffer) => {
    console.log(`[-] ${ws.clientId} disconnected (code: ${code})`);
    roomManager.leaveAll(ws);
    trackIpDisconnect(ws.ip);
  });

  ws.on('error', (err: Error) => {
    console.error(`[!] ${ws.clientId} error:`, err.message);
    metrics.totalErrors++;
  });
});

// ── Heartbeat ──────────────────────────────────────────

const heartbeatInterval = setInterval(() => {
  (wss.clients as Set<AuthenticatedWebSocket>).forEach((ws) => {
    if (!ws.isAlive) {
      console.log(`[x] Terminating dead connection: ${ws.clientId}`);
      roomManager.leaveAll(ws);
      trackIpDisconnect(ws.ip);
      ws.terminate();
      return;
    }
    ws.isAlive = false;
    ws.ping();
  });
}, config.heartbeatIntervalMs);

wss.on('close', () => clearInterval(heartbeatInterval));

// ── Graceful Shutdown ──────────────────────────────────

let isShuttingDown = false;

async function gracefulShutdown(signal: string): Promise<void> {
  if (isShuttingDown) return;
  isShuttingDown = true;

  console.log(`\n[${signal}] Starting graceful shutdown...`);
  clearInterval(heartbeatInterval);

  // Notify all clients
  const closePromises: Promise<void>[] = [];
  (wss.clients as Set<AuthenticatedWebSocket>).forEach((ws) => {
    closePromises.push(
      new Promise<void>((resolve) => {
        sendResponse(ws, makeResponse('server:shutdown', {
          message: 'Server is restarting',
          retryAfter: 5000 + Math.random() * 10000,
        }));
        ws.close(1012, 'Service restart');
        ws.on('close', () => resolve());
        setTimeout(resolve, 5000);
      })
    );
  });

  // Wait for graceful close (max 10s)
  await Promise.race([
    Promise.all(closePromises),
    new Promise<void>((resolve) => setTimeout(resolve, 10_000)),
  ]);

  // Force terminate remaining
  wss.clients.forEach((ws) => ws.terminate());

  // Close HTTP server
  server.close(() => {
    console.log('Server stopped.');
    process.exit(0);
  });

  // Force exit if server.close hangs
  setTimeout(() => process.exit(1), 5000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// ── Start ──────────────────────────────────────────────

server.listen(config.port, () => {
  console.log(`🌐 WebSocket server running on port ${config.port}`);
  console.log(`📊 Health: http://localhost:${config.port}/health`);
  console.log(`📈 Metrics: http://localhost:${config.port}/metrics`);
});
