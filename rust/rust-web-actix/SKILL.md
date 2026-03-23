---
name: rust-web-actix
description:
  positive: "Use when user builds Rust web services, asks about Actix Web, Axum, Tower middleware, request handlers, extractors, state management, or Rust async HTTP servers."
  negative: "Do NOT use for Rust error handling patterns (use rust-error-handling skill), Go web APIs (use go-api-patterns skill), or Rocket framework."
---

# Rust Web Development with Actix Web and Axum

## Framework Comparison

| Aspect | Actix Web | Axum |
|--------|-----------|------|
| Architecture | Actor model atop Tokio | Tokio + Tower + Hyper directly |
| Throughput | ~152k req/s (JSON) | ~148k req/s (JSON, within 5%) |
| Middleware | Custom `.wrap()` system | Tower `Layer`/`Service` ecosystem |
| Routing | Macro + resource-based | Function composition, no macros |
| Built-ins | WebSocket, static files, auth | Minimal — use tower-http crates |

- Pick **Actix Web** for maximum throughput, actor patterns, or all-in-one features.
- Pick **Axum** for Tokio alignment, Tower middleware reuse, and simpler onboarding.

## Axum Patterns

### Router, Handlers, Nesting

```rust
use axum::{Router, routing::{get, post}, Json, extract::State};
use std::sync::Arc;

struct AppState { db: sqlx::PgPool }

async fn list_users(State(state): State<Arc<AppState>>) -> Json<Vec<User>> {
    let users = sqlx::query_as!(User, "SELECT * FROM users")
        .fetch_all(&state.db).await.unwrap();
    Json(users)
}

let app = Router::new()
    .route("/users", get(list_users).post(create_user))
    .route("/users/{id}", get(get_user).put(update_user).delete(delete_user))
    .nest("/api/v1", v1_routes())
    .fallback(handler_404)
    .with_state(Arc::new(AppState { db: pool }));
```

### Extractors

```rust
use axum::extract::{Path, Query, Json};
async fn get_user(Path(id): Path<i64>) -> impl IntoResponse { /* ... */ }
async fn search(Query(params): Query<SearchParams>) -> impl IntoResponse { /* ... */ }
async fn create(Json(body): Json<CreateUser>) -> impl IntoResponse { /* ... */ }
```

## Actix Web Patterns

### App, Scopes, Handlers

```rust
use actix_web::{web, App, HttpServer, HttpResponse};

struct AppState { db: sqlx::PgPool }

async fn list_users(data: web::Data<AppState>) -> HttpResponse {
    let users = sqlx::query_as!(User, "SELECT * FROM users")
        .fetch_all(&data.db).await.unwrap();
    HttpResponse::Ok().json(users)
}

HttpServer::new(move || {
    App::new()
        .app_data(web::Data::new(AppState { db: pool.clone() }))
        .service(web::scope("/api")
            .route("/users", web::get().to(list_users))
            .route("/users/{id}", web::get().to(get_user)))
})
.bind("0.0.0.0:8080")?.run().await
```

### Extractors

```rust
async fn get_user(path: web::Path<i64>, data: web::Data<AppState>) -> HttpResponse { /* ... */ }
async fn search(query: web::Query<SearchParams>) -> HttpResponse { /* ... */ }
async fn create(body: web::Json<CreateUser>) -> HttpResponse { /* ... */ }
```

## Routing

### Path and Query Parameters

```rust
// Axum — tuple destructuring for multiple path segments
async fn get_item(Path((cat, id)): Path<(String, i64)>) -> impl IntoResponse { /* ... */ }

// Actix — same pattern via web::Path
async fn get_item(path: web::Path<(String, i64)>) -> HttpResponse { /* ... */ }

// Query params — both frameworks use Query<T> with Deserialize struct
#[derive(Deserialize)]
struct Pagination { page: Option<u32>, per_page: Option<u32> }
```

### Route Groups

```rust
// Axum — method router composition
let app = Router::new().route("/users", get(list_users).post(create_user));

// Actix — scope with guards
web::scope("/admin")
    .guard(guard::Header("x-admin", "true"))
    .route("/stats", web::get().to(admin_stats))
```

## Request Extraction

### JSON with Validation

```rust
#[derive(Deserialize, Validate)]
struct CreateUser {
    #[validate(email)]
    email: String,
    #[validate(length(min = 8))]
    password: String,
}
// Axum: Json<CreateUser> — Actix: web::Json<CreateUser>
```

### Multipart Upload (Axum)

```rust
use axum::extract::Multipart;
async fn upload(mut multipart: Multipart) -> impl IntoResponse {
    while let Some(field) = multipart.next_field().await.unwrap() {
        let data = field.bytes().await.unwrap();
    }
    StatusCode::OK
}
```

### Custom Extractor (Axum)

```rust
use axum::extract::FromRequestParts;
struct AuthUser { user_id: i64 }

#[async_trait]
impl<S: Send + Sync> FromRequestParts<S> for AuthUser {
    type Rejection = StatusCode;
    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let token = parts.headers.get("authorization")
            .and_then(|v| v.to_str().ok())
            .ok_or(StatusCode::UNAUTHORIZED)?;
        Ok(AuthUser { user_id: decode_jwt(token).map_err(|_| StatusCode::UNAUTHORIZED)? })
    }
}
```

