---
name: error-handling-patterns
description:
  positive: "Use when user designs error handling, asks about error types, Result/Either patterns, error boundaries, error propagation, custom error classes, error codes, or structured error responses in APIs."
  negative: "Do NOT use for Rust-specific error handling (use rust-error-handling skill), logging configuration (use logging-structured skill), or monitoring/alerting."
---

# Error Handling Patterns

## Philosophy

- **Fail fast.** Detect errors at the earliest point and surface them immediately.
- **Be explicit.** Make error paths visible in types and signatures. Never hide failures.
- **Distinguish recoverable from unrecoverable.** Validation failures are recoverable; corrupted state is not. Choose the mechanism accordingly.
- **Errors are data.** Treat errors as structured values, not strings. Attach context, codes, and metadata.
- **Handle at the right layer.** Catch errors where you have enough context to act. Propagate everything else.

## Exception-Based Patterns

### Custom Exception Hierarchy

Define domain-specific exceptions. Extend from a base application error, not the root Error/Exception class.

```typescript
// TypeScript
class AppError extends Error {
  constructor(message: string, public readonly code: string, options?: ErrorOptions) {
    super(message, options);
    this.name = this.constructor.name;
  }
}

class NotFoundError extends AppError {
  constructor(resource: string, id: string) {
    super(`${resource} ${id} not found`, "NOT_FOUND");
  }
}

class ValidationError extends AppError {
  constructor(public readonly fields: Record<string, string[]>) {
    super("Validation failed", "VALIDATION_ERROR");
  }
}
```

### Checked vs Unchecked Exceptions

- **Checked (Java):** Force callers to handle or declare. Use for recoverable conditions.
- **Unchecked (RuntimeException):** Use for programming errors. Do not catch in business logic.
- **Modern consensus:** Prefer unchecked with explicit documentation. Checked exceptions create coupling.

### Try/Catch Best Practices

- Catch the most specific exception type. Never catch `Exception` or `Throwable` broadly.
- Always re-throw or wrap unknown exceptions. Never swallow silently.
- Use `finally` / context managers for cleanup, not catch blocks.

## Result/Either Type Patterns

### TypeScript Result Pattern

```typescript
// Minimal discriminated union
type Result<T, E = Error> =
  | { ok: true; value: T }
  | { ok: false; error: E };

function parseAge(input: string): Result<number, string> {
  const n = Number(input);
  if (isNaN(n) || n < 0) return { ok: false, error: "Invalid age" };
  return { ok: true, value: n };
}

// Usage — compiler forces handling both branches
const result = parseAge(raw);
if (!result.ok) return handleError(result.error);
console.log(result.value);
```

### neverthrow

```typescript
import { ok, err, Result, ResultAsync } from "neverthrow";

function divide(a: number, b: number): Result<number, string> {
  return b === 0 ? err("Division by zero") : ok(a / b);
}

// Chain operations — short-circuits on first error
const result = divide(10, 2)
  .map((v) => v * 100)
  .andThen((v) => divide(v, 3));

// Async variant
const fetched = ResultAsync.fromPromise(
  fetch("/api/users"),
  () => new Error("Network failure")
);
```

### Effect Library

Use for complex applications needing typed errors, dependency injection, and resource management.

```typescript
import { Effect } from "effect";

const program = Effect.tryPromise({
  try: () => fetch("/api/data").then((r) => r.json()),
  catch: () => new NetworkError(),
}).pipe(Effect.flatMap((data) =>
  validate(data) ? Effect.succeed(data) : Effect.fail(new ValidationError())
));
```

### When to Use Which

| Approach | Use When |
|----------|----------|
| Exceptions | Truly unexpected failures, framework boundaries, legacy interop |
| Result types | Domain logic, parsing, validation, any operation with expected failure modes |
| Effect | Complex async workflows, resource management, dependency injection |

## Error Propagation

### Wrapping With Context

```typescript
// TypeScript — Error cause (ES2022)
try {
  await db.query(sql);
} catch (err) {
  throw new AppError("Failed to fetch user orders", "DB_ERROR", { cause: err });
}
```

```go
// Go — wrap with fmt.Errorf
func GetUser(id int) (*User, error) {
    row, err := db.QueryRow("SELECT ...", id)
    if err != nil {
        return nil, fmt.Errorf("get user %d: %w", id, err)
    }
    return scanUser(row)
}
```

```python
# Python — raise from
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    raise AppError("Invalid config file", "PARSE_ERROR") from e
```

