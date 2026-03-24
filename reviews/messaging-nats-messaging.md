# QA Review: nats-messaging

**Skill path:** `~/skillforge/messaging/nats-messaging/`
**Reviewer:** automated-qa
**Date:** 2025-07-17
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name + description) | ✅ | `name: nats-messaging`, multi-line `description` present |
| Positive triggers | ✅ | NATS messaging, JetStream, pub/sub, nats-server, cluster, KV store, object store, nats CLI, Go/Python/Node.js/Rust |
| Negative triggers | ✅ | Explicit: RabbitMQ, Kafka, Redis pub/sub, AWS SQS/SNS, gRPC streaming |
| Under 500 lines | ✅ | Exactly 500 lines (at the limit) |
| Imperative voice | ✅ | Consistent: "Use when…", "Never use wildcards in…", "Always drain…", "Always call drain()" |
| Code examples | ✅ | Go, Python, TypeScript, Bash — with input/output annotations |
| Links to references/scripts | ✅ | Tables at bottom link to all 5 reference docs, 4 scripts, 5 assets |

**Structural issues:**

1. **Duplicate files not referenced in SKILL.md.** The `scripts/` directory contains 6 files but SKILL.md only references 4. Unreferenced duplicates:
   - `scripts/nats-health-check.sh` (overlaps with `health-check.sh` — different implementation using nats CLI vs HTTP API)
   - `scripts/setup-nats-cluster.sh` (overlaps with `setup-cluster.sh` — hardcoded 3-node vs configurable N-node)

   Similarly, `assets/` has 7 files but SKILL.md references 5. Unreferenced:
   - `assets/docker-compose.yml` (full observability stack with Surveyor + Prometheus + Grafana; different from `docker-compose.yaml` which is a plain cluster)
   - `assets/k8s-nats-helm-values.yaml` (alternative Helm values using newer chart schema with `container:` block)

   **Recommendation:** Either remove duplicates or reference all files in SKILL.md with distinct descriptions.

---

## B. Content Check

### Technical Accuracy (verified via web search against official NATS docs)

| Topic | Accuracy | Notes |
|-------|----------|-------|
| Subject wildcards (`*`, `>`) | ✅ Correct | Matches official docs exactly |
| Core pub/sub, request/reply, queue groups | ✅ Correct | API usage matches `nats.go` and `nats-py` |
| JetStream stream config fields | ✅ Correct | Retention policies, storage types, replicas, discard, dedup window all accurate |
| JetStream consumer types (push/pull, durable/ephemeral) | ✅ Correct | Config options and behavior descriptions match docs |
| KV store and Object Store API | ✅ Correct | `CreateKeyValue`, `Put`, `Get`, `Update`, `Delete`, `WatchAll` all valid |
| Cluster config (HCL format) | ✅ Correct | `server_name`, `cluster { name, listen, routes }` syntax verified |
| Super-cluster gateways | ✅ Correct | `gateway { name, listen, gateways }` format matches docs |
| Leaf nodes | ✅ Correct | Hub/leaf config syntax verified |
| Auth: NKey, JWT, Accounts | ✅ Correct | nsc commands, resolver types, permissions syntax all verified |
| Monitoring endpoints table | ✅ Correct | All 9 endpoints (`/varz`, `/connz`, `/routez`, `/subsz`, `/jsz`, `/healthz`, `/gatewayz`, `/leafz`, `/accountz`) verified |
| nats CLI commands | ✅ Correct | `nats stream add`, `nats consumer add`, `nats bench`, `nats kv`, `nats object` flags verified |
| Client library packages | ✅ Correct | `nats.go`, `nats-py`, `nats` (npm), `async-nats` (cargo) all current |

### Issues Found

1. **Legacy JetStream API used throughout (moderate).** All Go code examples use the legacy `nats.JetStreamContext` API (`nc.JetStream()`, `js.AddStream()`, `js.PullSubscribe()`, `js.Subscribe()`). The modern `github.com/nats-io/nats.go/jetstream` package (stable since ~2023) uses `jetstream.New(nc)`, `js.CreateStream(ctx, ...)`, and `consumer.Consume()`/`consumer.Fetch()`/`consumer.Messages()`. The legacy API still works and compiles, but new projects should prefer the modern package. **No reference files mention this migration path.**

