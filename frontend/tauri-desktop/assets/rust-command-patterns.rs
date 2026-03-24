// Common Tauri v2 command patterns for Rust backend
//
// Demonstrates: sync/async commands, state access, error handling,
// serialization, file I/O, background tasks, and channel streaming.

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{ipc::Channel, AppHandle, Emitter, Manager, State};

// ─── Error Handling ──────────────────────────────────────────

/// Use thiserror + Serialize for clean IPC error transport.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Validation error: {0}")]
    Validation(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Database error: {0}")]
    Database(String),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
}

impl serde::Serialize for AppError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.to_string().as_ref())
    }
}

type Result<T> = std::result::Result<T, AppError>;

// ─── Data Models ─────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TodoItem {
    pub id: u32,
    pub title: String,
    pub completed: bool,
}

#[derive(Debug, Deserialize)]
pub struct CreateTodoRequest {
    pub title: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct TodoStats {
    pub total: usize,
    pub completed: usize,
    pub pending: usize,
}

// ─── Application State ──────────────────────────────────────

pub struct AppState {
    pub todos: Mutex<Vec<TodoItem>>,
    pub next_id: Mutex<u32>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            todos: Mutex::new(Vec::new()),
            next_id: Mutex::new(1),
        }
    }
}

// ─── Basic Sync Command ─────────────────────────────────────

/// Simple synchronous command — returns immediately.
#[tauri::command]
fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}

// ─── Command with State ─────────────────────────────────────

/// Access shared application state via `State<>`.
#[tauri::command]
fn create_todo(state: State<'_, AppState>, request: CreateTodoRequest) -> Result<TodoItem> {
    if request.title.trim().is_empty() {
        return Err(AppError::Validation("Title cannot be empty".into()));
    }

    let mut id = state.next_id.lock().unwrap();
    let todo = TodoItem {
        id: *id,
        title: request.title,
        completed: false,
    };
    *id += 1;

    state.todos.lock().unwrap().push(todo.clone());
    Ok(todo)
}

#[tauri::command]
fn list_todos(state: State<'_, AppState>) -> Vec<TodoItem> {
    state.todos.lock().unwrap().clone()
}

#[tauri::command]
fn toggle_todo(state: State<'_, AppState>, id: u32) -> Result<TodoItem> {
    let mut todos = state.todos.lock().unwrap();
    let todo = todos
        .iter_mut()
        .find(|t| t.id == id)
        .ok_or_else(|| AppError::NotFound(format!("Todo #{}", id)))?;
    todo.completed = !todo.completed;
    Ok(todo.clone())
}

#[tauri::command]
fn get_stats(state: State<'_, AppState>) -> TodoStats {
    let todos = state.todos.lock().unwrap();
    let completed = todos.iter().filter(|t| t.completed).count();
    TodoStats {
        total: todos.len(),
        completed,
        pending: todos.len() - completed,
    }
}

// ─── Async Command with File I/O ────────────────────────────

/// Async commands run on a thread pool and can perform blocking I/O.
#[tauri::command]
async fn read_config(app: AppHandle) -> Result<serde_json::Value> {
    let config_dir = app.path().app_config_dir().map_err(|e| {
        AppError::Io(std::io::Error::new(std::io::ErrorKind::NotFound, e.to_string()))
    })?;
    let config_path = config_dir.join("config.json");

    if !config_path.exists() {
        return Ok(serde_json::json!({}));
    }

    let content = tokio::fs::read_to_string(&config_path).await?;
    let config: serde_json::Value = serde_json::from_str(&content)?;
    Ok(config)
}

#[tauri::command]
async fn save_config(app: AppHandle, config: serde_json::Value) -> Result<()> {
    let config_dir = app.path().app_config_dir().map_err(|e| {
        AppError::Io(std::io::Error::new(std::io::ErrorKind::NotFound, e.to_string()))
    })?;
    tokio::fs::create_dir_all(&config_dir).await?;

    let config_path = config_dir.join("config.json");
    let content = serde_json::to_string_pretty(&config)?;
    tokio::fs::write(&config_path, content).await?;
    Ok(())
}

// ─── Command with Events ────────────────────────────────────

/// Emit events to the frontend during long-running operations.
#[tauri::command]
async fn process_files(app: AppHandle, paths: Vec<String>) -> Result<Vec<String>> {
    let total = paths.len();
    let mut results = Vec::new();

    for (i, path) in paths.iter().enumerate() {
        // Emit progress to frontend
        app.emit(
            "processing-progress",
            serde_json::json!({
                "current": i + 1,
                "total": total,
                "file": path,
            }),
        )
        .unwrap();

        let content = tokio::fs::read_to_string(path).await?;
        results.push(format!("{}: {} bytes", path, content.len()));

        // Simulate work
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }

    app.emit("processing-complete", &results).unwrap();
    Ok(results)
}

// ─── Command with Channel (Streaming) ───────────────────────

/// Use Channel for efficient streaming of data to the frontend.
#[derive(Debug, Serialize, Clone)]
pub struct DownloadProgress {
    pub url: String,
    pub bytes_downloaded: u64,
    pub total_bytes: u64,
    pub percentage: f64,
}

#[tauri::command]
async fn download_file(url: String, on_progress: Channel<DownloadProgress>) -> Result<String> {
    let total: u64 = 1_000_000;
    let chunk_size: u64 = 100_000;

    for downloaded in (0..=total).step_by(chunk_size as usize) {
        on_progress
            .send(DownloadProgress {
                url: url.clone(),
                bytes_downloaded: downloaded,
                total_bytes: total,
                percentage: (downloaded as f64 / total as f64) * 100.0,
            })
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }

    Ok(format!("Downloaded: {}", url))
}

// ─── Platform-Specific Command ──────────────────────────────

#[tauri::command]
fn get_system_info() -> serde_json::Value {
    serde_json::json!({
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "family": std::env::consts::FAMILY,
    })
}

// ─── Registration ────────────────────────────────────────────

/// Register all commands with the Tauri Builder.
pub fn register_commands() -> impl Fn(tauri::ipc::Invoke) -> bool {
    tauri::generate_handler![
        greet,
        create_todo,
        list_todos,
        toggle_todo,
        get_stats,
        read_config,
        save_config,
        process_files,
        download_file,
        get_system_info,
    ]
}

// Example main setup:
//
// fn main() {
//     tauri::Builder::default()
//         .manage(AppState::default())
//         .invoke_handler(register_commands())
//         .run(tauri::generate_context!())
//         .expect("error running app");
// }
