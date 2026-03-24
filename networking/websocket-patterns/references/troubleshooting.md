# WebSocket Troubleshooting Guide

## Table of Contents

- [Connection Drops Behind Proxies and Load Balancers](#connection-drops-behind-proxies-and-load-balancers)
- [Nginx WebSocket Configuration](#nginx-websocket-configuration)
- [HAProxy WebSocket Configuration](#haproxy-websocket-configuration)
- [SSL/TLS Termination](#ssltls-termination)
- [CORS and Origin Checking](#cors-and-origin-checking)
- [Memory Leaks from Unclosed Connections](#memory-leaks-from-unclosed-connections)
- [Message Ordering Guarantees](#message-ordering-guarantees)
- [Handling Offline/Reconnect State Sync](#handling-offlinereconnect-state-sync)
- [Mobile Network Transitions (WiFi → Cellular)](#mobile-network-transitions-wifi--cellular)
- [Browser Tab Throttling](#browser-tab-throttling)
- [Debugging with Browser DevTools](#debugging-with-browser-devtools)

---

## Connection Drops Behind Proxies and Load Balancers

### Symptoms

- Connections close after exactly 60s (or another round number)
- Clients reconnect frequently with close code 1006 (abnormal closure)
- Works in development but breaks in production

### Root Causes

1. **Proxy idle timeout**: Most proxies (AWS ALB, Cloudflare, nginx) close idle connections after 60–120 seconds.
2. **Intermediary doesn't support WebSocket**: Some corporate proxies or CDNs strip the `Upgrade` header.
3. **TCP keepalive not configured**: OS-level TCP keepalives may be too infrequent.

### Solutions

**Application-level heartbeat** (most reliable):

```ts
// Server: ping every 25 seconds (well under typical 60s proxy timeout)
const HEARTBEAT_INTERVAL = 25_000;

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  const interval = setInterval(() => {
    if (!ws.isAlive) { ws.terminate(); return; }
    ws.isAlive = false;
    ws.ping();
  }, HEARTBEAT_INTERVAL);

  ws.on('close', () => clearInterval(interval));
});
```

**AWS ALB idle timeout**: Set the ALB idle timeout higher than your heartbeat interval:

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $ALB_ARN \
  --attributes Key=idle_timeout.timeout_seconds,Value=120
```

**Cloudflare**: WebSocket connections have a 100-second idle timeout. Cannot be changed on free/pro plans. Use heartbeats < 90s.

---

## Nginx WebSocket Configuration

### Basic Proxying

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream websocket_backend {
    server 127.0.0.1:3000;
}

server {
    listen 443 ssl;
    server_name ws.example.com;

    ssl_certificate     /etc/ssl/certs/example.com.pem;
    ssl_certificate_key /etc/ssl/private/example.com.key;

    location /ws {
        proxy_pass http://websocket_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Timeouts
        proxy_read_timeout 86400s;   # 24 hours
        proxy_send_timeout 86400s;
        proxy_connect_timeout 10s;

        # Buffering
        proxy_buffering off;
        proxy_cache off;
    }
}
```

### Common Nginx Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Missing `proxy_http_version 1.1` | 502 Bad Gateway | Add `proxy_http_version 1.1;` |
| Missing `Upgrade` header | Connection falls back to polling | Add `proxy_set_header Upgrade $http_upgrade;` |
| Default `proxy_read_timeout` (60s) | Connections drop after 60s | Set to 86400s or higher |
| `proxy_buffering on` | Delayed message delivery | Set `proxy_buffering off;` |
| Using `$http_connection` instead of map | Breaks when client sends other `Connection` tokens | Use `map $http_upgrade $connection_upgrade` |

---

## HAProxy WebSocket Configuration

```haproxy
frontend ws_frontend
    bind *:443 ssl crt /etc/ssl/certs/combined.pem
    mode http
    timeout client 86400s

    # Route WebSocket traffic
    acl is_websocket hdr(Upgrade) -i websocket
    use_backend ws_backend if is_websocket
    default_backend http_backend

backend ws_backend
    mode http
    timeout server 86400s
    timeout tunnel 86400s    # critical for WebSocket
    balance source           # sticky sessions by source IP

    server ws1 10.0.0.1:3000 check
    server ws2 10.0.0.2:3000 check
```

### Key HAProxy Settings

- **`timeout tunnel`**: This is the critical timeout for WebSocket connections. It controls how long HAProxy keeps the bidirectional tunnel open. Without it, connections drop after the default server timeout.
- **`balance source`**: Ensures clients reconnect to the same backend (important for Socket.IO).
- **`mode http`**: Required for WebSocket. `mode tcp` works but loses HTTP header inspection.

---

## SSL/TLS Termination

### Patterns

1. **Terminate at load balancer** (most common): LB handles TLS; backend receives plain `ws://`. Simpler certificate management, but traffic between LB and backend is unencrypted.

2. **End-to-end TLS**: Backend servers handle TLS directly. Ensures encryption in transit everywhere but complicates certificate rotation.

3. **Re-encrypt at LB**: LB terminates client TLS and establishes new TLS to backend. Best security with managed certificates.

### Common Issues

**Mixed content errors**: If your page is served over HTTPS, WebSocket connections MUST use `wss://`:

```js
// Wrong: browser blocks this on HTTPS pages
const ws = new WebSocket('ws://api.example.com/ws');

// Correct
const ws = new WebSocket('wss://api.example.com/ws');
```

**Self-signed certificates in development**:

```ts
// Node.js client: skip TLS verification (dev only!)
import { WebSocket } from 'ws';
const ws = new WebSocket('wss://localhost:8443', {
  rejectUnauthorized: false,  // NEVER in production
});
```

**Certificate chain issues**: Ensure the full certificate chain (leaf + intermediates) is provided. Partial chains cause failures on some clients:

```bash
# Verify certificate chain
openssl s_client -connect ws.example.com:443 -servername ws.example.com
```

---

## CORS and Origin Checking

WebSocket connections are NOT subject to CORS (no preflight request). However, the browser sends the `Origin` header, and the server should validate it.

### Why Origin Checking Matters

Without origin validation, any website can open a WebSocket to your server and interact with it using the user's cookies (Cross-Site WebSocket Hijacking — CSWSH).

### Server-Side Origin Validation

```ts
// ws library
const wss = new WebSocketServer({
  verifyClient: (info, done) => {
    const origin = info.origin || info.req.headers.origin;
    const allowed = ['https://myapp.com', 'https://staging.myapp.com'];
    if (!allowed.includes(origin)) {
      done(false, 403, 'Origin not allowed');
      return;
    }
    done(true);
  },
});

// Socket.IO
const io = new Server(server, {
  cors: {
    origin: ['https://myapp.com', 'https://staging.myapp.com'],
    methods: ['GET', 'POST'],
    credentials: true,
  },
});
```

### Gotchas

- **Non-browser clients**: Non-browser WebSocket clients can set any `Origin` header. Don't rely on origin alone for security — combine with authentication.
- **Null origin**: Some privacy modes or local files send `Origin: null`. Decide your policy explicitly.
- **WebSocket subdomains**: If your API is at `wss://api.example.com` but the page is at `https://www.example.com`, the origin is `https://www.example.com`.

---

## Memory Leaks from Unclosed Connections

### Symptoms

- Server memory grows continuously over hours/days
- Eventually crashes with OOM (Out of Memory)
- Restarting temporarily fixes the issue

### Common Causes

1. **Event listeners not cleaned up**: Attaching listeners in `connection` without removing them on `close`.
2. **Timers not cleared**: `setInterval` for heartbeat continues after disconnect.
3. **References held in closures**: Data structures referencing the socket prevent GC.
4. **Zombie connections**: Half-open TCP connections where one side thinks it's still connected.

### Detection

```ts
// Monitor connection count and memory
setInterval(() => {
  const mem = process.memoryUsage();
  console.log({
    connections: wss.clients.size,
    heapUsed: Math.round(mem.heapUsed / 1024 / 1024) + 'MB',
    rss: Math.round(mem.rss / 1024 / 1024) + 'MB',
  });
}, 30_000);

// Take heap snapshots periodically
// node --inspect server.js
// Chrome DevTools > Memory > Heap Snapshot
```

### Prevention Checklist

```ts
wss.on('connection', (ws) => {
  // ✅ Always clear intervals on close
  const heartbeat = setInterval(() => ws.ping(), 30_000);
  ws.on('close', () => clearInterval(heartbeat));

  // ✅ Remove from collections on close
  rooms.get(roomId)?.add(ws);
  ws.on('close', () => rooms.get(roomId)?.delete(ws));

  // ✅ Set maximum connection limits
  if (wss.clients.size > MAX_CONNECTIONS) {
    ws.close(1013, 'Server overloaded');
    return;
  }

  // ✅ Set per-connection inactivity timeout
  let lastActivity = Date.now();
  ws.on('message', () => { lastActivity = Date.now(); });
  const idleCheck = setInterval(() => {
    if (Date.now() - lastActivity > 300_000) {  // 5 min idle
      ws.close(1000, 'Idle timeout');
    }
  }, 60_000);
  ws.on('close', () => clearInterval(idleCheck));
});
```

---

## Message Ordering Guarantees

### What WebSocket Guarantees

- **Single connection**: Messages arrive in the order they were sent (TCP guarantees ordering).
- **Multiple connections**: No ordering guarantee between different WebSocket connections.

### What Can Go Wrong

1. **Server broadcasts from async operations**: If the server reads from a database before sending, concurrent reads can complete out of order.
2. **Multi-server setups**: With Redis pub/sub, messages published from different servers may arrive in different orders on different clients.
3. **Reconnection**: Messages sent during reconnection may be lost or reordered.

### Solutions

**Sequence numbers**: Include a monotonically increasing sequence number in each message:

```ts
let serverSeq = 0;

function sendOrdered(ws: WebSocket, data: unknown) {
  ws.send(JSON.stringify({ seq: ++serverSeq, ...data }));
}

// Client reorder buffer
class OrderedReceiver {
  private expectedSeq = 1;
  private buffer = new Map<number, unknown>();

  receive(msg: { seq: number; [key: string]: unknown }) {
    this.buffer.set(msg.seq, msg);
    while (this.buffer.has(this.expectedSeq)) {
      this.process(this.buffer.get(this.expectedSeq)!);
      this.buffer.delete(this.expectedSeq);
      this.expectedSeq++;
    }
  }

  private process(msg: unknown) {
    // Handle the message
  }
}
```

**Vector clocks**: For multi-source ordering, use vector clocks or Lamport timestamps.

---

## Handling Offline/Reconnect State Sync

### The Problem

When a client disconnects and reconnects, it has missed messages. The server must bring the client up to date.

### Pattern 1: Last-Event-ID

```ts
// Client sends last received message ID on reconnect
const ws = new WebSocket(`wss://api.example.com/ws?lastEventId=${lastId}`);

// Server replays missed events
wss.on('connection', (ws, req) => {
  const lastId = new URL(req.url!, 'http://localhost').searchParams.get('lastEventId');
  if (lastId) {
    const missed = eventStore.getAfter(lastId);
    for (const event of missed) {
      ws.send(JSON.stringify(event));
    }
  }
});
```

### Pattern 2: State Snapshot + Delta

```ts
// On reconnect, send full state snapshot first
ws.on('open', () => {
  ws.send(JSON.stringify({
    type: 'snapshot',
    state: getCurrentState(),
    version: currentVersion,
  }));
});

// Then send incremental updates
function broadcastDelta(delta: unknown) {
  currentVersion++;
  broadcast(JSON.stringify({ type: 'delta', delta, version: currentVersion }));
}
```

### Pattern 3: Socket.IO Connection State Recovery

Socket.IO v4.6+ has built-in connection state recovery:

```ts
const io = new Server(server, {
  connectionStateRecovery: {
    maxDisconnectionDuration: 2 * 60 * 1000,  // 2 minutes
    skipMiddlewares: true,
  },
});

io.on('connection', (socket) => {
  if (socket.recovered) {
    // Client automatically receives missed events
    console.log('Recovered! Rooms restored:', socket.rooms);
  } else {
    // Full sync needed
    socket.emit('full-state', getState());
  }
});
```

---

## Mobile Network Transitions (WiFi → Cellular)

### The Problem

When a mobile device switches from WiFi to cellular (or vice versa), the TCP connection breaks because the IP address changes. The WebSocket connection dies silently — no close frame is sent.

### Symptoms

- Connection silently drops on network switch
- Heartbeat timeout eventually detects the drop (30–60s delay)
- Users see stale data during the gap

### Solutions

**Aggressive heartbeat on mobile**:

```ts
const isMobile = /Android|iPhone|iPad/i.test(navigator.userAgent);
const HEARTBEAT_MS = isMobile ? 10_000 : 30_000;  // 10s on mobile
```

**Network change detection** (browser):

```ts
// Detect network changes and proactively reconnect
window.addEventListener('online', () => {
  if (ws.readyState !== WebSocket.OPEN) {
    ws.close();
    reconnect();
  }
});

window.addEventListener('offline', () => {
  // Queue messages while offline
  isOffline = true;
});

// Network Information API (Chrome/Edge)
navigator.connection?.addEventListener('change', () => {
  console.log('Network changed:', navigator.connection.type);
  // Force reconnect to pick up new IP
  ws.close();
  reconnect();
});
```

**Connection quality monitoring**:

```ts
class ConnectionMonitor {
  private lastPong = Date.now();
  private latencies: number[] = [];

  startMonitoring(ws: WebSocket) {
    setInterval(() => {
      const pingTime = Date.now();
      ws.send(JSON.stringify({ type: 'ping', t: pingTime }));
    }, 5000);
  }

  onPong(timestamp: number) {
    const latency = Date.now() - timestamp;
    this.latencies.push(latency);
    if (this.latencies.length > 10) this.latencies.shift();

    const avg = this.latencies.reduce((a, b) => a + b, 0) / this.latencies.length;
    if (avg > 2000) {
      console.warn('High latency detected, connection may be degraded');
    }
  }
}
```

---

## Browser Tab Throttling

### The Problem

Modern browsers throttle background tabs to save resources:

- **Chrome**: `setTimeout`/`setInterval` minimum delay of 1 second for background tabs (after 5 minutes, throttled to 1 minute for chained timers)
- **Firefox**: Similar throttling, tabs in background for > 5 minutes have minimum 1-minute intervals
- **Safari**: Aggressively suspends background tabs

### Impact on WebSocket

- Heartbeat timers fire less frequently → proxy may close connection
- Message processing is delayed
- UI updates are batched

### Solutions

**Web Workers for heartbeat** (not throttled):

```ts
// heartbeat-worker.js
let interval;
self.onmessage = (e) => {
  if (e.data === 'start') {
    interval = setInterval(() => self.postMessage('ping'), 25000);
  } else if (e.data === 'stop') {
    clearInterval(interval);
  }
};

// main.js
const worker = new Worker('heartbeat-worker.js');
worker.postMessage('start');
worker.onmessage = () => {
  if (ws.readyState === WebSocket.OPEN) ws.ping?.() || ws.send('ping');
};
```

**Visibility API awareness**:

```ts
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    // Tab is in background — reduce non-essential updates
    ws.send(JSON.stringify({ type: 'set-update-frequency', freq: 'low' }));
  } else {
    // Tab is active — request full state sync (may have missed updates)
    ws.send(JSON.stringify({ type: 'set-update-frequency', freq: 'high' }));
    ws.send(JSON.stringify({ type: 'sync-request' }));
  }
});
```

**SharedWorker for single connection** (multiple tabs share one WebSocket):

```ts
// shared-ws-worker.js
const connections = [];
let ws;

self.onconnect = (e) => {
  const port = e.ports[0];
  connections.push(port);

  if (!ws) {
    ws = new WebSocket('wss://api.example.com/ws');
    ws.onmessage = (event) => {
      connections.forEach((p) => p.postMessage(event.data));
    };
  }

  port.onmessage = (event) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(event.data);
  };
};
```

---

## Debugging with Browser DevTools

### Chrome DevTools Network Tab

1. Open DevTools → **Network** tab
2. Filter by **WS** to show only WebSocket connections
3. Click a WebSocket connection to see:
   - **Headers**: Upgrade request/response, sub-protocols
   - **Messages**: All sent (↑ green) and received (↓ red) frames with timestamps
   - **Timing**: Connection establishment time

### Inspecting Frames

- **Text frames**: Displayed as readable text; JSON is formatted
- **Binary frames**: Shown as "Binary Message" with byte length
- **Control frames**: Ping/Pong visible with the "control" filter

### Console Debugging

```js
// Monkey-patch WebSocket for logging
const OrigWS = WebSocket;
window.WebSocket = function(...args) {
  const ws = new OrigWS(...args);
  const url = args[0];

  ws.addEventListener('open', () => console.log(`[WS] Connected: ${url}`));
  ws.addEventListener('close', (e) => console.log(`[WS] Closed: ${e.code} ${e.reason}`));
  ws.addEventListener('error', (e) => console.error(`[WS] Error:`, e));

  const origSend = ws.send.bind(ws);
  ws.send = (data) => {
    console.log(`[WS] ↑ SEND:`, typeof data === 'string' ? data : `Binary(${data.byteLength})`);
    origSend(data);
  };
  ws.addEventListener('message', (e) => {
    console.log(`[WS] ↓ RECV:`, e.data);
  });

  return ws;
};
```

### Command-Line Debugging

```bash
# wscat: interactive WebSocket client
npx wscat -c wss://api.example.com/ws

# websocat: powerful WebSocket CLI
websocat wss://api.example.com/ws

# curl: check WebSocket upgrade (won't complete the connection)
curl -i -N \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
  https://api.example.com/ws

# tcpdump: inspect raw WebSocket frames (unencrypted)
sudo tcpdump -i lo port 8080 -A

# wireshark: filter WebSocket traffic
# Filter: websocket
# Or for specific port: tcp.port == 8080 && websocket
```

### Socket.IO Debugging

```bash
# Enable Socket.IO debug logging
DEBUG=socket.io* node server.js

# Client-side
localStorage.debug = 'socket.io-client:*';

# Specific namespaces
DEBUG=socket.io:socket node server.js
DEBUG=socket.io:client:* node client.js
```

### Common Debug Scenarios

| Symptom | Check | Tool |
|---------|-------|------|
| "WebSocket connection failed" | Server running? Port open? | `curl`, `netstat` |
| 400 Bad Request on upgrade | Missing Upgrade headers | DevTools Headers |
| 502 Bad Gateway | Proxy misconfigured | nginx error.log |
| Messages not received | Check frame in Messages tab | DevTools WS Messages |
| Slow messages | Check timestamps between frames | DevTools Timing |
| Connection closes immediately | Check close code and reason | DevTools / `onclose` |
| Memory leak | Track connection count over time | `process.memoryUsage()` |
