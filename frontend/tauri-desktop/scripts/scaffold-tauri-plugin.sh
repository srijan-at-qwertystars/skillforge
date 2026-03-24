#!/usr/bin/env bash
#
# scaffold-tauri-plugin.sh — Generate a new Tauri v2 plugin project structure
#
# Usage:
#   ./scaffold-tauri-plugin.sh <plugin-name> [output-dir]
#
# Examples:
#   ./scaffold-tauri-plugin.sh analytics
#   ./scaffold-tauri-plugin.sh my-plugin ./plugins
#
# Creates:
#   tauri-plugin-<name>/
#   ├── Cargo.toml
#   ├── build.rs
#   ├── src/
#   │   ├── lib.rs
#   │   ├── commands.rs
#   │   └── error.rs
#   ├── permissions/
#   │   └── default.toml
#   ├── guest-js/
#   │   ├── index.ts
#   │   └── package.json
#   └── README.md

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <plugin-name> [output-dir]"
    echo "  plugin-name: Name of the plugin (e.g., 'analytics', 'my-feature')"
    echo "  output-dir:  Directory to create plugin in (default: current directory)"
    exit 1
fi

PLUGIN_NAME="$1"
OUTPUT_DIR="${2:-.}"

# Sanitize plugin name: lowercase, hyphens only
PLUGIN_NAME=$(echo "$PLUGIN_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
CRATE_NAME="tauri-plugin-${PLUGIN_NAME}"
# Rust identifier: underscores instead of hyphens
RUST_IDENT=$(echo "$PLUGIN_NAME" | tr '-' '_')
DIR="${OUTPUT_DIR}/${CRATE_NAME}"

if [[ -d "$DIR" ]]; then
    echo "Error: Directory '$DIR' already exists."
    exit 1
fi

echo "Creating Tauri v2 plugin: ${CRATE_NAME}"

mkdir -p "$DIR"/{src,permissions,guest-js}

# --- Cargo.toml ---
cat > "$DIR/Cargo.toml" <<EOF
[package]
name = "${CRATE_NAME}"
version = "0.1.0"
edition = "2021"
description = "A Tauri v2 plugin for ${PLUGIN_NAME}"
license = "MIT OR Apache-2.0"
keywords = ["tauri", "plugin", "tauri-plugin"]

[dependencies]
tauri = { version = "2", default-features = false }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "1"
log = "0.4"

[build-dependencies]
tauri-plugin = { version = "2", features = ["build"] }
EOF

# --- build.rs ---
cat > "$DIR/build.rs" <<'EOF'
const COMMANDS: &[&str] = &["ping"];

fn main() {
    tauri_plugin::Builder::new(COMMANDS).build();
}
EOF

# --- src/error.rs ---
cat > "$DIR/src/error.rs" <<'EOF'
use serde::{Serialize, Serializer};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Tauri error: {0}")]
    Tauri(#[from] tauri::Error),

    #[error("{0}")]
    Custom(String),
}

impl Serialize for Error {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.to_string().as_ref())
    }
}
EOF

# --- src/commands.rs ---
cat > "$DIR/src/commands.rs" <<'EOF'
use tauri::{command, AppHandle, Runtime};

use crate::error::Error;

#[command]
pub async fn ping<R: Runtime>(_app: AppHandle<R>) -> Result<String, Error> {
    Ok("pong".to_string())
}
EOF

# --- src/lib.rs ---
cat > "$DIR/src/lib.rs" <<EOF
use tauri::plugin::{Builder as PluginBuilder, TauriPlugin};
use tauri::Runtime;

mod commands;
mod error;

pub use error::Error;

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    PluginBuilder::<R, ()>::new("${PLUGIN_NAME}")
        .invoke_handler(tauri::generate_handler![commands::ping])
        .setup(|_app, _api| {
            log::info!("${PLUGIN_NAME} plugin initialized");
            Ok(())
        })
        .build()
}
EOF

# --- permissions/default.toml ---
cat > "$DIR/permissions/default.toml" <<EOF
[default]
description = "Default permissions for ${PLUGIN_NAME}"
permissions = ["allow-ping"]

[[permission]]
identifier = "allow-ping"
description = "Allows the ping command"

[[permission.commands]]
name = "ping"
EOF

# --- guest-js/package.json ---
cat > "$DIR/guest-js/package.json" <<EOF
{
  "name": "${CRATE_NAME}-api",
  "version": "0.1.0",
  "description": "JavaScript API for ${CRATE_NAME}",
  "types": "index.d.ts",
  "main": "index.js",
  "module": "index.mjs",
  "scripts": {
    "build": "tsup index.ts --format esm,cjs --dts",
    "dev": "tsup index.ts --format esm,cjs --dts --watch"
  },
  "dependencies": {
    "@tauri-apps/api": "^2.0.0"
  },
  "devDependencies": {
    "tsup": "^8.0.0",
    "typescript": "^5.0.0"
  },
  "license": "MIT"
}
EOF

# --- guest-js/index.ts ---
cat > "$DIR/guest-js/index.ts" <<EOF
import { invoke } from '@tauri-apps/api/core';

export async function ping(): Promise<string> {
    return invoke<string>('plugin:${PLUGIN_NAME}|ping');
}
EOF

# --- README.md ---
cat > "$DIR/README.md" <<EOF
# ${CRATE_NAME}

A Tauri v2 plugin for ${PLUGIN_NAME}.

## Installation

\`\`\`toml
# Cargo.toml
[dependencies]
${CRATE_NAME} = "0.1"
\`\`\`

\`\`\`bash
npm install ${CRATE_NAME}-api
\`\`\`

## Setup

\`\`\`rust
fn main() {
    tauri::Builder::default()
        .plugin(${CRATE_NAME//-/_}::init())
        .run(tauri::generate_context!())
        .unwrap();
}
\`\`\`

### Capabilities

\`\`\`json
{
  "permissions": ["${PLUGIN_NAME}:default"]
}
\`\`\`

## Usage

\`\`\`typescript
import { ping } from '${CRATE_NAME}-api';
const result = await ping(); // "pong"
\`\`\`

## License

MIT or Apache-2.0
EOF

echo ""
echo "Plugin scaffolded at: $DIR"
echo ""
echo "Next steps:"
echo "  1. cd $DIR"
echo "  2. Edit src/commands.rs to add your commands"
echo "  3. Update build.rs COMMANDS list"
echo "  4. Update permissions/default.toml"
echo "  5. Update guest-js/index.ts with your JS API"
echo "  6. cargo build to verify"
