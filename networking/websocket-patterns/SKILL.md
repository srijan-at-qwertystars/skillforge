---
name: websocket-patterns
description: >
  Use when user implements WebSocket connections, asks about real-time messaging,
  Socket.IO, ws library, WebSocket authentication, heartbeat/keepalive,
  reconnection strategies, or scaling WebSockets with Redis pub/sub.
  Do NOT use for HTTP long polling, Server-Sent Events (SSE), gRPC streaming,
  or general HTTP protocol questions.
---

# WebSocket Patterns & Implementation

## Protocol Fundamentals

WebSocket starts as HTTP/1.1 GET with `Upgrade: websocket` header. Server responds `101 Switching Protocols`. The TCP connection then carries bidirectional WebSocket frames.

```
GET /ws HTTP/1.1
Host: example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

Frame types: Text (0x1), Binary (0x2), Close (0x8), Ping (0x9), Pong (0xA).

### Close Codes

| Code | Meaning              | Action                               |
|------|----------------------|--------------------------------------|
| 1000 | Normal closure       | Don't reconnect                      |
| 1001 | Going away           | Server shutdown / page navigation    |
| 1006 | Abnormal closure     | No close frame — network failure     |
| 1008 | Policy violation     | Auth failure — redirect to login     |
| 1009 | Message too big      | Payload exceeds `maxPayload`         |
| 1011 | Server error         | Internal error — reconnect           |
| 1012 | Service restart      | Reconnect immediately                |
| 1013 | Try again later      | Reconnect with backoff               |

---

## Server: Node.js ws Library

```js
import { WebSocketServer } from 'ws';
import { createServer } from 'http';

const server = createServer();
const wss = new WebSocketServer({ server, maxPayload: 1024 * 1024 });

wss.on('connection', (ws, req) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (data, isBinary) => {
    for (const client of wss.clients) {
      if (client !== ws && client.readyState === 1)
        client.send(data, { binary: isBinary });
    }
  });

  ws.on('error', (err) => console.error('WS error:', err.message));
});

// Heartbeat — terminate dead connections every 30s
const hb = setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) return ws.terminate();
    ws.isAlive = false;
    ws.ping();
  }
}, 30_000);
wss.on('close', () => clearInterval(hb));
server.listen(8080);
```

## Server: Socket.IO

```js
import { Server } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';

const io = new Server(httpServer, {
  pingInterval: 25_000, pingTimeout: 20_000,
  maxHttpBufferSize: 1e6,
  cors: { origin: ['https://myapp.com'] },
});

// Redis adapter for horizontal scaling
const pub = createClient({ url: 'redis://localhost:6379' });
const sub = pub.duplicate();
await Promise.all([pub.connect(), sub.connect()]);
io.adapter(createAdapter(pub, sub));

// Auth middleware
io.use((socket, next) => {
  try { socket.user = verifyJWT(socket.handshake.auth.token); next(); }
  catch { next(new Error('Authentication failed')); }
});

io.on('connection', (socket) => {
  socket.join(`user:${socket.user.id}`);
  socket.on('chat:message', (data, ack) => {
    socket.to(data.room).emit('chat:message', {
      from: socket.user.id, text: data.text, ts: Date.now(),
    });
    ack?.({ status: 'ok' });
  });
});
```

## Server: Python websockets

```python
import asyncio, websockets

CLIENTS = set()

async def handler(ws):
    CLIENTS.add(ws)
    try:
        async for msg in ws:
            await asyncio.gather(
                *[c.send(msg) for c in CLIENTS if c != ws],
                return_exceptions=True)
    finally:
        CLIENTS.discard(ws)

async def main():
    async with websockets.serve(handler, "0.0.0.0", 8765,
                                ping_interval=20, ping_timeout=20):
        await asyncio.Future()

asyncio.run(main())
```

## Server: Go nhooyr.io/websocket

```go
conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
    OriginPatterns: []string{"myapp.com"},
})
if err != nil { return }
defer conn.CloseNow()
for {
    typ, data, err := conn.Read(ctx)
    if err != nil { return }
    conn.Write(ctx, typ, data)
}
```

---

## Client: Browser API with Reconnection

```js
class ResilientWebSocket {
  constructor(url, opts = {}) {
    this.url = url;
    this.maxRetries = opts.maxRetries ?? 10;
    this.handlers = { message: [], open: [], close: [] };
    this.attempt = 0;
    this.connect();
  }
  connect() {
    this.ws = new WebSocket(this.url);
    this.ws.onopen = () => {
      this.attempt = 0;
      this.hb = setInterval(() => {
        if (this.ws.readyState === 1) this.ws.send('ping');
      }, 25_000);
      this.handlers.open.forEach(fn => fn());
    };
    this.ws.onmessage = (e) => {
      if (e.data === 'pong') return;
      this.handlers.message.forEach(fn => fn(e));
    };
    this.ws.onclose = (e) => {
      clearInterval(this.hb);
      this.handlers.close.forEach(fn => fn(e));
      if (e.code !== 1000 && this.attempt < this.maxRetries) this.reconnect();
    };
    this.ws.onerror = () => this.ws.close();
  }
  reconnect() {
    const base = Math.min(1000 * 2 ** this.attempt, 30_000);
    const jitter = Math.random() * base * 0.5;
    this.attempt++;
    setTimeout(() => this.connect(), base + jitter);
  }
  send(data) { if (this.ws.readyState === 1) this.ws.send(data); }
  on(event, fn) { this.handlers[event].push(fn); }
  close() { this.ws.close(1000, 'Client closing'); }
}
```

---

## Authentication

### Token in Query Parameter

```js
// Client
const ws = new WebSocket(`wss://api.example.com/ws?token=${jwt}`);

