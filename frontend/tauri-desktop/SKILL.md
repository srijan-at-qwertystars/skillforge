---
name: tauri-desktop
description: >
  Build cross-platform desktop applications with Tauri v2 (Rust core + system webview).
  Covers project scaffolding, Rust commands, IPC invoke, events, state management,
  plugin system, window management, menus, system tray, file system access, updater,
  multi-window, security (capabilities, CSP), building, signing, and platform-specific code.
  TRIGGERS: "Tauri", "tauri app", "desktop application with web frontend",
  "Rust backend desktop", "tauri command", "tauri plugin", "tauri IPC",
  "create-tauri-app", "tauri invoke", "tauri events", "tauri window",
  "tauri tray", "tauri updater", "tauri capabilities".
  NOT for Electron, React Native, Flutter desktop, NW.js, or general Rust without Tauri context.
---

# Tauri v2 Desktop Application Development

## Architecture

Tauri v2 apps have two processes:
- **Rust Core**: native backend handling OS operations, state, and business logic
- **Webview Frontend**: HTML/CSS/JS rendered via system webview (WebView2 on Windows, WebKitGTK on Linux, WKWebView on macOS)

Communication uses IPC via **Commands** (request/response) and **Events** (pub/sub, bidirectional).

## Project Setup

```bash
# Scaffold a new project (interactive — picks framework + language)
npm create tauri-app@latest my-app
cd my-app
npm install
npm run tauri dev    # dev mode with hot reload
npm run tauri build  # production build
```

**Project structure:**
```
my-app/
├── src/              # Frontend source (React/Vue/Svelte/etc.)
├── src-tauri/
│   ├── Cargo.toml    # Rust dependencies
│   ├── tauri.conf.json
│   ├── capabilities/ # Security capability files
│   ├── src/
│   │   ├── main.rs   # Entry point (or lib.rs)
│   │   └── lib.rs    # Commands, setup, plugins
│   └── icons/
└── package.json
```

## Commands (IPC Invoke)

Commands are Rust functions callable from the frontend.

**Rust — define commands:**
```rust
#[tauri::command]
fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}

// Async command for I/O-bound work
#[tauri::command]
async fn read_data(path: String) -> Result<String, String> {
    std::fs::read_to_string(&path).map_err(|e| e.to_string())
}

// Access app handle, window, or state
#[tauri::command]
async fn do_work(
    app: tauri::AppHandle,
    window: tauri::Window,
    state: tauri::State<'_, AppState>,
) -> Result<String, String> {
    let count = state.counter.lock().unwrap();
    Ok(format!("Count: {count}"))
}
```

**Rust — register commands:**
```rust
fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![greet, read_data, do_work])
        .run(tauri::generate_context!())
        .expect("error running tauri app");
}
```

**Frontend — call commands:**
```typescript
import { invoke } from '@tauri-apps/api/core';

const message = await invoke<string>('greet', { name: 'World' });
const data = await invoke<string>('read_data', { path: '/tmp/file.txt' });
```

## Events System

Bidirectional pub/sub for fire-and-forget communication.

**Frontend — emit and listen:**
```typescript
import { emit, listen } from '@tauri-apps/api/event';

// Listen for backend events
const unlisten = await listen<{ progress: number }>('download-progress', (event) => {
    console.log(`Progress: ${event.payload.progress}%`);
});

// Emit to backend
await emit('start-download', { url: 'https://example.com/file.zip' });

// Cleanup
unlisten();
```

**Rust — emit and listen:**
```rust
use tauri::Emitter;

// Emit to all windows
app_handle.emit("download-progress", serde_json::json!({ "progress": 50 }))?;

// Emit to a specific window
app_handle.emit_to("main", "update-ready", payload)?;

// Listen for frontend events
app_handle.listen("start-download", |event| {
    println!("Received: {:?}", event.payload());
});
```

## State Management

Thread-safe app-wide state using `Mutex` or `RwLock`.

```rust
use std::sync::Mutex;

struct AppState {
    counter: Mutex<u32>,
    db_pool: sqlx::SqlitePool, // immutable state needs no Mutex
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            app.manage(AppState {
                counter: Mutex::new(0),
                db_pool: create_pool(),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![increment])
        .run(tauri::generate_context!())
        .unwrap();
}

#[tauri::command]
fn increment(state: tauri::State<'_, AppState>) -> u32 {
    let mut count = state.counter.lock().unwrap();
    *count += 1;
    *count
}
```

