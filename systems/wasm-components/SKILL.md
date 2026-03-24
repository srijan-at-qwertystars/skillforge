---
name: wasm-components
description: >
  USE when: writing WebAssembly modules or components, compiling Rust/Go/C/C++ to WASM,
  using wasm-pack or wasm-bindgen or cargo-component or wit-bindgen, targeting wasm32-unknown-unknown
  or wasm32-wasi or wasm32-wasip1 or wasm32-wasip2, writing WIT interfaces or worlds,
  working with WASI preview 1 or preview 2, using Wasmtime or Wasmer or WasmEdge or Spin,
  building Component Model components, using Emscripten or WASI SDK, running WASM in browsers
  or Node.js, using TinyGo for WASM, packaging WASM as OCI artifacts, using Docker with WASM,
  writing AssemblyScript, doing JS-WASM interop, WASM SIMD or threads.
  DO NOT USE when: writing plain JavaScript without WASM, building native binaries,
  working with Docker containers without WASM runtimes, general Rust/Go/C development
  not targeting WebAssembly.
---

# WebAssembly Components — Skill Reference

## Core Concepts

WebAssembly (WASM) is a portable binary instruction format. Key primitives:

- **Module**: compiled `.wasm` binary containing code, data, metadata. Stateless template.
- **Instance**: runtime instantiation of a module with resolved imports and allocated memory.
- **Linear Memory**: contiguous, byte-addressable, resizable buffer. Grows in 64KiB pages. Max 4GiB (32-bit).
- **Table**: typed array of opaque references (primarily `funcref`). Enables indirect calls.
- **Imports/Exports**: modules declare imports (functions, memory, tables, globals) and exports. Host provides imports at instantiation.
- **Globals**: typed mutable or immutable global variables.
- **Value types**: `i32`, `i64`, `f32`, `f64`, `v128` (SIMD), `funcref`, `externref`.

Validate a module before instantiation:
```javascript
const valid = WebAssembly.validate(bytes); // returns boolean
```

## WASI (WebAssembly System Interface)

WASI provides POSIX-like capabilities to WASM modules outside browsers.

### Preview 1 (wasip1)
- Stable, widely supported. Function-based ABI with `fd_read`, `fd_write`, `path_open`, `clock_time_get`, etc.
- Target: `wasm32-wasi` or `wasm32-wasip1`.
- Capability-based security: host grants specific file descriptors/directories.
- Run with: `wasmtime run app.wasm`, `wasmer run app.wasm`.

### Preview 2 (wasip2 / WASI 0.2)
- Released January 2024. Built on the Component Model and WIT.
- Modular interfaces: `wasi-cli`, `wasi-filesystem`, `wasi-sockets`, `wasi-http`, `wasi-clocks`, `wasi-random`.
- Target: `wasm32-wasip2`.
- Components (not raw modules) — use `wasm-tools component new` to wrap a core module.
- Preview 3 (WASI 0.3) in development: native async with `stream<T>` and `future<T>` types.

## Component Model

The Component Model enables language-agnostic, composable WASM components.

### WIT (WebAssembly Interface Types)
WIT is the IDL for defining component interfaces. Define in `.wit` files:

```wit
// wit/world.wit
package my:calculator@1.0.0;

interface math {
  add: func(a: s32, b: s32) -> s32;
  multiply: func(a: s32, b: s32) -> s32;
}

world calculator {
  export math;
}
```

WIT types: `bool`, `u8`–`u64`, `s8`–`s64`, `f32`, `f64`, `char`, `string`, `list<T>`, `option<T>`, `result<T, E>`, `tuple<T...>`, `record`, `variant`, `enum`, `flags`, `resource`.

### Interfaces
Group related functions and types. A component imports or exports interfaces.

### Worlds
A world is a contract: the complete set of imports and exports for a component. Target a world when building.

### Composition
Combine multiple components by wiring exports to imports:
```bash
# Compose two components
wasm-tools compose app.wasm --definitions math-impl.wasm -o composed.wasm
```

### Key tools
- `wasm-tools`: inspect, validate, compose, convert modules ↔ components.
- `wit-bindgen`: generate language bindings from WIT.
- `wac`: declarative component composition CLI.

```bash
cargo install wasm-tools
wasm-tools component wit my-component.wasm    # extract WIT from component
wasm-tools validate my-component.wasm         # validate component
wasm-tools component new core.wasm -o component.wasm  # wrap module as component
```

## Rust → WASM

### Browser target (wasm-pack + wasm-bindgen)
```toml
# Cargo.toml
[lib]
crate-type = ["cdylib"]

[dependencies]
wasm-bindgen = "0.2"

[profile.release]
opt-level = "s"    # optimize for size
lto = true
```

