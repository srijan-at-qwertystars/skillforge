/**
 * Socket.IO Server Template — TypeScript
 *
 * Features:
 *   - Namespaces for feature isolation
 *   - Room management with presence
 *   - Authentication middleware (JWT)
 *   - Redis adapter for horizontal scaling
 *   - Error handling with typed events
 *   - Rate limiting
 *   - Graceful shutdown
 *
 * Dependencies:
 *   npm install socket.io @socket.io/redis-adapter redis jsonwebtoken express
 *   npm install -D @types/jsonwebtoken @types/express typescript
 *
 * Usage:
 *   REDIS_URL=redis://localhost:6379 JWT_SECRET=secret npx ts-node socket-io-server.ts
 */

import http from 'http';
import express from 'express';
import { Server, Socket, Namespace } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient, RedisClientType } from 'redis';
import jwt from 'jsonwebtoken';

// ── Configuration ──────────────────────────────────────

const config = {
  port: parseInt(process.env.PORT || '3000'),
  redisUrl: process.env.REDIS_URL || '', // empty = no Redis (single server)
  jwtSecret: process.env.JWT_SECRET || 'change-me-in-production',
  corsOrigin: process.env.CORS_ORIGIN?.split(',') || ['http://localhost:3000'],
  maxConnectionsPerUser: 5,
  rateLimitPerMinute: 120,
};

// ── Types ──────────────────────────────────────────────

interface UserPayload {
  userId: string;
  name: string;
  roles: string[];
}

interface AuthenticatedSocket extends Socket {
  user: UserPayload;
  rateLimit: { count: number; resetAt: number };
}

// Client → Server events
interface ClientToServerEvents {
  'message:send': (data: { room: string; text: string }, ack: (response: { id: string }) => void) => void;
  'room:join': (data: { room: string }, ack: (response: { members: string[] }) => void) => void;
  'room:leave': (data: { room: string }) => void;
  'typing:start': (data: { room: string }) => void;
  'typing:stop': (data: { room: string }) => void;
  'presence:update': (data: { status: string }) => void;
}

// Server → Client events
interface ServerToClientEvents {
  'message:new': (data: { id: string; from: string; name: string; text: string; room: string; timestamp: number }) => void;
  'room:joined': (data: { userId: string; room: string; members: string[] }) => void;
  'room:left': (data: { userId: string; room: string }) => void;
  'typing:update': (data: { userId: string; room: string; isTyping: boolean }) => void;
  'presence:changed': (data: { userId: string; status: string }) => void;
  'error:custom': (data: { message: string; code: string }) => void;
  'server:shutdown': (data: { message: string; retryAfter: number }) => void;
}

interface InterServerEvents {
  ping: () => void;
}

interface SocketData {
  user: UserPayload;
}

type TypedServer = Server<ClientToServerEvents, ServerToClientEvents, InterServerEvents, SocketData>;
type TypedNamespace = Namespace<ClientToServerEvents, ServerToClientEvents, InterServerEvents, SocketData>;

// ── Application Setup ──────────────────────────────────

const app = express();
const server = http.createServer(app);

const io: TypedServer = new Server(server, {
  cors: {
    origin: config.corsOrigin,
    methods: ['GET', 'POST'],
    credentials: true,
  },
  pingInterval: 25000,
  pingTimeout: 10000,
  maxHttpBufferSize: 1e6, // 1MB
  connectionStateRecovery: {
    maxDisconnectionDuration: 2 * 60 * 1000, // 2 minutes
    skipMiddlewares: true,
  },
});

// ── Redis Adapter ──────────────────────────────────────

let pubClient: RedisClientType | null = null;
let subClient: RedisClientType | null = null;

async function setupRedisAdapter(): Promise<void> {
  if (!config.redisUrl) {
    console.log('⚠️  No REDIS_URL — running in single-server mode');
    return;
  }

  pubClient = createClient({ url: config.redisUrl }) as RedisClientType;
  subClient = pubClient.duplicate() as RedisClientType;

  pubClient.on('error', (err) => console.error('Redis pub error:', err));
  subClient.on('error', (err) => console.error('Redis sub error:', err));

  await Promise.all([pubClient.connect(), subClient.connect()]);
  io.adapter(createAdapter(pubClient, subClient));

  console.log('✅ Redis adapter connected');
}

