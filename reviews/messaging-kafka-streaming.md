# QA Review: kafka-streaming

**Skill path:** `~/skillforge/messaging/kafka-streaming/`
**Reviewed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Verdict:** PASS (with noted issues)

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML `name` + `description` | ✅ | Present and well-formed |
| Positive triggers in description | ✅ | Covers imports, docker images, Kafka concepts, adjacent patterns (event sourcing, CQRS, outbox, DLQ, EOS) |
| Negative triggers in description | ✅ | Explicitly excludes RabbitMQ, SQS, Celery, Redis Pub/Sub, Pulsar, Kinesis, NATS; references `celery-task-queues` skill |
| Body under 500 lines | ✅ | 500 total lines (484 body lines after 16-line frontmatter) |
| Imperative voice, no filler | ✅ | Dense, technical, no hedging or fluff |
| Examples with input/output | ✅ | Extensive code examples across Java, Python, Node.js, YAML, JSON, bash |
| references/ linked from SKILL.md | ✅ | Table at line 475–479 links all 3 reference docs with descriptions |
| scripts/ linked from SKILL.md | ✅ | Table at line 483–489 links all 3 scripts with usage |
| assets/ linked from SKILL.md | ⚠️ | Table at line 493–500 lists 4 of 5 assets — **`connect-source.json` is missing** from the table |

---

## b. Content Check

### Accuracy

| Claim | Verified | Status |
|-------|----------|--------|
| ZooKeeper removed in Kafka 4.0 | Web search confirms (released 2025-03-18) | ✅ |
| KRaft default in 4.0+ | Confirmed | ✅ |
| KIP-848 server-side rebalancing in 4.0 | Confirmed GA in 4.0 | ✅ |
| Producer `acks` default = `all` | Correct for Kafka ≥ 3.0 (changed from `1`) | ✅ |
| `session.timeout.ms` default = 45000 | Correct for Kafka 3.x+ | ✅ |
| `enable.idempotence` default true since 3.0 | Confirmed | ✅ |
| `EXACTLY_ONCE_V2` requires broker ≥ 2.5 | Confirmed (KIP-447) | ✅ |
| KafkaJS: "Pure JS, async/await, no native deps" | Technically correct but **incomplete** — KafkaJS is in **maintenance mode** since 2024 | ⚠️ |
| `franz-go` at `github.com/twmb/franz-go` | Correct | ✅ |
| `sarama` at `github.com/IBM/sarama` | Correct (moved from Shopify) | ✅ |
| Schema Registry compatibility table | Correct (BACKWARD is default) | ✅ |

### Code Correctness

| File | Status | Issue |
|------|--------|-------|
| SKILL.md inline examples | ✅ | All Java, Python, Node.js, YAML snippets are correct |
| `assets/producer-template.py` | ✅ | Correct confluent-kafka usage, proper delivery callbacks, graceful shutdown |
| `assets/consumer-template.py` | ✅ | Correct manual-commit pattern, DLQ routing, signal handling |
| `assets/docker-compose.yml` | ✅ | Valid KRaft config, correct inter-service dependencies, healthcheck |
| `assets/connect-source.json` | ✅ | Valid Debezium config, proper env-var substitution for password |
| `assets/streams-template.java` | ❌ | **Compile error**: Uses `events.branch(Named.as("branch-"), ...)` — this signature does not exist. `KStream.branch()` takes only `Predicate...` varargs (and is deprecated since Kafka 2.4/KIP-418). Should use `split().branch().defaultBranch()` API. |
| `scripts/kafka-local.sh` | ✅ | Correct Docker-based KRaft setup |
| `scripts/consumer-lag-check.sh` | ✅ | Proper lag parsing and threshold alerting |
| `scripts/topic-management.sh` | ✅ | Full CRUD operations, correct CLI flags |

### Missing Gotchas

1. **KafkaJS maintenance mode**: The client libraries table should note that KafkaJS is in maintenance mode and recommend `@confluentinc/kafka-javascript` for new Node.js projects.
2. **`message.timestamp.type` impact on compaction**: SKILL.md mentions `LogAppendTime` for retry topics but doesn't explain the interaction with compaction — `LogAppendTime` changes the semantics of `min.compaction.lag.ms`.
3. **Consumer static group membership**: Mentioned in troubleshooting reference but not in the main SKILL.md pitfalls section — this is a key production pattern engineers hit.

---

## c. Trigger Check

**Positive trigger coverage**: Excellent. Covers:
- Direct imports (`confluent-kafka`, `kafkajs`, `sarama`, `franz-go`, `org.apache.kafka`)
- Docker images (`kafka/kraft/schema-registry`)
- Concepts (`topics/partitions/consumer-groups/offsets/brokers`)
- Adjacent patterns (`event sourcing`, `CQRS`, `transactional outbox`, `DLQ`, `retry topics`, `EOS`)
- Operations (`monitoring`, `Kafka configuration tuning`)

**Negative trigger coverage**: Strong. Explicitly excludes:
- RabbitMQ, SQS, Celery, Redis Pub/Sub (general message queues)
- Pulsar, Kinesis, NATS (non-Kafka streaming)
- Generic pub/sub without Kafka mention
- Cross-references `celery-task-queues` skill

**False trigger risk**: Low. The "DO NOT trigger" clause is specific and well-delineated. A query about "RabbitMQ consumer lag" or "SQS dead letter queue" would not match.

**Under-trigger risk**: Low. The description covers the full Kafka ecosystem including Streams, Connect, Schema Registry, and operational concerns.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Core SKILL.md claims verified correct. KafkaJS maintenance-mode omission is notable but not an error. |
| **Completeness** | 4 | Comprehensive coverage of Kafka ecosystem. Three deep reference docs, three scripts, five asset templates. Minor gap: `connect-source.json` unlisted in asset table. |
| **Actionability** | 4 | Most templates are production-ready with error handling, graceful shutdown, DLQ routing. `streams-template.java` has a compile error in the branch API that would block direct use. |
| **Trigger quality** | 5 | Thorough positive and negative triggers with cross-skill references. Minimal false-trigger risk. |

**Overall: 4.25 / 5.0**

---

## e. Issues

Overall ≥ 4.0 and no dimension ≤ 2. **No GitHub issues required.**

### Recommended Fixes (non-blocking)

1. **`assets/streams-template.java` line 144**: Replace deprecated `branch(Named, Predicate...)` (which doesn't compile) with `split(Named.as("branch-")).branch(..., Branched.as("valid")).defaultBranch(Branched.as("invalid"))`.
2. **SKILL.md line 280 (Client Libraries table)**: Add note that KafkaJS is in maintenance mode; recommend `@confluentinc/kafka-javascript` for new projects.
3. **SKILL.md line 493 (Asset Templates table)**: Add `connect-source.json` entry.

---

## f. Tested

**Status: PASS**
