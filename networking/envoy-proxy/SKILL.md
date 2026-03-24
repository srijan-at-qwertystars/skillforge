---
name: envoy-proxy
description: >
  Expert guidance for Envoy Proxy configuration, architecture, and operations using the v3 API.
  Use when: configuring Envoy proxy, writing envoy.yaml, setting up xDS dynamic configuration,
  building Envoy filter chains, configuring Envoy listeners/clusters/routes, rate limiting with
  Envoy, writing Envoy WASM filters, Envoy ext_authz, Envoy circuit breaking, Envoy health checks,
  Envoy TLS/mTLS, Envoy load balancing, Envoy as Istio sidecar, Envoy admin interface debugging,
  Envoy access logs, Envoy stats/tracing/observability.
  NOT for: Nginx, HAProxy, Traefik, Caddy, Apache HTTPD, or general reverse proxy questions
  without Envoy context. Not for Envoy Gateway CRDs (separate project).
---

# Envoy Proxy Skill

## Core Architecture

Envoy is an L3/L4/L7 proxy designed for cloud-native applications. Key components:

- **Listeners** — Bind to addresses/ports, accept connections. Each has filter chains.
- **Filter Chains** — Ordered pipeline of network (L3/L4) and HTTP (L7) filters processing traffic.
- **Clusters** — Named groups of upstream endpoints Envoy routes traffic to.
- **Endpoints** — Individual backend instances (IP:port) within a cluster.
- **Routes** — Rules mapping incoming requests to clusters via virtual hosts.

All config uses the **v3 API** (`envoy.config.*.v3.*`). v2 is fully deprecated.

## Configuration Structure

### Static Configuration (envoy.yaml)

```yaml
static_resources:
  listeners:
    - name: http_listener
      address:
        socket_address: { address: 0.0.0.0, port_value: 8080 }
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress
                route_config:
                  name: local_route
                  virtual_hosts:
                    - name: backend
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route: { cluster: my_service }
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
    - name: my_service
      connect_timeout: 0.25s
      type: STRICT_DNS
      lb_policy: ROUND_ROBIN
      load_assignment:
        cluster_name: my_service
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: backend, port_value: 8080 }
admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: 9901 }
```

### Dynamic Configuration (xDS)

xDS APIs deliver config dynamically from a control plane (Istio, custom gRPC server):

| API | Purpose | Type URL |
|-----|---------|----------|
| **LDS** | Listener Discovery | `envoy.config.listener.v3.Listener` |
| **RDS** | Route Discovery | `envoy.config.route.v3.RouteConfiguration` |
| **CDS** | Cluster Discovery | `envoy.config.cluster.v3.Cluster` |
| **EDS** | Endpoint Discovery | `envoy.config.endpoint.v3.ClusterLoadAssignment` |
| **SDS** | Secret (TLS cert) Discovery | `envoy.extensions.transport_sockets.tls.v3.Secret` |
| **ADS** | Aggregated (multiplexed) | All above on one gRPC stream |

Bootstrap for dynamic config:

```yaml
dynamic_resources:
  lds_config:
    resource_api_version: V3
    api_config_source:
      api_type: GRPC
      transport_api_version: V3
      grpc_services:
        - envoy_grpc: { cluster_name: xds_cluster }
  cds_config:
    resource_api_version: V3
    api_config_source:
      api_type: GRPC
      transport_api_version: V3
      grpc_services:
        - envoy_grpc: { cluster_name: xds_cluster }
static_resources:
  clusters:
    - name: xds_cluster
      type: STRICT_DNS
      connect_timeout: 1s
      load_assignment:
        cluster_name: xds_cluster
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: control-plane, port_value: 18000 }
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http2_protocol_options: {}
```

## Routing & Traffic Management

### Weighted Clusters (Canary / Blue-Green)

```yaml
routes:
  - match: { prefix: "/" }
    route:
      weighted_clusters:
        clusters:
          - name: v1
            weight: 90
          - name: v2
            weight: 10
```

### Header-Based Routing

```yaml
routes:
  - match:
      prefix: "/api"
      headers:
        - name: x-version
          exact_match: "beta"
    route: { cluster: api_beta }
  - match: { prefix: "/api" }
    route: { cluster: api_stable }
```

