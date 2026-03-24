/**
 * Production-ready WebSocket server with rooms, authentication,
 * heartbeat, rate limiting, and graceful shutdown.
 *
 * Dependencies: npm install ws jsonwebtoken
 * Usage: npx ts-node ws-server.ts
 */

import { WebSocketServer, WebSocket, RawData } from 'ws';
import { IncomingMessage } from 'http';
import { createServer, Server as HttpServer } from 'http';
import { verify, JwtPayload } from 'jsonwebtoken';

// ─── Configuration ───────────────────────────────────────────────

const CONFIG = {
  port: parseInt(process.env.WS_PORT || '8080', 10),
  jwtSecret: process.env.JWT_SECRET || 'change-me-in-production',
  heartbeatInterval: 30_000,
  maxPayloadSize: 1024 * 1024, // 1MB
  maxConnectionsPerUser: 5,
  rateLimit: { windowMs: 60_000, maxMessages: 200 },
  shutdownTimeout: 10_000,
  allowedOrigins: (process.env.ALLOWED_ORIGINS || '*').split(','),
};

// ─── Types ───────────────────────────────────────────────────────

interface AuthenticatedSocket extends WebSocket {
  userId: string;
  username: string;
  isAlive: boolean;
  rooms: Set<string>;
  messageCount: number;
  rateLimitReset: number;
}

interface InboundMessage {
  type: string;
  room?: string;
  payload?: unknown;
  id?: string;
}

interface OutboundMessage {
  type: string;
  payload?: unknown;
  room?: string;
  from?: string;
  id?: string;
  timestamp: number;
}

// ─── Room Manager ────────────────────────────────────────────────

class RoomManager {
  private rooms = new Map<string, Set<AuthenticatedSocket>>();

  join(roomId: string, ws: AuthenticatedSocket): void {
    if (!this.rooms.has(roomId)) this.rooms.set(roomId, new Set());
    this.rooms.get(roomId)!.add(ws);
    ws.rooms.add(roomId);

    this.broadcastToRoom(roomId, {
      type: 'room:user-joined',
      room: roomId,
      payload: { userId: ws.userId, username: ws.username },
      timestamp: Date.now(),
    }, ws);
  }

  leave(roomId: string, ws: AuthenticatedSocket): void {
    this.rooms.get(roomId)?.delete(ws);
    ws.rooms.delete(roomId);

    if (this.rooms.get(roomId)?.size === 0) {
      this.rooms.delete(roomId);
    } else {
      this.broadcastToRoom(roomId, {
        type: 'room:user-left',
        room: roomId,
        payload: { userId: ws.userId, username: ws.username },
        timestamp: Date.now(),
      });
    }
  }

  leaveAll(ws: AuthenticatedSocket): void {
    for (const roomId of ws.rooms) {
      this.leave(roomId, ws);
    }
  }

  broadcastToRoom(
    roomId: string,
    message: OutboundMessage,
    exclude?: AuthenticatedSocket,
  ): void {
    const data = JSON.stringify(message);
    this.rooms.get(roomId)?.forEach((client) => {
      if (client !== exclude && client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    });
  }

  getMembers(roomId: string): string[] {
    return Array.from(this.rooms.get(roomId) || []).map((ws) => ws.userId);
  }

  getRoomList(): Array<{ id: string; memberCount: number }> {
    return Array.from(this.rooms.entries()).map(([id, members]) => ({
      id,
      memberCount: members.size,
    }));
  }
}

// ─── Server ──────────────────────────────────────────────────────

class WsServer {
  private httpServer: HttpServer;
  private wss: WebSocketServer;
  private rooms = new RoomManager();
  private heartbeatTimer?: ReturnType<typeof setInterval>;
  private isShuttingDown = false;
  private userConnections = new Map<string, Set<AuthenticatedSocket>>();

  constructor() {
    this.httpServer = createServer(this.handleHttp.bind(this));
    this.wss = new WebSocketServer({
      noServer: true,
      maxPayload: CONFIG.maxPayloadSize,
    });
    this.setupUpgrade();
    this.setupHeartbeat();
    this.setupShutdown();
  }

