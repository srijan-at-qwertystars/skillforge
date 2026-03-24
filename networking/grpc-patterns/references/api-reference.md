# gRPC API Quick Reference

## gRPC Status Codes

All 17 canonical status codes with guidance on when to use each:

| Code | Value | When to Use |
|------|-------|-------------|
| `OK` | 0 | RPC completed successfully. Never set explicitly — return `nil` error instead. |
| `CANCELLED` | 1 | Client cancelled the RPC (e.g., user navigated away). Do not use for server-initiated cancellation — use `ABORTED` instead. |
| `UNKNOWN` | 2 | Error from another domain that doesn't map to a gRPC code, or when the error type is unknown. Avoid if a more specific code applies. |
| `INVALID_ARGUMENT` | 3 | Client sent invalid data (bad field values, malformed request). Not for "not found" — use `NOT_FOUND`. Not retriable. |
| `DEADLINE_EXCEEDED` | 4 | Operation did not complete before the deadline. Can originate at client or server. May be retriable with a longer deadline. |
| `NOT_FOUND` | 5 | Requested entity does not exist. Use for GET-like lookups. For "create if not exists" patterns, use `ALREADY_EXISTS` on conflict. |
| `ALREADY_EXISTS` | 6 | Entity the client tried to create already exists. Use for idempotent create operations. |
| `PERMISSION_DENIED` | 7 | Caller is authenticated but lacks permission. Use `UNAUTHENTICATED` if identity is unknown. Not retriable. |
| `RESOURCE_EXHAUSTED` | 8 | Rate limit, quota exceeded, or out of disk/memory. Retriable after backing off. Include `RetryInfo` detail with suggested delay. |
| `FAILED_PRECONDITION` | 9 | Operation rejected because the system is not in the required state (e.g., deleting a non-empty directory). Client should fix the state, not blindly retry. |
| `ABORTED` | 10 | Operation aborted due to concurrency conflict (e.g., optimistic locking failure, transaction abort). Client should retry from the beginning. |
| `OUT_OF_RANGE` | 11 | Operation was attempted past a valid range (e.g., seeking past EOF). Unlike `FAILED_PRECONDITION`, the range is static. |
| `UNIMPLEMENTED` | 12 | RPC method is not implemented or not supported. Returned by `Unimplemented*Server` stubs. Not retriable. |
| `INTERNAL` | 13 | Invariant broken — a bug in the server. Use sparingly; prefer more specific codes. Log and alert on these. |
| `UNAVAILABLE` | 14 | Service is temporarily unavailable. **This is the primary retriable code.** Client should retry with backoff. Use for transient errors only. |
| `DATA_LOSS` | 15 | Unrecoverable data loss or corruption. Very rarely used. |
| `UNAUTHENTICATED` | 16 | Request missing valid authentication credentials. Client should re-authenticate and retry. |

### Status Code Decision Tree

```
Is the request valid?
├── No → INVALID_ARGUMENT
└── Yes → Is the caller authenticated?
    ├── No → UNAUTHENTICATED
    └── Yes → Is the caller authorized?
        ├── No → PERMISSION_DENIED
        └── Yes → Does the resource exist?
            ├── No (for reads) → NOT_FOUND
            ├── Yes (for creates) → ALREADY_EXISTS
            └── Process the request
                ├── Precondition failed → FAILED_PRECONDITION
                ├── Concurrency conflict → ABORTED
                ├── Rate limited → RESOURCE_EXHAUSTED
                ├── Timed out → DEADLINE_EXCEEDED
                ├── Server overloaded → UNAVAILABLE
                ├── Not implemented → UNIMPLEMENTED
                └── Server bug → INTERNAL
```

---

## Well-Known Proto Types

Import from `google/protobuf/`:

| Type | Import | Usage |
|------|--------|-------|
| `Timestamp` | `google/protobuf/timestamp.proto` | Point in time. Use instead of `int64 epoch_millis`. |
| `Duration` | `google/protobuf/duration.proto` | Span of time. Use instead of `int64 duration_ms`. |
| `FieldMask` | `google/protobuf/field_mask.proto` | Partial updates (PATCH semantics). Specify which fields to update. |
| `Struct` | `google/protobuf/struct.proto` | Arbitrary JSON-like data. Avoid if possible — use typed messages. |
| `Any` | `google/protobuf/any.proto` | Wraps any proto message with a type URL. Use for plugin systems. |
| `Empty` | `google/protobuf/empty.proto` | Empty message for RPCs with no meaningful request/response. |
| `StringValue` | `google/protobuf/wrappers.proto` | Nullable string (distinguishes "" from absent). |
| `Int32Value` | `google/protobuf/wrappers.proto` | Nullable int32 (distinguishes 0 from absent). |
| `BoolValue` | `google/protobuf/wrappers.proto` | Nullable bool (distinguishes false from absent). |

