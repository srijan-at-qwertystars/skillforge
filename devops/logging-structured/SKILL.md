---
name: logging-structured
description: |
  Use when user implements structured logging, asks about JSON log format, log levels, correlation/request IDs, MDC/context propagation, or logging libraries (pino, winston, structlog, slog, serilog, log4j2).
  Do NOT use for log aggregation platforms (ELK, Loki, Datadog), Prometheus metrics, or application tracing (use opentelemetry-instrumentation skill).
---

# Structured Logging

## Why Structured Logging

Emit logs as key-value pairs (JSON), not free-form strings. Structured logs are:

- **Machine-parseable** — ingest directly into search/analytics without custom parsers.
- **Queryable** — filter by field (`level:error AND service:payments`).
- **Context-rich** — attach request IDs, user IDs, durations without string interpolation.
- **Consistent** — enforce a schema across all services regardless of language.

## JSON Log Format

Use a consistent schema across every service. Required fields:

```json
{
  "timestamp": "2025-03-23T16:00:01.231Z",
  "level": "info",
  "message": "Order created",
  "service": "order-api",
  "trace_id": "27ab0c00-42dc-11ee-be56-0242ac120002",
  "span_id": "a1b2c3d4e5f60718",
  "request_id": "b19fbb1a-97e5-42ab-9c8b-0f123a594b23",
  "duration_ms": 148
}
```

Rules:
- Use ISO 8601 with timezone for `timestamp`.
- Use lowercase log level strings: `trace`, `debug`, `info`, `warn`, `error`, `fatal`.
- Keep field names snake_case across all services.
- Add domain fields as needed (`user_id`, `order_id`, `endpoint`) — keep them flat, not nested.
- Never put variable data in the `message` field; use structured fields instead.

## Log Levels

| Level   | Use for | Production default |
|---------|---------|--------------------|
| `trace` | Fine-grained debugging (loop iterations, variable state) | Off |
| `debug` | Diagnostic info (SQL queries, cache hits/misses, config loaded) | Off |
| `info`  | Business events (request handled, job completed, user signed in) | On |
| `warn`  | Recoverable issues (retry attempt, deprecated API called, slow query) | On |
| `error` | Failures requiring attention (unhandled exception, external service down) | On |
| `fatal` | Process cannot continue (missing config, port in use, OOM) | On |

Guidelines:
- Set production default to `info`. Enable `debug`/`trace` per-service via config, never code changes.
- Never log expected business outcomes as `error` (e.g., user not found → `info` or `warn`).
- One `error` log = one alert-worthy event. Keep signal-to-noise ratio high.

## Correlation IDs and Request Tracing

Generate a unique ID at the system boundary (API gateway, message consumer). Propagate it through every downstream call.

### Generation and Propagation

```
Client → API Gateway (generate X-Request-ID) → Service A → Service B → Service C
                         ↓                         ↓            ↓
                    All logs include request_id="abc-123"
```

- Use `X-Request-ID` or `X-Correlation-ID` HTTP header.
- If the header already exists (from client or upstream), preserve it.
- For async messaging, embed `correlation_id` in the message envelope.
- Map to OpenTelemetry `trace_id`/`span_id` when distributed tracing is active.

### Middleware Example (Node.js)

```javascript
import { randomUUID } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";

const als = new AsyncLocalStorage();

function correlationMiddleware(req, res, next) {
  const requestId = req.headers["x-request-id"] || randomUUID();
  res.setHeader("x-request-id", requestId);
  als.run({ requestId }, () => next());
}

function getRequestId() {
  return als.getStore()?.requestId;
}
```

### Middleware Example (Python / FastAPI)

```python
import uuid
from contextvars import ContextVar

request_id_var: ContextVar[str] = ContextVar("request_id", default="")

@app.middleware("http")
async def correlation_middleware(request, call_next):
    rid = request.headers.get("x-request-id", str(uuid.uuid4()))
    token = request_id_var.set(rid)
    response = await call_next(request)
    response.headers["x-request-id"] = rid
    request_id_var.reset(token)
    return response
```

## Context Propagation

Attach context once, include it in every log automatically.

### Java — MDC (Mapped Diagnostic Context)

```java
import org.slf4j.MDC;

// In filter/interceptor:
MDC.put("request_id", requestId);
MDC.put("user_id", userId);
try {
    chain.doFilter(request, response);
} finally {
    MDC.clear();
}

// logback.xml JSON layout automatically includes MDC fields.
```

### Python — contextvars + structlog

