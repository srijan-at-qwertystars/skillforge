---
name: grpc-services
description: >
  USE when building gRPC services, protobuf schemas, RPC APIs, streaming endpoints,
  service mesh communication, or microservice-to-microservice calls. USE when user
  mentions protobuf, proto files, .proto, protoc, buf, grpc-go, grpc-js, nice-grpc,
  connect-rpc, connect-es, connect-go, grpcio, betterproto, tonic, grpcurl, service
  definitions, unary RPC, streaming RPC, gRPC-Web, or Connect protocol. USE for
  interceptors, metadata, deadlines, health checks, reflection, or gRPC load balancing.
  DO NOT USE for REST APIs, GraphQL, WebSocket-only protocols, HTTP-only middleware,
  OpenAPI/Swagger specs, or message queues (Kafka, RabbitMQ, NATS). DO NOT USE for
  plain protobuf serialization without gRPC service context.
---

# gRPC Services

## Architecture

gRPC uses HTTP/2 transport, Protocol Buffers for serialization, and IDL-first service
definitions. HTTP/2 provides multiplexing, header compression, and bidirectional streaming.
Flow: `.proto` defines contract → codegen produces typed stubs → server implements
interface → client calls through a channel with deadline.

## Protocol Buffers (proto3)

Always use `syntax = "proto3";`. Set `package` with version suffix.

```protobuf
syntax = "proto3";
package acme.payments.v1;
option go_package = "github.com/acme/payments/gen/go/payments/v1;paymentsv1";
import "google/protobuf/timestamp.proto";
import "google/protobuf/field_mask.proto";

enum PaymentStatus {
  PAYMENT_STATUS_UNSPECIFIED = 0;  // Always have UNSPECIFIED = 0
  PAYMENT_STATUS_PENDING = 1;
  PAYMENT_STATUS_COMPLETED = 2;
  PAYMENT_STATUS_FAILED = 3;
}

message Money {
  string currency_code = 1;
  int64 units = 2;
  int32 nanos = 3;
}

message Payment {
  string id = 1;
  Money amount = 2;
  PaymentStatus status = 3;
  google.protobuf.Timestamp created_at = 4;
  map<string, string> metadata = 5;
  repeated string tags = 6;
  oneof source {
    string card_id = 10;
    string bank_account_id = 11;
  }
}

message CreatePaymentRequest {
  Money amount = 1;
  string idempotency_key = 2;
}
message CreatePaymentResponse { Payment payment = 1; }

message ListPaymentsRequest {
  int32 page_size = 1;
  string page_token = 2;
  google.protobuf.FieldMask read_mask = 3;
}
message ListPaymentsResponse {
  repeated Payment payments = 1;
  string next_page_token = 2;
}
```

**Rules**: Prefix enum values with enum name. Tags 1–15 use 1-byte encoding — reserve
for hot fields. `reserved` removed field numbers. Name messages `<Verb>Request`/`Response`.
Use well-known types (`Timestamp`, `Duration`, `FieldMask`, wrappers) over custom ones.

## Service Definitions & RPC Types

```protobuf
service PaymentService {
  rpc CreatePayment(CreatePaymentRequest) returns (CreatePaymentResponse);           // Unary
  rpc WatchPayments(WatchPaymentsRequest) returns (stream Payment);                  // Server streaming
  rpc BatchCreatePayments(stream CreatePaymentRequest) returns (BatchResponse);      // Client streaming
  rpc PaymentChat(stream PaymentEvent) returns (stream PaymentEvent);                // Bidi streaming
}
```

Default to unary. Server streaming for watches/feeds. Client streaming for bulk uploads.
Bidi for real-time collaboration.

## Code Generation

### Buf CLI (recommended)
```yaml
# buf.yaml
version: v2
modules:
  - path: proto
lint:
  use: [STANDARD]
breaking:
  use: [FILE]
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
```bash
buf lint && buf breaking --against '.git#branch=main' && buf generate
```

### protoc (traditional)
```bash
protoc --go_out=. --go_opt=paths=source_relative \
       --go-grpc_out=. --go-grpc_opt=paths=source_relative \
       proto/payments/v1/payments.proto
```

## Go Implementation

```go
type paymentServer struct {
    pb.UnimplementedPaymentServiceServer // Required: forward compat
}

func (s *paymentServer) CreatePayment(
    ctx context.Context, req *pb.CreatePaymentRequest,
) (*pb.CreatePaymentResponse, error) {
    if req.GetAmount() == nil {
        return nil, status.Error(codes.InvalidArgument, "amount required")
    }
    payment := &pb.Payment{Id: "pay_123", Amount: req.GetAmount(), Status: pb.PAYMENT_STATUS_PENDING}
    return &pb.CreatePaymentResponse{Payment: payment}, nil
}

