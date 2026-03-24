# Tauri v2 Plugin Development

## Table of Contents

- [Plugin Architecture Overview](#plugin-architecture-overview)
- [Creating a Plugin Project](#creating-a-plugin-project)
- [Rust Side: Plugin Core](#rust-side-plugin-core)
  - [Plugin Builder](#plugin-builder)
  - [Commands](#commands)
  - [State Management](#state-management)
  - [Events](#events)
  - [Lifecycle Hooks](#lifecycle-hooks)
- [JavaScript Side: Plugin API](#javascript-side-plugin-api)
  - [TypeScript Bindings](#typescript-bindings)
  - [Frontend API Design](#frontend-api-design)
- [Permission System](#permission-system)
  - [Defining Permissions](#defining-permissions)
  - [Default Permissions](#default-permissions)
  - [Scoped Permissions](#scoped-permissions)
  - [Permission Sets](#permission-sets)
- [Plugin Lifecycle](#plugin-lifecycle)
- [Existing Plugin Ecosystem](#existing-plugin-ecosystem)
  - [File System (fs)](#file-system-fs)
  - [HTTP Client (http)](#http-client-http)
  - [Shell](#shell)
  - [Dialog](#dialog)
  - [Notification](#notification)
  - [Updater](#updater)
  - [SQL Database](#sql-database)
  - [Store (Key-Value)](#store-key-value)
  - [Other Official Plugins](#other-official-plugins)
- [Testing Plugins](#testing-plugins)
- [Publishing Plugins](#publishing-plugins)

---

## Plugin Architecture Overview

A Tauri v2 plugin consists of two parts:

1. **Rust crate** (`tauri-plugin-<name>`) — backend logic, commands, state, OS integration
2. **JavaScript package** (`@tauri-apps/plugin-<name>` for official, or custom scope) — frontend API

```
tauri-plugin-my-plugin/
├── Cargo.toml                # Rust crate manifest
├── src/
│   ├── lib.rs                # Plugin entry point
│   ├── commands.rs           # Tauri commands
│   ├── error.rs              # Error types
│   ├── models.rs             # Data structures
│   └── desktop.rs / mobile.rs  # Platform-specific code
├── permissions/              # Permission definitions
│   ├── default.toml          # Default permission set
│   └── schemas/              # Auto-generated schemas
├── guest-js/                 # JavaScript/TypeScript source
│   ├── index.ts              # Public API
│   └── package.json          # NPM package config
├── build.rs                  # Build script for permission generation
└── README.md
```

---

## Creating a Plugin Project

### Using the CLI

```bash
# Initialize a new plugin project
npm run tauri plugin new my-plugin

# Or with cargo
cargo install tauri-cli
cargo tauri plugin new my-plugin
```

This scaffolds the full project structure with Rust crate, JS bindings, permissions, and build scripts.

### Manual Setup

**Cargo.toml:**
```toml
[package]
name = "tauri-plugin-my-plugin"
version = "0.1.0"
edition = "2021"

[dependencies]
tauri = { version = "2", default-features = false }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "1"
log = "0.4"

[build-dependencies]
tauri-plugin = { version = "2", features = ["build"] }
```

**build.rs:**
```rust
const COMMANDS: &[&str] = &["get_data", "set_data", "clear_data"];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .global_api_script_path("./api-iife.js")
        .build();
}
```

---

## Rust Side: Plugin Core

### Plugin Builder

The entry point for every plugin is the `init()` function returning a `TauriPlugin`:

```rust
use tauri::plugin::{Builder as PluginBuilder, TauriPlugin};
use tauri::{Manager, Runtime};

mod commands;
mod error;

pub use error::Error;
type Result<T> = std::result::Result<T, Error>;

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    PluginBuilder::<R, ()>::new("my-plugin")
        .invoke_handler(tauri::generate_handler![
            commands::get_data,
            commands::set_data,
            commands::clear_data,
        ])
        .setup(|app, _api| {
            // Initialize plugin state
            app.manage(PluginState::default());
            log::info!("my-plugin initialized");
            Ok(())
        })
        .on_navigation(|_window, url| {
            // Return false to block navigation
            log::debug!("Navigation to: {}", url);
            true
        })
        .on_event(|_app, event| {
            // Handle Tauri runtime events
            log::trace!("Event: {:?}", event);
        })
        .build()
}
```

### Commands

Plugin commands follow the same pattern as app commands but are namespaced:

```rust
// src/commands.rs
use tauri::{command, AppHandle, Runtime, State};

use crate::error::Error;
use crate::PluginState;

#[command]
pub async fn get_data<R: Runtime>(
    _app: AppHandle<R>,
    state: State<'_, PluginState>,
    key: String,
) -> Result<Option<String>, Error> {
    let store = state.data.lock().map_err(|_| Error::LockPoisoned)?;
    Ok(store.get(&key).cloned())
}

#[command]
pub async fn set_data<R: Runtime>(
    _app: AppHandle<R>,
    state: State<'_, PluginState>,
    key: String,
    value: String,
) -> Result<(), Error> {
    let mut store = state.data.lock().map_err(|_| Error::LockPoisoned)?;
    store.insert(key, value);
    Ok(())
}

#[command]
pub async fn clear_data<R: Runtime>(
    _app: AppHandle<R>,
    state: State<'_, PluginState>,
) -> Result<(), Error> {
    let mut store = state.data.lock().map_err(|_| Error::LockPoisoned)?;
    store.clear();
    Ok(())
}
```

### State Management

```rust
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Default)]
pub struct PluginState {
    pub data: Mutex<HashMap<String, String>>,
}

// For more complex state with configuration
pub struct ConfigurableState {
    pub config: PluginConfig,
    pub data: Mutex<HashMap<String, String>>,
}

#[derive(Default, serde::Deserialize)]
pub struct PluginConfig {
    pub max_items: Option<usize>,
    pub auto_persist: bool,
    pub storage_path: Option<String>,
}

// Plugin with configuration
pub fn init_with_config<R: Runtime>(config: PluginConfig) -> TauriPlugin<R> {
    PluginBuilder::<R, ()>::new("my-plugin")
        .setup(move |app, _api| {
            app.manage(ConfigurableState {
                config,
                data: Mutex::new(HashMap::new()),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_data,
            commands::set_data,
        ])
        .build()
}
```

### Events

Plugins can emit and listen to events:

```rust
use tauri::{Emitter, Runtime};

pub fn emit_plugin_event<R: Runtime>(
    app: &tauri::AppHandle<R>,
    event_name: &str,
    payload: impl serde::Serialize + Clone,
) -> crate::Result<()> {
    app.emit(&format!("my-plugin://{}", event_name), payload)
        .map_err(|e| crate::Error::EventEmit(e.to_string()))?;
    Ok(())
}

// Usage in a command
#[command]
pub async fn process_item<R: Runtime>(
    app: AppHandle<R>,
    item: String,
) -> Result<(), Error> {
    emit_plugin_event(&app, "processing-started", &item)?;

    // ... do work ...

    emit_plugin_event(&app, "processing-complete", serde_json::json!({
        "item": item,
        "status": "success"
    }))?;

    Ok(())
}
```

### Lifecycle Hooks

```rust
PluginBuilder::<R, ()>::new("my-plugin")
    // Called when the plugin is set up (app is starting)
    .setup(|app, api| {
        // Initialize resources, state, background tasks
        Ok(())
    })
    // Called on navigation events in any window
    .on_navigation(|window, url| {
        // Return false to block navigation
        true
    })
    // Called on window events
    .on_window_event(|window, event| {
        match event {
            tauri::WindowEvent::CloseRequested { .. } => {
                // Cleanup before window close
            }
            tauri::WindowEvent::Focused(focused) => {
                if *focused {
                    // Window gained focus
                }
            }
            _ => {}
        }
    })
    // Called on runtime events (app exit, etc.)
    .on_event(|app, event| {
        if let tauri::RunEvent::Exit = event {
            // Persist state, cleanup resources
            log::info!("Plugin shutting down");
        }
    })
    // Called when a webview is created
    .on_webview_ready(|webview| {
        log::info!("Webview ready: {}", webview.label());
    })
    // Called when the plugin is dropped
    .on_drop(|app| {
        log::info!("Plugin dropped");
    })
    .build()
```

---

## JavaScript Side: Plugin API

### TypeScript Bindings

**guest-js/index.ts:**
```typescript
import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';

// Type-safe command invocations
export async function getData(key: string): Promise<string | null> {
    return invoke<string | null>('plugin:my-plugin|get_data', { key });
}

export async function setData(key: string, value: string): Promise<void> {
    return invoke('plugin:my-plugin|set_data', { key, value });
}

export async function clearData(): Promise<void> {
    return invoke('plugin:my-plugin|clear_data');
}

// Event listeners
export async function onProcessingStarted(
    callback: (item: string) => void,
): Promise<UnlistenFn> {
    return listen<string>('my-plugin://processing-started', (event) => {
        callback(event.payload);
    });
}

export async function onProcessingComplete(
    callback: (result: { item: string; status: string }) => void,
): Promise<UnlistenFn> {
    return listen('my-plugin://processing-complete', (event) => {
        callback(event.payload as { item: string; status: string });
    });
}
```

**guest-js/package.json:**
```json
{
    "name": "tauri-plugin-my-plugin-api",
    "version": "0.1.0",
    "types": "index.d.ts",
    "main": "index.js",
    "module": "index.mjs",
    "scripts": {
        "build": "tsup src/index.ts --format esm,cjs --dts",
        "dev": "tsup src/index.ts --format esm,cjs --dts --watch"
    },
    "dependencies": {
        "@tauri-apps/api": "^2.0.0"
    },
    "devDependencies": {
        "tsup": "^8.0.0",
        "typescript": "^5.0.0"
    }
}
```

### Frontend API Design

Design a clean, ergonomic API for consumers:

```typescript
// Higher-level API wrapping raw commands

export interface PluginOptions {
    autoSync?: boolean;
    namespace?: string;
}

export class MyPluginStore {
    private namespace: string;
    private listeners: UnlistenFn[] = [];

    constructor(options: PluginOptions = {}) {
        this.namespace = options.namespace ?? 'default';
    }

    private prefixKey(key: string): string {
        return `${this.namespace}:${key}`;
    }

    async get<T>(key: string): Promise<T | null> {
        const raw = await getData(this.prefixKey(key));
        return raw ? (JSON.parse(raw) as T) : null;
    }

    async set<T>(key: string, value: T): Promise<void> {
        await setData(this.prefixKey(key), JSON.stringify(value));
    }

    async clear(): Promise<void> {
        await clearData();
    }

    async onChange(callback: (key: string, value: unknown) => void): Promise<void> {
        const unlisten = await listen('my-plugin://data-changed', (event) => {
            const { key, value } = event.payload as { key: string; value: unknown };
            callback(key, value);
        });
        this.listeners.push(unlisten);
    }

    destroy(): void {
        this.listeners.forEach((fn) => fn());
        this.listeners = [];
    }
}
```

---

## Permission System

Tauri v2 uses a capability-based permission system. Plugins must declare what permissions they offer.

### Defining Permissions

Create permission files in `permissions/`:

**permissions/get-data.toml:**
```toml
[[permission]]
identifier = "allow-get-data"
description = "Allows reading data from the plugin store"

[[permission.commands]]
name = "get_data"
```

**permissions/set-data.toml:**
```toml
[[permission]]
identifier = "allow-set-data"
description = "Allows writing data to the plugin store"

[[permission.commands]]
name = "set_data"
```

**permissions/clear-data.toml:**
```toml
[[permission]]
identifier = "allow-clear-data"
description = "Allows clearing all plugin store data"

[[permission.commands]]
name = "clear_data"
```

### Default Permissions

**permissions/default.toml:**
```toml
[default]
description = "Default permissions for my-plugin (read-only)"
permissions = ["allow-get-data"]
```

Apps using `"my-plugin:default"` get only read access. Write access must be explicitly granted.

### Scoped Permissions

For plugins that access resources (files, URLs, etc.), define scopes:

```toml
[[permission]]
identifier = "allow-scoped-read"
description = "Allows reading files within a specified scope"

[[permission.commands]]
name = "read_file"

[[permission.scope.allow]]
path = "$APPDATA/**"

[[permission.scope.deny]]
path = "$APPDATA/secrets/**"
```

**Consumer usage in capabilities:**
```json
{
    "permissions": [
        "my-plugin:default",
        "my-plugin:allow-set-data",
        {
            "identifier": "my-plugin:allow-scoped-read",
            "allow": [{ "path": "$DOCUMENT/**" }]
        }
    ]
}
```

### Permission Sets

Group permissions for common use cases:

```toml
[[set]]
identifier = "read-write"
description = "Full read/write access to the plugin store"
permissions = ["allow-get-data", "allow-set-data"]

[[set]]
identifier = "full-access"
description = "Full access including destructive operations"
permissions = ["allow-get-data", "allow-set-data", "allow-clear-data"]
```

---

## Plugin Lifecycle

### Initialization Flow

1. **`Cargo.toml` + `npm install`** — Dependencies added to host app
2. **`.plugin(my_plugin::init())`** — Plugin registered with Tauri Builder
3. **`setup()`** — Called during `tauri::Builder::build()`:
   - Plugin state initialized
   - Background tasks spawned
   - Resources acquired
4. **`on_webview_ready()`** — Called when each webview is created
5. **`on_navigation()`** — Called on every navigation in any webview
6. **`on_event()`** — Called on runtime events
7. **`on_drop()`** — Called when app exits

### Error Handling

Define plugin-specific error types:

```rust
// src/error.rs
use serde::{Serialize, Serializer};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Data not found: {0}")]
    NotFound(String),

    #[error("Lock poisoned")]
    LockPoisoned,

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Event emit error: {0}")]
    EventEmit(String),

    #[error("Tauri error: {0}")]
    Tauri(#[from] tauri::Error),
}

// Serialize errors for IPC transport
impl Serialize for Error {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.to_string().as_ref())
    }
}
```

---

## Existing Plugin Ecosystem

### File System (fs)

```bash
cargo add tauri-plugin-fs
npm install @tauri-apps/plugin-fs
```

```typescript
import { readTextFile, writeTextFile, readDir, mkdir, remove, rename, exists } from '@tauri-apps/plugin-fs';

const content = await readTextFile('/path/to/file.txt');
await writeTextFile('/path/to/output.txt', 'Hello');
const entries = await readDir('/path/to/dir');
await mkdir('/path/to/new-dir', { recursive: true });
```

**Key permissions:** `fs:default`, `fs:allow-read-text-file`, `fs:allow-write-text-file`, `fs:allow-read-dir`, `fs:scope`.

### HTTP Client (http)

```bash
cargo add tauri-plugin-http
npm install @tauri-apps/plugin-http
```

```typescript
import { fetch } from '@tauri-apps/plugin-http';

const response = await fetch('https://api.example.com/data', {
    method: 'GET',
    headers: { Authorization: 'Bearer token' },
});
const data = await response.json();

// POST with body
await fetch('https://api.example.com/submit', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key: 'value' }),
});
```

**Key permissions:** `http:default`, `http:allow-fetch`, scoped to allowed URLs.

### Shell

```bash
cargo add tauri-plugin-shell
npm install @tauri-apps/plugin-shell
```

```typescript
import { Command } from '@tauri-apps/plugin-shell';

// Pre-configured scoped command
const output = await Command.create('my-sidecar', ['--version']).execute();

// Open URL in default browser
import { open } from '@tauri-apps/plugin-shell';
await open('https://example.com');
```

**Key permissions:** `shell:default`, `shell:allow-execute`, `shell:allow-open`, scoped command definitions.

### Dialog

```bash
cargo add tauri-plugin-dialog
npm install @tauri-apps/plugin-dialog
```

```typescript
import { open, save, message, ask, confirm } from '@tauri-apps/plugin-dialog';

const file = await open({
    multiple: false,
    filters: [{ name: 'Images', extensions: ['png', 'jpg', 'gif'] }],
});

const savePath = await save({
    defaultPath: 'export.json',
    filters: [{ name: 'JSON', extensions: ['json'] }],
});

const yes = await ask('Are you sure?', { title: 'Confirm', kind: 'warning' });
await message('Operation complete!', { title: 'Success', kind: 'info' });
```

### Notification

```bash
cargo add tauri-plugin-notification
npm install @tauri-apps/plugin-notification
```

```typescript
import { sendNotification, requestPermission, isPermissionGranted } from '@tauri-apps/plugin-notification';

if (!(await isPermissionGranted())) {
    await requestPermission();
}

sendNotification({ title: 'Alert', body: 'Something happened' });
```

### Updater

```bash
cargo add tauri-plugin-updater
npm install @tauri-apps/plugin-updater
```

```typescript
import { check } from '@tauri-apps/plugin-updater';
import { relaunch } from '@tauri-apps/plugin-process';

const update = await check();
if (update) {
    await update.downloadAndInstall((event) => {
        if (event.event === 'Progress') {
            console.log(`Downloaded ${event.data.chunkLength} bytes`);
        }
    });
    await relaunch();
}
```

Requires signing keys and update endpoint configuration in `tauri.conf.json`.

### SQL Database

```bash
cargo add tauri-plugin-sql
npm install @tauri-apps/plugin-sql
```

```typescript
import Database from '@tauri-apps/plugin-sql';

// SQLite
const db = await Database.load('sqlite:app.db');

await db.execute(
    'CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)',
);

await db.execute('INSERT INTO users (name, email) VALUES ($1, $2)', [
    'Alice',
    'alice@example.com',
]);

const users = await db.select<{ id: number; name: string; email: string }[]>(
    'SELECT * FROM users WHERE name = $1',
    ['Alice'],
);
```

Supports SQLite, MySQL, and PostgreSQL.

### Store (Key-Value)

```bash
cargo add tauri-plugin-store
npm install @tauri-apps/plugin-store
```

```typescript
import { LazyStore } from '@tauri-apps/plugin-store';

const store = new LazyStore('settings.json');

await store.set('theme', 'dark');
await store.set('window-size', { width: 1024, height: 768 });

const theme = await store.get<string>('theme');
await store.save(); // Persist to disk
```

### Other Official Plugins

| Plugin | Purpose | Crate |
|--------|---------|-------|
| `clipboard-manager` | Read/write clipboard | `tauri-plugin-clipboard-manager` |
| `global-shortcut` | System-wide keyboard shortcuts | `tauri-plugin-global-shortcut` |
| `autostart` | Launch app on system boot | `tauri-plugin-autostart` |
| `log` | Structured logging | `tauri-plugin-log` |
| `os` | OS information (platform, arch, etc.) | `tauri-plugin-os` |
| `process` | Process management (exit, restart) | `tauri-plugin-process` |
| `deep-link` | Custom URL scheme handling | `tauri-plugin-deep-link` |
| `barcode-scanner` | Camera barcode scanning (mobile) | `tauri-plugin-barcode-scanner` |
| `biometric` | Fingerprint/Face ID auth (mobile) | `tauri-plugin-biometric` |
| `haptics` | Haptic feedback (mobile) | `tauri-plugin-haptics` |
| `nfc` | NFC tag reading (mobile) | `tauri-plugin-nfc` |

---

## Testing Plugins

### Unit Tests (Rust)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    fn create_test_state() -> PluginState {
        PluginState {
            data: Mutex::new(HashMap::new()),
        }
    }

    #[test]
    fn test_set_and_get() {
        let state = create_test_state();
        {
            let mut data = state.data.lock().unwrap();
            data.insert("key".to_string(), "value".to_string());
        }
        let data = state.data.lock().unwrap();
        assert_eq!(data.get("key"), Some(&"value".to_string()));
    }

    #[test]
    fn test_clear() {
        let state = create_test_state();
        {
            let mut data = state.data.lock().unwrap();
            data.insert("key".to_string(), "value".to_string());
        }
        {
            let mut data = state.data.lock().unwrap();
            data.clear();
        }
        let data = state.data.lock().unwrap();
        assert!(data.is_empty());
    }
}
```

### Integration Tests

```rust
#[cfg(test)]
mod integration_tests {
    use tauri::test::{mock_builder, mock_context, noop_assets, MockRuntime};

    fn setup_app() -> tauri::App<MockRuntime> {
        mock_builder()
            .plugin(super::init())
            .build(mock_context(noop_assets()))
            .unwrap()
    }

    #[test]
    fn test_plugin_initializes() {
        let app = setup_app();
        // Plugin state should be managed
        assert!(app.state::<super::PluginState>().data.lock().is_ok());
    }
}
```

---

## Publishing Plugins

### Preparing for Publication

1. **Choose naming convention:**
   - Rust crate: `tauri-plugin-<name>` (e.g., `tauri-plugin-analytics`)
   - NPM package: `tauri-plugin-<name>-api` or `@your-scope/tauri-plugin-<name>`

2. **Update Cargo.toml:**
```toml
[package]
name = "tauri-plugin-my-plugin"
version = "0.1.0"
authors = ["Your Name <you@example.com>"]
description = "A Tauri plugin for ..."
license = "MIT OR Apache-2.0"
repository = "https://github.com/you/tauri-plugin-my-plugin"
keywords = ["tauri", "plugin", "tauri-plugin"]
categories = ["gui", "os"]
edition = "2021"
```

3. **Write documentation:**
   - README.md with installation, usage, permissions
   - Rust doc comments on public API
   - TypeScript JSDoc on frontend API
   - Example app in `examples/` directory

4. **Publish:**
```bash
# Rust crate
cd tauri-plugin-my-plugin
cargo publish

# NPM package
cd guest-js
npm publish
```

### Plugin README Template

```markdown
# tauri-plugin-my-plugin

Description of what the plugin does.

## Installation

### Rust
```toml
[dependencies]
tauri-plugin-my-plugin = "0.1"
```

### JavaScript
```bash
npm install tauri-plugin-my-plugin-api
```

### Register Plugin
```rust
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_my_plugin::init())
        .run(tauri::generate_context!())
        .unwrap();
}
```

### Capabilities
```json
{
    "permissions": ["my-plugin:default"]
}
```

## Usage
... (code examples)

## Permissions
| Permission | Description |
|-----------|-------------|
| `my-plugin:default` | Read-only access |
| `my-plugin:allow-set-data` | Write access |
| `my-plugin:full-access` | Full access |

## License
MIT or Apache-2.0
```
