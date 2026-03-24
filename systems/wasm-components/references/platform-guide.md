# WebAssembly Platform Guide

## Table of Contents
1. [Spin (Fermyon)](#spin-fermyon)
2. [Wasmtime Standalone](#wasmtime-standalone)
3. [Wasmer](#wasmer)
4. [WasmEdge](#wasmedge)
5. [Cloudflare Workers](#cloudflare-workers)
6. [Fastly Compute](#fastly-compute)
7. [Vercel Edge Functions](#vercel-edge-functions)
8. [Docker + WASM](#docker--wasm)
9. [Kubernetes + WASM](#kubernetes--wasm)
10. [Extism (Plugin System)](#extism-plugin-system)
11. [WASM in Databases](#wasm-in-databases)
12. [WASM in Proxies](#wasm-in-proxies)

---

## Spin (Fermyon)

Serverless application framework built on Wasmtime. Supports HTTP, Redis, cron triggers.

### Quick Start

```bash
# Install
curl -fsSL https://developer.fermyon.com/downloads/install.sh | bash
sudo mv spin /usr/local/bin/

# Create project
spin new -t http-rust my-app && cd my-app
# Or: spin new -t http-ts, http-go, http-py

# Build and run
spin build
spin up  # serves on http://127.0.0.1:3000
```

### spin.toml

```toml
spin_manifest_version = 2

[application]
name = "my-app"
version = "0.1.0"

[[trigger.http]]
route = "/api/..."
component = "api"

[component.api]
source = "target/wasm32-wasip1/release/api.wasm"
allowed_outbound_hosts = ["https://api.example.com"]
key_value_stores = ["default"]
sqlite_databases = ["default"]

[component.api.build]
command = "cargo build --target wasm32-wasip1 --release"
```

### Key Features

- **Sub-millisecond cold start** — components are pre-compiled
- **Built-in key-value store** — `spin_sdk::key_value::Store`
- **Built-in SQLite** — `spin_sdk::sqlite::Connection`
- **Outbound HTTP** — allowlisted hosts only (security)
- **Deploy**: `spin deploy` to Fermyon Cloud, or self-host with `spin up`
- **Component Model native** — uses WIT interfaces for SDK

### Spin vs Direct Wasmtime

| Feature | Spin | Wasmtime CLI |
|---------|------|-------------|
| HTTP handling | Built-in trigger | Manual via wasi:http |
| Key-value | Built-in | Not included |
| Deployment | `spin deploy` | Manual |
| Multi-component | spin.toml routing | Manual composition |
| Use case | Web services | General-purpose |

---

## Wasmtime Standalone

Reference WASM runtime by Bytecode Alliance. Full spec compliance.

### Installation

```bash
curl https://wasmtime.dev/install.sh -sSf | bash
# Or: cargo install wasmtime-cli
```

### Usage

```bash
# Run a WASI CLI program
wasmtime run app.wasm -- arg1 arg2

# With filesystem access
wasmtime run --dir /tmp:/tmp --dir ./data:/data app.wasm

# With environment variables
wasmtime run --env KEY=VALUE app.wasm

# AOT compilation (faster subsequent starts)
wasmtime compile app.wasm -o app.cwasm
wasmtime run app.cwasm

# Serve HTTP (wasi:http component)
wasmtime serve component.wasm --addr 0.0.0.0:8080

# Resource limits
wasmtime run --max-memory-size 67108864 \  # 64MB
  --max-wasm-stack 1048576 \                # 1MB stack
  --fuel 1000000 \                          # instruction limit
  app.wasm

# Profiling
wasmtime run --profile=perfmap app.wasm
```

### Embedding (Rust)

```rust
use wasmtime::*;

fn main() -> anyhow::Result<()> {
    let engine = Engine::new(Config::new().wasm_component_model(true))?;
    let mut store = Store::new(&engine, ());
    let component = Component::from_file(&engine, "component.wasm")?;
    let mut linker = component::Linker::new(&engine);
    wasmtime_wasi::add_to_linker_sync(&mut linker)?;
    let instance = linker.instantiate(&mut store, &component)?;
    // Call exported functions...
    Ok(())
}
```

### Embedding (Python)

```python
from wasmtime import Store, Module, Instance, Func, FuncType, ValType

store = Store()
module = Module.from_file(store.engine, "module.wasm")
instance = Instance(store, module, [])
add = instance.exports(store)["add"]
print(add(store, 2, 3))  # 5
```

---

## Wasmer

Multi-backend runtime. Embeddable with broad language support.

### Installation and Usage

```bash
curl https://get.wasmer.io -sSfL | sh

# Run WASI module
wasmer run app.wasm

# With filesystem mapping
wasmer run --dir /data:./local-data app.wasm

# Package and publish
wasmer init   # creates wasmer.toml
wasmer publish

# AOT compile
wasmer compile app.wasm -o app.wasmu --target x86_64-linux

# Wasmer JS (browser/Node.js)
npm install @wasmer/sdk
```

### Key Differentiators

- **Multiple backends**: Cranelift (fast compile), LLVM (optimized output), Singlepass (fastest compile, JIT)
- **Wasmer Edge**: CDN-deployed WASM serverless platform
- **WAPM**: Package registry at wapm.io
- **wasmer.sh**: Browser-based WASM terminal
- **Language SDKs**: Rust, C, C++, Go, Python, Ruby, Java, JavaScript, PHP, Swift, Zig, Dart, R

---

## WasmEdge

High-performance runtime optimized for edge and AI workloads.

### Installation and Usage

```bash
curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh | bash

# Run
wasmedge app.wasm

# With extensions
wasmedge --dir /data:./data app.wasm

# AOT compilation
wasmedge compile app.wasm app_aot.wasm
```

### Unique Features

- **AI inference**: Built-in WASI-NN with GGML, PyTorch, TensorFlow Lite, OpenVINO
- **Networking**: Non-blocking async sockets, HTTP client/server
- **Databases**: MySQL, PostgreSQL client support via host functions
- **Kubernetes integration**: CRI-O, containerd support
- **Fastest cold start** among full-featured runtimes (~0.02ms)

```rust
// WASI-NN inference example (Rust)
use wasi_nn::*;

let graph = GraphBuilder::new(GraphEncoding::Ggml, ExecutionTarget::AUTO)
    .build_from_cache("llama-2-7b")?;
let context = graph.init_execution_context()?;
context.set_input(0, TensorType::U8, &[1], &prompt_bytes)?;
context.compute()?;
let output = context.get_output(0)?;
```

---

## Cloudflare Workers

V8-based edge compute. WASM modules run alongside JavaScript.

### Setup

```bash
npm create cloudflare@latest my-worker -- --type=hello-world
cd my-worker
```

### Rust WASM Worker

```bash
npm create cloudflare@latest my-wasm-worker -- --type=rust
```

```rust
// src/lib.rs
use worker::*;

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    Router::new()
        .get("/", |_, _| Response::ok("Hello from Rust WASM!"))
        .get("/compute/:n", |_, ctx| {
            let n: u32 = ctx.param("n").unwrap().parse().unwrap();
            Response::ok(format!("fib({n}) = {}", fib(n)))
        })
        .run(req, env)
        .await
}
```

### Constraints

| Limit | Value |
|-------|-------|
| WASM binary size | 1MB (free), 10MB (paid) |
| Memory | 128MB |
| CPU time/request | 10ms (free), 30s (paid) |
| Subrequests | 50/request (free) |
| Cold start | <5ms (V8 isolates) |

### wrangler.toml

```toml
name = "my-worker"
main = "build/worker/shim.mjs"
compatibility_date = "2024-01-01"

[build]
command = "cargo install -q worker-build && worker-build --release"
```

---

## Fastly Compute

Edge compute with Wasmtime. First-class WASM support.

### Setup

```bash
# Install CLI
brew install fastly/tap/fastly

# Create project
fastly compute init --language=rust
# Also supports: go, javascript, assemblyscript

# Build and deploy
fastly compute build
fastly compute deploy

# Local testing
fastly compute serve  # local dev server
```

### Rust Example

```rust
use fastly::{Error, Request, Response};

#[fastly::main]
fn main(req: Request) -> Result<Response, Error> {
    match (req.get_method_str(), req.get_path()) {
        ("GET", "/") => Ok(Response::from_body("Hello from Fastly Compute!")),
        ("GET", path) if path.starts_with("/api/") => {
            // Backend fetch
            let beresp = req.send("origin_backend")?;
            Ok(beresp)
        }
        _ => Ok(Response::from_status(404)),
    }
}
```

### Key Features

- **Sub-millisecond startup** — AOT-compiled WASM
- **Backend origins** — proxy to upstream servers
- **Geolocation** — built-in geo IP lookup
- **KV Store, Config Store, Secret Store** — platform-managed data
- **Real-time logging** — stream to S3, BigQuery, Datadog, etc.
- **Purge API** — cache invalidation at edge

### Constraints

| Limit | Value |
|-------|-------|
| WASM binary size | 100MB |
| Memory | 256MB |
| CPU time/request | 60s |
| Subrequests | 32 concurrent |

---

## Vercel Edge Functions

Run at the edge using V8. WASM via JavaScript interop.

### Usage

```typescript
// api/compute.ts (Edge Runtime)
import wasmModule from '../lib/module.wasm?module';

export const config = { runtime: 'edge' };

export default async function handler(req: Request) {
  const instance = await WebAssembly.instantiate(wasmModule);
  const result = instance.exports.compute(42);
  return new Response(JSON.stringify({ result }), {
    headers: { 'content-type': 'application/json' },
  });
}
```

### Rust + wasm-pack

```bash
cd lib && wasm-pack build --target web
```

```typescript
import init, { process_data } from '../lib/pkg';
export const config = { runtime: 'edge' };

export default async function handler(req: Request) {
  await init();
  const body = await req.arrayBuffer();
  const result = process_data(new Uint8Array(body));
  return new Response(result);
}
```

### Constraints

| Limit | Value |
|-------|-------|
| Code size | 4MB (after compression) |
| Memory | 128MB |
| Execution time | 30s (streaming), 5s (non-streaming) |
| Edge locations | ~30 regions |

---

## Docker + WASM

### containerd Shims

Docker Desktop 4.15+ supports WASM via containerd shims (beta).

```bash
# Enable in Docker Desktop: Settings → Features → "Use containerd" + "Enable Wasm"

# Run WASM workloads
docker run --rm \
  --runtime=io.containerd.wasmtime.v1 \
  --platform=wasi/wasm \
  ghcr.io/example/wasm-app:latest

# Available runtimes (install shims):
# io.containerd.wasmtime.v1
# io.containerd.wasmedge.v1
# io.containerd.wasmer.v1
# io.containerd.spin.v2
```

### Building WASM OCI Images

```dockerfile
FROM scratch
COPY target/wasm32-wasip1/release/app.wasm /app.wasm
ENTRYPOINT ["/app.wasm"]
```

```bash
# Build for wasi/wasm platform
docker buildx build --platform=wasi/wasm -t myapp:latest .

# Multi-platform (WASM + Linux)
docker buildx build \
  --platform=wasi/wasm,linux/amd64,linux/arm64 \
  -t myapp:latest .
```

### Docker Compose

```yaml
services:
  web:
    image: myapp:latest
    platform: wasi/wasm
    runtime: io.containerd.wasmtime.v1
    ports:
      - "8080:8080"

  # Traditional container alongside WASM
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: secret
```

### Benefits Over Containers

| Aspect | Linux Container | WASM |
|--------|----------------|------|
| Startup | 100ms–seconds | <1ms |
| Image size | 50MB–1GB | 1–10MB |
| Memory overhead | 20MB+ | <1MB |
| Isolation | Namespaces/cgroups | WASM sandbox |
| Portability | Per-architecture | Universal binary |
| Security | Root exploits possible | Memory-safe by design |

---

## Kubernetes + WASM

### runwasi

containerd shim that runs WASM workloads in Kubernetes.

```bash
# Install runwasi shim on nodes
# (varies by distro — typically install containerd-shim-wasmtime-v1)

# RuntimeClass for WASM workloads
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: wasmtime
handler: spin  # or: wasmtime, wasmedge
```

### SpinKube

Kubernetes operator for Spin applications.

```bash
# Install SpinKube
kubectl apply -f https://github.com/spinkube/spin-operator/releases/latest/download/spin-operator.crds.yaml
kubectl apply -f https://github.com/spinkube/spin-operator/releases/latest/download/spin-operator.runtime-class.yaml
kubectl apply -f https://github.com/spinkube/spin-operator/releases/latest/download/spin-operator.shim-executor.yaml
helm install spin-operator oci://ghcr.io/spinkube/charts/spin-operator
```

```yaml
# SpinApp CRD
apiVersion: core.spinoperator.dev/v1alpha1
kind: SpinApp
metadata:
  name: my-spin-app
spec:
  image: ghcr.io/myorg/my-spin-app:latest
  replicas: 3
  executor: containerd-shim-spin
```

### WASM Pod Spec

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: wasm-hello
spec:
  runtimeClassName: wasmtime
  containers:
    - name: hello
      image: ghcr.io/example/wasm-hello:latest
      ports:
        - containerPort: 8080
      resources:
        limits:
          memory: "64Mi"
          cpu: "100m"
```

### Benefits in K8s

- **Density**: Run thousands of WASM instances per node vs dozens of containers
- **Scheduling**: Near-instant pod starts — no image pull for cached OCI artifacts
- **Multi-tenancy**: WASM sandbox per request, not per pod
- **Mixed workloads**: WASM and Linux containers in the same cluster

---

## Extism (Plugin System)

Framework for building WASM plugin systems. Host calls guest functions; guest calls host functions.

### Host Side (Rust)

```rust
use extism::*;

fn main() -> Result<(), Error> {
    let manifest = Manifest::new([Wasm::file("plugin.wasm")]);
    let mut plugin = Plugin::new(&manifest, [], true)?;

    let result = plugin.call::<&str, &str>("greet", "World")?;
    println!("{result}"); // "Hello, World!"
    Ok(())
}
```

### Host Side (Node.js)

```javascript
import Extism from "@extism/extism";

const plugin = await Extism.createPlugin("plugin.wasm", {
  useWasi: true,
});
const result = await plugin.call("greet", "World");
console.log(result.text()); // "Hello, World!"
```

### Guest Side (Rust)

```rust
use extism_pdk::*;

#[plugin_fn]
pub fn greet(name: String) -> FnResult<String> {
    Ok(format!("Hello, {name}!"))
}

#[plugin_fn]
pub fn process(input: Json<InputData>) -> FnResult<Json<OutputData>> {
    let output = transform(input.into_inner());
    Ok(Json(output))
}
```

### Key Features

- **Host SDKs**: Rust, Go, Python, Node.js, Ruby, Java, .NET, Elixir, PHP, Zig, C
- **Guest PDKs**: Rust, Go, AssemblyScript, C, Haskell, Zig
- **Host functions**: Guest can call host-defined functions
- **HTTP**: Built-in outbound HTTP for plugins
- **Manifest**: Declare allowed hosts, memory limits, config per plugin

---

## WASM in Databases

### SQLite Extensions

Compile C/Rust functions to WASM, load as SQLite extensions:

```c
// extension.c — custom SQLite function
#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1

static void rot13(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    const char *input = (const char*)sqlite3_value_text(argv[0]);
    // ... rot13 transform ...
    sqlite3_result_text(ctx, output, -1, SQLITE_TRANSIENT);
}

int sqlite3_extension_init(sqlite3 *db, char **err, const sqlite3_api_routines *api) {
    SQLITE_EXTENSION_INIT2(api);
    sqlite3_create_function(db, "rot13", 1, SQLITE_UTF8, 0, rot13, 0, 0);
    return SQLITE_OK;
}
```

Projects using WASM SQLite extensions:
- **sqlite-wasm** (official): SQLite compiled to WASM for browser use
- **cr-sqlite** (Vulcan Labs): CRDT-based replication via WASM extension
- **Turso/libSQL**: WASM-based UDFs in production database

### PostgreSQL

**Supabase Wrappers**: WASM-based foreign data wrappers:
```sql
CREATE EXTENSION wrappers;
CREATE FOREIGN DATA WRAPPER wasm_wrapper
  HANDLER wasm_fdw_handler
  VALIDATOR wasm_fdw_validator;
```

**PL/WASM**: Run WASM functions as PostgreSQL stored procedures. Experimental — community-driven.

### SingleStore

Native WASM UDF support:
```sql
CREATE FUNCTION add_one(x INT) RETURNS INT
AS WASM FROM LOCAL INFILE 'add_one.wasm'
WITH WIT FROM LOCAL INFILE 'add_one.wit';

SELECT add_one(41); -- 42
```

---

## WASM in Proxies

### Envoy Proxy

Envoy supports WASM filters via the proxy-wasm ABI.

```yaml
# envoy.yaml
http_filters:
  - name: envoy.filters.http.wasm
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
      config:
        name: "my_filter"
        root_id: "my_filter_root"
        vm_config:
          runtime: envoy.wasm.runtime.v8
          code:
            local:
              filename: /etc/envoy/filter.wasm
```

### proxy-wasm SDK (Rust)

```rust
use proxy_wasm::traits::*;
use proxy_wasm::types::*;

proxy_wasm::main! {{
    proxy_wasm::set_http_context(|_, _| -> Box<dyn HttpContext> {
        Box::new(MyFilter)
    });
}}

struct MyFilter;

impl Context for MyFilter {}

impl HttpContext for MyFilter {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        if self.get_http_request_header("authorization").is_none() {
            self.send_http_response(401, vec![], Some(b"Unauthorized"));
            return Action::Pause;
        }
        Action::Continue
    }

    fn on_http_response_headers(&mut self, _: usize, _: bool) -> Action {
        self.add_http_response_header("x-powered-by", "wasm");
        Action::Continue
    }
}
```

### Compatible Proxies

| Proxy | WASM Support | ABI |
|-------|-------------|-----|
| Envoy | Production | proxy-wasm v0.2.1 |
| Istio | Via Envoy | proxy-wasm |
| NGINX (njs) | Experimental | Custom |
| Kong | Plugin system | Custom |
| Traefik | Experimental | proxy-wasm |
| Apache APISIX | Plugin system | proxy-wasm |

### Use Cases

- **Auth**: JWT validation, OAuth token introspection at the proxy layer
- **Rate limiting**: Custom rate limit logic per route/user
- **Transform**: Request/response body modification, header injection
- **Observability**: Custom metrics, trace context propagation
- **Multi-tenant routing**: Tenant-specific routing logic without proxy restart
