# WebSocket Troubleshooting Guide

## Table of Contents

- [Connection Drops Behind Proxies](#connection-drops-behind-proxies)
- [CORS and Origin Issues](#cors-and-origin-issues)
- [Memory Leaks from Uncleared Listeners](#memory-leaks-from-uncleared-listeners)
- [Buffered Messages on Slow Connections](#buffered-messages-on-slow-connections)
- [Reconnection Storms After Server Restart](#reconnection-storms-after-server-restart)
- [Debugging with Chrome DevTools](#debugging-with-chrome-devtools)
- [Wireshark for WebSocket Traffic](#wireshark-for-websocket-traffic)
- [Load Balancer Health Checks](#load-balancer-health-checks)
- [SSL/TLS Termination Issues](#ssltls-termination-issues)
- [Quick Diagnostic Checklist](#quick-diagnostic-checklist)

---

## Connection Drops Behind Proxies

### Symptom
WebSocket connections drop after 60 seconds of inactivity, or randomly disconnect despite active communication.

### Root Cause
Proxies and load balancers have idle timeout settings. If no data flows within the timeout window, the proxy terminates the TCP connection silently.

### Nginx Configuration

```nginx
server {
    location /ws {
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Critical timeout settings
        proxy_read_timeout 86400s;    # 24 hours — max idle time before Nginx drops
        proxy_send_timeout 86400s;
        proxy_connect_timeout 10s;    # initial connection timeout

        # Buffering can interfere with WebSocket frames
        proxy_buffering off;
        proxy_cache off;
    }
}
```

### HAProxy Configuration

```haproxy
defaults
    timeout connect 10s
    timeout client  86400s    # 24 hours
    timeout server  86400s
    timeout tunnel  86400s    # critical for WebSocket

frontend ws_front
    bind *:443 ssl crt /etc/ssl/cert.pem
    acl is_websocket hdr(Upgrade) -i websocket
    use_backend ws_back if is_websocket

backend ws_back
    option http-server-close
    # Do NOT use option httpclose — it breaks WebSocket
    server ws1 app1:3000 check
    server ws2 app2:3000 check
```

### AWS ALB Configuration

AWS ALB has a **fixed idle timeout** (default 60s, max 4000s). Configure via:

```bash
# Set ALB idle timeout to 4000 seconds (maximum)
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn arn:aws:elasticloadbalancing:... \
  --attributes Key=idle_timeout.timeout_seconds,Value=4000
```

**ALB limitations:**
- Max idle timeout is 4000s (~66 minutes) — you MUST implement server-side heartbeat
- ALB drops connections after idle timeout even with `proxy_read_timeout` set higher upstream
- Send ping/pong at intervals shorter than the ALB timeout (every 30s is safe)

### Cloudflare

Cloudflare terminates idle WebSocket connections after 100 seconds on free plans. Use heartbeats every 30s. Enterprise plans allow custom timeouts.

### Universal Fix: Server-Side Heartbeat

Always implement regardless of proxy:

```typescript
// Send ping every 30s from server
const HEARTBEAT_INTERVAL = 30_000;
const HEARTBEAT_TIMEOUT = 10_000;

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
});

const interval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (!ws.isAlive) {
      ws.terminate(); // dead connection
      return;
    }
    ws.isAlive = false;
    ws.ping();
  });
}, HEARTBEAT_INTERVAL);
```

---

## CORS and Origin Issues

### Symptom
- Browser console: "WebSocket connection to 'wss://...' failed"
- 403 Forbidden on WebSocket upgrade request
- Connection works from Node.js/Postman but not browser

### Key Fact
**WebSocket itself does NOT enforce CORS.** The `Origin` header is sent but the browser doesn't block based on server response. However:

1. **The initial HTTP upgrade request** may be blocked by CORS middleware
2. **Socket.IO** uses HTTP long-polling for the initial handshake before upgrading, and THIS is subject to CORS
3. **Server-side origin validation** may reject unexpected origins

### Socket.IO CORS Fix

```typescript
const io = new Server(httpServer, {
  cors: {
    origin: ['https://app.example.com', 'https://staging.example.com'],
    methods: ['GET', 'POST'],
    credentials: true,  // needed if using cookies
  },
  // Allow WebSocket upgrade without polling fallback
  transports: ['websocket', 'polling'],
});
```

### Raw WebSocket Origin Validation

```typescript
const wss = new WebSocketServer({
  server: httpServer,
  verifyClient: (info, callback) => {
    const origin = info.origin || info.req.headers.origin;
    const allowed = ['https://app.example.com', 'https://staging.example.com'];

    if (!allowed.includes(origin)) {
      callback(false, 403, 'Origin not allowed');
      return;
    }
    callback(true);
  },
});
```

### Common Pitfalls
| Issue | Fix |
|-------|-----|
| `origin` is `undefined` in Node.js client | Node doesn't send Origin by default — use `verifyClient` to allow null origin for server-to-server |
| CORS error on Socket.IO | Socket.IO does HTTP polling first — add CORS config to both Express and Socket.IO |
| `ws://` blocked on HTTPS page | Mixed content — always use `wss://` from HTTPS pages |
| Origin header mismatch | Check for trailing slashes, port numbers, `www` vs non-`www` |

---

## Memory Leaks from Uncleared Listeners

### Symptom
Server memory grows continuously. Node.js emits `MaxListenersExceededWarning`. After hours/days, server crashes with OOM.

### Common Leak Patterns

**1. Uncleaned connection references in Maps/Sets:**

```typescript
// ❌ LEAK: connections never removed from map
const connections = new Map<string, WebSocket>();
wss.on('connection', (ws) => {
  connections.set(ws.userId, ws);
  // Missing: ws.on('close', () => connections.delete(ws.userId));
});

// ✅ FIX: always clean up on close
wss.on('connection', (ws) => {
  connections.set(ws.userId, ws);
  ws.on('close', () => {
    connections.delete(ws.userId);
  });
});
```

**2. Event listeners added but never removed:**

```typescript
// ❌ LEAK: new listener on every message
ws.on('message', (data) => {
  const handler = () => { /* process data */ };
  emitter.on('update', handler);  // never removed!
});

// ✅ FIX: track and remove listeners
ws.on('message', (data) => {
  const handler = () => { /* process data */ };
  emitter.on('update', handler);
  ws.once('close', () => emitter.off('update', handler));
});
```

**3. Interval/timer not cleared:**

```typescript
// ❌ LEAK: interval runs forever after disconnect
wss.on('connection', (ws) => {
  const pingInterval = setInterval(() => ws.ping(), 30000);
  // Missing: ws.on('close', () => clearInterval(pingInterval));
});

// ✅ FIX
wss.on('connection', (ws) => {
  const pingInterval = setInterval(() => ws.ping(), 30000);
  ws.on('close', () => clearInterval(pingInterval));
});
```

**4. Closure capturing large objects:**

```typescript
// ❌ LEAK: closure holds reference to large buffer
wss.on('connection', (ws) => {
  const largeBuffer = loadInitialState(); // 10MB
  ws.on('message', (data) => {
    // largeBuffer is captured and can't be GC'd until ws is GC'd
    processWithState(data, largeBuffer);
  });
});

// ✅ FIX: extract what you need, release the reference
wss.on('connection', (ws) => {
  const stateId = loadInitialState().id; // extract only what's needed
  ws.on('message', (data) => {
    const state = getStateById(stateId); // load on demand
    processWithState(data, state);
  });
});
```

### Diagnosing Memory Leaks

```bash
# Monitor Node.js heap in production
node --inspect server.js
# Connect Chrome DevTools → chrome://inspect → Take heap snapshots

# Quick check: RSS growth over time
watch -n 10 'ps -o rss,vsz,pid -p $(pgrep -f "node server")'

# Expose heap stats via endpoint
app.get('/debug/heap', (req, res) => {
  const used = process.memoryUsage();
  res.json({
    rss: `${Math.round(used.rss / 1024 / 1024)}MB`,
    heapUsed: `${Math.round(used.heapUsed / 1024 / 1024)}MB`,
    heapTotal: `${Math.round(used.heapTotal / 1024 / 1024)}MB`,
    external: `${Math.round(used.external / 1024 / 1024)}MB`,
    connections: wss.clients.size,
  });
});
```

---

## Buffered Messages on Slow Connections

### Symptom
Server memory spikes when clients are on slow connections. `ws.bufferedAmount` grows. Server eventually runs out of memory.

### Root Cause
`ws.send()` queues data in the kernel's TCP send buffer. If the client can't consume fast enough, the buffer grows unboundedly.

### Detection and Prevention

```typescript
wss.on('connection', (ws) => {
  ws.on('message', (data) => {
    wss.clients.forEach(client => {
      if (client.readyState !== WebSocket.OPEN) return;

      // Check buffered amount before sending
      if (client.bufferedAmount > 1024 * 1024) { // 1MB threshold
        console.warn(`Slow client ${client.userId}, dropping message`);
        return; // skip this client
      }

      // Option 2: Terminate very slow clients
      if (client.bufferedAmount > 5 * 1024 * 1024) { // 5MB
        console.error(`Terminating slow client ${client.userId}`);
        client.terminate();
        return;
      }

      client.send(data);
    });
  });
});
```

### Backpressure Strategy

```typescript
class BackpressureManager {
  private highWaterMark = 1024 * 1024; // 1MB

  async safeSend(ws: WebSocket, data: string | Buffer): Promise<boolean> {
    if (ws.readyState !== WebSocket.OPEN) return false;

    if (ws.bufferedAmount > this.highWaterMark) {
      // Wait for buffer to drain
      await this.waitForDrain(ws);
    }

    ws.send(data);
    return true;
  }

  private waitForDrain(ws: WebSocket): Promise<void> {
    return new Promise((resolve, reject) => {
      const check = setInterval(() => {
        if (ws.readyState !== WebSocket.OPEN) {
          clearInterval(check);
          reject(new Error('Connection closed while waiting for drain'));
          return;
        }
        if (ws.bufferedAmount < this.highWaterMark / 2) {
          clearInterval(check);
          resolve();
        }
      }, 100);

      // Timeout — don't wait forever
      setTimeout(() => {
        clearInterval(check);
        reject(new Error('Drain timeout'));
      }, 5000);
    });
  }
}
```

---

## Reconnection Storms After Server Restart

### Symptom
After deploying or restarting the server, all clients reconnect simultaneously, overwhelming the server. CPU spikes to 100%, connections get refused, cascading failures.

### Prevention Strategies

**1. Jittered exponential backoff (client-side):**

```typescript
function reconnectDelay(attempt: number): number {
  const base = 1000;
  const max = 30000;
  const exponential = Math.min(base * Math.pow(2, attempt), max);
  const jitter = exponential * (0.5 + Math.random() * 0.5);
  return jitter;
}
// attempt 0: 500-1000ms
// attempt 1: 1000-2000ms
// attempt 2: 2000-4000ms
// ...
// attempt 5+: 15000-30000ms
```

**2. Server-side connection rate limiting:**

```typescript
const connectionTimes: number[] = [];
const MAX_CONNECTIONS_PER_SECOND = 100;

wss.on('connection', (ws, req) => {
  const now = Date.now();
  // Remove entries older than 1 second
  while (connectionTimes.length && connectionTimes[0] < now - 1000) {
    connectionTimes.shift();
  }

  if (connectionTimes.length >= MAX_CONNECTIONS_PER_SECOND) {
    ws.close(1013, 'Try again later'); // 1013 = server overloaded
    return;
  }
  connectionTimes.push(now);
  // ... handle connection
});
```

**3. Close code 1012 for planned restarts:**

```typescript
// Before shutdown, send 1012 with retry-after hint
function gracefulShutdown() {
  wss.clients.forEach(ws => {
    ws.send(JSON.stringify({
      type: 'server:restart',
      retryAfter: 5000 + Math.random() * 10000, // staggered retry
    }));
    ws.close(1012, 'Service restart');
  });

  // Wait for connections to drain before stopping
  setTimeout(() => process.exit(0), 5000);
}

process.on('SIGTERM', gracefulShutdown);
```

**4. Rolling deployment with health checks:**

```yaml
# Kubernetes deployment — rollingUpdate ensures not all pods restart at once
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  template:
    spec:
      terminationGracePeriodSeconds: 60  # time for connections to drain
```

---

## Debugging with Chrome DevTools

### Network Tab — WebSocket Inspection

1. Open DevTools → **Network** tab
2. Filter by **WS** (WebSocket)
3. Click on the WebSocket connection
4. **Headers** tab: inspect upgrade request/response headers
5. **Messages** tab: see all sent (↑ green) and received (↓ red) frames
6. Filter messages by content using the search box

### What to Look For

| Symptom in DevTools | Likely Cause |
|---------------------|-------------|
| Connection appears then immediately closes | Auth failure — check close code in Headers |
| Messages stop flowing but connection stays open | Server stopped sending — check server logs |
| `101 Switching Protocols` never appears | Proxy blocking upgrade — check for `200 OK` instead |
| Frames show but `onmessage` not firing | Message handler error — check Console tab |
| Binary frames (Opcode 2) appear garbled | Set `ws.binaryType = 'arraybuffer'` on client |

### Console Debugging Snippets

```javascript
// Monitor WebSocket creation globally
const OriginalWebSocket = window.WebSocket;
window.WebSocket = function(...args) {
  const ws = new OriginalWebSocket(...args);
  console.log('WS created:', args[0]);
  ws.addEventListener('open', () => console.log('WS opened:', args[0]));
  ws.addEventListener('close', (e) => console.log('WS closed:', e.code, e.reason));
  ws.addEventListener('error', (e) => console.log('WS error:', e));
  const origSend = ws.send.bind(ws);
  ws.send = (data) => {
    console.log('WS send:', data);
    origSend(data);
  };
  ws.addEventListener('message', (e) => console.log('WS recv:', e.data));
  return ws;
};

// Check connection state
// 0=CONNECTING, 1=OPEN, 2=CLOSING, 3=CLOSED
console.log('State:', ws.readyState);
console.log('Buffered:', ws.bufferedAmount, 'bytes');
console.log('Protocol:', ws.protocol);
console.log('Extensions:', ws.extensions);
```

---

## Wireshark for WebSocket Traffic

### Capture Filter

```
# Capture only WebSocket traffic (port 80 or 443)
tcp port 80 or tcp port 443

# Capture specific server
host api.example.com and tcp port 443
```

### Display Filters

```
# Show only WebSocket frames
websocket

# Filter by opcode
websocket.opcode == 1         # text frames
websocket.opcode == 2         # binary frames
websocket.opcode == 8         # close frames
websocket.opcode == 9         # ping
websocket.opcode == 10        # pong

# Filter by payload content
websocket.payload contains "error"

# Show WebSocket handshake
http.request.method == "GET" and http.upgrade == "websocket"
```

### Decrypting WSS (TLS) Traffic

To inspect `wss://` traffic, export the TLS session key:

```bash
# Set environment variable before launching Chrome
SSLKEYLOGFILE=~/tls-keys.log google-chrome

# In Wireshark: Edit → Preferences → Protocols → TLS
# Set "(Pre)-Master-Secret log filename" to ~/tls-keys.log
```

### Common Wireshark Findings

| Observation | Meaning |
|-------------|---------|
| TCP RST after upgrade request | Proxy/firewall blocking WebSocket |
| Close frame with code 1006 | Abnormal closure — no close handshake (network issue) |
| Large gap between frames | Idle timeout may trigger — ensure heartbeat |
| Fragmented frames (opcode 0) | Large messages split — check `maxPayload` settings |
| Repeated SYN/SYN-ACK | Connection retry — server may be refusing connections |

---

## Load Balancer Health Checks

### Problem
Load balancers send HTTP health checks to `/health`. If the WebSocket server only handles WebSocket upgrades, health checks fail, and the LB removes the server from rotation.

### Solution: Dual-Purpose HTTP Server

```typescript
import { createServer } from 'http';
import { WebSocketServer } from 'ws';

const server = createServer((req, res) => {
  if (req.url === '/health') {
    // Health check — verify server is ready to accept connections
    const healthy = wss.clients.size < MAX_CONNECTIONS;
    res.writeHead(healthy ? 200 : 503);
    res.end(JSON.stringify({
      status: healthy ? 'ok' : 'overloaded',
      connections: wss.clients.size,
      uptime: process.uptime(),
    }));
    return;
  }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({ server });
server.listen(3000);
```

### AWS ALB Health Check Configuration

```bash
# Target group health check — HTTP GET to /health
aws elbv2 modify-target-group \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3
```

### Kubernetes Readiness/Liveness Probes

```yaml
spec:
  containers:
    - name: ws-server
      ports:
        - containerPort: 3000
      readinessProbe:
        httpGet:
          path: /health
          port: 3000
        initialDelaySeconds: 5
        periodSeconds: 10
      livenessProbe:
        httpGet:
          path: /health
          port: 3000
        initialDelaySeconds: 15
        periodSeconds: 20
        failureThreshold: 3
```

---

## SSL/TLS Termination Issues

### Symptom
- `wss://` connections fail but `ws://` works
- ERR_SSL_PROTOCOL_ERROR in browser
- Connections timeout during TLS handshake

### Common Issues and Fixes

**1. TLS termination at load balancer — backend gets HTTP:**

```nginx
# Nginx terminates TLS, forwards as HTTP to backend
server {
    listen 443 ssl;
    ssl_certificate /etc/ssl/cert.pem;
    ssl_certificate_key /etc/ssl/key.pem;

    location /ws {
        # Backend receives ws:// not wss://
        proxy_pass http://backend:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        # Tell backend the original protocol
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**2. Self-signed certificates in development:**

```typescript
// Node.js client connecting to self-signed cert
import WebSocket from 'ws';

const ws = new WebSocket('wss://localhost:3000', {
  rejectUnauthorized: false, // ONLY for development
});
```

**3. Certificate chain incomplete:**

```bash
# Verify certificate chain
openssl s_client -connect api.example.com:443 -servername api.example.com

# Check for "Verify return code: 0 (ok)"
# If not, concatenate intermediate certs:
cat server.crt intermediate.crt > fullchain.pem
```

**4. HTTP/2 with WebSocket:**

HTTP/2 doesn't natively support WebSocket upgrade. Solutions:
- Use HTTP/1.1 for WebSocket endpoints (most common)
- Use RFC 8441 (WebSocket over HTTP/2) if supported by infrastructure
- Separate HTTP/2 for REST and HTTP/1.1 for WebSocket on different ports/paths

```nginx
# Force HTTP/1.1 for WebSocket path
server {
    listen 443 ssl http2;

    location /ws {
        # Override to HTTP/1.1 for WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://backend:3000;
    }

    location / {
        # HTTP/2 for everything else
        proxy_pass http://backend:3000;
    }
}
```

---

## Quick Diagnostic Checklist

Run through this when WebSocket connections are failing:

```
1. ❏ Can you connect with wscat/websocat from the same network?
     wscat -c wss://api.example.com/ws
     → If NO: network/DNS/firewall issue
     → If YES: browser-specific issue (CORS, mixed content)

2. ❏ Check the HTTP upgrade response
     curl -i -N \
       -H "Connection: Upgrade" \
       -H "Upgrade: websocket" \
       -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
       -H "Sec-WebSocket-Version: 13" \
       https://api.example.com/ws
     → Expect: 101 Switching Protocols
     → If 200: proxy not forwarding Upgrade header
     → If 400: missing required headers
     → If 403: origin/auth rejection

3. ❏ Check proxy/LB configuration
     - WebSocket upgrade support enabled?
     - Idle timeout > heartbeat interval?
     - Sticky sessions enabled (if using Socket.IO)?

4. ❏ Check server logs for connection/disconnection events

5. ❏ Check close code when connection drops
     1000 → normal close (intentional)
     1001 → server shutting down
     1006 → abnormal close (no close frame — network issue)
     1008 → policy violation (auth failed)
     1013 → server overloaded

6. ❏ Check for mixed content
     - HTTPS page trying to connect to ws:// → blocked
     - Must use wss:// from HTTPS pages

7. ❏ Monitor server resources
     - File descriptors: ulimit -n (should be >10000)
     - Memory: watch RSS for leaks
     - CPU: check for compression overhead
     - Connections: track wss.clients.size
```
