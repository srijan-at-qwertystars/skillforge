---
name: rust-error-handling
description:
  positive: "Use when user implements error handling in Rust, asks about Result/Option, the ? operator, custom error types, thiserror, anyhow, error conversion with From/Into, or error design patterns for Rust libraries vs applications."
  negative: "Do NOT use for general Rust syntax, ownership/borrowing, async Rust, or other languages' error handling."
---

# Rust Error Handling Patterns

## Result<T, E> and Option<T> Fundamentals

Use `Result<T, E>` for operations that can fail recoverably. Use `Option<T>` when absence of a value is valid, not erroneous.

```rust
// Result: operation can fail
fn parse_port(s: &str) -> Result<u16, std::num::ParseIntError> {
    s.parse::<u16>()
}

// Option: value may legitimately not exist
fn find_user(id: u64) -> Option<User> {
    users.get(&id).cloned()
}
```

**When to use which:**
- `Result<T, E>` — file I/O, network calls, parsing, validation, anything that can fail.
- `Option<T>` — lookups, optional config fields, search results that may be empty.
- Convert between them with `.ok()`, `.ok_or()`, `.ok_or_else()`.

```rust
let val: Option<i32> = some_lookup();
let val: Result<i32, MyError> = val.ok_or(MyError::NotFound)?;

let res: Result<i32, SomeError> = try_parse();
let opt: Option<i32> = res.ok(); // discard error info
```

## The ? Operator and Early Returns

The `?` operator propagates errors up the call stack. It calls `From::from()` on the error to convert it to the function's return error type.

```rust
fn read_config(path: &str) -> Result<Config, AppError> {
    let content = std::fs::read_to_string(path)?; // auto-converts io::Error via From
    let config: Config = serde_json::from_str(&content)?; // auto-converts serde error
    Ok(config)
}
```

Chain `?` freely — each one is an early return on `Err`. Works with both `Result` and `Option` (in functions returning `Option`).

```rust
fn first_line(text: &str) -> Option<&str> {
    let line = text.lines().next()?; // returns None if empty
    Some(line.trim())
}
```

## Custom Error Types with Enum Variants

Define an enum with one variant per error category. Implement `Display` and `Error`.

```rust
use std::fmt;

#[derive(Debug)]
pub enum DataError {
    Io(std::io::Error),
    Parse { line: usize, msg: String },
    Validation(String),
    NotFound { resource: String, id: u64 },
}

impl fmt::Display for DataError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O error: {e}"),
            Self::Parse { line, msg } => write!(f, "parse error at line {line}: {msg}"),
            Self::Validation(msg) => write!(f, "validation failed: {msg}"),
            Self::NotFound { resource, id } => write!(f, "{resource} not found: {id}"),
        }
    }
}

impl std::error::Error for DataError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for DataError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
```

## thiserror for Library Errors

`thiserror` eliminates boilerplate for custom error types. Use it in libraries and shared crates.

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ServiceError {
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("authentication failed for user {user_id}")]
    AuthFailed { user_id: String },

    #[error("rate limit exceeded, retry after {retry_after_secs}s")]
    RateLimited { retry_after_secs: u64 },

    #[error("invalid input: {0}")]
    InvalidInput(String),

    #[error(transparent)]
    Unexpected(#[from] anyhow::Error), // pass-through for unexpected errors
}
```

**Key attributes:**
- `#[error("...")]` — generates `Display` impl. Supports `{0}`, `{field_name}`, `{field:?}`.
- `#[from]` — generates `From<SourceError>` impl, enabling `?` auto-conversion.
- `#[source]` — marks a field as the error source without generating `From`.
- `#[error(transparent)]` — delegates `Display` and `source()` to the inner error.

```rust
#[derive(Error, Debug)]
pub enum ParseError {
    #[error("invalid header")]
    InvalidHeader,

    #[error("malformed body at offset {offset}")]
    MalformedBody {
        offset: usize,
        #[source]
        cause: std::io::Error, // source but no From impl
    },
}
```

## anyhow for Application Errors

Use `anyhow` in binaries, CLI tools, and application-level code where you need ergonomic error propagation with context.