```rust
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn fibonacci(n: u32) -> u32 {
    match n {
        0 => 0,
        1 => 1,
        _ => fibonacci(n - 1) + fibonacci(n - 2),
    }
}
```

```bash
wasm-pack build --target web       # produces pkg/ with .wasm + JS glue
wasm-pack build --target bundler   # for webpack/rollup
wasm-pack build --target nodejs    # for Node.js
```

### WASI target
```bash
rustup target add wasm32-wasip1
cargo build --target wasm32-wasip1 --release
wasmtime run target/wasm32-wasip1/release/app.wasm
```

### Component Model (cargo-component)
```bash
cargo install cargo-component
cargo component new my-component --lib
# Edit wit/world.wit, implement in src/lib.rs
cargo component build --release
```

```rust
// src/lib.rs — implements a WIT world
mod bindings;
use bindings::exports::my::calculator::math::Guest;

struct Component;

impl Guest for Component {
    fn add(a: i32, b: i32) -> i32 { a + b }
    fn multiply(a: i32, b: i32) -> i32 { a * b }
}
bindings::export!(Component with_types_in bindings);
```

**Output**: `target/wasm32-wasip1/release/my_component.wasm` — a valid component.

### Size optimization
```toml
[profile.release]
opt-level = "z"
lto = true
strip = true
codegen-units = 1
panic = "abort"
```
Then run `wasm-opt -Oz -o opt.wasm input.wasm` (from binaryen).

## Go → WASM

### Standard Go (browser only)
```bash
GOOS=js GOARCH=wasm go build -o app.wasm main.go
```
Copy `$(go env GOROOT)/misc/wasm/wasm_exec.js` to serve alongside. No WASI support in standard Go.

### TinyGo (recommended)
```bash
# Browser
tinygo build -o app.wasm -target=wasm ./main.go
# WASI Preview 1
tinygo build -o app.wasm -target=wasip1 ./main.go
# WASI Preview 2 (Component Model)
tinygo build -o app.wasm -target=wasip2 ./main.go
```

TinyGo produces much smaller binaries (100KB–500KB vs 2MB+). Limited stdlib (no full reflection). Use TinyGo's `wasm_exec.js` for browser — must match TinyGo version.

### Go Component Model
Use `wit-bindgen-go` to generate bindings from WIT, then build with TinyGo targeting `wasip2`.

## C/C++ → WASM

### Emscripten (browser-focused)
```bash
# Install
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk && ./emsdk install latest && ./emsdk activate latest
source ./emsdk_env.sh

# Compile
emcc hello.c -o hello.html                    # HTML + JS + WASM
emcc hello.c -o hello.js                      # JS + WASM
emcc lib.c -o lib.wasm -s STANDALONE_WASM     # standalone WASM
emcc -O3 -s WASM=1 -s EXPORTED_FUNCTIONS='["_add"]' lib.c -o lib.js
```

Export functions: use `EMSCRIPTEN_KEEPALIVE` macro or `-s EXPORTED_FUNCTIONS` flag.

### WASI SDK (server-side)
```bash
# Install WASI SDK from https://github.com/WebAssembly/wasi-sdk
export WASI_SDK_PATH=/opt/wasi-sdk

$WASI_SDK_PATH/bin/clang --sysroot=$WASI_SDK_PATH/share/wasi-sysroot \
  -O2 -o app.wasm app.c

wasmtime run app.wasm
```

Optimization flags: `-O2` (balanced), `-O3` (speed), `-Os`/`-Oz` (size), `-flto` (LTO).

## AssemblyScript

TypeScript-like language compiling directly to WASM:
```bash
npm init assemblyscript my-module
cd my-module && npm run asbuild
```

```typescript
// assembly/index.ts
export function add(a: i32, b: i32): i32 {
  return a + b;
}
```

```bash
npx asc assembly/index.ts -o build/module.wasm --optimize
```

Produces small, optimized WASM. No GC needed. Types map directly to WASM types.

## JavaScript Interop

### Browser: Loading and Instantiating
```javascript
// Streaming compilation (preferred — compiles while downloading)
const { instance } = await WebAssembly.instantiateStreaming(
  fetch("module.wasm"),
  importObject
);
const result = instance.exports.add(2, 3); // => 5

// Alternative: fetch + instantiate
const response = await fetch("module.wasm");
const bytes = await response.arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, importObject);
```

### Import Object
```javascript
const memory = new WebAssembly.Memory({ initial: 1, maximum: 10 }); // pages of 64KiB
const importObject = {
  env: {
    memory,
    log_i32: (value) => console.log("WASM says:", value),
    abort: () => { throw new Error("WASM abort"); },
  },
  wasi_snapshot_preview1: { /* WASI functions if needed */ },
};
```

