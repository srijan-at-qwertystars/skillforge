---
name: websocket-patterns
description: >
  Use when building real-time features with WebSockets, Socket.IO, or similar persistent connection protocols.
  Triggers: WebSocket server/client implementation, Socket.IO setup, real-time chat, live notifications,
  collaborative editing, live dashboards, pub/sub over WebSocket, WebSocket authentication, reconnection
  logic, heartbeat/ping-pong, scaling WebSocket servers, Redis adapter, sticky sessions, binary WebSocket
  messages, WebSocket testing, WebSocket security, SSE vs WebSocket decisions, connection management.
  Do NOT trigger for: plain HTTP REST APIs, GraphQL queries without subscriptions, static file serving,
  database queries, cron jobs, batch processing, email sending, simple request-response without persistent
  connections, Server-Sent Events without WebSocket comparison context.
---

# WebSocket Patterns

## Protocol Fundamentals

### Handshake
The WebSocket connection upgrades from HTTP/1.1. Key headers:
- **Request**: `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`
- **Response**: `101 Switching Protocols`, `Sec-WebSocket-Accept` (SHA-1 hash of key + GUID)

Always validate `Origin` header server-side to prevent Cross-Site WebSocket Hijacking.

### Frame Opcodes
| Opcode | Type | Purpose |
|--------|------|---------|
| `0x0` | Continuation | Multi-frame message continuation |
| `0x1` | Text | UTF-8 text data |
| `0x2` | Binary | Binary data (ArrayBuffer) |
| `0x8` | Close | Connection close with status code |
| `0x9` | Ping | Heartbeat request |
| `0xA` | Pong | Heartbeat response |

### Close Codes
| Code | Meaning | When to Use |
|------|---------|-------------|
| `1000` | Normal closure | Clean shutdown |
| `1001` | Going away | Server shutdown or page navigation |
| `1002` | Protocol error | Malformed frame received |
| `1003` | Unsupported data | Unexpected data type |
| `1006` | Abnormal closure | No close frame (connection dropped) |
| `1008` | Policy violation | Auth failure or message too large |
| `1011` | Internal error | Unexpected server condition |
| `1012` | Service restart | Server restarting, client should reconnect |
| `1013` | Try again later | Temporary overload |

### Ping/Pong Heartbeat
Send server-side pings at 30s intervals. Terminate connections missing 2+ consecutive pongs. Clients auto-reply to pings per RFC 6455.

## Server Implementations

### Node.js — ws library
```javascript
import { WebSocketServer } from 'ws';
const wss = new WebSocketServer({ port: 8080 });

wss.on('connection', (ws, req) => {
  const ip = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', (data, isBinary) => {
    // Broadcast to all other clients
    wss.clients.forEach(client => {
      if (client !== ws && client.readyState === 1) {
        client.send(data, { binary: isBinary });
      }
    });
  });
  ws.on('close', (code, reason) => {
    console.log(`Closed: ${code} ${reason}`);
  });
});
// Heartbeat interval — terminate dead connections
const interval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (!ws.isAlive) return ws.terminate();
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);
wss.on('close', () => clearInterval(interval));
```

### Python — FastAPI WebSocket
```python
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from typing import list

app = FastAPI()

class ConnectionManager:
    def __init__(self):
        self.active: list[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)

    def disconnect(self, ws: WebSocket):
        self.active.remove(ws)

    async def broadcast(self, message: str, exclude: WebSocket = None):
        for conn in self.active:
            if conn != exclude:
                await conn.send_text(message)

manager = ConnectionManager()

@app.websocket("/ws/{room_id}")
async def websocket_endpoint(ws: WebSocket, room_id: str):
    await manager.connect(ws)
    try:
        while True:
            data = await ws.receive_text()
            await manager.broadcast(f"[{room_id}] {data}", exclude=ws)
    except WebSocketDisconnect:
        manager.disconnect(ws)
```

