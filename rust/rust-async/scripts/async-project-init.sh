#!/usr/bin/env bash
# async-project-init.sh — Scaffold a Rust async project with tokio, axum, sqlx, tracing
#
# Usage: ./async-project-init.sh <project-name>
#
# Creates a production-ready async Rust project structure:
#   <project-name>/
#   ├── Cargo.toml          (tokio, axum, sqlx, tracing, tower deps)
#   ├── .env                (DATABASE_URL)
#   ├── src/
#   │   ├── main.rs         (tracing init, graceful shutdown, axum server)
#   │   ├── error.rs        (unified AppError with IntoResponse)
#   │   ├── routes/
#   │   │   ├── mod.rs      (router composition)
#   │   │   └── health.rs   (health check endpoint)
#   │   └── models/
#   │       └── mod.rs      (model placeholder)
#   └── migrations/         (sqlx migrations directory)

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project-name>"
    echo "Example: $0 my-api"
    exit 1
fi

PROJECT_NAME="$1"

if [ -d "$PROJECT_NAME" ]; then
    echo "Error: Directory '$PROJECT_NAME' already exists."
    exit 1
fi

echo "Creating async Rust project: $PROJECT_NAME"

mkdir -p "$PROJECT_NAME/src/routes"
mkdir -p "$PROJECT_NAME/src/models"
mkdir -p "$PROJECT_NAME/migrations"

# --- Cargo.toml ---
cat > "$PROJECT_NAME/Cargo.toml" << 'CARGO'
[package]
name = "__PROJECT_NAME__"
version = "0.1.0"
edition = "2021"

[dependencies]
# Async runtime
tokio = { version = "1", features = ["full"] }

# Web framework
axum = { version = "0.8", features = ["macros"] }
tower = { version = "0.5", features = ["util", "timeout", "limit"] }
tower-http = { version = "0.6", features = ["trace", "cors", "compression-gzip", "timeout", "limit", "request-id", "util", "catch-panic", "normalize-path"] }

# Database
sqlx = { version = "0.8", features = ["runtime-tokio-rustls", "postgres", "migrate", "chrono", "uuid"] }

# Serialization
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Error handling
thiserror = "2"
anyhow = "1"

# Tracing / Logging
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }

# Utilities
uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
dotenvy = "0.15"

[dev-dependencies]
tokio = { version = "1", features = ["test-util"] }
CARGO
sed -i "s/__PROJECT_NAME__/$PROJECT_NAME/g" "$PROJECT_NAME/Cargo.toml"

# --- .env ---
cat > "$PROJECT_NAME/.env" << 'ENV'
DATABASE_URL=postgres://postgres:postgres@localhost:5432/__PROJECT_NAME__
RUST_LOG=info
HOST=0.0.0.0
PORT=3000
ENV
sed -i "s/__PROJECT_NAME__/$PROJECT_NAME/g" "$PROJECT_NAME/.env"

# --- src/main.rs ---
cat > "$PROJECT_NAME/src/main.rs" << 'MAIN'
use std::net::SocketAddr;
use tokio::net::TcpListener;
use tracing_subscriber::{fmt, EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

mod error;
mod models;
mod routes;

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::PgPool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(fmt::layer())
        .init();

    let database_url = std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port: u16 = std::env::var("PORT")
        .unwrap_or_else(|_| "3000".into())
        .parse()
        .expect("PORT must be a number");

    let pool = sqlx::PgPool::connect(&database_url).await?;
    sqlx::migrate!().run(&pool).await?;
    tracing::info!("database connected and migrated");

    let state = AppState { pool };
    let app = routes::create_router(state);

    let addr: SocketAddr = format!("{host}:{port}").parse()?;
    let listener = TcpListener::bind(addr).await?;
    tracing::info!("listening on {addr}");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    tracing::info!("server shut down gracefully");
    Ok(())
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
MAIN

# --- src/error.rs ---
cat > "$PROJECT_NAME/src/error.rs" << 'ERROR'
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("not found: {0}")]
    NotFound(String),
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized")]
    Unauthorized,
    #[error(transparent)]
    Db(#[from] sqlx::Error),
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            Self::NotFound(msg) => (StatusCode::NOT_FOUND, msg.clone()),
            Self::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "Unauthorized".into()),
            Self::Db(e) => {
                tracing::error!("database error: {e:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal server error".into())
            }
            Self::Internal(e) => {
                tracing::error!("internal error: {e:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal server error".into())
            }
        };
        let body = serde_json::json!({ "error": message });
        (status, Json(body)).into_response()
    }
}
ERROR

# --- src/routes/mod.rs ---
cat > "$PROJECT_NAME/src/routes/mod.rs" << 'ROUTES'
use axum::Router;
use tower_http::trace::TraceLayer;
use tower_http::cors::CorsLayer;
use tower_http::compression::CompressionLayer;
use tower_http::timeout::TimeoutLayer;
use std::time::Duration;

use crate::AppState;

mod health;

pub fn create_router(state: AppState) -> Router {
    Router::new()
        .nest("/api", api_routes())
        .layer(TraceLayer::new_for_http())
        .layer(TimeoutLayer::new(Duration::from_secs(30)))
        .layer(CompressionLayer::new())
        .layer(CorsLayer::permissive())
        .with_state(state)
}

fn api_routes() -> Router<AppState> {
    Router::new()
        .merge(health::routes())
}
ROUTES

# --- src/routes/health.rs ---
cat > "$PROJECT_NAME/src/routes/health.rs" << 'HEALTH'
use axum::{routing::get, Json, Router};
use crate::AppState;

pub fn routes() -> Router<AppState> {
    Router::new().route("/health", get(health_check))
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "status": "ok" }))
}
HEALTH

# --- src/models/mod.rs ---
cat > "$PROJECT_NAME/src/models/mod.rs" << 'MODELS'
// Add your database models here.
// Example:
// use serde::{Deserialize, Serialize};
// use sqlx::FromRow;
//
// #[derive(Debug, Serialize, Deserialize, FromRow)]
// pub struct User {
//     pub id: i64,
//     pub name: String,
//     pub email: String,
//     pub created_at: chrono::DateTime<chrono::Utc>,
// }
MODELS

# --- .gitignore ---
cat > "$PROJECT_NAME/.gitignore" << 'GITIGNORE'
/target
.env
GITIGNORE

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  # Start Postgres (or use docker-compose)"
echo "  cargo run"
echo ""
echo "Structure:"
find "$PROJECT_NAME" -type f | sort | sed 's/^/  /'
