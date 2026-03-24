# QA Review: databases/valkey-redis

**Reviewer**: Copilot CLI (automated)
**Date**: 2025-07-17
**Skill path**: `~/skillforge/databases/valkey-redis/`

---

## A. Structure

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name) | ✅ | `valkey-redis` |
| YAML frontmatter (description) | ✅ | Detailed description with trigger guidance |
| Positive triggers | ✅ | ioredis, redis-py, go-redis, jedis, lettuce, valkey-py, valkey-glide, caching layer, session store, pub/sub, rate limiting, streams, Redlock, ElastiCache, MemoryDB, Dragonfly, KeyDB |
| Negative triggers | ✅ | SQL databases, MongoDB, DynamoDB, Memcached (without Redis mention), RabbitMQ/Kafka |
| Body < 500 lines | ✅ | 499 lines (just under limit) |
| Imperative voice | ✅ | "Use", "Set", "Deploy", "Always configure" |
| Code examples | ✅ | Every section includes copy-paste examples in Redis commands, Python, JavaScript, Lua |
| Links to refs/scripts/assets | ✅ | All 3 references, 3 scripts, 4 assets linked with descriptions in Additional Resources section |

**Verdict**: Structure is exemplary. All criteria met.

---

## B. Content — Technical Accuracy Verification

### Verified via web search

| Claim | Verified | Source |
|-------|----------|--------|
| Valkey is BSD-3 fork of Redis 7.2.4, March 2024, Linux Foundation | ✅ | linuxfoundation.org press release |
| RESP2/RESP3 protocol compatibility | ✅ | Percona Valkey 7.2.4 RC1 docs |
| Redis licensing: RSALv2/SSPLv1 | ✅ | Multiple sources confirm |
| HyperLogLog: 12KB/key, 0.81% standard error | ✅ | redis.io docs, w3resource |
| GEOSEARCH syntax (FROMLONLAT, BYRADIUS, FROMMEMBER) | ✅ | redis.io, valkey.io |
| Redlock: N≥5 nodes, majority N/2+1 | ✅ | Redis.io distlock spec |
| Cluster: 16384 hash slots, CRC16 mod 16384 | ✅ | Redis cluster spec |

### Minor observations (not errors)

1. **ZREVRANGE deprecation**: SKILL.md uses `ZREVRANGE` (deprecated since Redis 6.2, replaced by `ZRANGE ... REV`). Still functional; used for pedagogical clarity. The advanced-patterns.md also uses it. Not an error since the command works, but a future update could note the modern form.

2. **Lua non-deterministic commands**: Skill says "Avoid non-deterministic calls (TIME, RANDOMKEY)." Since Redis 7.0+/Valkey, script effects replication is default and these commands ARE allowed. The advice is conservatively safe and defensible but slightly outdated for the Redis 7+/Valkey target audience. The troubleshooting reference correctly frames this as for "scripts intended for replication."

3. **Redis Functions**: No mention of `FUNCTION LOAD`/`FUNCTION CALL` (Redis 7.0+) as a modern alternative to EVAL/EVALSHA. Minor omission — Lua EVAL coverage is thorough.

4. **Client-side caching**: No coverage of Redis 6+ server-assisted client-side caching (tracking). Noted in the client library table that valkey-go supports it, but no dedicated section.

### Reference files quality

- **advanced-patterns.md** (399 lines): Excellent — covers bloom/cuckoo filters, geospatial, RediSearch, RedisJSON, state machines, deduplication. Correct BF.*/CF.*/FT.*/JSON.* syntax verified.
- **troubleshooting.md** (396 lines): Comprehensive — memory diagnostics, SLOWLOG, cluster slot migration, sentinel split-brain, RESP errors, Lua debugging. All advice verified correct.
- **production-guide.md** (336 lines): Solid — sizing formulas, monitoring (Prometheus/PromQL), security (ACLs, TLS), Docker/K8s patterns with StatefulSet recommendation.