### Go — gorilla/websocket
```go
var upgrader = websocket.Upgrader{
    ReadBufferSize: 1024, WriteBufferSize: 1024,
    CheckOrigin: func(r *http.Request) bool {
        return r.Header.Get("Origin") == "https://yourdomain.com"
    },
}
func handleWS(w http.ResponseWriter, r *http.Request) {
    conn, err := upgrader.Upgrade(w, r, nil)
    if err != nil { return }
    defer conn.Close()
    conn.SetReadDeadline(time.Now().Add(60 * time.Second))
    conn.SetPongHandler(func(string) error {
        conn.SetReadDeadline(time.Now().Add(60 * time.Second))
        return nil
    })
    for {
        mt, msg, err := conn.ReadMessage()
        if err != nil { break }
        if err = conn.WriteMessage(mt, msg); err != nil { break }
    }
}
```

## Client-Side Patterns

### Browser WebSocket API with Reconnection
```javascript
class RobustWebSocket {
  constructor(url, options = {}) {
    this.url = url;
    this.maxRetries = options.maxRetries ?? 10;
    this.attempt = 0;
    this.queue = []; // offline message queue
    this.listeners = { message: [], open: [], close: [] };
    this.connect();
  }

  connect() {
    this.ws = new WebSocket(this.url);
    this.ws.binaryType = 'arraybuffer';
    this.ws.onopen = () => {
      this.attempt = 0;
      this.flushQueue();
      this.startHeartbeat();
      this.listeners.open.forEach(fn => fn());
    };
    this.ws.onmessage = (e) => {
      if (e.data === 'pong') { this.lastPong = Date.now(); return; }
      this.listeners.message.forEach(fn => fn(e));
    };
    this.ws.onclose = (e) => {
      this.stopHeartbeat();
      this.listeners.close.forEach(fn => fn(e));
      if (e.code !== 1000 && this.attempt < this.maxRetries) {
        this.scheduleReconnect();
      }
    };
    this.ws.onerror = () => {}; // onclose fires after onerror
  }

  send(data) {
    if (this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(typeof data === 'string' ? data : JSON.stringify(data));
    } else {
      this.queue.push(data); // queue when disconnected
    }
  }

  flushQueue() {
    while (this.queue.length && this.ws.readyState === WebSocket.OPEN) {
      this.send(this.queue.shift());
    }
  }

  scheduleReconnect() {
    const base = 500, max = 30000;
    const delay = Math.min(base * 2 ** this.attempt, max);
    const jitter = delay * (0.5 + Math.random() * 0.5);
    this.attempt++;
    setTimeout(() => this.connect(), jitter);
  }

  startHeartbeat() {
    this.lastPong = Date.now();
    this.heartbeat = setInterval(() => {
      if (Date.now() - this.lastPong > 35000) {
        this.ws.close(4000, 'heartbeat timeout');
        return;
      }
      if (this.ws.readyState === WebSocket.OPEN) this.ws.send('ping');
    }, 15000);
  }

  stopHeartbeat() { clearInterval(this.heartbeat); }

  on(event, fn) { this.listeners[event]?.push(fn); }
  close() { this.maxRetries = 0; this.ws.close(1000); }
}
```

## Socket.IO Patterns

### Namespaces, Rooms, Acknowledgements
```javascript
import { Server } from 'socket.io';
const io = new Server(3000, { cors: { origin: 'https://app.example.com' } });
const chat = io.of('/chat'); // Namespace: isolate feature domains

chat.use((socket, next) => { // Auth middleware per-namespace
  try { socket.user = verifyJWT(socket.handshake.auth.token); next(); }
  catch { next(new Error('unauthorized')); }
});

chat.on('connection', (socket) => {
  socket.join(`room:${socket.handshake.query.roomId}`);
  socket.on('message', (data, ack) => { // Acknowledgement pattern
    const saved = saveToDb(data);
    chat.to(`room:${data.roomId}`).emit('message', saved);
    ack({ status: 'ok', id: saved.id });
  });
  socket.on('file:upload', (buffer, metadata, ack) => { // Binary event
    ack({ url: storeFile(buffer, metadata) });
  });
  socket.on('disconnect', () => {
    chat.to(`room:${socket.handshake.query.roomId}`).emit('user:left', socket.user.id);
  });
});
```

