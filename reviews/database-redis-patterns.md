# Review: redis-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **RPUSH + BRPOP FIFO queue bug (Accuracy)** — Line 65-66: The Lists section labels the pattern as "Queues (FIFO)" but uses `RPUSH` + `BRPOP`, which both operate on the right/tail end, producing LIFO (stack) behavior. A correct FIFO queue uses `RPUSH` + `BLPOP` (or `LPUSH` + `BRPOP`). An AI following this example would build a stack, not a queue.

2. **Outdated ziplist terminology (Accuracy)** — Lines 49, 400-404: SKILL.md references `hash-max-ziplist-entries` and "ziplist" encoding, which are Redis ≤6.2 terms. Redis 7+ renamed these to `hash-max-listpack-entries` and "listpack" encoding. The skill's own `assets/redis.conf` correctly uses `hash-max-listpack-entries`, creating an internal inconsistency. Similarly `list-max-ziplist-size` → `list-max-listpack-size` and `zset-max-ziplist-entries` → `zset-max-listpack-entries`.

3. **WATCH pseudo-code not executable (Actionability)** — Lines 232-238: The `SET inventory:widget (val - 1)` is pseudo-code, not valid Redis syntax. An AI would fail trying to execute this literally. Should show the Python/client-side WATCH pattern instead, or clarify it's pseudo-code.

## Structure Check

- [x] YAML frontmatter with `name` and `description`
- [x] Positive triggers listed (caching, pub/sub, streams, locks, sessions, rate limiting, key design, cluster)
- [x] Negative triggers listed (Memcached, RabbitMQ/Kafka, relational DB, MongoDB)
- [x] Body under 500 lines (491 lines)
- [x] Imperative voice throughout
- [x] Examples with input/output comments
- [x] All references/, scripts/, and assets/ linked from SKILL.md "Additional Resources" section

## Content Verification (Web-Searched)

- [x] BRPOP syntax and behavior — confirmed correct syntax, but RPUSH+BRPOP=LIFO (see issue #1)
- [x] GEOSEARCH FROMMEMBER BYRADIUS — correct for Redis 6.2+
- [x] XAUTOCLAIM syntax — correct (key group consumer min-idle-time start COUNT)
- [x] SSUBSCRIBE/SPUBLISH — correctly labeled "Redis 7+"
- [x] FUNCTION LOAD syntax — correct shebang format
- [x] Lua scripting: EVAL, KEYS[], ARGV[] usage — correct
- [x] Redlock algorithm steps — accurate, includes appropriate safety caveat
- [x] Cluster hash slots (16384, CRC16) — correct
- [x] HyperLogLog error rate (~0.81%) — correct

## Trigger Check

- Description is comprehensive and specific — covers all major Redis use cases
- Negative triggers properly exclude adjacent technologies (Memcached, RabbitMQ, Kafka, MongoDB, SQL)
- Low false-trigger risk: "unless comparing" qualifier for message queue comparisons is well-scoped
- No false-positive concerns identified

## Assets/Scripts Quality

- `redis.conf` — Production-ready Redis 7+ template, well-commented, correct parameters
- `sentinel.conf` — Complete with client connection examples (Python, Node.js)
- `redis-cluster-setup.md` — Thorough 6-node guide with Docker Compose, operations, troubleshooting
- `lua-scripts/` — All 3 scripts are correct, atomic, with proper KEYS/ARGV usage
- `scripts/` — Health check, benchmark, and key analyzer are production-safe (SCAN-based)
- References cover advanced patterns, troubleshooting, and performance tuning comprehensively
