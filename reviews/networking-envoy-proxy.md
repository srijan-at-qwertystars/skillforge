# QA Review: networking/envoy-proxy

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17
**Skill path:** `~/skillforge/networking/envoy-proxy/`

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with `Use when` (+ triggers) and `NOT for` (− triggers) present |
| Under 500 lines | ✅ Pass | 496 lines (just under limit) |
| Imperative voice | ✅ Pass | Sections use direct instructional style |
| Examples | ✅ Pass | Two worked examples (route+circuit-breaker config, 503 debugging) |
| References linked | ✅ Pass | 3 reference docs (`advanced-patterns.md`, `troubleshooting.md`, `service-mesh-integration.md`) |
| Scripts linked | ✅ Pass | 3 scripts (`validate-envoy-config.sh`, `envoy-stats-parser.sh`, `generate-envoy-bootstrap.py`) |
| Assets linked | ✅ Pass | 5 assets including WASM template, docker-compose, bootstrap template |
| All files exist | ✅ Pass | All referenced files verified on disk |

## B. Content Check

### Verified Correct ✅
- **v3 API filter names & `@type` URLs**: All verified against Envoy 1.38 docs — `http_connection_manager`, `router`, `local_ratelimit`, `ext_authz`, `ratelimit`, `wasm`, `StdoutAccessLog` type URLs are correct.
- **xDS table**: LDS, RDS, CDS, EDS, SDS, ADS type URLs all accurate.
- **Static config structure**: Listener → filter_chain → HCM → routes → clusters pattern is correct.
- **Dynamic config bootstrap**: xDS bootstrap with `api_type: GRPC`, `transport_api_version: V3`, and HTTP/2 upstream config is correct.
- **Circuit breaker fields**: `max_connections`, `max_pending_requests`, `max_requests`, `max_retries` match v3 proto.
- **Rate limiting**: Both local (token bucket) and global (external gRPC service) configs are correct.
- **TLS/mTLS**: Downstream and upstream TLS contexts use correct type URLs and field names.
- **Health checks**: `expected_statuses` with `start`/`end` range is correct v3 syntax.
- **OpenTelemetry tracing**: `@type` URL `envoy.config.trace.v3.OpenTelemetryConfig` confirmed correct.
- **Admin endpoints table**: Accurate and useful.
- **503 debugging flow**: Response flags (`UH`, `UF`, `UO`) and stat names are correct.

### Issues Found 🔴

#### 1. WASM build target is WRONG (Accuracy bug)
**Line 496** and `assets/wasm-filter-template/README.md` specify:
```
cargo build --target wasm32-wasip1 --release
```
The correct target for Envoy proxy-wasm filters is **`wasm32-unknown-unknown`**. The `wasm32-wasip1` target produces WASI modules that Envoy's proxy-wasm runtime **cannot load**. Envoy does not provide WASI imports. This will cause runtime failures.

**Fix:** Change to `wasm32-unknown-unknown` in SKILL.md line 496 and `assets/wasm-filter-template/README.md`.

#### 2. `exact_match` is deprecated (Accuracy warning)
**Line 147** uses deprecated header matching syntax:
```yaml
headers:
  - name: x-version
    exact_match: "beta"
```
Should use the current `string_match` syntax:
```yaml
headers:
  - name: x-version
    string_match:
      exact: "beta"
```
`exact_match` still works but is deprecated and will be removed. A skill doc should teach current best practice.

### Missing Gotchas ⚠️

#### 3. Outlier detection absent from main doc
Outlier detection (passive health checking based on real traffic — `consecutive_5xx`, `base_ejection_time`, `max_ejection_percent`) is a critical production pattern. It's mentioned in the bootstrap-template asset but has no section in SKILL.md. Should be added alongside Health Checking or Circuit Breaking.

#### 4. Tracing config context ambiguous
Lines 330-338 show tracing with `tracing.http:` (bootstrap-level syntax) but don't clarify this vs HCM-level `tracing.provider:`. Could confuse users placing config in the wrong location.

## C. Trigger Check

### Positive triggers (should fire) ✅
The description covers: `envoy.yaml`, xDS, filter chains, listeners/clusters/routes, rate limiting, WASM filters, ext_authz, circuit breaking, health checks, TLS/mTLS, load balancing, Istio sidecar, admin interface, access logs, stats/tracing. **Comprehensive and specific to Envoy.**

### Negative triggers (should NOT fire) ✅
Explicitly excludes: Nginx, HAProxy, Traefik, Caddy, Apache HTTPD, "general reverse proxy questions without Envoy context", and Envoy Gateway CRDs. **Well-scoped exclusions.**

### False-trigger risk: **LOW**
- Every positive trigger includes "Envoy" by name — no generic proxy terms that would match Nginx/HAProxy/Traefik.
- The `NOT for` section is specific and covers the major alternatives.
- Minor gap: does not exclude Linkerd or Cilium Envoy configs, but these are edge cases.

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 / 5 | WASM build target is factually wrong and will cause failures. `exact_match` deprecated. |
| **Completeness** | 4 / 5 | Missing outlier detection section. Tracing context ambiguous. Otherwise very thorough. |
| **Actionability** | 5 / 5 | Excellent worked examples, debugging flow, full YAML configs, scripts, docker-compose. |
| **Trigger Quality** | 5 / 5 | Highly specific to Envoy with clear exclusions. Low false-trigger risk. |
| **Overall** | **4.25 / 5** | Strong skill with two accuracy issues that need fixing. |

## E. Verdict

**`needs-fix`** — The WASM build target error (wrong architecture = broken filters) is a significant accuracy issue that must be fixed before this skill is reliable. The deprecated `exact_match` syntax should also be updated.

### Required Fixes
1. Change `wasm32-wasip1` → `wasm32-unknown-unknown` in SKILL.md and `assets/wasm-filter-template/README.md`
2. Update header matching example from `exact_match` → `string_match.exact`

### Recommended Improvements
3. Add outlier detection section (3-5 lines of config + explanation)
4. Clarify tracing config is bootstrap-level, mention HCM-level `provider:` alternative