### Redis Adapter for Horizontal Scaling
```javascript
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';

const pubClient = createClient({ url: 'redis://redis:6379' });
const subClient = pubClient.duplicate();
await Promise.all([pubClient.connect(), subClient.connect()]);
io.adapter(createAdapter(pubClient, subClient));
// All io.to(room).emit() calls now broadcast across all server instances
```

Require sticky sessions in the load balancer when using Socket.IO:
```nginx
upstream socketio {
    ip_hash;  # sticky sessions
    server app1:3000;
    server app2:3000;
}
server {
    location /socket.io/ {
        proxy_pass http://socketio;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;  # 24h for persistent connections
    }
}
```

## Authentication

### Token-Based Auth (JWT)
Pass token in handshake — never in URL query params (logged by proxies):
```javascript
// Client
const socket = io('wss://api.example.com', {
  auth: { token: localStorage.getItem('jwt') }
});
// Server middleware validates before connection completes
```

### Connection Middleware Pattern
```javascript
wss.on('connection', (ws, req) => {
  const token = req.headers['sec-websocket-protocol'];
  try {
    ws.user = verifyJWT(token);
  } catch {
    ws.close(1008, 'unauthorized');
    return;
  }
});
```

For cookie auth, set `HttpOnly; Secure; SameSite=Strict` cookies. Verify during upgrade request.

## Message Patterns

### Typed Message Envelope
Wrap all messages in a consistent envelope for routing:
```typescript
interface WSMessage<T = unknown> {
  type: string;        // 'chat:message' | 'presence:update' | 'error'
  id: string;          // correlation ID for request/response
  timestamp: number;
  payload: T;
}

// Request/response pattern
ws.send(JSON.stringify({ type: 'user:get', id: 'req-1', payload: { userId: '42' } }));
// Server responds with same id:
// { type: 'user:get:response', id: 'req-1', payload: { name: 'Alice' } }
```

### Pub/Sub with Channels
```javascript
const channels = new Map(); // channelName -> Set<ws>
function subscribe(ws, channel) {
  if (!channels.has(channel)) channels.set(channel, new Set());
  channels.get(channel).add(ws);
}
function publish(channel, data, exclude = null) {
  channels.get(channel)?.forEach(ws => {
    if (ws !== exclude && ws.readyState === 1)
      ws.send(JSON.stringify({ type: 'channel:message', channel, payload: data }));
  });
}
ws.on('close', () => channels.forEach(subs => subs.delete(ws)));
```

### Binary Data — Protocol Buffers over WebSocket
```javascript
// Encode with protobuf before sending
const buffer = MyMessage.encode({ field: 'value' }).finish();
ws.send(buffer);  // ws.binaryType = 'arraybuffer' on client

// Decode on receive
ws.on('message', (data) => {
  const msg = MyMessage.decode(new Uint8Array(data));
});
```

Use binary for high-throughput scenarios (>1000 msg/s). Text JSON is fine for <100 msg/s.

## Error Handling and Resilience

### Exponential Backoff with Jitter
```
Delay = min(base * 2^attempt, maxDelay) * random(0.5, 1.0)
```
- Base: 500ms, Max: 30s, Reset on successful connect.
- Cap max retries (e.g., 10) then show "connection lost" UI.

### Offline Queue
Queue outbound messages during disconnection. Flush on reconnect. Add sequence numbers for idempotency:
```javascript
{ type: 'message', seq: 42, payload: { text: 'hello' } }
// Server deduplicates by (userId, seq)
```

