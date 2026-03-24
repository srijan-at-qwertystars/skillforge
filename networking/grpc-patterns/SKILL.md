---
name: grpc-patterns
description: >
  Guide for building gRPC services with Protocol Buffers, streaming RPCs, interceptors, and production infrastructure.
  Use when: building gRPC services, writing protobuf definitions, implementing bidirectional streaming,
  service-to-service RPC communication, grpc-web browser clients, protoc code generation, gRPC interceptors
  or middleware, gRPC error handling, gRPC load balancing, or gRPC health checking.
  Do NOT use when: building REST APIs, implementing GraphQL resolvers, WebSocket-based chat applications,
  simple HTTP request/response endpoints, browser-only apps without grpc-web proxy, or general HTTP routing.
---

# gRPC Patterns

## Protocol Buffers (proto3)

Use `syntax = "proto3";` at the top of every `.proto` file. Set `package` and `option go_package` / `option java_package` for generated code namespacing.

### Messages

```protobuf
syntax = "proto3";
package orders.v1;

message Order {
  string id = 1;
  string customer_id = 2;
  repeated LineItem items = 3;
  OrderStatus status = 4;
  map<string, string> metadata = 5;
  google.protobuf.Timestamp created_at = 6;
}

message LineItem {
  string product_id = 1;
  int32 quantity = 2;
  double price = 3;
}
```

### Enums, Oneofs, Maps, Imports

```protobuf
import "google/protobuf/timestamp.proto";
import "google/protobuf/any.proto";

enum OrderStatus {
  ORDER_STATUS_UNSPECIFIED = 0;
  ORDER_STATUS_PENDING = 1;
  ORDER_STATUS_CONFIRMED = 2;
  ORDER_STATUS_SHIPPED = 3;
}

message Payment {
  oneof method {
    CreditCard credit_card = 1;
    BankTransfer bank_transfer = 2;
    Wallet wallet = 3;
  }
}
```

Always set enum zero value to `_UNSPECIFIED`. Prefix enum values with the enum name in UPPER_SNAKE_CASE. Use `reserved` to prevent reuse of deleted field numbers.

## Service Definitions

Define all four RPC patterns in a single service block:

```protobuf
service OrderService {
  // Unary
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
  // Server streaming
  rpc WatchOrderStatus(WatchOrderRequest) returns (stream OrderStatusUpdate);
  // Client streaming
  rpc UploadLineItems(stream LineItem) returns (UploadSummary);
  // Bidirectional streaming
  rpc Chat(stream ChatMessage) returns (stream ChatMessage);
}
```

Keep request/response messages per-RPC (`CreateOrderRequest`, not `Order`). This allows independent evolution without breaking other RPCs.

## Code Generation

### protoc

```bash
# Install plugins
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# Generate Go code
protoc --go_out=. --go-grpc_out=. \
  --go_opt=paths=source_relative \
  --go-grpc_opt=paths=source_relative \
  proto/orders/v1/orders.proto
```

### buf (preferred)

Create `buf.yaml` with `version: v2`, module path, deps (e.g., `buf.build/googleapis/googleapis`), and lint/breaking rules. Create `buf.gen.yaml` with plugin configs for your target languages.

Run `buf generate` to produce code. Run `buf lint` before committing. Run `buf breaking --against '.git#branch=main'` to catch breaking changes.

## Server Implementation

### Go

```go
type orderServer struct {
    pb.UnimplementedOrderServiceServer
}

func (s *orderServer) CreateOrder(ctx context.Context, req *pb.CreateOrderRequest) (*pb.CreateOrderResponse, error) {
    if req.GetCustomerId() == "" {
        return nil, status.Errorf(codes.InvalidArgument, "customer_id required")
    }
    order := &pb.Order{Id: uuid.NewString(), CustomerId: req.GetCustomerId()}
    return &pb.CreateOrderResponse{Order: order}, nil
}

func main() {
    lis, _ := net.Listen("tcp", ":50051")
    srv := grpc.NewServer()
    pb.RegisterOrderServiceServer(srv, &orderServer{})
    reflection.Register(srv) // enable server reflection
    srv.Serve(lis)
}
```