## Response Types

```rust
// Axum — multiple return types implement IntoResponse
async fn json_resp() -> Json<serde_json::Value> { Json(serde_json::json!({"ok": true})) }
async fn html_resp() -> Html<&'static str> { Html("<h1>Hello</h1>") }
async fn tuple_resp() -> (StatusCode, Json<Msg>) { (StatusCode::CREATED, Json(msg)) }

// Custom IntoResponse wrapper
struct ApiResponse<T: Serialize> { data: T, status: StatusCode }
impl<T: Serialize> IntoResponse for ApiResponse<T> {
    fn into_response(self) -> Response {
        (self.status, Json(self.data)).into_response()
    }
}
```

## Middleware

### Tower Layers (Axum)

```rust
use tower::ServiceBuilder;
use tower_http::{trace::TraceLayer, cors::CorsLayer, compression::CompressionLayer,
    timeout::TimeoutLayer, limit::RequestBodyLimitLayer};

let app = Router::new()
    .route("/api/data", get(handler))
    .layer(ServiceBuilder::new()
        .layer(TraceLayer::new_for_http())
        .layer(TimeoutLayer::new(Duration::from_secs(30)))
        .layer(CompressionLayer::new())
        .layer(CorsLayer::permissive())
        .layer(RequestBodyLimitLayer::new(10 * 1024 * 1024)));
```

### Per-Route Middleware (Axum)

```rust
let public = Router::new().route("/health", get(health));
let protected = Router::new()
    .route("/admin", get(admin_panel))
    .layer(axum::middleware::from_fn(require_auth));
let app = Router::new().merge(public).merge(protected);
```

### Actix Middleware

```rust
use actix_web::middleware::{Logger, Compress, NormalizePath};
use actix_cors::Cors;
App::new()
    .wrap(Logger::default())
    .wrap(Compress::default())
    .wrap(NormalizePath::trim())
    .wrap(Cors::default().allow_any_origin().allow_any_method().allow_any_header())
```

### Rate Limiting

```rust
use tower::limit::RateLimitLayer;
let rate_limit = RateLimitLayer::new(100, Duration::from_secs(60));
// For IP-based limiting, use tower-governor or a custom Tower layer.
```

## State Management

```rust
// Axum — wrap in Arc, pass via with_state
use std::sync::Arc;
use tokio::sync::RwLock;

struct AppState { db: sqlx::PgPool, cache: RwLock<HashMap<String, String>> }
let app = Router::new().with_state(Arc::new(AppState { db: pool, cache: Default::default() }));

// Actix — web::Data wraps in Arc internally
App::new().app_data(web::Data::new(AppState { db: pool }))

// Use Extension for middleware-injected per-request values (Axum)
async fn handler(Extension(user): Extension<CurrentUser>) -> impl IntoResponse { /* ... */ }
```

## Database Integration

### SQLx Connection Pool

```rust
use sqlx::postgres::PgPoolOptions;
let pool = PgPoolOptions::new()
    .max_connections(20).min_connections(5)
    .acquire_timeout(Duration::from_secs(5))
    .connect(&database_url).await?;
```

### Compile-Time Queries and Transactions

```rust
// Compile-time checked (requires DATABASE_URL at build time)
let user = sqlx::query_as!(User, "SELECT id, email FROM users WHERE id = $1", id)
    .fetch_optional(&pool).await?;

// Transactions
let mut tx = pool.begin().await?;
sqlx::query!("INSERT INTO users (email) VALUES ($1)", email).execute(&mut *tx).await?;
sqlx::query!("INSERT INTO profiles (user_id) VALUES ($1)", uid).execute(&mut *tx).await?;
tx.commit().await?;
```

### Migrations

```bash
cargo install sqlx-cli --no-default-features --features postgres
sqlx migrate add create_users && sqlx migrate run
```

### SeaORM Alternative

```rust
use sea_orm::{entity::*, query::*, DatabaseConnection};
let users: Vec<user::Model> = User::find()
    .filter(user::Column::Active.eq(true))
    .order_by_asc(user::Column::Name)
    .all(&db).await?;
```

## Authentication

### JWT Middleware (Axum)

```rust
use jsonwebtoken::{decode, DecodingKey, Validation, Algorithm};

#[derive(Serialize, Deserialize)]
struct Claims { sub: String, exp: usize, role: String }

async fn auth_middleware(
    mut req: axum::extract::Request, next: axum::middleware::Next,
) -> Result<Response, StatusCode> {
    let token = req.headers().get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(StatusCode::UNAUTHORIZED)?;
    let claims = decode::<Claims>(token, &DecodingKey::from_secret(b"secret"),
        &Validation::new(Algorithm::HS256)).map_err(|_| StatusCode::UNAUTHORIZED)?;
    req.extensions_mut().insert(claims.claims);
    Ok(next.run(req).await)
}
```

