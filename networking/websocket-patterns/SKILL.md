---
name: websocket-patterns
description: >
  Guide for building real-time WebSocket applications. Use when implementing WebSocket servers/clients,
  real-time communication, Socket.IO, the ws library, bidirectional messaging, live updates, chat systems,
  notification services, collaborative editing, or multiplayer features. Covers protocol fundamentals,
  server/client implementations, authentication, reconnection, scaling with Redis, message patterns,
  and security hardening. Do NOT use for REST API design, Server-Sent Events (SSE) for one-way streams,
  gRPC streaming, HTTP polling for infrequent updates, or serving static content.
---

# WebSocket Patterns

## Protocol Fundamentals

### Handshake

WebSocket upgrades an HTTP/1.1 connection to a persistent full-duplex channel.

Client request:
```
GET /ws HTTP/1.1
Host: example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

Server response:
```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

The server computes `Sec-WebSocket-Accept` by concatenating the client key with `258EAFA5-E914-47DA-95CA-5AB9DC85B711`, then SHA-1 hashing and base64-encoding the result.

### Frame Structure

Each frame contains: FIN bit (1=final fragment), RSV1-3 (reserved for extensions), opcode (4 bits), mask bit, payload length, optional masking key, and payload data. Client-to-server frames MUST be masked.

### Opcodes

| Opcode | Type | Purpose |
|--------|------|---------|
| 0x0 | Continuation | Multi-frame message continuation |
| 0x1 | Text | UTF-8 encoded text data |
| 0x2 | Binary | Binary data |
| 0x8 | Close | Initiate or confirm connection close |
| 0x9 | Ping | Heartbeat request |
| 0xA | Pong | Heartbeat response |

### Close Codes

| Code | Meaning |
|------|---------|
| 1000 | Normal closure |
| 1001 | Going away (page navigation, server shutdown) |
| 1002 | Protocol error |
| 1003 | Unsupported data type |
| 1006 | Abnormal closure (no close frame, internal use only) |
| 1007 | Invalid payload (e.g., non-UTF-8 in text frame) |
| 1008 | Policy violation |
| 1009 | Message too large |
| 1011 | Server internal error |
| 4000-4999 | Application-specific codes |

## Server Implementations

### Node.js — ws Library

```js
import { WebSocketServer } from 'ws';
const wss = new WebSocketServer({ port: 8080 });

wss.on('connection', (ws, req) => {
  ws.on('message', (data, isBinary) => {
    ws.send(JSON.stringify({ echo: isBinary ? data : data.toString() }));
  });
  ws.on('close', (code, reason) => console.log(`Disconnected: ${code}`));
  ws.on('error', (err) => console.error('WS error:', err));
  const interval = setInterval(() => { if (ws.readyState === ws.OPEN) ws.ping(); }, 30000);
  ws.on('close', () => clearInterval(interval));
});
```
### Socket.IO Server

```js
import { Server } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';

const io = new Server(3000, {
  cors: { origin: 'https://example.com' },
  pingInterval: 25000, pingTimeout: 20000, maxHttpBufferSize: 1e6,
});
const pub = createClient({ url: 'redis://localhost:6379' });
const sub = pub.duplicate();
await Promise.all([pub.connect(), sub.connect()]);
io.adapter(createAdapter(pub, sub));
```
### Python — websockets Library

```python
import asyncio
import websockets

async def handler(websocket):
    async for message in websocket:
        await websocket.send(f"echo: {message}")

async def main():
    async with websockets.serve(handler, "0.0.0.0", 8765):
        await asyncio.Future()

asyncio.run(main())
```
### Go — gorilla/websocket

```go
var upgrader = websocket.Upgrader{
    CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "https://example.com" },
}
func wsHandler(w http.ResponseWriter, r *http.Request) {
    conn, err := upgrader.Upgrade(w, r, nil)
    if err != nil { log.Println(err); return }
    defer conn.Close()
    for { mt, msg, err := conn.ReadMessage(); if err != nil { break }; conn.WriteMessage(mt, msg) }
}
```

## Client-Side WebSocket

### Browser API

```js
const ws = new WebSocket('wss://example.com/ws');
ws.onopen = () => ws.send(JSON.stringify({ type: 'subscribe', channel: 'updates' }));
ws.onmessage = (event) => console.log('Received:', JSON.parse(event.data));
ws.onclose = (event) => console.log(`Closed: ${event.code} ${event.reason}`);
ws.onerror = (error) => console.error('WS error:', error);
```
### Reconnecting Client with Exponential Backoff

Jitter prevents thundering herd on reconnect storms. Reset attempt counter on successful open. Skip reconnect on intentional close (code 1000).

