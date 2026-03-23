---
name: grpc-protobuf
description: >
  Use when user implements gRPC services, designs Protobuf schemas (.proto files),
  asks about gRPC streaming, interceptors/middleware, error codes, gRPC-Web,
  service reflection, or Buf/protoc tooling.
  Do NOT use for REST API design, GraphQL, JSON serialization, or Apache Thrift.
---

# gRPC & Protocol Buffers

## Protobuf Schema Design

### Message Structure

Use proto3 syntax. Keep messages focused—one responsibility per message.

```protobuf
syntax = "proto3";
package myapp.user.v1;
import "google/protobuf/timestamp.proto";

message User {
  string user_id = 1;
  string email = 2;
  UserStatus status = 3;
  google.protobuf.Timestamp created_at = 4;
  map<string, string> metadata = 5;       // key-value pairs
  optional string nickname = 6;           // distinguishes unset from empty
  repeated Address addresses = 7;
  oneof contact {                         // mutually exclusive
    string phone = 8;
    string slack_handle = 9;
  }
}

enum UserStatus {
  USER_STATUS_UNSPECIFIED = 0;            // zero value = unspecified
  USER_STATUS_ACTIVE = 1;
  USER_STATUS_SUSPENDED = 2;
}

message Address {
  string line1 = 1;
  string city = 2;
  string country_code = 3;
}
```

### Well-Known Types

| Type | Use |
|------|-----|
| `Timestamp` | Absolute time |
| `Duration` | Time spans |
| `FieldMask` | Partial updates (PATCH) |
| `Struct` | Arbitrary JSON (avoid—lose type safety) |
| `StringValue`/wrappers | Nullable primitives |
| `Any` | Polymorphic payloads (use sparingly) |

All live under `google.protobuf.*`. Import only what you use.

### Key Rules

- Use `optional` to distinguish "not set" from "default value" for PATCH semantics.
- Use `oneof` for mutually exclusive fields. Never add `repeated` inside `oneof`.
- Use `map<K, V>` for key-value pairs. Keys must be integral or string types.
- Assign field numbers 1–15 to frequently used fields (1-byte tag encoding).
- Never use field numbers 19000–19999 (reserved by protobuf).

## Proto Style Guide

### Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| File | `lower_snake_case.proto` | `user_service.proto` |
| Package | `lower.dot.separated.v1` | `myapp.user.v1` |
| Message | `PascalCase` | `UserProfile` |
| Field | `lower_snake_case` | `user_id` |
| Enum type | `PascalCase` | `UserStatus` |
| Enum value | `UPPER_SNAKE_CASE` with type prefix | `USER_STATUS_ACTIVE` |
| Service | `PascalCase` | `UserService` |
| RPC method | `PascalCase` | `GetUser` |

### Versioning & Backward Compatibility

- End package names with a version: `myapp.user.v1`.
- Never reuse or change field numbers. Reserve removed fields:

```protobuf
message Product {
  string id = 1;
  reserved 2, 3;
  reserved "old_price", "legacy_code";
  string name = 4;
  string description = 5;
}
```

- Add new fields with new numbers—never fill gaps.
- Never change a field's type or switch between `optional`/`repeated`.
- Start enums at zero with `_UNSPECIFIED` value. Add new values freely; never remove or renumber.
- Use `reserved` for both field numbers and names to prevent accidental reuse.
- Bump package version (`v1` → `v2`) only for wire-incompatible changes.

## gRPC Service Types

```protobuf
service OrderService {
  // Unary: single request, single response
  rpc GetOrder(GetOrderRequest) returns (GetOrderResponse);

  // Server streaming: single request, stream of responses
  rpc WatchOrderStatus(WatchOrderStatusRequest) returns (stream OrderStatusUpdate);

  // Client streaming: stream of requests, single response
  rpc UploadLineItems(stream LineItem) returns (UploadSummary);

  // Bidirectional streaming: both sides stream
  rpc LiveChat(stream ChatMessage) returns (stream ChatMessage);
}
```