### Node.js (@grpc/grpc-js)

```javascript
const grpc = require("@grpc/grpc-js");
const protoLoader = require("@grpc/proto-loader");
const packageDef = protoLoader.loadSync("orders.proto");
const proto = grpc.loadPackageDefinition(packageDef);

const server = new grpc.Server();
server.addService(proto.orders.v1.OrderService.service, {
  createOrder(call, callback) {
    callback(null, { order: { id: "123", customerId: call.request.customerId } });
  },
});
server.bindAsync("0.0.0.0:50051", grpc.ServerCredentials.createInsecure(), () => server.start());
```

### Python

```python
class OrderServicer(orders_pb2_grpc.OrderServiceServicer):
    def CreateOrder(self, request, context):
        if not request.customer_id:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, "customer_id required")
        return orders_pb2.CreateOrderResponse(
            order=orders_pb2.Order(id=str(uuid4()), customer_id=request.customer_id)
        )

server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
orders_pb2_grpc.add_OrderServiceServicer_to_server(OrderServicer(), server)
server.add_insecure_port("[::]:50051")
server.start()
server.wait_for_termination()
```

## Client Patterns

### Stubs and Channels

```go
// Go: create channel with options
conn, err := grpc.NewClient("dns:///order-service:50051",
    grpc.WithTransportCredentials(insecure.NewCredentials()),
    grpc.WithDefaultServiceConfig(`{"loadBalancingConfig":[{"round_robin":{}}]}`),
)
defer conn.Close()
client := pb.NewOrderServiceClient(conn)
```

Reuse a single channel across goroutines/threads. Channels manage connection pooling internally—do not create one per request.

### Streaming Client

```go
stream, err := client.WatchOrderStatus(ctx, &pb.WatchOrderRequest{OrderId: "abc"})
for {
    update, err := stream.Recv()
    if err == io.EOF { break }
    if err != nil { log.Fatal(err) }
    fmt.Println(update.Status)
}
```

## Error Handling

### Status Codes

Use the most specific code. Common mappings:

| Scenario | Code |
|---|---|
| Bad input / validation | `INVALID_ARGUMENT` |
| Entity not found | `NOT_FOUND` |
| Already exists | `ALREADY_EXISTS` |
| Caller lacks permission | `PERMISSION_DENIED` |
| Caller not authenticated | `UNAUTHENTICATED` |
| Timeout exceeded | `DEADLINE_EXCEEDED` |
| Server overloaded | `UNAVAILABLE` (client should retry) |
| Bug in server logic | `INTERNAL` |
| Feature not implemented | `UNIMPLEMENTED` |

### Rich Error Details

```go
import "google.golang.org/genproto/googleapis/rpc/errdetails"

st := status.New(codes.InvalidArgument, "invalid order")
br := &errdetails.BadRequest{
    FieldViolations: []*errdetails.BadRequest_FieldViolation{
        {Field: "quantity", Description: "must be > 0"},
    },
}
st, _ = st.WithDetails(br)
return nil, st.Err()
```

Client-side extraction:

```go
st := status.Convert(err)
for _, detail := range st.Details() {
    if br, ok := detail.(*errdetails.BadRequest); ok {
        for _, v := range br.FieldViolations {
            log.Printf("field=%s desc=%s", v.Field, v.Description)
        }
    }
}
```

## Interceptors / Middleware

### Unary Server Interceptor (Go)

```go
func loggingInterceptor(ctx context.Context, req interface{},
    info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
    start := time.Now()
    resp, err := handler(ctx, req)
    log.Printf("method=%s duration=%s err=%v", info.FullMethod, time.Since(start), err)
    return resp, err
}

srv := grpc.NewServer(grpc.UnaryInterceptor(loggingInterceptor))
```

