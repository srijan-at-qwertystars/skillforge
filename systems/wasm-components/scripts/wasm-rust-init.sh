#!/usr/bin/env bash
# wasm-rust-init.sh — Initialize a Rust WASM project with cargo-component for Component Model
#
# Usage: wasm-rust-init.sh <project-name> [browser|wasi]
#   project-name  Name of the project directory to create
#   target        "browser" for wasm32-unknown-unknown, "wasi" for wasip2 component (default: wasi)
#
# Prerequisites: rustup, cargo, cargo-component (for wasi target)
# Installs missing targets/tools automatically when possible.

set -euo pipefail

PROJECT_NAME="${1:?Usage: $0 <project-name> [browser|wasi]}"
TARGET="${2:-wasi}"

if [[ "$TARGET" != "browser" && "$TARGET" != "wasi" ]]; then
    echo "Error: target must be 'browser' or 'wasi', got '$TARGET'" >&2
    exit 1
fi

if ! command -v cargo &>/dev/null; then
    echo "Error: cargo not found. Install Rust: https://rustup.rs/" >&2
    exit 1
fi

echo "==> Creating Rust WASM project: $PROJECT_NAME (target: $TARGET)"

if [[ "$TARGET" == "wasi" ]]; then
    # --- WASI Component Model project ---

    if ! command -v cargo-component &>/dev/null; then
        echo "==> Installing cargo-component..."
        cargo install cargo-component
    fi

    echo "==> Adding wasm32-wasip1 target..."
    rustup target add wasm32-wasip1 2>/dev/null || true

    echo "==> Creating component project..."
    cargo component new "$PROJECT_NAME" --lib
    cd "$PROJECT_NAME"

    # Enhance the default WIT
    cat > wit/world.wit << 'WIT'
package component:$PROJECT_PLACEHOLDER;

interface api {
    /// Process input and return output
    process: func(input: string) -> result<string, string>;

    /// Get version information
    version: func() -> string;
}

world component {
    export api;
}
WIT
    sed -i "s/\$PROJECT_PLACEHOLDER/${PROJECT_NAME//-/_}/" wit/world.wit

    # Write the implementation
    cat > src/lib.rs << 'RUST'
#[allow(warnings)]
mod bindings;

use bindings::exports::component::PLACEHOLDER::api::Guest;

struct Component;

impl Guest for Component {
    fn process(input: String) -> Result<String, String> {
        if input.is_empty() {
            return Err("input must not be empty".to_string());
        }
        Ok(format!("processed: {input}"))
    }

    fn version() -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }
}

bindings::export!(Component with_types_in bindings);
RUST
    PACKAGE_NAME="${PROJECT_NAME//-/_}"
    sed -i "s/PLACEHOLDER/${PACKAGE_NAME}/" src/lib.rs

    # Add release profile optimizations
    cat >> Cargo.toml << 'TOML'

[profile.release]
opt-level = "s"
lto = true
strip = true
codegen-units = 1
panic = "abort"
TOML

    echo "==> Building component..."
    cargo component build 2>&1 | tail -3

    echo ""
    echo "✅ WASI Component Model project created: $PROJECT_NAME/"
    echo ""
    echo "  Build:   cd $PROJECT_NAME && cargo component build --release"
    echo "  Test:    cargo test"
    echo "  WIT:     wit/world.wit"
    echo "  Output:  target/wasm32-wasip1/release/${PACKAGE_NAME}.wasm"

else
    # --- Browser target with wasm-pack + wasm-bindgen ---

    echo "==> Adding wasm32-unknown-unknown target..."
    rustup target add wasm32-unknown-unknown 2>/dev/null || true

    if ! command -v wasm-pack &>/dev/null; then
        echo "==> Installing wasm-pack..."
        cargo install wasm-pack
    fi

    cargo new --lib "$PROJECT_NAME"
    cd "$PROJECT_NAME"

    # Write Cargo.toml
    cat > Cargo.toml << TOML
[package]
name = "$PROJECT_NAME"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]
wasm-bindgen = "0.2"

[dev-dependencies]
wasm-bindgen-test = "0.3"

[profile.release]
opt-level = "s"
lto = true
strip = true
codegen-units = 1
panic = "abort"
TOML

    # Write lib.rs
    cat > src/lib.rs << 'RUST'
use wasm_bindgen::prelude::*;

/// Greet someone by name
#[wasm_bindgen]
pub fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

/// Add two numbers
#[wasm_bindgen]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_greet() {
        assert_eq!(greet("World"), "Hello, World!");
    }

    #[test]
    fn test_add() {
        assert_eq!(add(2, 3), 5);
    }
}
RUST

    # Create test file
    mkdir -p tests
    cat > tests/web.rs << 'RUST'
use wasm_bindgen_test::*;

wasm_bindgen_test_configure!(run_in_browser);

#[wasm_bindgen_test]
fn test_greet() {
    let result = PLACEHOLDER::greet("WASM");
    assert_eq!(result, "Hello, WASM!");
}
RUST
    PACKAGE_NAME="${PROJECT_NAME//-/_}"
    sed -i "s/PLACEHOLDER/${PACKAGE_NAME}/" tests/web.rs

    echo "==> Building with wasm-pack..."
    wasm-pack build --target web 2>&1 | tail -3

    echo ""
    echo "✅ Browser WASM project created: $PROJECT_NAME/"
    echo ""
    echo "  Build:   cd $PROJECT_NAME && wasm-pack build --target web"
    echo "  Test:    cargo test && wasm-pack test --node"
    echo "  Output:  pkg/"
fi