  // ── HTTP health endpoint ──

  private handleHttp(req: IncomingMessage, res: any): void {
    if (req.url === '/health') {
      const status = this.isShuttingDown ? 503 : 200;
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: this.isShuttingDown ? 'draining' : 'healthy',
        connections: this.wss.clients.size,
        rooms: this.rooms.getRoomList(),
        uptime: process.uptime(),
        memory: process.memoryUsage(),
      }));
      return;
    }
    res.writeHead(404);
    res.end();
  }

  // ── Authentication & Upgrade ──

  private setupUpgrade(): void {
    this.httpServer.on('upgrade', (req, socket, head) => {
      if (this.isShuttingDown) {
        socket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n');
        socket.destroy();
        return;
      }

      // Origin check
      const origin = req.headers.origin || '';
      if (CONFIG.allowedOrigins[0] !== '*' && !CONFIG.allowedOrigins.includes(origin)) {
        socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
        socket.destroy();
        return;
      }

      // Authenticate
      const url = new URL(req.url || '/', `http://${req.headers.host}`);
      const token = url.searchParams.get('token') || this.extractBearerToken(req);

      if (!token) {
        socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
        socket.destroy();
        return;
      }

      try {
        const decoded = verify(token, CONFIG.jwtSecret) as JwtPayload;
        const userId = decoded.sub!;

        // Per-user connection limit
        const userConns = this.userConnections.get(userId);
        if (userConns && userConns.size >= CONFIG.maxConnectionsPerUser) {
          socket.write('HTTP/1.1 429 Too Many Requests\r\n\r\n');
          socket.destroy();
          return;
        }

        this.wss.handleUpgrade(req, socket, head, (ws) => {
          const authedWs = ws as AuthenticatedSocket;
          authedWs.userId = userId;
          authedWs.username = (decoded as any).username || userId;
          authedWs.rooms = new Set();
          authedWs.messageCount = 0;
          authedWs.rateLimitReset = Date.now() + CONFIG.rateLimit.windowMs;
          this.wss.emit('connection', authedWs, req);
        });
      } catch {
        socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
        socket.destroy();
      }
    });

    this.wss.on('connection', this.onConnection.bind(this));
  }

  private extractBearerToken(req: IncomingMessage): string | null {
    const auth = req.headers.authorization;
    if (auth?.startsWith('Bearer ')) return auth.slice(7);
    return null;
  }

  // ── Connection Handler ──

  private onConnection(ws: AuthenticatedSocket, req: IncomingMessage): void {
    ws.isAlive = true;

    // Track user connections
    if (!this.userConnections.has(ws.userId)) {
      this.userConnections.set(ws.userId, new Set());
    }
    this.userConnections.get(ws.userId)!.add(ws);

    console.log(`[connect] user=${ws.userId} connections=${this.wss.clients.size}`);

    ws.send(JSON.stringify({
      type: 'connected',
      payload: { userId: ws.userId, username: ws.username },
      timestamp: Date.now(),
    }));

    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('message', (data) => this.onMessage(ws, data));
    ws.on('close', (code, reason) => this.onClose(ws, code, reason));
    ws.on('error', (err) => console.error(`[error] user=${ws.userId}:`, err.message));
  }

  // ── Message Handler ──

  private onMessage(ws: AuthenticatedSocket, data: RawData): void {
    // Rate limiting
    const now = Date.now();
    if (now > ws.rateLimitReset) {
      ws.messageCount = 0;
      ws.rateLimitReset = now + CONFIG.rateLimit.windowMs;
    }
    ws.messageCount++;
    if (ws.messageCount > CONFIG.rateLimit.maxMessages) {
      ws.send(JSON.stringify({
        type: 'error',
        payload: { code: 'RATE_LIMITED', message: 'Too many messages' },
        timestamp: now,
      }));
      return;
    }

    let msg: InboundMessage;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      ws.send(JSON.stringify({
        type: 'error',
        payload: { code: 'INVALID_JSON', message: 'Invalid JSON' },
        timestamp: now,
      }));
      return;
    }

    switch (msg.type) {
      case 'room:join':
        if (msg.room) this.rooms.join(msg.room, ws);
        break;

      case 'room:leave':
        if (msg.room) this.rooms.leave(msg.room, ws);
        break;

      case 'room:message':
        if (msg.room && ws.rooms.has(msg.room)) {
          this.rooms.broadcastToRoom(msg.room, {
            type: 'room:message',
            room: msg.room,
            payload: msg.payload,
            from: ws.userId,
            id: msg.id,
            timestamp: now,
          }, ws);
        }
        break;

      case 'room:list':
        ws.send(JSON.stringify({
          type: 'room:list',
          payload: this.rooms.getRoomList(),
          id: msg.id,
          timestamp: now,
        }));
        break;

      case 'room:members':
        if (msg.room) {
          ws.send(JSON.stringify({
            type: 'room:members',
            room: msg.room,
            payload: this.rooms.getMembers(msg.room),
            id: msg.id,
            timestamp: now,
          }));
        }
        break;

      case 'ping':
        ws.send(JSON.stringify({
          type: 'pong',
          payload: msg.payload,
          id: msg.id,
          timestamp: now,
        }));
        break;

      default:
        ws.send(JSON.stringify({
          type: 'error',
          payload: { code: 'UNKNOWN_TYPE', message: `Unknown type: ${msg.type}` },
          id: msg.id,
          timestamp: now,
        }));
    }
  }

  // ── Disconnect ──

  private onClose(ws: AuthenticatedSocket, code: number, reason: Buffer): void {
    this.rooms.leaveAll(ws);
    this.userConnections.get(ws.userId)?.delete(ws);
    if (this.userConnections.get(ws.userId)?.size === 0) {
      this.userConnections.delete(ws.userId);
    }
    console.log(`[disconnect] user=${ws.userId} code=${code} connections=${this.wss.clients.size}`);
  }

  // ── Heartbeat ──

  private setupHeartbeat(): void {
    this.heartbeatTimer = setInterval(() => {
      this.wss.clients.forEach((raw) => {
        const ws = raw as AuthenticatedSocket;
        if (!ws.isAlive) {
          console.log(`[heartbeat] terminating unresponsive: ${ws.userId}`);
          ws.terminate();
          return;
        }
        ws.isAlive = false;
        ws.ping();
      });
    }, CONFIG.heartbeatInterval);
  }

  // ── Graceful Shutdown ──

  private setupShutdown(): void {
    const shutdown = async (signal: string) => {
      if (this.isShuttingDown) return;
      this.isShuttingDown = true;
      console.log(`\n[shutdown] Received ${signal}, draining connections...`);

      if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);

      // Stop accepting new connections
      this.httpServer.close();

      // Notify and close existing connections
      const closePromises: Promise<void>[] = [];
      this.wss.clients.forEach((raw) => {
        const ws = raw as AuthenticatedSocket;
        if (ws.readyState === WebSocket.OPEN) {
          closePromises.push(
            new Promise<void>((resolve) => {
              ws.send(JSON.stringify({
                type: 'server:shutdown',
                payload: { retryAfter: 5 },
                timestamp: Date.now(),
              }));
              ws.close(1001, 'Server shutting down');
              ws.on('close', () => resolve());
              setTimeout(() => { ws.terminate(); resolve(); }, CONFIG.shutdownTimeout);
            }),
          );
        }
      });

      await Promise.allSettled(closePromises);
      console.log('[shutdown] All connections closed. Exiting.');
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  }

  // ── Start ──

  start(): void {
    this.httpServer.listen(CONFIG.port, () => {
      console.log(`WebSocket server listening on port ${CONFIG.port}`);
      console.log(`Health check: http://localhost:${CONFIG.port}/health`);
    });
  }
}

// ─── Entry Point ─────────────────────────────────────────────────

const server = new WsServer();
server.start();
