# QA Review: networking/load-balancing

**Reviewed:** $(date -u +%Y-%m-%d)
**Skill path:** `~/skillforge/networking/load-balancing/`
**Reviewer:** Copilot CLI (automated QA)

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `load-balancing` |
| YAML frontmatter `description` | ✅ Pass | Comprehensive, multi-line |
| Positive triggers | ✅ Pass | 20+ trigger phrases covering Nginx, HAProxy, AWS ALB/NLB/CLB, GCP, Azure, algorithms, health checks, SSL, WebSocket, gRPC, GSLB, auto-scaling |
| Negative triggers | ✅ Pass | 6 exclusions: single-server, CDN, API gateway (non-LB), DNS-only failover, service mesh, firewall/WAF |
| Body under 500 lines | ✅ Pass | 429 lines (SKILL.md) |
| Imperative voice | ✅ Pass | Consistently uses "Use", "Set", "Configure", "Route", "Combine" |
| Code examples | ✅ Pass | Nginx (5 blocks), HAProxy (5 blocks), Nginx SSL, AWS ASG pattern |
| Resources linked from SKILL.md | ✅ Pass | All 7 linked resources exist and are reachable: `references/advanced-patterns.md`, `references/troubleshooting.md`, `scripts/lb-health-check.sh`, `scripts/setup-haproxy.sh`, `assets/nginx-lb.conf`, `assets/haproxy.cfg`, `assets/docker-compose.yml` |

**Structure verdict:** All checks pass.

---

## b. Content Check

### Claims Verified via Web Search

| Claim | Verified | Source |
|-------|----------|--------|
| Round robin is stateless, sequential; least_conn routes to fewest active connections | ✅ Correct | nginx.org official docs |
| Nginx `slow_start` available in open source (since 1.11.5) | ✅ Correct | nginx.org upstream module docs |
| AWS ALB is L7 with native gRPC/WebSocket support | ✅ Correct | AWS docs, multiple 2024 comparisons |
| AWS NLB is L4 with static IPs, preserves source IP | ✅ Correct | AWS docs, DZone, Cloudviz |
| HAProxy stick-table rate limiting with `track-sc0` | ✅ Correct | HAProxy official tutorials, community guides |
| Power of two choices: max load drops from O(log n / log log n) to O(log log n) | ✅ Correct | Well-established CS result (Mitzenmacher/Richa) |
| `random two least_conn` in Nginx 1.15.1+ | ✅ Correct | nginx.org upstream module docs |

### Missing Gotchas / Issues Found

1. **Nginx `slow_start` limitation not documented (Minor):** The skill mentions `slow_start=30s` in the auto-scaling section (line 328) but does not note that `slow_start` is incompatible with `hash`, `ip_hash`, and `random` load balancing methods — it only works with `round_robin` and `least_conn`. This could lead users to combine it with unsupported algorithms.

2. **HAProxy rate-limiting example uses `tcp-request` in HTTP context (Nit):** Line 168 of SKILL.md uses `tcp-request connection track-sc0 src` inside an HTTP-mode frontend. While this technically works (tracking starts at connection level, HTTP counters still increment), the more canonical pattern for HTTP rate limiting is `http-request track-sc0 src`. The production `haproxy.cfg` asset correctly uses `http-request track-sc0 src`. Inconsistency between SKILL.md example and the asset config could confuse users.

3. **Docker Compose references missing demo files (Minor):** `docker-compose.yml` depends on `./demo/backend.conf`, `./demo/nginx-lb.conf`, and `./demo/haproxy-demo.cfg` which are not included in the `assets/` or `demo/` directory. Setup instructions are in comments within the compose file, but users must manually create these files before `docker compose up` will work.

4. **No mention of PROXY protocol for L4 source IP preservation (Minor):** The pitfalls section mentions `X-Forwarded-For` for L7 and "proxy protocol" for L4 in passing (line 368), but there's no dedicated section or example showing PROXY protocol configuration in Nginx or HAProxy. This is a common production need for L4 load balancing.

### Example Correctness

All Nginx and HAProxy code examples are syntactically correct and follow current best practices:
- Nginx upstream blocks, proxy headers, WebSocket upgrade, gRPC pass — all correct
- HAProxy frontend/backend, ACL routing, cookie persistence, stick tables — all correct
- Production config assets (`nginx-lb.conf`, `haproxy.cfg`) are comprehensive and well-structured
- Shell scripts (`lb-health-check.sh`, `setup-haproxy.sh`) use `set -euo pipefail`, proper argument parsing, and clean output

---

## c. Trigger Check

### Would the description trigger correctly?

**Yes.** The description covers the major trigger surface well:
- Technology-specific: Nginx upstream, HAProxy frontend/backend, AWS ALB/NLB/CLB, GCP, Azure
- Concept-specific: round robin, weighted round robin, least connections, IP hash, consistent hashing
- Feature-specific: health checks, session affinity, sticky sessions, SSL termination, connection draining, rate limiting, WebSocket/gRPC balancing, GSLB, auto-scaling

### False trigger risks

| Potential false trigger | Risk | Mitigation |
|------------------------|------|------------|
| "reverse proxy setup" without load balancing | Low | Negative trigger "single-server deployments without distribution needs" covers this |
| "rate limiting" queries about application-level rate limiting | Low | Description specifies "rate limiting at LB layer" |
| Service mesh traffic management | None | Explicitly excluded: "service mesh sidecar traffic management (Istio/Linkerd)" |
| CDN configuration | None | Explicitly excluded |

### False negative risks

| Scenario | Risk | Notes |
|----------|------|-------|
| "Envoy load balancing" queries | Medium | Envoy is not mentioned in positive triggers; only appears in advanced-patterns.md reference |
| "Traefik load balancing" queries | Medium | Not mentioned at all in the skill |
| "Kubernetes ingress load balancing" | Medium | K8s ingress controllers are not explicitly triggered |

**Trigger verdict:** Good coverage with well-defined boundaries. Could improve by adding Envoy/Traefik/K8s ingress to positive triggers.

---

## d. Scores

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 4/5 | All major claims verified correct. Minor: `slow_start` limitation undocumented; HAProxy rate-limit example uses non-canonical `tcp-request` in HTTP mode. |
| **Completeness** | 5/5 | Exceptionally comprehensive. Covers L4/L7, 6 algorithms, Nginx + HAProxy + 3 cloud providers, health checks, session persistence, SSL/TLS, connection draining, rate limiting, WebSocket/gRPC, GSLB, auto-scaling, monitoring metrics, debugging checklists. Plus 2 reference docs (705 + 865 lines), 2 scripts, 3 config assets. |
| **Actionability** | 5/5 | Production-ready configs, working shell scripts with proper arg parsing, docker compose for local testing, concrete thresholds and tuning values, debugging checklists with exact commands. |
| **Trigger quality** | 4/5 | Strong positive/negative trigger coverage. Minor gap: Envoy, Traefik, and K8s ingress not in triggers. |

### **Overall: 4.5 / 5.0**

---

## e. Issue Filing

**No GitHub issues required.** Overall score (4.5) ≥ 4.0 and no individual dimension ≤ 2.

---

## f. Test Status

**Result: PASS** ✅

### Recommended Improvements (non-blocking)

1. Add a note that Nginx `slow_start` only works with `round_robin` and `least_conn` algorithms
2. Update the HAProxy rate-limiting example in SKILL.md to use `http-request track-sc0 src` for consistency with the production asset config
3. Include the `./demo/` support files alongside `docker-compose.yml` or provide a setup script
4. Add Envoy and Traefik to positive triggers in the description
5. Add a PROXY protocol configuration example for L4 source IP preservation