### FieldMask Pattern (Partial Updates)

```protobuf
import "google/protobuf/field_mask.proto";

message UpdateOrderRequest {
  Order order = 1;
  google.protobuf.FieldMask update_mask = 2;
}
```

```go
// Server: apply only specified fields
func (s *server) UpdateOrder(ctx context.Context, req *pb.UpdateOrderRequest) (*pb.Order, error) {
    existing := s.getOrder(req.Order.Id)
    for _, path := range req.UpdateMask.Paths {
        switch path {
        case "status":
            existing.Status = req.Order.Status
        case "metadata":
            existing.Metadata = req.Order.Metadata
        }
    }
    return existing, nil
}
```

---

## Common Service Patterns

### Health Checking Service (`grpc.health.v1`)

```protobuf
// Pre-defined — do not redefine
service Health {
  rpc Check(HealthCheckRequest) returns (HealthCheckResponse);
  rpc Watch(HealthCheckRequest) returns (stream HealthCheckResponse);
}

// HealthCheckResponse.ServingStatus:
// UNKNOWN = 0
// SERVING = 1
// NOT_SERVING = 2
// SERVICE_UNKNOWN = 3
```

**Go implementation:**
```go
import (
    "google.golang.org/grpc/health"
    healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

hsrv := health.NewServer()
healthpb.RegisterHealthServer(srv, hsrv)

// Set per-service status
hsrv.SetServingStatus("orders.v1.OrderService", healthpb.HealthCheckResponse_SERVING)

// Set overall server status
hsrv.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
```

**Testing:**
```bash
grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check
grpcurl -plaintext -d '{"service":"orders.v1.OrderService"}' localhost:50051 grpc.health.v1.Health/Check
```

### Server Reflection Service (`grpc.reflection.v1`)

Allows clients to discover services and message types at runtime.

```go
import "google.golang.org/grpc/reflection"
reflection.Register(srv)
```

**Using with grpcurl:**
```bash
# List all services
grpcurl -plaintext localhost:50051 list

# Describe a service
grpcurl -plaintext localhost:50051 describe orders.v1.OrderService

# Describe a message type
grpcurl -plaintext localhost:50051 describe orders.v1.Order
```

### Channelz Service (`grpc.channelz.v1`)

Runtime introspection for debugging connections, streams, and sockets.

```go
import "google.golang.org/grpc/channelz/service"
service.RegisterChannelzServiceToServer(srv)
```

**Querying:**
```bash
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetTopChannels
grpcurl -plaintext localhost:50051 grpc.channelz.v1.Channelz/GetServers
grpcurl -plaintext -d '{"server_id":1}' localhost:50051 grpc.channelz.v1.Channelz/GetServerSockets
```

---

## protoc CLI Reference

### Basic Commands

```bash
# Generate Go code
protoc --go_out=. --go-grpc_out=. \
  --go_opt=paths=source_relative \
  --go-grpc_opt=paths=source_relative \
  -I proto/ \
  proto/orders/v1/orders.proto

# Generate Python code
protoc --python_out=. --grpc_python_out=. \
  -I proto/ \
  proto/orders/v1/orders.proto

# Generate with multiple include paths
protoc -I proto/ -I third_party/ \
  --go_out=gen/go --go-grpc_out=gen/go \
  proto/orders/v1/orders.proto

# Decode binary proto (pipe binary data)
protoc --decode=orders.v1.Order proto/orders/v1/orders.proto < order.bin

# Encode text format to binary
protoc --encode=orders.v1.Order proto/orders/v1/orders.proto < order.txtpb > order.bin
```

### Common Flags

| Flag | Description |
|------|-------------|
| `-I` / `--proto_path` | Add import search path (can specify multiple) |
| `--go_out` | Output directory for Go protobuf messages |
| `--go-grpc_out` | Output directory for Go gRPC service stubs |
| `--go_opt=paths=source_relative` | Generate files relative to proto source |
| `--python_out` | Output directory for Python protobuf messages |
| `--grpc_python_out` | Output directory for Python gRPC stubs |
| `--java_out` | Output directory for Java protobuf messages |
| `--grpc-java_out` | Output directory for Java gRPC stubs |
| `--js_out` | Output directory for JavaScript protobuf messages |
| `--grpc-web_out` | Output directory for gRPC-Web stubs |
| `--descriptor_set_out` | Write a FileDescriptorSet (binary proto file) |
| `--include_imports` | Include transitive imports in descriptor set |
| `--include_source_info` | Include source code info in descriptor set |

---

## buf CLI Reference

### Setup

