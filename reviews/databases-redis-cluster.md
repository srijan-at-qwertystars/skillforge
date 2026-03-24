# Review: redis-cluster

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5
Issues: none

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter (name + description) | ✅ | Lines 1–11. `name: redis-cluster`, multi-line `description` with positive and negative triggers. |
| Positive triggers | ✅ | 15 terms: Redis Cluster, Sentinel, replication, HA, scaling, failover, partitioning, hash slots, resharding, cluster config, client setup, MOVED/ASK, cross-slot errors, gossip protocol, monitoring. |
| Negative triggers | ✅ | 7 exclusions: single Redis basics, data structures tutorial, Memcached, DynamoDB, general caching, Streams tutorial, pub/sub basics, standalone CLI. |
| Under 500 lines | ✅ | 496 lines (4 lines of margin). |
| Imperative voice | ✅ | Commands and instructions throughout ("Set", "Use", "Open", "Configure", "Run"). |
| Examples | ✅ | 20+ code blocks: bash, conf, Python, Node.js, Java. Includes expected output. |
| Links to references/scripts/assets | ✅ | Three tables at the end linking all 3 reference docs, 3 scripts, and 3 asset files with descriptions. |

## B. Content Check

### Fact Verification (via web search against official Redis docs)

| Claim | Verified | Source |
|---|---|---|
| 16,384 hash slots | ✅ | redis.io cluster spec |
| `CRC16(key) mod 16384` | ✅ | redis.io cluster spec |
| Cluster bus port = client_port + 10000 | ✅ | redis.io cluster spec |
| Gossip: PING/PONG with node IDs, slot bitmap, failure flags | ✅ | redis.io cluster spec |
| PFAIL → FAIL promotion by majority quorum | ✅ | redis.io cluster spec |
| 3 masters minimum for quorum failover | ✅ | redis.io cluster spec |
| MOVED = permanent redirect, update slot map | ✅ | redis.io MOVED docs |
| ASK = temporary redirect during migration, send ASKING first, do NOT update slot map | ✅ | redis.io ASK docs |
| CLUSTER FAILOVER FORCE = skip data sync but still needs majority vote | ✅ | redis.io CLUSTER FAILOVER docs |
| CLUSTER FAILOVER TAKEOVER = skip vote entirely, emergency only | ✅ | redis.io CLUSTER FAILOVER docs |
| Hash tags: first `{` to first `}` is extracted | ✅ | redis.io cluster spec |
| Empty `{}` → full key is hashed | ✅ | redis.io cluster spec |

### Examples Correctness

- **Cluster create command** (line 80–84): Correct syntax, correct `--cluster-replicas 1` usage.
- **Slot distribution output** (lines 88–93): Correct — 0-5460, 5461-10922, 10923-16383 sums to 16384.
- **Python redis-py** (lines 249–258): Correct `RedisCluster` API with `startup_nodes` dict format.
- **Node.js ioredis** (lines 263–273): Correct `Redis.Cluster` constructor with `scaleReads` option.
- **Java Jedis** (lines 277–283): Correct `JedisCluster` constructor signature.
- **Hash tag examples** (lines 146–158): Correct — demonstrates same-slot MGET success and cross-slot MGET failure.
- **Lua script example** (lines 172–175): Correct — `EVAL` with 2 keys sharing hash tag.

### Pitfalls Coverage (10 items)

All 10 pitfalls are accurate and actionable. Covers the major production gotchas:
cross-slot errors, hotspots, big keys, bus port blocked, Docker/NAT, full coverage,
stale topology, memory without eviction, unbalanced slots, split-brain.

### Missing Gotchas Assessment

Minor items not in SKILL.md but covered in reference files:
- `KEYS`/`SCAN` only operates on local node (covered in operations-guide.md)
- Pub/Sub broadcast-to-all-nodes pre-Redis 7 (covered in advanced-patterns.md)
- Per-node FLUSHALL requirement (covered in operations-guide.md)
- Replication lag / write loss on failover (covered in troubleshooting.md)

**Verdict**: No missing gotchas — SKILL.md covers the top 10 inline, remainder appropriately delegated to reference docs.

### Reference Files Quality