```rust
use anyhow::{bail, ensure, Context, Result};

fn process_file(path: &str) -> Result<Output> {
    ensure!(!path.is_empty(), "path must not be empty");

    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read {path}"))?;

    let data: Data = serde_json::from_str(&content)
        .context("failed to parse JSON")?;

    if !data.is_valid() {
        bail!("data validation failed: missing required fields");
    }

    Ok(transform(data))
}

fn main() -> Result<()> {
    let output = process_file("input.json")?;
    println!("{output:?}");
    Ok(())
}
```

**Key features:**
- `context()` / `with_context()` — attach human-readable context to any error.
- `bail!("msg")` — return an error immediately (like `return Err(anyhow!("msg"))`).
- `ensure!(condition, "msg")` — bail if condition is false.
- `anyhow!("msg")` — create an ad-hoc error.

## Library vs Application Error Design

| Concern | Library | Application |
|---------|---------|-------------|
| Error type | Custom enum with `thiserror` | `anyhow::Result<T>` |
| Goal | Callers match on variants | Propagate with context, log at top |
| Specificity | High — each failure mode is a variant | Low — aggregate and report |
| `From` impls | Yes, for all wrapped error sources | Implicit via `anyhow` |
| Dependencies | Minimize (only `thiserror`) | `anyhow` + whatever you need |

**Library rules:**
- Return `Result<T, YourError>` from all public functions.
- Never use `anyhow::Error` in public APIs.
- Make error variants exhaustive so callers can match.
- Keep `#[non_exhaustive]` on error enums to allow adding variants without breaking changes.

```rust
#[derive(Error, Debug)]
#[non_exhaustive]
pub enum ClientError {
    #[error("connection failed: {0}")]
    Connection(#[from] std::io::Error),

    #[error("timeout after {0:?}")]
    Timeout(std::time::Duration),
}
```

**Application rules:**
- Use `anyhow::Result<T>` for internal functions.
- Add `.context()` at every error boundary to build a readable chain.
- Handle specific errors only where recovery is possible.

## Error Conversion Chains (From, Into, map_err)

The `?` operator calls `From::from(err)` to convert the error. Implement `From` for automatic conversion; use `map_err` when you need custom logic.

```rust
// Automatic via From (preferred)
impl From<reqwest::Error> for ApiError {
    fn from(e: reqwest::Error) -> Self {
        if e.is_timeout() {
            Self::Timeout
        } else {
            Self::Network(e.to_string())
        }
    }
}

// map_err for one-off conversions or adding context
fn fetch_data(url: &str) -> Result<Data, AppError> {
    let body = reqwest::blocking::get(url)
        .map_err(|e| AppError::Network {
            url: url.to_string(),
            source: e,
        })?;
    Ok(body.json()?)
}
```

**Conversion hierarchy:**
1. `#[from]` with `thiserror` — zero boilerplate, use when conversion is lossless.
2. Manual `From` impl — when you need conditional logic during conversion.
3. `map_err` — for one-off conversions, adding fields, or adapting third-party types.

## Downcasting Errors

Use `anyhow`'s downcast when you need to recover a specific error type from an erased error.

```rust
use anyhow::Result;

fn handle_error(err: anyhow::Error) {
    // Try to downcast to a specific type
    if let Some(db_err) = err.downcast_ref::<sqlx::Error>() {
        eprintln!("database error: {db_err}");
        return;
    }

    // Walk the error source chain
    for cause in err.chain() {
        eprintln!("caused by: {cause}");
    }
}
```

**Source chain traversal** (works with any `std::error::Error`):

```rust
fn print_error_chain(err: &dyn std::error::Error) {
    eprintln!("error: {err}");
    let mut source = err.source();
    while let Some(cause) = source {
        eprintln!("  caused by: {cause}");
        source = cause.source();
    }
}
```

Prefer pattern matching on typed enums over downcasting. Reserve downcasting for plugin systems, FFI boundaries, or truly dynamic error handling.

## Common Patterns

### Error wrapping — add context while preserving the source

```rust
#[derive(Error, Debug)]
pub enum StorageError {
    #[error("failed to write key '{key}'")]
    Write {
        key: String,
        #[source]
        cause: std::io::Error,
    },
}
```

### Transparent errors — delegate display and source

```rust
#[derive(Error, Debug)]
pub enum WrapperError {
    #[error(transparent)]
    Internal(#[from] InternalError),
}
```

### Multiple error sources in one variant

```rust
#[derive(Error, Debug)]
pub enum MigrationError {
    #[error("migration '{name}' failed")]
    Failed {
        name: String,
        version: u32,
        #[source]
        cause: Box<dyn std::error::Error + Send + Sync>,
    },
}
```