Use `tokio::sync::Mutex` if holding the lock across `.await` points.

## Plugin System

Plugins extend Tauri with modular, reusable functionality.

**Using official plugins:**
```bash
# Add via cargo and npm
cargo add tauri-plugin-fs
npm install @tauri-apps/plugin-fs
```

```rust
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .run(tauri::generate_context!())
        .unwrap();
}
```

**Creating a custom plugin:**
```rust
use tauri::plugin::{Builder as PluginBuilder, TauriPlugin};
use tauri::Runtime;

#[tauri::command]
fn plugin_command() -> String {
    "from plugin".into()
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    PluginBuilder::new("my-plugin")
        .invoke_handler(tauri::generate_handler![plugin_command])
        .setup(|app, _api| {
            // Plugin initialization
            Ok(())
        })
        .build()
}
```

**Key official plugins:** `fs`, `dialog`, `shell`, `http`, `notification`,
`clipboard-manager`, `global-shortcut`, `updater`, `store`, `sql`, `log`,
`os`, `process`, `autostart`.

## Window Management

```rust
use tauri::{Manager, WebviewWindowBuilder, WebviewUrl};

#[tauri::command]
async fn open_settings(app: tauri::AppHandle) -> Result<(), String> {
    WebviewWindowBuilder::new(&app, "settings", WebviewUrl::App("settings.html".into()))
        .title("Settings").inner_size(600.0, 400.0).resizable(true)
        .build().map_err(|e| e.to_string())?;
    Ok(())
}
```

Handle window events on the Builder:
```rust
.on_window_event(|window, event| {
    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
        window.hide().unwrap(); // Hide instead of close
        api.prevent_close();
    }
})
```

**Frontend window control:**
```typescript
import { getCurrentWindow } from '@tauri-apps/api/window';

const win = getCurrentWindow();
await win.setTitle('New Title');
await win.minimize();
await win.close();
```

## Menu & System Tray

**Application menu:**
```rust
use tauri::menu::{MenuBuilder, SubmenuBuilder};

// Inside Builder::default().setup(|app| { ... })
let menu = MenuBuilder::new(app)
    .item(&SubmenuBuilder::new(app, "File")
        .text("open", "Open File").separator().quit().build()?)
    .item(&SubmenuBuilder::new(app, "Edit")
        .copy().paste().build()?)
    .build()?;
app.set_menu(menu)?;
```

Handle menu events via `.on_menu_event(|app, event| { match event.id().as_ref() { ... } })` on the Builder.
```rust
use tauri::tray::{TrayIconBuilder, MouseButton, MouseButtonState};
use tauri::menu::{MenuBuilder, MenuItemBuilder};

// Inside Builder::default().setup(|app| { ... })
let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;
let show = MenuItemBuilder::with_id("show", "Show").build(app)?;
let menu = MenuBuilder::new(app).items(&[&show, &quit]).build()?;

TrayIconBuilder::new()
    .icon(app.default_window_icon().unwrap().clone())
    .menu(&menu)
    .on_menu_event(|app, event| match event.id().as_ref() {
        "quit" => app.exit(0),
        "show" => {
            if let Some(w) = app.get_webview_window("main") {
                w.show().unwrap();
                w.set_focus().unwrap();
            }
        }
        _ => {}
    })
    .on_tray_icon_event(|tray, event| {
        if let tauri::tray::TrayIconEvent::Click {
            button: MouseButton::Left, button_state: MouseButtonState::Up, ..
        } = event {
            if let Some(w) = tray.app_handle().get_webview_window("main") {
                w.show().unwrap();
                w.set_focus().unwrap();
            }
        }
    })
    .build(app)?;
```

## File System Access

Use `tauri-plugin-fs` with scoped permissions.

```typescript
import { readTextFile, writeTextFile, exists } from '@tauri-apps/plugin-fs';
import { appDataDir, join } from '@tauri-apps/api/path';

const dir = await appDataDir();
const filePath = await join(dir, 'config.json');

if (await exists(filePath)) {
    const content = await readTextFile(filePath);
    console.log(JSON.parse(content));
}

await writeTextFile(filePath, JSON.stringify({ theme: 'dark' }));
```

**Capability for fs access:**
```json
{
  "identifier": "main-capability",
  "windows": ["main"],
  "permissions": [
    "fs:default",
    "fs:allow-read-text-file",
    "fs:allow-write-text-file",
    "fs:allow-exists",
    { "identifier": "fs:scope", "allow": [{ "path": "$APPDATA/**" }] }
  ]
}
```