// ── Authentication Middleware ──────────────────────────

function authMiddleware(socket: Socket, next: (err?: Error) => void): void {
  const token = socket.handshake.auth?.token
    || socket.handshake.headers?.authorization?.replace('Bearer ', '');

  if (!token) {
    next(new Error('Authentication required'));
    return;
  }

  try {
    const user = jwt.verify(token, config.jwtSecret) as UserPayload;
    (socket as AuthenticatedSocket).user = user;
    socket.data.user = user;
    next();
  } catch (err) {
    next(new Error('Invalid or expired token'));
  }
}

// ── Rate Limiting Middleware ───────────────────────────

function rateLimitMiddleware(socket: AuthenticatedSocket): (event: string[], next: (err?: Error) => void) => void {
  socket.rateLimit = { count: 0, resetAt: Date.now() + 60_000 };

  return (_event: string[], next: (err?: Error) => void) => {
    const now = Date.now();
    if (now > socket.rateLimit.resetAt) {
      socket.rateLimit.count = 0;
      socket.rateLimit.resetAt = now + 60_000;
    }
    socket.rateLimit.count++;

    if (socket.rateLimit.count > config.rateLimitPerMinute) {
      socket.emit('error:custom', {
        message: 'Rate limit exceeded',
        code: 'RATE_LIMIT',
      });
      next(new Error('Rate limit exceeded'));
      return;
    }
    next();
  };
}

// ── Helper: Generate Message ID ────────────────────────

let messageCounter = 0;
function generateMessageId(): string {
  return `${Date.now().toString(36)}-${(++messageCounter).toString(36)}`;
}

// ── Chat Namespace ─────────────────────────────────────

const chatNamespace: TypedNamespace = io.of('/chat');

chatNamespace.use(authMiddleware);

chatNamespace.on('connection', (rawSocket) => {
  const socket = rawSocket as unknown as AuthenticatedSocket;
  const { userId, name } = socket.user;

  console.log(`[chat] ${name} (${userId}) connected`);

  // Rate limiting
  socket.use(rateLimitMiddleware(socket));

  // Join room
  socket.on('room:join', async (data, ack) => {
    const { room } = data;
    if (!room || typeof room !== 'string' || room.length > 100) {
      socket.emit('error:custom', { message: 'Invalid room name', code: 'INVALID_ROOM' });
      return;
    }

    await socket.join(room);
    const sockets = await chatNamespace.in(room).fetchSockets();
    const members = [...new Set(sockets.map((s) => s.data.user?.userId).filter(Boolean))] as string[];

    ack({ members });

    socket.to(room).emit('room:joined', { userId, room, members });
    console.log(`[chat] ${name} joined room: ${room}`);
  });

  // Leave room
  socket.on('room:leave', async (data) => {
    const { room } = data;
    await socket.leave(room);
    socket.to(room).emit('room:left', { userId, room });
    console.log(`[chat] ${name} left room: ${room}`);
  });

  // Send message
  socket.on('message:send', (data, ack) => {
    const { room, text } = data;
    if (!text || typeof text !== 'string' || text.length > 5000) {
      socket.emit('error:custom', { message: 'Invalid message', code: 'INVALID_MESSAGE' });
      return;
    }

    const id = generateMessageId();
    const message = {
      id,
      from: userId,
      name,
      text,
      room,
      timestamp: Date.now(),
    };

    chatNamespace.to(room).emit('message:new', message);
    ack({ id });
  });

  // Typing indicators
  socket.on('typing:start', (data) => {
    socket.to(data.room).emit('typing:update', {
      userId,
      room: data.room,
      isTyping: true,
    });
  });

  socket.on('typing:stop', (data) => {
    socket.to(data.room).emit('typing:update', {
      userId,
      room: data.room,
      isTyping: false,
    });
  });

  // Disconnect
  socket.on('disconnect', (reason) => {
    console.log(`[chat] ${name} (${userId}) disconnected: ${reason}`);
  });
});

