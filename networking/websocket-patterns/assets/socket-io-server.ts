/**
 * Socket.IO server with Redis adapter, rooms, namespaces, middleware,
 * authentication, rate limiting, and graceful shutdown.
 *
 * Dependencies:
 *   npm install socket.io @socket.io/redis-adapter redis jsonwebtoken
 *
 * Usage: npx ts-node socket-io-server.ts
 */

import { Server, Socket } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient, RedisClientType } from 'redis';
import { createServer } from 'http';
import { verify, JwtPayload } from 'jsonwebtoken';

// ─── Configuration ───────────────────────────────────────────────

const CONFIG = {
  port: parseInt(process.env.PORT || '3000', 10),
  redisUrl: process.env.REDIS_URL || 'redis://localhost:6379',
  jwtSecret: process.env.JWT_SECRET || 'change-me-in-production',
  allowedOrigins: (process.env.ALLOWED_ORIGINS || 'http://localhost:3000').split(','),
  pingInterval: 25_000,
  pingTimeout: 20_000,
  maxHttpBufferSize: 1_000_000, // 1MB
  rateLimit: { windowMs: 60_000, maxEvents: 200 },
  connectionStateRecovery: {
    maxDisconnectionDuration: 2 * 60 * 1000, // 2 minutes
    skipMiddlewares: true,
  },
};

// ─── Types ───────────────────────────────────────────────────────

interface UserData {
  userId: string;
  username: string;
  role: string;
  eventCount: number;
  rateLimitReset: number;
}

interface ChatMessage {
  roomId: string;
  content: string;
  timestamp?: number;
}

interface RoomInfo {
  roomId: string;
  members: string[];
  memberCount: number;
}

// ─── Server Setup ────────────────────────────────────────────────