- `references/advanced-patterns.md` (42.1 KB): Lua scripting, cross-slot transactions, sharded pub/sub, Streams, client-side caching, connection pooling, migration, ACLs. Thorough.
- `references/troubleshooting.md` (35.1 KB): Split-brain, slot migration failures, node join/leave, memory fragmentation, redirect storms, state inconsistency, replication buffer overflow, slow log, latency, network partitions. Thorough.
- `references/operations-guide.md` (31.3 KB): Rolling upgrades, capacity planning, backup, add/remove nodes, rebalancing, monitoring, Prometheus/Grafana, alerting, maintenance windows. Thorough.

### Scripts Quality

- `scripts/setup-cluster.sh` (323 lines): Well-structured, `set -euo pipefail`, Docker + bare-metal modes, production hardening, auth, cleanup. Proper prerequisite checks and wait loops.
- `scripts/health-check.sh` (320 lines): 10 checks (state, slots, nodes, replication, memory, clients, latency, balance, rejected conns, persistence). JSON output option. Correct exit codes.
- `scripts/resharding.sh` (256 lines): Dry-run, batch control, progress bar, rollback from log, post-validation. Production-grade.

### Assets Quality

- `assets/docker-compose.yaml` (331 lines): 6-node cluster with health checks, volumes, auto-init service, resource limits, proper networking. Ready to use.
- `assets/redis-cluster.conf` (320 lines): Comprehensive production template with clear `*** CHANGE ME ***` markers. Covers cluster, network, memory, AOF, RDB, security, replication, I/O threads, slow log, buffer limits, logging, Docker/NAT.
- `assets/sentinel.conf` (210 lines): Clear warning banner that Sentinel ≠ Cluster. Complete Sentinel config with documentation.

## C. Trigger Check

| Scenario | Should Trigger? | Would Trigger? | Result |
|---|---|---|---|
| "How do I set up a Redis Cluster?" | Yes | Yes — matches "Redis Cluster" | ✅ |
| "Redis hash slot distribution" | Yes | Yes — matches "Redis hash slots" | ✅ |
| "MOVED error in Redis" | Yes | Yes — matches "MOVED/ASK redirections" | ✅ |
| "Redis cluster resharding" | Yes | Yes — matches "Redis resharding" | ✅ |
| "Redis Sentinel failover" | Yes | Yes — matches "Redis Sentinel" | ✅ |
| "Redis gossip protocol" | Yes | Yes — matches "Redis gossip protocol" | ✅ |
| "How to use Redis SET/GET" | No | No — excluded "single Redis instance basics" | ✅ |
| "Redis data structures tutorial" | No | No — explicitly excluded | ✅ |
| "Memcached vs Redis" | No | No — "Memcached" excluded | ✅ |
| "Redis Streams consumer groups" | No | No — "Redis Streams tutorial" excluded | ✅ |
| "Redis pub/sub tutorial" | No | No — "Redis pub/sub basics" excluded | ✅ |
| "DynamoDB partition keys" | No | No — "DynamoDB" excluded | ✅ |

**False positive risk**: Low. Negative triggers are explicit and cover the main confusion points.
**False negative risk**: Very low. Positive triggers cover 15 distinct terms spanning all cluster-related topics.

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 5/5 | All technical facts verified against official Redis documentation. Slot count, CRC16 formula, gossip protocol, bus port, MOVED/ASK semantics, failover variants — all correct. |
| **Completeness** | 5/5 | Covers architecture, setup, failover, hash tags, resharding, client libraries (3 languages), persistence, monitoring (8 alert metrics), 10 pitfalls. Three deep reference docs, three production scripts, three deployment assets. |
| **Actionability** | 5/5 | Every section has copy-pasteable commands/configs. Docker Compose for instant local cluster. Scripts with --help, argument parsing, error handling. Production config with `*** CHANGE ME ***` markers. |
| **Trigger quality** | 5/5 | 15 positive triggers, 7 negative exclusions. No false positive/negative risks identified. Covers edge cases like Sentinel (included correctly for comparison) and Streams/pub/sub (excluded correctly). |

## E. Issue Filing

Overall score 5.0/5. No dimension ≤ 2. **No GitHub issues required.**

## F. Test Tag

`<!-- tested: pass -->` appended to SKILL.md.