### Fallible constructors

```rust
impl Config {
    pub fn from_file(path: &str) -> Result<Self, ConfigError> {
        let raw = std::fs::read_to_string(path)?;
        let config: Config = toml::from_str(&raw)?;
        config.validate()?;
        Ok(config)
    }
}
```

## Anti-Patterns

### Never `unwrap()` or `expect()` in production paths

```rust
// BAD: panics on error
let file = File::open("config.toml").unwrap();

// GOOD: propagate the error
let file = File::open("config.toml").context("opening config")?;
```

Reserve `unwrap()` for tests and cases with proof of infallibility. Use `expect("reason")` only when you can guarantee the invariant holds (e.g., compile-time constants, regex patterns known valid).

### Avoid stringly-typed errors

```rust
// BAD: no structure, impossible to match
fn validate(input: &str) -> Result<(), String> {
    Err(format!("invalid input: {input}"))
}

// GOOD: typed, matchable
fn validate(input: &str) -> Result<(), ValidationError> {
    Err(ValidationError::InvalidFormat { input: input.to_string() })
}
```

### Do not use `Box<dyn Error>` as a public API return type

```rust
// BAD: callers can't match, inspect, or handle specific errors
pub fn load() -> Result<Data, Box<dyn std::error::Error>> { .. }

// GOOD: explicit error type
pub fn load() -> Result<Data, LoadError> { .. }
```

`Box<dyn Error>` is acceptable in internal application code or trait objects where heterogeneous errors are unavoidable.

### Avoid swallowing errors silently

```rust
// BAD: error is silently ignored
let _ = save_to_disk(&data);

// GOOD: log if you intentionally discard
if let Err(e) = save_to_disk(&data) {
    tracing::warn!("failed to save data: {e:#}");
}
```

## Testing Error Conditions

Use `assert!(result.is_err())` for basic checks. Match on specific variants for precise assertions.

```rust
#[test]
fn test_missing_file_returns_io_error() {
    let result = read_config("/nonexistent/path");
    assert!(result.is_err());
    match result.unwrap_err() {
        ConfigError::Io(_) => {} // expected
        other => panic!("expected Io error, got: {other}"),
    }
}
```

Use `#[should_panic]` only for testing panics, not for `Result` errors.

**Testing with anyhow:**

```rust
#[test]
fn test_with_anyhow_downcast() -> Result<()> {
    let result = process("bad input");
    let err = result.unwrap_err();
    let validation_err = err.downcast_ref::<ValidationError>()
        .expect("expected ValidationError");
    assert_eq!(validation_err.field, "email");
    Ok(())
}
```

**Testing error messages:**

```rust
#[test]
fn test_error_display() {
    let err = ServiceError::RateLimited { retry_after_secs: 30 };
    assert_eq!(err.to_string(), "rate limit exceeded, retry after 30s");
}
```

**Asserting specific error variants with matches!:**

```rust
#[test]
fn test_not_found() {
    let err = lookup(999).unwrap_err();
    assert!(matches!(err, LookupError::NotFound { id: 999 }));
}
```

## Async Error Handling

The `?` operator works in async functions the same as sync. Return `Result` as usual.

```rust
async fn fetch_user(client: &reqwest::Client, id: u64) -> Result<User, ApiError> {
    let resp = client
        .get(format!("https://api.example.com/users/{id}"))
        .send()
        .await?
        .error_for_status()
        .map_err(|e| ApiError::HttpStatus {
            code: e.status().unwrap_or_default(),
            url: e.url().cloned(),
        })?;
    let user: User = resp.json().await?;
    Ok(user)
}
```

**Handling errors in spawned tasks:**

```rust
let handle = tokio::spawn(async move {
    process_job(job).await
});

match handle.await {
    Ok(Ok(result)) => println!("success: {result:?}"),
    Ok(Err(app_err)) => eprintln!("task error: {app_err:#}"),
    Err(join_err) => eprintln!("task panicked: {join_err}"),
}
```

**Timeout as an error:**

```rust
use tokio::time::{timeout, Duration};

async fn fetch_with_timeout(url: &str) -> Result<Response, ApiError> {
    timeout(Duration::from_secs(10), reqwest::get(url))
        .await
        .map_err(|_| ApiError::Timeout)?
        .map_err(ApiError::from)
}
```

<!-- tested: pass -->