```js
class ReconnectingWebSocket {
  constructor(url, { baseDelay = 500, maxDelay = 30000, maxRetries = Infinity } = {}) {
    Object.assign(this, { url, baseDelay, maxDelay, maxRetries, attempt: 0 });
    this.handlers = { message: [], open: [], close: [] };
    this.connect();
  }
  connect() {
    this.ws = new WebSocket(this.url);
    this.ws.onopen = () => { this.attempt = 0; this.handlers.open.forEach(h => h()); };
    this.ws.onmessage = (e) => this.handlers.message.forEach(h => h(e));
    this.ws.onclose = (e) => {
      this.handlers.close.forEach(h => h(e));
      if (this.attempt < this.maxRetries && e.code !== 1000) this.scheduleReconnect();
    };
  }
  scheduleReconnect() {
    const exp = Math.min(this.baseDelay * 2 ** this.attempt, this.maxDelay);
    setTimeout(() => this.connect(), exp * (0.5 + Math.random() * 0.5));
    this.attempt++;
  }
  send(data) { if (this.ws.readyState === WebSocket.OPEN) this.ws.send(data); }
  on(event, handler) { this.handlers[event]?.push(handler); }
  close() { this.maxRetries = 0; this.ws.close(1000); }
}
```

## Socket.IO Patterns

### Rooms and Namespaces

```js
const chatNs = io.of('/chat');

chatNs.on('connection', (socket) => {
  socket.on('join-room', (roomId) => {
    socket.join(roomId);
    chatNs.to(roomId).emit('user-joined', { userId: socket.id });
  });

  socket.on('message', (data) => {
    chatNs.to(data.roomId).emit('message', data);
  });
});
```
### Acknowledgements

```js
// Server emits with callback
socket.emit('save-document', docData, (response) => {
  console.log('Client confirmed:', response.status);
});

// Client responds
socket.on('save-document', (data, callback) => {
  try { saveLocally(data); callback({ status: 'ok' }); }
  catch (err) { callback({ status: 'error', message: err.message }); }
});
```
### Middleware

```js
io.use((socket, next) => {
  const token = socket.handshake.auth.token;
  try {
    socket.data.user = verifyJWT(token);
    next();
  } catch (err) {
    next(new Error('Authentication failed'));
  }
});

// Namespace-level middleware
adminNs.use((socket, next) => {
  if (socket.data.user?.role !== 'admin') return next(new Error('Forbidden'));
  next();
});
```

## Authentication Patterns

### Token-Based (JWT)

```js
// Client
const socket = io('wss://api.example.com', {
  auth: { token: localStorage.getItem('jwt') },
});

// Server
io.use((socket, next) => {
  const decoded = verifyJWT(socket.handshake.auth.token);
  if (!decoded) return next(new Error('Invalid token'));
  socket.data.userId = decoded.sub;
  next();
});
```
### Cookie-Based

```js
const server = new WebSocketServer({ noServer: true });
httpServer.on('upgrade', (req, socket, head) => {
  const session = parseCookie(req.headers.cookie);
  if (!session?.valid) { socket.destroy(); return; }
  server.handleUpgrade(req, socket, head, (ws) => {
    ws.userId = session.userId;
    server.emit('connection', ws, req);
  });
});
```
### Per-Message Authentication

Verify tokens on sensitive operations:
```js
ws.on('message', (raw) => {
  const { token, action, payload } = JSON.parse(raw);
  if (!verifyJWT(token)) return ws.close(4001, 'Unauthorized');
  handleAction(action, payload);
});
```

## Heartbeat and Connection Health

```js
wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
});

const heartbeat = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) return ws.terminate();
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on('close', () => clearInterval(heartbeat));
```

## Scaling with Redis

### Redis Adapter (Pub/Sub)

Each Socket.IO instance publishes events to Redis; all instances subscribe and deliver to local clients. Enables room broadcasts across nodes.

```js
import { createAdapter } from '@socket.io/redis-adapter';
const pub = createClient({ url: 'redis://redis:6379' });
const sub = pub.duplicate();
await Promise.all([pub.connect(), sub.connect()]);
io.adapter(createAdapter(pub, sub));
```
### Redis Streams Adapter (Durable)

Use for guaranteed delivery and connection state recovery:
```js
import { createAdapter } from '@socket.io/redis-streams-adapter';
const client = createClient({ url: 'redis://redis:6379' });
await client.connect();
io.adapter(createAdapter(client));
```
### Sticky Sessions (nginx)

```nginx
upstream websocket_servers {
    ip_hash;
    server ws1:3000;
    server ws2:3000;
}
server {
    location /socket.io/ {
        proxy_pass http://websocket_servers;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

## Message Patterns

### Pub/Sub

```js
const topics = new Map(); // topic -> Set<ws>
ws.on('message', (raw) => {
  const { action, topic, payload } = JSON.parse(raw);
  if (action === 'subscribe') {
    if (!topics.has(topic)) topics.set(topic, new Set());
    topics.get(topic).add(ws);
  } else if (action === 'publish') {
    topics.get(topic)?.forEach((c) => {
      if (c.readyState === WebSocket.OPEN) c.send(JSON.stringify({ topic, payload }));
    });
  }
});
```
### Request-Response over WebSocket

Correlate requests/responses with unique IDs and timeouts:

```js
let reqId = 0;
const pending = new Map();
function request(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++reqId;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Timeout')); }, 5000);
    pending.set(id, { resolve, timer });
    ws.send(JSON.stringify({ id, method, params }));
  });
}
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) {
    clearTimeout(pending.get(msg.id).timer);
    pending.get(msg.id).resolve(msg.result);
    pending.delete(msg.id);
  }
};
```
### Broadcasting

```js
function broadcast(sender, data) {
  wss.clients.forEach((c) => {
    if (c !== sender && c.readyState === WebSocket.OPEN) c.send(data);
  });
}
```

## Binary Data and Streaming

```js
// Server: handle binary frames
ws.on('message', (data, isBinary) => {
  if (isBinary) {
    const buffer = Buffer.from(data);
    processFile(buffer);
    ws.send(JSON.stringify({ status: 'received', size: buffer.length }));
  }
});

