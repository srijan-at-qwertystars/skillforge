# WASM Filter Template — Envoy Proxy-WASM (Rust)

Minimal scaffold for building an Envoy WASM filter using the Proxy-WASM Rust SDK.

## Prerequisites

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Add WASI target
rustup target add wasm32-wasip1
```

## Build

```bash
cargo build --target wasm32-wasip1 --release
# Output: target/wasm32-wasip1/release/envoy_wasm_filter.wasm
```

## Configure in Envoy

```yaml
http_filters:
  - name: envoy.filters.http.wasm
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
      config:
        name: my_filter
        root_id: ""
        vm_config:
          runtime: envoy.wasm.runtime.v8
          code:
            local:
              filename: "/filters/envoy_wasm_filter.wasm"
        configuration:
          "@type": type.googleapis.com/google.protobuf.StringValue
          value: '{"header_name":"x-custom","header_value":"my-value"}'
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

## Project Structure

```
wasm-filter-template/
├── Cargo.toml      # Rust project manifest
├── README.md       # This file
└── src/
    └── lib.rs      # Filter implementation
```

## Extending

The template demonstrates:
- Plugin configuration parsing (JSON → struct via serde)
- Request header injection
- Response header injection
- Per-request logging

Common extensions:
- **Authentication:** Check `authorization` header, call `send_http_response(401, ...)`.
- **Rate limiting:** Use `proxy_set_shared_data` / `proxy_get_shared_data` for counters.
- **Body transformation:** Implement `on_http_request_body` / `on_http_response_body`.
- **External calls:** Use `dispatch_http_call` for async HTTP subrequests.