2. **Go client example `RequestWithContext` bug (minor).** In `assets/go-client-example.go:460`:
   ```go
   reply, err := nc.RequestWithContext(ctx, "service.echo", []byte("hello from Go"), 5*time.Second)
   ```
   `RequestWithContext` takes `(ctx, subject, data)` — 3 args, not 4. The `5*time.Second` timeout is invalid here (timeout is derived from the context). This would fail to compile. Should be either `nc.Request(subject, data, 5*time.Second)` or `nc.RequestWithContext(ctx, subject, data)` with a context deadline.

### Missing Gotchas

| Gotcha | Impact | Recommendation |
|--------|--------|----------------|
| Modern `jetstream` package vs legacy API | High — new users may adopt deprecated patterns | Add a note in SKILL.md's JetStream section: "The Go examples use the legacy `nats.JetStreamContext` API. For new projects, prefer `github.com/nats-io/nats.go/jetstream`." |
| `max_payload` default is 1MB, not 8MB | Medium — production configs in assets set 8MB which is fine, but SKILL.md doesn't mention the default | Consider noting the 1MB default alongside the anti-pattern about huge messages |
| JetStream `max_mem` / `max_file` = 0 means no limit | Low — could surprise operators | Mention in operations guide |
| `nats-server --signal reload` as alternative to `kill -HUP` | Low — convenience | Optional |

### Reference Documents Quality

| File | Lines | Quality |
|------|-------|---------|
| `references/advanced-patterns.md` | ~700 | ✅ Excellent — mirrors, sources, dedup, flow control, DLQ, windowed aggregation |
| `references/jetstream-patterns.md` | ~420 | ✅ Excellent — deep stream/consumer config, exactly-once, flow control, subject transforms |
| `references/operations-guide.md` | ~700 | ✅ Excellent — sizing, TLS, backup/restore, rolling upgrades, Prometheus/Grafana |
| `references/security-guide.md` | ~450 | ✅ Excellent — TLS, NKeys, JWT, accounts, cert rotation, resolver config, checklist |
| `references/troubleshooting.md` | ~630 | ✅ Excellent — slow consumers, message loss, storage, split-brain, consumer stall, error table |

### Scripts Quality

| Script | Lines | Quality | Notes |
|--------|-------|---------|-------|
| `scripts/setup-cluster.sh` | 340 | ✅ Good | Docker + bare-metal, configurable N nodes, health check, colored output |
| `scripts/health-check.sh` | 345 | ✅ Good | HTTP API + nats CLI fallback, JSON output, exit codes |
| `scripts/stream-manager.sh` | ~550 | ✅ Good | Full CRUD for streams/consumers, backup/restore |
| `scripts/benchmark-nats.sh` | 257 | ✅ Good | Core pub/sub, req/reply, JetStream publish/consume, auto-cleanup |

### Assets Quality

| Asset | Quality | Notes |
|-------|---------|-------|
| `assets/nats-server.conf` | ✅ Excellent | Production template with TLS, NKey auth, cluster, gateway, leaf, WebSocket, MQTT, lame duck |
| `assets/docker-compose.yaml` | ✅ Excellent | 3-node cluster, resource limits, YAML anchors, exporter + nats-box profiles |
| `assets/kubernetes-helm-values.yaml` | ✅ Good | JetStream, clustering, TLS, PDB, topology spread, exporter sidecar |
| `assets/go-client-example.go` | ⚠️ Good | Comprehensive but has `RequestWithContext` bug (line 460) and uses legacy API |
| `assets/python-client-example.py` | ✅ Excellent | Type hints, dataclass config, structured logging, signal handling |

---

## C. Trigger Check

### Positive Triggers (should activate)

