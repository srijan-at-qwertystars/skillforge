# QA Review: devops/service-mesh

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-18
**Skill path:** `~/skillforge/devops/service-mesh/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ Pass | `name: service-mesh` |
| YAML frontmatter has `description` | ✅ Pass | Multi-line description present |
| Positive triggers | ✅ Pass | Covers Istio, Envoy, Linkerd, mTLS, VirtualService, DestinationRule, Gateway, ambient mesh, multi-cluster, etc. |
| Negative triggers | ✅ Pass | Excludes monolithic apps, Docker Compose, <5 microservices, standalone API gateway, basic K8s networking, simple LB |
| Body under 500 lines | ✅ Pass | 497 lines (tight — 3 lines of margin) |
| Imperative voice | ✅ Pass | "Use when…" / "Do NOT use for…" pattern |
| Examples present | ✅ Pass | Extensive YAML/bash examples throughout |
| Resources linked from SKILL.md | ✅ Pass | References (2), scripts (2), assets (3) all linked in "Additional Resources" section |

**Files inventory:**
- `SKILL.md` — 497 lines, main skill document
- `references/advanced-patterns.md` — ~785 lines, 10 advanced topics (Wasm, multi-cluster, ext-authz, rate limiting, traffic mirroring, locality LB, Flagger, ambient deep dive, egress, Lua)
- `references/troubleshooting.md` — ~645 lines, 9 troubleshooting sections
- `scripts/install-istio.sh` — 173 lines, well-structured with arg parsing, validation, cleanup
- `scripts/mesh-debug.sh` — 264 lines, 10 commands with help text
- `assets/virtualservice.yaml` — 144 lines, traffic splitting + DestinationRule
- `assets/peer-auth.yaml` — 172 lines, PeerAuth + AuthorizationPolicy templates
- `assets/gateway.yaml` — 179 lines, TLS/mTLS/redirect + VirtualService bindings

---

## b. Content Check

### Claims Verified via Web Search

| Claim | Verdict | Detail |
|-------|---------|--------|
| "istiod: Single binary since Istio 1.5+" | ✅ Correct | Confirmed — istiod unified control plane introduced in Istio 1.5 (March 2020) |
| "Ambient mesh (GA in Istio 1.24, Nov 2024)" | ✅ Correct | Confirmed — GA announced November 7, 2024 with Istio 1.24 |
| "WasmPlugin — Advanced extensibility (Istio 1.12+)" | ✅ Correct | WasmPlugin CRD introduced in Istio 1.12, API version `extensions.istio.io/v1alpha1` |
| Linkerd "40-400% lower latency" | ⚠️ Partially | Sourced from Buoyant (Linkerd vendor). Direction is correct per independent benchmarks, but framing is vendor-biased. Better to cite independent studies. |
| "Typical sidecar overhead: 0.5-1ms p50 latency" | ❌ Understated | Independent benchmarks (Istio 1.24 perf tests, Azure AKS, academic studies) consistently report **2-4ms p50** per hop. The 0.5-1ms figure is optimistic and potentially misleading. |
| "Scrape from Envoy sidecars on port 15090" | ⚠️ Misleading | Port 15090 serves Envoy-only metrics. The default merged metrics endpoint (with `enablePrometheusMerge: true`) is port **15020**. Should clarify both ports. |

### Missing Gotchas / Topics

1. **Kubernetes Gateway API**: Istio increasingly supports the Kubernetes Gateway API (`gateway.networking.k8s.io`) as an alternative to its own `networking.istio.io` CRDs. This is the future direction and is not mentioned anywhere.
2. **gRPC-specific patterns**: No coverage of gRPC load balancing nuances with Envoy (HTTP/2 connection pooling, per-RPC LB).
3. **OpenTelemetry integration**: Modern observability trend; only legacy Jaeger/Zipkin B3 headers mentioned. Istio supports W3C Trace Context and OTel natively since 1.15+.
4. **Sidecar ordering / lifecycle**: `holdApplicationUntilProxyStarts` is mentioned but `EXIT_ON_ZERO_ACTIVE_CONNECTIONS` for graceful shutdown is missing.

### Example Correctness

- All YAML examples use correct API versions (`networking.istio.io/v1beta1`, `security.istio.io/v1`).
- Bash scripts have proper `set -euo pipefail`, arg parsing, and cleanup.
- Rust Wasm plugin scaffold is syntactically correct and uses current `proxy-wasm` SDK patterns.
- PromQL example is valid syntax.

---

## c. Trigger Check

| Aspect | Assessment |
|--------|-----------|
| **True positive coverage** | Excellent — covers Istio, Envoy, Linkerd, mTLS, VirtualService, DestinationRule, Gateway, PeerAuthentication, AuthorizationPolicy, ambient mesh, multi-cluster mesh, canary deployments, circuit breaking |
| **False positive risk** | Low — "sidecar proxy patterns" could theoretically match non-mesh contexts but is very unlikely given the surrounding trigger terms |
| **False negative risk** | Low-moderate — missing triggers for "Gateway API" (K8s native), "SPIFFE", "service identity", "zero-trust networking" which could be relevant |
| **Negative trigger quality** | Good — "<5 microservices" threshold is sensible. "Docker Compose networking" exclusion prevents misuse |

**Verdict:** Description triggers correctly for its intended scope. Minor false-negative risk for Kubernetes Gateway API users who might not mention "Istio" explicitly.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 / 5 | Mostly accurate. p50 latency claim (0.5-1ms) is understated vs benchmarks (2-4ms). Prometheus port 15090 should mention 15020 default. Linkerd comparison cites vendor numbers. |
| **Completeness** | 4 / 5 | Very comprehensive Istio coverage including ambient mesh, Wasm, multi-cluster, troubleshooting. Missing: Kubernetes Gateway API, gRPC LB, OpenTelemetry, graceful shutdown. |
| **Actionability** | 5 / 5 | Excellent. Production-ready YAML templates, well-documented scripts with `--help`, detailed troubleshooting flows, decision matrices (Lua vs Wasm, Istio vs Linkerd). |
| **Trigger quality** | 5 / 5 | Well-scoped positive and negative triggers. Appropriate exclusion criteria. Minimal false-positive/negative risk. |
| **Overall** | **4.5** | High-quality skill. Accuracy issues are minor and correctable. |

---

## e. Issues

No GitHub issues required (overall 4.5 ≥ 4.0, no dimension ≤ 2).

### Recommended Improvements (non-blocking)

1. **Fix p50 latency claim** (line 462 of SKILL.md): Change "0.5-1ms p50 latency" to "2-4ms p50 latency" per Istio 1.24 benchmarks and independent studies.
2. **Clarify Prometheus metrics ports**: Add that port 15020 is the default merged metrics endpoint; 15090 is Envoy-only.
3. **Add Kubernetes Gateway API section**: Brief section noting Istio's support for `gateway.networking.k8s.io` resources as the future-facing API.
4. **Add OpenTelemetry mention**: Note W3C Trace Context support alongside B3 headers.
5. **Cite independent benchmarks** for Linkerd comparison instead of vendor-sourced "40-400%" figure.

---

## f. Test Status

**Result: PASS**

Review path: `~/skillforge/reviews/devops-service-mesh.md`