func main() {
    lis, _ := net.Listen("tcp", ":50051")
    s := grpc.NewServer(
        grpc.ChainUnaryInterceptor(loggingInterceptor, authInterceptor),
    )
    pb.RegisterPaymentServiceServer(s, &paymentServer{})

    healthSrv := health.NewServer()
    healthpb.RegisterHealthServer(s, healthSrv)
    healthSrv.SetServingStatus("acme.payments.v1.PaymentService", healthpb.HealthCheckResponse_SERVING)
    reflection.Register(s)

    s.Serve(lis)
}
```

### Interceptors (Go)
```go
func loggingInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo,
    handler grpc.UnaryHandler) (any, error) {
    start := time.Now()
    resp, err := handler(ctx, req)
    log.Printf("method=%s duration=%s err=%v", info.FullMethod, time.Since(start), err)
    return resp, err
}

func authInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo,
    handler grpc.UnaryHandler) (any, error) {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok || len(md.Get("authorization")) == 0 {
        return nil, status.Error(codes.Unauthenticated, "missing auth token")
    }
    return handler(ctx, req)
}
```

### Client (Go)
```go
conn, _ := grpc.NewClient("localhost:50051",
    grpc.WithTransportCredentials(insecure.NewCredentials()),
)
defer conn.Close()
client := pb.NewPaymentServiceClient(conn)

ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second) // Always set deadline
defer cancel()
resp, err := client.CreatePayment(ctx, &pb.CreatePaymentRequest{
    Amount: &pb.Money{CurrencyCode: "USD", Units: 100},
    IdempotencyKey: "key-abc-123",
})
```

## TypeScript/Node Implementation

### nice-grpc (recommended Node server)
```typescript
import { createServer, createChannel, createClient, ServerError, Status } from 'nice-grpc';
const server = createServer();
server.add(PaymentServiceDefinition, {
  async createPayment(request) {
    if (!request.amount) throw new ServerError(Status.INVALID_ARGUMENT, 'amount required');
    return { payment: { id: 'pay_123', amount: request.amount } };
  },
  async *watchPayments(request) { // Server streaming via async generator
    yield { id: 'pay_1', status: 'COMPLETED' };
  },
});
await server.listen('0.0.0.0:50051');

// Client
const channel = createChannel('localhost:50051');
const client = createClient(PaymentServiceDefinition, channel);
const resp = await client.createPayment({ amount: { currencyCode: 'USD', units: 100 } });
```

### Connect-ES (browser + Node, supports gRPC + gRPC-Web + Connect)
```typescript
import { ConnectRouter } from '@connectrpc/connect';
import { fastify } from 'fastify';
import { fastifyConnectPlugin } from '@connectrpc/connect-fastify';

const routes = (router: ConnectRouter) => {
  router.service(PaymentService, {
    async createPayment(req) {
      return { payment: { id: 'pay_123', amount: req.amount } };
    },
  });
};
const app = fastify();
await app.register(fastifyConnectPlugin, { routes });
await app.listen({ port: 8080 });
```

## Python Implementation

### grpcio
```python
class PaymentServicer(payments_pb2_grpc.PaymentServiceServicer):
    def CreatePayment(self, request, context):
        if not request.HasField("amount"):
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, "amount required")
        return payments_pb2.CreatePaymentResponse(
            payment=payments_pb2.Payment(id="pay_123", amount=request.amount))

server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
payments_pb2_grpc.add_PaymentServiceServicer_to_server(PaymentServicer(), server)
server.add_insecure_port("[::]:50051")
server.start(); server.wait_for_termination()
```

### betterproto (async, idiomatic Python)
```python
class PaymentService(PaymentServiceBase):
    async def create_payment(self, amount, idempotency_key, **kwargs):
        return CreatePaymentResponse(payment=Payment(id="pay_123", amount=amount))

