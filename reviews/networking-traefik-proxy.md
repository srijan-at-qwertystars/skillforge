# Review: traefik-proxy

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Deprecated `sslRedirect` in Traefik v3** — The skill targets Traefik v3 (`traefik:v3.2`) but uses `sslRedirect: true` in middleware headers configs throughout SKILL.md (lines 200, 269), dynamic-config.yaml (line 133), and all three scripts' generated output. In Traefik v3, `sslRedirect` is deprecated; HTTP→HTTPS should be handled via entryPoint-level redirections (which the skill *also* correctly shows in static config). The middleware usage will produce deprecation warnings. Recommend removing `sslRedirect` from middleware examples and adding a note that entryPoint redirection is the v3-preferred approach.

2. **Deprecated `browserXssFilter` in Traefik v3** — Used in SKILL.md (lines 207, 274), dynamic-config.yaml (line 139), and generate-middleware.sh output. This header option is deprecated in v3 as modern browsers ignore `X-XSS-Protection` in favor of CSP. The dynamic-config.yaml already includes `contentSecurityPolicy` which is the correct replacement — but the deprecation should be noted, and the main SKILL.md middleware reference should recommend CSP instead.

3. **Pinned image tag `traefik:v3.2` is outdated** — Current stable is v3.6.x. While pinning is good practice, the skill should either use a more recent tag or note that users should check for the latest v3.x release. Appears in SKILL.md, docker-compose.yaml, setup-traefik.sh, and Helm values.

## Detailed Review

### a. Structure Check — PASS

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name+description) | ✅ | Lines 1-11, both `name` and `description` present |
| Positive triggers | ✅ | 17 trigger phrases covering all major Traefik concepts |
| Negative triggers | ✅ | 8 exclusions: Nginx, HAProxy, Caddy, AWS ALB/ELB, Envoy, Apache, Istio, plain Ingress |
| Under 500 lines | ✅ | 479 lines (just under limit) |
| Imperative voice | ✅ | "Set static via", "Persist acme.json", "Use staging for testing", "Route dashboard to" |
| Examples | ✅ | Two worked examples (Docker Compose HTTPS setup, canary deployment) |
| Links to references/scripts | ✅ | Tables linking all 3 references, 3 scripts, 3 assets with descriptions |

### b. Content Check — PASS (with notes)

**Verified correct via web search:**
- Middleware names: `rateLimit`, `circuitBreaker`, `basicAuth`, `ipAllowList`, `headers`, `compress`, `stripPrefix`, `addPrefix`, `chain`, `redirectRegex` — all match official Traefik v3 docs
- IngressRoute CRD apiVersion `traefik.io/v1alpha1` — confirmed correct
- ACME configuration: `certificatesResolvers`, `httpChallenge`, `dnsChallenge`, `tlsChallenge` — syntax verified
- EntryPoint structure, provider config, static/dynamic separation — all accurate
- Router rule syntax: `Host()`, `PathPrefix()`, `HostSNI()` — correct
- Circuit breaker expressions: `ResponseCodeRatio()`, `NetworkErrorRatio()`, `LatencyAtQuantileMS()` — verified

**Supporting files quality:**
- `references/` (3 files, 3,354 lines total): Thorough deep-dives on advanced patterns, troubleshooting, and Kubernetes. Well-structured with TOCs.
- `scripts/` (3 files, 1,573 lines total): All use `set -euo pipefail`, have `--help`, color output, proper arg parsing. `setup-traefik.sh` handles both Docker and Helm. `test-config.sh` validates YAML, checks ACME permissions, queries API. `generate-middleware.sh` supports YAML/Docker-labels/K8s-CRD output formats.
- `assets/` (3 files, 693 lines total): Production-ready templates with inline comments explaining each option. docker-compose includes socket proxy option, health checks, multiple example services.

**Missing gotchas (minor):**
- No mention of `sslRedirect`/`browserXssFilter` deprecation status in v3 (see issues above)
- No mention of `core.defaultRuleSyntax` for v2→v3 migration compatibility
- Docker socket proxy is only shown as a comment; could emphasize security benefits more

### c. Trigger Check — PASS

**Would trigger for Traefik queries:** ✅ Yes — comprehensive coverage of all Traefik-specific terminology (proxy, router, middleware, IngressRoute, Docker labels, Let's Encrypt, entrypoints, load balancer, TLS, ACME, reverse proxy, service discovery, dashboard, rate limiting, circuit breaker, TCP/UDP, observability).

**False trigger for competing tools:** ✅ No — explicit negative triggers exclude Nginx, HAProxy, Caddy, AWS ALB/ELB, Envoy, Apache httpd, Istio (without Traefik), and plain Kubernetes Ingress (without Traefik CRDs). Edge case: a query about "reverse proxy" without mentioning Traefik would not trigger (correct behavior since the trigger phrases require "Traefik" prefix).

### d. Score Summary

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Accuracy | 4/5 | All config syntax verified correct; deducted for deprecated v2 options (`sslRedirect`, `browserXssFilter`) used without deprecation notes in a v3-targeted skill, and outdated image tag |
| Completeness | 5/5 | Covers all Traefik primitives, 3 providers (Docker/K8s/File), all ACME challenge types, full middleware catalog, TCP/UDP, observability stack, troubleshooting, with 9 supporting files totaling 5,620 lines |
| Actionability | 5/5 | Copy-paste templates, executable scripts with help text, multiple output format support, clear next-steps instructions |
| Trigger quality | 5/5 | 17 positive triggers, 8 negative triggers, no ambiguity, proper Traefik-scoped terminology |
| **Overall** | **4.8/5** | |

### e. GitHub Issues

No issues filed — overall score (4.8) ≥ 4.0 and no dimension ≤ 2.

### f. SKILL.md Annotation

Appended `<!-- tested: pass -->` to SKILL.md.
