---
name: wasm-patterns
description:
  positive: "Use when user works with WebAssembly, asks about Wasm modules, WASI, wasm-bindgen, Emscripten, WASM component model, or integrating Rust/C/Go compiled to WebAssembly."
  negative: "Do NOT use for JavaScript performance (without Wasm), browser APIs, or server-side JavaScript runtimes (use deno-patterns or node-streams skills)."
---

# WebAssembly Patterns

## Wasm Fundamentals

Wasm is a stack-based virtual machine with a compact binary format (`.wasm`). Every module contains:

- **Types** — function signatures (`(param i32 i32) (result i32)`)
- **Functions** — executable code referencing type signatures
- **Linear memory** — contiguous, resizable byte array shared between Wasm and host
- **Tables** — typed arrays of references (used for indirect function calls)
- **Imports/Exports** — entities provided by or exposed to the host

Wasm supports `i32`, `i64`, `f32`, `f64`, `v128` (SIMD), `funcref`, and `externref`. All higher-level types (strings, structs, arrays) require encoding into linear memory.

Linear memory is a single contiguous `ArrayBuffer` accessible from both Wasm and JS. Grow with `memory.grow`. Access from JS via `WebAssembly.Memory.buffer`. Memory is zero-initialized and bounds-checked.

---

## Rust + Wasm

### Project Setup with wasm-pack

```bash
cargo install wasm-pack
wasm-pack new my-wasm-lib
cd my-wasm-lib
wasm-pack build --target web --release
```

### Cargo.toml Configuration

```toml
[lib]
crate-type = ["cdylib"]

[dependencies]
wasm-bindgen = "0.2"
web-sys = { version = "0.3", features = ["console", "Window", "Document"] }
js-sys = "0.3"

[profile.release]
lto = true
opt-level = "z"       # optimize for size; use "3" for speed
codegen-units = 1
strip = true
```

### wasm-bindgen Exports

```rust
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn fibonacci(n: u32) -> u32 {
    match n {
        0 => 0,
        1 => 1,
        _ => {
            let (mut a, mut b) = (0u32, 1u32);
            for _ in 2..=n {
                let tmp = b;
                b = a + b;
                a = tmp;
            }
            b
        }
    }
}
```

### Passing Complex Data

Pass slices for zero-copy interop. Avoid `String` on hot paths—use `&[u8]` instead:

```rust
#[wasm_bindgen]
pub fn invert_image(data: &mut [u8]) {
    for pixel in data.chunks_exact_mut(4) {
        pixel[0] = 255 - pixel[0];
        pixel[1] = 255 - pixel[1];
        pixel[2] = 255 - pixel[2];
    }
}
```

### web-sys and js-sys

Use `web-sys` for DOM/browser API bindings. Use `js-sys` for JS built-in objects. Enable only needed `features` in `Cargo.toml` to minimize binary size.

### Build Targets

| Target                       | Use Case                          |
|------------------------------|-----------------------------------|
| `wasm32-unknown-unknown`     | Browser via wasm-bindgen          |
| `wasm32-wasip1`              | WASI Preview 1 (CLI, server)     |
| `wasm32-wasip2`              | WASI Preview 2 (Component Model) |

---

## C/C++ + Emscripten

### Basic Compilation

```bash
# Install: git clone https://github.com/emscripten-core/emsdk && ./emsdk install latest
emcc src/main.c -o output.js -O3 -s MODULARIZE=1 -s EXPORT_ES6=1 \
  -s EXPORTED_FUNCTIONS='["_process_data","_malloc","_free"]' \
  -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap"]'
```

### EM_JS for Inline JS Bindings

```c
#include <emscripten.h>

EM_JS(void, js_log, (const char* msg), {
    console.log(UTF8ToString(msg));
});

void process() {
    js_log("Processing from C");
}
```

### Pthreads