### Scripts quality

- **setup-cluster.sh** (173 lines): Auto-detects Valkey/Redis, creates 6-node cluster, trap cleanup, connection verification. Well-structured.
- **health-check.sh** (339 lines): Checks memory, clients, replication, persistence, slowlog, keyspace, cluster. JSON/quiet modes. Proper exit codes (0/1/2/3).
- **migrate-redis-valkey.sh** (477 lines): 5 commands (check/prepare/swap/verify/rollback). Includes backup, dry-run, key count verification. Production-ready.

### Assets quality

- **redis.conf** (287 lines): Production-ready, annotated with rationale. Covers network, replication, security, memory, AOF, cluster, I/O threads, jemalloc.
- **docker-compose.yml** (482 lines): Three profiles (standalone, sentinel, cluster). Sentinel with 3 nodes + quorum. Cluster with 6 nodes + auto-init. Health checks on all services.
- **connection-template.ts** (396 lines): ioredis patterns for standalone, sentinel, cluster, pub/sub. Includes graceful shutdown, retry strategies, TLS config.
- **rate-limiter.lua** (65 lines): Sliding window rate limiter with proper sorted set cleanup, retry-after calculation, multi-language usage examples.

---

## C. Trigger Check — False Positive Analysis

| Scenario | Should Trigger? | Will Trigger? | Result |
|----------|----------------|---------------|--------|
| Code imports `ioredis` | Yes | Yes | ✅ |
| Code imports `redis-py` | Yes | Yes | ✅ |
| User asks about Memcached caching | No | No | ✅ |
| User asks about DynamoDB tables | No | No | ✅ |
| User asks about PostgreSQL queries | No | No | ✅ |
| User asks about RabbitMQ pub/sub | No | No | ✅ |
| Dockerfile uses `redis:7-alpine` image | Yes | Yes | ✅ |
| User mentions "Memcached vs Redis" | Yes (comparison) | Yes (Redis mention) | ✅ |
| User asks about "ElastiCache for Redis" | Yes | Yes | ✅ |
| User asks about "general caching strategies" | No | No | ✅ |
| Code imports `mongodb` driver | No | No | ✅ |
| User asks about Kafka streams | No | No (unless Redis mentioned) | ✅ |

**Verdict**: Trigger boundaries are well-defined. No false positive risk identified.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All commands, data structures, configs, and patterns verified correct. Two minor notes (ZREVRANGE deprecation, Lua non-deterministic advice) are defensible choices, not errors. |
| **Completeness** | 5 | Covers all major Redis/Valkey topics in SKILL.md. Three reference docs add advanced patterns, troubleshooting, and production operations. Three scripts for cluster setup, health checks, and migration. Four assets with production config, Docker Compose, TypeScript template, and Lua rate limiter. |
| **Actionability** | 5 | Every section includes copy-paste code examples. Production-ready config files, Docker Compose with 3 deployment profiles, migration script with rollback, health check with exit codes. Multi-language examples (Python, JS/TS, Lua, bash). |
| **Trigger Quality** | 5 | Comprehensive positive triggers covering all major client libraries and use cases. Clear negative triggers preventing false positives. Correctly handles edge cases like Redis-vs-Memcached comparisons. |

### Overall Score: **5.0** (average of 5, 5, 5, 5)

---

## E. Verdict

**PASS** ✅

This is a high-quality, comprehensive skill. No dimension ≤ 2 and overall ≥ 4.0. No GitHub issues required.

### Suggestions for future improvement (non-blocking)

1. Add a note that `ZREVRANGE` is deprecated since Redis 6.2 — recommend `ZRANGE ... REV` as the modern form
2. Update Lua scripting section to note that Redis 7+/Valkey allows non-deterministic commands via script effects replication
3. Consider adding a section on Redis Functions (`FUNCTION LOAD`/`FUNCTION CALL`) as the modern scripting alternative
4. Consider adding client-side caching (server-assisted tracking) coverage
