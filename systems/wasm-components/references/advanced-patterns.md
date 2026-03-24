# Advanced WebAssembly Patterns

## Table of Contents
1. [Component Model Deep Dive](#component-model-deep-dive)
2. [WIT Syntax Reference](#wit-syntax-reference)
3. [Component Composition with WAC](#component-composition-with-wac)
4. [WASI Preview 2 Interfaces](#wasi-preview-2-interfaces)
5. [Memory Management Strategies](#memory-management-strategies)
6. [SIMD Operations](#simd-operations)
7. [Threads and Shared Memory](#threads-and-shared-memory)
8. [Proposals: Exception Handling, Tail Calls, GC](#proposals)
9. [wasm-tools CLI Reference](#wasm-tools-cli-reference)
10. [Component Linking](#component-linking)

---

## Component Model Deep Dive

The Component Model layers on top of core WASM modules to provide:
- **Language-agnostic interfaces** via WIT (no more C ABI wrangling)
- **Typed imports/exports** with rich types (strings, lists, records, variants, resources)
- **Composition** — wire components together without shared memory
- **Virtualization** — intercept and modify component behavior

### Architecture

```
┌─────────────────────────────────────┐
│           Component                 │
│  ┌───────────┐   ┌───────────┐     │
│  │ Core      │   │ Core      │     │
│  │ Module A  │──▶│ Module B  │     │
│  └───────────┘   └───────────┘     │
│       ▲               │            │
│       │  canonical     │            │
│       │  ABI lifts     ▼            │
│  ┌─────────────────────────────┐   │
│  │  Component Type (WIT)       │   │
│  │  imports: [...]             │   │
│  │  exports: [...]             │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

Key distinction: **core modules** share linear memory and use the core WASM ABI. **Components** communicate through the canonical ABI — values are lifted/lowered across boundaries, enabling safe cross-language interop.

### Canonical ABI

The canonical ABI defines how WIT types map to core WASM:
- `string` → pointer + length in linear memory (UTF-8)
- `list<T>` → pointer + length
- `record` → flattened struct fields
- `variant` → discriminant + payload
- `resource` → handle (i32 index)
- `option<T>` → discriminant + optional value
- `result<T, E>` → discriminant + ok-value or err-value

Lifting: core WASM values → component-level typed values.
Lowering: component-level typed values → core WASM values.

The `post-return` canonical function frees memory allocated during a call.

---

## WIT Syntax Reference

### Packages

```wit
package myorg:mypackage@1.2.3;
```

Package names are namespaced (`namespace:name`) with optional semver. Packages contain interfaces and worlds.

### Interfaces

```wit
interface key-value {
  /// A stored value
  resource bucket {
    constructor(name: string);
    get: func(key: string) -> option<list<u8>>;
    set: func(key: string, value: list<u8>);
    delete: func(key: string);
    exists: func(key: string) -> bool;
    list-keys: func(cursor: option<u64>) -> key-response;
  }

  record key-response {
    keys: list<string>,
    cursor: option<u64>,
  }

  open: func(name: string) -> bucket;
}
```

### Resources

Resources are opaque handles with methods:
```wit
resource connection {
  constructor(url: string);
  query: func(sql: string, params: list<value>) -> result<rows, error>;
  execute: func(sql: string, params: list<value>) -> result<u64, error>;
  close: func();
}
```

Resources have ownership semantics — a `borrow<connection>` cannot outlive the call.

### Worlds

```wit
world http-proxy {
  // What the component needs from the host
  import wasi:http/outgoing-handler@0.2.0;
  import wasi:logging/logging;

  // What the component provides
  export wasi:http/incoming-handler@0.2.0;
}

world plugin {
  // Import a named interface
  import host-functions: interface {
    log: func(msg: string);
    get-config: func(key: string) -> option<string>;
  }
  // Export a named interface
  export plugin-api: interface {
    init: func() -> result<_, string>;
    process: func(input: list<u8>) -> list<u8>;
  }
}
```

### Advanced WIT Types

```wit
// Flags — bitfield
flags permissions {
  read,
  write,
  execute,
}

// Variant — tagged union
variant filter {
  all,
  none,
  some(list<string>),
  pattern(string),
}

// Enum — no payloads
enum color { red, green, blue }

// Nested types
type headers = list<tuple<string, string>>;
type body = option<list<u8>>;
```

### Type Aliases and Use

```wit
interface types {
  type timeout = u64;
  type request-id = string;
}

interface handler {
  use types.{timeout, request-id};
  handle: func(id: request-id, deadline: timeout) -> result<_, string>;
}
```

---

## Component Composition with WAC

WAC (WebAssembly Composition) provides declarative component wiring.

### WAC Language

```wac
// composition.wac
package myorg:composed;

// Instantiate components with specific imports wired
let backend = new myorg:backend@1.0.0 {
  "wasi:http/outgoing-handler@0.2.0": wasi:http/outgoing-handler@0.2.0,
};

let auth = new myorg:auth@1.0.0 {
  "myorg:backend/api": backend["myorg:backend/api"],
};

// Export from the auth component
export auth["myorg:auth/handler"];
```

### CLI Usage

```bash
# Install
cargo install wac-cli

# Compose from WAC file
wac compose composition.wac -o composed.wasm

# Plug one component into another (quick one-off)
wac plug --plug auth.wasm app.wasm -o composed.wasm

# Encode a WAC definition
wac encode composition.wac -o composed.wasm
```

### Composition Patterns

**Middleware pattern** — intercept requests:
```wac
let middleware = new myorg:logging@1.0.0 {
  "wasi:http/incoming-handler@0.2.0": app["wasi:http/incoming-handler@0.2.0"],
};
export middleware["wasi:http/incoming-handler@0.2.0"];
```

**Sidecar pattern** — add capabilities:
```wac
let cache = new myorg:cache@1.0.0 {};
let app = new myorg:app@1.0.0 {
  "myorg:cache/store": cache["myorg:cache/store"],
};
export app["wasi:http/incoming-handler@0.2.0"];
```

---

## WASI Preview 2 Interfaces

### wasi:http

```wit
// Incoming request handler (implement this)
interface incoming-handler {
  use types.{incoming-request, response-outparam};
  handle: func(request: incoming-request, response-out: response-outparam);
}

// Outgoing request (call external services)
interface outgoing-handler {
  use types.{outgoing-request, request-options, incoming-response, error-code};
  handle: func(request: outgoing-request, options: option<request-options>)
    -> result<incoming-response, error-code>;
}
```

Rust implementation pattern:
```rust
use wasi::http::types::*;

impl Guest for Component {
    fn handle(request: IncomingRequest, response_out: ResponseOutparam) {
        let hdrs = Headers::new();
        hdrs.set(&"content-type".to_string(),
                 &[b"application/json".to_vec()]).unwrap();
        let resp = OutgoingResponse::new(hdrs);
        resp.set_status_code(200).unwrap();
        let body = resp.body().unwrap();
        ResponseOutparam::set(response_out, Ok(resp));
        let stream = body.write().unwrap();
        stream.blocking_write_and_flush(b"{\"status\":\"ok\"}").unwrap();
        drop(stream);
        OutgoingBody::finish(body, None).unwrap();
    }
}
```

### wasi:filesystem

```wit
interface types {
  resource descriptor {
    read-via-stream: func(offset: filesize) -> result<input-stream, error-code>;
    write-via-stream: func(offset: filesize) -> result<output-stream, error-code>;
    stat: func() -> result<descriptor-stat, error-code>;
    // ...
  }
}
interface preopens {
  get-directories: func() -> list<tuple<descriptor, string>>;
}
```

Host grants access via `--dir` flags. Components see only granted directories.

### wasi:sockets

```wit
interface tcp {
  resource tcp-socket {
    start-bind: func(network: borrow<network>, local-address: ip-socket-address)
      -> result<_, error-code>;
    start-connect: func(network: borrow<network>, remote-address: ip-socket-address)
      -> result<_, error-code>;
    // ...
  }
}
```

Currently supported in Wasmtime and WasmEdge. Requires explicit network grants.

### wasi:cli

Provides `stdin`, `stdout`, `stderr`, `environment` (env vars), `exit`, and `terminal-*` interfaces. The default world for command-line WASI applications.

---

## Memory Management Strategies

### Linear Memory

WASM's default: a single contiguous, growable byte array.

**Arena allocator** — best for request-scoped work:
```rust
use bumpalo::Bump;

static mut ARENA: Option<Bump> = None;

#[no_mangle]
pub extern "C" fn handle_request(ptr: *const u8, len: usize) -> *const u8 {
    let arena = unsafe { ARENA.get_or_insert_with(|| Bump::new()) };
    arena.reset(); // free all allocations from previous request
    let input = unsafe { std::slice::from_raw_parts(ptr, len) };
    let result = arena.alloc_slice_copy(process(input));
    result.as_ptr()
}
```

**Pool allocator** — pre-allocate fixed-size blocks for predictable allocation:
```rust
struct Pool<const SIZE: usize, const COUNT: usize> {
    blocks: [[u8; SIZE]; COUNT],
    free_list: Vec<usize>,
}
```

**wee_alloc** — tiny allocator (~1KB) for size-constrained modules:
```toml
[dependencies]
wee_alloc = "0.4"
```
```rust
#[global_allocator]
static ALLOC: wee_alloc::WeeAlloc = wee_alloc::WeeAlloc::INIT;
```

### Shared Memory

Shared linear memory between threads (requires `--shared-memory`):
```javascript
const memory = new WebAssembly.Memory({ initial: 1, maximum: 10, shared: true });
```

Rules:
- Memory must be imported (not exported) from the module
- `maximum` is required for shared memory
- Access via `Atomics` for synchronization
- Requires COOP/COEP headers in browsers

### Garbage Collection Proposal (WasmGC)

Adds managed reference types to WASM — structs, arrays with GC:
```wasm
(type $point (struct (field $x f64) (field $y f64)))
(type $points (array (ref $point)))
```

Supported in Chrome 119+, Firefox 120+. Enables efficient compilation of GC languages (Java, Kotlin, Dart, OCaml) without shipping a GC in the module.

---

## SIMD Operations

WASM SIMD provides 128-bit packed operations via the `v128` type.

### Rust SIMD

```rust
#[cfg(target_arch = "wasm32")]
use core::arch::wasm32::*;

pub fn dot_product(a: &[f32; 4], b: &[f32; 4]) -> f32 {
    unsafe {
        let va = v128_load(a.as_ptr() as *const v128);
        let vb = v128_load(b.as_ptr() as *const v128);
        let prod = f32x4_mul(va, vb);
        // Horizontal sum
        let hi = i32x4_shuffle::<2, 3, 0, 1>(prod, prod);
        let sum = f32x4_add(prod, hi);
        let hi2 = i32x4_shuffle::<1, 0, 3, 2>(sum, sum);
        let result = f32x4_add(sum, hi2);
        f32x4_extract_lane::<0>(result)
    }
}
```

Build: `RUSTFLAGS="-C target-feature=+simd128" cargo build --target wasm32-unknown-unknown`

### C/C++ SIMD

```c
#include <wasm_simd128.h>

void add_vectors(float* a, float* b, float* out, int n) {
    for (int i = 0; i < n; i += 4) {
        v128_t va = wasm_v128_load(&a[i]);
        v128_t vb = wasm_v128_load(&b[i]);
        wasm_v128_store(&out[i], wasm_f32x4_add(va, vb));
    }
}
```

Build: `emcc -msimd128 -O3 simd.c -o simd.wasm`

### Available SIMD Operations (subset)

| Category | Operations |
|----------|-----------|
| i8x16 | add, sub, min_s/u, max_s/u, eq, ne, lt, gt, shl, shr |
| i16x8 | add, sub, mul, min_s/u, max_s/u, extmul |
| i32x4 | add, sub, mul, dot_i16x8_s, trunc_sat_f32x4 |
| i64x2 | add, sub, mul, extend_low/high_i32x4 |
| f32x4 | add, sub, mul, div, sqrt, min, max, ceil, floor |
| f64x2 | add, sub, mul, div, sqrt, min, max, ceil, floor |
| v128 | and, or, xor, andnot, bitselect, any_true |

---

## Threads and Shared Memory

### Setup

Compile with atomics support:
```bash
# Rust
RUSTFLAGS="-C target-feature=+atomics,+bulk-memory,+mutable-globals" \
  cargo build --target wasm32-unknown-unknown -Z build-std=std,panic_abort

# Emscripten
emcc -pthread -s SHARED_MEMORY=1 -s PTHREAD_POOL_SIZE=4 app.c -o app.js
```

### Browser Threading

```javascript
// Required HTTP headers
// Cross-Origin-Opener-Policy: same-origin
// Cross-Origin-Embedder-Policy: require-corp

const memory = new WebAssembly.Memory({ initial: 1, maximum: 100, shared: true });

// Main thread
const worker = new Worker("worker.js");
worker.postMessage({ module: wasmModule, memory });

// worker.js
self.onmessage = async ({ data: { module, memory } }) => {
  const instance = await WebAssembly.instantiate(module, {
    env: { memory }
  });
  // Shared memory is now accessible from both threads
  Atomics.store(new Int32Array(memory.buffer), 0, 42);
  Atomics.notify(new Int32Array(memory.buffer), 0);
};
```

### Atomics

```javascript
const view = new Int32Array(memory.buffer);

// Atomic operations
Atomics.store(view, idx, value);
Atomics.load(view, idx);
Atomics.add(view, idx, value);
Atomics.sub(view, idx, value);
Atomics.compareExchange(view, idx, expected, replacement);

// Synchronization
Atomics.wait(view, idx, expectedValue, timeout); // blocks
Atomics.notify(view, idx, count); // wake waiters
```

---

## Proposals

### Exception Handling

Adds structured try/catch/throw to WASM. Phase 4 (standardized).

```wasm
(tag $my-error (param i32))

(try
  (do
    (throw $my-error (i32.const 42))
  )
  (catch $my-error
    ;; handle error, value on stack
    drop
  )
  (catch_all
    ;; handle unknown exceptions
  )
)
```

Rust: exceptions auto-map to `panic` unwinding. C++: maps to native C++ exceptions via Emscripten.

### Tail Calls

Enables guaranteed tail-call optimization — critical for functional languages.

```wasm
(func $factorial (param $n i64) (param $acc i64) (result i64)
  (if (i64.le_u (local.get $n) (i64.const 1))
    (then (return (local.get $acc)))
    (else
      (return_call $factorial
        (i64.sub (local.get $n) (i64.const 1))
        (i64.mul (local.get $n) (local.get $acc))
      )
    )
  )
)
```

Supported in Chrome 112+, Firefox 121+, Wasmtime.

### Garbage Collection (WasmGC)

Adds struct/array heap types managed by the runtime GC:
- `struct.new`, `struct.get`, `struct.set`
- `array.new`, `array.get`, `array.set`, `array.len`
- Subtyping with `sub` declarations
- `ref.cast`, `ref.test` for downcasting
- `i31ref` for small tagged integers

Eliminates the need for languages to ship their own GC in the WASM binary. Kotlin/WASM and Dart use this.

---

## wasm-tools CLI Reference

```bash
# Install
cargo install wasm-tools

# Inspect
wasm-tools print module.wasm                       # disassemble to WAT
wasm-tools dump module.wasm                        # hex dump with annotations
wasm-tools objdump module.wasm                     # section-level overview
wasm-tools component wit component.wasm            # extract WIT definition

# Validate
wasm-tools validate module.wasm                    # validate core module
wasm-tools validate --features all component.wasm  # validate with all features

# Convert
wasm-tools component new core.wasm -o component.wasm          # module → component
wasm-tools component new core.wasm --adapt wasi_snapshot_preview1.reactor.wasm \
  -o component.wasm                                             # with WASI adapter
wasm-tools component embed --world my-world wit/ core.wasm -o embedded.wasm  # embed WIT

# Compose
wasm-tools compose app.wasm -d lib.wasm -o composed.wasm      # compose components
wasm-tools compose --config compose.yml app.wasm -o out.wasm   # config-driven

# Strip / Optimize metadata
wasm-tools strip module.wasm -o stripped.wasm                  # remove custom sections
wasm-tools metadata show module.wasm                           # show producers metadata
wasm-tools metadata add module.wasm --name "my-tool" -o out.wasm

# Smith (fuzzing)
wasm-tools smith --fuel 100 -o fuzz.wasm                       # generate random module
```

---

## Component Linking

### Static Linking (composition)

Wire component exports to imports at build time:
```bash
# A exports "myorg:math/operations"
# B imports "myorg:math/operations"
wasm-tools compose B.wasm --definitions A.wasm -o linked.wasm
```

### Dynamic Linking (runtime)

Runtimes like Wasmtime support dynamic linking via the `Linker` API:
```rust
use wasmtime::component::*;

let engine = Engine::default();
let mut linker = Linker::new(&engine);

// Register one component's exports as available imports
wasmtime_wasi::add_to_linker_sync(&mut linker)?;
linker.instance("myorg:math/operations")?
    .func_wrap("add", |_ctx, (a, b): (i32, i32)| Ok((a + b,)))?;

let component = Component::from_file(&engine, "app.wasm")?;
let instance = linker.instantiate(&mut store, &component)?;
```

### Shared-Nothing Linking

Components never share memory. Data crosses boundaries via the canonical ABI (copy semantics). This provides:
- **Memory safety**: no dangling pointers across components
- **Language interop**: each component uses its own allocator/GC
- **Security**: components cannot read each other's memory

Trade-off: copying overhead for large data transfers. Use `stream<T>` (WASI 0.3) for bulk data.