// ── Notifications Namespace ────────────────────────────

const notifNamespace = io.of('/notifications');

notifNamespace.use(authMiddleware);

notifNamespace.on('connection', (rawSocket) => {
  const socket = rawSocket as unknown as AuthenticatedSocket;
  const { userId, name } = socket.user;

  // Auto-join user's personal notification channel
  socket.join(`user:${userId}`);
  console.log(`[notif] ${name} (${userId}) connected`);

  // Presence updates
  socket.on('presence:update', (data) => {
    notifNamespace.emit('presence:changed', {
      userId,
      status: data.status,
    });
  });

  socket.on('disconnect', () => {
    notifNamespace.emit('presence:changed', {
      userId,
      status: 'offline',
    });
  });
});

// Expose a function for other services to send notifications
export function sendNotification(userId: string, data: Record<string, unknown>): void {
  notifNamespace.to(`user:${userId}`).emit('message:new', {
    id: generateMessageId(),
    from: 'system',
    name: 'System',
    text: JSON.stringify(data),
    room: `user:${userId}`,
    timestamp: Date.now(),
  });
}

// ── Error Handling ─────────────────────────────────────

io.engine.on('connection_error', (err) => {
  console.error('Connection error:', err.message, err.context);
});

// ── Health & Metrics ───────────────────────────────────

app.get('/health', async (_req, res) => {
  const chatSockets = await chatNamespace.fetchSockets();
  const notifSockets = await notifNamespace.fetchSockets();

  res.json({
    status: 'ok',
    connections: {
      chat: chatSockets.length,
      notifications: notifSockets.length,
      total: chatSockets.length + notifSockets.length,
    },
    redis: config.redisUrl ? 'connected' : 'disabled',
    uptime: process.uptime(),
  });
});

app.get('/metrics', async (_req, res) => {
  const chatSockets = await chatNamespace.fetchSockets();
  const chatRooms = chatNamespace.adapter.rooms;

  res.json({
    connections: {
      chat: chatSockets.length,
      uniqueUsers: new Set(chatSockets.map((s) => s.data.user?.userId)).size,
    },
    rooms: {
      count: chatRooms?.size || 0,
    },
    memory: {
      rss: `${Math.round(process.memoryUsage().rss / 1024 / 1024)}MB`,
      heap: `${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`,
    },
    uptime: process.uptime(),
  });
});

// ── Graceful Shutdown ──────────────────────────────────

let isShuttingDown = false;

async function gracefulShutdown(signal: string): Promise<void> {
  if (isShuttingDown) return;
  isShuttingDown = true;

  console.log(`\n[${signal}] Shutting down gracefully...`);

  // Notify all clients
  const retryAfter = 5000 + Math.random() * 10000;
  io.emit('server:shutdown' as any, { message: 'Server restarting', retryAfter });

  // Wait briefly for message delivery
  await new Promise((resolve) => setTimeout(resolve, 1000));

  // Disconnect all sockets
  const allSockets = await io.fetchSockets();
  for (const socket of allSockets) {
    socket.disconnect(true);
  }

  // Close Redis connections
  if (pubClient) await pubClient.quit().catch(() => {});
  if (subClient) await subClient.quit().catch(() => {});

  // Close server
  io.close(() => {
    server.close(() => {
      console.log('Server stopped.');
      process.exit(0);
    });
  });

  setTimeout(() => process.exit(1), 10000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// ── Start ──────────────────────────────────────────────

async function start(): Promise<void> {
  await setupRedisAdapter();

  server.listen(config.port, () => {
    console.log(`🔌 Socket.IO server running on port ${config.port}`);
    console.log(`   Namespaces: /chat, /notifications`);
    console.log(`   Health: http://localhost:${config.port}/health`);
    console.log(`   Redis: ${config.redisUrl || 'disabled'}`);
  });
}

start().catch((err) => {
  console.error('Failed to start:', err);
  process.exit(1);
});