### Stream Server Interceptor

```go
func streamInterceptor(srv interface{}, ss grpc.ServerStream,
    info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
    log.Printf("stream started: %s", info.FullMethod)
    return handler(srv, ss)
}

grpc.NewServer(grpc.StreamInterceptor(streamInterceptor))
```

Chain multiple interceptors with `grpc.ChainUnaryInterceptor(...)` and `grpc.ChainStreamInterceptor(...)`. Order matters—auth before logging before metrics.

### Client Interceptors

```go
conn, _ := grpc.NewClient(addr,
    grpc.WithUnaryInterceptor(clientLoggingInterceptor),
    grpc.WithStreamInterceptor(clientStreamInterceptor),
)
```

## Deadlines, Timeouts, and Cancellation

Always set deadlines. RPCs without deadlines risk hanging forever.

```go
ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
defer cancel()
resp, err := client.CreateOrder(ctx, req)
if status.Code(err) == codes.DeadlineExceeded {
    log.Println("request timed out")
}
```

```python
try:
    response = stub.CreateOrder(request, timeout=5.0)
except grpc.RpcError as e:
    if e.code() == grpc.StatusCode.DEADLINE_EXCEEDED:
        print("timed out")
```

Deadlines propagate across service hops automatically via gRPC metadata. In a call chain A→B→C, if A's deadline expires, B and C are cancelled.

## Metadata and Headers

```go
// Client: send metadata
md := metadata.Pairs("x-request-id", uuid.NewString(), "authorization", "Bearer "+token)
ctx := metadata.NewOutgoingContext(ctx, md)
resp, err := client.CreateOrder(ctx, req)

// Server: read metadata
md, ok := metadata.FromIncomingContext(ctx)
reqID := md.Get("x-request-id")

// Server: send response headers and trailers
grpc.SendHeader(ctx, metadata.Pairs("x-trace-id", traceID))
grpc.SetTrailer(ctx, metadata.Pairs("x-processing-time", elapsed))
```

Binary metadata values: append `-bin` suffix to the key. gRPC base64-encodes automatically.

## Authentication

### TLS

```go
creds, _ := credentials.NewServerTLSFromFile("server.crt", "server.key")
srv := grpc.NewServer(grpc.Creds(creds))

// Client
creds, _ := credentials.NewClientTLSFromFile("ca.crt", "")
conn, _ := grpc.NewClient(addr, grpc.WithTransportCredentials(creds))
```

### Per-RPC Token Credentials

```go
type tokenAuth struct{ token string }
func (t tokenAuth) GetRequestMetadata(ctx context.Context, uri ...string) (map[string]string, error) {
    return map[string]string{"authorization": "Bearer " + t.token}, nil
}
func (t tokenAuth) RequireTransportSecurity() bool { return true }

conn, _ := grpc.NewClient(addr,
    grpc.WithTransportCredentials(creds),
    grpc.WithPerRPCCredentials(tokenAuth{token: "my-jwt"}),
)
```

Validate tokens in a server unary interceptor. Return `codes.Unauthenticated` for missing/invalid tokens, `codes.PermissionDenied` for insufficient scopes.

## Load Balancing

### Client-Side (DNS + Round Robin)

```go
conn, _ := grpc.NewClient("dns:///my-service.default.svc.cluster.local:50051",
    grpc.WithDefaultServiceConfig(`{"loadBalancingConfig":[{"round_robin":{}}]}`),
)
```

### Proxy-Based

Place Envoy, NGINX, or a cloud L7 load balancer in front of gRPC backends. Configure HTTP/2 upstream support. Envoy is preferred for gRPC—it understands the protocol natively.

### xDS

For service mesh integration, use xDS-enabled gRPC clients. Import `google.golang.org/grpc/xds` and use `xds:///service-name` as the target. The client fetches endpoints, routing rules, and LB policies from the xDS control plane (e.g., Istio, Traffic Director).

