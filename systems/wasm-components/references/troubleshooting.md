# WebAssembly Troubleshooting Guide

## Table of Contents
1. [Memory Issues](#memory-issues)
2. [Stack Overflow in Recursion](#stack-overflow-in-recursion)
3. [Floating Point Determinism](#floating-point-determinism)
4. [Missing WASI Imports](#missing-wasi-imports)
5. [ABI Mismatches Between Languages](#abi-mismatches-between-languages)
6. [Slow Compilation Times](#slow-compilation-times)
7. [Debugging WASM](#debugging-wasm)
8. [wasm-bindgen Type Errors](#wasm-bindgen-type-errors)
9. [TinyGo Limitations](#tinygo-limitations)
10. [Emscripten Filesystem Issues](#emscripten-filesystem-issues)
11. [Binary Size Optimization](#binary-size-optimization)
12. [Import/Export Naming Conflicts](#importexport-naming-conflicts)

---

## Memory Issues

### 4GB Linear Memory Limit

**Symptom**: `RuntimeError: memory access out of bounds` or `RangeError: WebAssembly.Memory(): could not allocate memory`.

**Cause**: 32-bit WASM linear memory is capped at 65,536 pages × 64KiB = 4GiB.

**Solutions**:
```javascript
// Check current memory size
const pages = instance.exports.memory.buffer.byteLength / 65536;
console.log(`Memory: ${pages} pages (${pages * 64}KiB)`);

// Set appropriate initial/maximum
const memory = new WebAssembly.Memory({
  initial: 256,  // 16MiB — reasonable starting point
  maximum: 16384 // 1GiB cap — prevents runaway growth
});
```

**For large data**: Process in chunks rather than loading everything at once. Consider Memory64 proposal (experimental) for >4GiB.

**Rust**: Set memory limits in Cargo.toml:
```toml
# Limit initial memory to prevent over-allocation
[package.metadata.wasm-pack.profile.release]
wasm-opt = ["-Oz", "--initial-memory=16777216"]  # 16MiB
```

### Memory Growth Invalidation

**Symptom**: Stale data, corrupted reads after allocations.

**Cause**: `memory.grow()` may reallocate the underlying `ArrayBuffer`, invalidating all existing `TypedArray` views.

**Fix**: Always re-derive views after any call that might grow memory:
```javascript
function safeRead(instance, ptr, len) {
  // ALWAYS create a fresh view — never cache the buffer reference
  const view = new Uint8Array(instance.exports.memory.buffer);
  return view.slice(ptr, ptr + len);
}

// WRONG — buffer reference may be stale
const view = new Uint8Array(instance.exports.memory.buffer);
instance.exports.do_work(); // might call memory.grow()
const data = view.slice(0, 10); // UNDEFINED BEHAVIOR
```

### Out of Memory in Guest

**Symptom**: `unreachable` trap from allocator, or silent corruption.

**Rust fix**: Use `panic = "abort"` and implement a custom OOM handler:
```rust
#[cfg(target_arch = "wasm32")]
#[alloc_error_handler]
fn oom(_: core::alloc::Layout) -> ! {
    core::arch::wasm32::unreachable()
}
```

---

## Stack Overflow in Recursion

**Symptom**: `RuntimeError: call stack exhausted` or `RuntimeError: unreachable`.

**Cause**: WASM has a fixed-size call stack (typically 1MB, runtime-dependent). Deep recursion exhausts it.

**Solutions**:

1. **Convert to iteration**:
```rust
// BAD: recursive fibonacci
fn fib(n: u64) -> u64 {
    if n <= 1 { n } else { fib(n-1) + fib(n-2) }
}

// GOOD: iterative
fn fib(n: u64) -> u64 {
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 0..n { let t = a + b; a = b; b = t; }
    a
}
```

2. **Increase stack size** (runtime-specific):
```bash
# Wasmtime
wasmtime run --max-wasm-stack 8388608 app.wasm  # 8MB stack

# Emscripten (at compile time)
emcc -s STACK_SIZE=2097152 app.c -o app.wasm  # 2MB stack
```

3. **Use trampoline pattern** for mutual recursion:
```rust
enum Trampoline<T> {
    Done(T),
    More(Box<dyn FnOnce() -> Trampoline<T>>),
}

fn run<T>(mut t: Trampoline<T>) -> T {
    loop {
        match t {
            Trampoline::Done(v) => return v,
            Trampoline::More(f) => t = f(),
        }
    }
}
```

---

## Floating Point Determinism

**Symptom**: Different results on different platforms for the same computation.

**Cause**: WASM spec allows NaN bit patterns to be non-deterministic. `f32.min`/`f32.max` with NaN inputs may vary. Some runtimes use different rounding for edge cases.

**Solutions**:

1. **Canonicalize NaN**: Check and normalize after each operation:
```rust
fn canonical_nan_f32(x: f32) -> f32 {
    if x.is_nan() { f32::NAN } else { x }
}
```

2. **Use integer math** for determinism-critical code (fixed-point):
```rust
// Fixed-point Q16.16
type Fixed = i32;
const SCALE: i32 = 65536;
fn fixed_mul(a: Fixed, b: Fixed) -> Fixed {
    ((a as i64 * b as i64) >> 16) as i32
}
```

3. **wasm-opt canonicalization**: not yet available — must handle in guest code.

4. **Testing**: Run the same binary on multiple runtimes (Wasmtime, Wasmer, V8) to catch non-determinism early.

---

## Missing WASI Imports

**Symptom**: `LinkError: import ... is not a Function` or `Error: missing import: wasi_snapshot_preview1::fd_write`.

### Diagnosis

```bash
# List all imports
wasm-tools print module.wasm | grep '(import'

# Or use wasm-objdump
wasm-objdump -x module.wasm | grep -A 100 'Import\['
```

### Common Causes and Fixes

**Wrong target**:
```bash
# This produces a browser module — no WASI imports expected
rustup target add wasm32-unknown-unknown
# This produces a WASI module — needs WASI runtime
rustup target add wasm32-wasip1
```

**Missing WASI polyfill in browser**:
```javascript
import { WASI } from "@bjorn3/browser_wasi_shim";
const wasi = new WASI([], [], []);
const { instance } = await WebAssembly.instantiateStreaming(
  fetch("app.wasm"),
  { wasi_snapshot_preview1: wasi.wasiImport }
);
wasi.start(instance);
```

**Preview 1 vs Preview 2 mismatch**:
```bash
# Convert P1 module to P2 component with adapter
wasm-tools component new module-p1.wasm \
  --adapt wasi_snapshot_preview1.reactor.wasm \
  -o component-p2.wasm
```

**Stub missing imports** when you don't need them:
```javascript
const stubs = {
  wasi_snapshot_preview1: {
    fd_write: () => 0,
    fd_read: () => 0,
    fd_close: () => 0,
    fd_seek: () => 0,
    environ_get: () => 0,
    environ_sizes_get: () => 0,
    proc_exit: (code) => { throw new Error(`exit(${code})`); },
    clock_time_get: () => 0,
  }
};
```

---

## ABI Mismatches Between Languages

**Symptom**: Garbled data, wrong values, traps when calling between Rust and C, or between components.

### String Passing

Each language has different string representations:
- **Rust**: UTF-8, pointer + length (no null terminator)
- **C**: null-terminated byte array
- **Go**: struct with pointer + length
- **AssemblyScript**: UTF-16, with header

**Fix**: Always agree on the ABI at the boundary:
```rust
// Rust exporting for C callers
#[no_mangle]
pub extern "C" fn get_greeting() -> *const u8 {
    // Must be null-terminated for C
    b"hello\0".as_ptr()
}

// Rust exporting with length (preferred for non-C callers)
#[no_mangle]
pub extern "C" fn get_greeting_len() -> u32 { 5 }
```

### Struct Layout

```rust
// Ensure C-compatible layout
#[repr(C)]
struct Point {
    x: f64,
    y: f64,
}
```

Without `#[repr(C)]`, Rust may reorder fields. WASM doesn't have a native struct ABI — you must serialize to linear memory with agreed layout.

### Component Model Solution

Use WIT interfaces — the canonical ABI handles all type conversions:
```wit
interface api {
  greet: func(name: string) -> string;
}
```
No manual pointer/length passing needed.

---

## Slow Compilation Times

### Rust WASM Builds

**Problem**: `cargo build --target wasm32-wasip1` takes minutes.

**Fixes**:
```toml
# .cargo/config.toml — per-project

# Use cranelift (faster compile, slower code) for dev
[profile.dev]
opt-level = 0
codegen-units = 256

# Reserve heavy optimization for release only
[profile.release]
opt-level = "z"
lto = "thin"       # "thin" is much faster than "fat"
codegen-units = 1
```

```bash
# Use sccache for caching
cargo install sccache
export RUSTC_WRAPPER=sccache

# Incremental compilation (default for dev)
export CARGO_INCREMENTAL=1
```

### Emscripten Builds

```bash
# Use -O0 for dev, -O3 only for release
emcc -O0 -g app.c -o app.js          # fast compile, debuggable
emcc -O3 -flto app.c -o app.js       # slow compile, optimized
```

### wasm-opt

`wasm-opt` can be very slow on large modules:
```bash
# Skip in dev, run only for release
wasm-opt -O2 input.wasm -o output.wasm     # moderate optimization
wasm-opt -O4 input.wasm -o output.wasm     # maximum (very slow)

# Skip wasm-opt in wasm-pack dev builds
wasm-pack build --dev  # skips wasm-opt
```

---

## Debugging WASM

### Source Maps

```bash
# Rust: Generate source maps with wasm-pack
wasm-pack build --dev  # includes debug info and source maps

# Emscripten: Generate DWARF + source maps
emcc -g -gsource-map app.c -o app.js
# -g4 for maximum debug info (large output)
```

### DWARF Debug Info

```bash
# Rust: Include DWARF
cargo build --target wasm32-wasip1  # debug build includes DWARF by default

# Strip for release
wasm-tools strip --all module.wasm -o stripped.wasm

# Inspect DWARF
llvm-dwarfdump module.wasm
wasm-tools dump --section .debug_info module.wasm
```

### Browser DevTools

1. **Chrome**: Enable "WebAssembly Debugging" in DevTools experiments
   - Sources → filesystem → add folder for source maps
   - Step through WASM with C/Rust source view
   - Profile WASM in Performance tab (functions show as `wasm-function[N]`)

2. **Firefox**: Native WASM debugging in Debugger panel
   - Set breakpoints in WAT disassembly
   - Inspect linear memory in Memory tab

3. **Chrome DWARF extension** (`C/C++ DevTools Support`):
   - Install from Chrome Web Store
   - Enables variable inspection, expression evaluation in original source language

### Wasmtime Debugging

```bash
# Run with logging
WASMTIME_LOG=wasmtime=debug wasmtime run app.wasm

# Generate perf map for profiling
wasmtime run --profile=perfmap app.wasm
perf record -g -p $(pgrep wasmtime)
perf report

# GDB debugging (native debug info required)
wasmtime run -g app.wasm &
gdb -p $!
```

### Print Debugging

When all else fails, add tracing imports:
```rust
#[link(wasm_import_module = "env")]
extern "C" {
    fn trace_i32(val: i32);
    fn trace_f64(val: f64);
}
```

Provide implementations in the host:
```javascript
const imports = {
  env: {
    trace_i32: (v) => console.log(`[wasm] i32: ${v}`),
    trace_f64: (v) => console.log(`[wasm] f64: ${v}`),
  }
};
```

---

## wasm-bindgen Type Errors

### Common Errors

**`expected type ... found type ...`**:
- Ensure `wasm-bindgen` CLI version matches the crate version exactly
```bash
# Check versions
cargo tree -i wasm-bindgen
wasm-bindgen --version

# Pin to same version
cargo install wasm-bindgen-cli --version 0.2.100
```

**`cannot import ... not a function`**:
- Missing `#[wasm_bindgen]` attribute on imported function
- Misspelled JS function name

**`closure invoked recursively or after being dropped`**:
```rust
// WRONG: closure dropped when function returns
let cb = Closure::wrap(Box::new(|| {}) as Box<dyn Fn()>);
element.add_event_listener_with_callback("click", cb.as_ref().unchecked_ref());
// cb dropped here!

// FIX: forget or store statically
cb.forget(); // leak intentionally
// OR
static CALLBACKS: Lazy<Mutex<Vec<Closure<dyn Fn()>>>> = ...;
```

**`JsValue(undefined)` from expected object**:
- JS API returned undefined — add null checks
- Web API not available in current context (e.g., `window` in Worker)

### Type Mapping Reference

| Rust type | JS type | Notes |
|-----------|---------|-------|
| `bool` | `boolean` | |
| `u8`–`u32`, `i8`–`i32` | `number` | |
| `u64`, `i64` | `bigint` | Requires `--reference-types` |
| `f32`, `f64` | `number` | |
| `String` | `string` | Copied across boundary |
| `&str` | `string` | Copied |
| `Vec<u8>` | `Uint8Array` | Copied; use `js_sys::Uint8Array` for zero-copy |
| `JsValue` | `any` | Opaque handle |
| `Option<T>` | `T \| undefined` | |
| `Result<T, E>` | throws on Err | E must impl `Into<JsValue>` |

---

## TinyGo Limitations

### vs Standard Go

| Feature | Standard Go | TinyGo |
|---------|------------|--------|
| Binary size (hello world) | ~2MB | ~50KB |
| Full reflection | ✅ | ❌ (limited) |
| `encoding/json` | ✅ | Partial |
| `net/http` | ❌ (no WASI) | ❌ |
| Goroutines | ❌ (no threads) | ✅ (cooperative) |
| `cgo` | ❌ | Partial |
| `go:embed` | ❌ | ✅ |
| WASI Preview 2 | ❌ | ✅ |

### Common TinyGo Issues

**`panic: unimplemented: ...`**: Unsupported stdlib feature. Check [TinyGo package support](https://tinygo.org/docs/reference/lang-support/stdlib/).

**Large binary from `fmt.Println`**: `fmt` pulls in reflection. Use `println()` builtin instead:
```go
// BAD: pulls in fmt, reflection — adds ~200KB
fmt.Println("hello")

// GOOD: builtin, tiny
println("hello")
```

**JSON marshaling fails**: Use a TinyGo-compatible JSON library:
```go
import "github.com/valyala/fastjson"
// or manually construct JSON strings
```

**Goroutine deadlocks**: TinyGo uses cooperative scheduling in WASM. Goroutines only yield at channel operations or explicit `runtime.Gosched()`.

---

## Emscripten Filesystem Issues

### Virtual Filesystem

Emscripten bundles a virtual filesystem. Common issues:

**Files not found at runtime**:
```bash
# Embed files into the virtual FS
emcc app.c -o app.js --preload-file assets/  # async preload
emcc app.c -o app.js --embed-file config.json  # inline in JS
```

**Large preloaded files slow startup**:
```bash
# Use --preload-file for async loading (preferred for large files)
# Use --embed-file for small critical files only
emcc app.c -o app.js \
  --preload-file large-data/@/data/ \
  --embed-file small-config.json@/config.json
```

**Custom filesystem backend**:
```javascript
// Mount IDBFS for persistent browser storage
FS.mkdir('/save');
FS.mount(IDBFS, {}, '/save');
FS.syncfs(true, (err) => { /* loaded from IndexedDB */ });

// Mount WORKERFS for File API access
FS.mount(WORKERFS, { files: fileList }, '/input');
```

**MEMFS runs out of memory**: The default in-memory FS consumes linear memory. For large files, use streaming or external storage.

**Node.js filesystem access**:
```bash
emcc app.c -o app.js -lnodefs.js -s NODERAWFS=1  # direct Node.js FS access
```

---

## Binary Size Optimization

### Checklist (most to least impact)

1. **Rust release profile**:
```toml
[profile.release]
opt-level = "z"     # optimize for size
lto = true          # link-time optimization (eliminates dead code)
codegen-units = 1   # better optimization, slower compile
strip = true        # strip debug symbols
panic = "abort"     # remove unwinding code (~10-30KB savings)
```

2. **Run wasm-opt** (from binaryen):
```bash
wasm-opt -Oz --strip-debug --strip-producers -o opt.wasm input.wasm
# Typical savings: 10-30% additional reduction
```

3. **Audit dependencies**: Each crate adds code
```bash
# Analyze binary composition
cargo install twiggy
twiggy top -n 20 module.wasm          # largest functions
twiggy dominators module.wasm         # what retains what
twiggy paths module.wasm "alloc"      # why is alloc included
```

4. **Use wee_alloc** (~1KB vs ~10KB for dlmalloc):
```rust
#[global_allocator]
static ALLOC: wee_alloc::WeeAlloc = wee_alloc::WeeAlloc::INIT;
```

5. **Avoid format strings**: `format!()` and `panic!("{}")` pull in formatting machinery (~50KB). Use static strings.

6. **Feature-gate dependencies**:
```toml
serde = { version = "1", default-features = false, features = ["derive"] }
```

7. **TinyGo over standard Go**: ~50KB vs ~2MB for hello world.

8. **AssemblyScript**: Compiles directly to WASM without runtime — tiny output.

### Size Comparison (hello world HTTP handler)

| Language/Toolchain | Unoptimized | Optimized |
|-------------------|-------------|-----------|
| Rust + cargo-component | ~2MB | ~200KB |
| TinyGo wasip2 | ~300KB | ~80KB |
| C + WASI SDK | ~50KB | ~15KB |
| AssemblyScript | ~5KB | ~2KB |

---

## Import/Export Naming Conflicts

### Symptom

`LinkError: import object field 'X' is not a Function` or `TypeError: WebAssembly.instantiate(): Import #0 module="X" error`.

### Common Causes

**Namespace mismatch**:
```javascript
// Module expects: (import "env" "log")
// WRONG
const imports = { log: (x) => console.log(x) };
// RIGHT
const imports = { env: { log: (x) => console.log(x) } };
```

**WASI module name differences**:
```javascript
// Preview 1: "wasi_snapshot_preview1"
// Preview 2: "wasi:cli/environment@0.2.0" etc.
// Check actual imports:
WebAssembly.Module.imports(module).forEach(imp =>
  console.log(`${imp.module}::${imp.name} (${imp.kind})`)
);
```

**Case sensitivity**: Import names are case-sensitive. `"MyFunc"` ≠ `"myFunc"`.

**Duplicate export names**: Two exports cannot share a name. Rename in the WAT or source code.

### Debugging Tool

```bash
# List all imports and exports
wasm-tools print module.wasm | grep -E '^\s+\((import|export)'

# Structured listing
wasm-tools component wit component.wasm  # for components

# Programmatic (Node.js)
node -e "
const fs = require('fs');
const buf = fs.readFileSync('module.wasm');
const mod = new WebAssembly.Module(buf);
console.log('IMPORTS:', WebAssembly.Module.imports(mod));
console.log('EXPORTS:', WebAssembly.Module.exports(mod));
"
```
