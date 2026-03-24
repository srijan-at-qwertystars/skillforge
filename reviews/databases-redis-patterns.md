# QA Review: redis-patterns

**Skill path:** `~/skillforge/databases/redis-patterns/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** **PASS**

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `redis-patterns` |
| YAML frontmatter `description` with positive triggers | ✅ | USE when, TRIGGER on imports/commands |
| YAML frontmatter `description` with negative triggers | ✅ | DO NOT trigger for Valkey, Memcached, DynamoDB |
| Body under 500 lines | ✅ | 491 lines (tight but within limit) |
| Imperative voice | ✅ | "Use for", "Always configure", "Never use KEYS in production" |
| Examples with input/output | ✅ | All Redis command blocks include expected return values in comments |
| References linked from SKILL.md | ✅ | 3 reference docs linked in table at bottom |
| Scripts linked from SKILL.md | ✅ | 3 scripts linked with usage descriptions |
| Assets linked from SKILL.md | ✅ | 5 assets linked (docker-compose, config, Lua, Python) |

**All structure checks pass.**

---

## B. Content Check — Fact Verification

All key claims verified via web search against current Redis documentation:

| Claim | Verified | Source |
|-------|----------|--------|
| Single-threaded command execution, I/O threads since Redis 6 | ✅ | redis.io docs, multiple technical articles |
| `HEXPIRE` per-field expiry introduced in Redis 7.4+ | ✅ | redis.io/commands/hexpire, Redis 7.4 release notes |
| HyperLogLog ~0.81% standard error, 12KB max | ✅ | redis.io HyperLogLog docs |
| `LPUSH` + `RPOP` = FIFO queue | ✅ | redis.io lists docs — msg1 pushed first lands at right, RPOP gets it first |
| Client libraries (ioredis, redis-py, go-redis/v9, Jedis, Lettuce, fred, redis-rs) | ✅ | All confirmed current and actively maintained |
| `fred` is a Rust crate (not Node.js) | ✅ | crates.io/crates/fred, docs.rs/fred |
| Redlock caveats (clock drift, GC pauses) | ✅ | Accurately cites Martin Kleppmann's analysis |
| `GEOSEARCH` with `FROMLONLAT`/`BYRADIUS` syntax | ✅ | Redis 6.2+ command syntax |
| AOF `aof-use-rdb-preamble` default in Redis 7 | ✅ | Enabled by default since Redis 4.0, confirmed in 7.x |
| `XAUTOCLAIM` available since 6.2+ | ✅ | Correct |
| Eviction policies list (8 policies including LFU variants) | ✅ | Complete and accurate |

### Minor Issues Found

1. **`redis.conf` redundancy:** Lines 153–154 have both `activedefrag yes` and `active-defrag-enabled yes` — these are the same directive (old vs new name). Harmless but redundant.
2. **`io-threads-do-reads yes`** in redis.conf (line 28): Redis docs note this is experimental. Should add a comment noting this.
3. **Line count at 491/500**: No headroom for additions without refactoring.

### Missing Gotchas (minor — covered in references)

- RESP3 protocol not mentioned in main SKILL.md (covered in `references/advanced-patterns.md`)
- Redis Functions (7.0 replacement for EVAL) not in main doc (covered in references)
- No mention of `CLIENT NO-EVICT` for protecting admin connections

These are appropriately delegated to reference files and do not reduce the main doc's quality.

### Examples Correctness

All code examples checked:
- Redis CLI examples: ✅ Correct syntax and expected outputs
- Python `redis-py` pipeline example: ✅ Correct API usage
- Node.js `ioredis` pipeline example: ✅ Correct API usage
- Lua rate-limiter script: ✅ Sound sliding-window algorithm
- Python cache patterns: ✅ Well-structured, production-quality code with proper error handling
- Docker Compose files: ✅ Valid YAML, correct Redis Stack and Cluster configurations
- Shell scripts: ✅ Proper `set -euo pipefail`, correct `redis-cli` usage

---

## C. Trigger Check

| Scenario | Expected | Actual | Status |
|----------|----------|--------|--------|
| "How do I implement caching with Redis?" | Trigger | ✅ Triggers on "Redis" keyword | ✅ |
| "Set up ioredis connection pool" | Trigger | ✅ Triggers on "ioredis" import mention | ✅ |
| "ZADD leaderboard pattern" | Trigger | ✅ Triggers on "ZADD" command mention | ✅ |
| "Redis Cluster hash slots" | Trigger | ✅ Triggers on "Redis Cluster" mention | ✅ |
| "Implement rate limiter with redis-py" | Trigger | ✅ Triggers on "redis-py" import | ✅ |
| "How to use Valkey for caching?" | No trigger | ✅ Explicit exclusion: "DO NOT trigger for Valkey" | ✅ |
| "Memcached vs Redis comparison" | No trigger | ✅ Excludes Memcached; no general comparison trigger | ✅ |
| "DynamoDB session storage" | No trigger | ✅ Explicit exclusion for DynamoDB | ✅ |

**Edge case:** A Valkey user importing `ioredis` could trigger this skill since `ioredis` is listed as a positive trigger. This is acceptable — the libraries are Redis-native and the skill content applies.

**Trigger quality is strong** with comprehensive positive triggers (commands, libraries, features) and explicit negative exclusions.

---

## D. Scores

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 5 | All technical claims verified correct against current Redis docs |
| **Completeness** | 4 | Comprehensive main doc covering all core patterns; 3 deep-dive references; missing RESP3/Functions in main doc (appropriate in refs) |
| **Actionability** | 5 | Ready-to-run scripts (local setup, health check, benchmark), production config, Docker Compose files, Python code patterns with tests |
| **Trigger quality** | 4 | Strong positive/negative triggers with explicit library and command matches; minor Valkey-library edge case |
| **Overall** | **4.5** | Excellent skill — production-ready, accurate, comprehensive |

---

## E. Issue Filing

**No GitHub issues required.** Overall score (4.5) ≥ 4.0 and no dimension ≤ 2.

---

## F. Test Status

`<!-- tested: pass -->` appended to SKILL.md.

---

## Summary

This is a high-quality, production-grade Redis skill. All technical claims were verified accurate against current Redis 7.x documentation. The structure is well-organized with a main reference doc under 500 lines, three deep-dive reference files, three utility scripts, and five asset files. Code examples are correct and actionable. Trigger description is comprehensive with proper positive and negative matching. No blocking issues found.