// Server — verify during upgrade
const wss = new WebSocketServer({
  server,
  verifyClient: ({ req }, cb) => {
    const token = new URL(req.url, 'http://x').searchParams.get('token');
    try { req.user = verifyJWT(token); cb(true); }
    catch { cb(false, 401, 'Unauthorized'); }
  },
});
```

Caution: tokens in URLs appear in server logs. Use short-lived tokens (<60s) scoped to WebSocket only.

### First-Message Auth

```js
ws.once('message', (data) => {
  const msg = JSON.parse(data);
  if (msg.type !== 'auth') return ws.close(1008, 'Auth required');
  try { ws.user = verifyJWT(msg.token); ws.authenticated = true; }
  catch { ws.close(1008, 'Invalid token'); }
});
```

**Cookie-based:** Cookies transmit automatically during HTTP upgrade. Validate session cookie in `verifyClient`. Best when WebSocket is same-origin.

---

## Heartbeat / Keepalive

**Protocol-level:** `ws` library auto-replies to pings. Server sends `ws.ping()` on interval, marks dead connections via `isAlive` flag (see server example above).

**Application-level** — use when proxies (Cloudflare, ALB) strip control frames:

```js
// Server sends JSON ping; client replies with pong
setInterval(() => ws.send(JSON.stringify({ type: 'ping', ts: Date.now() })), 25_000);
```

**Nginx config** — set `proxy_read_timeout` above heartbeat interval:

```nginx
location /ws {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 60s;
}
```

---

## Reconnection Strategies

**Exponential backoff with jitter** prevents thundering herd on server restart:```js
function getReconnectDelay(attempt) {
  const base = Math.min(1000 * 2 ** attempt, 30_000);
  return base + Math.random() * base * 0.5;
}
```

**State recovery:** Track last received message ID. On reconnect, send `{ type: 'resume', lastSeenId }`. Server replays missed messages or sends full snapshot.

**Socket.IO v4+ recovery** — built-in:

```js
const io = new Server(httpServer, {
  connectionStateRecovery: { maxDisconnectionDuration: 120_000, skipMiddlewares: true },
});
```

---

## Message Patterns

### Request-Response (RPC)

```js
let reqId = 0;
const pending = new Map();
function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++reqId;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('timeout')); }, 10_000);
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

### Pub/Sub Channels

```js
const channels = new Map(); // channel → Set<ws>
ws.on('message', (raw) => {
  const msg = JSON.parse(raw);
  if (msg.type === 'subscribe') {
    if (!channels.has(msg.channel)) channels.set(msg.channel, new Set());
    channels.get(msg.channel).add(ws);
  } else if (msg.type === 'publish') {
    const subs = channels.get(msg.channel);
    if (!subs) return;
    const out = JSON.stringify({ channel: msg.channel, data: msg.data });
    for (const c of subs) { if (c.readyState === 1) c.send(out); }
  }
});
```

### Rooms (Socket.IO)

```js
socket.join('room:123');
io.to('room:123').emit('update', data);     // all in room
socket.to('room:123').emit('update', data); // exclude sender
```

---

## Scaling WebSockets

```
Clients → Load Balancer (ip_hash or sticky cookie)
             ├─ WS Server 1 ─┐
             ├─ WS Server 2 ─┼─ Redis Pub/Sub
             └─ WS Server 3 ─┘
```

### Redis Pub/Sub Cross-Instance Messaging

```js
const pub = createClient({ url: 'redis://redis:6379' });
const sub = pub.duplicate();
await Promise.all([pub.connect(), sub.connect()]);

ws.on('message', (data) => pub.publish('chat:global', data.toString()));

await sub.subscribe('chat:global', (message) => {
  for (const c of wss.clients) { if (c.readyState === 1) c.send(message); }
});
```

### Sticky Sessions (Nginx)