async function createSocketServer() {
  const httpServer = createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: 'healthy',
        uptime: process.uptime(),
        memory: process.memoryUsage(),
      }));
      return;
    }
    res.writeHead(404);
    res.end();
  });

  const io = new Server(httpServer, {
    cors: {
      origin: CONFIG.allowedOrigins,
      methods: ['GET', 'POST'],
      credentials: true,
    },
    pingInterval: CONFIG.pingInterval,
    pingTimeout: CONFIG.pingTimeout,
    maxHttpBufferSize: CONFIG.maxHttpBufferSize,
    connectionStateRecovery: CONFIG.connectionStateRecovery,
    transports: ['websocket', 'polling'],
  });

  // ── Redis Adapter ──

  const pubClient: RedisClientType = createClient({ url: CONFIG.redisUrl });
  const subClient: RedisClientType = pubClient.duplicate();

  pubClient.on('error', (err) => console.error('[redis-pub] Error:', err.message));
  subClient.on('error', (err) => console.error('[redis-sub] Error:', err.message));

  await Promise.all([pubClient.connect(), subClient.connect()]);
  console.log('[redis] Connected to Redis');

  io.adapter(createAdapter(pubClient, subClient));

  // ── Global Middleware: Authentication ──

  io.use((socket, next) => {
    const token = socket.handshake.auth.token as string | undefined;
    if (!token) {
      return next(new Error('Authentication required'));
    }

    try {
      const decoded = verify(token, CONFIG.jwtSecret) as JwtPayload & {
        username?: string;
        role?: string;
      };
      socket.data = {
        userId: decoded.sub!,
        username: decoded.username || decoded.sub!,
        role: decoded.role || 'user',
        eventCount: 0,
        rateLimitReset: Date.now() + CONFIG.rateLimit.windowMs,
      } satisfies UserData;
      next();
    } catch {
      next(new Error('Invalid token'));
    }
  });

  // ── Global Middleware: Rate Limiting ──

  io.use((socket, next) => {
    const originalOnEvent = (socket as any)._onevent;
    (socket as any)._onevent = function (packet: any) {
      const data = socket.data as UserData;
      const now = Date.now();

      if (now > data.rateLimitReset) {
        data.eventCount = 0;
        data.rateLimitReset = now + CONFIG.rateLimit.windowMs;
      }

      data.eventCount++;
      if (data.eventCount > CONFIG.rateLimit.maxEvents) {
        socket.emit('error', { code: 'RATE_LIMITED', message: 'Too many events' });
        return;
      }

      originalOnEvent.call(this, packet);
    };
    next();
  });

  // ── Global Middleware: Logging ──

  io.use((socket, next) => {
    console.log(`[connect] user=${socket.data.userId} id=${socket.id}`);
    next();
  });

  // ═══════════════════════════════════════════════════════════════
  //  Default Namespace: /
  // ═══════════════════════════════════════════════════════════════

  io.on('connection', (socket: Socket) => {
    const user = socket.data as UserData;

    if (socket.recovered) {
      console.log(`[recovered] user=${user.userId} rooms restored`);
    }

    // ── Room Management ──

    socket.on('room:join', async (roomId: string, callback?: (res: RoomInfo) => void) => {
      await socket.join(roomId);
      socket.to(roomId).emit('room:user-joined', {
        userId: user.userId,
        username: user.username,
      });

      const members = await io.in(roomId).fetchSockets();
      const info: RoomInfo = {
        roomId,
        members: members.map((s) => (s.data as UserData).userId),
        memberCount: members.length,
      };

      callback?.(info);
      console.log(`[room:join] user=${user.userId} room=${roomId}`);
    });

    socket.on('room:leave', async (roomId: string) => {
      await socket.leave(roomId);
      socket.to(roomId).emit('room:user-left', {
        userId: user.userId,
        username: user.username,
      });
      console.log(`[room:leave] user=${user.userId} room=${roomId}`);
    });

    // ── Messaging ──

    socket.on('message', (msg: ChatMessage, callback?: (res: { status: string }) => void) => {
      const enriched = {
        ...msg,
        from: user.userId,
        username: user.username,
        timestamp: Date.now(),
      };

      if (msg.roomId) {
        socket.to(msg.roomId).emit('message', enriched);
      } else {
        socket.broadcast.emit('message', enriched);
      }

      callback?.({ status: 'delivered' });
    });

    // ── Typing Indicator ──

    socket.on('typing:start', (roomId: string) => {
      socket.to(roomId).emit('typing:start', {
        userId: user.userId,
        username: user.username,
      });
    });

    socket.on('typing:stop', (roomId: string) => {
      socket.to(roomId).emit('typing:stop', { userId: user.userId });
    });

    // ── Presence ──

    socket.on('presence:update', (status: 'online' | 'away' | 'busy') => {
      socket.broadcast.emit('presence:update', {
        userId: user.userId,
        status,
        timestamp: Date.now(),
      });
    });

    // ── Disconnect ──

    socket.on('disconnect', (reason) => {
      console.log(`[disconnect] user=${user.userId} reason=${reason}`);
      socket.broadcast.emit('presence:update', {
        userId: user.userId,
        status: 'offline',
        timestamp: Date.now(),
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════
  //  Admin Namespace: /admin
  // ═══════════════════════════════════════════════════════════════

  const adminNs = io.of('/admin');

  // Admin-only middleware
  adminNs.use((socket, next) => {
    const user = socket.data as UserData;
    if (user.role !== 'admin') {
      return next(new Error('Admin access required'));
    }
    next();
  });

  adminNs.on('connection', (socket) => {
    const user = socket.data as UserData;
    console.log(`[admin:connect] user=${user.userId}`);

    socket.on('server:stats', async (callback: (stats: unknown) => void) => {
      const sockets = await io.fetchSockets();
      callback({
        totalConnections: sockets.length,
        users: sockets.map((s) => ({
          userId: (s.data as UserData).userId,
          rooms: Array.from(s.rooms).filter((r) => r !== s.id),
        })),
        memory: process.memoryUsage(),
        uptime: process.uptime(),
      });
    });

    socket.on('user:disconnect', async (userId: string) => {
      const sockets = await io.fetchSockets();
      for (const s of sockets) {
        if ((s.data as UserData).userId === userId) {
          s.disconnect(true);
        }
      }
    });

    socket.on('room:broadcast', (data: { roomId: string; message: string }) => {
      io.to(data.roomId).emit('admin:broadcast', {
        message: data.message,
        from: 'admin',
        timestamp: Date.now(),
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════
  //  Notifications Namespace: /notifications
  // ═══════════════════════════════════════════════════════════════

  const notifNs = io.of('/notifications');

  notifNs.on('connection', (socket) => {
    const user = socket.data as UserData;

    // Auto-join user-specific notification channel
    socket.join(`user:${user.userId}`);

    socket.on('subscribe', (topic: string) => {
      socket.join(`topic:${topic}`);
    });

    socket.on('unsubscribe', (topic: string) => {
      socket.leave(`topic:${topic}`);
    });
  });

  // Expose notification sender for use by other services
  function sendNotification(userId: string, notification: unknown) {
    notifNs.to(`user:${userId}`).emit('notification', notification);
  }

  function broadcastNotification(topic: string, notification: unknown) {
    notifNs.to(`topic:${topic}`).emit('notification', notification);
  }

  // ── Graceful Shutdown ──────────────────────────────────────────

  const shutdown = async (signal: string) => {
    console.log(`\n[shutdown] Received ${signal}`);

    // Notify all clients
    io.emit('server:shutdown', { retryAfter: 5 });

    // Close Socket.IO (disconnects all clients)
    io.close();

    // Close Redis connections
    await Promise.allSettled([pubClient.quit(), subClient.quit()]);

    httpServer.close(() => {
      console.log('[shutdown] Server stopped');
      process.exit(0);
    });

    // Force exit after timeout
    setTimeout(() => {
      console.error('[shutdown] Forced exit after timeout');
      process.exit(1);
    }, 10_000);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  // ── Start ──────────────────────────────────────────────────────

  httpServer.listen(CONFIG.port, () => {
    console.log(`Socket.IO server listening on port ${CONFIG.port}`);
    console.log(`Health check: http://localhost:${CONFIG.port}/health`);
    console.log(`Namespaces: / (main), /admin, /notifications`);
  });

  return { io, sendNotification, broadcastNotification };
}

// ─── Entry Point ─────────────────────────────────────────────────

createSocketServer().catch((err) => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