### Error Cause Chains

```typescript
function getRootCause(err: Error): Error {
  return err.cause instanceof Error ? getRootCause(err.cause) : err;
}
```

## API Error Responses

### RFC 9457 Problem Details (supersedes RFC 7807)

Use `application/problem+json` for all API error responses.

```json
{
  "type": "https://api.example.com/problems/insufficient-funds",
  "title": "Insufficient Funds",
  "status": 422,
  "detail": "Account xxxx1234 has $10.00, but $50.00 is required.",
  "instance": "/transfers/txn-789",
  "balance": 10.00,
  "required": 50.00,
  "traceId": "abc-123-def"
}
```

### Error Envelope Pattern

Wrap errors in a consistent envelope when not using Problem Details:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Request validation failed",
    "details": [
      { "field": "email", "message": "Invalid email format" },
      { "field": "age", "message": "Must be between 0 and 150" }
    ],
    "traceId": "req-abc-123"
  }
}
```

### Error Codes

- Define a registry of stable, documented error codes (e.g., `USER_NOT_FOUND`, `RATE_LIMITED`).
- Error codes are for machines. Messages are for humans. Clients switch on codes, never on message text.

### Internationalization

Return error codes and machine-readable fields. Let the client localize messages.

## HTTP Status Code Mapping

| Code | Use When |
|------|----------|
| 400 | Malformed request syntax, invalid JSON |
| 401 | Missing or invalid authentication |
| 403 | Authenticated but unauthorized for this resource |
| 404 | Resource does not exist |
| 409 | Conflict with current state (duplicate, version mismatch) |
| 422 | Valid syntax but semantically invalid (validation errors) |
| 429 | Rate limited |
| 500 | Unexpected server error (bug, unhandled exception) |
| 502 | Upstream service returned invalid response |
| 503 | Service temporarily unavailable (maintenance, overloaded) |
| 504 | Upstream service timeout |

- **4xx = client's fault.** Include detail for the client to fix the request.
- **5xx = server's fault.** Log full details server-side. Return minimal info to client.

## Error Boundaries

### React Error Boundaries

```tsx
class ErrorBoundary extends React.Component<Props, { error?: Error }> {
  state: { error?: Error } = {};

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    reportError(error, info.componentStack);
  }

  render() {
    if (this.state.error) return <FallbackUI error={this.state.error} />;
    return this.props.children;
  }
}
```

Place boundaries at route level and around independently-failing widgets. Each boundary renders its own fallback.

### Framework-Level Boundaries

- **Express:** Final error-handling middleware `(err, req, res, next)`.
- **Next.js:** `error.tsx` files per route segment.
- **Spring:** `@ControllerAdvice` with `@ExceptionHandler`.
- **ASP.NET:** `UseExceptionHandler` middleware with Problem Details.

### Graceful Degradation

When a non-critical feature fails, disable it and serve the page. Show cached data when live source is unavailable. Log the failure silently.

## Validation Errors

### Input Validation

Validate at the boundary. Parse, don't validate — convert raw input into validated domain types.

```typescript
import { z } from "zod";

const CreateUserSchema = z.object({
  email: z.string().email(),
  age: z.number().int().min(0).max(150),
  name: z.string().min(1).max(200),
});