### When to Use Each

| Pattern | Use Case |
|---------|----------|
| Unary | CRUD operations, simple queries |
| Server streaming | Real-time feeds, log tailing, notifications |
| Client streaming | Bulk uploads, telemetry ingestion |
| Bidirectional | Chat, collaborative editing, live sync |

### Streaming Best Practices

- Always handle context cancellation and deadlines in streaming RPCs.
- Send keepalive/heartbeat messages to detect dead connections.
- Design stream messages to be independent and replayable.
- Close streams explicitly; handle `io.EOF` on the receiver side.
- Limit message size (default 4 MB). For large payloads, chunk data across stream messages.

## Error Handling

### Status Codes

Use the most specific code. Map HTTP-like semantics:

| Code | Name | When to Use |
|------|------|-------------|
| 0 | `OK` | Success |
| 3 | `INVALID_ARGUMENT` | Validation failure |
| 5 | `NOT_FOUND` | Resource missing |
| 6 | `ALREADY_EXISTS` | Duplicate creation |
| 7 | `PERMISSION_DENIED` | Authz failure (authenticated but unauthorized) |
| 8 | `RESOURCE_EXHAUSTED` | Rate limit, quota exceeded |
| 9 | `FAILED_PRECONDITION` | System state prevents operation |
| 10 | `ABORTED` | Concurrency conflict |
| 11 | `OUT_OF_RANGE` | Value outside valid bounds |
| 12 | `UNIMPLEMENTED` | RPC not implemented |
| 13 | `INTERNAL` | Server bug |
| 14 | `UNAVAILABLE` | Transient failure—client should retry |
| 16 | `UNAUTHENTICATED` | Missing or invalid credentials |

### Rich Error Model

Attach structured details using `google.rpc` types (`BadRequest`, `RetryInfo`, `ErrorInfo`, `DebugInfo`, `QuotaFailure`, `PreconditionFailure`, `ResourceInfo`):

```go
st := status.New(codes.InvalidArgument, "validation failed")
br := &errdetails.BadRequest{FieldViolations: []*errdetails.BadRequest_FieldViolation{
    {Field: "email", Description: "email is required"},
}}
st, _ = st.WithDetails(br)
return st.Err()
```

## Interceptors / Middleware

### Unary Interceptor (Go)

```go
func loggingInterceptor(ctx context.Context, req interface{},
    info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
    start := time.Now()
    resp, err := handler(ctx, req)
    log.Printf("method=%s duration=%s err=%v", info.FullMethod, time.Since(start), err)
    return resp, err
}

server := grpc.NewServer(
    grpc.ChainUnaryInterceptor(loggingInterceptor, authInterceptor, recoveryInterceptor),
    grpc.ChainStreamInterceptor(streamLoggingInterceptor),
)
```

### Common Interceptor Patterns

| Interceptor | Purpose |
|-------------|---------|
| Auth | Validate tokens from metadata, reject `UNAUTHENTICATED` |
| Logging | Log method, duration, status code |
| Recovery | Catch panics, return `INTERNAL` |
| Retry | Client-side retry with backoff for `UNAVAILABLE` |
| Tracing | Inject/extract OpenTelemetry span context |
| Validation | Validate request messages before handler |
| Rate limiting | Return `RESOURCE_EXHAUSTED` on overload |

### Client Interceptor

```go
conn, _ := grpc.Dial(target,
    grpc.WithChainUnaryInterceptor(retryInterceptor, tracingInterceptor))
```

## Deadlines and Timeouts

Always set deadlines. RPCs without deadlines can leak resources.

```go
// Client: always set a deadline
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
resp, err := client.GetUser(ctx, req)
```

- Deadlines propagate automatically across chained gRPC calls.
- Set shorter deadlines for downstream calls than the incoming deadline.
- Handle `context.Canceled` and `context.DeadlineExceeded` gracefully.
- Use `grpc.WaitForReady(true)` to queue RPCs until connection is ready.