## Updater

```bash
cargo add tauri-plugin-updater
npm install @tauri-apps/plugin-updater

# Generate signing keys
npm run tauri signer generate -- -w ~/.tauri/myapp.key
```

**tauri.conf.json:**
```json
{
  "bundle": { "createUpdaterArtifacts": true },
  "plugins": {
    "updater": {
      "endpoints": ["https://releases.example.com/{{target}}/{{arch}}/{{current_version}}"],
      "pubkey": "dW50cnVzdGVkIGNvbW1lbnQ..."
    }
  }
}
```

**Check for updates in frontend:**
```typescript
import { check } from '@tauri-apps/plugin-updater';

const update = await check();
if (update) {
    console.log(`Update ${update.version} available`);
    await update.downloadAndInstall();
    // Optionally restart
    import { relaunch } from '@tauri-apps/plugin-process';
    await relaunch();
}
```

## Security: Capabilities & CSP

**Capabilities** (replaces v1 allowlist) — defined in `src-tauri/capabilities/`:
```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "main-capability",
  "description": "Permissions for the main window",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "core:window:allow-set-title",
    "dialog:default",
    "fs:default",
    { "identifier": "fs:scope", "allow": [{ "path": "$APPDATA/**" }] }
  ]
}
```

**CSP in tauri.conf.json:**
```json
{
  "app": {
    "security": {
      "csp": "default-src 'self'; connect-src ipc: http://ipc.localhost; img-src 'self' asset: blob: data:; style-src 'self' 'unsafe-inline'",
      "freezePrototype": true
    }
  }
}
```

Best practices: never use `"csp": null` in production; always enable `freezePrototype`;
assign minimal permissions per window; never use `"windows": ["*"]` with broad permissions.

## Building & Signing

```bash
npm run tauri build                                     # Current platform
npm run tauri build -- --target universal-apple-darwin   # macOS universal
```

Configure in `tauri.conf.json` under `"bundle"`: set `identifier`, `icon`, `targets`.
For Windows signing: `"windows": { "certificateThumbprint": "HASH" }`.
For macOS signing: `"macOS": { "signingIdentity": "Developer ID Application: ..." }`.
CI env vars: `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.

## Platform-Specific Code

**Rust:**
```rust
#[tauri::command]
fn platform_info() -> String {
    #[cfg(target_os = "macos")]
    return "macOS".to_string();
    #[cfg(target_os = "windows")]
    return "Windows".to_string();
    #[cfg(target_os = "linux")]
    return "Linux".to_string();
}
```

**Platform-specific capabilities:**
```json
{
  "identifier": "desktop-capability",
  "windows": ["main"],
  "platforms": ["linux", "macOS", "windows"],
  "permissions": ["core:default"]
}
```

**Frontend platform detection:**
```typescript
import { platform } from '@tauri-apps/plugin-os';
const os = await platform(); // 'linux' | 'macos' | 'windows'
```

## Examples

### Example 1: Create a Tauri command with state

**Input:** "Add a counter command that persists across calls"

**Output:**
```rust
// src-tauri/src/lib.rs
use std::sync::Mutex;

struct Counter(Mutex<i32>);

#[tauri::command]
fn increment(counter: tauri::State<'_, Counter>) -> i32 {
    let mut val = counter.0.lock().unwrap();
    *val += 1;
    *val
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Counter(Mutex::new(0)))
        .invoke_handler(tauri::generate_handler![increment])
        .run(tauri::generate_context!())
        .expect("error running app");
}
```
```typescript
// Frontend
import { invoke } from '@tauri-apps/api/core';
const count = await invoke<number>('increment'); // Returns 1, 2, 3...
```

### Example 2: Minimize-to-tray on close

**Input:** "Make the app minimize to system tray on close"

**Output:** Combine `on_window_event` with `CloseRequested` + `api.prevent_close()` + `window.hide()`,
and a tray menu item that calls `window.show()` (see System Tray and Window Management sections).

### Example 3: Scoped file access

**Input:** "Let the app read/write JSON config in app data"

**Output:** Add `tauri-plugin-fs`, create a capability granting `fs:allow-read-text-file`,
`fs:allow-write-text-file` scoped to `$APPDATA/**`, then use the plugin-fs JS API (see File System section).