### State Sync After Reconnect
On reconnect, send `lastEventId` or timestamp. Server replays missed events:
```javascript
ws.onopen = () => {
  ws.send(JSON.stringify({ type: 'sync', since: lastTimestamp }));
};
```

## Security Checklist

- **Always use `wss://`** — never `ws://` in production
- **Validate Origin header** during handshake to prevent CSWSH
- **Rate limit** connections per IP (e.g., 10 new connections/minute) and messages per connection (e.g., 60/minute)
- **Validate all inbound messages** — parse JSON in try/catch, enforce schema, reject oversized frames
- **Set max payload size**: `new WebSocketServer({ maxPayload: 1024 * 1024 })` (1MB default in ws)
- **Authenticate on handshake**, not after connection opens
- **Authorize per-message** for sensitive operations
- **Implement idle timeout** — close connections inactive for >5 minutes without heartbeat

## Testing

### Mock WebSocket Server (Node.js)
```javascript
import { WebSocketServer } from 'ws';
function createMockServer(port = 8999) {
  const wss = new WebSocketServer({ port });
  const messages = [];
  wss.on('connection', (ws) => {
    ws.on('message', (data) => {
      messages.push(JSON.parse(data));
      ws.send(JSON.stringify({ type: 'ack', id: messages.length }));
    });
  });
  return { wss, messages, close: () => wss.close() };
}
// In test: const mock = createMockServer(); ... assert mock.messages; mock.close();
```

### Load Testing with k6
```javascript
import ws from 'k6/ws';
import { check } from 'k6';
export const options = { vus: 500, duration: '60s' };
export default function () {
  const res = ws.connect('wss://staging.example.com/ws', {}, (socket) => {
    socket.on('open', () => socket.send(JSON.stringify({ type: 'ping' })));
    socket.on('message', (msg) => check(msg, { 'has type': (m) => JSON.parse(m).type !== undefined }));
    socket.setTimeout(() => socket.close(), 10000);
  });
  check(res, { 'status is 101': (r) => r && r.status === 101 });
}
```

## WebSocket vs SSE vs Long Polling

| Factor | WebSocket | SSE | Long Polling |
|--------|-----------|-----|--------------|
| Direction | Bidirectional | Server → Client | Server → Client |
| Latency | <50ms | <100ms | 1-30s |
| Binary data | Yes | No (text only) | Yes |
| Auto-reconnect | Manual | Built-in | Built-in |
| HTTP/2 compat | Separate connection | Multiplexed | Multiplexed |
| Max connections/origin | Browser-limited (6-13) | ~6 per origin | ~6 per origin |
| Proxy-friendly | Sometimes blocked | Yes | Yes |

**Decision guide:** Bidirectional/binary → **WebSocket** • Server-push text → **SSE** • Legacy/hostile → **Long Polling** • Chat/gaming/collab → **WebSocket** • Notifications/feeds → **SSE** or **WebSocket**

## Real-World Architecture Patterns

- **Chat**: Client → WS → Server → Redis Pub/Sub → All Instances → Room Clients. Store in DB, deliver history via REST.
- **Notifications**: Per-user connection map. Publish to user channel on events. Fall back to push if WS disconnected.
- **Collaborative editing**: OT or CRDT. Send operations (not full doc). Sequence server-side. See `references/advanced-patterns.md`.
- **Live dashboard**: Push metric snapshots at 1-5s intervals. Binary encoding for large datasets.

## Production Gotchas

| Issue | Cause | Fix |
|-------|-------|-----|
| Connections drop after 60s | Proxy/LB idle timeout | `proxy_read_timeout 86400s` in nginx |
| Can't scale past 1 server | No message bus | Add Redis Pub/Sub adapter |
| Memory grows unbounded | Leaked refs | Clean up Maps/Sets on `close` event |
| Reconnection storm | All clients reconnect at once | Jittered exponential backoff |
| 502 on connect | LB doesn't support Upgrade | Enable WS support in LB config |
| File descriptor exhaustion | Low ulimit | `ulimit -n 65535`, tune `LimitNOFILE` |
| Messages lost on reconnect | No offline queue | Queue + seq numbers + server replay |
| Browser tab limits | 6-13 conns per origin | Multiplex via single connection + channels |
| Stale connections | No heartbeat | Ping every 30s, terminate after 2 missed pongs |

