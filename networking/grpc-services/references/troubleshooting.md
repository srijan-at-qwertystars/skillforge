# gRPC Troubleshooting Guide

> Diagnosis and fixes for common gRPC issues. Organized by symptom.

## Table of Contents

- [Error Code Reference](#error-code-reference)
- [UNAVAILABLE vs DEADLINE_EXCEEDED](#unavailable-vs-deadline_exceeded)
- [Connection Reset](#connection-reset)
- [TLS Handshake Failures](#tls-handshake-failures)
- [Proto Compatibility Breaks](#proto-compatibility-breaks)
- [Code Generation Mismatches](#code-generation-mismatches)
- [Streaming Backpressure](#streaming-backpressure)
- [Memory Leaks in Streaming](#memory-leaks-in-streaming)
- [Interceptor Ordering Bugs](#interceptor-ordering-bugs)
- [Metadata Size Limits](#metadata-size-limits)
- [Debugging with grpcurl](#debugging-with-grpcurl)
- [Debugging with grpcui](#debugging-with-grpcui)
- [Evans CLI](#evans-cli)
- [Common Error Codes and Fixes](#common-error-codes-and-fixes)

---

## Error Code Reference

| Code | Numeric | Retryable | Meaning |
|------|---------|-----------|---------|
| `OK` | 0 | — | Success |
| `CANCELLED` | 1 | No | Client cancelled |
| `UNKNOWN` | 2 | Maybe | Server returned a non-status error |
| `INVALID_ARGUMENT` | 3 | No | Client sent bad data |
| `DEADLINE_EXCEEDED` | 4 | Maybe | Timeout (could be transient) |
| `NOT_FOUND` | 5 | No | Resource doesn't exist |
| `ALREADY_EXISTS` | 6 | No | Conflict on create |
| `PERMISSION_DENIED` | 7 | No | Authed but not authorized |
| `RESOURCE_EXHAUSTED` | 8 | Yes | Rate limited |
| `FAILED_PRECONDITION` | 9 | No | System state wrong |
| `ABORTED` | 10 | Yes | Concurrency conflict |
| `OUT_OF_RANGE` | 11 | No | Pagination/offset invalid |
| `UNIMPLEMENTED` | 12 | No | Method not found |
| `INTERNAL` | 13 | No | Server bug |
| `UNAVAILABLE` | 14 | Yes | Transient failure |
| `DATA_LOSS` | 15 | No | Unrecoverable data loss |
| `UNAUTHENTICATED` | 16 | No | Missing/invalid credentials |

---

## UNAVAILABLE vs DEADLINE_EXCEEDED

### UNAVAILABLE (code 14)

**Meaning:** Server is temporarily unreachable. Safe to retry.

**Common causes:**
- Server process not running or crashed.
- DNS resolution failure.
- Network partition.
- Load balancer has no healthy backends.
- Server's `MaxConnectionAge` triggered reconnect.
- TLS certificate expired.

**Client sees:**
```
rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp: connect: connection refused"
```

**Fix:** Retry with exponential backoff. Check server health. Verify DNS.

### DEADLINE_EXCEEDED (code 4)

**Meaning:** Operation didn't complete within the deadline.

**Common causes:**
- Client deadline too short.
- Server is slow (CPU, DB, downstream).
- Network latency spike.
- Queued behind slow requests (head-of-line).
- Deadline propagated through a chain — upstream consumed all time.

**Client sees:**
```
rpc error: code = DeadlineExceeded desc = context deadline exceeded
```

**Debugging deadline propagation:**
```go
// Check remaining deadline on server
deadline, ok := ctx.Deadline()
if ok {
    remaining := time.Until(deadline)
    log.Printf("remaining deadline: %v", remaining)
    if remaining < 100*time.Millisecond {
        return nil, status.Error(codes.DeadlineExceeded, "not enough time to process")
    }
}
```

**Key difference:** UNAVAILABLE = can't connect. DEADLINE_EXCEEDED = connected but slow. Both may be retryable, but DEADLINE_EXCEEDED retries need a fresh deadline.

---

## Connection Reset

### Symptoms

```
rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: read tcp: read: connection reset by peer"
```

or

```
rpc error: code = Internal desc = stream terminated by RST_STREAM with error code: NO_ERROR
```

### Causes and Fixes

| Cause | Fix |
|-------|-----|
| Server `MaxConnectionAge` expired | Handle reconnects; increase age or add grace period |
| Server `GracefulStop()` during RPC | Add `MaxConnectionAgeGrace` to allow in-flight RPCs |
| Proxy/LB idle timeout | Set keepalive `Time` < proxy idle timeout |
| Server OOM killed | Monitor memory; reduce `MaxRecvMsgSize` |
| HTTP/2 GOAWAY | Normal during graceful drain; client retries automatically |
| TLS cert rotation | Use cert reloading, not restart |

### Server-Side Graceful Drain

```go
// Signal handler for graceful shutdown
sigCh := make(chan os.Signal, 1)
signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
<-sigCh

// Stop accepting new RPCs, drain existing ones
go func() {
    time.Sleep(30 * time.Second) // Hard deadline
    s.Stop()
}()
s.GracefulStop() // Wait for in-flight RPCs
```

---

## TLS Handshake Failures

### Symptoms

```
transport: authentication handshake failed: tls: first record does not look like a TLS handshake
```

```
transport: authentication handshake failed: x509: certificate signed by unknown authority
```

### Diagnosis Matrix

| Error | Cause | Fix |
|-------|-------|-----|
| `first record does not look like a TLS handshake` | Client using TLS, server is plaintext (or vice versa) | Match TLS config on both sides |
| `certificate signed by unknown authority` | Client doesn't trust server's CA | Add CA cert to client's cert pool |
| `certificate is not valid for` | CN/SAN doesn't match target hostname | Fix cert or use `grpc.WithAuthority()` |
| `certificate has expired` | Cert validity period passed | Rotate certificates |
| `bad certificate` | mTLS: server doesn't trust client cert | Add client CA to server's cert pool |
| `handshake failure` (generic) | TLS version or cipher mismatch | Check `tls.Config.MinVersion` and cipher suites |

### Debug TLS

```bash
# Check cert details
openssl s_client -connect localhost:50051 -alpn h2 2>/dev/null | openssl x509 -noout -text

# Test with grpcurl (skip verify for debugging)
grpcurl -insecure localhost:50051 list

# Test with specific CA
grpcurl -cacert ca.crt localhost:50051 list
```

### Common mTLS Setup Bug

```go
// BUG: Using NewServerTLSFromFile without ClientAuth
creds, _ := credentials.NewServerTLSFromFile("server.crt", "server.key")

// FIX: Full mTLS config
cert, _ := tls.LoadX509KeyPair("server.crt", "server.key")
caCert, _ := os.ReadFile("ca.crt")
caPool := x509.NewCertPool()
caPool.AppendCertsFromPEM(caCert)
creds := credentials.NewTLS(&tls.Config{
    Certificates: []tls.Certificate{cert},
    ClientAuth:   tls.RequireAndVerifyClientCert,
    ClientCAs:    caPool,
})
```

---

## Proto Compatibility Breaks

### Symptoms

- Client gets `UNIMPLEMENTED` for existing methods.
- Fields missing or zero in responses.
- Deserialization errors or garbage data.
- Enum values decode as numbers instead of names.

### Detection

```bash
# Detect breaking changes against main
buf breaking --against '.git#branch=main'

# Detect against BSR
buf breaking --against 'buf.build/acme/payments'
```

### Common Breaks

| Change | Why It Breaks | Fix |
|--------|--------------|-----|
| Changed field number | Wire format corrupted | Reserve old number, add new field |
| Changed field type | Deserializes as wrong type | Add new field, deprecate old |
| Removed field | Old clients send data to void | Use `reserved` |
| Renamed enum value | JSON serialization breaks | Add alias, keep old value |
| Changed `oneof` membership | Wire encoding changes | Don't move fields in/out of oneof |
| Changed `repeated` → scalar | Wire encoding incompatible | New field |
| Changed package name | Full method name changes | `UNIMPLEMENTED` on all RPCs |

### Safe Migration Pattern

```protobuf
// Step 1: Add new field alongside old
message Payment {
    string old_status = 3 [deprecated = true]; // Will remove in v2
    PaymentStatus status_enum = 7;             // New typed field
}

// Step 2: Server writes both fields during migration
// Step 3: Clients migrate to new field
// Step 4: Reserve old field
message Payment {
    reserved 3;
    reserved "old_status";
    PaymentStatus status_enum = 7;
}
```

---

## Code Generation Mismatches

### Symptoms

- `undefined: pb.UnimplementedXxxServer`
- Type assertion failures at runtime.
- `RegisterXxxServer` signature doesn't match.
- Import path confusion.

### Causes and Fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Missing `Unimplemented*` embed | Generated code newer than server code | Regenerate: `buf generate` |
| Wrong package imports | `go_package` option mismatch | Check `option go_package` in `.proto` |
| Stale generated files | Forgot to regenerate after proto change | Add `buf generate` to CI/build |
| Mixed protoc/buf output | Different codegen tools produce incompatible code | Standardize on one tool |
| Version skew | `protoc-gen-go` version doesn't match `protoc-gen-go-grpc` | Pin versions in `buf.gen.yaml` or `go.mod` |

### Nuclear Fix

```bash
# Delete all generated code and regenerate
find gen/ -name "*.pb.go" -delete
find gen/ -name "*_grpc.pb.go" -delete
buf generate
```

### Go Module Issues

```bash
# Ensure protobuf packages are consistent
go get google.golang.org/protobuf@latest
go get google.golang.org/grpc@latest
go get google.golang.org/genproto@latest
go mod tidy
```

---

## Streaming Backpressure

### Symptoms

- Server memory grows during streaming.
- `Send()` blocks for long periods.
- Client recv buffer overflows.
- `RESOURCE_EXHAUSTED` errors.

### How Backpressure Works

```
Producer → Send() → HTTP/2 flow control window → Recv() → Consumer
           ↑ blocks when window full                ↑ must drain
```

`Send()` blocks when the receiver's flow control window is exhausted. This is *correct behavior* — it's backpressure working as designed.

### Problem: Unbounded Producer

```go
// BAD: Buffering defeats backpressure
func (s *server) StreamData(req *pb.Req, stream pb.Svc_StreamDataServer) error {
    ch := make(chan *pb.Data, 1000000) // Huge buffer = OOM risk
    go producer(ch)
    for msg := range ch {
        stream.Send(msg)
    }
    return nil
}

// GOOD: Direct send with context check
func (s *server) StreamData(req *pb.Req, stream pb.Svc_StreamDataServer) error {
    for data := range s.produce(stream.Context()) {
        if err := stream.Send(data); err != nil {
            return err
        }
    }
    return nil
}
```

### Problem: Slow Consumer

If the client is slow to recv, the server's Send blocks. Server-side timeouts:

```go
func sendWithTimeout(stream grpc.ServerStream, msg proto.Message, timeout time.Duration) error {
    ch := make(chan error, 1)
    go func() { ch <- stream.SendMsg(msg) }()
    select {
    case err := <-ch:
        return err
    case <-time.After(timeout):
        return status.Error(codes.DeadlineExceeded, "send timed out")
    }
}
```

---

## Memory Leaks in Streaming

### Symptoms

- Server RSS grows over time.
- Go runtime pprof shows allocations in gRPC stream code.
- `goroutine` count increases without bound.

### Common Leaks

**Leak 1: Unfinished streams**

```go
// BAD: Stream handler returns without draining
func (s *server) Watch(req *pb.Req, stream pb.Svc_WatchServer) error {
    ch := s.subscribe()
    // Missing: defer s.unsubscribe(ch) — channel and goroutine leak
    for msg := range ch {
        stream.Send(msg)
    }
    return nil
}
```

**Leak 2: Client not closing stream**

```go
// BAD: Client opens stream but never closes
stream, _ := client.Watch(ctx, req)
msg, _ := stream.Recv() // Read one message and abandon
// Stream stays open, server keeps goroutine

// FIX: Always cancel the context
ctx, cancel := context.WithCancel(context.Background())
defer cancel() // Closes stream and server-side handler
stream, _ := client.Watch(ctx, req)
```

**Leak 3: Goroutine leak in bidi**

```go
// BAD: Recv goroutine outlives handler
func (s *server) Chat(stream pb.Svc_ChatServer) error {
    go func() {
        for {
            msg, _ := stream.Recv() // Never exits if stream is abandoned
            s.process(msg)
        }
    }()
    // ...
}

// FIX: Use context cancellation
func (s *server) Chat(stream pb.Svc_ChatServer) error {
    ctx := stream.Context()
    go func() {
        for {
            msg, err := stream.Recv()
            if err != nil { return } // EOF or cancel exits goroutine
            s.process(msg)
        }
    }()
    <-ctx.Done()
    return ctx.Err()
}
```

### Diagnosis

```go
// Add pprof endpoint alongside gRPC
go func() {
    http.ListenAndServe(":6060", nil) // Default pprof handlers
}()
```

```bash
# Check goroutine count
go tool pprof http://localhost:6060/debug/pprof/goroutine

# Check heap
go tool pprof http://localhost:6060/debug/pprof/heap
```

---

## Interceptor Ordering Bugs

### The Order Matters

```go
// Interceptors execute LEFT to RIGHT, innermost last
grpc.ChainUnaryInterceptor(
    recoveryInterceptor,  // 1st: catches panics from everything below
    loggingInterceptor,   // 2nd: logs the request/response
    authInterceptor,      // 3rd: checks auth
    rateLimitInterceptor, // 4th: rate limits
)
```

Execution order: recovery → logging → auth → rateLimit → handler → rateLimit → auth → logging → recovery

### Common Bugs

**Bug 1: Auth after logging — logs unauthenticated requests**

```go
// BAD: Logs sensitive data from unauthed requests
grpc.ChainUnaryInterceptor(loggingInterceptor, authInterceptor)

// FIX: Auth first
grpc.ChainUnaryInterceptor(authInterceptor, loggingInterceptor)
```

**Bug 2: Recovery not outermost — panics crash server**

```go
// BAD: Panic in loggingInterceptor is uncaught
grpc.ChainUnaryInterceptor(loggingInterceptor, recoveryInterceptor)

// FIX: Recovery always outermost
grpc.ChainUnaryInterceptor(recoveryInterceptor, loggingInterceptor)
```

**Bug 3: Forgetting stream interceptors**

```go
// BAD: Only protects unary RPCs
grpc.NewServer(grpc.ChainUnaryInterceptor(authInterceptor))

// FIX: Also chain stream interceptors
grpc.NewServer(
    grpc.ChainUnaryInterceptor(authInterceptor),
    grpc.ChainStreamInterceptor(streamAuthInterceptor),
)
```

**Bug 4: Context not propagated**

```go
// BAD: Ignores enriched context from interceptor
func myInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo,
    handler grpc.UnaryHandler) (any, error) {
    newCtx := context.WithValue(ctx, "user", user)
    return handler(ctx, req) // BUG: passes old ctx, not newCtx
}

// FIX
return handler(newCtx, req)
```

---

## Metadata Size Limits

### Defaults

- gRPC Go: 8KB for received metadata (header + trailer combined).
- Envoy: 60KB default for headers.
- HTTP/2 HPACK: individual header value max ~16KB.

### Symptoms

```
rpc error: code = Internal desc = header list size exceeds limit
```

### Fix: Increase Limit

```go
// Server
grpc.NewServer(grpc.MaxHeaderListSize(32 * 1024)) // 32KB

// Client
grpc.NewClient(target, grpc.WithMaxHeaderListSize(32 * 1024))
```

### Best Practice

Don't put large data in metadata. Use message fields instead.

```go
// BAD: Large JWT or payload in metadata
md := metadata.Pairs("x-user-data", hugeJSONBlob)

// GOOD: Small identifiers in metadata, bulk data in message
md := metadata.Pairs("x-request-id", "abc123")
```

---

## Debugging with grpcurl

### Installation

```bash
# macOS
brew install grpcurl

# Go install
go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest

# Docker
docker run fullstorydev/grpcurl -plaintext host.docker.internal:50051 list
```

### Common Commands

```bash
# List all services (requires reflection)
grpcurl -plaintext localhost:50051 list

# Describe a service
grpcurl -plaintext localhost:50051 describe acme.payments.v1.PaymentService

# Unary call
grpcurl -plaintext \
  -d '{"amount":{"currency_code":"USD","units":100}}' \
  localhost:50051 acme.payments.v1.PaymentService/CreatePayment

# With metadata
grpcurl -plaintext \
  -H 'authorization: Bearer tok123' \
  -H 'x-request-id: debug-1' \
  -d '{"id":"pay_1"}' \
  localhost:50051 acme.payments.v1.PaymentService/GetPayment

# Server streaming
grpcurl -plaintext \
  -d '{"filter":"status=PENDING"}' \
  localhost:50051 acme.payments.v1.PaymentService/WatchPayments

# Without reflection (provide proto files)
grpcurl -plaintext \
  -import-path ./proto \
  -proto payments/v1/payments.proto \
  -d '{}' \
  localhost:50051 acme.payments.v1.PaymentService/ListPayments

# TLS with client cert
grpcurl -cacert ca.crt -cert client.crt -key client.key \
  myserver:50051 list

# Health check
grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check
grpcurl -plaintext \
  -d '{"service":"acme.payments.v1.PaymentService"}' \
  localhost:50051 grpc.health.v1.Health/Check

# Verbose output (shows headers/trailers)
grpcurl -plaintext -v \
  -d '{}' \
  localhost:50051 acme.payments.v1.PaymentService/ListPayments
```

---

## Debugging with grpcui

```bash
# Install
go install github.com/fullstorydev/grpcui/cmd/grpcui@latest

# Launch (opens browser)
grpcui -plaintext localhost:50051

# With TLS
grpcui -cacert ca.crt localhost:50051

# On a different port
grpcui -plaintext -port 8080 localhost:50051
```

grpcui provides a web form for each RPC — fill in fields, set metadata, send, and see responses. Excellent for manual testing and demos.

---

## Evans CLI

Interactive gRPC client with REPL mode.

### Installation

```bash
# macOS
brew install evans

# Go install
go install github.com/ktr0731/evans@latest
```

### Usage

```bash
# Connect with reflection
evans -r repl -p 50051

# Inside REPL:
> show service
> show message
> package acme.payments.v1
> service PaymentService
> call CreatePayment
# Interactive prompt fills in fields

# CLI mode (non-interactive)
echo '{"amount":{"currency_code":"USD","units":100}}' | \
  evans -r cli -p 50051 call acme.payments.v1.PaymentService.CreatePayment
```

### Evans vs grpcurl

| Feature | grpcurl | Evans |
|---------|---------|-------|
| Scripting | ✅ Better | ❌ REPL-focused |
| Interactive | ❌ CLI only | ✅ REPL with prompts |
| Streaming | ✅ Full support | ✅ Full support |
| Tab completion | ❌ | ✅ |
| Field auto-fill | ❌ | ✅ Prompts per field |

---

## Common Error Codes and Fixes

### `code = Unavailable desc = connection closed before server preface received`

**Cause:** Server isn't speaking HTTP/2, or a proxy is blocking.
**Fix:** Check if server is actually running gRPC (not HTTP/1.1). Check for L4 proxies that don't support HTTP/2.

### `code = Unimplemented desc = unknown service`

**Cause:** Service not registered, or proto package mismatch.
**Fix:**
```bash
# Verify service is registered
grpcurl -plaintext localhost:50051 list
# Check the full service name matches your proto package
```

### `code = Unavailable desc = transport is closing`

**Cause:** Server sent GOAWAY (graceful shutdown, MaxConnectionAge).
**Fix:** Client automatically reconnects. If frequent, increase `MaxConnectionAge`.

### `code = ResourceExhausted desc = grpc: received message larger than max`

**Cause:** Message exceeds `MaxRecvMsgSize` (default 4MB).
**Fix:** Increase limit or use streaming:
```go
grpc.MaxRecvMsgSize(16 * 1024 * 1024) // 16MB
```

### `code = Internal desc = stream terminated by RST_STREAM`

**Cause:** HTTP/2 stream reset. Often from proxy timeouts or server bugs.
**Fix:** Check proxy idle stream timeouts. Enable keepalives.

### `code = FailedPrecondition desc = ...`

**Cause:** Operation rejected because system isn't in required state.
**Fix:** Application-specific. Usually means a state machine transition was invalid. Check business logic, not infrastructure.

### `code = Unknown desc = ...`

**Cause:** Server returned a Go `error` instead of `status.Error`.
**Fix:** Always wrap errors:
```go
// BAD
return nil, fmt.Errorf("db error: %w", err)

// GOOD
return nil, status.Errorf(codes.Internal, "db error: %v", err)
```

### `code = Unavailable desc = name resolver error`

**Cause:** DNS resolution failed.
**Fix:** Check target format. Use `dns:///hostname:port` for DNS resolver. Verify DNS is reachable.
