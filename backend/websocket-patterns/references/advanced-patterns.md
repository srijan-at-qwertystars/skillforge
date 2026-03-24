# Advanced WebSocket Patterns

## Table of Contents

- [Multiplexing Over a Single Connection](#multiplexing-over-a-single-connection)
- [Custom Subprotocols](#custom-subprotocols)
- [WebSocket Compression (permessage-deflate)](#websocket-compression-permessage-deflate)
- [Binary Message Framing](#binary-message-framing)
- [Connection State Machines](#connection-state-machines)
- [Graceful Degradation to SSE/Polling](#graceful-degradation-to-ssepolling)
- [WebSocket Gateway Patterns](#websocket-gateway-patterns)
- [Distributed Pub/Sub with Redis/NATS](#distributed-pubsub-with-redisnats)
- [Presence Tracking](#presence-tracking)
- [Cursor Sharing for Collaboration](#cursor-sharing-for-collaboration)

---

## Multiplexing Over a Single Connection

Browsers limit connections per origin (6–13). Multiplexing channels over one WebSocket avoids exhausting limits.

### Channel Multiplexing Protocol

```typescript
// Message envelope with channel routing
interface MultiplexedMessage {
  channel: string;       // 'chat', 'notifications', 'presence'
  id: string;            // correlation ID
  action: 'subscribe' | 'unsubscribe' | 'publish' | 'data';
  payload: unknown;
}

// Server-side channel router
class ChannelRouter {
  private channels = new Map<string, Set<WebSocket>>();
  private subscriptions = new Map<WebSocket, Set<string>>();

  subscribe(ws: WebSocket, channel: string): void {
    if (!this.channels.has(channel)) this.channels.set(channel, new Set());
    this.channels.get(channel)!.add(ws);

    if (!this.subscriptions.has(ws)) this.subscriptions.set(ws, new Set());
    this.subscriptions.get(ws)!.add(channel);
  }

  unsubscribe(ws: WebSocket, channel: string): void {
    this.channels.get(channel)?.delete(ws);
    this.subscriptions.get(ws)?.delete(channel);
  }

  publish(channel: string, payload: unknown, exclude?: WebSocket): void {
    const msg = JSON.stringify({ channel, action: 'data', payload });
    this.channels.get(channel)?.forEach(ws => {
      if (ws !== exclude && ws.readyState === WebSocket.OPEN) {
        ws.send(msg);
      }
    });
  }

  // Clean up all subscriptions for a disconnected client
  removeClient(ws: WebSocket): void {
    this.subscriptions.get(ws)?.forEach(ch => {
      this.channels.get(ch)?.delete(ws);
    });
    this.subscriptions.delete(ws);
  }
}
```

### Client-Side Channel Manager

```typescript
class WSChannelClient {
  private handlers = new Map<string, Set<(data: unknown) => void>>();

  constructor(private ws: WebSocket) {
    ws.onmessage = (e) => {
      const msg: MultiplexedMessage = JSON.parse(e.data);
      if (msg.action === 'data') {
        this.handlers.get(msg.channel)?.forEach(fn => fn(msg.payload));
      }
    };
  }

  subscribe(channel: string, handler: (data: unknown) => void): () => void {
    if (!this.handlers.has(channel)) this.handlers.set(channel, new Set());
    this.handlers.get(channel)!.add(handler);
    this.ws.send(JSON.stringify({ channel, action: 'subscribe' }));

    return () => {
      this.handlers.get(channel)?.delete(handler);
      if (this.handlers.get(channel)?.size === 0) {
        this.ws.send(JSON.stringify({ channel, action: 'unsubscribe' }));
        this.handlers.delete(channel);
      }
    };
  }

  publish(channel: string, payload: unknown): void {
    this.ws.send(JSON.stringify({ channel, action: 'publish', payload }));
  }
}
```

**Key design decisions:**
- Each channel is independently subscribable/unsubscribable
- Server tracks per-client subscriptions for cleanup on disconnect
- Binary channels can coexist — use a 1-byte channel prefix on binary frames

---

## Custom Subprotocols

Subprotocols negotiate application-level protocol during handshake. Use them for versioning, format negotiation, or capability discovery.

### Defining a Subprotocol

```typescript
// Server advertises supported subprotocols
const wss = new WebSocketServer({
  port: 8080,
  handleProtocols: (protocols: Set<string>, req) => {
    // Client sent: Sec-WebSocket-Protocol: v2.json, v1.json
    if (protocols.has('v2.json')) return 'v2.json';
    if (protocols.has('v1.json')) return 'v1.json';
    return false; // reject connection — no common protocol
  }
});

wss.on('connection', (ws) => {
  // ws.protocol contains the negotiated subprotocol
  const serializer = ws.protocol === 'v2.json'
    ? new V2Serializer()
    : new V1Serializer();

  ws.on('message', (data) => {
    const msg = serializer.deserialize(data);
    // ...
  });
});

// Client specifies preferred subprotocols (in priority order)
const ws = new WebSocket('wss://api.example.com/ws', ['v2.json', 'v1.json']);
ws.onopen = () => {
  console.log('Negotiated protocol:', ws.protocol); // 'v2.json'
};
```

### Use Cases for Custom Subprotocols
| Subprotocol | Purpose |
|------------|---------|
| `v1.json`, `v2.json` | API versioning — clients specify supported versions |
| `binary.protobuf` | Negotiate binary encoding vs JSON |
| `graphql-transport-ws` | GraphQL subscriptions over WebSocket |
| `mqtt` | MQTT over WebSocket |
| `auth.ticket` | Indicate ticket-based authentication flow |

---

## WebSocket Compression (permessage-deflate)

WebSocket extension defined in RFC 7692. Compresses each message independently. Significant for text-heavy payloads (JSON), marginal for already-compressed binary.

### Enabling in Node.js (ws library)

```typescript
import { WebSocketServer } from 'ws';

const wss = new WebSocketServer({
  port: 8080,
  perMessageDeflate: {
    zlibDeflateOptions: {
      chunkSize: 1024,
      memLevel: 7,
      level: 3,               // 1=fast, 9=best compression, 3=good balance
    },
    zlibInflateOptions: {
      chunkSize: 10 * 1024,
    },
    clientNoContextTakeover: true,  // Don't reuse deflate context (saves memory)
    serverNoContextTakeover: true,
    serverMaxWindowBits: 10,        // Limit memory usage
    concurrencyLimit: 10,           // Limit concurrent zlib operations
    threshold: 1024,                // Only compress messages > 1KB
  },
});
```

### Performance Tradeoffs

| Setting | CPU | Memory | Compression |
|---------|-----|--------|-------------|
| `level: 1` | Low | Low | ~60% |
| `level: 3` | Medium | Medium | ~70% |
| `level: 6` | High | High | ~75% |
| `level: 9` | Very High | Very High | ~78% |
| `noContextTakeover: true` | — | Saves ~300KB/conn | Slightly worse |
| `noContextTakeover: false` | — | +300KB/conn | Better ratio |

**Recommendations:**
- Enable for JSON-heavy workloads (chat, notifications, API data)
- Disable for binary data (images, audio, protobuf — already compressed)
- Use `noContextTakeover: true` at scale (>10K connections) to control memory
- Set `threshold: 1024` to skip tiny messages — overhead exceeds savings
- Monitor CPU — compression at `level: 6+` can bottleneck under high throughput

---

## Binary Message Framing

For high-throughput or mixed-type messages, define a binary framing protocol. Avoids JSON parse overhead.

### Custom Binary Frame Format

```
Byte 0:       Message type (uint8)
Bytes 1-4:    Payload length (uint32 big-endian)
Bytes 5-8:    Sequence number (uint32 big-endian)
Bytes 9-12:   Timestamp (uint32, seconds since epoch)
Bytes 13-N:   Payload
```

```typescript
// Encoding
function encodeFrame(type: number, seq: number, payload: Uint8Array): ArrayBuffer {
  const frame = new ArrayBuffer(13 + payload.byteLength);
  const view = new DataView(frame);
  view.setUint8(0, type);
  view.setUint32(1, payload.byteLength, false); // big-endian
  view.setUint32(5, seq, false);
  view.setUint32(9, Math.floor(Date.now() / 1000), false);
  new Uint8Array(frame, 13).set(payload);
  return frame;
}

// Decoding
function decodeFrame(buffer: ArrayBuffer): {
  type: number; length: number; seq: number; timestamp: number; payload: Uint8Array
} {
  const view = new DataView(buffer);
  return {
    type: view.getUint8(0),
    length: view.getUint32(1, false),
    seq: view.getUint32(5, false),
    timestamp: view.getUint32(9, false),
    payload: new Uint8Array(buffer, 13),
  };
}

// Message type constants
const MSG = {
  HEARTBEAT: 0x01,
  CHAT: 0x02,
  PRESENCE: 0x03,
  CURSOR: 0x04,
  ACK: 0x05,
} as const;
```

### When to Use Binary vs JSON

| Criterion | Binary | JSON |
|-----------|--------|------|
| Throughput | >1000 msg/s | <100 msg/s |
| Payload size matters | Yes — bandwidth constrained | No — small messages |
| Schema evolution | Harder — need versioning bytes | Easier — add fields |
| Debugging ease | Harder — need hex viewer | Easy — human readable |
| Client compatibility | All modern browsers (ArrayBuffer) | Universal |

---

## Connection State Machines

Model WebSocket lifecycle as a state machine to prevent invalid transitions and race conditions.

### State Diagram

```
  DISCONNECTED
      │
      ▼ connect()
  CONNECTING ──────────────────┐
      │                        │ error/timeout
      ▼ onopen                 ▼
  AUTHENTICATING          WAITING_TO_RETRY
      │                        │
      │ auth success           │ delay elapsed
      ▼                        │
  CONNECTED ◄──────────────────┘
      │
      │ onclose / onerror
      ▼
  DISCONNECTING
      │
      ▼ cleanup done
  DISCONNECTED (→ WAITING_TO_RETRY if retriable)
```

### Implementation

```typescript
type WSState = 'disconnected' | 'connecting' | 'authenticating'
             | 'connected' | 'disconnecting' | 'waiting_to_retry';

class WSStateMachine {
  private state: WSState = 'disconnected';
  private ws: WebSocket | null = null;
  private retryCount = 0;

  private readonly transitions: Record<WSState, WSState[]> = {
    disconnected:     ['connecting'],
    connecting:       ['authenticating', 'waiting_to_retry', 'disconnected'],
    authenticating:   ['connected', 'disconnecting'],
    connected:        ['disconnecting'],
    disconnecting:    ['disconnected', 'waiting_to_retry'],
    waiting_to_retry: ['connecting', 'disconnected'],
  };

  private transition(to: WSState): void {
    if (!this.transitions[this.state].includes(to)) {
      throw new Error(`Invalid transition: ${this.state} → ${to}`);
    }
    console.log(`WS: ${this.state} → ${to}`);
    this.state = to;
    this.onStateChange?.(to);
  }

  onStateChange?: (state: WSState) => void;

  connect(url: string, token: string): void {
    this.transition('connecting');
    this.ws = new WebSocket(url);

    this.ws.onopen = () => {
      this.transition('authenticating');
      this.ws!.send(JSON.stringify({ type: 'auth', token }));
    };

    this.ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (this.state === 'authenticating' && msg.type === 'auth:ok') {
        this.retryCount = 0;
        this.transition('connected');
      }
      // ... handle other messages
    };

    this.ws.onclose = (e) => {
      this.transition('disconnecting');
      this.ws = null;
      if (e.code !== 1000 && this.retryCount < 10) {
        this.transition('waiting_to_retry');
        this.scheduleRetry(url, token);
      } else {
        this.transition('disconnected');
      }
    };

    this.ws.onerror = () => {}; // onclose fires after onerror
  }

  private scheduleRetry(url: string, token: string): void {
    const delay = Math.min(500 * 2 ** this.retryCount, 30000);
    this.retryCount++;
    setTimeout(() => {
      if (this.state === 'waiting_to_retry') this.connect(url, token);
    }, delay * (0.5 + Math.random() * 0.5));
  }

  send(data: string): void {
    if (this.state !== 'connected') {
      throw new Error(`Cannot send in state: ${this.state}`);
    }
    this.ws!.send(data);
  }

  disconnect(): void {
    if (this.state === 'connected') {
      this.retryCount = Infinity; // prevent auto-reconnect
      this.ws?.close(1000, 'user initiated');
    }
  }

  getState(): WSState { return this.state; }
}
```

---

## Graceful Degradation to SSE/Polling

Not all networks allow WebSocket. Implement a transport abstraction that falls back gracefully.

### Transport Abstraction Layer

```typescript
interface Transport {
  connect(): Promise<void>;
  send(data: string): void;
  onMessage(handler: (data: string) => void): void;
  close(): void;
  readonly type: 'websocket' | 'sse' | 'polling';
}

class WebSocketTransport implements Transport {
  readonly type = 'websocket';
  private ws!: WebSocket;
  private messageHandler?: (data: string) => void;

  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket('wss://api.example.com/ws');
      this.ws.onopen = () => resolve();
      this.ws.onerror = () => reject(new Error('WebSocket failed'));
      this.ws.onmessage = (e) => this.messageHandler?.(e.data);
      setTimeout(() => reject(new Error('WebSocket timeout')), 5000);
    });
  }

  send(data: string): void { this.ws.send(data); }
  onMessage(handler: (data: string) => void): void { this.messageHandler = handler; }
  close(): void { this.ws.close(1000); }
}

class SSETransport implements Transport {
  readonly type = 'sse';
  private es!: EventSource;
  private messageHandler?: (data: string) => void;

  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.es = new EventSource('/api/events');
      this.es.onopen = () => resolve();
      this.es.onerror = () => reject(new Error('SSE failed'));
      this.es.onmessage = (e) => this.messageHandler?.(e.data);
      setTimeout(() => reject(new Error('SSE timeout')), 5000);
    });
  }

  send(data: string): void {
    // SSE is server-push only — send via HTTP POST
    fetch('/api/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: data,
    });
  }

  onMessage(handler: (data: string) => void): void { this.messageHandler = handler; }
  close(): void { this.es.close(); }
}

// Auto-negotiate best transport
async function connectWithFallback(): Promise<Transport> {
  const transports: Transport[] = [
    new WebSocketTransport(),
    new SSETransport(),
    // new PollingTransport(), // last resort
  ];

  for (const transport of transports) {
    try {
      await transport.connect();
      console.log(`Connected via ${transport.type}`);
      return transport;
    } catch {
      console.warn(`${transport.type} failed, trying next...`);
    }
  }
  throw new Error('All transports failed');
}
```

---

## WebSocket Gateway Patterns

### API Gateway Pattern

The gateway terminates WebSocket connections and routes to internal services. Clients talk to one endpoint; the gateway fans out.

```
Client ──WSS──▶ API Gateway ──gRPC/HTTP──▶ Chat Service
                     │                 ──▶ Notification Service
                     │                 ──▶ Presence Service
                     ▼
               Connection Registry (Redis)
```

```typescript
// Gateway message router
class WSGateway {
  private services: Map<string, ServiceClient> = new Map();

  constructor() {
    this.services.set('chat', new ChatServiceClient());
    this.services.set('notifications', new NotificationServiceClient());
    this.services.set('presence', new PresenceServiceClient());
  }

  async handleMessage(ws: WebSocket, raw: string): Promise<void> {
    const msg = JSON.parse(raw);
    const [domain] = msg.type.split(':'); // 'chat:send' → 'chat'
    const service = this.services.get(domain);

    if (!service) {
      ws.send(JSON.stringify({ type: 'error', message: `Unknown domain: ${domain}` }));
      return;
    }

    const result = await service.handle(msg, ws.userId);
    if (result.broadcast) {
      this.broadcastToRoom(result.room, result.data);
    } else {
      ws.send(JSON.stringify(result.data));
    }
  }

  private async broadcastToRoom(room: string, data: unknown): Promise<void> {
    // Publish to Redis for cross-instance delivery
    await redis.publish(`room:${room}`, JSON.stringify(data));
  }
}
```

### Reverse Proxy Pattern (Nginx)

```nginx
# Route different WebSocket paths to different backend services
map $uri $ws_backend {
    ~^/ws/chat      chat-service:3001;
    ~^/ws/feed      feed-service:3002;
    ~^/ws/collab    collab-service:3003;
    default         default-service:3000;
}

server {
    location ~ ^/ws/ {
        proxy_pass http://$ws_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

---

## Distributed Pub/Sub with Redis/NATS

### Redis Pub/Sub for Cross-Server Messaging

```typescript
import { createClient } from 'redis';

class RedisPubSub {
  private pub: ReturnType<typeof createClient>;
  private sub: ReturnType<typeof createClient>;
  private localSubscribers = new Map<string, Set<(data: string) => void>>();

  async init(): Promise<void> {
    this.pub = createClient({ url: 'redis://redis:6379' });
    this.sub = this.pub.duplicate();
    await Promise.all([this.pub.connect(), this.sub.connect()]);
  }

  async subscribe(channel: string, handler: (data: string) => void): Promise<void> {
    if (!this.localSubscribers.has(channel)) {
      this.localSubscribers.set(channel, new Set());
      await this.sub.subscribe(channel, (message) => {
        this.localSubscribers.get(channel)?.forEach(fn => fn(message));
      });
    }
    this.localSubscribers.get(channel)!.add(handler);
  }

  async publish(channel: string, data: string): Promise<void> {
    await this.pub.publish(channel, data);
  }

  async unsubscribe(channel: string, handler: (data: string) => void): Promise<void> {
    this.localSubscribers.get(channel)?.delete(handler);
    if (this.localSubscribers.get(channel)?.size === 0) {
      await this.sub.unsubscribe(channel);
      this.localSubscribers.delete(channel);
    }
  }
}
```

### NATS for Cross-Server Messaging

```typescript
import { connect, StringCodec } from 'nats';

class NATSPubSub {
  private nc!: Awaited<ReturnType<typeof connect>>;
  private sc = StringCodec();

  async init(): Promise<void> {
    this.nc = await connect({ servers: 'nats://nats:4222' });
  }

  subscribe(subject: string, handler: (data: string) => void): { unsubscribe: () => void } {
    const sub = this.nc.subscribe(subject);
    (async () => {
      for await (const msg of sub) {
        handler(this.sc.decode(msg.data));
      }
    })();
    return { unsubscribe: () => sub.unsubscribe() };
  }

  publish(subject: string, data: string): void {
    this.nc.publish(subject, this.sc.encode(data));
  }

  // NATS supports request/reply natively
  async request(subject: string, data: string, timeoutMs = 5000): Promise<string> {
    const resp = await this.nc.request(subject, this.sc.encode(data), { timeout: timeoutMs });
    return this.sc.decode(resp.data);
  }
}
```

### Redis vs NATS Comparison

| Feature | Redis Pub/Sub | NATS |
|---------|--------------|------|
| Persistence | No (fire-and-forget) | No (use JetStream for persistence) |
| Pattern subscriptions | Yes (`PSUBSCRIBE`) | Yes (wildcards `>`, `*`) |
| Request/reply | Manual | Native |
| Throughput | ~500K msg/s | ~10M msg/s |
| Clustering | Redis Cluster | Built-in clustering |
| Existing infra | Often already deployed | Separate service |

---

## Presence Tracking

Track who's online, in which room, with real-time updates.

### Server-Side Presence Manager

```typescript
interface PresenceInfo {
  userId: string;
  status: 'online' | 'away' | 'busy';
  lastSeen: number;
  metadata?: Record<string, unknown>; // custom app data
}

class PresenceManager {
  // userId → { ws, info }
  private connections = new Map<string, { ws: WebSocket; info: PresenceInfo }>();
  // roomId → Set<userId>
  private rooms = new Map<string, Set<string>>();

  join(ws: WebSocket, userId: string, roomId: string): void {
    this.connections.set(userId, {
      ws,
      info: { userId, status: 'online', lastSeen: Date.now() },
    });

    if (!this.rooms.has(roomId)) this.rooms.set(roomId, new Set());
    this.rooms.get(roomId)!.add(userId);

    // Broadcast join to room members
    this.broadcastToRoom(roomId, {
      type: 'presence:join',
      userId,
      members: this.getRoomMembers(roomId),
    });
  }

  leave(userId: string, roomId: string): void {
    this.connections.delete(userId);
    this.rooms.get(roomId)?.delete(userId);

    this.broadcastToRoom(roomId, {
      type: 'presence:leave',
      userId,
      members: this.getRoomMembers(roomId),
    });
  }

  updateStatus(userId: string, status: PresenceInfo['status']): void {
    const conn = this.connections.get(userId);
    if (conn) {
      conn.info.status = status;
      conn.info.lastSeen = Date.now();
    }
  }

  getRoomMembers(roomId: string): PresenceInfo[] {
    const members: PresenceInfo[] = [];
    this.rooms.get(roomId)?.forEach(userId => {
      const conn = this.connections.get(userId);
      if (conn) members.push(conn.info);
    });
    return members;
  }

  // Distributed presence with Redis
  async syncToRedis(redis: RedisClient, userId: string, roomId: string): Promise<void> {
    const info = this.connections.get(userId)?.info;
    if (!info) return;
    await redis.hSet(`presence:${roomId}`, userId, JSON.stringify(info));
    await redis.expire(`presence:${roomId}`, 120); // TTL for cleanup
    await redis.publish('presence:update', JSON.stringify({ roomId, ...info }));
  }

  private broadcastToRoom(roomId: string, data: unknown): void {
    const msg = JSON.stringify(data);
    this.rooms.get(roomId)?.forEach(userId => {
      const conn = this.connections.get(userId);
      if (conn?.ws.readyState === WebSocket.OPEN) {
        conn.ws.send(msg);
      }
    });
  }
}
```

---

## Cursor Sharing for Collaboration

Real-time cursor position sharing for collaborative editors, design tools, or whiteboards.

### Cursor Protocol

```typescript
// High-frequency updates — throttle to ~20 FPS (50ms)
interface CursorUpdate {
  type: 'cursor:move';
  userId: string;
  position: { x: number; y: number };
  selection?: { start: number; end: number }; // for text editors
  color: string;   // assigned per user
  name: string;
}

// Client: throttle cursor events
class CursorSharing {
  private throttleMs = 50;
  private lastSend = 0;
  private pendingUpdate: CursorUpdate | null = null;
  private rafId: number | null = null;

  constructor(
    private ws: WebSocket,
    private userId: string,
    private color: string,
    private name: string,
  ) {}

  onMouseMove(x: number, y: number): void {
    this.pendingUpdate = {
      type: 'cursor:move',
      userId: this.userId,
      position: { x, y },
      color: this.color,
      name: this.name,
    };
    this.scheduleFlush();
  }

  private scheduleFlush(): void {
    if (this.rafId) return;
    this.rafId = requestAnimationFrame(() => {
      this.rafId = null;
      const now = Date.now();
      if (now - this.lastSend >= this.throttleMs && this.pendingUpdate) {
        this.ws.send(JSON.stringify(this.pendingUpdate));
        this.lastSend = now;
        this.pendingUpdate = null;
      } else {
        this.scheduleFlush(); // try again next frame
      }
    });
  }
}

// Server: broadcast cursor updates to room (skip back to sender)
wss.on('connection', (ws) => {
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString());
    if (msg.type === 'cursor:move') {
      const roomId = wsToRoom.get(ws);
      rooms.get(roomId)?.forEach(client => {
        if (client !== ws && client.readyState === WebSocket.OPEN) {
          client.send(raw); // forward raw to avoid re-serialization
        }
      });
    }
  });
});
```

### Rendering Remote Cursors

```typescript
class CursorRenderer {
  private cursors = new Map<string, HTMLElement>();

  updateCursor(update: CursorUpdate): void {
    let el = this.cursors.get(update.userId);
    if (!el) {
      el = document.createElement('div');
      el.className = 'remote-cursor';
      el.innerHTML = `
        <svg width="16" height="16" viewBox="0 0 16 16">
          <path d="M0 0 L16 6 L6 8 L4 16 Z" fill="${update.color}" />
        </svg>
        <span class="cursor-label" style="background:${update.color}">${update.name}</span>
      `;
      document.getElementById('canvas')!.appendChild(el);
      this.cursors.set(update.userId, el);
    }
    el.style.transform = `translate(${update.position.x}px, ${update.position.y}px)`;
  }

  removeCursor(userId: string): void {
    this.cursors.get(userId)?.remove();
    this.cursors.delete(userId);
  }
}
```

### Performance Tips for Cursor Sharing
- **Throttle to 50ms** (20 FPS) — higher rates waste bandwidth with no visual benefit
- **Use binary frames** for cursor data if many users share (16 bytes vs ~120 bytes JSON)
- **Interpolate remote cursors** client-side for smooth rendering between updates
- **Remove stale cursors** after 5s of no updates (user idle or disconnected)
- **Batch cursor updates** if multiple users move simultaneously — send one frame with array
