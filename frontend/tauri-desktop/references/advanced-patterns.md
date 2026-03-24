# Tauri v2 Advanced Patterns

## Table of Contents

- [Multi-Window Management](#multi-window-management)
- [Custom Protocols](#custom-protocols)
- [Deep Linking](#deep-linking)
- [Drag and Drop](#drag-and-drop)
- [Clipboard](#clipboard)
- [Notifications](#notifications)
- [System Tray Advanced Patterns](#system-tray-advanced-patterns)
- [Global Shortcuts](#global-shortcuts)
- [Custom Title Bars](#custom-title-bars)
- [Shell Commands](#shell-commands)
- [Embedded Server](#embedded-server)
- [Tauri v2 Mobile Support](#tauri-v2-mobile-support)

---

## Multi-Window Management

### Creating Windows Programmatically

```rust
use tauri::{Manager, WebviewWindowBuilder, WebviewUrl};

#[tauri::command]
async fn open_editor(app: tauri::AppHandle, file_id: String) -> Result<(), String> {
    let label = format!("editor-{}", file_id);

    // Prevent duplicate windows
    if let Some(existing) = app.get_webview_window(&label) {
        existing.set_focus().map_err(|e| e.to_string())?;
        return Ok(());
    }

    WebviewWindowBuilder::new(
        &app,
        &label,
        WebviewUrl::App(format!("editor.html?file={}", file_id).into()),
    )
    .title(format!("Editor — {}", file_id))
    .inner_size(800.0, 600.0)
    .min_inner_size(400.0, 300.0)
    .position(100.0, 100.0)
    .resizable(true)
    .decorations(true)
    .visible(true)
    .focused(true)
    .build()
    .map_err(|e| e.to_string())?;

    Ok(())
}
```

### Inter-Window Communication

Windows communicate via the event system. Target specific windows with `emit_to`:

```rust
use tauri::{Emitter, Manager};

#[tauri::command]
async fn broadcast_theme(app: tauri::AppHandle, theme: String) -> Result<(), String> {
    // Emit to all windows
    app.emit("theme-changed", &theme).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn send_to_window(
    app: tauri::AppHandle,
    target: String,
    message: String,
) -> Result<(), String> {
    app.emit_to(&target, "message", &message)
        .map_err(|e| e.to_string())?;
    Ok(())
}
```

**Frontend — listen for cross-window events:**

```typescript
import { listen } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';

const unlisten = await listen<string>('theme-changed', (event) => {
    document.documentElement.setAttribute('data-theme', event.payload);
});

// Send message to another window
import { emit } from '@tauri-apps/api/event';
await emit('sync-state', { data: currentState });
```

### Window State Persistence

Save and restore window position/size across sessions:

```rust
use serde::{Deserialize, Serialize};
use std::fs;
use tauri::Manager;

#[derive(Serialize, Deserialize, Default)]
struct WindowState {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    maximized: bool,
}

fn save_window_state(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        if let (Ok(pos), Ok(size)) = (window.outer_position(), window.outer_size()) {
            let state = WindowState {
                x: pos.x as f64,
                y: pos.y as f64,
                width: size.width as f64,
                height: size.height as f64,
                maximized: window.is_maximized().unwrap_or(false),
            };
            let path = app
                .path()
                .app_data_dir()
                .unwrap()
                .join("window-state.json");
            let _ = fs::write(path, serde_json::to_string(&state).unwrap());
        }
    }
}

fn restore_window_state(app: &tauri::AppHandle) {
    let path = app
        .path()
        .app_data_dir()
        .unwrap()
        .join("window-state.json");
    if let Ok(data) = fs::read_to_string(&path) {
        if let Ok(state) = serde_json::from_str::<WindowState>(&data) {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_position(tauri::Position::Physical(
                    tauri::PhysicalPosition::new(state.x as i32, state.y as i32),
                ));
                let _ = window.set_size(tauri::Size::Physical(
                    tauri::PhysicalSize::new(state.width as u32, state.height as u32),
                ));
                if state.maximized {
                    let _ = window.maximize();
                }
            }
        }
    }
}
```

### Modal and Child Windows

```rust
#[tauri::command]
async fn open_modal(app: tauri::AppHandle) -> Result<(), String> {
    let main = app.get_webview_window("main").unwrap();

    let modal = WebviewWindowBuilder::new(
        &app,
        "confirm-dialog",
        WebviewUrl::App("confirm.html".into()),
    )
    .title("Confirm Action")
    .inner_size(400.0, 200.0)
    .resizable(false)
    .minimizable(false)
    .maximizable(false)
    .always_on_top(true)
    .parent(&main)
    .map_err(|e| e.to_string())?
    .build()
    .map_err(|e| e.to_string())?;

    Ok(())
}
```

---

## Custom Protocols

Register custom URI schemes to serve local assets or intercept requests:

```rust
use tauri::http::{Request, Response};

fn main() {
    tauri::Builder::default()
        .register_asynchronous_uri_scheme_protocol("media", |_ctx, request, responder| {
            // Handle media:// URLs
            std::thread::spawn(move || {
                let path = request.uri().path();
                match std::fs::read(format!("/path/to/media{}", path)) {
                    Ok(data) => {
                        let mime = mime_guess::from_path(path)
                            .first_or_octet_stream()
                            .to_string();
                        responder.respond(
                            Response::builder()
                                .header("Content-Type", &mime)
                                .header("Access-Control-Allow-Origin", "*")
                                .body(data)
                                .unwrap(),
                        );
                    }
                    Err(_) => {
                        responder.respond(
                            Response::builder()
                                .status(404)
                                .body(b"Not Found".to_vec())
                                .unwrap(),
                        );
                    }
                }
            });
        })
        .run(tauri::generate_context!())
        .unwrap();
}
```

**Frontend usage:**
```html
<img src="media://images/photo.jpg" />
<video src="media://videos/clip.mp4"></video>
```

### Asset Protocol

Tauri provides a built-in `asset` protocol for streaming local files:

```typescript
import { convertFileSrc } from '@tauri-apps/api/core';

// Convert a filesystem path to an asset:// URL the webview can load
const assetUrl = convertFileSrc('/path/to/image.png');
// assetUrl = "asset://localhost/path/to/image.png" (or similar)
```

**Capability required:**
```json
{
  "permissions": [
    "core:default",
    {
      "identifier": "core:asset:default",
      "allow": [{ "path": "$APPDATA/**" }]
    }
  ]
}
```

---

## Deep Linking

Handle custom URL schemes (e.g., `myapp://action/param`) to open your app with context.

### Setup

**tauri.conf.json:**
```json
{
  "plugins": {
    "deep-link": {
      "desktop": {
        "schemes": ["myapp"]
      }
    }
  }
}
```

```bash
cargo add tauri-plugin-deep-link
npm install @tauri-apps/plugin-deep-link
```

### Rust Handler

```rust
use tauri_plugin_deep_link::DeepLinkExt;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            // Handle URLs when app is already running
            app.deep_link().on_open_url(|event| {
                for url in event.urls() {
                    println!("Deep link received: {}", url);
                    // Parse and route: myapp://open/file?id=123
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .unwrap();
}
```

### Frontend Handler

```typescript
import { onOpenUrl } from '@tauri-apps/plugin-deep-link';

await onOpenUrl((urls) => {
    for (const url of urls) {
        const parsed = new URL(url);
        if (parsed.pathname === '/open/file') {
            const fileId = parsed.searchParams.get('id');
            navigateTo(`/editor/${fileId}`);
        }
    }
});
```

---

## Drag and Drop

### File Drop on Window

Handle files dragged onto the application window:

```rust
use tauri::DragDropEvent;

fn main() {
    tauri::Builder::default()
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::DragDrop(drag_event) = event {
                match drag_event {
                    DragDropEvent::Enter { paths, position } => {
                        println!("Drag entered at {:?} with {} files", position, paths.len());
                        // Highlight drop zone
                        let _ = window.emit("drag-enter", &paths);
                    }
                    DragDropEvent::Over { position } => {
                        // Track cursor position for drop zone feedback
                    }
                    DragDropEvent::Drop { paths, position } => {
                        println!("Dropped {} files at {:?}", paths.len(), position);
                        let _ = window.emit("files-dropped", &paths);
                    }
                    DragDropEvent::Leave => {
                        let _ = window.emit("drag-leave", ());
                    }
                    _ => {}
                }
            }
        })
        .run(tauri::generate_context!())
        .unwrap();
}
```

**Frontend — react to file drops:**
```typescript
import { listen } from '@tauri-apps/api/event';

await listen<string[]>('files-dropped', async (event) => {
    for (const path of event.payload) {
        console.log('Processing file:', path);
        const content = await invoke('read_file', { path });
        // Process the file
    }
});

await listen('drag-enter', () => {
    document.getElementById('drop-zone')?.classList.add('drag-over');
});

await listen('drag-leave', () => {
    document.getElementById('drop-zone')?.classList.remove('drag-over');
});
```

### Initiating Drag from App

Use the `startDrag` API to initiate OS-native drag operations:

```typescript
import { getCurrentWindow } from '@tauri-apps/api/window';

const window = getCurrentWindow();
await window.startDragging(); // Allows dragging the window by the element
```

---

## Clipboard

```bash
cargo add tauri-plugin-clipboard-manager
npm install @tauri-apps/plugin-clipboard-manager
```

```typescript
import { writeText, readText, writeImage, readImage } from '@tauri-apps/plugin-clipboard-manager';

// Text clipboard
await writeText('Hello from Tauri!');
const text = await readText();

// Image clipboard (v2)
import { readFile } from '@tauri-apps/plugin-fs';
const imageData = await readFile('/path/to/image.png');
await writeImage(imageData);
```

**Monitor clipboard changes:**
```typescript
import { onClipboardUpdate } from '@tauri-apps/plugin-clipboard-manager';

await onClipboardUpdate(async () => {
    const content = await readText();
    console.log('Clipboard changed:', content);
});
```

---

## Notifications

```bash
cargo add tauri-plugin-notification
npm install @tauri-apps/plugin-notification
```

```typescript
import {
    isPermissionGranted,
    requestPermission,
    sendNotification,
} from '@tauri-apps/plugin-notification';

let granted = await isPermissionGranted();
if (!granted) {
    const permission = await requestPermission();
    granted = permission === 'granted';
}

if (granted) {
    sendNotification({
        title: 'Download Complete',
        body: 'Your file has been downloaded successfully.',
        icon: 'icons/icon.png',
    });
}
```

### Rich Notifications with Actions

```typescript
import { sendNotification, registerActionTypes } from '@tauri-apps/plugin-notification';

// Register action types (call once at startup)
await registerActionTypes([
    {
        id: 'download-actions',
        actions: [
            { id: 'open', title: 'Open File' },
            { id: 'dismiss', title: 'Dismiss', destructive: true },
        ],
    },
]);

sendNotification({
    title: 'Download Complete',
    body: 'report.pdf — 2.4 MB',
    actionTypeId: 'download-actions',
});
```

---

## System Tray Advanced Patterns

### Dynamic Tray Menu Updates

```rust
use tauri::tray::TrayIconBuilder;
use tauri::menu::{MenuBuilder, MenuItemBuilder, CheckMenuItemBuilder};
use tauri::{Manager, Runtime};

fn build_tray_menu<R: Runtime>(app: &tauri::AppHandle<R>, status: &str) -> tauri::Result<tauri::menu::Menu<R>> {
    let status_item = MenuItemBuilder::with_id("status", format!("Status: {}", status))
        .enabled(false)
        .build(app)?;
    let pause = CheckMenuItemBuilder::with_id("pause", "Pause Sync")
        .checked(status == "paused")
        .build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;

    MenuBuilder::new(app)
        .items(&[&status_item, &pause, &quit])
        .build()
}

#[tauri::command]
async fn update_tray_status(app: tauri::AppHandle, status: String) -> Result<(), String> {
    if let Some(tray) = app.tray_by_id("main-tray") {
        let menu = build_tray_menu(&app, &status).map_err(|e| e.to_string())?;
        tray.set_menu(Some(menu)).map_err(|e| e.to_string())?;
    }
    Ok(())
}
```

### Tray Icon Animation

```rust
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::image::Image;

#[tauri::command]
async fn animate_tray(app: tauri::AppHandle, animating: tauri::State<'_, Arc<AtomicBool>>) -> Result<(), String> {
    animating.store(true, Ordering::SeqCst);
    let app_clone = app.clone();
    let flag = animating.inner().clone();

    tauri::async_runtime::spawn(async move {
        let frames = vec!["icons/sync-1.png", "icons/sync-2.png", "icons/sync-3.png"];
        let mut i = 0;
        while flag.load(Ordering::SeqCst) {
            if let Some(tray) = app_clone.tray_by_id("main-tray") {
                let icon = Image::from_path(frames[i % frames.len()]).unwrap();
                let _ = tray.set_icon(Some(icon));
            }
            i += 1;
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        }
    });

    Ok(())
}
```

---

## Global Shortcuts

```bash
cargo add tauri-plugin-global-shortcut
npm install @tauri-apps/plugin-global-shortcut
```

```rust
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};

fn main() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        let sc = shortcut.to_string();
                        match sc.as_str() {
                            "CmdOrCtrl+Shift+Space" => {
                                // Toggle window visibility
                                if let Some(w) = app.get_webview_window("main") {
                                    if w.is_visible().unwrap_or(false) {
                                        let _ = w.hide();
                                    } else {
                                        let _ = w.show();
                                        let _ = w.set_focus();
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                })
                .build(),
        )
        .setup(|app| {
            let shortcut: Shortcut = "CmdOrCtrl+Shift+Space".parse().unwrap();
            app.global_shortcut().register(shortcut)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .unwrap();
}
```

**Frontend registration:**
```typescript
import { register, unregister } from '@tauri-apps/plugin-global-shortcut';

await register('CmdOrCtrl+Shift+C', (event) => {
    if (event.state === 'Pressed') {
        console.log('Global shortcut triggered!');
    }
});

// Cleanup
await unregister('CmdOrCtrl+Shift+C');
```

---

## Custom Title Bars

Create a frameless window with a custom title bar for consistent cross-platform styling.

**tauri.conf.json:**
```json
{
  "app": {
    "windows": [
      {
        "label": "main",
        "decorations": false,
        "transparent": false,
        "width": 1024,
        "height": 768
      }
    ]
  }
}
```

**React custom title bar component:**
```tsx
import { getCurrentWindow } from '@tauri-apps/api/window';

function TitleBar() {
    const appWindow = getCurrentWindow();

    return (
        <div
            data-tauri-drag-region
            className="flex items-center justify-between h-8 bg-gray-800 text-white select-none"
        >
            <div className="flex items-center gap-2 px-3">
                <img src="/icon.png" className="w-4 h-4" alt="" />
                <span className="text-sm font-medium">My App</span>
            </div>

            <div className="flex h-full">
                <button
                    onClick={() => appWindow.minimize()}
                    className="px-3 hover:bg-gray-700 transition-colors"
                    aria-label="Minimize"
                >
                    &#x2500;
                </button>
                <button
                    onClick={async () => {
                        (await appWindow.isMaximized())
                            ? appWindow.unmaximize()
                            : appWindow.maximize();
                    }}
                    className="px-3 hover:bg-gray-700 transition-colors"
                    aria-label="Maximize"
                >
                    &#x25A1;
                </button>
                <button
                    onClick={() => appWindow.close()}
                    className="px-3 hover:bg-red-600 transition-colors"
                    aria-label="Close"
                >
                    &#x2715;
                </button>
            </div>
        </div>
    );
}
```

Key: `data-tauri-drag-region` enables window dragging on that element.

### macOS Traffic Lights with Custom Title Bar

```json
{
  "app": {
    "windows": [
      {
        "decorations": false,
        "titleBarStyle": "Overlay",
        "hiddenTitle": true
      }
    ]
  }
}
```

This keeps macOS traffic lights (close/minimize/maximize) while hiding the default title bar.

---

## Shell Commands

Execute external programs from Tauri using `tauri-plugin-shell`.

```bash
cargo add tauri-plugin-shell
npm install @tauri-apps/plugin-shell
```

### Scoped Shell Commands

Define allowed commands in capabilities:

```json
{
  "permissions": [
    {
      "identifier": "shell:allow-execute",
      "allow": [
        {
          "name": "git-status",
          "cmd": "git",
          "args": ["status", "--porcelain"]
        },
        {
          "name": "open-url",
          "cmd": "open",
          "args": [{ "validator": "^https://.*$" }]
        }
      ]
    }
  ]
}
```

**Frontend:**
```typescript
import { Command } from '@tauri-apps/plugin-shell';

// Execute a scoped command
const output = await Command.create('git-status').execute();
console.log('stdout:', output.stdout);
console.log('stderr:', output.stderr);
console.log('exit code:', output.code);
```

### Streaming Output

```typescript
const command = Command.create('long-running-task');

command.stdout.on('data', (line) => {
    console.log('stdout:', line);
});

command.stderr.on('data', (line) => {
    console.error('stderr:', line);
});

command.on('close', (data) => {
    console.log('Process exited with code:', data.code);
});

command.on('error', (error) => {
    console.error('Error:', error);
});

const child = await command.spawn();
// Later: await child.kill();
```

### Sidecar Binaries

Bundle external binaries with your app:

**tauri.conf.json:**
```json
{
  "bundle": {
    "externalBin": ["binaries/ffmpeg"]
  }
}
```

Place platform-specific binaries at:
- `src-tauri/binaries/ffmpeg-x86_64-pc-windows-msvc.exe`
- `src-tauri/binaries/ffmpeg-x86_64-apple-darwin`
- `src-tauri/binaries/ffmpeg-x86_64-unknown-linux-gnu`

```typescript
import { Command } from '@tauri-apps/plugin-shell';
const output = await Command.sidecar('binaries/ffmpeg', ['-version']).execute();
```

---

## Embedded Server

Run a local HTTP server inside your Tauri app for scenarios like serving media, hosting a local API, or communicating with other local processes.

```rust
use std::sync::Arc;
use tauri::Manager;
use tokio::sync::oneshot;

#[tauri::command]
async fn start_server(app: tauri::AppHandle) -> Result<u16, String> {
    let (tx, rx) = oneshot::channel::<u16>();

    tauri::async_runtime::spawn(async move {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        tx.send(port).unwrap();

        let app = axum::Router::new()
            .route("/api/health", axum::routing::get(|| async { "OK" }))
            .route(
                "/api/data",
                axum::routing::get(|| async {
                    axum::Json(serde_json::json!({"status": "running"}))
                }),
            );

        axum::serve(listener, app).await.unwrap();
    });

    let port = rx.await.map_err(|e| e.to_string())?;
    Ok(port)
}
```

**Cargo.toml additions:**
```toml
[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
```

---

## Tauri v2 Mobile Support

Tauri v2 supports iOS and Android alongside desktop platforms.

### Initializing Mobile

```bash
# Add mobile targets to existing project
npm run tauri android init
npm run tauri ios init

# Development
npm run tauri android dev
npm run tauri ios dev

# Build
npm run tauri android build
npm run tauri ios build
```

### Mobile Entry Point

```rust
// src-tauri/src/lib.rs

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![greet])
        .run(tauri::generate_context!())
        .expect("error running app");
}
```

The `#[cfg_attr(mobile, tauri::mobile_entry_point)]` attribute generates the proper entry points for iOS/Android.

### Platform-Specific Capabilities

```json
{
  "identifier": "mobile-capability",
  "windows": ["main"],
  "platforms": ["iOS", "android"],
  "permissions": [
    "core:default",
    "notification:default",
    "haptics:default"
  ]
}
```

### Mobile-Specific Considerations

- **No system tray** on mobile — use push notifications instead.
- **No global shortcuts** on mobile.
- **File system** paths differ — always use `app.path()` APIs, never hardcode paths.
- **Webview** is WKWebView on iOS, Android WebView on Android.
- Some plugins have mobile support flags; check plugin docs.
- Use `#[cfg(mobile)]` and `#[cfg(desktop)]` for conditional compilation.

```rust
#[tauri::command]
fn get_platform_features() -> Vec<String> {
    let mut features = vec!["core".to_string()];

    #[cfg(desktop)]
    {
        features.push("system-tray".to_string());
        features.push("global-shortcuts".to_string());
        features.push("multi-window".to_string());
    }

    #[cfg(mobile)]
    {
        features.push("haptics".to_string());
        features.push("push-notifications".to_string());
    }

    features
}
```

### Responsive UI Tips

```typescript
import { platform } from '@tauri-apps/plugin-os';

const os = await platform();
const isMobile = os === 'ios' || os === 'android';

// Adjust UI based on platform
if (isMobile) {
    document.body.classList.add('mobile');
    // Use larger touch targets, different navigation patterns
}
```
