# Advanced gRPC Patterns

## Table of Contents

- [Bidirectional Streaming Patterns](#bidirectional-streaming-patterns)
  - [Chat Systems](#chat-systems)
  - [Real-Time Feeds](#real-time-feeds)
  - [Flow Control in Streams](#flow-control-in-streams)
- [Server Reflection for Dynamic Clients](#server-reflection-for-dynamic-clients)
- [gRPC-Gateway (REST + gRPC)](#grpc-gateway-rest--grpc)
- [Buf Schema Registry](#buf-schema-registry)
- [Proto Versioning Strategies](#proto-versioning-strategies)
- [Custom Resolvers](#custom-resolvers)
- [Service Mesh Integration](#service-mesh-integration)
  - [Envoy](#envoy)
  - [Istio](#istio)
- [Connection Management and Keepalives](#connection-management-and-keepalives)
- [Retry Policies](#retry-policies)
- [Hedging](#hedging)
- [Performance Optimization](#performance-optimization)
  - [Message Size Limits](#message-size-limits)
  - [Compression](#compression)
  - [Flow Control](#flow-control)

---

## Bidirectional Streaming Patterns

### Chat Systems

Bidirectional streaming is ideal for chat: both client and server send messages independently on the same connection.

```protobuf
service ChatService {
  rpc Chat(stream ChatMessage) returns (stream ChatMessage);
}

message ChatMessage {
  string user_id = 1;
  string room_id = 2;
  string content = 3;
  google.protobuf.Timestamp sent_at = 4;
}
```

**Go server pattern — fan-out to connected clients:**

```go
type chatServer struct {
    pb.UnimplementedChatServiceServer
    mu    sync.RWMutex
    rooms map[string]map[string]chan *pb.ChatMessage // room -> user -> channel
}

func (s *chatServer) Chat(stream pb.ChatService_ChatServer) error {
    // First message identifies the user and room
    initial, err := stream.Recv()
    if err != nil {
        return err
    }
    roomID, userID := initial.RoomId, initial.UserId

    ch := make(chan *pb.ChatMessage, 64)
    s.mu.Lock()
    if s.rooms[roomID] == nil {
        s.rooms[roomID] = make(map[string]chan *pb.ChatMessage)
    }
    s.rooms[roomID][userID] = ch
    s.mu.Unlock()

    defer func() {
        s.mu.Lock()
        delete(s.rooms[roomID], userID)
        s.mu.Unlock()
        close(ch)
    }()

    // Send goroutine: forward messages from channel to stream
    errCh := make(chan error, 1)
    go func() {
        for msg := range ch {
            if err := stream.Send(msg); err != nil {
                errCh <- err
                return
            }
        }
    }()

    // Receive loop: broadcast incoming messages to all users in room
    for {
        select {
        case err := <-errCh:
            return err
        default:
        }
        msg, err := stream.Recv()
        if err == io.EOF {
            return nil
        }
        if err != nil {
            return err
        }
        s.broadcast(roomID, userID, msg)
    }
}

func (s *chatServer) broadcast(roomID, senderID string, msg *pb.ChatMessage) {
    s.mu.RLock()
    defer s.mu.RUnlock()
    for uid, ch := range s.rooms[roomID] {
        if uid != senderID {
            select {
            case ch <- msg:
            default:
                // Drop message if client is slow — consider logging
            }
        }
    }
}
```

**Key design decisions:**
- Buffer channels to absorb short bursts (64 is a starting point; tune per use case)
- Drop messages for slow consumers rather than blocking all clients
- Use `sync.RWMutex` — reads (broadcasts) far outnumber writes (join/leave)
- First message bootstraps identity; alternatively, use metadata

### Real-Time Feeds

Server-to-client streaming for real-time price feeds, event logs, or notifications:

```protobuf
service MarketDataService {
  // Server streaming for price updates
  rpc SubscribePrices(PriceSubscription) returns (stream PriceUpdate);
  // Bidirectional: client can update subscriptions on the fly
  rpc StreamPrices(stream PriceSubscription) returns (stream PriceUpdate);
}

message PriceSubscription {
  repeated string symbols = 1;
  enum Action {
    ACTION_UNSPECIFIED = 0;
    ACTION_SUBSCRIBE = 1;
    ACTION_UNSUBSCRIBE = 2;
  }
  Action action = 2;
}

message PriceUpdate {
  string symbol = 1;
  double price = 2;
  int64 volume = 3;
  google.protobuf.Timestamp timestamp = 4;
}
```

**Bidirectional feed pattern (dynamic subscriptions):**

```go
func (s *marketServer) StreamPrices(stream pb.MarketDataService_StreamPricesServer) error {
    subs := make(map[string]bool)
    updates := make(chan *pb.PriceUpdate, 256)

    // Receive loop: manage subscriptions
    go func() {
        for {
            req, err := stream.Recv()
            if err != nil {
                close(updates)
                return
            }
            for _, sym := range req.Symbols {
                switch req.Action {
                case pb.PriceSubscription_ACTION_SUBSCRIBE:
                    subs[sym] = true
                case pb.PriceSubscription_ACTION_UNSUBSCRIBE:
                    delete(subs, sym)
                }
            }
        }
    }()

    // Send loop: push matching updates
    ticker := time.NewTicker(100 * time.Millisecond)
    defer ticker.Stop()
    for {
        select {
        case <-stream.Context().Done():
            return stream.Context().Err()
        case <-ticker.C:
            for sym := range subs {
                update := s.getLatestPrice(sym)
                if err := stream.Send(update); err != nil {
                    return err
                }
            }
        }
    }
}
```

### Flow Control in Streams

gRPC uses HTTP/2 flow control. When a receiver is slow, the sender blocks on `Send()`. Handle this:

```go
// Set window size for high-throughput streams
srv := grpc.NewServer(
    grpc.InitialWindowSize(1 << 20),     // 1 MB per-stream
    grpc.InitialConnWindowSize(1 << 22), // 4 MB per-connection
)
```

**Backpressure pattern:**
- Monitor `Send()` latency; if consistently high, the consumer is slow
- Implement server-side buffering with overflow policy (drop oldest, drop newest, or signal the client)
- Use stream context cancellation to detect dead clients

---

## Server Reflection for Dynamic Clients

Server reflection exposes service and message descriptors at runtime. Essential for:
- CLI tools (grpcurl, Evans)
- Dynamic API gateways
- Service cataloging and documentation

```go
import "google.golang.org/grpc/reflection"

srv := grpc.NewServer()
pb.RegisterMyServiceServer(srv, &myServer{})
reflection.Register(srv)
```

**Building a dynamic client using reflection:**

```go
import (
    "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
    "google.golang.org/protobuf/proto"
    "google.golang.org/protobuf/types/dynamicpb"
)

// Connect and list services
refClient := grpc_reflection_v1alpha.NewServerReflectionClient(conn)
stream, _ := refClient.ServerReflectionInfo(ctx)

// Request service list
stream.Send(&grpc_reflection_v1alpha.ServerReflectionRequest{
    MessageRequest: &grpc_reflection_v1alpha.ServerReflectionRequest_ListServices{},
})
resp, _ := stream.Recv()

// Resolve a method descriptor, build a dynamic message, invoke the RPC
```

**Security note:** Disable reflection in production if service schemas are sensitive. Use per-environment feature flags:

```go
if os.Getenv("ENABLE_REFLECTION") == "true" {
    reflection.Register(srv)
}
```

---

## gRPC-Gateway (REST + gRPC)

gRPC-Gateway generates a REST reverse proxy from proto annotations, letting you serve both REST and gRPC from one service definition.

**Step 1: Annotate protos**

```protobuf
import "google/api/annotations.proto";

service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse) {
    option (google.api.http) = {
      post: "/v1/orders"
      body: "*"
    };
  }
  rpc GetOrder(GetOrderRequest) returns (Order) {
    option (google.api.http) = {
      get: "/v1/orders/{order_id}"
    };
  }
  rpc ListOrders(ListOrdersRequest) returns (ListOrdersResponse) {
    option (google.api.http) = {
      get: "/v1/orders"
    };
  }
}
```

**Step 2: Generate gateway stubs**

```yaml
# buf.gen.yaml
version: v2
plugins:
  - remote: buf.build/grpc-ecosystem/gateway
    out: gen/go
    opt:
      - paths=source_relative
      - generate_unbound_methods=true
```

**Step 3: Wire up the gateway**

```go
import "github.com/grpc-ecosystem/grpc-gateway/v2/runtime"

func runGateway() {
    ctx := context.Background()
    mux := runtime.NewServeMux(
        runtime.WithMarshalerOption(runtime.MIMEWildcard, &runtime.JSONPb{
            MarshalOptions: protojson.MarshalOptions{EmitUnpopulated: true},
        }),
    )
    opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
    pb.RegisterOrderServiceHandlerFromEndpoint(ctx, mux, "localhost:50051", opts)
    http.ListenAndServe(":8080", mux)
}
```

**Custom error handling:**

```go
runtime.WithErrorHandler(func(ctx context.Context, mux *runtime.ServeMux,
    m runtime.Marshaler, w http.ResponseWriter, r *http.Request, err error) {
    st := status.Convert(err)
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(runtime.HTTPStatusFromCode(st.Code()))
    json.NewEncoder(w).Encode(map[string]string{
        "code":    st.Code().String(),
        "message": st.Message(),
    })
})
```

---

## Buf Schema Registry

The Buf Schema Registry (BSR) hosts proto modules, manages dependencies, and provides generated code as packages.

**Publishing to BSR:**

```bash
# Login
buf registry login

# Push module
buf push

# Tag a release
buf push --tag v1.2.0
```

**Consuming from BSR:**

```yaml
# buf.yaml
version: v2
modules:
  - path: proto
    name: buf.build/myorg/myservice
deps:
  - buf.build/googleapis/googleapis
  - buf.build/grpc-ecosystem/grpc-gateway
```

**Generated SDKs:** BSR auto-generates client libraries for Go, TypeScript, Java, Python. Import directly:

```go
import ordersv1 "buf.build/gen/go/myorg/myservice/protocolbuffers/go/orders/v1"
```

---

## Proto Versioning Strategies

### Package-Level Versioning

```protobuf
// v1 — original
package myservice.v1;

// v2 — breaking changes
package myservice.v2;
```

**Rules for non-breaking changes (within a version):**
- Add new fields (with new field numbers)
- Add new RPC methods
- Add new enum values (not at position 0)
- Add new messages

**Changes that require a new version:**
- Removing or renaming fields/RPCs
- Changing field types or numbers
- Changing enum value assignments
- Reordering oneof fields

### Migration Strategy

Run both versions simultaneously:

```go
srv := grpc.NewServer()
v1pb.RegisterOrderServiceServer(srv, &orderServerV1{})
v2pb.RegisterOrderServiceServer(srv, &orderServerV2{})
```

Use interceptors to route or translate between versions during migration periods.

### Reserved Fields

```protobuf
message Order {
  reserved 6, 9 to 11;
  reserved "legacy_status", "old_field";
  // Prevents accidental reuse of removed fields
}
```

---

## Custom Resolvers

Override default DNS resolution for custom service discovery:

```go
import "google.golang.org/grpc/resolver"

type consulResolver struct {
    cc     resolver.ClientConn
    consul *api.Client
}

func (r *consulResolver) ResolveNow(resolver.ResolveNowOptions) {
    entries, _, _ := r.consul.Health().Service("order-service", "", true, nil)
    addrs := make([]resolver.Address, len(entries))
    for i, e := range entries {
        addrs[i] = resolver.Address{Addr: fmt.Sprintf("%s:%d", e.Service.Address, e.Service.Port)}
    }
    r.cc.UpdateState(resolver.State{Addresses: addrs})
}

// Register the scheme
type consulResolverBuilder struct{}

func (b *consulResolverBuilder) Build(target resolver.Target, cc resolver.ClientConn,
    opts resolver.BuildOptions) (resolver.Resolver, error) {
    r := &consulResolver{cc: cc, consul: newConsulClient()}
    r.ResolveNow(resolver.ResolveNowOptions{})
    go r.watch() // Watch for changes
    return r, nil
}

func (b *consulResolverBuilder) Scheme() string { return "consul" }

func init() {
    resolver.Register(&consulResolverBuilder{})
}

// Usage
conn, _ := grpc.NewClient("consul:///order-service", ...)
```

---

## Service Mesh Integration

### Envoy

Envoy is the preferred gRPC proxy — it natively understands HTTP/2 and gRPC.

**Envoy config for gRPC upstream:**

```yaml
static_resources:
  listeners:
    - name: grpc_listener
      address:
        socket_address: { address: 0.0.0.0, port_value: 8443 }
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: grpc
                codec_type: AUTO
                route_config:
                  name: local_route
                  virtual_hosts:
                    - name: grpc_service
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/orders.v1.OrderService" }
                          route:
                            cluster: order_service
                            timeout: 30s
                            retry_policy:
                              retry_on: "unavailable,resource-exhausted"
                              num_retries: 3
                http_filters:
                  - name: envoy.filters.http.grpc_web
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.grpc_web.v3.GrpcWeb
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
    - name: order_service
      type: STRICT_DNS
      lb_policy: ROUND_ROBIN
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http2_protocol_options: {}
      load_assignment:
        cluster_name: order_service
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: order-svc, port_value: 50051 }
      health_checks:
        - timeout: 5s
          interval: 10s
          grpc_health_check: {}
```

### Istio

With Istio, gRPC services get mTLS, traffic management, and observability automatically.

**DestinationRule for gRPC:**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: order-service
spec:
  host: order-service.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        h2UpgradePolicy: UPGRADE
    loadBalancer:
      simple: ROUND_ROBIN
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 30s
      baseEjectionTime: 60s
```

**VirtualService for canary routing:**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: order-service
spec:
  hosts:
    - order-service
  http:
    - match:
        - headers:
            x-canary:
              exact: "true"
      route:
        - destination:
            host: order-service
            subset: v2
    - route:
        - destination:
            host: order-service
            subset: v1
          weight: 90
        - destination:
            host: order-service
            subset: v2
          weight: 10
```

---

## Connection Management and Keepalives

### Server-Side Keepalive

```go
srv := grpc.NewServer(
    grpc.KeepaliveParams(keepalive.ServerParameters{
        MaxConnectionIdle:     15 * time.Minute, // Close idle connections
        MaxConnectionAge:      30 * time.Minute, // Force reconnect for load balancing
        MaxConnectionAgeGrace: 5 * time.Second,  // Grace period for in-flight RPCs
        Time:                  5 * time.Minute,   // Ping client if idle
        Timeout:               1 * time.Second,   // Wait for ping ack
    }),
    grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
        MinTime:             5 * time.Second, // Minimum time between client pings
        PermitWithoutStream: true,            // Allow pings with no active streams
    }),
)
```

### Client-Side Keepalive

```go
conn, _ := grpc.NewClient(addr,
    grpc.WithKeepaliveParams(keepalive.ClientParameters{
        Time:                10 * time.Second, // Ping server if idle
        Timeout:             3 * time.Second,  // Wait for ping ack
        PermitWithoutStream: true,             // Ping even with no active RPCs
    }),
)
```

**Key considerations:**
- `MaxConnectionAge` is critical for client-side load balancing — without it, clients hold long-lived connections and never discover new backends
- Cloud load balancers often have idle timeouts (e.g., GCP default 10 minutes); set keepalive `Time` below that
- Too-frequent pings can cause `ENHANCE_YOUR_CALM` (GOAWAY with too_many_pings) — respect `MinTime`

---

## Retry Policies

Configure retries via service config (no code changes needed):

```go
serviceConfig := `{
    "methodConfig": [{
        "name": [{"service": "orders.v1.OrderService"}],
        "retryPolicy": {
            "maxAttempts": 4,
            "initialBackoff": "0.1s",
            "maxBackoff": "1s",
            "backoffMultiplier": 2,
            "retryableStatusCodes": ["UNAVAILABLE", "RESOURCE_EXHAUSTED"]
        }
    }]
}`

conn, _ := grpc.NewClient(addr,
    grpc.WithDefaultServiceConfig(serviceConfig),
)
```

**Per-method configuration:**

```go
serviceConfig := `{
    "methodConfig": [
        {
            "name": [{"service": "orders.v1.OrderService", "method": "CreateOrder"}],
            "timeout": "5s",
            "retryPolicy": {
                "maxAttempts": 2,
                "initialBackoff": "0.5s",
                "maxBackoff": "2s",
                "backoffMultiplier": 2,
                "retryableStatusCodes": ["UNAVAILABLE"]
            }
        },
        {
            "name": [{"service": "orders.v1.OrderService", "method": "GetOrder"}],
            "timeout": "3s",
            "retryPolicy": {
                "maxAttempts": 4,
                "initialBackoff": "0.1s",
                "maxBackoff": "1s",
                "backoffMultiplier": 2,
                "retryableStatusCodes": ["UNAVAILABLE", "RESOURCE_EXHAUSTED"]
            }
        }
    ]
}`
```

**Rules:**
- Only retry on idempotent operations or specific status codes
- `UNAVAILABLE` is always safe to retry (transient transport error)
- Never retry `INVALID_ARGUMENT`, `NOT_FOUND`, `ALREADY_EXISTS` — these won't change
- `maxAttempts` includes the original call (so 4 = 1 original + 3 retries)
- Retries are transparent to the application — no code changes needed

---

## Hedging

Hedging sends multiple copies of an RPC in parallel and uses the first successful response. Useful for latency-sensitive reads:

```go
serviceConfig := `{
    "methodConfig": [{
        "name": [{"service": "orders.v1.OrderService", "method": "GetOrder"}],
        "hedgingPolicy": {
            "maxAttempts": 3,
            "hedgingDelay": "0.5s",
            "nonFatalStatusCodes": ["UNAVAILABLE", "RESOURCE_EXHAUSTED"]
        }
    }]
}`
```

**How it works:**
1. First attempt sent immediately
2. After `hedgingDelay`, if no response, send second attempt
3. After another `hedgingDelay`, if no response, send third attempt
4. First successful response wins; others are cancelled

**Caveats:**
- Only use for read-only / idempotent operations
- Cannot combine hedging and retry on the same method
- Increases server load proportionally to `maxAttempts`
- Monitor hedging rate — high rates indicate underlying latency problems

---

## Performance Optimization

### Message Size Limits

Default max message size is 4 MB. Increase for large payloads:

```go
// Server
srv := grpc.NewServer(
    grpc.MaxRecvMsgSize(16 * 1024 * 1024), // 16 MB
    grpc.MaxSendMsgSize(16 * 1024 * 1024),
)

// Client
conn, _ := grpc.NewClient(addr,
    grpc.WithDefaultCallOptions(
        grpc.MaxCallRecvMsgSize(16*1024*1024),
        grpc.MaxCallSendMsgSize(16*1024*1024),
    ),
)
```

**Better approach: use streaming for large data** instead of increasing message size. Stream chunks of 32–64 KB:

```protobuf
service FileService {
  rpc Upload(stream FileChunk) returns (UploadResponse);
  rpc Download(DownloadRequest) returns (stream FileChunk);
}

message FileChunk {
  bytes data = 1;
  int64 offset = 2;
}
```

### Compression

Enable per-RPC or globally:

```go
// Client: per-RPC
resp, err := client.GetOrder(ctx, req, grpc.UseCompressor(gzip.Name))

// Server: register compressor (auto-decompresses incoming)
import _ "google.golang.org/grpc/encoding/gzip"

// Client: global default
conn, _ := grpc.NewClient(addr,
    grpc.WithDefaultCallOptions(grpc.UseCompressor(gzip.Name)),
)
```

**When to compress:**
- Large text-heavy responses (JSON-like proto fields, logs)
- Bulk data transfers
- When bandwidth is expensive (cross-region, mobile)

**When NOT to compress:**
- Small messages (<1 KB) — overhead exceeds benefit
- Already-compressed data (images, encrypted payloads)
- Ultra-low-latency paths — CPU cost matters

### Flow Control

HTTP/2 flow control prevents fast senders from overwhelming slow receivers:

```go
srv := grpc.NewServer(
    // Per-stream window: how much data a single stream can buffer
    grpc.InitialWindowSize(1 << 20), // 1 MB (default 64 KB)
    // Per-connection window: aggregate across all streams
    grpc.InitialConnWindowSize(1 << 22), // 4 MB (default 16 * 64 KB)
)
```

**Tuning guidelines:**
- High-throughput streams (file transfer, data pipeline): increase to 1–4 MB
- Many concurrent streams with small messages: keep defaults
- Monitor `grpc_server_msg_sent_total` and `grpc_server_msg_received_total` for bottlenecks
- Use channelz (`grpc.EnableChannelz()`) for detailed per-channel and per-stream diagnostics
