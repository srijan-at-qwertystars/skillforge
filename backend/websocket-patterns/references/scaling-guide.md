# Scaling WebSockets Guide

## Table of Contents

- [Horizontal Scaling with Sticky Sessions](#horizontal-scaling-with-sticky-sessions)
- [Redis Pub/Sub Adapter for Socket.IO](#redis-pubsub-adapter-for-socketio)
- [NATS for Cross-Server Messaging](#nats-for-cross-server-messaging)
- [Connection Limits Per Server](#connection-limits-per-server)
- [Connection Pooling](#connection-pooling)
- [Kubernetes WebSocket Support](#kubernetes-websocket-support)
- [AWS API Gateway WebSocket API](#aws-api-gateway-websocket-api)
- [Connection Lifecycle Management](#connection-lifecycle-management)
- [Memory Estimation Per Connection](#memory-estimation-per-connection)
- [Scaling Checklist](#scaling-checklist)

---

## Horizontal Scaling with Sticky Sessions

WebSocket connections are stateful — a client must always reach the **same server** for the duration of its connection. Sticky sessions (session affinity) ensure this.

### IP Hash (Layer 4)

```nginx
upstream ws_backend {
    ip_hash;    # same client IP → same backend
    server app1:3000;
    server app2:3000;
    server app3:3000;
}

server {
    listen 443 ssl;
    location /ws {
        proxy_pass http://ws_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
    }
}
```

**Limitations of IP hash:**
- Clients behind NAT/corporate proxy share an IP → all hit one server
- CDN/proxy in front means all traffic appears as one IP
- Not effective with IPv6 (many unique addresses)

### Cookie-Based Sticky Sessions (Layer 7)

```nginx
upstream ws_backend {
    server app1:3000;
    server app2:3000;
    server app3:3000;

    # Nginx Plus (commercial) — cookie-based sticky
    sticky cookie srv_id expires=1h domain=.example.com path=/;
}
```

For open-source Nginx, use the `sticky` module or handle at the application level:

```nginx
# Alternative: use $cookie_ variable
map $cookie_ws_server $ws_target {
    "app1"  app1:3000;
    "app2"  app2:3000;
    default app1:3000;
}

server {
    location /ws {
        proxy_pass http://$ws_target;
        # Set cookie on initial connection
        add_header Set-Cookie "ws_server=$upstream_addr; Path=/; HttpOnly";
    }
}
```

### HAProxy Sticky Sessions

```haproxy
backend ws_servers
    balance roundrobin
    cookie WS_SRV insert indirect nocache
    server app1 app1:3000 check cookie app1
    server app2 app2:3000 check cookie app2
    server app3 app3:3000 check cookie app3

    # WebSocket-specific settings
    option http-server-close
    timeout tunnel 86400s
```

### When Sticky Sessions Are Not Enough

Sticky sessions solve connection routing but NOT cross-server messaging. You still need a message bus (Redis, NATS) for:
- Broadcasting to all clients across servers
- Room-based messaging where room members span servers
- Presence tracking across the cluster

---

## Redis Pub/Sub Adapter for Socket.IO

The Socket.IO Redis adapter broadcasts events across multiple server instances.

### Setup

```typescript
import { Server } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';

const io = new Server(httpServer, {
  cors: { origin: '*' },
  // Important for horizontal scaling
  connectionStateRecovery: {
    maxDisconnectionDuration: 2 * 60 * 1000, // 2 minutes
    skipMiddlewares: true,
  },
});

// Create dedicated pub/sub clients (can't reuse regular Redis client)
const pubClient = createClient({ url: process.env.REDIS_URL || 'redis://redis:6379' });
const subClient = pubClient.duplicate();
await Promise.all([pubClient.connect(), subClient.connect()]);

io.adapter(createAdapter(pubClient, subClient));

// Now io.to(room).emit() works across all server instances
io.on('connection', (socket) => {
  socket.join('global');
  socket.on('message', (data) => {
    // This reaches ALL clients in 'chat' room across ALL servers
    io.to('chat').emit('message', data);
  });
});
```

### Redis Adapter with Sharded Pub/Sub (Redis 7+)

```typescript
import { createAdapter } from '@socket.io/redis-adapter';

// Sharded pub/sub scales better with Redis Cluster
const pubClient = createClient({ url: 'redis://redis:6379' });
const subClient = pubClient.duplicate();
await Promise.all([pubClient.connect(), subClient.connect()]);

io.adapter(createAdapter(pubClient, subClient, {
  key: 'socket.io',              // prefix for Redis keys
  publishOnSpecificResponseChannel: true,  // reduces cross-talk
}));
```

### Monitoring Redis Adapter

```typescript
io.of('/').adapter.on('error', (err) => {
  console.error('Redis adapter error:', err);
});

// Monitor pub/sub latency
const start = Date.now();
await pubClient.publish('__ping__', Date.now().toString());
// Measure roundtrip in subscriber

// Redis MONITOR to see adapter traffic (development only!)
// redis-cli MONITOR | grep socket.io
```

### Redis Adapter Limitations
- **No message persistence** — if a server is down when a message is published, it's lost
- **Redis is single-threaded** — high message throughput can bottleneck Redis
- **Memory** — each adapter message goes through Redis, adding latency (~1ms LAN)
- **Alternative: Redis Streams adapter** (`@socket.io/redis-streams-adapter`) for persistence

---

## NATS for Cross-Server Messaging

NATS provides higher throughput than Redis pub/sub and supports request/reply, queue groups, and JetStream for persistence.

### NATS as WebSocket Message Bus

```typescript
import { connect, StringCodec, JSONCodec } from 'nats';

const nc = await connect({ servers: process.env.NATS_URL || 'nats://nats:4222' });
const jc = JSONCodec();

class NATSMessageBus {
  // Broadcast to all servers
  async publishToRoom(roomId: string, event: string, data: unknown): Promise<void> {
    nc.publish(`ws.room.${roomId}`, jc.encode({ event, data }));
  }

  // Subscribe this server to room events
  subscribeToRoom(roomId: string, handler: (event: string, data: unknown) => void): void {
    const sub = nc.subscribe(`ws.room.${roomId}`);
    (async () => {
      for await (const msg of sub) {
        const { event, data } = jc.decode(msg.data) as any;
        handler(event, data);
      }
    })();
  }

  // Queue group — only ONE server processes each message (load balancing)
  subscribeQueue(subject: string, queue: string, handler: (data: unknown) => void): void {
    const sub = nc.subscribe(subject, { queue });
    (async () => {
      for await (const msg of sub) {
        handler(jc.decode(msg.data));
      }
    })();
  }

  // Request/reply for point-to-point communication
  async request(subject: string, data: unknown, timeoutMs = 5000): Promise<unknown> {
    const resp = await nc.request(subject, jc.encode(data), { timeout: timeoutMs });
    return jc.decode(resp.data);
  }
}
```

### NATS JetStream for Persistent Messaging

```typescript
const js = nc.jetstream();
const jsm = await nc.jetstreamManager();

// Create a stream for WebSocket events
await jsm.streams.add({
  name: 'WS_EVENTS',
  subjects: ['ws.events.>'],
  retention: 'limits',       // or 'workqueue' for exactly-once processing
  max_msgs: 1_000_000,
  max_age: 24 * 60 * 60 * 1e9,  // 24 hours in nanoseconds
  storage: 'memory',         // or 'file' for disk persistence
});

// Publish persistent event
await js.publish('ws.events.chat.room1', jc.encode({
  type: 'message',
  userId: 'user1',
  text: 'hello',
  timestamp: Date.now(),
}));

// Durable consumer — survives server restarts
const consumer = await js.consumers.get('WS_EVENTS', 'ws-server-1');
const messages = await consumer.consume();
for await (const msg of messages) {
  const event = jc.decode(msg.data);
  // Deliver to local WebSocket clients
  deliverToLocalClients(event);
  msg.ack();
}
```

---

## Connection Limits Per Server

### Operating System Limits

```bash
# Check current file descriptor limit
ulimit -n
# Default is often 1024 — far too low for WebSocket servers

# Set per-process limit (temporary)
ulimit -n 65535

# Permanent: /etc/security/limits.conf
*    soft    nofile    65535
*    hard    nofile    65535

# Systemd service override
# /etc/systemd/system/ws-server.service.d/override.conf
[Service]
LimitNOFILE=65535
```

### Kernel Parameters for High Connection Counts

```bash
# /etc/sysctl.conf — apply with sysctl -p

# Max file descriptors system-wide
fs.file-max = 1000000

# TCP tuning for many connections
net.core.somaxconn = 65535          # listen backlog
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535  # outbound port range
net.ipv4.tcp_tw_reuse = 1          # reuse TIME_WAIT sockets
net.core.netdev_max_backlog = 65535

# TCP keepalive (for detecting dead connections at OS level)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# Memory for TCP buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

### Application-Level Limits

```typescript
const MAX_CONNECTIONS = parseInt(process.env.MAX_WS_CONNECTIONS || '10000');

const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: 1 * 1024 * 1024, // 1MB max message size
  verifyClient: (info, callback) => {
    if (wss.clients.size >= MAX_CONNECTIONS) {
      callback(false, 503, 'Server at capacity');
      return;
    }
    callback(true);
  },
});

// Expose metrics for monitoring
app.get('/metrics', (req, res) => {
  res.json({
    connections: wss.clients.size,
    maxConnections: MAX_CONNECTIONS,
    utilization: (wss.clients.size / MAX_CONNECTIONS * 100).toFixed(1) + '%',
    memoryMB: Math.round(process.memoryUsage().rss / 1024 / 1024),
  });
});
```

### Practical Connection Limits by Setup

| Server | Connections | Notes |
|--------|------------|-------|
| Node.js (ws, single core) | 10K–50K | CPU-bound at high message rates |
| Node.js (ws, cluster) | 50K–200K | Use PM2 or cluster module |
| Go (gorilla/websocket) | 100K–1M | Goroutines handle concurrency well |
| Elixir (Phoenix) | 1M–2M | BEAM VM excels at many connections |
| Java (Netty) | 100K–500K | Needs JVM tuning |

---

## Connection Pooling

For server-to-server WebSocket connections (microservices, gateways), pool connections to avoid overhead of repeated handshakes.

```typescript
class WSConnectionPool {
  private pools = new Map<string, WebSocket[]>();
  private maxPoolSize = 10;

  async acquire(url: string): Promise<WebSocket> {
    const pool = this.pools.get(url) || [];

    // Find an available connection
    const available = pool.find(ws => ws.readyState === WebSocket.OPEN);
    if (available) return available;

    // Create new connection if under limit
    if (pool.length < this.maxPoolSize) {
      const ws = await this.createConnection(url);
      pool.push(ws);
      this.pools.set(url, pool);
      return ws;
    }

    // Wait for one to become available
    return this.waitForAvailable(url);
  }

  private createConnection(url: string): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.onopen = () => resolve(ws);
      ws.onerror = () => reject(new Error(`Failed to connect to ${url}`));

      ws.onclose = () => {
        const pool = this.pools.get(url);
        if (pool) {
          const idx = pool.indexOf(ws);
          if (idx !== -1) pool.splice(idx, 1);
        }
      };

      setTimeout(() => reject(new Error('Connection timeout')), 5000);
    });
  }

  private waitForAvailable(url: string): Promise<WebSocket> {
    return new Promise((resolve) => {
      const check = setInterval(() => {
        const pool = this.pools.get(url) || [];
        const available = pool.find(ws => ws.readyState === WebSocket.OPEN);
        if (available) {
          clearInterval(check);
          resolve(available);
        }
      }, 100);
    });
  }

  closeAll(): void {
    this.pools.forEach(pool => {
      pool.forEach(ws => ws.close(1000, 'Pool shutdown'));
    });
    this.pools.clear();
  }
}
```

---

## Kubernetes WebSocket Support

### Ingress Configuration (nginx-ingress)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ws-ingress
  annotations:
    # Critical for WebSocket support
    nginx.ingress.kubernetes.io/proxy-read-timeout: "86400"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "86400"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "10"

    # WebSocket upgrade
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";

    # Sticky sessions for Socket.IO
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/affinity-mode: "persistent"
    nginx.ingress.kubernetes.io/session-cookie-name: "WS_AFFINITY"
    nginx.ingress.kubernetes.io/session-cookie-expires: "86400"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "86400"
    nginx.ingress.kubernetes.io/session-cookie-change-on-failure: "true"
spec:
  rules:
    - host: ws.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ws-service
                port:
                  number: 3000
```

### Service and Deployment

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ws-service
spec:
  selector:
    app: ws-server
  ports:
    - port: 3000
      targetPort: 3000
  # ClusterIP (default) works for ingress
  # Use headless service for direct pod addressing if needed
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ws-server
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: ws-server
  template:
    metadata:
      labels:
        app: ws-server
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: ws-server
          image: ws-server:latest
          ports:
            - containerPort: 3000
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
          env:
            - name: REDIS_URL
              value: "redis://redis-service:6379"
            - name: MAX_WS_CONNECTIONS
              value: "10000"
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
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]  # drain connections
```

### Horizontal Pod Autoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ws-server-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ws-server
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: ws_active_connections
        target:
          type: AverageValue
          averageValue: "8000"  # scale when avg connections per pod > 8000
```

---

## AWS API Gateway WebSocket API

Fully managed WebSocket API — no servers to manage. Pay per connection-minute and message.

### Terraform Configuration

```hcl
resource "aws_apigatewayv2_api" "ws" {
  name                       = "ws-api"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

# Routes
resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.connect.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.disconnect.id}"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.default.id}"
}

resource "aws_apigatewayv2_route" "send_message" {
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = "sendMessage"
  target    = "integrations/${aws_apigatewayv2_integration.send_message.id}"
}

# Lambda integration
resource "aws_apigatewayv2_integration" "connect" {
  api_id           = aws_apigatewayv2_api.ws.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.connect.invoke_arn
}

# Stage & deployment
resource "aws_apigatewayv2_stage" "production" {
  api_id      = aws_apigatewayv2_api.ws.id
  name        = "production"
  auto_deploy = true
}
```

### Lambda Handler for WebSocket

```typescript
import { APIGatewayProxyHandler } from 'aws-lambda';
import { ApiGatewayManagementApi } from '@aws-sdk/client-apigatewaymanagementapi';

// Store connections in DynamoDB
const TABLE = process.env.CONNECTIONS_TABLE!;

export const connectHandler: APIGatewayProxyHandler = async (event) => {
  const connectionId = event.requestContext.connectionId!;
  await dynamodb.put({ TableName: TABLE, Item: { connectionId, connectedAt: Date.now() } });
  return { statusCode: 200, body: 'Connected' };
};

export const disconnectHandler: APIGatewayProxyHandler = async (event) => {
  const connectionId = event.requestContext.connectionId!;
  await dynamodb.delete({ TableName: TABLE, Key: { connectionId } });
  return { statusCode: 200, body: 'Disconnected' };
};

export const sendMessageHandler: APIGatewayProxyHandler = async (event) => {
  const { domainName, stage } = event.requestContext;
  const api = new ApiGatewayManagementApi({
    endpoint: `https://${domainName}/${stage}`,
  });

  const body = JSON.parse(event.body || '{}');
  const connections = await dynamodb.scan({ TableName: TABLE });

  // Broadcast to all connected clients
  const sends = connections.Items!.map(async ({ connectionId }) => {
    try {
      await api.postToConnection({
        ConnectionId: connectionId,
        Data: Buffer.from(JSON.stringify(body)),
      });
    } catch (err: any) {
      if (err.statusCode === 410) {
        // Connection is stale — remove
        await dynamodb.delete({ TableName: TABLE, Key: { connectionId } });
      }
    }
  });

  await Promise.all(sends);
  return { statusCode: 200, body: 'Sent' };
};
```

### AWS API Gateway Limits
| Limit | Value |
|-------|-------|
| Max connection duration | 2 hours |
| Idle timeout | 10 minutes |
| Max message size | 128 KB (32 KB default) |
| Max concurrent connections | 500 (soft limit, requestable to 10K+) |
| Pricing | $1 per million messages + $0.25 per million connection-minutes |

---

## Connection Lifecycle Management

### Graceful Shutdown

```typescript
let isShuttingDown = false;

async function gracefulShutdown(signal: string): Promise<void> {
  console.log(`Received ${signal}, starting graceful shutdown...`);
  isShuttingDown = true;

  // 1. Stop accepting new connections
  wss.close();

  // 2. Notify all clients with close code 1012 (service restart)
  const closePromises: Promise<void>[] = [];
  wss.clients.forEach(ws => {
    closePromises.push(new Promise((resolve) => {
      ws.send(JSON.stringify({ type: 'server:shutdown', retryAfter: 5000 }));
      ws.close(1012, 'Service restart');
      ws.on('close', resolve);
      setTimeout(resolve, 5000); // force resolve after 5s
    }));
  });

  // 3. Wait for connections to drain (max 30s)
  await Promise.race([
    Promise.all(closePromises),
    new Promise(resolve => setTimeout(resolve, 30000)),
  ]);

  // 4. Force terminate remaining connections
  wss.clients.forEach(ws => ws.terminate());

  // 5. Clean up resources
  clearInterval(heartbeatInterval);
  await redis.quit();
  httpServer.close();

  console.log('Shutdown complete');
  process.exit(0);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Reject new connections during shutdown
wss.on('connection', (ws) => {
  if (isShuttingDown) {
    ws.close(1013, 'Server shutting down');
    return;
  }
  // ... normal handling
});
```

### Connection Health Monitoring

```typescript
class ConnectionMonitor {
  private metrics = {
    totalConnections: 0,
    activeConnections: 0,
    messagesIn: 0,
    messagesOut: 0,
    bytesIn: 0,
    bytesOut: 0,
    errors: 0,
    avgLatencyMs: 0,
  };

  track(wss: WebSocketServer): void {
    wss.on('connection', (ws) => {
      this.metrics.totalConnections++;
      this.metrics.activeConnections++;

      ws.on('message', (data: Buffer) => {
        this.metrics.messagesIn++;
        this.metrics.bytesIn += data.byteLength;
      });

      ws.on('close', () => {
        this.metrics.activeConnections--;
      });

      ws.on('error', () => {
        this.metrics.errors++;
      });
    });
  }

  getMetrics(): typeof this.metrics {
    return { ...this.metrics };
  }

  // Prometheus format
  toPrometheus(): string {
    return [
      `ws_connections_total ${this.metrics.totalConnections}`,
      `ws_connections_active ${this.metrics.activeConnections}`,
      `ws_messages_in_total ${this.metrics.messagesIn}`,
      `ws_messages_out_total ${this.metrics.messagesOut}`,
      `ws_bytes_in_total ${this.metrics.bytesIn}`,
      `ws_bytes_out_total ${this.metrics.bytesOut}`,
      `ws_errors_total ${this.metrics.errors}`,
    ].join('\n');
  }
}
```

---

## Memory Estimation Per Connection

### Baseline Memory Per WebSocket Connection

| Component | Memory | Notes |
|-----------|--------|-------|
| TCP socket (kernel) | ~3–10 KB | Depends on buffer sizes |
| Node.js `ws` object | ~1–2 KB | JavaScript object overhead |
| Application state | ~0.5–5 KB | User data, subscriptions, metadata |
| Send/receive buffers | ~8–32 KB | Default TCP buffer sizes |
| TLS state (wss://) | ~20–50 KB | Per-connection TLS session |
| Compression context | ~300 KB | If `perMessageDeflate` enabled with context takeover |
| **Total (no TLS, no compression)** | **~15 KB** | |
| **Total (TLS, no compression)** | **~50 KB** | |
| **Total (TLS + compression)** | **~350 KB** | |

### Capacity Planning Formula

```
Max connections = Available memory / Memory per connection

Example: 4GB server, TLS, no compression
  Available for WS = 4096MB - 512MB (OS) - 256MB (app base) = 3328MB
  Memory per connection = 50KB
  Max connections = 3328MB / 50KB ≈ 66,560 connections

Example: 4GB server, TLS + compression (context takeover)
  Max connections = 3328MB / 350KB ≈ 9,508 connections
  → Disable context takeover: 3328MB / 80KB ≈ 41,600 connections
```

### Reducing Memory Per Connection

```typescript
const wss = new WebSocketServer({
  server: httpServer,
  maxPayload: 64 * 1024,         // 64KB max message (default 100MB!)
  perMessageDeflate: {
    serverNoContextTakeover: true, // saves ~300KB per connection
    clientNoContextTakeover: true,
    threshold: 1024,               // only compress messages > 1KB
  },
  // Reduce backpressure buffer
  backlog: 512,
});

// Minimize per-connection state
wss.on('connection', (ws) => {
  // ❌ Don't store large objects on the ws object
  // ws.history = getAllMessages(); // could be MBs

  // ✅ Store minimal identifiers, look up on demand
  ws.userId = 'user123';
  ws.roomId = 'room456';
});
```

### Monitoring Memory

```bash
# Real-time memory monitoring
watch -n 5 'echo "Connections: $(curl -s localhost:3000/metrics | jq .connections)" && \
  echo "RSS: $(ps -o rss= -p $(pgrep -f "node server")) KB"'

# Calculate per-connection memory
# Take RSS with 0 connections, then with N connections
# Per-conn = (RSS_N - RSS_0) / N
```

---

## Scaling Checklist

### Before Going to Production

```
Infrastructure:
  ❏ ulimit -n set to 65535+ on all servers
  ❏ Kernel TCP parameters tuned (somaxconn, tcp_max_syn_backlog)
  ❏ Load balancer configured with WebSocket upgrade support
  ❏ Sticky sessions enabled (if using Socket.IO or stateful protocol)
  ❏ Idle timeouts set > heartbeat interval on ALL layers
  ❏ TLS termination configured (at LB or app level)
  ❏ Health check endpoint returns connection count and readiness

Application:
  ❏ Server-side heartbeat (ping every 30s, terminate after 2 missed pongs)
  ❏ Client-side reconnection with jittered exponential backoff
  ❏ Graceful shutdown (SIGTERM → drain → terminate)
  ❏ Max payload size configured
  ❏ Rate limiting per connection (messages/second)
  ❏ Message validation on all inbound messages
  ❏ Authentication during handshake (not after)
  ❏ Connection count limit per server

Scaling:
  ❏ Message bus (Redis/NATS) for cross-server broadcast
  ❏ Connection state externalized (not in-process memory)
  ❏ Memory estimation done — know your per-connection cost
  ❏ Autoscaling configured based on connection count or CPU
  ❏ Rolling deployment strategy (not all-at-once)

Monitoring:
  ❏ Connection count metric (active, total, per-room)
  ❏ Message rate metric (in/out per second)
  ❏ Error rate metric (connection errors, message errors)
  ❏ Memory usage tracking (RSS, heap)
  ❏ Latency measurement (message round-trip time)
  ❏ Alert on connection count approaching limit
  ❏ Alert on memory growth trend
  ❏ Dashboard for real-time visibility
```