```python
import structlog

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ]
)

# Bind context for the current request:
structlog.contextvars.bind_contextvars(request_id=rid, user_id=uid)
log = structlog.get_logger()
log.info("order.created", order_id="o-456", total=99.95)
# Output: {"request_id":"...","user_id":"...","level":"info","timestamp":"...","event":"order.created","order_id":"o-456","total":99.95}
```

### Node.js — AsyncLocalStorage + pino

```javascript
import pino from "pino";
import { AsyncLocalStorage } from "node:async_hooks";

const als = new AsyncLocalStorage();
const baseLogger = pino({ level: "info" });

function getLogger() {
  const store = als.getStore();
  return store?.logger || baseLogger;
}

// In middleware:
als.run({ logger: baseLogger.child({ requestId, userId }) }, () => next());

// In handlers:
getLogger().info({ orderId: "o-456", total: 99.95 }, "order created");
```

### Go — slog context

```go
import "log/slog"

// Attach context fields via groups or With:
logger := slog.Default().With(
    slog.String("request_id", rid),
    slog.String("user_id", uid),
)
logger.Info("order created",
    slog.String("order_id", "o-456"),
    slog.Float64("total", 99.95),
)
```

### .NET — Serilog LogContext

```csharp
using Serilog.Context;

// In middleware:
using (LogContext.PushProperty("RequestId", requestId))
using (LogContext.PushProperty("UserId", userId))
{
    await next(context);
}

// Anywhere in the request pipeline:
Log.Information("Order created {@OrderId} {@Total}", orderId, total);
```

## Library Recommendations

### Node.js — pino

Fastest Node.js logger. JSON by default. Use child loggers for context. Use `pino-pretty` in dev only.

```javascript
import pino from "pino";

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  serializers: {
    err: pino.stdSerializers.err,
    req: pino.stdSerializers.req,
  },
  redact: ["req.headers.authorization", "body.password"],
});

const child = logger.child({ service: "payment-api" });
child.info({ orderId: "o-789" }, "payment processed");
```

Key features: built-in redaction, custom serializers, async transport via `pino.transport()`.

### Python — structlog

Processor pipeline architecture. Bind context incrementally. Integrates with stdlib `logging`.

```python
import structlog

log = structlog.get_logger()
log = log.bind(service="payment-api")
log.info("payment.processed", order_id="o-789", amount=49.99)
```

Use `structlog.stdlib.ProcessorFormatter` to route structlog through stdlib handlers for library compatibility.

### Go — log/slog (stdlib)

Standard library since Go 1.21. Use `slog.JSONHandler` for production.

```go
package main

import (
    "log/slog"
    "os"
)

func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level: slog.LevelInfo,
    }))
    slog.SetDefault(logger)

    slog.Info("payment processed",
        slog.String("service", "payment-api"),
        slog.String("order_id", "o-789"),
        slog.Float64("amount", 49.99),
    )
}
```

Use `slog.Group` for namespaced fields. Write custom `slog.Handler` for redaction or enrichment.

### Java — SLF4J + Logback (or Log4j2)

Use SLF4J as the facade. Configure JSON output via Logback's `JsonEncoder` or Log4j2's `JsonTemplateLayout`.

```xml
<!-- logback.xml -->
<appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
  <encoder class="ch.qos.logback.classic.encoder.JsonEncoder"/>
</appender>
```

```java
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

Logger log = LoggerFactory.getLogger(PaymentService.class);
log.atInfo()
   .addKeyValue("order_id", orderId)
   .addKeyValue("amount", amount)
   .log("payment processed");
```

Use `MDC` for request-scoped context (see Context Propagation above). Use async appenders for throughput.

### .NET — Serilog

Message templates with structured capture. Rich sink ecosystem.

```csharp
Log.Logger = new LoggerConfiguration()
    .Enrich.FromLogContext()
    .Enrich.WithProperty("Service", "payment-api")
    .WriteTo.Console(new RenderedCompactJsonFormatter())
    .CreateLogger();

Log.Information("Payment processed {OrderId} {Amount}", orderId, amount);
```

Use `Destructure.ByTransforming<T>()` to control how complex objects serialize. Use `WriteTo.Async()` for buffered output.

## What to Log

- Request/response metadata: method, path, status code, duration.
- Business events: order created, user registered, payment failed.
- State transitions: job started → completed/failed.
- External call results: service name, status, latency.
- Error details: error type, message, stack trace, error ID.

## What NOT to Log

- **Passwords, tokens, API keys, secrets** — never, under any circumstance.
- **PII** (emails, SSNs, phone numbers) — redact or tokenize before logging.
- **Full request/response bodies** — log selectively; large payloads waste storage and risk leaking data.
- **Health check successes** — log failures only; successes create noise at scale.
- **Repetitive loop iterations** — aggregate instead (e.g., "processed 1000 items in 340ms").

