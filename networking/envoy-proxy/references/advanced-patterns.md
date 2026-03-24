# Envoy Proxy — Advanced Patterns

## Table of Contents

- [xDS Protocol Deep Dive](#xds-protocol-deep-dive)
  - [State of the World (SotW) vs Delta xDS](#state-of-the-world-sotw-vs-delta-xds)
  - [Aggregated Discovery Service (ADS)](#aggregated-discovery-service-ads)
  - [xDS Resource Ordering and Dependencies](#xds-resource-ordering-and-dependencies)
  - [Incremental xDS (Delta) Protocol Flow](#incremental-xds-delta-protocol-flow)
- [WASM Filter Development](#wasm-filter-development)
  - [Proxy-WASM ABI Overview](#proxy-wasm-abi-overview)
  - [Rust SDK Development](#rust-sdk-development)
  - [Go SDK Development (TinyGo)](#go-sdk-development-tinygo)
  - [C++ SDK Development](#c-sdk-development)
  - [WASM VM Lifecycle and Shared Data](#wasm-vm-lifecycle-and-shared-data)
  - [Deploying WASM Filters](#deploying-wasm-filters)
- [Lua Filters](#lua-filters)
  - [Lua Filter Configuration](#lua-filter-configuration)
  - [Lua Script API](#lua-script-api)
  - [Lua vs WASM Trade-offs](#lua-vs-wasm-trade-offs)
- [External Processing (ext_proc)](#external-processing-ext_proc)
  - [ext_proc Architecture](#ext_proc-architecture)
  - [ext_proc Configuration](#ext_proc-configuration)
  - [ext_proc Processing Modes](#ext_proc-processing-modes)
- [Tap Filter](#tap-filter)
  - [Tap Filter Configuration](#tap-filter-configuration)
  - [Transport Tap](#transport-tap)
- [Custom Access Logs](#custom-access-logs)
  - [File Access Log with Custom Format](#file-access-log-with-custom-format)
  - [gRPC Access Log Service (ALS)](#grpc-access-log-service-als)
  - [OpenTelemetry Access Log](#opentelemetry-access-log)
  - [Useful Access Log Command Operators](#useful-access-log-command-operators)
- [Header Manipulation](#header-manipulation)
  - [Route-Level Header Manipulation](#route-level-header-manipulation)
  - [Virtual Host Level Headers](#virtual-host-level-headers)
  - [Header-to-Metadata Filter](#header-to-metadata-filter)
- [Weighted Routing Patterns](#weighted-routing-patterns)
  - [Canary Deployments](#canary-deployments)
  - [Header-Based Traffic Splitting](#header-based-traffic-splitting)
  - [Runtime-Controlled Traffic Shifting](#runtime-controlled-traffic-shifting)
- [Traffic Mirroring (Shadowing)](#traffic-mirroring-shadowing)
  - [Request Mirroring Configuration](#request-mirroring-configuration)
  - [Mirroring with Runtime Control](#mirroring-with-runtime-control)
- [Fault Injection](#fault-injection)
  - [Delay Injection](#delay-injection)
  - [Abort Injection](#abort-injection)
  - [Header-Triggered Faults](#header-triggered-faults)

---

## xDS Protocol Deep Dive

The xDS (x Discovery Service) protocol is Envoy's mechanism for receiving dynamic configuration from a control plane. It uses gRPC bidirectional streaming (or REST long-polling as fallback).

### State of the World (SotW) vs Delta xDS

**SotW (State of the World)** — the original xDS protocol:

- Control plane sends the **complete set** of resources on every update.
- If you have 10,000 endpoints and 1 changes, the control plane resends all 10,000.
- Uses `DiscoveryRequest` / `DiscoveryResponse` messages.
- Simpler to implement but does not scale well with large resource sets.

```protobuf
// SotW request
message DiscoveryRequest {
  string version_info = 1;        // Last accepted version (ACK) or rejected (NACK)
  Node node = 2;                  // Envoy node identification
  repeated string resource_names = 3;  // Subscribed resource names (empty = wildcard)
  string type_url = 4;            // Resource type
  Status error_detail = 5;       // Set on NACK
}

// SotW response
message DiscoveryResponse {
  string version_info = 1;        // Version of this resource set
  repeated Any resources = 2;    // Complete set of resources
  string type_url = 4;
  string nonce = 5;              // Must be echoed in next request
}
```

**ACK/NACK flow:**
1. Envoy sends `DiscoveryRequest` with empty `version_info` (initial).
2. Control plane sends `DiscoveryResponse` with `version_info: "v1"`, `nonce: "abc"`.
3. Envoy accepts → sends `DiscoveryRequest` with `version_info: "v1"`, `response_nonce: "abc"` (ACK).
4. Envoy rejects → sends `DiscoveryRequest` with previous `version_info`, `response_nonce: "abc"`, `error_detail` set (NACK).

### Aggregated Discovery Service (ADS)

ADS multiplexes all xDS resource types onto a **single gRPC stream**, ensuring ordering guarantees:

```yaml
# Bootstrap configuration for ADS
dynamic_resources:
  ads_config:
    api_type: GRPC
    transport_api_version: V3
    grpc_services:
      - envoy_grpc:
          cluster_name: xds_cluster
  lds_config:
    resource_api_version: V3
    ads: {}
  cds_config:
    resource_api_version: V3
    ads: {}
```

**Why ADS matters:** Without ADS, each xDS type uses a separate stream. This creates race conditions:
- CDS updates a cluster name before RDS references it → traffic drops.
- EDS sends endpoints for a cluster that doesn't exist yet → ignored.

ADS guarantees: CDS → EDS → LDS → RDS ordering on one stream, preventing inconsistencies.

### xDS Resource Ordering and Dependencies

The required ordering for consistent configuration:

1. **CDS** — Cluster definitions must arrive first.
2. **EDS** — Endpoints for those clusters.
3. **LDS** — Listener definitions (may reference clusters for inline route configs).
4. **RDS** — Route configurations referencing clusters.
5. **SDS** — Secrets (TLS certs) can arrive at any point; Envoy blocks listeners until certs are available.

With ADS, the control plane is responsible for sending updates in this order. Without ADS (separate streams per type), Envoy handles best-effort ordering but races are possible.

### Incremental xDS (Delta) Protocol Flow

Delta xDS sends only changed resources, dramatically reducing bandwidth for large deployments:

```protobuf
message DeltaDiscoveryRequest {
  Node node = 1;
  string type_url = 2;
  repeated string resource_names_subscribe = 3;    // New subscriptions
  repeated string resource_names_unsubscribe = 4;  // Remove subscriptions
  map<string, string> initial_resource_versions = 5;  // On reconnect
  string response_nonce = 6;
  Status error_detail = 7;
}

message DeltaDiscoveryResponse {
  repeated Resource resources = 1;         // Changed/new resources
  repeated string removed_resources = 6;   // Deleted resources
  string system_version_info = 2;
  string nonce = 5;
  string type_url = 4;
}
```

**Key differences from SotW:**
- Each resource has its own version (not a global version).
- Explicit subscribe/unsubscribe for individual resources.
- `removed_resources` field for explicit deletions (SotW infers removal by absence).
- On reconnect, client sends `initial_resource_versions` so server knows what to diff.

**When to use Delta xDS:**
- >1,000 endpoints or clusters — SotW becomes expensive.
- Frequent endpoint churn (Kubernetes pod scaling).
- Control plane wants fine-grained resource lifecycle management.

```yaml
# Bootstrap for Delta xDS
dynamic_resources:
  cds_config:
    resource_api_version: V3
    api_config_source:
      api_type: DELTA_GRPC
      transport_api_version: V3
      grpc_services:
        - envoy_grpc:
            cluster_name: xds_cluster
```

---

## WASM Filter Development

### Proxy-WASM ABI Overview

Proxy-WASM defines a stable ABI between the host (Envoy) and guest (WASM module):

- **Host callbacks** — Functions Envoy exposes to the WASM module (e.g., `proxy_get_header_map_value`, `proxy_send_local_response`).
- **Guest exports** — Functions the WASM module exports for Envoy to call (e.g., `proxy_on_request_headers`, `proxy_on_response_body`).
- **Memory model** — Linear memory owned by the WASM module; host copies data in/out via ABI functions.
- **Contexts** — Root context (VM lifecycle), stream context (per-request).

Supported runtimes in Envoy:
- `envoy.wasm.runtime.v8` — Default, production-grade V8 isolate.
- `envoy.wasm.runtime.wasmtime` — Alternative Wasmtime runtime.
- `envoy.wasm.runtime.null` — Native C++ plugin (no WASM sandbox, for development).

### Rust SDK Development

The Rust SDK (`proxy-wasm`) is the most mature and recommended for production:

```toml
# Cargo.toml
[package]
name = "my_envoy_filter"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
proxy-wasm = "0.2"
log = "0.4"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

```rust
// src/lib.rs
use proxy_wasm::traits::*;
use proxy_wasm::types::*;
use log::info;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> {
        Box::new(MyFilterRoot {
            config: String::new(),
        })
    });
}}

struct MyFilterRoot {
    config: String,
}

impl Context for MyFilterRoot {}

impl RootContext for MyFilterRoot {
    fn on_configure(&mut self, _plugin_configuration_size: usize) -> bool {
        if let Some(config_bytes) = self.get_plugin_configuration() {
            self.config = String::from_utf8(config_bytes).unwrap_or_default();
        }
        true
    }

    fn create_http_context(&self, _context_id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(MyFilter {
            config: self.config.clone(),
        }))
    }

    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
}

struct MyFilter {
    config: String,
}

impl Context for MyFilter {}

impl HttpContext for MyFilter {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        // Add a custom header
        self.add_http_request_header("x-wasm-filter", "active");

        // Read an incoming header
        if let Some(auth) = self.get_http_request_header("authorization") {
            if auth.is_empty() {
                self.send_http_response(401, vec![], Some(b"Unauthorized"));
                return Action::Pause;
            }
        }

        // Log request path
        if let Some(path) = self.get_http_request_header(":path") {
            info!("Request path: {}", path);
        }

        Action::Continue
    }

    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        self.add_http_response_header("x-powered-by", "envoy-wasm");
        Action::Continue
    }
}
```

Build:
```bash
rustup target add wasm32-wasip1
cargo build --target wasm32-wasip1 --release
# Output: target/wasm32-wasip1/release/my_envoy_filter.wasm
```

### Go SDK Development (TinyGo)

Go WASM filters require TinyGo (standard Go compiler doesn't target WASI properly for proxy-wasm):

```go
// main.go
package main

import (
    "github.com/tetratelabs/proxy-wasm-go-sdk/proxywasm"
    "github.com/tetratelabs/proxy-wasm-go-sdk/proxywasm/types"
)

func main() {
    proxywasm.SetVMContext(&vmContext{})
}

type vmContext struct {
    types.DefaultVMContext
}

func (*vmContext) NewPluginContext(contextID uint32) types.PluginContext {
    return &pluginContext{}
}

type pluginContext struct {
    types.DefaultPluginContext
}

func (*pluginContext) NewHttpContext(contextID uint32) types.HttpContext {
    return &httpContext{}
}

type httpContext struct {
    types.DefaultHttpContext
}

func (ctx *httpContext) OnHttpRequestHeaders(numHeaders int, endOfStream bool) types.Action {
    path, err := proxywasm.GetHttpRequestHeader(":path")
    if err != nil {
        proxywasm.LogErrorf("failed to get path: %v", err)
        return types.ActionContinue
    }

    proxywasm.LogInfof("request path: %s", path)

    if err := proxywasm.AddHttpRequestHeader("x-wasm-filter", "go"); err != nil {
        proxywasm.LogErrorf("failed to add header: %v", err)
    }

    return types.ActionContinue
}
```

Build:
```bash
tinygo build -o filter.wasm -scheduler=none -target=wasi ./main.go
```

### C++ SDK Development

The C++ SDK provides the lowest-level control and best performance:

```cpp
// filter.cc
#include "proxy_wasm_intrinsics.h"

class MyRootContext : public RootContext {
public:
    explicit MyRootContext(uint32_t id, std::string_view root_id)
        : RootContext(id, root_id) {}
};

class MyHttpContext : public Context {
public:
    explicit MyHttpContext(uint32_t id, RootContext* root)
        : Context(id, root) {}

    FilterHeadersStatus onRequestHeaders(uint32_t headers, bool end_of_stream) override {
        addRequestHeader("x-wasm-filter", "cpp");

        auto path = getRequestHeader(":path");
        LOG_INFO(std::string("Request path: ") + std::string(path->view()));

        return FilterHeadersStatus::Continue;
    }

    FilterHeadersStatus onResponseHeaders(uint32_t headers, bool end_of_stream) override {
        addResponseHeader("x-processed-by", "envoy-wasm-cpp");
        return FilterHeadersStatus::Continue;
    }
};

static RegisterContextFactory register_MyHttpContext(
    CONTEXT_FACTORY(MyHttpContext),
    ROOT_FACTORY(MyRootContext),
    "my_root_id");
```

### WASM VM Lifecycle and Shared Data

```
┌──────────────────────────────────────────────────────┐
│                   Envoy Process                       │
│                                                      │
│  ┌──────────────────┐  ┌──────────────────┐          │
│  │   WASM VM 1       │  │   WASM VM 2       │         │
│  │                   │  │                   │         │
│  │  RootContext      │  │  RootContext      │         │
│  │  ├─ HttpCtx A     │  │  ├─ HttpCtx D     │         │
│  │  ├─ HttpCtx B     │  │  ├─ HttpCtx E     │         │
│  │  └─ HttpCtx C     │  │  └─ HttpCtx F     │         │
│  └──────────────────┘  └──────────────────┘          │
│         │                       │                     │
│         └───── Shared KV Store ─┘                     │
│          (proxy_get/set_shared_data)                  │
└──────────────────────────────────────────────────────┘
```

- Each WASM filter configuration creates a VM group.
- `vm_id` controls VM sharing — same `vm_id` shares a VM (and RootContext).
- `proxy_set_shared_data` / `proxy_get_shared_data` — atomic KV store across VMs with CAS support.
- `proxy_enqueue_shared_queue` / `proxy_dequeue_shared_queue` — inter-VM message passing.

### Deploying WASM Filters

**Local file:**
```yaml
vm_config:
  code:
    local:
      filename: "/etc/envoy/filters/my_filter.wasm"
```

**Remote fetch (OCI or HTTP):**
```yaml
vm_config:
  code:
    remote:
      http_uri:
        uri: "https://storage.example.com/filters/my_filter.wasm"
        cluster: wasm_storage
        timeout: 10s
      sha256: "abc123..."  # Required for integrity
```

---

## Lua Filters

### Lua Filter Configuration

Lua filters are simpler than WASM for lightweight request/response transformations:

```yaml
http_filters:
  - name: envoy.filters.http.lua
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
      default_source_code:
        inline_string: |
          function envoy_on_request(request_handle)
            local path = request_handle:headers():get(":path")
            request_handle:logInfo("Request to: " .. path)

            -- Add a custom header
            request_handle:headers():add("x-lua-processed", "true")

            -- Block requests to /admin
            if string.sub(path, 1, 6) == "/admin" then
              request_handle:respond(
                {[":status"] = "403"},
                "Forbidden"
              )
            end
          end

          function envoy_on_response(response_handle)
            response_handle:headers():add("x-envoy-lua", "1")
          end
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

### Lua Script API

Key API functions available in Lua filters:

```lua
-- Request phase: envoy_on_request(request_handle)
request_handle:headers()                     -- Get/set request headers
request_handle:body()                        -- Get request body (buffers entire body)
request_handle:trailers()                    -- Get request trailers
request_handle:respond(headers, body)        -- Send direct response, skip upstream
request_handle:metadata()                    -- Get route/virtual host metadata
request_handle:httpCall(cluster, headers, body, timeout)  -- Make subrequest
request_handle:logInfo/logWarn/logErr(msg)   -- Logging
request_handle:streamInfo()                  -- Connection/stream metadata
request_handle:connection()                  -- Connection object

-- Response phase: envoy_on_response(response_handle)
response_handle:headers()                    -- Get/set response headers
response_handle:body()                       -- Get response body
response_handle:trailers()                   -- Get response trailers

-- HTTP subrequest example
local headers, body = request_handle:httpCall(
  "auth_cluster",
  {
    [":method"] = "GET",
    [":path"] = "/validate",
    [":authority"] = "auth-service",
    ["authorization"] = request_handle:headers():get("authorization")
  },
  "",    -- body
  5000   -- timeout ms
)
```

### Lua vs WASM Trade-offs

| Aspect | Lua | WASM |
|--------|-----|------|
| **Sandboxing** | Limited (runs in Envoy process) | Full V8/Wasmtime sandbox |
| **Performance** | Good for simple logic | Better for complex computation |
| **Language** | Lua only | Rust, Go, C++, AssemblyScript |
| **Deployment** | Inline in config or file | Separate `.wasm` binary |
| **Async HTTP calls** | Built-in `httpCall()` | Via `dispatch_http_call()` |
| **Body buffering** | Automatic (can be expensive) | Streaming capable |
| **Use case** | Quick header transforms, routing logic | Complex auth, data transforms, policies |

---

## External Processing (ext_proc)

### ext_proc Architecture

ext_proc is a bidirectional gRPC streaming filter that sends request/response data to an external gRPC server for processing. Unlike ext_authz (which only makes allow/deny decisions), ext_proc can **modify** headers and bodies.

```
Client ──► Envoy ──► ext_proc Server (gRPC bidi stream)
                         │
                         ▼
                   Modify headers/body
                         │
              ◄──────────┘
           Envoy forwards modified request ──► Upstream
```

### ext_proc Configuration

```yaml
http_filters:
  - name: envoy.filters.http.ext_proc
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
      grpc_service:
        envoy_grpc:
          cluster_name: ext_proc_cluster
        timeout: 2s
      failure_mode_allow: false
      processing_mode:
        request_header_mode: SEND
        response_header_mode: SEND
        request_body_mode: NONE
        response_body_mode: NONE
        request_trailer_mode: SKIP
        response_trailer_mode: SKIP
      message_timeout: 1s
```

### ext_proc Processing Modes

| Mode | Description |
|------|-------------|
| `SKIP` | Do not send this phase to the external server |
| `SEND` | Send headers; body is not buffered |
| `BUFFERED` | Buffer entire body and send as one message |
| `STREAMED` | Stream body chunks to external server |
| `BUFFERED_PARTIAL` | Buffer up to a limit, then send partial |

The external server receives `ProcessingRequest` and returns `ProcessingResponse`:

```protobuf
message ProcessingRequest {
  oneof request {
    HttpHeaders request_headers = 2;
    HttpBody request_body = 3;
    HttpTrailers request_trailers = 4;
    HttpHeaders response_headers = 5;
    HttpBody response_body = 6;
    HttpTrailers response_trailers = 7;
  }
}

message ProcessingResponse {
  oneof response {
    HeadersResponse request_headers = 1;
    BodyResponse request_body = 2;
    // ... mirrors request phases
  }
  // Can mutate headers, replace body, or end processing
}
```

---

## Tap Filter

The tap filter captures full request/response pairs for debugging or auditing.

### Tap Filter Configuration

```yaml
http_filters:
  - name: envoy.filters.http.tap
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.tap.v3.Tap
      common_config:
        static_config:
          match_config:
            # Tap requests matching any of these conditions
            or_match:
              rules:
                - http_request_headers_match:
                    headers:
                      - name: x-debug
                        exact_match: "true"
                - http_response_headers_match:
                    headers:
                      - name: ":status"
                        exact_match: "500"
          output_config:
            sinks:
              - file_per_tap:
                  path_prefix: /tmp/envoy-tap/
            max_buffered_rx_bytes: 1048576
            max_buffered_tx_bytes: 1048576
```

Admin-triggered tapping (runtime, no restart):
```bash
# POST to admin to start tapping
curl -X POST "http://localhost:9901/tap" \
  -d '{
    "config_id": "http_tap",
    "tap_config": {
      "match_config": {
        "http_request_headers_match": {
          "headers": [{"name": ":path", "prefix_match": "/api"}]
        }
      },
      "output_config": {
        "streaming": true
      }
    }
  }'
```

### Transport Tap

Capture raw TCP bytes (L4):

```yaml
filter_chains:
  - filters:
      - name: envoy.filters.network.tap
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.tap.v3.Tap
          common_config:
            static_config:
              match_config:
                any_match: true
              output_config:
                sinks:
                  - file_per_tap:
                      path_prefix: /tmp/tcp-tap/
```

---

## Custom Access Logs

### File Access Log with Custom Format

```yaml
access_log:
  - name: envoy.access_loggers.file
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
      path: /var/log/envoy/access.log
      log_format:
        json_format:
          timestamp: "%START_TIME(%Y-%m-%dT%H:%M:%S%z)%"
          method: "%REQ(:METHOD)%"
          path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
          protocol: "%PROTOCOL%"
          response_code: "%RESPONSE_CODE%"
          response_flags: "%RESPONSE_FLAGS%"
          bytes_received: "%BYTES_RECEIVED%"
          bytes_sent: "%BYTES_SENT%"
          duration_ms: "%DURATION%"
          upstream_service_time: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
          upstream_host: "%UPSTREAM_HOST%"
          upstream_cluster: "%UPSTREAM_CLUSTER%"
          request_id: "%REQ(X-REQUEST-ID)%"
          user_agent: "%REQ(USER-AGENT)%"
          downstream_remote: "%DOWNSTREAM_REMOTE_ADDRESS%"
          route_name: "%ROUTE_NAME%"
          connection_termination: "%CONNECTION_TERMINATION_DETAILS%"
```

### gRPC Access Log Service (ALS)

Send access logs to a remote gRPC service:

```yaml
access_log:
  - name: envoy.access_loggers.http_grpc
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.access_loggers.grpc.v3.HttpGrpcAccessLogConfig
      common_config:
        log_name: "envoy_access_log"
        grpc_service:
          envoy_grpc:
            cluster_name: als_cluster
        transport_api_version: V3
      additional_request_headers_to_log:
        - "x-request-id"
        - "authorization"
      additional_response_headers_to_log:
        - "x-ratelimit-remaining"
```

### OpenTelemetry Access Log

```yaml
access_log:
  - name: envoy.access_loggers.open_telemetry
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.access_loggers.open_telemetry.v3.OpenTelemetryAccessLogConfig
      common_config:
        log_name: "otel_envoy_access"
        grpc_service:
          envoy_grpc:
            cluster_name: otel_collector
        transport_api_version: V3
      body:
        string_value: "%REQ(:METHOD)% %REQ(:PATH)% %PROTOCOL% %RESPONSE_CODE% %RESPONSE_FLAGS%"
      attributes:
        values:
          - key: "upstream.host"
            value:
              string_value: "%UPSTREAM_HOST%"
          - key: "duration"
            value:
              string_value: "%DURATION%"
```

### Useful Access Log Command Operators

| Operator | Description |
|----------|-------------|
| `%RESPONSE_FLAGS%` | Why the response was generated (UH, UF, UO, NR, etc.) |
| `%UPSTREAM_HOST%` | Upstream IP:port selected |
| `%UPSTREAM_CLUSTER%` | Cluster name selected by router |
| `%UPSTREAM_TRANSPORT_FAILURE_REASON%` | TLS handshake failure details |
| `%DURATION%` | Total request duration (ms) |
| `%REQUEST_DURATION%` | Time receiving request (ms) |
| `%RESPONSE_DURATION%` | Time from upstream first byte to last byte (ms) |
| `%RESPONSE_TX_DURATION%` | Time sending response to downstream (ms) |
| `%DOWNSTREAM_REMOTE_ADDRESS%` | Client IP:port |
| `%REQUESTED_SERVER_NAME%` | SNI value from TLS handshake |
| `%ROUTE_NAME%` | Matched route name |
| `%UPSTREAM_REQUEST_ATTEMPT_COUNT%` | Number of attempts (retries) |
| `%CONNECTION_TERMINATION_DETAILS%` | Why connection was closed |

**Response flags reference:**

| Flag | Meaning |
|------|---------|
| `UH` | No healthy upstream |
| `UF` | Upstream connection failure |
| `UO` | Upstream overflow (circuit breaker) |
| `NR` | No route configured |
| `URX` | Upstream retry limit exceeded |
| `NC` | No cluster found |
| `DT` | Downstream request timeout |
| `DC` | Downstream connection termination |
| `RL` | Rate limited |
| `UAEX` | Unauthorized external service |
| `IH` | Invalid header value |

---

## Header Manipulation

### Route-Level Header Manipulation

```yaml
routes:
  - match:
      prefix: "/api"
    route:
      cluster: api_backend
    request_headers_to_add:
      - header:
          key: "x-custom-route"
          value: "api"
        append_action: OVERWRITE_IF_EXISTS_OR_ADD
    request_headers_to_remove:
      - "x-internal-only"
    response_headers_to_add:
      - header:
          key: "x-served-by"
          value: "%UPSTREAM_HOST%"
        append_action: ADD_IF_ABSENT
    response_headers_to_remove:
      - "server"
      - "x-powered-by"
```

### Virtual Host Level Headers

```yaml
virtual_hosts:
  - name: api
    domains: ["api.example.com"]
    request_headers_to_add:
      - header:
          key: "x-vhost"
          value: "api"
    routes:
      - match: { prefix: "/" }
        route: { cluster: api_backend }
```

Header evaluation order: route → virtual host → connection manager (most specific wins).

### Header-to-Metadata Filter

Convert incoming headers to dynamic metadata for use by other filters:

```yaml
http_filters:
  - name: envoy.filters.http.header_to_metadata
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.header_to_metadata.v3.Config
      request_rules:
        - header: x-tenant-id
          on_header_present:
            metadata_namespace: envoy.lb
            key: tenant_id
            type: STRING
          on_header_missing:
            metadata_namespace: envoy.lb
            key: tenant_id
            value: "default"
            type: STRING
```

Use with subset load balancing:
```yaml
clusters:
  - name: multi_tenant
    lb_policy: ROUND_ROBIN
    lb_subset_config:
      fallback_policy: DEFAULT_SUBSET
      default_subset:
        tenant_id: "default"
      subset_selectors:
        - keys: ["tenant_id"]
```

---

## Weighted Routing Patterns

### Canary Deployments

Progressive rollout with runtime-adjustable weights:

```yaml
routes:
  - match:
      prefix: "/"
    route:
      weighted_clusters:
        clusters:
          - name: service_v1
            weight: 95
          - name: service_v2
            weight: 5
        runtime_key_prefix: routing.traffic_split
```

The runtime key allows changing weights without config reload:
```bash
# Shift more traffic to v2
curl -X POST "http://localhost:9901/runtime_modify?routing.traffic_split.service_v2=20"
```

### Header-Based Traffic Splitting

Route internal testers to the canary:

```yaml
routes:
  # Internal testers always go to v2
  - match:
      prefix: "/"
      headers:
        - name: x-canary
          exact_match: "true"
    route:
      cluster: service_v2

  # Everyone else gets weighted split
  - match:
      prefix: "/"
    route:
      weighted_clusters:
        clusters:
          - name: service_v1
            weight: 95
          - name: service_v2
            weight: 5
```

### Runtime-Controlled Traffic Shifting

Use runtime fractional percent for gradual rollouts:

```yaml
routes:
  - match:
      prefix: "/"
      runtime_fraction:
        default_value:
          numerator: 5
          denominator: HUNDRED
        runtime_key: routing.canary_percent
    route:
      cluster: service_v2
  - match:
      prefix: "/"
    route:
      cluster: service_v1
```

---

## Traffic Mirroring (Shadowing)

### Request Mirroring Configuration

Mirror a percentage of traffic to a shadow cluster for testing:

```yaml
routes:
  - match:
      prefix: "/"
    route:
      cluster: production
      request_mirror_policies:
        - cluster: shadow_cluster
          runtime_fraction:
            default_value:
              numerator: 100
              denominator: HUNDRED
```

Key behaviors:
- Mirrored requests are fire-and-forget (responses discarded).
- Original request is never delayed by the mirror.
- The `host` / `:authority` header is appended with `-shadow` suffix.
- Mirrored request carries same headers/body as the original.
- Mirror failures do not affect the primary request.

### Mirroring with Runtime Control

```yaml
request_mirror_policies:
  - cluster: shadow_v2
    runtime_fraction:
      default_value:
        numerator: 10
        denominator: HUNDRED
      runtime_key: mirror.shadow_v2_pct
```

Adjust at runtime:
```bash
curl -X POST "http://localhost:9901/runtime_modify?mirror.shadow_v2_pct=50"
```

---

## Fault Injection

The fault injection filter introduces controlled failures for chaos testing.

### Delay Injection

```yaml
http_filters:
  - name: envoy.filters.http.fault
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault
      delay:
        fixed_delay: 3s
        percentage:
          numerator: 10
          denominator: HUNDRED
```

### Abort Injection

```yaml
http_filters:
  - name: envoy.filters.http.fault
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault
      abort:
        http_status: 503
        percentage:
          numerator: 5
          denominator: HUNDRED
```

### Header-Triggered Faults

Allow per-request fault injection via headers (useful in staging):

```yaml
http_filters:
  - name: envoy.filters.http.fault
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault
      delay:
        header_delay: {}
        percentage:
          numerator: 100
          denominator: HUNDRED
      abort:
        header_abort: {}
        percentage:
          numerator: 100
          denominator: HUNDRED
```

Trigger via request headers:
```bash
# Inject 2-second delay
curl -H "x-envoy-fault-delay-request: 2000" http://service/api

# Inject 503 abort
curl -H "x-envoy-fault-abort-request: 503" http://service/api

# Both together
curl -H "x-envoy-fault-delay-request: 1000" \
     -H "x-envoy-fault-abort-request: 500" \
     http://service/api
```

Combine with route-level fault injection for per-route chaos:

```yaml
routes:
  - match:
      prefix: "/api/v2"
    route:
      cluster: api_v2
    typed_per_filter_config:
      envoy.filters.http.fault:
        "@type": type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault
        delay:
          fixed_delay: 500ms
          percentage:
            numerator: 50
            denominator: HUNDRED
```