### Retry Policy

```yaml
route:
  cluster: my_service
  retry_policy:
    retry_on: "5xx,connect-failure,retriable-status-codes"
    num_retries: 3
    per_try_timeout: 2s
    retriable_status_codes: [503]
```

## Load Balancing

Supported `lb_policy` values on clusters:

- `ROUND_ROBIN` — Default, equal distribution
- `LEAST_REQUEST` — Picks host with fewest active requests
- `RING_HASH` — Consistent hashing (sticky sessions)
- `RANDOM` — Random selection
- `MAGLEV` — Fast consistent hashing (better distribution than ring hash)

Ring hash example for session affinity:

```yaml
clusters:
  - name: sticky_service
    lb_policy: RING_HASH
    ring_hash_lb_config:
      minimum_ring_size: 1024
```

With route-level hash policy:

```yaml
route:
  cluster: sticky_service
  hash_policy:
    - cookie: { name: SESSION_ID, ttl: 0s }
```

## Health Checking

```yaml
clusters:
  - name: my_service
    health_checks:
      - timeout: 1s
        interval: 5s
        unhealthy_threshold: 3
        healthy_threshold: 2
        http_health_check:
          path: "/healthz"
          expected_statuses:
            - start: 200
              end: 300
```

## Circuit Breaking

```yaml
clusters:
  - name: my_service
    circuit_breakers:
      thresholds:
        - priority: DEFAULT
          max_connections: 100
          max_pending_requests: 1000
          max_requests: 5000
          max_retries: 3
        - priority: HIGH
          max_connections: 200
          max_pending_requests: 2000
```

When thresholds are hit, Envoy returns 503 and increments `upstream_cx_overflow` / `upstream_rq_pending_overflow` stats.

## Rate Limiting

### Local Rate Limit (per-instance)

```yaml
http_filters:
  - name: envoy.filters.http.local_ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
      stat_prefix: local_rl
      token_bucket:
        max_tokens: 100
        tokens_per_fill: 100
        fill_interval: 60s
      filter_enabled:
        runtime_key: local_rate_limit_enabled
        default_value: { numerator: 100, denominator: HUNDRED }
      filter_enforced:
        runtime_key: local_rate_limit_enforced
        default_value: { numerator: 100, denominator: HUNDRED }
```

### Global Rate Limit (external service)

```yaml
http_filters:
  - name: envoy.filters.http.ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
      domain: my_domain
      rate_limit_service:
        grpc_service:
          envoy_grpc: { cluster_name: rate_limit_cluster }
        transport_api_version: V3
```

## TLS / mTLS

### Downstream TLS (with client cert = mTLS)

```yaml
filter_chains:
  - transport_socket:
      name: envoy.transport_sockets.tls
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
        common_tls_context:
          tls_certificates:
            - certificate_chain: { filename: "/certs/server.crt" }
              private_key: { filename: "/certs/server.key" }
          validation_context:
            trusted_ca: { filename: "/certs/ca.crt" }
        require_client_certificate: true  # omit for TLS-only
```

### Upstream mTLS (Envoy → backend)

```yaml
clusters:
  - name: mtls_backend
    transport_socket:
      name: envoy.transport_sockets.tls
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
        common_tls_context:
          tls_certificates:
            - certificate_chain: { filename: "/certs/client.crt" }
              private_key: { filename: "/certs/client.key" }
        sni: backend.example.com
```

## Observability

### Access Logs

```yaml
access_log:
  - name: envoy.access_loggers.stdout
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
      log_format:
        json_format:
          timestamp: "%START_TIME%"
          method: "%REQ(:METHOD)%"
          path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
          status: "%RESPONSE_CODE%"
          duration_ms: "%DURATION%"
          upstream: "%UPSTREAM_HOST%"
          trace_id: "%REQ(X-REQUEST-ID)%"
```

### Stats (Prometheus)

Scrape `http://<admin>:9901/stats/prometheus`. Key stat prefixes:
- `cluster.<name>.upstream_rq_*` — upstream request metrics
- `listener.<addr>.downstream_cx_*` — connection metrics
- `http.<stat_prefix>.downstream_rq_*` — HTTP request metrics

### Distributed Tracing