## Error Logging Patterns

### Include Error Context

```javascript
// Bad
logger.error("something went wrong");

// Good
logger.error({
  err,
  orderId,
  userId,
  operation: "payment.charge",
  errorId: randomUUID(),
}, "payment charge failed");
```

### Assign Error IDs

Generate a unique `error_id` per error log entry. Return it in API responses so support can correlate user reports to logs: `{ "error": "Payment failed", "error_id": "err-a1b2c3d4" }`.

### Stack Traces

- Include full stack traces for unexpected errors at `error` level.
- Omit stack traces for expected/handled errors (validation failures, 404s).
- Serialize stack traces as a single string field in JSON, not an array.

## Log Redaction and Sanitization

Redact at the logging layer, not after the fact. Examples:
const logger = pino({
  redact: {
    paths: ["req.headers.authorization", "body.password", "body.ssn"],
    censor: "[REDACTED]",
  },
});
```

### structlog processor

```python
SENSITIVE_KEYS = {"password", "token", "ssn", "credit_card"}

def redact_sensitive(_, __, event_dict):
    for key in SENSITIVE_KEYS:
        if key in event_dict:
            event_dict[key] = "[REDACTED]"
    return event_dict

structlog.configure(processors=[redact_sensitive, ...])
```

### Serilog destructure policy

```csharp
Log.Logger = new LoggerConfiguration()
    .Destructure.ByTransforming<CreditCard>(
        cc => new { Last4 = cc.Number[^4..], cc.Expiry })
    .CreateLogger();
```

Rules:
- Maintain a central allow-list of loggable fields — deny by default.
- Audit log output regularly for PII leaks.
- Integrate redaction checks into CI (lint rules, custom analyzers).

## Performance Considerations

### Async Logging

Offload I/O from the hot path. Every major library supports this:

- **pino**: `pino.transport({ target: 'pino/file' })` runs in a worker thread.
- **Logback**: `AsyncAppender` wraps any appender with a queue.
- **Serilog**: `WriteTo.Async(a => a.File(...))`.
- **slog**: Write a custom handler that buffers and flushes asynchronously.

### Sampling

For high-throughput paths (>10k req/s), sample verbose logs:

```javascript
if (Math.random() < 0.01) {
  logger.debug({ latency, query }, "db query executed");
}
```

Better: use a sampling processor that guarantees error logs are never dropped.

### Log Levels in Production

- Default to `info`. Change levels at runtime via config or feature flags — no redeploys.
- Guard expensive log construction:

```java
// Avoid computing debug message if debug is off:
if (log.isDebugEnabled()) {
    log.debug("Cache state: {}", computeExpensiveCacheSnapshot());
}

// Or use SLF4J fluent API (lazy evaluation):
log.atDebug().addArgument(() -> computeExpensiveCacheSnapshot()).log("Cache state: {}");
```

```go
if logger.Enabled(ctx, slog.LevelDebug) {
    logger.Debug("cache state", slog.Any("snapshot", computeSnapshot()))
}
```

## Anti-Patterns

### String Concatenation

```javascript
// Bad — allocates string even if debug is off, loses structure
logger.debug("User " + userId + " purchased " + itemId + " for $" + price);

// Good — structured, zero-cost if level is disabled
logger.debug({ userId, itemId, price }, "purchase completed");
```

### Logging in Hot Loops

```go
// Bad — logs per item, floods output
for _, item := range items {
    slog.Info("processing item", slog.String("id", item.ID))
}

// Good — log summary
slog.Info("batch processed", slog.Int("count", len(items)), slog.Duration("elapsed", elapsed))
```

### Inconsistent Formats

Pick one schema and enforce it. Do not mix:
- `userId` / `user_id` / `UserID` — choose `user_id`, enforce with linting.
- Timestamps as Unix epoch in one service, ISO 8601 in another — use ISO 8601 everywhere.
- `msg` / `message` / `event` — pick one, configure all loggers the same way.

### Logging Without Context

```python
# Bad — useless in production
log.error("request failed")

# Good — actionable
log.error("request.failed", method="POST", path="/api/orders",
          status=500, error_id="err-x1y2", duration_ms=230)
```

### Catching and Swallowing

```java
// Bad — hides failures
try { process(order); }
catch (Exception e) { log.warn("oops"); }

// Good — preserves full context
try { process(order); }
catch (Exception e) {
    log.atError()
       .addKeyValue("order_id", order.getId())
       .setCause(e)
       .log("order processing failed");
    throw;
}
```