Enable with `-pthread -s USE_PTHREADS=1 -s PTHREAD_POOL_SIZE=4`. Requires COOP/COEP headers (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`). Re-use threads via pools—thread startup is slower than native.

### Key Flags

| Flag                     | Purpose                                   |
|--------------------------|-------------------------------------------|
| `-O3`                    | Maximum speed optimization                |
| `-Oz`                    | Maximum size optimization                 |
| `-s MODULARIZE=1`        | Wrap output as ES module factory          |
| `-s ALLOW_MEMORY_GROWTH` | Enable dynamic memory growth              |
| `-s INITIAL_MEMORY=32MB` | Set initial linear memory                 |
| `-g4 --source-map`       | Debug build with source maps              |
| `-s FILESYSTEM=0`        | Disable virtual FS (reduces binary size)  |

### Main Loop

Never use blocking `while(1)` in `main()`. Use `emscripten_set_main_loop(callback, fps, simulate_infinite_loop)` to yield to the browser event loop.

---

## Go + Wasm

### Standard Go

```bash
GOOS=js GOARCH=wasm go build -o main.wasm
# Copy wasm_exec.js from $(go env GOROOT)/misc/wasm/
```

```go
package main

import "syscall/js"

func add(this js.Value, args []js.Value) interface{} {
    return args[0].Int() + args[1].Int()
}

func main() {
    js.Global().Set("goAdd", js.FuncOf(add))
    select {} // keep alive
}
```

### TinyGo

Standard Go produces large binaries (2+ MB minimum). Use TinyGo for size-critical deployments (`tinygo build -o main.wasm -target wasm ./main.go`). TinyGo output is typically 50–200 KB.

---

## WASI (WebAssembly System Interface)

### Overview

WASI provides portable system-level APIs for Wasm outside the browser. Capability-based security model—modules declare required permissions; hosts grant them explicitly.

### WASI Preview 2 Interfaces

| Interface          | Capability                        |
|--------------------|-----------------------------------|
| `wasi:filesystem`  | File and directory access         |
| `wasi:sockets`     | TCP/UDP networking                |
| `wasi:clocks`      | Monotonic and wall clocks         |
| `wasi:random`      | Cryptographic random numbers      |
| `wasi:http`        | Outbound HTTP requests            |
| `wasi:cli`         | Args, env vars, stdio, exit codes |

### Running a WASI Module

```bash
cargo build --target wasm32-wasip1 --release
wasmtime target/wasm32-wasip1/release/myapp.wasm --dir ./data
wasmtime --dir /tmp::./sandbox --env KEY=val module.wasm
```

Preview 2 is the current stable target built on the Component Model and WIT. Preview 3 (expected 2025) adds standardized async I/O.

---

## Component Model

### WIT (WebAssembly Interface Types)

WIT is the IDL for defining component interfaces. It separates contract from implementation:

```wit
package my:image-processor;

interface processor {
    record image {
        width: u32,
        height: u32,
        data: list<u8>,
    }

    grayscale: func(img: image) -> image;
    resize: func(img: image, w: u32, h: u32) -> image;
}

world image-app {
    import wasi:logging/logging;
    export processor;
}
```

### Building Components

Use `cargo-component` for Rust:

```bash
cargo install cargo-component
cargo component new my-component --lib
cargo component build --release
```

Use `jco` for JavaScript/TypeScript components:

```bash
npm install -g @bytecodealliance/jco
jco componentize app.js --wit wit/ -o component.wasm
```

### Composition

Compose multiple components into a single module with `wasm-tools compose app.wasm -d db-adapter.wasm -o composed.wasm`. Components are language-agnostic—compose Rust, Go, JS, and Python together.

---

## Browser Integration

### Loading and Instantiation

```javascript
// Preferred: streaming compilation
const { instance } = await WebAssembly.instantiateStreaming(
  fetch('/module.wasm'),
  importObject
);
const result = instance.exports.fibonacci(42);

// Access linear memory from JS
const memory = instance.exports.memory;
const view = new Uint8Array(memory.buffer);
```

### Web Workers for Heavy Computation

Offload compute to avoid blocking the main thread:

```javascript
// worker.js
import init, { process_frame } from './pkg/my_wasm.js';

self.onmessage = async ({ data }) => {
  await init();
  const result = process_frame(data.pixels);
  self.postMessage(result, [result.buffer]);
};
```

### Memory Management

- Call `memory.grow()` sparingly—it invalidates existing `ArrayBuffer` views
- Re-read `memory.buffer` after any potential growth
- Free Wasm-allocated memory when done if the module exposes a dealloc function

---

## JS ↔ Wasm Interop

### Passing Strings

```javascript
// JS → Wasm: encode string into linear memory
const encoder = new TextEncoder();
const bytes = encoder.encode("hello");
const ptr = instance.exports.alloc(bytes.length);
new Uint8Array(instance.exports.memory.buffer, ptr, bytes.length).set(bytes);
instance.exports.process_string(ptr, bytes.length);
instance.exports.dealloc(ptr, bytes.length);
```

### Passing Typed Arrays

```javascript
// Zero-copy via shared memory view
const wasmMemory = new Float32Array(instance.exports.memory.buffer);
wasmMemory.set(myFloatArray, offset / 4);
instance.exports.process_floats(offset, myFloatArray.length);
```

### Callbacks from Wasm to JS

```rust
#[wasm_bindgen]
extern "C" {
    fn on_progress(percent: f64);
}

#[wasm_bindgen]
pub fn long_task(data: &[u8]) {
    for (i, chunk) in data.chunks(1024).enumerate() {
        process_chunk(chunk);
        on_progress(i as f64 / (data.len() as f64 / 1024.0));
    }
}
```

### Async Interop (Rust)

```rust
use wasm_bindgen_futures::JsFuture;

#[wasm_bindgen]
pub async fn fetch_data(url: &str) -> Result<JsValue, JsValue> {
    let window = web_sys::window().unwrap();
    let resp: web_sys::Response = JsFuture::from(window.fetch_with_str(url)).await?.into();
    let json = JsFuture::from(resp.json()?).await?;
    Ok(json)
}
```

---

## Server-Side Wasm

### Runtimes

| Runtime    | Strengths                                    |
|------------|----------------------------------------------|
| Wasmtime   | Bytecode Alliance, WASI 0.2+, Component Model, production-grade |
| Wasmer     | Broad language support, plugin systems, Wasmer Edge |
| WasmEdge   | AI/ML inference, WASI-NN, Kubernetes integration |

### Frameworks and Platforms

| Platform        | Model                              |
|-----------------|------------------------------------|
| Spin (Fermyon)  | Serverless functions, HTTP/Redis triggers, KV/SQLite stores |
| Fastly Compute  | Edge compute, sub-millisecond cold starts |
| Cloudflare Workers | Edge functions with Wasm support  |
| SpinKube        | Spin on Kubernetes at scale        |

### Spin Example (Rust)

```rust
use spin_sdk::http::{IntoResponse, Request, Response};
use spin_sdk::http_component;

#[http_component]
fn handle_request(req: Request) -> anyhow::Result<impl IntoResponse> {
    Ok(Response::builder()
        .status(200)
        .header("content-type", "application/json")
        .body(r#"{"status":"ok"}"#)
        .build())
}
```

Deploy: `spin build && spin deploy`. Wasm modules instantiate in <1 ms vs 50–500 ms for containers, making Wasm ideal for serverless, edge, and scale-to-zero.

---

## Use Cases

Wasm excels at: **image processing** (SIMD pixel manipulation), **cryptography** (constant-time, portable), **game engines** (deterministic, shared browser/server codebase), **PDF rendering** (port C/C++ libs like PDFium), **ML inference** (ONNX/TFLite via WASI-NN), **audio/video codecs** (real-time, no native plugins), and **CAD/3D modeling** (desktop-class tools in browser).

---

## Performance

### Optimization Checklist

Build in release mode with LTO (`lto = true`). Run `wasm-opt -O3 module.wasm -o optimized.wasm` on every release artifact. Use `opt-level = "z"` for size or `"3"` for speed. Set `codegen-units = 1` and `strip = true` in release profiles.

### SIMD

Use Wasm SIMD for data-parallel workloads (4x–10x speedup). In Rust, use `std::arch::wasm32::*` intrinsics. In C/C++, use `EMSCRIPTEN_SIMD128`. Always profile scalar vs SIMD to verify benefit.

### Memory Allocation

Preallocate fixed-size buffers on the stack in hot paths. Use arena allocators for batch allocations. Consider `#![no_std]` with a custom allocator for minimal binaries.

### Startup Time

Use `WebAssembly.compileStreaming()` to compile while downloading. Cache compiled modules in IndexedDB. Split large modules into lazy-loaded chunks.

---

## Debugging

### Source Maps and DWARF

Build with debug info for source-level debugging:

```bash
wasm-pack build --dev                                          # Rust
emcc -g4 --source-map-base http://localhost:8080/ -o out.js in.c  # Emscripten
```

Wasmtime and Chrome DevTools support DWARF debug info in `.wasm` files. Chrome's C/C++ DevTools extension provides source-level stepping.

### Chrome DevTools

Open Sources panel to find `.wasm` files. Set breakpoints in Wasm text format or source-mapped code. Use the Performance tab for profiling and Memory tab for linear memory inspection.

Use `wasm-opt --print` to disassemble and inspect binaries. Use `wasm-opt --strip-debug` for production.

---

## Tooling

| Tool             | Purpose                                           |
|------------------|---------------------------------------------------|
| `wasm-pack`      | Build Rust→Wasm packages with JS bindings         |
| `wasm-opt`       | Optimize/shrink `.wasm` binaries (Binaryen)       |
| `wasm-tools`     | Parse, validate, compose, strip Wasm modules      |
| `wit-bindgen`    | Generate language bindings from WIT definitions    |
| `cargo-component`| Build Wasm components from Rust with WIT           |
| `jco`            | JavaScript component toolchain (transpile, componentize) |
| `wasm-bindgen`   | Rust↔JS glue code generator                       |
| `twiggy`         | Code size profiler for `.wasm` binaries            |
| `wasm2wat`/`wat2wasm` | Convert between binary and text formats       |

---

## Anti-Patterns

### Shipping Unoptimized Binaries

Always run `wasm-opt` on release builds. Omitting it leaves 30–50% of performance and size gains on the table. Never ship debug builds to production.

### Excessive JS↔Wasm Boundary Crossings

Each call across the boundary has overhead. Batch work into single Wasm calls instead of calling per-pixel or per-element:

```javascript
// BAD: call per pixel
for (let i = 0; i < pixels.length; i++) {
  instance.exports.process_pixel(pixels[i]);
}

// GOOD: pass entire buffer
const ptr = instance.exports.alloc(pixels.length);
new Uint8Array(memory.buffer, ptr, pixels.length).set(pixels);
instance.exports.process_all_pixels(ptr, pixels.length);
instance.exports.dealloc(ptr, pixels.length);
```

### Large Binary Sizes

Enable LTO and `opt-level = "z"`. Use `#[wasm_bindgen]` only on functions that need JS exposure. Audit dependencies with `twiggy top module.wasm`. Avoid pulling in `std::fmt` machinery unnecessarily (each `format!` adds ~10 KB). Use `wee_alloc` or `dlmalloc` instead of the default allocator.

### Using Wasm for Everything

Wasm is not faster than JS for DOM manipulation, simple CRUD, or string-heavy operations. Profile before porting. Wasm excels at compute-bound, data-parallel, and algorithmic workloads.

### Memory View Invalidation

After `memory.grow()` or any call that might grow memory, existing `TypedArray` views are detached. Always re-read `memory.buffer` after such calls.

### Blocking the Main Thread

Run heavy Wasm computation in Web Workers. Never call long-running Wasm functions on the main thread.