## Example Interactions

- **"Add WebSocket support to my Express app"** → ws server attached to Express, JWT auth, typed envelope, heartbeat, graceful shutdown, client reconnection.
- **"Scale my Socket.IO app"** → Redis adapter, nginx sticky sessions + upgrade headers, health checks.
- **"WebSocket connections keep dropping"** → Diagnostic checklist (proxy timeouts, heartbeat, LB), nginx fixes, reconnection backoff.
- **"WebSocket or SSE for dashboard?"** → Decision matrix, recommendation with tradeoffs, implementation skeleton.

## Reference Docs

In-depth guides in `references/`:

| Document | Topics |
|----------|--------|
| [advanced-patterns.md](references/advanced-patterns.md) | Multiplexing, custom subprotocols, permessage-deflate compression, binary framing, connection state machines, graceful degradation to SSE/polling, gateway patterns, distributed pub/sub (Redis/NATS), presence tracking, cursor sharing |
| [troubleshooting.md](references/troubleshooting.md) | Connection drops behind Nginx/HAProxy/AWS ALB, CORS/origin issues, memory leaks from uncleared listeners, buffered messages on slow connections, reconnection storms, Chrome DevTools debugging, Wireshark WebSocket inspection, health checks, SSL/TLS termination |
| [scaling-guide.md](references/scaling-guide.md) | Horizontal scaling with sticky sessions, Redis pub/sub adapter for Socket.IO, NATS cross-server messaging, connection limits, connection pooling, Kubernetes ingress config, AWS API Gateway WebSocket API, lifecycle management, memory estimation per connection |

## Scripts

Executable tools in `scripts/` (run with `./scripts/<name>.sh`):

| Script | Purpose |
|--------|---------|
| [init-ws-project.sh](scripts/init-ws-project.sh) | Scaffold a complete WebSocket project: server with rooms/broadcast/heartbeat, client HTML page with auto-reconnect, npm dependencies |
| [ws-load-test.sh](scripts/ws-load-test.sh) | Load test WebSocket servers using k6, Artillery, or built-in Node.js tester. Measures connection time, message latency, max concurrent connections |
| [ws-debug-proxy.sh](scripts/ws-debug-proxy.sh) | Transparent WebSocket debug proxy that logs all frames between client and server. Supports text, JSON, and compact output formats |

## Assets (Copy-Paste Templates)

Production-ready templates in `assets/`:

| File | Description |
|------|-------------|
| [ws-server.ts](assets/ws-server.ts) | TypeScript WebSocket server: rooms, heartbeat, JWT auth middleware, message validation, rate limiting, graceful shutdown, health/metrics endpoints |
| [ws-client.ts](assets/ws-client.ts) | TypeScript WebSocket client: auto-reconnect with exponential backoff, offline message queue, heartbeat, event emitter, request/response correlation, state machine |
| [socket-io-server.ts](assets/socket-io-server.ts) | Socket.IO server: namespaces (/chat, /notifications), rooms, JWT middleware, Redis adapter, typed events, rate limiting, graceful shutdown |
| [nginx-websocket.conf](assets/nginx-websocket.conf) | Nginx config: WebSocket upgrade headers, 24h timeouts, sticky sessions (ip_hash), SSL/TLS, rate limiting, Socket.IO path, health checks |
| [k6-ws-test.js](assets/k6-ws-test.js) | k6 load test: staged VU ramp-up, connection lifecycle, message latency measurement, room operations, custom metrics, pass/fail thresholds |

<!-- tested: pass -->