server = Server([PaymentService()])
await server.start("0.0.0.0", 50051)
```

## Error Handling

| Code | When |
|------|------|
| `INVALID_ARGUMENT` | Bad client input |
| `NOT_FOUND` | Resource missing |
| `ALREADY_EXISTS` | Duplicate create |
| `PERMISSION_DENIED` | Authenticated but not authorized |
| `UNAUTHENTICATED` | Missing/invalid credentials |
| `UNAVAILABLE` | Transient error (safe to retry) |
| `DEADLINE_EXCEEDED` | Timeout |
| `RESOURCE_EXHAUSTED` | Rate limit hit |
| `INTERNAL` | Unexpected server error |
| `FAILED_PRECONDITION` | System not in required state |

### Rich Error Details (Go)
```go
st := status.New(codes.InvalidArgument, "invalid payment")
detailed, _ := st.WithDetails(&errdetails.BadRequest{
    FieldViolations: []*errdetails.BadRequest_FieldViolation{
        {Field: "amount.units", Description: "must be positive"},
    },
})
return nil, detailed.Err()
```

## Metadata, Deadlines, Authentication

```go
// Send metadata from client
md := metadata.Pairs("x-request-id", "req-123", "authorization", "Bearer tok")
ctx := metadata.NewOutgoingContext(ctx, md)

// Read metadata on server
md, _ := metadata.FromIncomingContext(ctx)

// Send headers/trailers from server
grpc.SetHeader(ctx, metadata.Pairs("x-trace-id", "abc"))
grpc.SetTrailer(ctx, metadata.Pairs("x-timing", "50ms"))
```

**Deadlines**: Always set on client. Propagated via context. Python: `stub.Method(req, timeout=5.0)`

### mTLS
```go
// Server
creds, _ := credentials.NewServerTLSFromFile("server.crt", "server.key")
s := grpc.NewServer(grpc.Creds(creds))
// Client
creds, _ := credentials.NewClientTLSFromFile("ca.crt", "server.example.com")
conn, _ := grpc.NewClient("server:443", grpc.WithTransportCredentials(creds))
```

### Per-RPC Token
```go
type tokenAuth struct{ token string }
func (t tokenAuth) GetRequestMetadata(ctx context.Context, _ ...string) (map[string]string, error) {
    return map[string]string{"authorization": "Bearer " + t.token}, nil
}
func (t tokenAuth) RequireTransportSecurity() bool { return true }
// Use: grpc.WithPerRPCCredentials(tokenAuth{token: "jwt"})
```

## Health Checking & Reflection

Register `grpc.health.v1.Health`. Kubernetes uses it directly:
```yaml
livenessProbe:
  grpc:
    port: 50051
```
Test: `grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check`

Enable `reflection.Register(s)` for `grpcurl`/`grpcui` discovery:
```bash
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext -d '{"amount":{"currency_code":"USD","units":100}}' \
  localhost:50051 acme.payments.v1.PaymentService/CreatePayment
```

## Load Balancing

**Proxy**: Envoy, Nginx, Linkerd — standard in Kubernetes.
**Client-side**: `round_robin` via service config.
```go
conn, _ := grpc.NewClient("dns:///my-service:50051",
    grpc.WithDefaultServiceConfig(`{"loadBalancingConfig":[{"round_robin":{}}]}`))
```
**xDS**: Dynamic config from Envoy control plane. Routes, LB, and auth distributed
to gRPC clients without proxy hop.

## gRPC-Web & Connect Protocol

**gRPC-Web**: Browser-compatible subset. No client streaming. Deploy via Envoy proxy
or prefer Connect for new services.

**Connect**: Wire-compatible with gRPC, also works over HTTP/1.1 + JSON. Debuggable
with curl. Libraries: `connect-go`, `connect-es`, `connect-kotlin`.
```go
mux := http.NewServeMux()
path, handler := paymentsv1connect.NewPaymentServiceHandler(&paymentServer{})
mux.Handle(path, handler)
http.ListenAndServe(":8080", h2c.NewHandler(mux, &http2.Server{}))
```
Test: `curl -X POST http://localhost:8080/acme.payments.v1.PaymentService/CreatePayment -H 'Content-Type: application/json' -d '{"amount":{"currencyCode":"USD","units":100}}'`

## Testing

### Go: bufconn (in-process, no network)
```go
func TestCreatePayment(t *testing.T) {
    lis := bufconn.Listen(1024 * 1024)
    s := grpc.NewServer()
    pb.RegisterPaymentServiceServer(s, &paymentServer{})
    go s.Serve(lis)
    conn, _ := grpc.NewClient("passthrough:///bufconn",
        grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
            return lis.DialContext(ctx)
        }),
        grpc.WithTransportCredentials(insecure.NewCredentials()),
    )
    client := pb.NewPaymentServiceClient(conn)
    resp, err := client.CreatePayment(context.Background(), &pb.CreatePaymentRequest{
        Amount: &pb.Money{CurrencyCode: "USD", Units: 100}, IdempotencyKey: "test-key",
    })
    require.NoError(t, err)
    assert.Equal(t, "pay_123", resp.GetPayment().GetId())
}
```

