# gRPC Troubleshooting Guide

## Table of Contents

- [Connection Refused Debugging](#connection-refused-debugging)
- [TLS Certificate Errors](#tls-certificate-errors)
- [Proto Compatibility Breaks](#proto-compatibility-breaks)
- [Deadline Exceeded Causes](#deadline-exceeded-causes)
- [Resource Exhaustion](#resource-exhaustion)
- [HTTP/2 GOAWAY Frames](#http2-goaway-frames)
- [Load Balancer Misconfiguration (L4 vs L7)](#load-balancer-misconfiguration-l4-vs-l7)
- [gRPC-Web Proxy Issues](#grpc-web-proxy-issues)
- [Code Generation Conflicts](#code-generation-conflicts)
- [Performance Profiling with Channelz](#performance-profiling-with-channelz)

---

## Connection Refused Debugging

**Symptoms:** `rpc error: code = Unavailable desc = connection error: connection refused`

**Diagnostic checklist:**

1. **Server not running or wrong port:**
   ```bash
   # Check if the port is listening
   ss -tlnp | grep 50051
   netstat -tlnp | grep 50051
   
   # Test raw TCP connectivity
   nc -zv localhost 50051
   ```

2. **Binding to wrong interface:**
   ```go
   // WRONG: only accepts localhost connections
   lis, _ := net.Listen("tcp", "127.0.0.1:50051")
   
   // RIGHT: accepts connections from any interface
   lis, _ := net.Listen("tcp", ":50051")
   lis, _ := net.Listen("tcp", "0.0.0.0:50051")
   ```

3. **DNS resolution failure:**
   ```bash
   # Verify DNS resolution
   dig order-service.default.svc.cluster.local
   nslookup order-service
   
   # Test with grpcurl using IP directly
   grpcurl -plaintext 10.0.1.5:50051 list
   ```

4. **Kubernetes service issues:**
   ```bash
   # Check endpoints exist
   kubectl get endpoints order-service
   
   # Check pod is ready
   kubectl get pods -l app=order-service
   
   # Check service port mapping
   kubectl describe svc order-service
   ```

5. **Firewall / security group:**
   ```bash
   # Check iptables
   iptables -L -n | grep 50051
   
   # Test from within the same network
   kubectl exec -it debug-pod -- nc -zv order-service 50051
   ```

**Enable verbose gRPC logging for deeper diagnosis:**

```bash
# Go
GRPC_GO_LOG_SEVERITY_LEVEL=info GRPC_GO_LOG_VERBOSITY_LEVEL=99 ./myserver

# Environment variable for all languages
GRPC_VERBOSITY=DEBUG GRPC_TRACE=all ./myserver
```

---

## TLS Certificate Errors

**Common errors and fixes:**

### `transport: authentication handshake failed: tls: first record does not look like a TLS handshake`

Client is using TLS but server is running in plaintext (or vice versa).

```go
// Mismatch: server is insecure, client uses TLS
// Server
lis, _ := net.Listen("tcp", ":50051")
srv := grpc.NewServer() // No TLS

// Client — this will fail
creds, _ := credentials.NewClientTLSFromFile("ca.crt", "")
conn, _ := grpc.NewClient("localhost:50051", grpc.WithTransportCredentials(creds))

// Fix: both must agree on TLS or plaintext
```

### `certificate signed by unknown authority`

Client doesn't trust the server's CA.

```go
// Fix 1: Provide the CA cert
creds, _ := credentials.NewClientTLSFromFile("path/to/ca.crt", "server-name")

// Fix 2: Use system cert pool (if CA is publicly trusted)
creds := credentials.NewTLS(&tls.Config{})

// Fix 3: Skip verification (DEVELOPMENT ONLY)
creds := credentials.NewTLS(&tls.Config{InsecureSkipVerify: true})
```

### `certificate is valid for X, not Y`

Server name doesn't match the certificate's SAN (Subject Alternative Name).

```bash
# Check what names the cert is valid for
openssl x509 -in server.crt -noout -text | grep -A1 "Subject Alternative Name"

# Generate cert with correct SAN
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 \
  -subj "/CN=order-service" \
  -addext "subjectAltName=DNS:order-service,DNS:order-service.default.svc.cluster.local,IP:10.0.1.5"
```

### `certificate has expired`

```bash
# Check certificate expiry
openssl x509 -in server.crt -noout -dates

# Check remote server's cert
openssl s_client -connect order-service:50051 </dev/null 2>/dev/null | openssl x509 -noout -dates
```

### mTLS Issues

```go
// Server requiring client certs
certPool := x509.NewCertPool()
ca, _ := os.ReadFile("ca.crt")
certPool.AppendCertsFromPEM(ca)
creds := credentials.NewTLS(&tls.Config{
    Certificates: []tls.Certificate{serverCert},
    ClientAuth:   tls.RequireAndVerifyClientCert,
    ClientCAs:    certPool,
})

// Client providing its cert
clientCert, _ := tls.LoadX509KeyPair("client.crt", "client.key")
creds := credentials.NewTLS(&tls.Config{
    Certificates: []tls.Certificate{clientCert},
    RootCAs:      certPool,
})
```

---

## Proto Compatibility Breaks

### Detecting Breaking Changes

```bash
# Using buf
buf breaking --against '.git#branch=main'
buf breaking --against 'buf.build/myorg/myservice'

# Common breaking changes detected:
# - Field number changed
# - Field type changed
# - Required field added (proto2)
# - Enum value removed
# - Service/method removed
# - Message removed
```

### Common Compatibility Mistakes

**Changing field types:**
```protobuf
// v1: string id = 1;
// v2: int64 id = 1;   // BREAKING: wire format changes
```

**Reusing deleted field numbers:**
```protobuf
message Order {
  // Field 3 was "string description" but removed
  // WRONG: reusing field 3 with different type
  int32 priority = 3;
  
  // RIGHT: reserve the field number
  reserved 3;
  reserved "description";
  string priority_label = 7; // new field number
}
```

**Changing enum semantics:**
```protobuf
// v1
enum Status {
  STATUS_UNSPECIFIED = 0;
  STATUS_ACTIVE = 1;    // Means "running"
  STATUS_INACTIVE = 2;  // Means "stopped"
}

// v2 — changing what 1 means is breaking even if names stay the same
```

**Renaming without reserving:**
```protobuf
// v1: string customer_name = 5;
// v2: string client_name = 5;
// Wire-compatible but JSON serialization breaks (field name changes)
```

### Safe Evolution Patterns

```protobuf
message Order {
  string id = 1;
  // Safe: add new fields with new numbers
  string tracking_number = 8;
  // Safe: add new optional wrapper
  google.protobuf.StringValue notes = 9;
  // Safe: deprecate (don't remove)
  string old_field = 4 [deprecated = true];
}
```

---

## Deadline Exceeded Causes

**Symptoms:** `rpc error: code = DeadlineExceeded desc = context deadline exceeded`

### Common Causes

1. **Deadline too short:**
   ```go
   // 100ms might be too short for a database call
   ctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
   ```

2. **Deadline not propagated correctly:**
   ```go
   // WRONG: creating new context loses parent deadline
   func (s *server) GetOrder(ctx context.Context, req *pb.GetOrderRequest) (*pb.Order, error) {
       newCtx := context.Background() // Loses deadline!
       return s.db.GetOrder(newCtx, req.Id)
   }
   
   // RIGHT: use incoming context
   func (s *server) GetOrder(ctx context.Context, req *pb.GetOrderRequest) (*pb.Order, error) {
       return s.db.GetOrder(ctx, req.Id) // Deadline propagates
   }
   ```

3. **Cascading deadlines in call chains:**
   ```
   Client (5s deadline) → Service A (processes 3s) → Service B (only 2s remaining)
   ```
   Fix: check remaining deadline before making downstream calls:
   ```go
   deadline, ok := ctx.Deadline()
   if ok && time.Until(deadline) < 500*time.Millisecond {
       return nil, status.Errorf(codes.DeadlineExceeded, "insufficient time for downstream call")
   }
   ```

4. **Slow server processing:**
   - Database queries taking too long
   - External API calls without their own timeouts
   - Lock contention
   - GC pauses

5. **Network latency:**
   - Cross-region calls
   - DNS resolution delays
   - TLS handshake overhead on first connection

### Debugging

```go
// Log remaining deadline in interceptor
func deadlineInterceptor(ctx context.Context, req interface{},
    info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
    if deadline, ok := ctx.Deadline(); ok {
        log.Printf("method=%s remaining=%s", info.FullMethod, time.Until(deadline))
    }
    return handler(ctx, req)
}
```

---

## Resource Exhaustion

### Too Many Concurrent Streams

**Symptoms:** `rpc error: code = Unavailable desc = transport: received the unexpected content-type`
or new RPCs hang/fail.

```go
// Limit concurrent streams per connection
srv := grpc.NewServer(
    grpc.MaxConcurrentStreams(100), // Default is unlimited
)
```

### Memory Exhaustion from Large Messages

```go
// Set receive limits
srv := grpc.NewServer(
    grpc.MaxRecvMsgSize(4 * 1024 * 1024), // 4 MB (default)
)

// Client-side send limit
conn, _ := grpc.NewClient(addr,
    grpc.WithDefaultCallOptions(
        grpc.MaxCallSendMsgSize(4*1024*1024),
    ),
)
```

### Connection Exhaustion

```go
// Monitor with channelz
import "google.golang.org/grpc/channelz/service"
service.RegisterChannelzServiceToServer(srv)

// Check from grpcurl
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetTopChannels
```

### Goroutine Leaks (Go-specific)

Common with streaming RPCs when not properly closing:

```go
// WRONG: goroutine leak if context is cancelled
go func() {
    for {
        msg, err := stream.Recv()
        if err != nil {
            return // Who cleans up?
        }
        process(msg)
    }
}()

// RIGHT: respect context
go func() {
    for {
        select {
        case <-stream.Context().Done():
            return
        default:
            msg, err := stream.Recv()
            if err != nil {
                return
            }
            process(msg)
        }
    }
}()
```

### Thread Pool Exhaustion (Python)

```python
# Default is 10 workers — too low for production
server = grpc.server(
    futures.ThreadPoolExecutor(max_workers=10),  # PROBLEM
    maximum_concurrent_rpcs=200,
)

# Fix: size the pool appropriately
server = grpc.server(
    futures.ThreadPoolExecutor(max_workers=50),
    maximum_concurrent_rpcs=200,
)
```

---

## HTTP/2 GOAWAY Frames

**Symptoms:** Client sees `transport is closing` or connections drop unexpectedly.

### What Causes GOAWAY

1. **Server graceful shutdown:**
   ```go
   srv.GracefulStop() // Sends GOAWAY, waits for in-flight RPCs
   ```

2. **MaxConnectionAge reached:**
   ```go
   grpc.KeepaliveParams(keepalive.ServerParameters{
       MaxConnectionAge: 30 * time.Minute,
   })
   ```

3. **Too many pings (ENHANCE_YOUR_CALM):**
   ```
   GOAWAY with error code ENHANCE_YOUR_CALM, debug data "too_many_pings"
   ```
   Fix: increase client ping interval or set server's `MinTime` lower:
   ```go
   // Server: allow more frequent pings
   grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
       MinTime:             10 * time.Second,
       PermitWithoutStream: true,
   })
   // Client: don't ping too often
   grpc.WithKeepaliveParams(keepalive.ClientParameters{
       Time: 30 * time.Second,
   })
   ```

4. **Load balancer idle timeout:**
   - AWS ALB: 60s idle timeout
   - GCP: 10 min idle timeout
   - Fix: keepalive pings below the LB timeout

5. **Protocol errors:**
   ```
   GOAWAY with error code PROTOCOL_ERROR
   ```
   Usually indicates HTTP/2 framing issues — check proxy configuration.

### Client-Side Handling

gRPC clients automatically reconnect after GOAWAY. Ensure:

```go
conn, _ := grpc.NewClient(addr,
    grpc.WithConnectParams(grpc.ConnectParams{
        Backoff: backoff.Config{
            BaseDelay:  1 * time.Second,
            Multiplier: 1.6,
            Jitter:     0.2,
            MaxDelay:   120 * time.Second,
        },
        MinConnectTimeout: 20 * time.Second,
    }),
)
```

---

## Load Balancer Misconfiguration (L4 vs L7)

### The Problem

gRPC uses HTTP/2, which multiplexes many RPCs over one TCP connection. An L4 (TCP) load balancer sees one connection and sends all traffic to one backend.

### L4 Load Balancer (TCP)

**Symptoms:** All requests hit one backend; other backends are idle.

```
Client → L4 LB → Backend 1 (all traffic)
                  Backend 2 (idle)
                  Backend 3 (idle)
```

**Fixes:**
1. Switch to an L7 (HTTP/2-aware) load balancer
2. Use client-side load balancing:
   ```go
   conn, _ := grpc.NewClient("dns:///my-service:50051",
       grpc.WithDefaultServiceConfig(`{"loadBalancingConfig":[{"round_robin":{}}]}`),
   )
   ```
3. Set `MaxConnectionAge` on server to force periodic reconnections

### L7 Load Balancer (HTTP/2)

Must be configured for HTTP/2 upstream:

**NGINX:**
```nginx
upstream grpc_backends {
    server backend1:50051;
    server backend2:50051;
}

server {
    listen 443 ssl http2;
    
    location / {
        grpc_pass grpc://grpc_backends;
        # Must use HTTP/2 to backends
    }
}
```

**AWS ALB:**
- Target group protocol must be `gRPC` or `HTTP/2`
- Health check must use gRPC health checking protocol
- Idle timeout affects long-lived streams

**GCP:**
- Use `HTTP/2` backend protocol
- Enable gRPC health checks
- Set connection draining timeout ≥ longest expected RPC

### Kubernetes Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "GRPC"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  rules:
    - host: grpc.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: order-service
                port:
                  number: 50051
```

---

## gRPC-Web Proxy Issues

### CORS Errors

**Symptoms:** `Access-Control-Allow-Origin` missing, browser blocks requests.

**Envoy fix:**
```yaml
http_filters:
  - name: envoy.filters.http.cors
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors
  - name: envoy.filters.http.grpc_web
route_config:
  virtual_hosts:
    - cors_policy:
        allow_origin_string_match:
          - safe_regex: { regex: ".*" }
        allow_methods: "GET, PUT, DELETE, POST, OPTIONS"
        allow_headers: "content-type, x-grpc-web, x-user-agent"
        expose_headers: "grpc-status, grpc-message"
        max_age: "1728000"
```

### Content-Type Mismatch

gRPC-Web uses `application/grpc-web` or `application/grpc-web+proto`, not `application/grpc`. Ensure the proxy translates correctly.

```bash
# Debug: check what content-type the browser sends
curl -v -X POST https://api.example.com/orders.v1.OrderService/CreateOrder \
  -H "Content-Type: application/grpc-web+proto" \
  -H "X-Grpc-Web: 1"
```

### Streaming Limitations

gRPC-Web supports:
- ✅ Unary RPCs
- ✅ Server streaming (using `application/grpc-web-text` with base64 encoding)
- ❌ Client streaming (not supported)
- ❌ Bidirectional streaming (not supported)

For full streaming in browsers, use **Connect protocol** (`@connectrpc/connect-web`) which supports all RPC types via WebSocket or HTTP/2.

### Proxy Not Translating Trailers

gRPC sends status in HTTP/2 trailers. gRPC-Web encodes them in the response body. If your proxy doesn't handle this:

```
Error: Response closed without grpc-status (Headers only)
```

**Fix:** Ensure `envoy.filters.http.grpc_web` filter is in the chain *before* the router.

---

## Code Generation Conflicts

### Duplicate Symbols

**Symptoms:** `proto: duplicate proto type registered`

```bash
# Find the conflict
grep -r "RegisterType" gen/ | sort | uniq -d

# Common cause: multiple versions of the same proto in different packages
# Fix: ensure only one copy of each proto is generated
```

### Import Path Conflicts (Go)

```protobuf
// WRONG: inconsistent go_package across files
// file1.proto: option go_package = "github.com/myorg/api/orders";
// file2.proto: option go_package = "github.com/myorg/api/orders/v1";

// RIGHT: consistent go_package
// file1.proto: option go_package = "github.com/myorg/api/orders/v1;ordersv1";
// file2.proto: option go_package = "github.com/myorg/api/orders/v1;ordersv1";
```

### buf vs protoc Conflicts

If using both `buf generate` and `protoc` in the same project:
- Generated code may differ between tools
- Lock file conflicts
- Different plugin versions

**Fix:** Standardize on one tool (prefer `buf`). Remove `protoc` invocations from Makefiles.

### Plugin Version Mismatch

```bash
# Check installed versions
protoc --version
protoc-gen-go --version
protoc-gen-go-grpc --version
buf --version

# Ensure plugin versions match proto library versions
go list -m google.golang.org/protobuf
go list -m google.golang.org/grpc
```

### Stale Generated Code

```bash
# Clean and regenerate
rm -rf gen/
buf generate

# Add to CI
buf generate
git diff --exit-code gen/ || (echo "Generated code is stale" && exit 1)
```

---

## Performance Profiling with Channelz

Channelz provides real-time introspection into gRPC internals: channels, subchannels, sockets, and servers.

### Enabling Channelz

```go
import "google.golang.org/grpc/channelz/service"

srv := grpc.NewServer()
service.RegisterChannelzServiceToServer(srv)
```

### Querying Channelz

```bash
# Get top-level channels
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetTopChannels

# Get server info
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetServers

# Get socket details (for connection metrics)
grpcurl -plaintext -d '{"socket_id": 1}' localhost:50051 grpc.channelz.v1.Channelz/GetSocket
```

### What Channelz Shows

| Metric | What It Tells You |
|--------|-------------------|
| `calls_started` | Total RPCs initiated |
| `calls_succeeded` | RPCs completed successfully |
| `calls_failed` | RPCs that returned errors |
| `last_call_started_timestamp` | When the last RPC was made |
| `streams_started` / `streams_succeeded` | Stream lifecycle |
| `messages_sent` / `messages_received` | Message counts per socket |
| `keepalives_sent` | Keepalive ping activity |
| `local_flow_control_window` | Available flow control window |
| `remote_flow_control_window` | Peer's available window |

### Identifying Issues

**Connection imbalance:**
```bash
# Check subchannel distribution
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetTopChannels | \
  jq '.channel[].data.calls_started'
# If one subchannel has far more calls, load balancing is broken
```

**Flow control bottleneck:**
```bash
# Check socket-level flow control windows
grpcurl -plaintext -d '{"socket_id": 1}' localhost:50051 \
  grpc.channelz.v1.Channelz/GetSocket | jq '.socket.data'
# Low local_flow_control_window = receiver is slow
# Low remote_flow_control_window = sender is being throttled
```

**Stale connections:**
```bash
# Look for channels with no recent activity
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetTopChannels | \
  jq '.channel[] | {id: .ref.channel_id, last: .data.last_call_started_timestamp}'
```

### Alternative: gRPC Prometheus Metrics

```go
import grpc_prometheus "github.com/grpc-ecosystem/go-grpc-prometheus"

srv := grpc.NewServer(
    grpc.UnaryInterceptor(grpc_prometheus.UnaryServerInterceptor),
    grpc.StreamInterceptor(grpc_prometheus.StreamServerInterceptor),
)
grpc_prometheus.Register(srv)
grpc_prometheus.EnableHandlingTimeHistogram()

// Expose metrics endpoint
http.Handle("/metrics", promhttp.Handler())
```

**Key Prometheus metrics:**
- `grpc_server_handled_total` — RPC count by method and status code
- `grpc_server_handling_seconds` — Latency histogram
- `grpc_server_msg_received_total` — Messages received (useful for streams)
- `grpc_server_started_total` — RPCs started (compare with handled for in-flight)