### Password Hashing

```rust
use argon2::{Argon2, PasswordHasher, PasswordVerifier, password_hash::SaltString};
use rand_core::OsRng;

fn hash_password(pw: &str) -> String {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default().hash_password(pw.as_bytes(), &salt).unwrap().to_string()
}
fn verify_password(pw: &str, hash: &str) -> bool {
    let parsed = argon2::PasswordHash::new(hash).unwrap();
    Argon2::default().verify_password(pw.as_bytes(), &parsed).is_ok()
}
```

## Error Handling

### Axum — IntoResponse for Errors

```rust
use thiserror::Error;
#[derive(Error, Debug)]
enum AppError {
    #[error("not found")] NotFound,
    #[error("unauthorized")] Unauthorized,
    #[error("internal: {0}")] Internal(#[from] anyhow::Error),
    #[error("db: {0}")] Database(#[from] sqlx::Error),
}
impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, self.to_string()),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, self.to_string()),
            _ => (StatusCode::INTERNAL_SERVER_ERROR, "internal error".into()),
        };
        (status, Json(serde_json::json!({"error": msg}))).into_response()
    }
}
// Handlers return Result<Json<T>, AppError>
```

### Actix — ResponseError

```rust
impl actix_web::ResponseError for AppError {
    fn error_response(&self) -> HttpResponse {
        match self {
            AppError::NotFound => HttpResponse::NotFound().json(json!({"error": "not found"})),
            _ => HttpResponse::InternalServerError().json(json!({"error": "internal error"})),
        }
    }
}
```

## Testing

### Axum — Tower oneshot

```rust
use axum::body::Body;
use tower::ServiceExt;
#[tokio::test]
async fn test_list_users() {
    let app = create_app(test_pool().await);
    let resp = app.oneshot(Request::builder().uri("/api/users")
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}
```

### Actix — TestRequest

```rust
#[actix_web::test]
async fn test_get_users() {
    let app = test::init_service(App::new()
        .app_data(web::Data::new(test_state().await))
        .route("/users", web::get().to(list_users))).await;
    let resp = test::call_service(&app, test::TestRequest::get().uri("/users").to_request()).await;
    assert!(resp.status().is_success());
}
```

### Repository Mocking

```rust
#[async_trait]
trait UserRepo: Send + Sync {
    async fn find_by_id(&self, id: i64) -> Result<Option<User>, sqlx::Error>;
}
struct MockUserRepo;
#[async_trait]
impl UserRepo for MockUserRepo {
    async fn find_by_id(&self, _id: i64) -> Result<Option<User>, sqlx::Error> {
        Ok(Some(User { id: 1, email: "test@example.com".into() }))
    }
}
```

## Deployment

### Multi-Stage Dockerfile

```dockerfile
FROM rust:1.83-slim AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main(){}" > src/main.rs && cargo build --release && rm -rf src
COPY src ./src
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/myapp /usr/local/bin/
EXPOSE 8080
CMD ["myapp"]
```

### Graceful Shutdown

```rust
// Axum
axum::serve(listener, app).with_graceful_shutdown(async {
    tokio::signal::ctrl_c().await.ok();
}).await?;

// Actix
HttpServer::new(|| App::new()).shutdown_timeout(30).bind("0.0.0.0:8080")?.run().await?;
```

### Static Linking

```bash
rustup target add x86_64-unknown-linux-musl
cargo build --release --target x86_64-unknown-linux-musl
```

## Performance

```rust
#[tokio::main(flavor = "multi_thread", worker_threads = 8)]
async fn main() { /* ... */ }
```

### Connection and Concurrency Limits

```rust
// Axum — Tower concurrency layer
app.layer(tower::limit::ConcurrencyLimitLayer::new(1000));

// Actix
HttpServer::new(|| App::new()).workers(num_cpus::get()).backlog(2048).max_connections(25_000);
```

### Async Rules
- Use `tokio::spawn` for background tasks; `spawn_blocking` for CPU-heavy or sync work.
- Prefer `tokio::select!` for racing futures.
- Never hold `MutexGuard` across `.await` — use `tokio::sync::Mutex` if needed.

## Anti-Patterns

### Blocking in Async

```rust
// BAD — blocks Tokio worker
async fn bad() { std::thread::sleep(Duration::from_secs(5)); }

// GOOD
async fn good() {
    tokio::task::spawn_blocking(|| std::thread::sleep(Duration::from_secs(5))).await.unwrap();
}
```

```rust
// BAD: let config = config.clone(); // copies entire struct per request
// GOOD: let config = Arc::new(config); // clone Arc = cheap pointer copy
```

```rust
// BAD: tokio::sync::mpsc::unbounded_channel() — OOM risk under load
// GOOD: tokio::sync::mpsc::channel(1000) — bounded with backpressure
```

### Other Pitfalls
- Always set `max_connections` on DB pools based on actual DB capacity.
- Always apply `RequestBodyLimitLayer` (Axum) or `PayloadConfig` (Actix).
- Never log secrets or full request bodies in production.