### Connect: standard httptest
```go
mux := http.NewServeMux()
mux.Handle(paymentsv1connect.NewPaymentServiceHandler(&paymentServer{}))
srv := httptest.NewServer(mux)
client := paymentsv1connect.NewPaymentServiceClient(http.DefaultClient, srv.URL)
resp, err := client.CreatePayment(ctx, connect.NewRequest(&pb.CreatePaymentRequest{...}))
```

### Python: pytest fixture
```python
@pytest.fixture
def grpc_server():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
    payments_pb2_grpc.add_PaymentServiceServicer_to_server(PaymentServicer(), server)
    port = server.add_insecure_port("[::]:0")
    server.start()
    yield port
    server.stop(grace=0)

def test_create_payment(grpc_server):
    with grpc.insecure_channel(f"localhost:{grpc_server}") as ch:
        stub = payments_pb2_grpc.PaymentServiceStub(ch)
        resp = stub.CreatePayment(payments_pb2.CreatePaymentRequest(
            amount=payments_pb2.Money(currency_code="USD", units=100)))
        assert resp.payment.id == "pay_123"
```

## Common Pitfalls

1. **Missing `UnimplementedServer` embed** — breaks when new methods are added.
2. **No deadlines on client calls** — requests hang forever.
3. **Returning `error` not `status.Error`** — client gets `UNKNOWN` status.
4. **Reusing proto field numbers** — silent wire corruption. Use `reserved`.
5. **Blocking in streaming handlers** — check `ctx.Err()`, return on cancel.
6. **Large messages** — default 4MB limit. Stream or set `grpc.MaxRecvMsgSize`.
7. **`UNAVAILABLE` vs `INTERNAL`** — only `UNAVAILABLE` is retry-safe.
8. **No health checks** — K8s/LBs can't route traffic correctly.
9. **Unversioned proto packages** — use `foo.v1` for safe evolution.
10. **Skipping buf lint** — catches naming and structure issues before review.

## References

Deep-dive docs for specific topics:

- **[`references/advanced-patterns.md`](references/advanced-patterns.md)** — Streaming best practices,
  flow control, keepalive tuning, connection management, retry policies, hedging,
  service mesh (Istio/Envoy), gRPC-Web proxying, reflection, channelz, xDS load
  balancing, custom codecs, compression, large messages, protobuf evolution.

- **[`references/troubleshooting.md`](references/troubleshooting.md)** — Error code reference,
  UNAVAILABLE vs DEADLINE_EXCEEDED, connection reset, TLS failures, proto compatibility,
  codegen mismatches, streaming backpressure, memory leaks, interceptor ordering,
  metadata limits, debugging with grpcurl/grpcui/Evans.

- **[`references/buf-guide.md`](references/buf-guide.md)** — Buf CLI deep dive: buf.yaml v2,
  buf.gen.yaml, lint rules, breaking change detection, BSR, managed mode, remote
  plugins, buf curl, protoc migration, CI integration.

## Scripts

Executable utilities in `scripts/`:

- **`scripts/proto-init.sh`** — Scaffold a new protobuf project with buf.yaml,
  buf.gen.yaml, directory structure, and starter proto file.
  Usage: `./scripts/proto-init.sh <project-name> <go|ts|python>`

- **`scripts/grpc-health-check.sh`** — Health check a gRPC service via grpcurl.
  Reports health status, lists services via reflection.
  Usage: `./scripts/grpc-health-check.sh <host:port> [service-name] [--list] [--tls]`

- **`scripts/proto-breaking-check.sh`** — Run buf breaking change detection against
  a git branch. Usage: `./scripts/proto-breaking-check.sh [branch]`

## Assets & Templates

Reusable templates in `assets/`:

- **`assets/service.proto`** — Proto3 service template with CRUD, pagination,
  field masks, batch operations, and proper naming conventions.
- **`assets/buf.yaml`** — Modern buf.yaml v2 with STANDARD lint + FILE breaking rules.
- **`assets/buf.gen.yaml`** — Code generation for Go + TypeScript (Connect-ES)
  with managed mode.
- **`assets/go-server-template.go`** — Go gRPC server with interceptors (recovery,
  logging, request-id), health check, reflection, keepalive, graceful shutdown.
- **`assets/docker-compose.yml`** — Dev environment: gRPC server, Envoy gRPC-Web
  proxy, grpcui testing UI.

<!-- tested: pass -->