| Query | Would trigger? | Notes |
|-------|---------------|-------|
| "How do I set up NATS JetStream?" | ✅ Yes | "NATS JetStream" in description |
| "Configure NATS cluster" | ✅ Yes | "NATS cluster setup" in description |
| "NATS pub/sub example in Go" | ✅ Yes | "NATS pub/sub" + "Go" in description |
| "nats-server configuration" | ✅ Yes | "nats-server configuration" in description |
| "NATS key-value store" | ✅ Yes | "NATS key-value store" in description |
| "How to use nats CLI" | ✅ Yes | "nats CLI tool" in description |
| "NATS authentication with NKeys" | ✅ Yes | Covered by "authentication" in description |
| "NATS object store for large files" | ✅ Yes | "NATS object store" in description |

### Negative Triggers (should NOT activate)

| Query | Would trigger? | Notes |
|-------|---------------|-------|
| "How to set up RabbitMQ cluster?" | ✅ No | Explicit exclusion in description |
| "Kafka consumer group configuration" | ✅ No | Explicit exclusion |
| "Redis pub/sub vs Redis Streams" | ✅ No | Explicit exclusion |
| "AWS SQS FIFO queue setup" | ✅ No | Explicit exclusion |
| "gRPC streaming example" | ✅ No | Explicit exclusion |
| "ZeroMQ publish subscribe" | ⚠️ Ambiguous | Not explicitly excluded, but unlikely to match |

### Edge Cases

| Query | Expected behavior | Actual | Notes |
|-------|-------------------|--------|-------|
| "Message queue comparison NATS vs Kafka" | Might trigger | Likely yes — "NATS" keyword present | Acceptable — skill content is NATS-specific |
| "Messaging system with persistence" | Should not trigger | Likely no | Generic query lacks NATS-specific terms |
| "MQTT broker setup" | Should not trigger | ⚠️ Possible — SKILL.md covers MQTT bridge | MQTT bridge is a NATS feature, so triggering is reasonable |

**Trigger quality is excellent.** Comprehensive positive coverage with well-crafted negative exclusions.

---

## D. Scores

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 4 / 5 | All server config, CLI commands, and patterns verified correct. Deducted for legacy API usage and `RequestWithContext` bug in Go example. Core SKILL.md content is accurate. |
| **Completeness** | 4 / 5 | Exceptional coverage of core NATS, JetStream, clustering, auth, monitoring. 5 deep-dive reference docs, 4+ scripts, 5+ assets. Deducted for missing modern `jetstream` package guidance and duplicate files that create confusion. |
| **Actionability** | 5 / 5 | Production-ready code in Go, Python, TypeScript. Docker Compose, Helm values, server config templates. Health check, benchmark, cluster setup, and stream management scripts. Copy-paste ready. |
| **Trigger quality** | 5 / 5 | Comprehensive positive triggers covering every NATS concept. Explicit negative exclusions for 5 competing systems. Clear, well-structured description. |

**Overall: 4.5 / 5.0**

---

## E. Summary

### Strengths
- **Exceptional breadth**: Covers the entire NATS ecosystem from core pub/sub through JetStream, KV/Object stores, clustering, security, monitoring, and operational tooling
- **Multi-language examples**: Go, Python, TypeScript, and bash with realistic production patterns
- **Deep reference library**: 5 focused reference documents totaling ~2900 lines of detailed guidance
- **Production-ready assets**: Server config, Docker Compose, Helm values, and client examples that can be used immediately
- **Excellent patterns/anti-patterns section**: Concise DO/DON'T lists that prevent common mistakes
- **Strong trigger design**: Clear positive/negative boundary with no ambiguity

### Issues to Address
1. **Fix `RequestWithContext` bug** in `assets/go-client-example.go:460` — compilation error
2. **Add modern `jetstream` package note** — at minimum a callout in SKILL.md's JetStream section pointing to the new API
3. **Clean up duplicate files** — remove or properly reference `nats-health-check.sh`, `setup-nats-cluster.sh`, `docker-compose.yml`, `k8s-nats-helm-values.yaml`
4. **Add migration note** for users moving from legacy to modern JetStream API

### Verdict

**PASS** — High-quality skill with comprehensive coverage, accurate content, and excellent actionability. Issues identified are moderate (legacy API, one code bug, duplicate files) and do not prevent the skill from being useful and correct for current NATS deployments.

---

*Review generated: 2025-07-17*