## Authentication

### TLS / mTLS

```go
// Server with TLS
creds, _ := credentials.NewServerTLSFromFile("cert.pem", "key.pem")
server := grpc.NewServer(grpc.Creds(creds))

// Client with TLS
creds, _ := credentials.NewClientTLSFromFile("ca-cert.pem", "")
conn, _ := grpc.Dial(addr, grpc.WithTransportCredentials(creds))
```

For mTLS (service-to-service), load both client and server certs. In Kubernetes, delegate to a service mesh (Istio/Linkerd).

### Per-RPC Token Auth

```go
type tokenAuth struct{ token string }
func (t tokenAuth) GetRequestMetadata(ctx context.Context, uri ...string) (map[string]string, error) {
    return map[string]string{"authorization": "Bearer " + t.token}, nil
}
func (t tokenAuth) RequireTransportSecurity() bool { return true }

conn, _ := grpc.Dial(addr,
    grpc.WithTransportCredentials(creds),
    grpc.WithPerRPCCredentials(tokenAuth{token: "my-jwt"}),
)
```

## gRPC-Web for Browser Clients

Browsers cannot speak native gRPC (no HTTP/2 trailer support). Use gRPC-Web with a translation proxy.

### Proxy Options

| Proxy | Notes |
|-------|-------|
| Envoy | Production standard. Use `envoy.filters.http.grpc_web` filter |
| ConnectRPC | Modern alternative—supports gRPC, gRPC-Web, and Connect protocol |
| grpcwebproxy | Lightweight Go proxy for dev/simple setups |

### Envoy Config (minimal)

```yaml
http_filters:
  - name: envoy.filters.http.grpc_web
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.grpc_web.v3.GrpcWeb
  - name: envoy.filters.http.cors
  - name: envoy.filters.http.router
```

### Client (TypeScript with ConnectRPC)

```typescript
import { createClient } from "@connectrpc/connect";
import { createGrpcWebTransport } from "@connectrpc/connect-web";
import { UserService } from "./gen/user_connect";

const transport = createGrpcWebTransport({
  baseUrl: "https://api.example.com",
});
const client = createClient(UserService, transport);
const user = await client.getUser({ userId: "123" });
```

### Constraints

- Server streaming works. Client streaming and bidirectional streaming are not supported in gRPC-Web.
- Always configure CORS in the proxy for browser origins.
- Pass auth tokens via `Authorization` header metadata.

## Reflection and Health Checking

Enable reflection for `grpcurl`/`grpcui`. Implement `grpc.health.v1.Health` for health checks.

```go
import "google.golang.org/grpc/reflection"
import "google.golang.org/grpc/health"
import healthpb "google.golang.org/grpc/health/grpc_health_v1"

server := grpc.NewServer()
pb.RegisterUserServiceServer(server, &userServer{})
reflection.Register(server)

healthServer := health.NewServer()
healthpb.RegisterHealthServer(server, healthServer)
healthServer.SetServingStatus("myapp.user.v1.UserService", healthpb.HealthCheckResponse_SERVING)
```

```bash
grpcurl -plaintext localhost:50051 list                    # List services
grpcurl -plaintext -d '{"user_id":"123"}' localhost:50051 myapp.user.v1.UserService/GetUser
```

Use health checks for Kubernetes liveness/readiness probes and load balancer backends.

## Buf CLI

Prefer Buf over raw `protoc` for linting, formatting, breaking change detection, and code generation.

### Setup

```yaml
# buf.yaml
version: v2
modules:
  - path: proto
lint:
  use:
    - STANDARD
breaking:
  use:
    - FILE
```

```yaml
# buf.gen.yaml
version: v2
plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative
```

### Commands

```bash
buf lint                          # Lint proto files
buf format -w                     # Auto-format
buf breaking --against .git#branch=main  # Detect breaking changes
buf generate                      # Generate code
buf build                         # Validate compilation
buf push                          # Push to BSR
```