function parseCreateUser(input: unknown): Result<z.infer<typeof CreateUserSchema>, ValidationError> {
  const parsed = CreateUserSchema.safeParse(input);
  if (!parsed.success) return { ok: false, error: new ValidationError(formatZodErrors(parsed.error)) };
  return { ok: true, value: parsed.data };
}
```

### Aggregated Field-Level Errors

Return all validation errors at once. Never return one at a time.

```json
{ "code": "VALIDATION_ERROR", "errors": [
  { "field": "email", "code": "INVALID_FORMAT", "message": "Must be a valid email" },
  { "field": "age", "code": "OUT_OF_RANGE", "message": "Must be between 0 and 150" }
]}
```

## Async Error Handling

### Promise Rejection Patterns

```typescript
// Always return rejected promises, never throw inside async functions
async function fetchUser(id: string): Promise<User> {
  const res = await fetch(`/api/users/${id}`);
  if (!res.ok) throw new AppError(`Fetch failed: ${res.status}`, "FETCH_ERROR");
  return res.json();
}
```

### Unhandled Rejection Handlers

Register global handlers as a safety net, not primary error handling:

```typescript
// Node.js — fail fast on unhandled rejections
process.on("unhandledRejection", (reason) => {
  logger.error("Unhandled rejection", { reason });
  process.exit(1);
});
```

### Promise.allSettled for Partial Failures

```typescript
const results = await Promise.allSettled([fetchA(), fetchB(), fetchC()]);
const failures = results.filter((r) => r.status === "rejected").map((r) => r.reason);
if (failures.length) logger.warn("Partial failures", { failures });
```

## Retry and Recovery

### Retriable vs Non-Retriable

| Retriable | Non-Retriable |
|-----------|---------------|
| 429 Too Many Requests | 400 Bad Request |
| 503 Service Unavailable | 401 Unauthorized |
| Network timeout | 403 Forbidden |
| Connection reset | 404 Not Found |
| 500 (idempotent requests only) | 409 Conflict |

### Exponential Backoff

```typescript
async function withRetry<T>(
  fn: () => Promise<T>,
  opts: { maxRetries: number; baseDelayMs: number }
): Promise<T> {
  for (let attempt = 0; attempt <= opts.maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt === opts.maxRetries || !isRetriable(err)) throw err;
      const delay = opts.baseDelayMs * 2 ** attempt + Math.random() * 100;
      await new Promise((r) => setTimeout(r, delay));
    }
  }
  throw new Error("Unreachable");
}
```

### Dead Letter Queues

Route messages that fail after max retries to a DLQ. Attach error, attempt count, and timestamp. Monitor DLQ depth.

## Language-Specific Patterns

### TypeScript / JavaScript

```typescript
// Error subclasses with cause (ES2022)
class DatabaseError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "DatabaseError";
  }
}

// AggregateError for multiple failures
throw new AggregateError([new Error("DB timeout"), new Error("Cache miss")], "Multi-failure");
```

### Python

```python
# ExceptionGroup (Python 3.11+)
try:
    async with asyncio.TaskGroup() as tg:
        tg.create_task(fetch_a())
        tg.create_task(fetch_b())
except* ValueError as eg:
    for exc in eg.exceptions:
        logger.error("ValueError in task", exc_info=exc)
except* OSError as eg:
    for exc in eg.exceptions:
        logger.error("OSError in task", exc_info=exc)
```

```python
# contextlib.suppress for expected, ignorable errors
from contextlib import suppress

with suppress(FileNotFoundError):
    os.remove(temp_file)
```

### Go

```go
// Sentinel errors
var ErrNotFound = errors.New("not found")
var ErrPermission = errors.New("permission denied")

// Wrap with context
if err != nil {
    return fmt.Errorf("load config %s: %w", path, err)
}

// Check with errors.Is / errors.As
if errors.Is(err, ErrNotFound) {
    return http.StatusNotFound
}

var appErr *AppError
if errors.As(err, &appErr) {
    log.Printf("app error code: %s", appErr.Code)
}
```

### Java

```java
// Unchecked domain exceptions
public class OrderException extends RuntimeException {
    private final String code;
    public OrderException(String message, String code, Throwable cause) {
        super(message, cause);
        this.code = code;
    }
}

// Optional for absence (not for errors)
public Optional<User> findUser(String id) {
    return Optional.ofNullable(userRepo.get(id));
}

// CompletableFuture error handling
CompletableFuture.supplyAsync(() -> fetchOrder(id))
    .thenApply(this::validate)
    .exceptionally(ex -> { logger.error("Failed", ex); return fallbackOrder(); });
```

## Anti-Patterns

### Swallowing Errors

```typescript
// WRONG
try { riskyOperation(); } catch (e) { /* ignore */ }
// RIGHT
try { riskyOperation(); } catch (e) { logger.error("Failed", { error: e }); throw e; }
```

### String Errors

```typescript
// WRONG — no stack trace, no type safety
throw "Something went wrong";
// RIGHT
throw new AppError("Something went wrong", "UNKNOWN_ERROR");
```

### Pokemon Catching

```python
# WRONG — catches everything including KeyboardInterrupt
try:
    process()
except Exception:
    pass

# RIGHT — catch specific, let fatal errors propagate
try:
    process()
except (ValueError, ConnectionError) as e:
    logger.error("Processing failed", exc_info=e)
    raise
```

### Error as Control Flow

Do not use exceptions for expected branching. Check conditions first or use Result types.

### Leaking Internal Details

- Never return stack traces, SQL queries, or file paths in API responses.
- Map internal errors to safe messages at the API boundary.
- Log full details server-side with a trace ID. Return only the trace ID to the client.