### Linear Memory Access
```javascript
// Read a string from WASM memory
function readString(instance, ptr, len) {
  const memory = new Uint8Array(instance.exports.memory.buffer);
  const bytes = memory.slice(ptr, ptr + len);
  return new TextDecoder().decode(bytes);
}

// Write data into WASM memory
function writeBytes(instance, ptr, data) {
  const memory = new Uint8Array(instance.exports.memory.buffer);
  memory.set(data, ptr);
}
```

**Caution**: `memory.buffer` may change after `memory.grow()`. Always re-read the buffer reference after potential growth.

### Web Workers
```javascript
// worker.js — run WASM off the main thread
const { instance } = await WebAssembly.instantiateStreaming(fetch("heavy.wasm"));
self.onmessage = (e) => {
  const result = instance.exports.compute(e.data);
  self.postMessage(result);
};
```

Use `SharedArrayBuffer` + `Atomics` for shared WASM memory between workers (requires COOP/COEP headers).

## Server-Side WASM Runtimes

| Runtime    | Language | Key strengths                              | WASI P2 | Component Model |
|------------|----------|--------------------------------------------|---------|-----------------|
| Wasmtime   | Rust     | Reference impl, full spec compliance, AOT  | ✅      | ✅              |
| Wasmer     | Rust     | Embeddable, multi-backend (Cranelift/LLVM) | ✅      | Partial         |
| WasmEdge   | C++      | High perf, AI/networking extensions, edge  | ✅      | ✅              |
| wazero     | Go       | Zero-dependency pure Go, fast startup      | P1 only | ❌              |
| Spin       | Rust     | Serverless framework by Fermyon, HTTP      | ✅      | ✅              |
| wasmCloud  | Rust     | Distributed, capability-based, lattice     | ✅      | ✅              |

```bash
# Wasmtime
wasmtime run --wasi cli app.wasm
wasmtime compile app.wasm -o app.cwasm   # AOT compile for faster startup

# Wasmer
wasmer run app.wasm
wasmer compile app.wasm -o app.wasmu     # universal binary

# WasmEdge
wasmedge run app.wasm

# Spin
spin new http-rust my-app && cd my-app
spin build && spin up                    # local dev server on :3000
```

## WASM in Containers

### containerd + runwasi shims
```bash
# Run WASM via Docker with containerd shim
docker run --runtime=io.containerd.wasmtime.v1 \
  --platform=wasi/wasm my-wasm-image:latest

# Available shims: wasmtime, wasmedge, wasmer, spin
docker run --runtime=io.containerd.spin.v2 \
  --platform=wasi/wasm my-spin-app:latest
```

### Docker Compose
```yaml
services:
  wasm-app:
    image: my-registry/wasm-app:latest
    platform: wasi/wasm
    runtime: io.containerd.wasmtime.v1
```

### Kubernetes
Deploy via SpinKube operator with `containerd-shim-spin`. WASM pods start in <1ms.

### Building OCI images
```dockerfile
FROM scratch
COPY app.wasm /app.wasm
ENTRYPOINT ["/app.wasm"]
```
Build: `docker buildx build --platform=wasi/wasm -t myregistry/app:latest .`

## Performance

### AOT Compilation
Pre-compile for near-zero cold start: `wasmtime compile module.wasm -o module.cwasm`.

### Memory Management
- Pre-allocate memory: `new WebAssembly.Memory({ initial: 256 })` (16MiB).
- Minimize `memory.grow()` — may invalidate buffer references. Use arena allocators in guest code.
- For Rust: `wee_alloc` for smaller allocator (~1KB vs ~10KB dlmalloc).

### SIMD
Enable 128-bit SIMD in Rust: `RUSTFLAGS="-C target-feature=+simd128"`. Emscripten: `emcc -msimd128`.

### Threads
Requires `SharedArrayBuffer` (COOP/COEP headers). Rust: `RUSTFLAGS="-C target-feature=+atomics,+bulk-memory,+mutable-globals"`.

### Profiling
- Chrome DevTools Performance tab. `wasmtime run --profile=perfmap` for perf. `twiggy top module.wasm` for size analysis.

## Networking in WASM

### WASI HTTP (wasi-http)
Component Model interface for HTTP handlers. Spin and wasmCloud implement it natively. Define handlers via `wasi:http/incoming-handler` world.

### WASI Sockets
Preview 2 includes `wasi:sockets/tcp` and `wasi:sockets/udp`. Support varies by runtime.