```yaml
tracing:
  http:
    name: envoy.tracers.opentelemetry
    typed_config:
      "@type": type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig
      grpc_service:
        envoy_grpc: { cluster_name: otel_collector }
      service_name: my-envoy
```

Envoy propagates trace context (`x-request-id`, `x-b3-traceid`, W3C `traceparent`).

## WASM Filters

```yaml
http_filters:
  - name: envoy.filters.http.wasm
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
      config:
        name: my_filter
        root_id: my_root
        vm_config:
          runtime: envoy.wasm.runtime.v8
          code:
            local: { filename: "/filters/my_filter.wasm" }
        configuration:
          "@type": type.googleapis.com/google.protobuf.StringValue
          value: '{"log_level":"info"}'
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

WASM filters run in a sandboxed V8/Wasmtime VM. Build with proxy-wasm SDKs (Rust, Go, C++, AssemblyScript).

## External Authorization (ext_authz)

### gRPC ext_authz

```yaml
http_filters:
  - name: envoy.filters.http.ext_authz
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
      grpc_service:
        envoy_grpc: { cluster_name: auth_service }
        timeout: 0.5s
      transport_api_version: V3
```

### HTTP ext_authz

```yaml
http_filters:
  - name: envoy.filters.http.ext_authz
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
      http_service:
        server_uri:
          uri: http://auth-service:8080
          cluster: auth_service
          timeout: 0.5s
        authorization_request:
          allowed_headers:
            patterns:
              - exact: authorization
              - exact: cookie
```

## Envoy as Sidecar (Istio)

In Istio, Envoy runs as a sidecar injected into each pod. Istio's istiod provides xDS config:
- `EnvoyFilter` CRD — patches generated Envoy config (add filters, modify clusters)
- `DestinationRule` — maps to cluster settings (TLS mode, LB policy, circuit breakers)
- `VirtualService` — maps to route config (retries, timeouts, fault injection, traffic splitting)

## Admin Interface Debugging

Key admin endpoints at `http://127.0.0.1:9901`:

| Endpoint | Purpose |
|----------|---------|
| `/config_dump` | Full running config (JSON) |
| `/clusters` | Cluster membership, health status, stats |
| `/stats?filter=<regex>` | Filtered stats |
| `/stats/prometheus` | Prometheus-format metrics |
| `/logging?level=debug` | Change log level at runtime |
| `/server_info` | Version, uptime, state |
| `/ready` | Readiness probe (200 if live) |

Debug connection issues: `curl localhost:9901/clusters` shows per-endpoint health, active connections, and request counts.

## Examples

### Input: "Configure Envoy to route /api to a backend with retries and circuit breaking"

Output:

```yaml
static_resources:
  listeners:
    - name: main
      address:
        socket_address: { address: 0.0.0.0, port_value: 8080 }
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: api
                route_config:
                  virtual_hosts:
                    - name: api
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/api" }
                          route:
                            cluster: api_backend
                            retry_policy:
                              retry_on: "5xx,connect-failure"
                              num_retries: 3
                              per_try_timeout: 1s
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
    - name: api_backend
      connect_timeout: 0.5s
      type: STRICT_DNS
      lb_policy: LEAST_REQUEST
      circuit_breakers:
        thresholds:
          - max_connections: 50
            max_pending_requests: 500
            max_requests: 1000
            max_retries: 3
      health_checks:
        - timeout: 1s
          interval: 5s
          unhealthy_threshold: 3
          healthy_threshold: 2
          http_health_check: { path: "/healthz" }
      load_assignment:
        cluster_name: api_backend
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: api-svc, port_value: 8080 }
```

### Input: "How do I debug why Envoy returns 503?"

Output: Check these in order:
1. `curl localhost:9901/clusters` — verify endpoint health (look for `health_flags`)
2. `curl localhost:9901/stats?filter=upstream_cx` — check `upstream_cx_connect_fail`, `upstream_cx_overflow`
3. If `upstream_rq_pending_overflow > 0` → circuit breaker tripped, raise thresholds
4. If endpoints show `failed_active_hc` → fix health check path or backend health
5. Check access logs for `RESPONSE_FLAGS`: `UH` (no healthy upstream), `UF` (upstream connection failure), `UO` (upstream overflow / circuit breaker)
