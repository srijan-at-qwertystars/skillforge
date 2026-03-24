# QA Review: consul-service-discovery

**Skill Path:** `~/skillforge/devops/consul-service-discovery/SKILL.md`
**Reviewed:** 2025-07-17
**Line Count:** 394 / 500 max ✅

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with TRIGGERS and NOT-triggers present |
| Under 500 lines | ✅ Pass | 394 lines |
| Imperative voice | ✅ Pass | Consistent throughout |
| Examples | ✅ Pass | 4 examples with Input/Output pairs |
| References linked | ✅ Pass | 3 reference docs (advanced-patterns, troubleshooting, kubernetes-integration) |
| Scripts linked | ✅ Pass | 3 scripts (setup-consul-dev.sh, consul-backup.sh, service-register.sh) |
| Assets linked | ✅ Pass | 5 assets (Helm values, consul-template examples, docker-compose, ACL policies, service def) |

## B. Content Check

### Verified Correct ✅
- **Service registration** — Agent API (`/v1/agent/service/register`), Catalog API (`/v1/catalog/register`), HCL config file with `consul reload`. All JSON fields and endpoints verified against official docs.
- **Health checks** — HTTP, TCP, gRPC, Script, TTL table and examples are accurate. Exit codes (0=pass, 1=warn, 2=fail) correct.
- **DNS interface** — `<tag>.<service>.service[.<dc>].consul` format correct. Port 8600 correct.
- **KV store** — CRUD operations, CAS via `ModifyIndex`, `?recurse` and `?raw` flags all correct.
- **Connect/Service mesh** — Sidecar proxy HCL, `consul connect envoy -sidecar-for`, upstream `local_bind_port` pattern correct.
- **ACL system** — `consul acl bootstrap`, policy create with `-rules @-`, token create all correct. Uses modern `initial_management` (not deprecated `master`). ✅
- **Gossip & Raft** — `consul keygen`, `consul operator raft list-peers`, 3-or-5 server guidance correct.
- **Multi-DC federation** — `consul join -wan`, `?dc=` query param, mesh gateway config correct.
- **consul-template** — Template syntax with `range service`, `key` function correct.
- **K8s Helm** — Chart repo, `connectInject`, `manageSystemACLs`, pod annotations correct.
- **Watches** — `-type=service`, `-type=keyprefix`, HTTP handler config correct.
- **Prepared queries** — Failover with `NearestN`, DNS via `.query.consul` correct.
- **Sessions & locks** — Session create/acquire/release/renew API flow correct. `consul lock` CLI correct. Behaviors (`release`, `delete`) correct.

### Issues Found

1. **`consul intention create` deprecation not noted** (Medium)
   The skill presents `consul intention create -allow web api` as a primary method (§5 Intentions). As of Consul 1.9+, this CLI is deprecated in favor of `service-intentions` config entries via `consul config write`. The skill does show config entries for L7 intentions but doesn't flag the CLI as legacy.

2. **L7 intentions HCL syntax** (Minor)
   The inline format `{ Action = "allow", HTTP { PathPrefix = "/v2/", Methods = ["GET"] } }` mixes comma-separated attributes with a block-style `HTTP { }`. Proper HCL should use multi-line block format or `HTTP = { ... }` attribute syntax.

3. **Missing gotcha: `enable_script_checks` security risk** (Medium)
   Script health checks (§2) require `enable_script_checks = true` on the agent, which enables remote code execution via the API — a known CVE vector. The safer `enable_local_script_checks = true` alternative is not mentioned. This is a significant operational safety gap.

4. **Missing gotcha: `DeregisterCriticalServiceAfter`** (Low)
   Not mentioned anywhere. This field auto-deregisters services stuck in critical state, preventing stale entries — a common production need.

5. **Missing gotcha: Catalog API anti-entropy caveat** (Low)
   Services registered via the Catalog API (§1) are not managed by anti-entropy, meaning they won't be re-registered after agent restart. This distinction from Agent API registration is important but not called out.

## C. Trigger Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| Consul-specific triggers | ✅ Pass | 17 trigger phrases, all include "Consul" or "consul" |
| Negative triggers | ✅ Pass | Explicitly excludes etcd, ZooKeeper, Eureka, Istio, general DNS/LB |
| False trigger: etcd? | ✅ No | No keyword overlap |
| False trigger: ZooKeeper? | ✅ No | No keyword overlap |
| False trigger: Istio? | ✅ No | Explicitly excluded; "service mesh" requires Consul context |
| Specificity | ✅ Good | Triggers require Consul-specific terms, not generic service discovery |

Trigger quality is excellent — well-scoped with explicit negative boundaries.

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 / 5 | All CLI commands and API calls verified correct. Minor L7 HCL syntax issue; deprecated `consul intention create` not flagged. |
| **Completeness** | 4 / 5 | Outstanding breadth (13 sections + 3 references + 3 scripts + 5 assets). Missing security gotchas for script checks and catalog API anti-entropy caveat. |
| **Actionability** | 5 / 5 | Every section has copy-paste-ready examples. Scripts are operational. 4 end-to-end examples cover registration, mesh, locking, and K8s. |
| **Trigger Quality** | 5 / 5 | Specific, comprehensive, explicit negative triggers prevent false matches. |
| **Overall** | **4.5 / 5** | |

## E. Recommendations

1. Add deprecation note to `consul intention create` section, recommending config entries as the primary approach.
2. Add a "⚠️ Security" callout in the Script health check row noting `enable_local_script_checks` as the safe default.
3. Add a brief "Gotchas" section or inline notes covering: `DeregisterCriticalServiceAfter`, catalog API anti-entropy limitation, and DNS TTL defaults.
4. Fix L7 intentions HCL to use proper multi-line block syntax.

## F. Verdict

**PASS** — Overall 4.5/5, no dimension ≤ 2. No GitHub issue required.