### Browser Networking
Use JS interop: call `fetch()` via imported functions or wasm-bindgen's `web_sys::window().fetch()`.

## Package Management

### Warg (WebAssembly Registry)
Federated protocol by Bytecode Alliance for publishing WASM components:
```bash
cargo install wkg
wkg publish my:package@1.0.0 --file component.wasm
wkg get my:package@1.0.0
```

Cryptographically verifiable log. Content stored in OCI registries or blob stores.

### OCI Artifacts
Distribute WASM as OCI artifacts using standard container registries:
```bash
# Push with ORAS
oras push ghcr.io/myorg/mymodule:v1 app.wasm:application/wasm

# Push with wasm-to-oci
wasm-to-oci push app.wasm ghcr.io/myorg/mymodule:v1
```

Works with GitHub Container Registry, Azure CR, Docker Hub, any OCI-compliant registry.

## Testing WASM Modules

### Rust
```bash
# Unit tests run natively, not in WASM
cargo test

# Run tests in WASM (browser)
wasm-pack test --headless --chrome

# Run tests in WASM (Node.js)
wasm-pack test --node
```

### Integration testing with Wasmtime
```rust
use wasmtime::*;
#[test]
fn test_component() -> anyhow::Result<()> {
    let engine = Engine::default();
    let component = Component::from_file(&engine, "math.wasm")?;
    let mut store = Store::new(&engine, ());
    let instance = Linker::new(&engine).instantiate(&mut store, &component)?;
    Ok(())
}
```

### JavaScript
```javascript
// test.mjs — Node.js test
import { readFile } from "fs/promises";
import assert from "assert";

const wasm = await readFile("module.wasm");
const { instance } = await WebAssembly.instantiate(wasm);
assert.strictEqual(instance.exports.add(2, 3), 5);
assert.strictEqual(instance.exports.add(-1, 1), 0);
console.log("All tests passed");
```

### Component Model testing
Test HTTP handler components: `wasmtime serve -S cli component.wasm &` then `curl http://localhost:8080/`.

## Common Pitfalls

1. **Memory invalidation**: `WebAssembly.Memory.buffer` reference goes stale after `memory.grow()`. Always re-read `instance.exports.memory.buffer` before access.
2. **String passing**: WASM has no native string type. Pass pointer + length. Encode/decode UTF-8 at boundary. Use `TextEncoder`/`TextDecoder`.
3. **Missing imports**: instantiation fails if any import is missing. Check import names exactly match (namespaces are case-sensitive).
4. **wasm-bindgen version mismatch**: JS glue and `.wasm` must come from same build. Never mix versions.
5. **TinyGo stdlib gaps**: not all Go stdlib works. Test early. No full reflection, limited `encoding/json`.
6. **Large binary size**: enable LTO, `opt-level = "z"`, `strip = true`, `panic = "abort"` in Rust. Run `wasm-opt` from binaryen. Audit dependencies — each adds code.
7. **Blocking in async contexts**: WASM execution blocks the JS event loop. Offload heavy computation to Web Workers.
8. **CORS and MIME**: serve `.wasm` files with `application/wasm` MIME type. `instantiateStreaming` fails without it.
9. **Component vs Module confusion**: Component Model `.wasm` files are not raw core modules. Use `wasm-tools component new` to wrap, `wasm-tools print` to inspect.
10. **WASI capability model**: Preview 1 requires explicit `--dir`/`--mapdir` grants. Preview 2 uses typed capability handles.
11. **Shared memory headers**: Threads require `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`.
12. **32-bit address space**: linear memory caps at 4GiB. Memory64 proposal extends to 64-bit (not yet widely supported).

## Quick Reference: Target Matrix

| Source       | Tool              | Target                     | Output          |
|--------------|-------------------|----------------------------|-----------------|
| Rust         | cargo / wasm-pack | `wasm32-unknown-unknown`   | Browser module  |
| Rust         | cargo             | `wasm32-wasip1`            | WASI P1 module  |
| Rust         | cargo-component   | `wasm32-wasip1`            | WASI component  |
| Rust         | cargo             | `wasm32-wasip2`            | WASI P2 module  |
| Go           | go build          | `GOOS=js GOARCH=wasm`      | Browser module  |
| Go           | tinygo            | `-target=wasip1`           | WASI P1 module  |
| Go           | tinygo            | `-target=wasip2`           | WASI P2 component|
| C/C++        | emcc              | (default)                  | Browser module  |
| C/C++        | clang (WASI SDK)  | `--target=wasm32-wasi`     | WASI P1 module  |
| AssemblyScript| asc              | (default)                  | Browser module  |

## Additional Resources