```bash
# Install
# macOS
brew install bufbuild/buf/buf
# Linux
curl -sSL https://github.com/bufbuild/buf/releases/latest/download/buf-Linux-x86_64 -o buf
chmod +x buf && sudo mv buf /usr/local/bin/

# Initialize a new module
buf config init
```

### Common Commands

```bash
# Generate code from protos
buf generate

# Lint proto files
buf lint
buf lint --error-format=json

# Check for breaking changes
buf breaking --against '.git#branch=main'
buf breaking --against 'buf.build/myorg/myservice'
buf breaking --against '.git#tag=v1.0.0'

# Format proto files
buf format -w

# Push to BSR
buf push
buf push --tag v1.2.0

# Update dependencies
buf dep update

# Export protos (resolve imports)
buf export -o exported/

# Convert between formats
buf convert --type orders.v1.Order --from order.bin --to order.json
buf convert --type orders.v1.Order --from order.json --to order.bin

# List breaking change categories
buf breaking --help
```

### buf.yaml Configuration

```yaml
version: v2
modules:
  - path: proto
    name: buf.build/myorg/myservice
deps:
  - buf.build/googleapis/googleapis
  - buf.build/grpc-ecosystem/grpc-gateway
lint:
  use:
    - STANDARD
  except:
    - PACKAGE_VERSION_SUFFIX
breaking:
  use:
    - FILE
```

### buf.gen.yaml Configuration

```yaml
version: v2
managed:
  enabled: true
  override:
    - file_option: go_package_prefix
      value: github.com/myorg/myservice/gen/go
plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc-ecosystem/gateway
    out: gen/go
    opt:
      - paths=source_relative
      - generate_unbound_methods=true
  - remote: buf.build/connectrpc/go
    out: gen/go
    opt: paths=source_relative
```

### Lint Rules Quick Reference

| Rule | What It Checks |
|------|----------------|
| `DIRECTORY_SAME_PACKAGE` | All files in a directory have the same package |
| `PACKAGE_DEFINED` | Every file has a package declaration |
| `PACKAGE_DIRECTORY_MATCH` | Package matches directory structure |
| `PACKAGE_SAME_DIRECTORY` | Same package is not in multiple directories |
| `ENUM_FIRST_VALUE_ZERO` | First enum value is 0 |
| `ENUM_NO_ALLOW_ALIAS` | No `allow_alias` option on enums |
| `ENUM_PASCAL_CASE` | Enum names are PascalCase |
| `ENUM_VALUE_UPPER_SNAKE_CASE` | Enum values are UPPER_SNAKE_CASE |
| `FIELD_LOWER_SNAKE_CASE` | Field names are lower_snake_case |
| `MESSAGE_PASCAL_CASE` | Message names are PascalCase |
| `RPC_PASCAL_CASE` | RPC names are PascalCase |
| `SERVICE_PASCAL_CASE` | Service names are PascalCase |
| `RPC_REQUEST_RESPONSE_UNIQUE` | Each RPC has unique request/response types |
| `RPC_REQUEST_STANDARD_NAME` | Request messages end with `Request` |
| `RPC_RESPONSE_STANDARD_NAME` | Response messages end with `Response` |
| `PACKAGE_VERSION_SUFFIX` | Package ends with version (e.g., `.v1`) |

---

## grpcurl Quick Reference

```bash
# List services (requires reflection)
grpcurl -plaintext localhost:50051 list

# List methods in a service
grpcurl -plaintext localhost:50051 list orders.v1.OrderService

# Describe a service
grpcurl -plaintext localhost:50051 describe orders.v1.OrderService

# Describe a message type
grpcurl -plaintext localhost:50051 describe orders.v1.Order

# Unary call
grpcurl -plaintext -d '{"customer_id":"c1"}' \
  localhost:50051 orders.v1.OrderService/CreateOrder

# Call with headers
grpcurl -plaintext \
  -H "authorization: Bearer my-token" \
  -H "x-request-id: abc-123" \
  -d '{"order_id":"o1"}' \
  localhost:50051 orders.v1.OrderService/GetOrder

# Server streaming
grpcurl -plaintext -d '{"order_id":"o1"}' \
  localhost:50051 orders.v1.OrderService/WatchOrderStatus

# Use proto file instead of reflection
grpcurl -plaintext -import-path ./proto -proto orders.proto \
  -d '{"customer_id":"c1"}' \
  localhost:50051 orders.v1.OrderService/CreateOrder

# TLS connection
grpcurl -cacert ca.crt -cert client.crt -key client.key \
  order-service:50051 list

# Health check
grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check

# With -connect-timeout and -max-time
grpcurl -plaintext -connect-timeout 5 -max-time 30 \
  localhost:50051 orders.v1.OrderService/CreateOrder
```