// Client: chunked upload
const CHUNK_SIZE = 64 * 1024;
for (let offset = 0; offset < buffer.byteLength; offset += CHUNK_SIZE) {
  const chunk = buffer.slice(offset, offset + CHUNK_SIZE);
  ws.send(JSON.stringify({ type: 'chunk', seq: offset / CHUNK_SIZE }));
  ws.send(chunk);
}
```

## Error Handling and Graceful Degradation

```js
ws.on('error', (err) => console.error(`WS error [${ws.userId}]:`, err.message));

process.on('SIGTERM', () => {
  wss.clients.forEach((ws) => ws.close(1001, 'Server shutting down'));
  wss.close(() => process.exit(0));
});
```

Socket.IO automatic fallback: `io('https://example.com', { transports: ['websocket', 'polling'] })`.

## Testing WebSocket Services

```js
import { WebSocket } from 'ws';
import assert from 'node:assert';
const ws = new WebSocket('ws://localhost:8080');
ws.on('open', () => ws.send(JSON.stringify({ action: 'ping' })));
ws.on('message', (data) => { assert.strictEqual(JSON.parse(data).action, 'pong'); ws.close(); });
```

Load test with Artillery (`artillery run ws-test.yml`):
```yaml
config:
  target: "ws://localhost:8080"
  phases: [{ duration: 60, arrivalRate: 50 }]
  engines: { ws: {} }
scenarios:
  - engine: ws
    flow:
      - send: '{"action":"subscribe","topic":"news"}'
      - think: 1
      - send: '{"action":"publish","topic":"news","payload":"hello"}'
```

## Security

### Origin Validation

```js
const wss = new WebSocketServer({
  verifyClient: (info) => {
    const origin = info.origin || info.req.headers.origin;
    return ['https://example.com', 'https://app.example.com'].includes(origin);
  },
});
```
### Rate Limiting

```js
const messageCounts = new Map();
ws.on('message', () => {
  const count = (messageCounts.get(ws) || 0) + 1;
  messageCounts.set(ws, count);
  if (count > 100) { ws.close(1008, 'Rate limit exceeded'); return; }
});
setInterval(() => messageCounts.clear(), 60000);
```
### Message Size Limits

```js
const wss = new WebSocketServer({ port: 8080, maxPayload: 1024 * 1024 }); // 1MB
```

Socket.IO equivalent: set `maxHttpBufferSize: 1e6` in server options. Always use `wss://` in production. Validate and sanitize all incoming messages on both client and server.

## Monitoring and Debugging

Track in production: connection count (current/peak), message throughput (msg/sec), round-trip ping latency, error rate by close code (especially 1006, 1011), memory per connection.

```js
let connectionCount = 0;
wss.on('connection', () => connectionCount++);

app.get('/metrics', (req, res) => {
  res.json({ connections: connectionCount, uptime: process.uptime(), memory: process.memoryUsage() });
});
```

Debug Socket.IO: `DEBUG=socket.io* node server.js`. Inspect browser frames in Chrome DevTools → Network → WS tab. CLI tool: `npx wscat -c wss://example.com/ws`.

## References

- **[Advanced Patterns](references/advanced-patterns.md)** — Multiplexing, sub-protocols, binary protocols, permessage-deflate, connection pooling, graceful drain, WebSocket over HTTP/2 (RFC 8441), WebTransport comparison, presence, cursor sharing, OT/CRDT collaborative editing.
- **[Troubleshooting](references/troubleshooting.md)** — Proxy/LB drops, Nginx/HAProxy config, SSL/TLS, CORS, memory leaks, message ordering, reconnect state sync, mobile network transitions, browser tab throttling, DevTools debugging.

## Scripts

- **[ws-load-test.sh](scripts/ws-load-test.sh)** — Load testing with concurrent connections and throughput metrics. Uses websocat or wscat. Run with `--help`.
- **[ws-debug.sh](scripts/ws-debug.sh)** — Frame-level debugging with timestamps, JSON pretty-print, custom headers, and interactive mode. Run with `--help`.

## Assets

- **[ws-server.ts](assets/ws-server.ts)** — Production ws-library server: rooms, JWT auth, heartbeat, rate limiting, graceful shutdown.
- **[socket-io-server.ts](assets/socket-io-server.ts)** — Socket.IO server: Redis adapter, namespaces, middleware, connection state recovery.
- **[nginx-websocket.conf](assets/nginx-websocket.conf)** — Nginx WebSocket proxy: upgrade headers, SSL, sticky sessions, rate limiting.

<!-- tested: pass -->