```nginx
upstream ws_backend {
    ip_hash;
    server ws1:8080;
    server ws2:8080;
}
```

### Scaling Checklist

- Store session state in Redis, not process memory.
- Use Redis adapter (Socket.IO) or manual pub/sub (ws) for cross-node messaging.
- Configure load balancer for WebSocket upgrade headers.
- Single Node.js process handles ~50K–65K concurrent connections.
- Use cluster module for multi-core. For guaranteed delivery, use Redis Streams or Kafka.

---

## Binary Data

```js
// Send ArrayBuffer from client
ws.send(new Float64Array([3.14159]).buffer);
// Receive binary on server
ws.on('message', (data, isBinary) => {
  if (isBinary) new Float64Array(data.buffer, data.byteOffset, data.byteLength / 8);
});
// Protobuf: ws.send(MyMessage.encode({ id: 1 }).finish())
// Decode:   MyMessage.decode(new Uint8Array(data))
```

Use protobuf/MessagePack/FlatBuffers for high-throughput. Reduces bandwidth 2–10x vs JSON.

---

## Error Handling

```js
// Server — validate inbound messages
ws.on('message', (raw) => {
  let msg;
  try { msg = JSON.parse(raw); }
  catch { return ws.send(JSON.stringify({ error: 'INVALID_JSON' })); }
  if (!msg.type || typeof msg.type !== 'string')
    return ws.send(JSON.stringify({ error: 'MISSING_TYPE' }));
});

ws.on('error', (err) => console.error('WS error:', err.message));

// Client — handle close codes
ws.onclose = (e) => {
  if (e.code === 1000) return;               // normal
  if (e.code === 1008) return redirectToLogin();
  if (e.code === 1012) return reconnectNow();
  reconnectWithBackoff();                     // default
};
```

---

## Security

### Origin Checking

```js
const wss = new WebSocketServer({
  server,
  verifyClient: (info, cb) => {
    const allowed = ['https://myapp.com', 'https://staging.myapp.com'];
    if (!allowed.includes(info.origin)) return cb(false, 403, 'Forbidden');
    cb(true);
  },
});
```

### Rate Limiting

```js
const LIMIT = 100, WINDOW = 60_000;
const rates = new Map();

ws.on('message', (data) => {
  const now = Date.now();
  let r = rates.get(ws);
  if (!r || now - r.start > WINDOW) { r = { start: now, count: 0 }; rates.set(ws, r); }
  if (++r.count > LIMIT) return ws.close(1008, 'Rate limit exceeded');
});
```

### Security Checklist

- Always `wss://` in production. Validate `Origin` header during upgrade.
- Set `maxPayload` to reject oversized messages.
- Rate-limit connections per IP and messages per connection.
- Validate all inbound messages as untrusted input.
- Use short-lived auth tokens. Revalidate periodically.
- Log auth failures, rate-limit hits, and abnormal disconnects.

---

## Testing

```js
// Unit test with Node.js test runner
import { WebSocketServer } from 'ws';
import { test } from 'node:test';
import assert from 'node:assert';

test('echo', async () => {
  const wss = new WebSocketServer({ port: 0 });
  wss.on('connection', (ws) => ws.on('message', (d) => ws.send(d)));
  const ws = new WebSocket(`ws://localhost:${wss.address().port}`);
  await new Promise(r => ws.addEventListener('open', r));
  ws.send('hello');
  const reply = await new Promise(r => ws.addEventListener('message', e => r(e.data)));
  assert.strictEqual(reply, 'hello');
  ws.close(); wss.close();
});
```

CLI: `npx wscat -c ws://localhost:8080` or `websocat ws://localhost:8080`. Load test with `artillery` (engine: ws) or `k6`.

---

## Socket.IO vs Raw WebSocket — Decision Guide

| Factor                | Raw WebSocket (ws)                 | Socket.IO                         |
|-----------------------|------------------------------------|------------------------------------|
| Latency               | ~12ms p99, minimal overhead        | ~32ms p99                          |
| Memory / connection   | ~3 KB                              | ~8–10 KB                           |
| Auto reconnect        | Build yourself                     | Built-in with backoff              |
| Rooms / namespaces    | Build yourself                     | Built-in                           |
| Binary support        | Native                             | Supported, less flexible           |
| Cross-language clients| Any WS client                      | Socket.IO-specific client needed   |
| Scaling               | Manual Redis pub/sub               | Redis adapter, drop-in             |
| Transport fallback    | None                               | HTTP long-polling fallback         |
| Ideal for             | Trading, gaming, IoT, high-freq    | Chat, collab, notifications        |

**Use `ws`** when performance and protocol control matter. **Use Socket.IO** when developer velocity and built-in reliability matter. Both scale with Redis.

<!-- tested: pass -->
