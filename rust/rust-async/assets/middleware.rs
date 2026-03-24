use axum::{
    extract::Request,
    http::{HeaderValue, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use std::sync::Arc;
use std::time::Instant;

// ---------------------------------------------------------------------------
// Request ID Middleware
// ---------------------------------------------------------------------------
/// Adds a unique X-Request-Id header to every request and response.
pub async fn request_id_middleware(mut request: Request, next: Next) -> Response {
    let request_id = uuid::Uuid::new_v4().to_string();

    request.headers_mut().insert(
        "x-request-id",
        HeaderValue::from_str(&request_id).unwrap(),
    );

    let mut response = next.run(request).await;

    response.headers_mut().insert(
        "x-request-id",
        HeaderValue::from_str(&request_id).unwrap(),
    );

    response
}

// ---------------------------------------------------------------------------
// Request Logging Middleware
// ---------------------------------------------------------------------------
/// Logs method, path, status, and duration for every request.
pub async fn logging_middleware(request: Request, next: Next) -> Response {
    let method = request.method().clone();
    let uri = request.uri().clone();
    let start = Instant::now();

    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-")
        .to_string();

    let response = next.run(request).await;
    let elapsed = start.elapsed();

    tracing::info!(
        method = %method,
        uri = %uri,
        status = %response.status().as_u16(),
        elapsed_ms = elapsed.as_millis() as u64,
        request_id = %request_id,
        "request completed"
    );

    response
}

// ---------------------------------------------------------------------------
// Auth Middleware
// ---------------------------------------------------------------------------
/// JWT bearer token authentication.
/// Rejects requests without a valid Authorization header.
///
/// Usage:
/// ```rust
/// let app = Router::new()
///     .route("/protected", get(handler))
///     .layer(middleware::from_fn_with_state(state, auth_middleware));
/// ```
#[derive(Clone)]
pub struct AuthConfig {
    pub jwt_secret: Arc<String>,
}

pub async fn auth_middleware(
    axum::extract::State(config): axum::extract::State<AuthConfig>,
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let auth_header = request
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or(StatusCode::UNAUTHORIZED)?;

    let token = auth_header
        .strip_prefix("Bearer ")
        .ok_or(StatusCode::UNAUTHORIZED)?;

    // Replace with real JWT validation (e.g., jsonwebtoken crate)
    if token.is_empty() || config.jwt_secret.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Example: decode and validate JWT
    // let claims = jsonwebtoken::decode::<Claims>(
    //     token,
    //     &DecodingKey::from_secret(config.jwt_secret.as_bytes()),
    //     &Validation::default(),
    // ).map_err(|_| StatusCode::UNAUTHORIZED)?;

    Ok(next.run(request).await)
}

// ---------------------------------------------------------------------------
// Rate Limiting Middleware
// ---------------------------------------------------------------------------
/// Simple in-memory sliding window rate limiter.
/// For production, use `tower_governor` or a Redis-backed solution.
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

#[derive(Clone)]
pub struct RateLimiter {
    requests: Arc<Mutex<HashMap<String, Vec<Instant>>>>,
    max_requests: usize,
    window: Duration,
}

impl RateLimiter {
    pub fn new(max_requests: usize, window: Duration) -> Self {
        Self {
            requests: Arc::new(Mutex::new(HashMap::new())),
            max_requests,
            window,
        }
    }

    fn check(&self, key: &str) -> bool {
        let mut map = self.requests.lock().unwrap();
        let now = Instant::now();
        let entries = map.entry(key.to_string()).or_default();

        // Remove expired entries
        entries.retain(|t| now.duration_since(*t) < self.window);

        if entries.len() >= self.max_requests {
            false
        } else {
            entries.push(now);
            true
        }
    }
}

/// Rate limit middleware using client IP as key.
pub async fn rate_limit_middleware(
    axum::extract::State(limiter): axum::extract::State<RateLimiter>,
    request: Request,
    next: Next,
) -> Result<Response, impl IntoResponse> {
    let key = request
        .headers()
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown")
        .to_string();

    if !limiter.check(&key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            [("retry-after", "60")],
            "Rate limit exceeded",
        ));
    }

    Ok(next.run(request).await)
}

// ---------------------------------------------------------------------------
// Example: Applying All Middleware
// ---------------------------------------------------------------------------
// ```rust
// use axum::{Router, middleware, routing::get};
//
// let auth_config = AuthConfig { jwt_secret: Arc::new("secret".into()) };
// let rate_limiter = RateLimiter::new(100, Duration::from_secs(60));
//
// let app = Router::new()
//     .route("/api/data", get(handler))
//     .layer(middleware::from_fn(request_id_middleware))
//     .layer(middleware::from_fn(logging_middleware))
//     .layer(middleware::from_fn_with_state(auth_config, auth_middleware))
//     .layer(middleware::from_fn_with_state(rate_limiter, rate_limit_middleware));
// ```
