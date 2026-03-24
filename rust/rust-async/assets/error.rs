use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

/// Unified application error type.
///
/// Implements `IntoResponse` for automatic conversion to HTTP responses.
/// Implements `From` for common error types to enable `?` in handlers.
///
/// Usage in handlers:
/// ```rust
/// async fn handler() -> Result<Json<Data>, AppError> {
///     let data = db_query().await?;  // sqlx::Error → AppError::Db
///     Ok(Json(data))
/// }
/// ```
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("not found: {0}")]
    NotFound(String),

    #[error("bad request: {0}")]
    BadRequest(String),

    #[error("unauthorized: {0}")]
    Unauthorized(String),

    #[error("forbidden")]
    Forbidden,

    #[error("conflict: {0}")]
    Conflict(String),

    #[error("rate limited")]
    RateLimited,

    #[error(transparent)]
    Db(#[from] sqlx::Error),

    #[error(transparent)]
    Validation(#[from] validator::ValidationErrors),

    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

impl AppError {
    pub fn not_found(msg: impl Into<String>) -> Self {
        Self::NotFound(msg.into())
    }

    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self::BadRequest(msg.into())
    }

    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self::Unauthorized(msg.into())
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        Self::Internal(anyhow::anyhow!(msg.into()))
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            Self::NotFound(msg) => (StatusCode::NOT_FOUND, msg.clone()),
            Self::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            Self::Unauthorized(msg) => (StatusCode::UNAUTHORIZED, msg.clone()),
            Self::Forbidden => (StatusCode::FORBIDDEN, "Forbidden".into()),
            Self::Conflict(msg) => (StatusCode::CONFLICT, msg.clone()),
            Self::RateLimited => (StatusCode::TOO_MANY_REQUESTS, "Rate limited".into()),
            Self::Validation(e) => (StatusCode::UNPROCESSABLE_ENTITY, e.to_string()),
            Self::Db(e) => {
                tracing::error!(error = ?e, "database error");
                match e {
                    sqlx::Error::RowNotFound => {
                        (StatusCode::NOT_FOUND, "Resource not found".into())
                    }
                    sqlx::Error::Database(db_err) if db_err.is_unique_violation() => {
                        (StatusCode::CONFLICT, "Resource already exists".into())
                    }
                    _ => (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Internal server error".into(),
                    ),
                }
            }
            Self::Internal(e) => {
                tracing::error!(error = ?e, "internal error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Internal server error".into(),
                )
            }
        };

        let body = serde_json::json!({
            "error": {
                "message": message,
                "code": status.as_u16(),
            }
        });

        (status, Json(body)).into_response()
    }
}

// Enable ? conversion from reqwest errors
impl From<reqwest::Error> for AppError {
    fn from(e: reqwest::Error) -> Self {
        tracing::error!(error = ?e, "HTTP client error");
        Self::Internal(e.into())
    }
}

/// Result type alias for handlers.
pub type AppResult<T> = Result<T, AppError>;