### Breaking Change Policies

| Policy | Checks |
|--------|--------|
| `FILE` | Strictest—field/type/file-level compatibility |
| `PACKAGE` | Package-level compatibility |
| `WIRE` | Wire format compatibility only |
| `WIRE_JSON` | Wire + JSON compatibility |

Integrate `buf breaking` in CI to block merges that break API contracts.

## Load Balancing

### Why Standard L4 LB Fails

gRPC multiplexes RPCs over a single HTTP/2 connection. A TCP-level load balancer sends all RPCs from one connection to one backend.

### Client-Side Load Balancing

```go
conn, _ := grpc.Dial(
    "dns:///my-service.default.svc.cluster.local:50051",
    grpc.WithDefaultServiceConfig(`{"loadBalancingConfig": [{"round_robin":{}}]}`),
)
```

In Kubernetes, use headless services (`clusterIP: None`) so DNS returns all pod IPs.

### Proxy-Based (L7)

Use Envoy, Linkerd, or Istio for L7 load balancing with per-request routing, retries, and circuit breaking.

### xDS

For advanced control, use xDS-aware gRPC clients:

```go
conn, _ := grpc.Dial("xds:///my-service", opts...)
```

The xDS control plane manages endpoints, LB policy, locality-aware routing, and health checks dynamically.

| Approach | When to Use |
|----------|-------------|
| Client-side (`round_robin`) | Simple internal services, Kubernetes headless svc |
| L7 proxy (Envoy) | Heterogeneous clients, need observability/security |
| xDS | Large-scale, dynamic topology, multi-region |

## Testing gRPC Services

### In-Process Testing (Go)

```go
func TestGetUser(t *testing.T) {
    lis := bufconn.Listen(1024 * 1024)
    server := grpc.NewServer()
    pb.RegisterUserServiceServer(server, &userServer{})
    go server.Serve(lis)
    defer server.Stop()

    dialer := func(ctx context.Context, s string) (net.Conn, error) { return lis.Dial() }
    conn, _ := grpc.DialContext(ctx, "bufnet",
        grpc.WithContextDialer(dialer),
        grpc.WithTransportCredentials(insecure.NewCredentials()))
    defer conn.Close()

    client := pb.NewUserServiceClient(conn)
    resp, err := client.GetUser(ctx, &pb.GetUserRequest{UserId: "123"})
    require.NoError(t, err)
    assert.Equal(t, "123", resp.User.UserId)
}
```

- Use `bufconn` for integration tests without real network.
- Mock generated client interfaces for unit tests.
- Verify error codes: `assert.Equal(t, codes.NotFound, status.Code(err))`.
- Use `grpcurl` for manual/smoke testing against running services.

## Common Patterns

### Pagination

```protobuf
message ListUsersRequest {
  int32 page_size = 1;    // max items per page
  string page_token = 2;  // opaque cursor from previous response
}

message ListUsersResponse {
  repeated User users = 1;
  string next_page_token = 2; // empty when no more pages
}
```

Encode cursor as an opaque token (base64-encoded key). Never expose internal offsets.

### Long-Running Operations

Use `google.longrunning.Operation` for async work. Return an `Operation` with a name; client polls `GetOperation` or calls `WaitOperation`.

### Field Masks for Partial Updates

```protobuf
message UpdateUserRequest {
  User user = 1;
  google.protobuf.FieldMask update_mask = 2;
}
```

Server applies only the paths listed in `update_mask`. Iterate `UpdateMask.Paths` and update matching fields on the existing resource.

### Request/Response Naming

Follow `{MethodName}Request` / `{MethodName}Response`. Return resource directly for mutations, `google.protobuf.Empty` for deletes.

### Idempotency

Include a client-generated `request_id` for non-idempotent operations:

```protobuf
message CreateOrderRequest {
  string request_id = 1; // UUID for deduplication
  Order order = 2;
}
```

Server deduplicates by `request_id` and returns the cached response for retries.

<!-- tested: pass -->
