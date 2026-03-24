# Advanced WebSocket Patterns

## Table of Contents

- [Multiplexing Multiple Channels](#multiplexing-multiple-channels)
- [Protocol Sub-Protocols](#protocol-sub-protocols)
- [Custom Binary Protocols](#custom-binary-protocols)
- [WebSocket Compression (permessage-deflate)](#websocket-compression-permessage-deflate)
- [Connection Pooling on the Server Side](#connection-pooling-on-the-server-side)
- [Graceful Shutdown with Drain](#graceful-shutdown-with-drain)
- [WebSocket over HTTP/2 (RFC 8441)](#websocket-over-http2-rfc-8441)
- [WebTransport Comparison](#webtransport-comparison)
- [Presence Systems](#presence-systems)
- [Cursor Sharing](#cursor-sharing)
- [Collaborative Editing via OT/CRDT over WebSocket](#collaborative-editing-via-otcrdt-over-websocket)

---

## Multiplexing Multiple Channels

A single WebSocket connection can carry traffic for multiple logical channels, avoiding the overhead of separate TCP connections per channel. The key is a framing envelope that tags each message with a channel identifier.

### Channel Envelope Pattern

```ts
interface ChannelMessage {
  channel: string;       // e.g., "chat", "notifications", "presence"
  id?: string;           // correlation ID for request-response
  action: string;        // e.g., "subscribe", "unsubscribe", "message"
  payload: unknown;
}
```

### Server-Side Channel Router

```ts
import { WebSocketServer, WebSocket } from 'ws';

type ChannelHandler = (ws: WebSocket, action: string, payload: unknown) => void;

class ChannelRouter {
  private handlers = new Map<string, ChannelHandler>();

  register(channel: string, handler: ChannelHandler) {
    this.handlers.set(channel, handler);
  }

  route(ws: WebSocket, raw: string) {
    const msg: ChannelMessage = JSON.parse(raw);
    const handler = this.handlers.get(msg.channel);
    if (!handler) {
      ws.send(JSON.stringify({ channel: msg.channel, action: 'error', payload: 'Unknown channel' }));
      return;
    }
    handler(ws, msg.action, msg.payload);
  }
}

const router = new ChannelRouter();

router.register('chat', (ws, action, payload) => {
  // Handle chat messages
});

router.register('presence', (ws, action, payload) => {
  // Handle presence updates
});

const wss = new WebSocketServer({ port: 8080 });
wss.on('connection', (ws) => {
  ws.on('message', (data) => router.route(ws, data.toString()));
});
```

### Client-Side Multiplexer

```ts
class MultiplexClient {
  private ws: WebSocket;
  private listeners = new Map<string, Set<(msg: any) => void>>();

  constructor(url: string) {
    this.ws = new WebSocket(url);
    this.ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      this.listeners.get(msg.channel)?.forEach((fn) => fn(msg));
    };
  }

  subscribe(channel: string, handler: (msg: any) => void) {
    if (!this.listeners.has(channel)) this.listeners.set(channel, new Set());
    this.listeners.get(channel)!.add(handler);
    this.send(channel, 'subscribe', {});
    return () => {
      this.listeners.get(channel)?.delete(handler);
      if (this.listeners.get(channel)?.size === 0) {
        this.send(channel, 'unsubscribe', {});
        this.listeners.delete(channel);
      }
    };
  }

  send(channel: string, action: string, payload: unknown) {
    if (this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ channel, action, payload }));
    }
  }
}
```

### Design Considerations

- **Backpressure**: A slow consumer on one channel can block all channels. Consider per-channel message queues with overflow policies (drop oldest, drop newest, or error).
- **Priority**: Assign priority levels to channels so control messages (heartbeat, auth) are never starved.
- **Flow Control**: Implement per-channel credits or sliding windows for high-throughput channels.

---

## Protocol Sub-Protocols

The WebSocket handshake supports the `Sec-WebSocket-Protocol` header for negotiating application-level sub-protocols.

### Negotiation

```ts
// Client requests preferred sub-protocols (ordered by preference)
const ws = new WebSocket('wss://api.example.com/ws', ['graphql-ws', 'json-rpc']);

// Server selects one
const wss = new WebSocketServer({
  handleProtocols(protocols, request) {
    if (protocols.has('graphql-ws')) return 'graphql-ws';
    if (protocols.has('json-rpc')) return 'json-rpc';
    return false; // reject connection
  },
});
```

### Common Sub-Protocols

| Sub-Protocol | RFC/Spec | Use Case |
|-------------|----------|----------|
| `graphql-ws` | graphql-ws spec | GraphQL subscriptions |
| `graphql-transport-ws` | graphql-ws v5 | Modern GraphQL over WS |
| `wamp` | WAMP spec | RPC + Pub/Sub |
| `stomp` | STOMP 1.2 | Message broker interop |
| `mqtt` | MQTT over WS | IoT messaging |
| `json-rpc` | JSON-RPC 2.0 | Structured RPC calls |

### Versioned Sub-Protocols

Use sub-protocol versioning to maintain backward compatibility:

```ts
// Register handlers per version
const handlers = {
  'myapp-v1': handleV1Message,
  'myapp-v2': handleV2Message,
};

wss.on('connection', (ws) => {
  const handler = handlers[ws.protocol];
  ws.on('message', (data) => handler(ws, data));
});
```

---

## Custom Binary Protocols

For performance-critical applications, replace JSON with a compact binary format.

### Using Protocol Buffers

```proto
// messages.proto
syntax = "proto3";

message WsMessage {
  uint32 type = 1;
  bytes payload = 2;
  uint64 timestamp = 3;
  string correlation_id = 4;
}
```

### Using a Manual Binary Layout

```ts
// Encode: [1 byte type][4 bytes length][N bytes payload]
function encode(type: number, payload: Uint8Array): ArrayBuffer {
  const buf = new ArrayBuffer(5 + payload.byteLength);
  const view = new DataView(buf);
  view.setUint8(0, type);
  view.setUint32(1, payload.byteLength);
  new Uint8Array(buf, 5).set(payload);
  return buf;
}

function decode(buf: ArrayBuffer): { type: number; payload: Uint8Array } {
  const view = new DataView(buf);
  const type = view.getUint8(0);
  const length = view.getUint32(1);
  const payload = new Uint8Array(buf, 5, length);
  return { type, payload };
}
```

### MessagePack Alternative

```ts
import { encode, decode } from '@msgpack/msgpack';

// ~30-50% smaller than JSON for typical payloads
ws.send(encode({ type: 'update', data: { x: 100, y: 200 } }));

ws.on('message', (data, isBinary) => {
  if (isBinary) {
    const msg = decode(data as Buffer);
    // process msg
  }
});
```

### Format Comparison

| Format | Size (typical) | Encode Speed | Decode Speed | Schema Required |
|--------|---------------|-------------|-------------|-----------------|
| JSON | 1x (baseline) | Fast | Fast | No |
| MessagePack | 0.5–0.7x | Very Fast | Very Fast | No |
| Protocol Buffers | 0.3–0.5x | Fast | Very Fast | Yes |
| FlatBuffers | 0.3–0.5x | Very Fast | Zero-copy | Yes |

---

## WebSocket Compression (permessage-deflate)

The `permessage-deflate` extension (RFC 7692) compresses WebSocket message payloads using the DEFLATE algorithm.

### Server Configuration (ws library)

```ts
const wss = new WebSocketServer({
  port: 8080,
  perMessageDeflate: {
    zlibDeflateOptions: {
      chunkSize: 1024,
      memLevel: 7,
      level: 3,            // 1=fast, 9=best compression
    },
    zlibInflateOptions: {
      chunkSize: 10 * 1024,
    },
    clientNoContextTakeover: true,  // reduce server memory per connection
    serverNoContextTakeover: true,
    serverMaxWindowBits: 10,        // limit memory (default 15 = 32KB)
    concurrencyLimit: 10,           // limit concurrent zlib operations
    threshold: 1024,                // only compress messages > 1KB
  },
});
```

### Trade-offs

| Setting | Effect |
|---------|--------|
| `clientNoContextTakeover: true` | Less memory per connection, worse compression ratio |
| `serverNoContextTakeover: true` | Server uses less memory, each message compressed independently |
| Lower `serverMaxWindowBits` | Less memory, worse compression |
| Higher compression `level` | Better ratio, higher CPU usage |
| Higher `threshold` | Skip compressing small messages (overhead > savings) |

### When to Use

- **Enable**: Text-heavy messages (JSON, XML), messages > 1KB, low connection count
- **Disable**: Binary data (already compressed images/video), high connection count (memory), latency-sensitive applications, small messages (< 128 bytes)

### Memory Impact

Each connection with context takeover uses ~300KB of memory for zlib state. With 10,000 connections, that's ~3GB just for compression. Use `noContextTakeover` or disable compression for high-connection-count servers.

---

## Connection Pooling on the Server Side

When a WebSocket server acts as a client to upstream services, connection pooling prevents resource exhaustion.

### Upstream WebSocket Pool

```ts
class WsConnectionPool {
  private pool: WebSocket[] = [];
  private waiting: Array<(ws: WebSocket) => void> = [];

  constructor(
    private url: string,
    private maxSize: number = 10,
  ) {}

  async acquire(): Promise<WebSocket> {
    const available = this.pool.find((ws) => ws.readyState === WebSocket.OPEN);
    if (available) {
      this.pool = this.pool.filter((ws) => ws !== available);
      return available;
    }
    if (this.pool.length < this.maxSize) {
      return this.createConnection();
    }
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  release(ws: WebSocket) {
    if (ws.readyState !== WebSocket.OPEN) return;
    const waiter = this.waiting.shift();
    if (waiter) {
      waiter(ws);
    } else {
      this.pool.push(ws);
    }
  }

  private createConnection(): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      ws.on('open', () => resolve(ws));
      ws.on('error', reject);
    });
  }

  async drain() {
    for (const ws of this.pool) {
      ws.close(1001, 'Pool draining');
    }
    this.pool = [];
  }
}
```

---

## Graceful Shutdown with Drain

Graceful shutdown ensures in-flight messages are delivered before the server stops accepting new connections.

### Drain Pattern

```ts
import { WebSocketServer, WebSocket } from 'ws';

class GracefulWsServer {
  private wss: WebSocketServer;
  private draining = false;

  constructor(port: number) {
    this.wss = new WebSocketServer({ port });
    this.setupShutdown();
  }

  private setupShutdown() {
    const shutdown = async (signal: string) => {
      console.log(`Received ${signal}, starting graceful shutdown...`);
      this.draining = true;

      // Stop accepting new connections
      this.wss.close();

      // Notify all clients
      const closePromises: Promise<void>[] = [];
      this.wss.clients.forEach((ws) => {
        if (ws.readyState === WebSocket.OPEN) {
          closePromises.push(
            new Promise((resolve) => {
              ws.send(JSON.stringify({ type: 'server-shutdown', retryAfter: 5 }));
              ws.close(1001, 'Server shutting down');
              ws.on('close', () => resolve());
              // Force-close after timeout
              setTimeout(() => { ws.terminate(); resolve(); }, 5000);
            })
          );
        }
      });

      await Promise.all(closePromises);
      console.log('All connections closed, exiting.');
      process.exit(0);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  }

  isAcceptingConnections() {
    return !this.draining;
  }
}
```

### Health Check Integration

```ts
app.get('/health', (req, res) => {
  if (server.isAcceptingConnections()) {
    res.status(200).json({ status: 'healthy', connections: wss.clients.size });
  } else {
    res.status(503).json({ status: 'draining' });
  }
});
```

---

## WebSocket over HTTP/2 (RFC 8441)

RFC 8441 enables WebSocket connections over HTTP/2 via the `CONNECT` method with `:protocol` pseudo-header, allowing WebSocket to share an existing HTTP/2 connection.

### Benefits

- **Connection reuse**: Multiple WebSocket streams over one TCP connection
- **Reduced latency**: No additional TCP+TLS handshake
- **Header compression**: HTTP/2 HPACK compresses WebSocket upgrade headers
- **Multiplexing**: WebSocket streams coexist with regular HTTP/2 requests

### Browser Support

As of 2024, browser support is limited. Chrome supports it behind flags. Most production deployments still use HTTP/1.1 for WebSocket.

### Server Support

| Server | Support |
|--------|---------|
| nginx | Not supported (as of 1.25) |
| Envoy | Supported via `allow_connect` |
| h2o | Supported |
| Node.js http2 | Manual implementation needed |

### Node.js HTTP/2 WebSocket (Experimental)

```ts
import http2 from 'node:http2';

const server = http2.createSecureServer({
  key: fs.readFileSync('key.pem'),
  cert: fs.readFileSync('cert.pem'),
  settings: { enableConnectProtocol: true },
});

server.on('stream', (stream, headers) => {
  if (headers[':method'] === 'CONNECT' && headers[':protocol'] === 'websocket') {
    stream.respond({ ':status': 200 });
    // stream is now a bidirectional WebSocket-like channel
    stream.on('data', (chunk) => {
      // Process WebSocket frames manually or use a framing library
      stream.write(chunk); // echo
    });
  }
});
```

---

## WebTransport Comparison

WebTransport is a newer API that provides bidirectional communication over HTTP/3 (QUIC).

### WebSocket vs WebTransport

| Feature | WebSocket | WebTransport |
|---------|-----------|-------------|
| Transport | TCP | QUIC (UDP) |
| Head-of-line blocking | Yes | No (per-stream) |
| Unreliable datagrams | No | Yes |
| Multiple streams | Manual multiplex | Native |
| Connection migration | No | Yes (QUIC) |
| Browser support | Universal | Chrome, Edge (growing) |
| Server ecosystem | Mature | Early stage |
| Proxy compatibility | Good | Limited |

### When to Choose WebTransport

- **Gaming**: Unreliable datagrams for position updates (lost frames are stale anyway)
- **Video streaming**: Independent streams prevent head-of-line blocking
- **Mobile apps**: QUIC connection migration handles network transitions gracefully

### When to Stick with WebSocket

- **Broad browser support needed**: WebSocket is universal
- **Corporate proxy environments**: WebSocket passes through most proxies
- **Ordered/reliable delivery required**: WebSocket guarantees ordering
- **Existing infrastructure**: Mature tooling, load balancers, monitoring

### WebTransport Client Example

```ts
const transport = new WebTransport('https://example.com/wt');
await transport.ready;

// Bidirectional stream (like WebSocket)
const stream = await transport.createBidirectionalStream();
const writer = stream.writable.getWriter();
const reader = stream.readable.getReader();

await writer.write(new TextEncoder().encode('Hello'));
const { value } = await reader.read();
console.log(new TextDecoder().decode(value));

// Unreliable datagram (no WebSocket equivalent)
const dgWriter = transport.datagrams.writable.getWriter();
await dgWriter.write(new Uint8Array([1, 2, 3]));
```

---

## Presence Systems

Presence tracks which users are online/offline/away in real-time.

### Server-Side Presence Manager

```ts
interface PresenceEntry {
  userId: string;
  status: 'online' | 'away' | 'offline';
  lastSeen: number;
  metadata?: Record<string, unknown>; // custom fields: avatar, typing state, etc.
}

class PresenceManager {
  private presence = new Map<string, PresenceEntry>();
  private connections = new Map<string, Set<WebSocket>>();

  join(userId: string, ws: WebSocket, metadata?: Record<string, unknown>) {
    if (!this.connections.has(userId)) {
      this.connections.set(userId, new Set());
    }
    this.connections.get(userId)!.add(ws);
    this.presence.set(userId, {
      userId, status: 'online', lastSeen: Date.now(), metadata,
    });
    this.broadcast({ type: 'presence', userId, status: 'online', metadata });
  }

  leave(userId: string, ws: WebSocket) {
    const conns = this.connections.get(userId);
    conns?.delete(ws);
    // Only mark offline if no remaining connections (multi-tab/device)
    if (!conns?.size) {
      this.connections.delete(userId);
      this.presence.set(userId, {
        userId, status: 'offline', lastSeen: Date.now(),
      });
      this.broadcast({ type: 'presence', userId, status: 'offline' });
    }
  }

  setAway(userId: string) {
    const entry = this.presence.get(userId);
    if (entry) {
      entry.status = 'away';
      this.broadcast({ type: 'presence', userId, status: 'away' });
    }
  }

  getAll(): PresenceEntry[] {
    return Array.from(this.presence.values());
  }

  private broadcast(msg: unknown) {
    const data = JSON.stringify(msg);
    for (const conns of this.connections.values()) {
      for (const ws of conns) {
        if (ws.readyState === WebSocket.OPEN) ws.send(data);
      }
    }
  }
}
```

### Scaling Presence with Redis

```ts
import Redis from 'ioredis';

const redis = new Redis();
const PRESENCE_KEY = 'presence';
const PRESENCE_TTL = 60; // seconds

async function heartbeat(userId: string) {
  await redis.zadd(PRESENCE_KEY, Date.now(), userId);
}

async function getOnlineUsers(): Promise<string[]> {
  const cutoff = Date.now() - PRESENCE_TTL * 1000;
  return redis.zrangebyscore(PRESENCE_KEY, cutoff, '+inf');
}

async function pruneStale() {
  const cutoff = Date.now() - PRESENCE_TTL * 1000;
  await redis.zremrangebyscore(PRESENCE_KEY, '-inf', cutoff);
}

// Run heartbeat every 30 seconds per user
// Run pruneStale on an interval
```

---

## Cursor Sharing

Real-time cursor sharing shows other users' pointer positions or text cursors.

### Throttled Cursor Broadcasting

```ts
// Client: throttle cursor events to ~20 updates/sec
let lastSend = 0;
const THROTTLE_MS = 50;

document.addEventListener('mousemove', (e) => {
  const now = Date.now();
  if (now - lastSend < THROTTLE_MS) return;
  lastSend = now;
  ws.send(JSON.stringify({
    type: 'cursor',
    x: e.clientX / window.innerWidth,  // normalize to 0-1
    y: e.clientY / window.innerHeight,
    viewport: { width: window.innerWidth, height: window.innerHeight },
  }));
});
```

### Server-Side Cursor Relay

```ts
wss.on('connection', (ws) => {
  const userId = ws.userId;

  ws.on('message', (raw) => {
    const msg = JSON.parse(raw.toString());
    if (msg.type === 'cursor') {
      // Relay to other users in the same document/room
      broadcastToRoom(ws.roomId, JSON.stringify({
        type: 'cursor',
        userId,
        ...msg,
      }), ws);
    }
  });
});
```

### Interpolation on the Receiving End

```ts
// Smooth cursor rendering with interpolation
class RemoteCursor {
  private targetX = 0;
  private targetY = 0;
  private currentX = 0;
  private currentY = 0;

  update(x: number, y: number) {
    this.targetX = x;
    this.targetY = y;
  }

  render() {
    // Linear interpolation for smooth movement
    this.currentX += (this.targetX - this.currentX) * 0.3;
    this.currentY += (this.targetY - this.currentY) * 0.3;
    this.element.style.transform = `translate(${this.currentX}px, ${this.currentY}px)`;
    requestAnimationFrame(() => this.render());
  }
}
```

---

## Collaborative Editing via OT/CRDT over WebSocket

### Operational Transformation (OT)

OT transforms concurrent operations against each other so they can be applied in any order and converge to the same state.

#### Operation Types

```ts
type Operation =
  | { type: 'insert'; position: number; text: string }
  | { type: 'delete'; position: number; length: number }
  | { type: 'retain'; count: number };
```

#### Transform Function

```ts
function transform(op1: Operation, op2: Operation): [Operation, Operation] {
  // op1 was applied first on one client, op2 on another
  // Returns [op1', op2'] such that apply(apply(doc, op1), op2') === apply(apply(doc, op2), op1')
  if (op1.type === 'insert' && op2.type === 'insert') {
    if (op1.position <= op2.position) {
      return [op1, { ...op2, position: op2.position + op1.text.length }];
    }
    return [{ ...op1, position: op1.position + op2.text.length }, op2];
  }
  // ... handle all operation type combinations
}
```

#### OT Server Architecture

```
Client A ──op──> Server ──transform──> broadcast op' to all clients
Client B ──op──> Server ──transform──> broadcast op' to all clients
                   │
              Document State
              Revision History
```

### CRDTs (Conflict-free Replicated Data Types)

CRDTs guarantee convergence without a central server for conflict resolution.

#### Yjs Integration over WebSocket

```ts
// Server (y-websocket provider)
import { WebSocketServer } from 'ws';
import { setupWSConnection } from 'y-websocket/bin/utils';

const wss = new WebSocketServer({ port: 1234 });
wss.on('connection', (ws, req) => {
  setupWSConnection(ws, req);
});

// Client
import * as Y from 'yjs';
import { WebsocketProvider } from 'y-websocket';

const ydoc = new Y.Doc();
const provider = new WebsocketProvider('ws://localhost:1234', 'my-document', ydoc);

const ytext = ydoc.getText('content');
ytext.observe((event) => {
  console.log('Text changed:', ytext.toString());
});

// Edit from any client — automatically synced
ytext.insert(0, 'Hello ');
```

#### Automerge Integration

```ts
import * as Automerge from '@automerge/automerge';

let doc = Automerge.init();
doc = Automerge.change(doc, (d) => {
  d.text = new Automerge.Text();
  d.text.insertAt(0, ...'Hello'.split(''));
});

// Sync changes over WebSocket
const changes = Automerge.getChanges(oldDoc, newDoc);
ws.send(encode(changes)); // send binary changes

ws.on('message', (data) => {
  const changes = decode(data);
  doc = Automerge.applyChanges(doc, changes)[0];
});
```

### OT vs CRDT Comparison

| Aspect | OT | CRDT |
|--------|-----|------|
| Server dependency | Requires central server | Can work peer-to-peer |
| Complexity | Complex transform functions | Complex data structures |
| Memory | Lower overhead | Higher (tombstones, metadata) |
| Latency | Server round-trip required | Immediate local apply |
| Proven at scale | Google Docs | Figma, Linear |
| Offline support | Limited | Excellent |
| Consistency model | Strong (server-ordered) | Eventual (convergent) |

### Best Practices for Collaborative Editing

1. **Batch operations**: Group rapid keystrokes into single operations (debounce 50–100ms)
2. **Cursor awareness**: Broadcast cursor positions alongside document changes
3. **Undo/redo**: Track operation origin for per-user undo stacks
4. **Persistence**: Periodically snapshot the document state; replay operations on load
5. **Awareness protocol**: Use Yjs awareness protocol for presence, cursors, and selection
6. **Conflict indicators**: Visually indicate when concurrent edits overlap
