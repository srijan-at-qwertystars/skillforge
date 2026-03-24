# Axum Deep Dive

## Table of Contents
- [Routing](#routing)
- [Extractors](#extractors)
- [Middleware](#middleware)
- [Error Handling](#error-handling)
- [WebSocket Support](#websocket-support)
- [Server-Sent Events (SSE)](#server-sent-events-sse)
- [Multipart Uploads](#multipart-uploads)
- [Shared State Patterns](#shared-state-patterns)
- [Testing](#testing)
- [Deployment with tower-http](#deployment-with-tower-http)

---

## Routing

### Basic Router Setup
```rust
use axum::{
    Router,
    routing::{get, post, put, delete, any},
};

let app = Router::new()
    .route("/", get(root_handler))
    .route("/users", get(list_users).post(create_user))
    .route("/users/{id}", get(get_user).put(update_user).delete(delete_user))
    .route("/health", get(|| async { "ok" }));
```

### Path Parameters
```rust
// Single parameter
async fn get_user(Path(id): Path<u64>) -> impl IntoResponse {
    format!("User {id}")
}

// Multiple parameters
async fn get_post(Path((user_id, post_id)): Path<(u64, u64)>) -> impl IntoResponse {
    format!("User {user_id}, Post {post_id}")
}

// With deserialization
#[derive(Deserialize)]
struct PostPath { user_id: u64, slug: String }

async fn get_post_by_slug(Path(path): Path<PostPath>) -> impl IntoResponse {
    format!("User {}, Post {}", path.user_id, path.slug)
}
```

### Nested Routers
```rust
// Modular routing — each module owns its routes
fn api_routes() -> Router<AppState> {
    Router::new()
        .nest("/users", user_routes())
        .nest("/posts", post_routes())
        .nest("/admin", admin_routes())
}

fn user_routes() -> Router<AppState> {
    Router::new()
        .route("/", get(list_users).post(create_user))
        .route("/{id}", get(get_user).put(update_user))
        .route("/{id}/posts", get(user_posts))
}

// Main app
let app = Router::new()
    .nest("/api/v1", api_routes())
    .with_state(state);
// Results in: /api/v1/users, /api/v1/users/:id, etc.
```

### Fallback and Method Routing
```rust
let app = Router::new()
    .route("/api/{*path}", any(api_fallback))     // Catch-all for /api/*
    .fallback(not_found_handler);                  // Global fallback

async fn not_found_handler(uri: axum::http::Uri) -> impl IntoResponse {
    (StatusCode::NOT_FOUND, format!("No route for {uri}"))
}

// Method-specific routing with method_router
use axum::routing::MethodRouter;

fn item_routes() -> MethodRouter<AppState> {
    get(list_items)
        .post(create_item)
        .put(replace_items)
}
```

### Router Merging
```rust
let public = Router::new()
    .route("/login", post(login))
    .route("/register", post(register));

let authenticated = Router::new()
    .route("/profile", get(profile))
    .route("/settings", get(settings).put(update_settings))
    .layer(middleware::from_fn(auth_middleware));

let app = public.merge(authenticated).with_state(state);
```

---

## Extractors

Extractors pull data from requests. They implement `FromRequest` or `FromRequestParts`.

### Built-in Extractors
```rust
use axum::extract::{Path, Query, Json, State, Extension, Host, ConnectInfo};
use axum::http::{HeaderMap, Method, Uri};

// Path — URL path parameters
async fn get_user(Path(id): Path<u64>) -> impl IntoResponse { }

// Query — URL query string
#[derive(Deserialize)]
struct Pagination { page: Option<u32>, limit: Option<u32> }
async fn list(Query(params): Query<Pagination>) -> impl IntoResponse { }

// Json — Request body
#[derive(Deserialize)]
struct CreateUser { name: String, email: String }
async fn create(Json(body): Json<CreateUser>) -> impl IntoResponse { }

// State — Shared application state
async fn handler(State(state): State<AppState>) -> impl IntoResponse { }

// Headers
async fn handler(headers: HeaderMap) -> impl IntoResponse {
    let auth = headers.get("authorization");
}

// Multiple extractors (order matters — body extractors must be last)
async fn create_user(
    State(state): State<AppState>,       // FromRequestParts
    Path(org_id): Path<u64>,              // FromRequestParts
    Query(params): Query<Pagination>,     // FromRequestParts
    headers: HeaderMap,                   // FromRequestParts
    Json(body): Json<CreateUser>,         // FromRequest (consumes body — MUST be last)
) -> impl IntoResponse { }
```

### Custom Extractor
```rust
use axum::extract::FromRequestParts;
use axum::http::request::Parts;

struct AuthUser {
    user_id: u64,
    role: String,
}

#[async_trait]
impl<S: Send + Sync> FromRequestParts<S> for AuthUser {
    type Rejection = (StatusCode, String);

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let auth_header = parts.headers
            .get("Authorization")
            .and_then(|v| v.to_str().ok())
            .ok_or((StatusCode::UNAUTHORIZED, "Missing auth header".into()))?;

        let token = auth_header.strip_prefix("Bearer ")
            .ok_or((StatusCode::UNAUTHORIZED, "Invalid auth format".into()))?;

        let claims = verify_jwt(token)
            .map_err(|e| (StatusCode::UNAUTHORIZED, format!("Invalid token: {e}")))?;

        Ok(AuthUser {
            user_id: claims.sub,
            role: claims.role,
        })
    }
}

// Use in handlers — extraction happens automatically
async fn protected(user: AuthUser) -> impl IntoResponse {
    format!("Hello user {}, role: {}", user.user_id, user.role)
}
```

### Optional and Result Extractors
```rust
// Optional — doesn't fail if missing
async fn handler(auth: Option<AuthUser>) -> impl IntoResponse {
    match auth {
        Some(user) => format!("Logged in as {}", user.user_id),
        None => "Anonymous".to_string(),
    }
}

// Result — get the rejection error for custom handling
async fn handler(user: Result<AuthUser, AuthRejection>) -> impl IntoResponse {
    match user {
        Ok(u) => (StatusCode::OK, format!("Hello {}", u.user_id)),
        Err(e) => (StatusCode::UNAUTHORIZED, format!("Auth failed: {e}")),
    }
}
```

---

## Middleware

### Function Middleware (from_fn)
```rust
use axum::middleware::{self, Next};
use axum::extract::Request;

async fn logging_middleware(request: Request, next: Next) -> impl IntoResponse {
    let method = request.method().clone();
    let uri = request.uri().clone();
    let start = std::time::Instant::now();

    let response = next.run(request).await;

    tracing::info!(
        method = %method,
        uri = %uri,
        status = %response.status(),
        elapsed_ms = %start.elapsed().as_millis(),
    );
    response
}

// Apply to specific routes
let app = Router::new()
    .route("/api/data", get(handler))
    .layer(middleware::from_fn(logging_middleware));
```

### Middleware with State
```rust
async fn auth_middleware(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Result<impl IntoResponse, StatusCode> {
    let auth_header = request.headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or(StatusCode::UNAUTHORIZED)?;

    let token = auth_header.strip_prefix("Bearer ")
        .ok_or(StatusCode::UNAUTHORIZED)?;

    state.jwt_validator.verify(token)
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    Ok(next.run(request).await)
}

let app = Router::new()
    .route("/protected", get(handler))
    .layer(middleware::from_fn_with_state(state.clone(), auth_middleware))
    .with_state(state);
```

### Tower Layers
```rust
use tower_http::{
    trace::TraceLayer,
    timeout::TimeoutLayer,
    cors::CorsLayer,
    compression::CompressionLayer,
    limit::RequestBodyLimitLayer,
    set_header::SetResponseHeaderLayer,
};

let app = Router::new()
    .route("/api", get(handler))
    .layer(
        tower::ServiceBuilder::new()
            // Outermost (first on request, last on response)
            .layer(TraceLayer::new_for_http())
            .layer(TimeoutLayer::new(Duration::from_secs(30)))
            .layer(CorsLayer::permissive())
            .layer(CompressionLayer::new())
            .layer(RequestBodyLimitLayer::new(10 * 1024 * 1024)) // 10 MB
            // Innermost (last on request, first on response)
    );
```

### Middleware Ordering
```
Request flow:  Client → Layer1 → Layer2 → Layer3 → Handler
Response flow: Client ← Layer1 ← Layer2 ← Layer3 ← Handler

// .layer() wraps OUTSIDE, so last .layer() call = outermost = runs first
Router::new()
    .layer(A)  // Runs 2nd on request, 2nd on response
    .layer(B)  // Runs 1st on request, 3rd on response (outermost)
```

### Selective Middleware
```rust
// Apply middleware to specific route groups
let public = Router::new()
    .route("/login", post(login))
    .route("/health", get(health));

let protected = Router::new()
    .route("/users", get(list_users))
    .route("/admin", get(admin_panel))
    .layer(middleware::from_fn(require_auth));

let rate_limited = Router::new()
    .route("/api/search", get(search))
    .layer(GovernorLayer::new(rate_limit_config));

let app = Router::new()
    .merge(public)
    .merge(protected)
    .merge(rate_limited)
    .layer(TraceLayer::new_for_http()) // Applied to ALL routes
    .with_state(state);
```

---

## Error Handling

### IntoResponse for Custom Error Types
```rust
use axum::response::{IntoResponse, Response};
use axum::http::StatusCode;

#[derive(Debug)]
enum AppError {
    NotFound(String),
    BadRequest(String),
    Internal(anyhow::Error),
    Unauthorized,
    Db(sqlx::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            Self::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "Unauthorized".to_string()),
            Self::Db(e) => {
                tracing::error!("Database error: {e:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal error".to_string())
            }
            Self::Internal(e) => {
                tracing::error!("Internal error: {e:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal error".to_string())
            }
        };

        let body = serde_json::json!({ "error": message });
        (status, Json(body)).into_response()
    }
}

// Implement From for automatic ? conversion
impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => Self::NotFound("Resource not found".into()),
            other => Self::Db(other),
        }
    }
}

impl From<anyhow::Error> for AppError {
    fn from(e: anyhow::Error) -> Self { Self::Internal(e) }
}

// Handlers return Result<impl IntoResponse, AppError>
async fn get_user(
    State(state): State<AppState>,
    Path(id): Path<u64>,
) -> Result<Json<User>, AppError> {
    let user = sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id as i64)
        .fetch_one(&state.pool)
        .await?; // Auto-converts sqlx::Error → AppError
    Ok(Json(user))
}
```

### Validation Errors
```rust
use validator::Validate;

#[derive(Deserialize, Validate)]
struct CreateUser {
    #[validate(length(min = 1, max = 100))]
    name: String,
    #[validate(email)]
    email: String,
    #[validate(range(min = 0, max = 150))]
    age: u8,
}

// Validated extractor
async fn create_user(Json(body): Json<CreateUser>) -> Result<Json<User>, AppError> {
    body.validate().map_err(|e| AppError::BadRequest(e.to_string()))?;
    // ... create user
}
```

---

## WebSocket Support

```rust
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use futures::{SinkExt, StreamExt};

async fn ws_handler(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(|socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = socket.split();

    // Spawn sender task
    let mut send_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        loop {
            interval.tick().await;
            if sender.send(Message::Ping(vec![])).await.is_err() {
                break; // Client disconnected
            }
        }
    });

    // Receive messages
    let mut recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = receiver.next().await {
            match msg {
                Message::Text(text) => {
                    tracing::info!("Received: {text}");
                    // Process message
                }
                Message::Binary(data) => { /* handle binary */ }
                Message::Close(_) => break,
                _ => {}
            }
        }
    });

    // Wait for either task to complete
    tokio::select! {
        _ = &mut send_task => recv_task.abort(),
        _ = &mut recv_task => send_task.abort(),
    }
}

// Route
let app = Router::new().route("/ws", get(ws_handler));
```

### Chat Room with Broadcast
```rust
use tokio::sync::broadcast;

#[derive(Clone)]
struct ChatState {
    tx: broadcast::Sender<String>,
}

async fn ws_chat(
    ws: WebSocketUpgrade,
    State(state): State<ChatState>,
) -> impl IntoResponse {
    ws.on_upgrade(|socket| async move {
        let (mut sender, mut receiver) = socket.split();
        let mut rx = state.tx.subscribe();

        // Forward broadcast messages to this client
        let mut send_task = tokio::spawn(async move {
            while let Ok(msg) = rx.recv().await {
                if sender.send(Message::Text(msg)).await.is_err() { break; }
            }
        });

        // Forward this client's messages to broadcast
        let tx = state.tx.clone();
        let mut recv_task = tokio::spawn(async move {
            while let Some(Ok(Message::Text(text))) = receiver.next().await {
                let _ = tx.send(text);
            }
        });

        tokio::select! {
            _ = &mut send_task => recv_task.abort(),
            _ = &mut recv_task => send_task.abort(),
        }
    })
}
```

---

## Server-Sent Events (SSE)

```rust
use axum::response::sse::{Event, KeepAlive, Sse};
use tokio_stream::StreamExt as _;
use std::convert::Infallible;

async fn sse_handler(
    State(state): State<AppState>,
) -> Sse<impl futures::Stream<Item = Result<Event, Infallible>>> {
    let stream = async_stream::stream! {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        let mut count = 0u64;
        loop {
            interval.tick().await;
            count += 1;
            let data = serde_json::json!({ "count": count, "time": chrono::Utc::now() });
            yield Ok(Event::default()
                .event("update")
                .data(data.to_string())
                .id(count.to_string()));
        }
    };

    Sse::new(stream).keep_alive(KeepAlive::default())
}

// Route
let app = Router::new().route("/events", get(sse_handler));
```

---

## Multipart Uploads

```rust
use axum::extract::Multipart;

async fn upload(mut multipart: Multipart) -> Result<Json<Vec<String>>, AppError> {
    let mut filenames = Vec::new();

    while let Some(field) = multipart.next_field().await
        .map_err(|e| AppError::BadRequest(e.to_string()))?
    {
        let name = field.name().unwrap_or("unknown").to_string();
        let file_name = field.file_name()
            .unwrap_or("unnamed")
            .to_string();
        let content_type = field.content_type()
            .unwrap_or("application/octet-stream")
            .to_string();

        // Validate file type
        if !["image/png", "image/jpeg"].contains(&content_type.as_str()) {
            return Err(AppError::BadRequest(format!("Invalid file type: {content_type}")));
        }

        let data = field.bytes().await
            .map_err(|e| AppError::BadRequest(e.to_string()))?;

        // Validate size (10 MB max)
        if data.len() > 10 * 1024 * 1024 {
            return Err(AppError::BadRequest("File too large".into()));
        }

        let path = format!("uploads/{file_name}");
        tokio::fs::write(&path, &data).await
            .map_err(|e| AppError::Internal(e.into()))?;

        tracing::info!(field = %name, file = %file_name, size = data.len(), "uploaded");
        filenames.push(file_name);
    }

    Ok(Json(filenames))
}

let app = Router::new()
    .route("/upload", post(upload))
    .layer(RequestBodyLimitLayer::new(50 * 1024 * 1024)); // 50 MB total limit
```

---

## Shared State Patterns

### Pattern 1: Clone-able State with Arc internals
```rust
// Recommended: State struct is Clone, wraps Arc internally
#[derive(Clone)]
struct AppState {
    pool: sqlx::PgPool,              // PgPool is already Arc internally
    cache: Arc<DashMap<String, String>>,
    config: Arc<Config>,
    http_client: reqwest::Client,    // Client is already Arc internally
}

let state = AppState {
    pool: PgPool::connect(&db_url).await?,
    cache: Arc::new(DashMap::new()),
    config: Arc::new(Config::from_env()?),
    http_client: reqwest::Client::new(),
};

let app = Router::new()
    .route("/", get(handler))
    .with_state(state);
```

### Pattern 2: Inner Arc Pattern
```rust
// For complex state or when you want a single Arc
struct AppStateInner {
    pool: sqlx::PgPool,
    config: Config,
    // ... many fields
}

#[derive(Clone)]
struct AppState(Arc<AppStateInner>);

impl AppState {
    fn new(pool: sqlx::PgPool, config: Config) -> Self {
        Self(Arc::new(AppStateInner { pool, config }))
    }

    fn pool(&self) -> &sqlx::PgPool { &self.0.pool }
    fn config(&self) -> &Config { &self.0.config }
}
```

### Pattern 3: Sub-States
```rust
// Extract only what handlers need
#[derive(Clone)]
struct AppState {
    db: DbState,
    auth: AuthState,
}

#[derive(Clone)]
struct DbState { pool: sqlx::PgPool }

#[derive(Clone)]
struct AuthState { jwt_secret: Arc<String> }

// Implement FromRef for sub-state extraction
impl FromRef<AppState> for DbState {
    fn from_ref(state: &AppState) -> Self { state.db.clone() }
}

impl FromRef<AppState> for AuthState {
    fn from_ref(state: &AppState) -> Self { state.auth.clone() }
}

// Handlers extract just what they need
async fn get_user(State(db): State<DbState>) -> impl IntoResponse { }
async fn login(State(auth): State<AuthState>) -> impl IntoResponse { }
```

---

## Testing

### Handler Unit Tests
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;
    use axum::body::Body;
    use tower::ServiceExt; // for oneshot

    fn test_app() -> Router {
        let state = AppState::new_test(); // Test-specific state
        Router::new()
            .route("/users", get(list_users).post(create_user))
            .route("/users/{id}", get(get_user))
            .with_state(state)
    }

    #[tokio::test]
    async fn test_list_users() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/users")
                    .body(Body::empty())
                    .unwrap()
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        let body = axum::body::to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let users: Vec<User> = serde_json::from_slice(&body).unwrap();
        assert!(!users.is_empty());
    }

    #[tokio::test]
    async fn test_create_user() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/users")
                    .header("Content-Type", "application/json")
                    .body(Body::from(r#"{"name":"Alice","email":"alice@test.com"}"#))
                    .unwrap()
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::CREATED);
    }

    #[tokio::test]
    async fn test_not_found() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/users/99999")
                    .body(Body::empty())
                    .unwrap()
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }
}
```

### Integration Tests with Real Database
```rust
#[cfg(test)]
mod integration {
    use sqlx::PgPool;

    // Use sqlx::test for automatic test database management
    #[sqlx::test]
    async fn test_user_crud(pool: PgPool) {
        let state = AppState { pool };
        let app = create_app(state);

        // Create
        let resp = app.clone().oneshot(/* create request */).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);

        // Read
        let resp = app.clone().oneshot(/* get request */).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }
}
```

---

## Deployment with tower-http

### Production Middleware Stack
```rust
use tower_http::{
    trace::{TraceLayer, DefaultOnResponse, DefaultMakeSpan},
    cors::{CorsLayer, Any},
    compression::CompressionLayer,
    timeout::TimeoutLayer,
    limit::RequestBodyLimitLayer,
    set_header::SetResponseHeaderLayer,
    catch_panic::CatchPanicLayer,
    request_id::{MakeRequestId, RequestId, SetRequestIdLayer, PropagateRequestIdLayer},
    normalize_path::NormalizePathLayer,
};
use http::header::{HeaderName, HeaderValue};

#[derive(Clone)]
struct RequestIdGenerator;
impl MakeRequestId for RequestIdGenerator {
    fn make_request_id<B>(&mut self, _: &http::Request<B>) -> Option<RequestId> {
        Some(RequestId::new(
            HeaderValue::from_str(&uuid::Uuid::new_v4().to_string()).unwrap()
        ))
    }
}

let app = NormalizePathLayer::trim_trailing_slash()
    .layer(
        Router::new()
            .nest("/api", api_routes())
            .layer(
                tower::ServiceBuilder::new()
                    .layer(SetRequestIdLayer::x_request_id(RequestIdGenerator))
                    .layer(PropagateRequestIdLayer::x_request_id())
                    .layer(
                        TraceLayer::new_for_http()
                            .make_span_with(DefaultMakeSpan::new().level(tracing::Level::INFO))
                            .on_response(DefaultOnResponse::new().level(tracing::Level::INFO))
                    )
                    .layer(TimeoutLayer::new(Duration::from_secs(30)))
                    .layer(CatchPanicLayer::new())
                    .layer(CompressionLayer::new())
                    .layer(RequestBodyLimitLayer::new(10 * 1024 * 1024))
                    .layer(
                        CorsLayer::new()
                            .allow_origin(Any)
                            .allow_methods([Method::GET, Method::POST, Method::PUT, Method::DELETE])
                            .allow_headers(Any)
                            .max_age(Duration::from_secs(3600))
                    )
            )
            .with_state(state)
    );
```

### Graceful Shutdown
```rust
#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let state = AppState::new().await;
    let app = create_app(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    tracing::info!("listening on {}", listener.local_addr().unwrap());

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();
}

async fn shutdown_signal() {
    let ctrl_c = async { tokio::signal::ctrl_c().await.unwrap() };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .unwrap()
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("received Ctrl+C"),
        _ = terminate => tracing::info!("received SIGTERM"),
    }
}
```

### Serving Static Files
```rust
use tower_http::services::{ServeDir, ServeFile};

let app = Router::new()
    .nest("/api", api_routes())
    .nest_service("/static", ServeDir::new("static"))
    .fallback_service(ServeFile::new("static/index.html")); // SPA fallback
```
