# Envoy Proxy — Troubleshooting Guide

## Table of Contents

- [Common Errors and Fixes](#common-errors-and-fixes)
  - [503 — No Healthy Upstream (UH)](#503--no-healthy-upstream-uh)
  - [503 — Upstream Connection Failure (UF)](#503--upstream-connection-failure-uf)
  - [503 — Upstream Overflow / Circuit Breaker (UO)](#503--upstream-overflow--circuit-breaker-uo)
  - [404 — No Route Matched (NR)](#404--no-route-matched-nr)
  - [TLS Handshake Failures](#tls-handshake-failures)
  - [Connection Reset / Timeout](#connection-reset--timeout)
  - [413 — Payload Too Large](#413--payload-too-large)
  - [431 — Request Header Fields Too Large](#431--request-header-fields-too-large)
- [Admin Interface Debugging](#admin-interface-debugging)
  - [/clusters — Endpoint Health and Stats](#clusters--endpoint-health-and-stats)
  - [/config_dump — Full Running Configuration](#config_dump--full-running-configuration)
  - [/stats — Metrics and Counters](#stats--metrics-and-counters)
  - [/listeners — Active Listeners](#listeners--active-listeners)
  - [/logging — Runtime Log Level](#logging--runtime-log-level)
  - [/runtime — Runtime Feature Flags](#runtime--runtime-feature-flags)
- [Access Log Analysis](#access-log-analysis)
  - [Response Flags Reference](#response-flags-reference)
  - [Analyzing Latency Issues](#analyzing-latency-issues)
  - [Identifying Upstream Failures](#identifying-upstream-failures)
- [Reloadable Features](#reloadable-features)
  - [envoy.reloadable_features Overview](#envoyreloadable_features-overview)
  - [Common Reloadable Feature Toggles](#common-reloadable-feature-toggles)
- [Upstream Connection Pool Issues](#upstream-connection-pool-issues)
  - [Connection Pool Exhaustion](#connection-pool-exhaustion)
  - [HTTP/2 Connection Issues](#http2-connection-issues)
  - [TCP Connection Lifecycle](#tcp-connection-lifecycle)
- [Memory and CPU Profiling](#memory-and-cpu-profiling)
  - [Memory Analysis](#memory-analysis)
  - [CPU Profiling](#cpu-profiling)
  - [Buffer Overflows and OOM](#buffer-overflows-and-oom)
- [Debugging Recipes](#debugging-recipes)
  - [Full Request Tracing](#full-request-tracing)
  - [xDS Debugging](#xds-debugging)
  - [WASM Filter Debugging](#wasm-filter-debugging)

---

## Common Errors and Fixes

### 503 — No Healthy Upstream (UH)

**Symptom:** All requests return 503 with response flag `UH`.

**Diagnosis:**
```bash
# Check cluster health
curl -s localhost:9901/clusters | grep -E "(health_flags|cx_active|membership)"

# Look for:
# service_name::10.0.0.5:8080::health_flags::/failed_active_hc/...
# service_name::default_priority::max_connections::100
# service_name::added_via_api::true
```

**Common causes and fixes:**

1. **All endpoints failing health checks:**
   ```bash
   # Check health check stats
   curl -s localhost:9901/stats?filter=health_check
   # Look for: cluster.my_service.health_check.attempt: 100
   #           cluster.my_service.health_check.failure: 100
   ```
   Fix: Verify health check path responds with 200 on backends. Check `expected_statuses` range.

2. **DNS resolution failure (STRICT_DNS cluster):**
   ```bash
   curl -s localhost:9901/stats?filter=dns
   # Look for: cluster.my_service.update_no_rebuild: increasing
   #           cluster.my_service.dns.resolve_failed: > 0
   ```
   Fix: Verify DNS name resolves from Envoy's network. Check `dns_resolvers` config.

3. **No endpoints configured (EDS):**
   ```bash
   curl -s localhost:9901/clusters | grep "membership_total"
   # cluster.my_service::observability_name::my_service
   # cluster.my_service::default_priority::membership_total::0
   ```
   Fix: Verify control plane is sending endpoints via EDS. Check xDS connection.

4. **Outlier detection ejected all hosts:**
   ```bash
   curl -s localhost:9901/stats?filter=outlier
   # cluster.my_service.outlier_detection.ejections_active: 3 (= total hosts)
   ```
   Fix: Set `max_ejection_percent` to less than 100 or tune outlier thresholds.

### 503 — Upstream Connection Failure (UF)

**Symptom:** 503 with response flag `UF`.

**Diagnosis:**
```bash
curl -s localhost:9901/stats?filter=upstream_cx
# cluster.my_service.upstream_cx_connect_fail: increasing
# cluster.my_service.upstream_cx_connect_timeout: increasing
```

**Common causes:**

1. **Backend not listening on expected port:**
   ```bash
   # From Envoy's container/host, test connectivity
   nc -zv backend-host 8080
   ```

2. **Connect timeout too aggressive:**
   ```yaml
   clusters:
     - name: my_service
       connect_timeout: 0.25s  # Too low for cross-region
       # Increase to 1s-5s for remote backends
   ```

3. **Network policy blocking traffic (Kubernetes):**
   ```bash
   # Check if Envoy can reach the pod
   kubectl exec envoy-pod -- curl -v backend-pod:8080/healthz
   ```

### 503 — Upstream Overflow / Circuit Breaker (UO)

**Symptom:** 503 with response flag `UO`.

**Diagnosis:**
```bash
curl -s localhost:9901/stats?filter=circuit_breaker
# cluster.my_service.circuit_breakers.default.cx_open: 1
# cluster.my_service.circuit_breakers.default.rq_pending_open: 1

curl -s localhost:9901/stats?filter=upstream_rq_pending_overflow
# cluster.my_service.upstream_rq_pending_overflow: 500  # requests rejected
```

**Fix:** Tune circuit breaker thresholds:
```yaml
circuit_breakers:
  thresholds:
    - priority: DEFAULT
      max_connections: 1024       # from default 1024
      max_pending_requests: 1024  # from default 1024
      max_requests: 1024          # from default 1024
      max_retries: 3              # from default 3
      track_remaining: true       # expose remaining budget in stats
```

Monitor remaining budget:
```bash
curl -s localhost:9901/stats?filter=remaining
# cluster.my_service.circuit_breakers.default.remaining_cx: 800
# cluster.my_service.circuit_breakers.default.remaining_pending: 990
```

### 404 — No Route Matched (NR)

**Symptom:** 404 with response flag `NR`.

**Diagnosis:**
```bash
# Dump route config
curl -s localhost:9901/config_dump?resource=dynamic_route_configs | python3 -m json.tool

# Or for static routes
curl -s localhost:9901/config_dump?resource=static_route_configs | python3 -m json.tool

# Check what domains/hosts are configured
curl -s localhost:9901/config_dump | grep -A5 '"domains"'
```

**Common causes:**

1. **Host header doesn't match any virtual host domain:**
   ```yaml
   virtual_hosts:
     - name: backend
       domains: ["api.example.com"]  # Won't match "localhost" or IP
       # Fix: Add all expected domains or use ["*"] for catch-all
   ```

2. **Path doesn't match any route:**
   ```yaml
   routes:
     - match: { prefix: "/api/" }  # Won't match "/api" (no trailing slash)
       # Fix: Use prefix: "/api" to match both
   ```

3. **Route order matters — first match wins:**
   ```yaml
   routes:
     - match: { prefix: "/" }       # This catches everything
       route: { cluster: default }
     - match: { prefix: "/api" }    # Never reached!
       route: { cluster: api }
   ```

### TLS Handshake Failures

**Symptom:** Connection drops, `UPSTREAM_TRANSPORT_FAILURE_REASON` in access logs.

**Diagnosis:**
```bash
# Check TLS stats
curl -s localhost:9901/stats?filter=ssl
# listener.0.0.0.0_443.ssl.handshake: 100
# listener.0.0.0.0_443.ssl.fail_verify_error: 50
# listener.0.0.0.0_443.ssl.connection_error: 10

# Check upstream TLS
curl -s localhost:9901/stats?filter=ssl | grep upstream
# cluster.my_service.ssl.handshake: 80
# cluster.my_service.ssl.fail_verify_error: 20
```

**Common causes:**

1. **Certificate expired:**
   ```bash
   openssl x509 -in /certs/server.crt -noout -dates
   ```

2. **CA mismatch (mTLS):**
   ```bash
   # Verify client cert was signed by the trusted CA
   openssl verify -CAfile /certs/ca.crt /certs/client.crt
   ```

3. **SNI mismatch:**
   ```yaml
   # Upstream TLS context must set correct SNI
   transport_socket:
     typed_config:
       "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
       sni: "backend.example.com"  # Must match server cert CN/SAN
   ```

4. **TLS version mismatch:**
   ```yaml
   common_tls_context:
     tls_params:
       tls_minimum_protocol_version: TLSv1_2
       tls_maximum_protocol_version: TLSv1_3
   ```

5. **SDS secret not yet available:**
   ```bash
   curl -s localhost:9901/stats?filter=sds
   # Check: sds.*.update_rejected or sds.*.init_fetch_timeout
   ```

### Connection Reset / Timeout

**Diagnosis:**
```bash
curl -s localhost:9901/stats?filter=downstream_cx_destroy
# http.ingress.downstream_cx_destroy_remote_active_rq: > 0 means client disconnected

curl -s localhost:9901/stats?filter=upstream_rq_timeout
# cluster.my_service.upstream_rq_timeout: increasing
```

**Common causes:**

1. **Idle timeout too aggressive:**
   ```yaml
   # HTTP Connection Manager
   common_http_protocol_options:
     idle_timeout: 300s  # Default 1h; lower if seeing idle connection buildup
   ```

2. **Request/route timeout:**
   ```yaml
   route:
     cluster: slow_service
     timeout: 60s  # Default 15s — increase for slow endpoints
   ```

3. **Stream idle timeout:**
   ```yaml
   # In HttpConnectionManager
   stream_idle_timeout: 300s  # Default 5min
   ```

### 413 — Payload Too Large

```yaml
# Increase in HttpConnectionManager
http_connection_manager:
  # Per-route override
  route_config:
    virtual_hosts:
      - routes:
          - match: { prefix: "/upload" }
            route:
              cluster: upload_service
              max_grpc_timeout: 0s
            per_request_buffer_limit_bytes: 52428800  # 50MB
```

Or globally:
```yaml
http_connection_manager:
  # No global max by default, but per_connection_buffer_limit applies
  per_connection_buffer_limit_bytes: 52428800
```

### 431 — Request Header Fields Too Large

```yaml
http_connection_manager:
  max_request_headers_kb: 96  # Default 60KB, max 8192KB
```

---

## Admin Interface Debugging

### /clusters — Endpoint Health and Stats

```bash
# Full cluster status
curl -s localhost:9901/clusters

# Output format per endpoint:
# cluster_name::IP:PORT::health_flags::...
# cluster_name::IP:PORT::weight::100
# cluster_name::IP:PORT::region::us-east-1
# cluster_name::IP:PORT::zone::us-east-1a
# cluster_name::IP:PORT::sub_zone::
# cluster_name::IP:PORT::canary::false
# cluster_name::IP:PORT::priority::0
# cluster_name::IP:PORT::success_rate::99.5
# cluster_name::IP:PORT::local_origin_success_rate::100

# Filter for unhealthy
curl -s localhost:9901/clusters | grep "health_flags" | grep -v "health_flags::"

# Health flag values:
# /failed_active_hc  — Active health check failed
# /failed_eds_health  — EDS marked unhealthy
# /failed_outlier_check — Outlier detection ejected
# /active_hc_timeout — Health check timed out
# /pending_active_hc — Initial health check pending
# /pending_dynamic_removal — Endpoint being removed
# /excluded_via_immediate_hc_fail — Immediately failed
```

### /config_dump — Full Running Configuration

```bash
# Full config dump
curl -s localhost:9901/config_dump | python3 -m json.tool | head -100

# Filter by resource type
curl -s "localhost:9901/config_dump?resource=dynamic_listeners"
curl -s "localhost:9901/config_dump?resource=dynamic_route_configs"
curl -s "localhost:9901/config_dump?resource=dynamic_active_clusters"
curl -s "localhost:9901/config_dump?resource=static_clusters"

# Include EDS endpoints
curl -s "localhost:9901/config_dump?include_eds"

# Mask sensitive data (secrets)
curl -s "localhost:9901/config_dump?mask=true"

# Search for specific config
curl -s localhost:9901/config_dump | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
for config in cfg.get('configs', []):
    if 'dynamic_route_configs' in config:
        for rc in config['dynamic_route_configs']:
            print(json.dumps(rc, indent=2))
"
```

### /stats — Metrics and Counters

```bash
# All stats
curl -s localhost:9901/stats

# Filtered (supports regex)
curl -s "localhost:9901/stats?filter=upstream_rq"
curl -s "localhost:9901/stats?filter=cluster\.my_service\."

# Prometheus format
curl -s localhost:9901/stats/prometheus

# Stats with histogram quantiles
curl -s "localhost:9901/stats?filter=upstream_rq_time&format=json" | python3 -m json.tool

# Key stats to monitor:
# cluster.<name>.upstream_rq_total           — Total requests
# cluster.<name>.upstream_rq_2xx             — Successful requests
# cluster.<name>.upstream_rq_5xx             — Server errors
# cluster.<name>.upstream_rq_timeout         — Timed out requests
# cluster.<name>.upstream_rq_retry           — Retried requests
# cluster.<name>.upstream_rq_pending_overflow — Circuit breaker rejections
# cluster.<name>.upstream_cx_connect_fail    — Connection failures
# cluster.<name>.upstream_cx_active          — Active connections
# cluster.<name>.upstream_cx_overflow        — Conn pool overflow
# cluster.<name>.membership_healthy          — Healthy endpoints
# cluster.<name>.membership_total            — Total endpoints
# listener.<addr>.downstream_cx_total        — Total connections received
# listener.<addr>.downstream_cx_active       — Active connections
# http.<prefix>.downstream_rq_total          — Total HTTP requests
# http.<prefix>.downstream_rq_2xx            — 2xx responses
# http.<prefix>.downstream_rq_5xx            — 5xx responses

# Reset counters (useful for debugging)
curl -X POST localhost:9901/reset_counters
```

### /listeners — Active Listeners

```bash
# List all active listeners
curl -s localhost:9901/listeners

# With detail
curl -s "localhost:9901/listeners?format=json" | python3 -m json.tool

# Drain listeners (graceful shutdown)
curl -X POST localhost:9901/drain_listeners
# Only inbound
curl -X POST "localhost:9901/drain_listeners?inboundonly"
```

### /logging — Runtime Log Level

```bash
# View current levels
curl -s localhost:9901/logging

# Set global level
curl -X POST "localhost:9901/logging?level=debug"
curl -X POST "localhost:9901/logging?level=info"     # Reset

# Set per-component level
curl -X POST "localhost:9901/logging?connection=debug"
curl -X POST "localhost:9901/logging?upstream=debug"
curl -X POST "localhost:9901/logging?router=debug"
curl -X POST "localhost:9901/logging?http=debug"
curl -X POST "localhost:9901/logging?pool=debug"       # Connection pool
curl -X POST "localhost:9901/logging?filter=debug"      # Filter chain

# Useful components for debugging:
# connection — TCP connection events
# upstream   — Upstream cluster/endpoint selection
# router     — HTTP routing decisions
# http       — HTTP codec, header processing
# pool       — Connection pool management
# filter     — Filter chain processing
# config     — xDS config updates
# dns        — DNS resolution
```

### /runtime — Runtime Feature Flags

```bash
# View all runtime values
curl -s localhost:9901/runtime | python3 -m json.tool

# Modify runtime value
curl -X POST "localhost:9901/runtime_modify?key=value"

# Useful runtime overrides:
# Disable health checks temporarily:
curl -X POST "localhost:9901/runtime_modify?health_check.min_interval=86400000"
```

---

## Access Log Analysis

### Response Flags Reference

Full list of `%RESPONSE_FLAGS%` values and their meaning:

| Flag | Name | Description |
|------|------|-------------|
| `UH` | NoHealthyUpstream | No healthy upstream host in cluster |
| `UF` | UpstreamConnectionFailure | Upstream connection failure |
| `UO` | UpstreamOverflow | Circuit breaker limit exceeded |
| `NR` | NoRouteFound | No matching route |
| `URX` | UpstreamRetryLimitExceeded | All retries exhausted |
| `NC` | NoClusterFound | Cluster not found |
| `DT` | DownstreamRequestTimeout | Request timed out waiting for downstream |
| `DC` | DownstreamConnectionTermination | Client disconnected |
| `LH` | FailedLocalHealthCheck | Local origin health check failed |
| `UT` | UpstreamRequestTimeout | Upstream request timed out |
| `LR` | LocalReset | Envoy reset the connection |
| `RL` | RateLimited | Rate limit filter rejected |
| `UAEX` | UnauthorizedExternalService | ext_authz denied |
| `RLSE` | RateLimitServiceError | Rate limit service error |
| `IH` | InvalidEnvoyRequestHeaders | Invalid headers |
| `SI` | StreamIdleTimeout | Stream idle timeout triggered |
| `DPE` | DownstreamProtocolError | HTTP protocol error from client |
| `UPE` | UpstreamProtocolError | HTTP protocol error from upstream |
| `UMSDR` | UpstreamMaxStreamDurationReached | Max stream duration hit |
| `OM` | OverloadManagerTerminated | Overload manager killed request |

### Analyzing Latency Issues

Parse access logs for slow requests:

```bash
# JSON access logs — find requests > 1000ms
cat /var/log/envoy/access.log | python3 -c "
import json, sys
for line in sys.stdin:
    try:
        entry = json.loads(line)
        duration = int(entry.get('duration_ms', 0))
        if duration > 1000:
            print(f'{duration}ms {entry.get(\"method\")} {entry.get(\"path\")} -> {entry.get(\"upstream_host\")} flags={entry.get(\"response_flags\")}')
    except: pass
" | sort -rn | head -20

# Break down latency components:
# DURATION = REQUEST_DURATION + RESPONSE_DURATION + RESPONSE_TX_DURATION
# REQUEST_DURATION    — Time to receive full request from downstream
# RESPONSE_DURATION   — Time waiting for upstream response (includes upstream_service_time)
# RESPONSE_TX_DURATION — Time to send response to downstream
```

### Identifying Upstream Failures

```bash
# Count response flags
cat /var/log/envoy/access.log | python3 -c "
import json, sys
from collections import Counter
flags = Counter()
for line in sys.stdin:
    try:
        entry = json.loads(line)
        f = entry.get('response_flags', '-')
        if f and f != '-':
            flags[f] += 1
    except: pass
for flag, count in flags.most_common():
    print(f'{flag}: {count}')
"

# Filter for specific upstream cluster failures
grep '"upstream_cluster":"my_service"' /var/log/envoy/access.log | \
  grep -v '"response_code":200' | tail -20
```

---

## Reloadable Features

### envoy.reloadable_features Overview

Envoy uses reloadable features as runtime toggles for behavior changes, typically introduced to guard new behavior that might break existing setups. These can be toggled at runtime without a restart.

```bash
# List all reloadable features and their defaults
curl -s localhost:9901/runtime | python3 -c "
import json, sys
data = json.load(sys.stdin)
for key, val in sorted(data.get('entries', {}).items()):
    if 'reloadable' in key:
        print(f'{key}: {val}')
"
```

### Common Reloadable Feature Toggles

```yaml
# In bootstrap config or via runtime layer
layered_runtime:
  layers:
    - name: static_layer
      static_layer:
        envoy.reloadable_features.http_reject_path_with_fragment: true
        envoy.reloadable_features.no_extension_lookup_by_name: true
        envoy.reloadable_features.override_request_timeout_by_gateway_timeout: false
```

Or at runtime:
```bash
# Toggle a reloadable feature
curl -X POST "localhost:9901/runtime_modify?envoy.reloadable_features.enable_grpc_async_client_cache=false"
```

Notable reloadable features:
- `http_reject_path_with_fragment` — Reject URLs with `#` fragments.
- `no_extension_lookup_by_name` — Require typed_config for all extensions.
- `override_request_timeout_by_gateway_timeout` — Use `grpc-timeout` header.
- `allow_concurrency_for_alpn_pool` — HTTP/2 connection pooling behavior.

---

## Upstream Connection Pool Issues

### Connection Pool Exhaustion

**Symptom:** High latency or 503s with `UO` flag despite backends being healthy.

```bash
# Check connection pool stats
curl -s "localhost:9901/stats?filter=upstream_cx" | grep my_service
# cluster.my_service.upstream_cx_active: 100
# cluster.my_service.upstream_cx_total: 50000
# cluster.my_service.upstream_cx_overflow: 500  # Pool overflows!
# cluster.my_service.upstream_cx_connect_timeout: 10
# cluster.my_service.upstream_cx_max_requests: 0

# Check pending requests
curl -s "localhost:9901/stats?filter=upstream_rq" | grep my_service
# cluster.my_service.upstream_rq_active: 95
# cluster.my_service.upstream_rq_pending_active: 200  # Waiting for connections
# cluster.my_service.upstream_rq_pending_overflow: 50  # Rejected
```

**Fixes:**

1. **Raise circuit breaker limits:**
   ```yaml
   circuit_breakers:
     thresholds:
       - max_connections: 4096
         max_pending_requests: 4096
         max_requests: 4096
   ```

2. **Use HTTP/2 to upstream (multiplexing):**
   ```yaml
   clusters:
     - name: my_service
       typed_extension_protocol_options:
         envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
           "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
           explicit_http_config:
             http2_protocol_options:
               max_concurrent_streams: 100
   ```

3. **Tune connection pool per-endpoint:**
   ```yaml
   clusters:
     - name: my_service
       upstream_connection_options:
         tcp_keepalive:
           keepalive_probes: 3
           keepalive_time: 300
           keepalive_interval: 30
   ```

### HTTP/2 Connection Issues

**Symptom:** `GOAWAY` frames, stream resets, or `upstream_rq_rx_reset` increasing.

```bash
curl -s "localhost:9901/stats?filter=http2" | grep my_service
# cluster.my_service.http2.rx_reset: 100
# cluster.my_service.http2.tx_reset: 5
# cluster.my_service.http2.goaway_received: 10
# cluster.my_service.http2.streams_active: 50
# cluster.my_service.http2.pending_send_bytes: 0
```

**Common fixes:**

```yaml
# Tune HTTP/2 settings
http2_protocol_options:
  max_concurrent_streams: 100            # Default: 2147483647
  initial_stream_window_size: 1048576    # 1MB (default 256KB)
  initial_connection_window_size: 1048576 # 1MB
```

### TCP Connection Lifecycle

Key timeouts affecting connection pools:

```yaml
clusters:
  - name: my_service
    connect_timeout: 1s           # TCP connect timeout

    # Connection pool settings
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        common_http_protocol_options:
          idle_timeout: 300s           # Close idle connections after 5 min
          max_connection_duration: 0s  # No max lifetime (0 = disabled)
          max_requests_per_connection: 0  # No limit (0 = disabled)

    upstream_connection_options:
      tcp_keepalive:
        keepalive_probes: 3     # Probes before marking dead
        keepalive_time: 300     # Seconds before first probe
        keepalive_interval: 30  # Seconds between probes
```

---

## Memory and CPU Profiling

### Memory Analysis

```bash
# Check memory usage via admin
curl -s localhost:9901/memory | python3 -m json.tool
# {
#   "allocated": "52428800",     # Currently allocated (bytes)
#   "heap_size": "67108864",     # Total heap size
#   "pageheap_unmapped": "0",
#   "pageheap_free": "4194304",
#   "total_thread_cache": "2097152",
#   "total_physical_bytes": "67108864"
# }

# Monitor over time
watch -n 5 'curl -s localhost:9901/memory | python3 -c "
import json,sys
m=json.load(sys.stdin)
alloc=int(m[\"allocated\"])/1024/1024
heap=int(m[\"heap_size\"])/1024/1024
print(f\"Allocated: {alloc:.1f}MB  Heap: {heap:.1f}MB\")
"'

# Stats related to memory
curl -s "localhost:9901/stats?filter=buffer"
# http.ingress.downstream_flow_control_paused_reading_total
# http.ingress.downstream_flow_control_resumed_reading_total
```

### CPU Profiling

Envoy supports `gperftools` CPU profiling (if compiled with it):

```bash
# Enable CPU profiling (requires --enable-cpu-profiler flag at build)
curl -X POST "localhost:9901/cpuprofiler?enable=y"

# Let it run for some time under load...

# Disable and write profile
curl -X POST "localhost:9901/cpuprofiler?enable=n"

# Analyze with pprof
pprof --pdf /usr/local/bin/envoy /tmp/envoy.prof > profile.pdf

# Or use heap profiler
curl -X POST "localhost:9901/heapprofiler?enable=y"
# ...
curl -X POST "localhost:9901/heapprofiler?enable=n"
```

### Buffer Overflows and OOM

**Symptom:** Envoy OOM killed, or `overload_manager` triggering.

**Configure overload manager to prevent OOM:**

```yaml
overload_manager:
  refresh_interval: 0.25s
  resource_monitors:
    - name: envoy.resource_monitors.fixed_heap
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.resource_monitors.fixed_heap.v3.FixedHeapConfig
        max_heap_size_bytes: 1073741824  # 1GB — set to container memory limit * 0.95
  actions:
    - name: envoy.overload_actions.shrink_heap
      triggers:
        - name: envoy.resource_monitors.fixed_heap
          threshold:
            value: 0.90
    - name: envoy.overload_actions.stop_accepting_requests
      triggers:
        - name: envoy.resource_monitors.fixed_heap
          threshold:
            value: 0.95
    - name: envoy.overload_actions.disable_http_keepalive
      triggers:
        - name: envoy.resource_monitors.fixed_heap
          threshold:
            value: 0.92

# Per-connection buffer limit
listeners:
  - per_connection_buffer_limit_bytes: 1048576  # 1MB
```

**Large request/response bodies causing memory pressure:**
```yaml
# Limit request body buffering
route:
  cluster: my_service
  per_request_buffer_limit_bytes: 10485760  # 10MB max buffer per request

# For streaming (no buffering):
# Ensure no filters require body buffering (ext_proc BUFFERED mode, Lua body(), etc.)
```

---

## Debugging Recipes

### Full Request Tracing

Enable maximum verbosity for a single request:

```bash
# 1. Set debug logging
curl -X POST "localhost:9901/logging?level=debug"

# 2. Send request with trace headers
curl -v -H "x-request-id: debug-12345" http://localhost:8080/api/test

# 3. Search logs for the request ID
grep "debug-12345" /var/log/envoy/envoy.log

# 4. Reset logging
curl -X POST "localhost:9901/logging?level=info"
```

Alternatively, use the tap filter for non-intrusive capture:
```bash
curl -X POST localhost:9901/tap -d '{
  "config_id": "http_tap",
  "tap_config": {
    "match_config": {
      "http_request_headers_match": {
        "headers": [{"name": "x-request-id", "exact_match": "debug-12345"}]
      }
    },
    "output_config": {"streaming": true}
  }
}'
```

### xDS Debugging

```bash
# Check xDS connection status
curl -s "localhost:9901/stats?filter=control_plane"
# control_plane.connected_state: 1  (1 = connected)
# control_plane.pending_requests: 0

# Check xDS update stats
curl -s "localhost:9901/stats?filter=update"
# cluster_manager.cds.update_success: 10
# cluster_manager.cds.update_rejected: 0
# listener_manager.lds.update_success: 5
# listener_manager.lds.update_rejected: 1  # <- Check error
# listener_manager.lds.update_failure: 0

# Check last xDS version applied
curl -s localhost:9901/config_dump | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
for config in cfg.get('configs', []):
    for key in ['dynamic_listeners', 'dynamic_route_configs', 'dynamic_active_clusters']:
        if key in config:
            for item in config[key]:
                ver = item.get('version_info', 'N/A')
                name = 'unknown'
                if 'listener' in item:
                    name = item['listener'].get('name', 'unknown')
                elif 'route_config' in item:
                    name = item['route_config'].get('name', 'unknown')
                elif 'cluster' in item:
                    name = item['cluster'].get('name', 'unknown')
                print(f'{key}: {name} (version: {ver})')
"

# Enable xDS debug logging
curl -X POST "localhost:9901/logging?config=debug"
```

### WASM Filter Debugging

```bash
# Check WASM runtime stats
curl -s "localhost:9901/stats?filter=wasm"
# wasm.envoy_wasm_runtime_v8.active: 1
# wasm.envoy_wasm_runtime_v8.created: 1
# wasm.<filter_name>.remote_load_cache_entries: 0
# wasm.<filter_name>.remote_load_cache_negative_hits: 0
# wasm.<filter_name>.remote_load_fetch_failures: 0
# wasm.<filter_name>.remote_load_cache_misses: 0

# Enable WASM debug logging
curl -X POST "localhost:9901/logging?wasm=debug"

# WASM filters log via proxy_log_* host calls, visible in Envoy logs
# Look for: [wasm] ... or [source/extensions/common/wasm/...]

# Common WASM issues:
# 1. "Failed to load WASM module" — Check file path and permissions
# 2. "WASM missing malloc/free" — Rebuild with proper allocator exports
# 3. "proxy_on_configure returned false" — Config parsing failed in RootContext
```
