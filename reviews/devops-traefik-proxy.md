# QA Review: devops/traefik-proxy

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17
**Skill path:** `~/skillforge/devops/traefik-proxy/`

---

## (a) Structure

| Check | Status | Notes |
|---|---|---|
| Frontmatter `name` | ✅ Pass | `traefik-proxy` |
| Frontmatter `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers | ✅ Pass | "Use when: configuring Traefik, reverse proxy setup, edge router, service discovery, Docker labels routing, Let's Encrypt certificates, middleware chains, IngressRoute" |
| Negative triggers | ✅ Pass | "Do NOT use for: Nginx configuration, Caddy server setup, HAProxy configuration, or general load balancing theory without a Traefik context" |
| Body ≤ 500 lines | ✅ Pass | 497 lines |
| Imperative voice | ✅ Pass | Consistent imperative ("Enable", "Configure", "Define", "Set", "Use", etc.) |
| Resources linked | ✅ Pass | 3 references, 3 scripts, 4 assets — all linked in tables at bottom of SKILL.md |

**Files reviewed:**

- `SKILL.md` (497 lines)
- `references/advanced-patterns.md` (764 lines) — plugins, canary, gRPC, WebSocket, rate limiting, IP filtering, content routing, Consul/etcd, multi-region
- `references/troubleshooting.md` (737 lines) — certs, socket security, labels, middleware ordering, 502/504, dashboard, hot reload, memory, logs, K8s CRDs
- `references/kubernetes-guide.md` (853 lines) — Helm, IngressRoute, Middleware CRDs, TLSOption, cross-namespace, Ingress vs IngressRoute vs Gateway API, cert-manager
- `scripts/traefik-validate.sh` (269 lines) — static/dynamic/Compose validation
- `scripts/traefik-docker-setup.sh` (270 lines) — bootstraps Traefik + Docker
- `scripts/traefik-cert-check.sh` (268 lines) — acme.json, API, live TLS cert checks
- `assets/docker-compose.yml` (101 lines) — production Compose
- `assets/traefik.yml` (145 lines) — production static config
- `assets/dynamic-config.yml` (178 lines) — middleware chains, TLS options
- `assets/kubernetes-values.yml` (255 lines) — Helm values for HA Traefik

---

## (b) Content — Traefik v3 Claim Verification

All major claims were web-searched against official Traefik v3 documentation and migration guides.

| Claim | Verdict | Source |
|---|---|---|
| `ipAllowList` replaces deprecated `ipWhiteList` | ✅ Correct | Traefik v2→v3 migration guide |
| `swarmMode` removed; separate `swarm` provider in v3 | ✅ Correct | Traefik v2→v3 migration details |
| HTTP/3 (QUIC) stable in v3, no longer experimental | ✅ Correct | Traefik v3 release notes |
| WASM plugin support added in v3 | ✅ Correct | Traefik v3 plugin docs |
| OpenTelemetry is primary tracing; Jaeger/Zipkin direct integrations removed | ✅ Correct | Traefik v3 observability docs |
| Gateway API production-ready alternative to IngressRoute | ✅ Correct | Traefik v3 Kubernetes docs |
| CRD API group `traefik.io/v1alpha1` (not `traefik.containo.us`) | ✅ Correct | v3 CRD migration guide |
| Docker label syntax (`traefik.http.routers.<name>.tls.certresolver`) | ✅ Correct | Traefik Docker provider docs |
| Middleware names: `rateLimit`, `circuitBreaker`, `stripPrefix`, `forwardAuth`, `basicAuth`, `compress` | ✅ Correct | Traefik v3 middleware reference |
| `tls.caOptional` removed in v3 | ✅ Correct | Mentioned in anti-pattern #12 |

### Inaccuracies Found

1. **InfluxDB2 metrics shown as available (line 392).** InfluxDB and InfluxDB2 direct metrics exporters were **removed** in Traefik v3 in favor of OTLP. The commented-out example could mislead users into thinking it's still supported. Similarly, StatsD was removed.
   - **Severity:** Low (commented out, but misleading)
   - **Fix:** Remove the InfluxDB2 comment or add a note that it was removed in v3; recommend OTLP → InfluxDB via OpenTelemetry Collector.

2. **`advanced-patterns.md` section heading uses "IP Whitelisting Strategies"** (line 9/459). While the code correctly uses `ipAllowList`, the heading uses deprecated terminology.
   - **Severity:** Low (cosmetic, terminology inconsistency)
   - **Fix:** Rename to "IP Allow List Strategies" or "IP Filtering Strategies".

### Missing Gotchas

1. **`core.defaultRuleSyntax: v2`** — Not mentioned. This setting allows gradual v2→v3 migration of Docker label rule syntax. Useful for teams migrating large deployments.
2. **OTLP metrics export** — The skill only shows OTLP under tracing. The native `metrics.otlp` exporter (new in v3) for pushing metrics via OTLP is not documented.
3. **`ServersTransportTCP`** — v3 introduced a separate `ServersTransportTCP` CRD/config for TCP services, distinct from the HTTP `ServersTransport`. Not mentioned.
4. **Graceful shutdown / lifecycle hooks** — No mention of `lifecycle.requestAcceptGraceTimeout` or the `respondingTimeouts.gracePeriod` configuration for zero-downtime deployments.
5. **Traefik v3 minimum Go version / binary compatibility** — Minor, but could help deployment planning.

---

## (c) Trigger Quality

**Strengths:**
- Clear positive triggers covering the primary use cases (Traefik config, Docker labels, Let's Encrypt, middleware, IngressRoute)
- Well-scoped negative triggers excluding Nginx, Caddy, HAProxy, and generic LB theory

**Weaknesses:**
- Missing trigger keywords: "Traefik dashboard", "Traefik metrics", "Traefik tracing", "TCP/UDP routing with Traefik", "Traefik plugins", "Traefik health checks"
- Could benefit from trigger phrases for troubleshooting scenarios: "Traefik 502", "Traefik certificate not working", "Traefik labels not working"
- No negative trigger for "API gateway" (which could confuse with Traefik Hub vs general API gateway tools like Kong)

**Overall:** Triggers are functional and will match the most common user intents. Edge cases around observability and troubleshooting may not trigger reliably.

---

## (d) Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | All v3 config syntax, middleware names, Docker labels, and K8s CRDs verified correct. One minor inaccuracy (InfluxDB2 shown as available). No factual errors in core content. |
| **Completeness** | 5 | Exceptionally comprehensive. Covers all providers (Docker, K8s, file, Consul, etcd), all major middleware, TLS/ACME, TCP/UDP, metrics, tracing, plugins, anti-patterns. Three reference docs, three utility scripts, four asset templates. Hard to find a major Traefik v3 topic not covered. |
| **Actionability** | 5 | Every section includes copy-paste-ready config snippets. Production Compose template, Helm values, and dynamic config templates are directly usable. Scripts have proper error handling, `--help`, and color-coded output. Anti-patterns section gives concrete fixes. |
| **Trigger Quality** | 4 | Good positive/negative triggers covering primary use cases. Missing some edge-case keywords (dashboard, metrics, troubleshooting). Could add a few more negative triggers. |
| **Overall** | **4.5** | Weighted average of all dimensions. |

---

## Verdict

**Status: PASS** ✅

Overall score 4.5 ≥ 4.0 and no dimension ≤ 2. No GitHub issues required.

### Recommendations (non-blocking)

1. Remove or annotate the InfluxDB2 metrics comment to avoid confusion — it was removed in v3.
2. Rename "IP Whitelisting Strategies" heading in `advanced-patterns.md` to use inclusive terminology.
3. Add `metrics.otlp` documentation as a v3-native metrics export option.
4. Expand trigger keywords to include dashboard, metrics, tracing, and troubleshooting terms.
5. Consider adding a brief section on graceful shutdown and `ServersTransportTCP` for TCP use cases.