## Health Checking and Reflection

### Health Checking

Implement `grpc.health.v1.Health` on the server:

```go
import "google.golang.org/grpc/health"
import healthpb "google.golang.org/grpc/health/grpc_health_v1"

hsrv := health.NewServer()
healthpb.RegisterHealthServer(srv, hsrv)
hsrv.SetServingStatus("orders.v1.OrderService", healthpb.HealthCheckResponse_SERVING)
```

Client-side health checking via service config:

```json
{ "healthCheckConfig": { "serviceName": "orders.v1.OrderService" } }
```

### Server Reflection

Enable reflection so tools like grpcurl and Evans can introspect services:

```go
import "google.golang.org/grpc/reflection"
reflection.Register(srv)
```

## gRPC-Web

Use gRPC-Web when browser clients need to call gRPC services. The browser cannot use HTTP/2 trailers directly, so a proxy translates.

**Option 1: Envoy proxy** — add `envoy.filters.http.grpc_web` filter.  
**Option 2: Connect protocol** — use `connectrpc.com/connect` (Go) for a single server serving gRPC, gRPC-Web, and Connect clients without a proxy.

```typescript
// Browser client with @connectrpc/connect-web
import { createGrpcWebTransport } from "@connectrpc/connect-web";
import { createClient } from "@connectrpc/connect";
import { OrderService } from "./gen/orders/v1/orders_connect";

const transport = createGrpcWebTransport({ baseUrl: "https://api.example.com" });
const client = createClient(OrderService, transport);
const res = await client.createOrder({ customerId: "c1" });
```

## Testing gRPC Services

### grpcurl

```bash
# List services (requires reflection)
grpcurl -plaintext localhost:50051 list

# Describe a service
grpcurl -plaintext localhost:50051 describe orders.v1.OrderService

# Call unary RPC
grpcurl -plaintext -d '{"customer_id":"c1"}' localhost:50051 orders.v1.OrderService/CreateOrder

# Health check
grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check
```

### Evans (interactive)

```bash
evans --host localhost --port 50051 -r repl
# Inside REPL: call CreateOrder
```

### Unit Testing (Go)

Use `bufconn` for in-process testing without a real network listener:

```go
func bufDialer(lis *bufconn.Listener) func(context.Context, string) (net.Conn, error) {
    return func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }
}

func TestCreateOrder(t *testing.T) {
    lis := bufconn.Listen(1024 * 1024)
    srv := grpc.NewServer()
    pb.RegisterOrderServiceServer(srv, &orderServer{})
    go srv.Serve(lis)
    defer srv.Stop()

    conn, _ := grpc.NewClient("passthrough:///bufnet",
        grpc.WithContextDialer(bufDialer(lis)),
        grpc.WithTransportCredentials(insecure.NewCredentials()),
    )
    defer conn.Close()
    client := pb.NewOrderServiceClient(conn)

    resp, err := client.CreateOrder(context.Background(), &pb.CreateOrderRequest{CustomerId: "c1"})
    require.NoError(t, err)
    assert.NotEmpty(t, resp.Order.Id)
}
```

### Python Unit Testing

Use `grpc_testing.server_from_dictionary` to create an in-process server. Call `invoke_unary_unary` with the service descriptor, request, and assert on the returned status code.

## Key Conventions

- Version proto packages: `package myservice.v1;`. Use `v2` for breaking changes.
- Never reuse or change field numbers. Use `reserved` for removed fields.
- Set deadlines on every RPC call. Default 5s for internal, 30s for external-facing.
- Return the narrowest gRPC status code. Avoid `UNKNOWN` and `INTERNAL` for expected errors.
- Chain interceptors: auth → rate-limit → logging → metrics.
- Use `buf lint` and `buf breaking` in CI to enforce schema quality.
- Enable health checking and reflection on every production server.
- Prefer `connect-go` when serving both gRPC and browser clients from one binary.
