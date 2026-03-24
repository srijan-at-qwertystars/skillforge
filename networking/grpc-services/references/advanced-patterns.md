# Advanced gRPC Patterns

> Dense reference for production gRPC patterns. Each section is self-contained.

## Table of Contents

- [Streaming Best Practices](#streaming-best-practices)
- [Flow Control](#flow-control)
- [Keepalive Tuning](#keepalive-tuning)
- [Connection Management](#connection-management)
- [Retry Policies](#retry-policies)
- [Hedging](#hedging)
- [Service Mesh Integration (Istio/Envoy)](#service-mesh-integration)
- [gRPC-Web Proxying](#grpc-web-proxying)
- [Reflection for Debugging](#reflection-for-debugging)
- [Channelz](#channelz)
- [xDS Load Balancing](#xds-load-balancing)
- [Custom Codecs](#custom-codecs)
- [Compression](#compression)
- [Large Message Handling](#large-message-handling)
- [Protobuf Evolution Strategies](#protobuf-evolution-strategies)

---

## Streaming Best Practices

### Server Streaming

Use for: event feeds, watch APIs, large result sets, real-time updates.

```go
func (s *server) WatchOrders(req *pb.WatchRequest, stream pb.OrderService_WatchOrdersServer) error {
    ctx := stream.Context()
    ch := s.subscribeOrders(req.GetFilter())
    defer s.unsubscribe(ch)

    for {
        select {
        case <-ctx.Done():
            return ctx.Err() // Client cancelled or deadline exceeded
        case order, ok := <-ch:
            if !ok {
                return nil // Channel closed, stream ends cleanly
            }
            if err := stream.Send(order); err != nil {
                return err // Client disconnected
            }
        }
    }
}
```

**Rules:**
- Always check `ctx.Done()` in the loop — clients may cancel at any time.
- Return `nil` for normal completion, `status.Error` for abnormal.
- Don't hold locks while calling `Send()` — it blocks on flow control.
- Use `SendMsg` for zero-copy if your message is already marshalled.

### Client Streaming

Use for: file uploads, batch ingestion, aggregation.

```go
func (s *server) BatchIngest(stream pb.DataService_BatchIngestServer) error {
    var count int
    for {
        item, err := stream.Recv()
        if err == io.EOF {
            return stream.SendAndClose(&pb.BatchResponse{Processed: int32(count)})
        }
        if err != nil {
            return err
        }
        if err := s.process(item); err != nil {
            return status.Errorf(codes.Internal, "failed item %d: %v", count, err)
        }
        count++
    }
}
```

### Bidirectional Streaming

Use for: chat, collaborative editing, real-time sync.

```go
func (s *server) Chat(stream pb.ChatService_ChatServer) error {
    ctx := stream.Context()
    errCh := make(chan error, 1)

    // Receive goroutine
    go func() {
        for {
            msg, err := stream.Recv()
            if err == io.EOF {
                errCh <- nil
                return
            }
            if err != nil {
                errCh <- err
                return
            }
            s.broadcast(msg)
        }
    }()

    // Send loop
    ch := s.subscribe()
    defer s.unsubscribe(ch)
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case err := <-errCh:
            return err
        case msg := <-ch:
            if err := stream.Send(msg); err != nil {
                return err
            }
        }
    }
}
```

**Key patterns:**
- Separate recv/send goroutines for bidi — recv is blocking.
- Use an error channel to propagate recv errors to the send loop.
- Always handle `io.EOF` on recv — it signals the client closed its half.

### Streaming Metadata

```go
// Server: send headers before first message, trailers after last
func (s *server) StreamData(req *pb.Req, stream pb.Svc_StreamDataServer) error {
    stream.SendHeader(metadata.Pairs("x-stream-id", "abc123"))
    // ... send messages ...
    stream.SetTrailer(metadata.Pairs("x-item-count", "42"))
    return nil
}

// Client: read headers and trailers
header, _ := stream.Header()
// ... recv messages ...
trailer := stream.Trailer()
```

---

## Flow Control

gRPC uses HTTP/2 flow control windows. Defaults:
- Initial window: 64KB per stream, 64KB per connection (Go).
- BDP (Bandwidth Delay Product) estimation: auto-adjusts in grpc-go.

### Tuning Flow Control (Go)

```go
grpc.NewServer(
    grpc.InitialWindowSize(1 << 20),     // 1MB per stream
    grpc.InitialConnWindowSize(1 << 20), // 1MB per connection
)

grpc.NewClient(target,
    grpc.WithInitialWindowSize(1 << 20),
    grpc.WithInitialConnWindowSize(1 << 20),
)
```

### When to Tune

- **High throughput streaming**: Increase window to avoid stalls.
- **Many concurrent streams**: Increase connection window proportionally.
- **High latency links**: Larger windows fill the BDP.
- **Memory constrained**: Keep defaults or reduce.

### Backpressure in Streaming

`Send()` blocks when the flow control window is exhausted. This is intentional backpressure. Don't buffer unboundedly on the send side:

```go
// BAD: unbounded buffer
for item := range items {
    buffer = append(buffer, item) // OOM risk
}

// GOOD: let Send() apply backpressure
for item := range items {
    if err := stream.Send(item); err != nil { // Blocks when window full
        return err
    }
}
```

---

## Keepalive Tuning

Keepalives detect dead connections and keep NAT/firewall mappings alive.

### Server-Side Keepalive (Go)

```go
grpc.NewServer(
    grpc.KeepaliveParams(keepalive.ServerParameters{
        MaxConnectionIdle:     15 * time.Minute, // Close idle connections
        MaxConnectionAge:      30 * time.Minute, // Force reconnect for LB
        MaxConnectionAgeGrace: 5 * time.Second,  // Grace period after age
        Time:                  5 * time.Minute,  // Ping interval if idle
        Timeout:               1 * time.Second,  // Wait for ping ack
    }),
    grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
        MinTime:             5 * time.Second, // Min allowed ping interval
        PermitWithoutStream: true,            // Allow pings with no streams
    }),
)
```

### Client-Side Keepalive (Go)

```go
grpc.NewClient(target,
    grpc.WithKeepaliveParams(keepalive.ClientParameters{
        Time:                10 * time.Second, // Ping interval when idle
        Timeout:             3 * time.Second,  // Ping ack deadline
        PermitWithoutStream: true,             // Ping even with no streams
    }),
)
```

### Common Keepalive Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `transport is closing` | Server `MaxConnectionAge` too low | Increase age or handle reconnects |
| `GOAWAY` flood | Client pings too fast | Client `Time` >= server `MinTime` |
| Connections drop behind NAT | No keepalive | Enable with `Time` < NAT timeout (often 60s) |
| Idle connections pile up | No `MaxConnectionIdle` | Set to 5–15 minutes |

---

## Connection Management

### Channel Pooling

A single `grpc.ClientConn` multiplexes streams. One connection usually suffices. Pool only when:
- Target is a single IP (no LB) and you need parallelism beyond HTTP/2 limits.
- You're hitting max concurrent streams per connection (default: 100).

```go
type ConnPool struct {
    conns []*grpc.ClientConn
    idx   atomic.Uint64
}

func (p *ConnPool) Get() *grpc.ClientConn {
    return p.conns[p.idx.Add(1)%uint64(len(p.conns))]
}
```

### Graceful Drain

```go
// Server: stop accepting new RPCs, wait for in-flight
s.GracefulStop()

// Or with timeout
go func() {
    time.Sleep(30 * time.Second)
    s.Stop() // Force if graceful takes too long
}()
s.GracefulStop()
```

### Resolver and Balancer

```go
// DNS resolver with round-robin
conn, _ := grpc.NewClient(
    "dns:///my-service.prod.svc.cluster.local:50051",
    grpc.WithDefaultServiceConfig(`{"loadBalancingConfig":[{"round_robin":{}}]}`),
)
```

DNS resolver re-resolves on connection failure. Set `dns:///` scheme explicitly.

---

## Retry Policies

Configured via service config JSON. Retries are transparent to application code.

```go
serviceConfig := `{
    "methodConfig": [{
        "name": [{"service": "acme.payments.v1.PaymentService"}],
        "retryPolicy": {
            "maxAttempts": 4,
            "initialBackoff": "0.1s",
            "maxBackoff": "1s",
            "backoffMultiplier": 2,
            "retryableStatusCodes": ["UNAVAILABLE", "RESOURCE_EXHAUSTED"]
        }
    }]
}`

conn, _ := grpc.NewClient(target,
    grpc.WithDefaultServiceConfig(serviceConfig),
)
```

**Rules:**
- Only retry on `UNAVAILABLE` and `RESOURCE_EXHAUSTED` by default.
- Never retry `INVALID_ARGUMENT`, `NOT_FOUND`, `ALREADY_EXISTS`.
- `maxAttempts` includes the original — so 4 means 1 original + 3 retries.
- Server must return `UNAVAILABLE` (not `INTERNAL`) for transient failures.
- Retry buffer limit: 8KB per call by default. Large requests may not retry.

### Per-Method Config

```json
{
    "methodConfig": [
        {
            "name": [{"service": "acme.payments.v1.PaymentService", "method": "GetPayment"}],
            "timeout": "5s",
            "retryPolicy": {
                "maxAttempts": 3,
                "initialBackoff": "0.05s",
                "maxBackoff": "0.5s",
                "backoffMultiplier": 2,
                "retryableStatusCodes": ["UNAVAILABLE"]
            }
        },
        {
            "name": [{"service": "acme.payments.v1.PaymentService", "method": "CreatePayment"}],
            "timeout": "10s"
        }
    ]
}
```

---

## Hedging

Send multiple copies of a request simultaneously. First response wins. Use for latency-sensitive reads.

```json
{
    "methodConfig": [{
        "name": [{"service": "acme.search.v1.SearchService", "method": "Search"}],
        "hedgingPolicy": {
            "maxAttempts": 3,
            "hedgingDelay": "0.5s",
            "nonFatalStatusCodes": ["UNAVAILABLE", "INTERNAL"]
        }
    }]
}
```

**Rules:**
- Hedging and retry are mutually exclusive per method.
- Only for idempotent operations (reads). Never for writes.
- `hedgingDelay`: wait before sending the next hedge. 0 = all at once.
- Server must handle duplicate requests gracefully.
- Each hedge consumes retry buffer quota.

---

## Service Mesh Integration

### Istio

gRPC works with Istio out of the box on named ports.

```yaml
# Kubernetes Service — port must be named grpc-*
apiVersion: v1
kind: Service
metadata:
  name: payment-service
spec:
  ports:
    - name: grpc-api  # Istio detects gRPC from "grpc-" prefix
      port: 50051
      targetPort: 50051

---
# DestinationRule — circuit breaker
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-service
spec:
  host: payment-service
  trafficPolicy:
    connectionPool:
      http:
        h2UpgradePolicy: UPGRADE
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s

---
# VirtualService — retries and timeout
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-service
spec:
  hosts: [payment-service]
  http:
    - route:
        - destination:
            host: payment-service
      timeout: 10s
      retries:
        attempts: 3
        perTryTimeout: 3s
        retryOn: "cancelled,deadline-exceeded,unavailable"
```

### Envoy

Direct Envoy config for gRPC cluster:

```yaml
clusters:
  - name: grpc_backend
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options: {}
    load_assignment:
      cluster_name: grpc_backend
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address: { address: backend, port_value: 50051 }
```

---

## gRPC-Web Proxying

### Envoy as gRPC-Web Proxy

```yaml
# envoy.yaml
static_resources:
  listeners:
    - name: listener_0
      address:
        socket_address: { address: 0.0.0.0, port_value: 8080 }
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: grpc_web
                codec_type: AUTO
                route_config:
                  name: local_route
                  virtual_hosts:
                    - name: backend
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route: { cluster: grpc_backend }
                      cors:
                        allow_origin_string_match:
                          - prefix: "*"
                        allow_methods: "GET, PUT, DELETE, POST, OPTIONS"
                        allow_headers: "x-grpc-web,content-type,x-user-agent"
                        expose_headers: "grpc-status,grpc-message"
                http_filters:
                  - name: envoy.filters.http.grpc_web
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.grpc_web.v3.GrpcWeb
                  - name: envoy.filters.http.cors
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.cors.v3.Cors
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

### Alternative: Connect Protocol

Connect eliminates the need for a proxy. Serves gRPC, gRPC-Web, and Connect on the same port. Prefer Connect for new services that need browser support.

```go
mux := http.NewServeMux()
path, handler := svcconnect.NewPaymentServiceHandler(&server{})
mux.Handle(path, handler)
// Serves gRPC, gRPC-Web, and Connect simultaneously
http.ListenAndServe(":8080", h2c.NewHandler(mux, &http2.Server{}))
```

---

## Reflection for Debugging

Server reflection exposes service metadata at runtime.

### Enable (Go)

```go
import "google.golang.org/grpc/reflection"
reflection.Register(s) // Before s.Serve()
```

### Enable (Python)

```python
from grpc_reflection.v1alpha import reflection
SERVICE_NAMES = (
    payments_pb2.DESCRIPTOR.services_by_name['PaymentService'].full_name,
    reflection.SERVICE_NAME,
)
reflection.enable_server_reflection(SERVICE_NAMES, server)
```

### Query with grpcurl

```bash
# List services
grpcurl -plaintext localhost:50051 list

# Describe a service
grpcurl -plaintext localhost:50051 describe acme.payments.v1.PaymentService

# Describe a message
grpcurl -plaintext localhost:50051 describe acme.payments.v1.Payment

# Call an RPC
grpcurl -plaintext -d '{"amount":{"currency_code":"USD","units":100}}' \
  localhost:50051 acme.payments.v1.PaymentService/CreatePayment
```

### grpcui — Browser UI

```bash
grpcui -plaintext localhost:50051
# Opens interactive web UI for testing RPCs
```

### Security

Disable reflection in production or gate behind auth. It exposes your entire API surface.

```go
if os.Getenv("ENV") != "production" {
    reflection.Register(s)
}
```

---

## Channelz

Runtime introspection of gRPC internals: channels, subchannels, sockets, servers.

### Enable (Go)

```go
import "google.golang.org/grpc/channelz/service"
service.RegisterChannelzServiceToServer(s)
```

### Query

```bash
# Via grpcurl
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetTopChannels
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetServers
```

### What Channelz Shows

- **Channels**: Target, state, calls started/succeeded/failed, last call time.
- **Subchannels**: Per-backend connection status.
- **Sockets**: Local/remote addresses, streams, messages, keepalive info.
- **Servers**: Listening addresses, calls stats.

Use channelz for debugging connection issues, load distribution, and performance bottlenecks.

---

## xDS Load Balancing

xDS (x Discovery Service) lets gRPC clients receive routing, load balancing, and policy configs from an Envoy control plane (like Istio's istiod).

### Bootstrap Config

```json
{
    "xds_servers": [{
        "server_uri": "xds-control-plane:18000",
        "channel_creds": [{"type": "insecure"}],
        "server_features": ["xds_v3"]
    }],
    "node": {
        "id": "payment-client-1",
        "cluster": "payment-clients"
    }
}
```

### Client Setup (Go)

```go
import _ "google.golang.org/grpc/xds" // Register xDS resolver and balancer

// Use xds:/// scheme
conn, _ := grpc.NewClient("xds:///payment-service",
    grpc.WithTransportCredentials(insecure.NewCredentials()),
)
```

### What xDS Provides

| Resource | Purpose |
|----------|---------|
| LDS (Listener) | Inbound connection config |
| RDS (Route) | URL path → cluster mapping |
| CDS (Cluster) | Backend cluster config, LB policy |
| EDS (Endpoint) | Actual backend IPs and weights |

### Benefits Over DNS

- Weighted routing (canary, A/B).
- Priority-based failover.
- Locality-aware load balancing.
- Dynamic config updates without client restart.
- mTLS via xDS certificate management.

---

## Custom Codecs

Replace protobuf with a custom serialization format.

```go
import "google.golang.org/grpc/encoding"

type jsonCodec struct{}

func (jsonCodec) Marshal(v any) ([]byte, error)   { return json.Marshal(v) }
func (jsonCodec) Unmarshal(data []byte, v any) error { return json.Unmarshal(data, v) }
func (jsonCodec) Name() string                     { return "json" }

func init() {
    encoding.RegisterCodec(jsonCodec{})
}

// Client usage
conn, _ := grpc.NewClient(target, grpc.WithDefaultCallOptions(
    grpc.ForceCodecV2(jsonCodec{}),
))
```

**Use cases:**
- JSON codec for debugging (inspect payloads in proxies).
- FlatBuffers for zero-copy deserialization.
- Custom binary format for specific performance needs.

**Caution:** Both client and server must agree on the codec. The `content-type` header signals the codec: `application/grpc+json`.

---

## Compression

### Per-Call Compression (Go)

```go
import "google.golang.org/grpc/encoding/gzip"

// Client: compress outgoing
resp, err := client.GetReport(ctx, req, grpc.UseCompressor(gzip.Name))

// Server: register compressor (automatic for registered codecs)
import _ "google.golang.org/grpc/encoding/gzip" // Side-effect: registers gzip
```

### Default Compression

```go
// All calls use gzip
conn, _ := grpc.NewClient(target,
    grpc.WithDefaultCallOptions(grpc.UseCompressor(gzip.Name)),
)
```

### Custom Compressor

```go
import "google.golang.org/grpc/encoding"

type zstdCompressor struct{}
func (z *zstdCompressor) Compress(w io.Writer) (io.WriteCloser, error) { /* ... */ }
func (z *zstdCompressor) Decompress(r io.Reader) (io.Reader, error)   { /* ... */ }
func (z *zstdCompressor) Name() string                                 { return "zstd" }

func init() { encoding.RegisterCompressor(&zstdCompressor{}) }
```

### When to Compress

- Large messages (>1KB benefit). Small messages may get larger.
- Text-heavy payloads (JSON fields, strings). Binary data compresses poorly.
- High bandwidth cost links.
- **Don't** compress already-compressed data or latency-critical tiny RPCs.

---

## Large Message Handling

Default max message size: 4MB receive, unlimited send (Go). Adjust per-server or per-call.

### Increase Limits

```go
// Server
grpc.NewServer(
    grpc.MaxRecvMsgSize(50 * 1024 * 1024), // 50MB
    grpc.MaxSendMsgSize(50 * 1024 * 1024),
)

// Client
grpc.NewClient(target,
    grpc.WithDefaultCallOptions(
        grpc.MaxCallRecvMsgSize(50 * 1024 * 1024),
        grpc.MaxCallSendMsgSize(50 * 1024 * 1024),
    ),
)
```

### Better: Use Streaming for Large Data

```protobuf
message UploadChunk {
    bytes data = 1;      // ~64KB–1MB per chunk
    int64 offset = 2;
    bool is_last = 3;
}

service FileService {
    rpc Upload(stream UploadChunk) returns (UploadResponse);
    rpc Download(DownloadRequest) returns (stream UploadChunk);
}
```

```go
func (s *server) Upload(stream pb.FileService_UploadServer) error {
    var buf bytes.Buffer
    for {
        chunk, err := stream.Recv()
        if err == io.EOF {
            return stream.SendAndClose(&pb.UploadResponse{Size: int64(buf.Len())})
        }
        if err != nil {
            return err
        }
        buf.Write(chunk.GetData())
    }
}
```

### Guidelines

| Message Size | Approach |
|-------------|----------|
| < 4MB | Default, no changes needed |
| 4MB–50MB | Increase limits with `MaxRecvMsgSize` |
| > 50MB | Use client/server streaming with chunks |
| > 1GB | Consider presigned URLs + out-of-band transfer |

---

## Protobuf Evolution Strategies

### Safe Changes (Wire Compatible)

- Add new fields with new numbers.
- Add new enum values (keep `UNSPECIFIED = 0`).
- Add new RPCs to services.
- Add new services to a package.
- Change `int32` ↔ `int64`, `uint32` ↔ `uint64` (with caution).
- Change `string` ↔ `bytes` (if UTF-8).

### Breaking Changes (Never Do)

- Change field numbers.
- Change field types incompatibly (`string` → `int32`).
- Remove or rename fields without `reserved`.
- Rename enum values (breaks JSON serialization).
- Change package name.
- Move fields in/out of `oneof`.

### Reserved Fields

```protobuf
message Payment {
    reserved 7, 9 to 11;                    // Reserve removed field numbers
    reserved "old_field", "legacy_status";   // Reserve removed names
}
```

### Versioning Strategy

```
proto/
  acme/
    payments/
      v1/
        payments.proto       # Stable, no breaking changes
      v2/
        payments.proto       # New major version, can break
```

- Keep v1 running alongside v2 during migration.
- Use `buf breaking --against '.git#branch=main'` to catch accidental breaks.
- Run `buf lint` in CI to enforce naming conventions.

### Field Presence and Defaults

```protobuf
// proto3: scalar fields have implicit presence (0/""/false = not set)
// Use wrappers for explicit presence:
import "google/protobuf/wrappers.proto";

message UpdateRequest {
    string id = 1;
    google.protobuf.StringValue name = 2;     // null = don't update
    google.protobuf.Int32Value priority = 3;  // null = don't update
}

// Or use field_mask for partial updates (preferred):
message UpdateRequest {
    string id = 1;
    Payment payment = 2;
    google.protobuf.FieldMask update_mask = 3;
}
```

### Optional Fields (proto3)

```protobuf
// proto3 optional — generates has_* method
message Filter {
    optional int32 min_amount = 1;  // Can distinguish 0 from not-set
    optional string category = 2;
}
```
