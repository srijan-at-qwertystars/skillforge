# QA Review: networking/istio-service-mesh

**Reviewer:** Copilot CLI  
**Date:** 2025-07-16  
**Skill path:** `~/skillforge/networking/istio-service-mesh/`  
**SKILL.md lines:** 435 (under 500 ✅)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | Has `name`, `description`, `triggers` with positive/negative lists |
| Under 500 lines | ✅ Pass | 435 lines |
| Imperative voice | ✅ Pass | Uses imperative throughout ("Use", "Set", "Deploy", "Pin") |
| Examples | ✅ Pass | Rich YAML examples for all major CRDs and CLI commands |
| References linked | ✅ Pass | 3 reference docs (traffic, security, troubleshooting) — all exist |
| Scripts linked | ✅ Pass | 3 scripts (install, debug, canary) — all exist |
| Assets linked | ✅ Pass | 5 asset manifests — all exist |

**Linked file totals:** 3,503 lines across references, scripts, and assets.

---

## B. Content Check

### Verified Accurate ✅
- **API versions**: `networking.istio.io/v1` for VirtualService, DestinationRule, Gateway, ServiceEntry — correct (promoted to v1 in Istio 1.22, May 2024)
- **Security API versions**: `security.istio.io/v1` for PeerAuthentication, AuthorizationPolicy, RequestAuthentication — correct
- **WasmPlugin API**: `extensions.istio.io/v1alpha1` — correct (still alpha as of Istio 1.24)
- **Ambient mesh**: ztunnel description, `istio.io/dataplane-mode=ambient` label, waypoint proxy usage — all accurate
- **VirtualService YAML**: Header matching, weighted routing, subset references — correct structure
- **DestinationRule YAML**: Subsets, load balancer, outlier detection fields — correct
- **Gateway YAML**: TLS SIMPLE mode, credentialName — correct
- **Circuit breaking fields**: `consecutive5xxErrors`, `maxEjectionPercent` — correct
- **Fault injection**: delay/abort percentage syntax — correct
- **Helm install order**: base → istiod → gateway — correct
- **Sidecar injection**: label and annotation syntax correct
- **mTLS guidance**: PERMISSIVE → STRICT migration advice is sound

### Errors Found ❌

1. **Non-existent `production` profile** (lines 54, 72)  
   `istioctl install --set profile=production` will fail. There is no `production` profile in Istio. Available profiles: `default`, `demo`, `minimal`, `empty`, `remote`, `preview`, `external`, `openshift`, `ambient`. The `default` profile is the recommended production baseline. Line 72 also incorrectly describes `production` as a profile option.

2. **Deprecated `istioctl authn tls-check` command** (line 386)  
   This command was removed in Istio 1.7 (2020). Running it on any modern Istio returns `unknown command 'authn'`. Replace with `istioctl proxy-config` commands or `istioctl analyze` for mTLS debugging.

### Missing Content (Gotchas / Gaps)

3. **Kubernetes Gateway API (`gateway.networking.k8s.io`)** — The skill lists "Gateway API Istio" as a positive trigger but provides zero coverage of the Kubernetes Gateway API. As of 2024-2025, Istio officially supports and recommends the K8s Gateway API for new deployments. Missing: `HTTPRoute`, `GatewayClass`, `Gateway` (k8s), migration guidance from Istio Gateway.

4. **Telemetry CRD** — `telemetry.istio.io/v1` is not mentioned. This CRD controls metrics, access logging, and tracing configuration per-workload and is the modern replacement for MeshConfig-level telemetry settings.

5. **EnvoyFilter CRD** — Referenced only in passing ("Prefer WasmPlugin over EnvoyFilter") but not documented. Users still encounter EnvoyFilter in production and need guidance on when/how to use it.

6. **`istioctl install` deprecation trajectory** — IstioOperator-based installation via `istioctl install` is on a deprecation path in favor of Helm. Worth noting for teams planning long-term.

---

## C. Trigger Check

### False-Positive Risk Analysis

| Trigger | Specificity | Risk |
|---------|-------------|------|
| `Istio` | ✅ Unambiguous | None |
| `VirtualService` | ✅ Istio-specific | None |
| `DestinationRule` | ✅ Istio-specific | None |
| `PeerAuthentication` | ✅ Istio-specific | None |
| `AuthorizationPolicy` | ✅ Istio-specific | None |
| `istioctl` | ✅ Istio-specific | None |
| `ambient mesh` | ✅ Currently Istio-specific | None |
| `waypoint proxy` | ✅ Istio-specific | None |
| `Gateway API Istio` | ✅ Qualified | None |
| **`service mesh`** | ⚠️ Too broad | Would match Linkerd, Consul, generic mesh discussions |
| **`Envoy proxy`** | ⚠️ Broad | Would match standalone Envoy, Envoy Gateway |
| **`mTLS`** | ⚠️ Too broad | Mutual TLS is used in many non-Istio contexts |
| **`traffic management`** | ⚠️ Too broad | Matches any networking discussion |
| **`sidecar injection`** | ⚠️ Moderate | Could match other sidecar-based systems |

**Negative triggers** are well-crafted (Linkerd, Consul Connect, AWS App Mesh, Traefik mesh, plain Envoy). However, negatives may not fully mitigate the broad positive triggers depending on the matching system.

**Would it falsely trigger for Linkerd?** Depends on implementation. If a query says "service mesh" without mentioning Linkerd, this skill would trigger even when Linkerd is the actual context. "mTLS" and "traffic management" have the same problem.

**Recommendation:** Qualify broad triggers — `Istio service mesh`, `Istio mTLS`, `Istio traffic management`. Remove or qualify `Envoy proxy` → `Istio Envoy sidecar`.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3/5 | Two copy-paste-would-fail commands: non-existent `production` profile and removed `istioctl authn tls-check`. Both appear in prominent code blocks. Rest of YAML/CRDs is correct. |
| **Completeness** | 4/5 | Excellent coverage of core Istio CRDs, security, resilience, ambient, multi-cluster, Wasm. Missing Kubernetes Gateway API (significant given it's a listed trigger), Telemetry CRD, EnvoyFilter. |
| **Actionability** | 5/5 | Outstanding. Extensive YAML examples, 3 operational scripts, 5 asset manifests, 3 reference guides, troubleshooting commands, best practices list. |
| **Trigger quality** | 3/5 | Good Istio-specific terms but 4-5 overly broad terms (`service mesh`, `mTLS`, `traffic management`, `Envoy proxy`, `sidecar injection`) risk false positives for non-Istio queries. |
| **Overall** | **3.75/5** | |

---

## E. Verdict

**`needs-fix`** — Two factual errors in commands would break user workflows. Broad triggers risk false positives. Kubernetes Gateway API gap is notable given it's a listed trigger with zero coverage.

### Priority Fixes
1. Replace `production` profile with `default` (or document the actual profile list)
2. Replace `istioctl authn tls-check` with modern alternatives
3. Qualify broad triggers (`service mesh` → `Istio service mesh`, etc.)
4. Add Kubernetes Gateway API section (even a brief one with HTTPRoute example)
