# QA Review: messaging/kafka-streaming

**Reviewed:** 2025-07-15
**Skill path:** `messaging/kafka-streaming/`
**Reviewer:** Copilot QA

---

## Scores

| Dimension | Score | Notes |
|-----------|-------|-------|
| **Accuracy** | 4 | Two factual errors: `session.timeout.ms` default wrong, hopping window example incorrect |
| **Completeness** | 5 | Excellent breadth: producers, consumers, Streams, Connect, Schema Registry, security, monitoring, ops |
| **Actionability** | 5 | Production-ready templates in Java/Python/Node.js/Go, Docker Compose, config files, monitoring scripts |
| **Trigger quality** | 4 | Good positive/negative triggers; slight false-trigger risk on broad terms |
| **Overall** | **4.5** | High-quality skill with minor accuracy fixes needed |

---

## a. Structure Check

- [x] YAML frontmatter has `name` and `description`
- [x] Positive triggers present (event-driven architectures, streaming pipelines, CDC, etc.)
- [x] Negative triggers present (RabbitMQ, Redis pub/sub, SQS/SNS, Pub/Sub, Service Bus, MQTT, request-reply)
- [x] Body under 500 lines (419 lines)
- [x] Imperative voice used throughout
- [x] Code examples in multiple languages (Java, Python, Node.js, Go)
- [x] Resources linked from SKILL.md (references/, scripts/, assets/ tables)
- [x] References exist: advanced-patterns.md (2128 lines), troubleshooting.md (1166 lines), api-reference.md (559 lines), operations-guide.md (590 lines)
- [x] Scripts exist: setup-kafka.sh, monitor-lag.sh, kafka-local.sh, consumer-lag-check.sh, topic-management.sh
- [x] Assets exist: docker-compose.yml, producer/consumer configs, connect-source.json, Python/Java templates

**Verdict:** Structure is excellent. No issues.

---

## b. Content Check — Issues Found

### Issue 1: `session.timeout.ms` default is wrong (SKILL.md line 109)

**Claim:** "Tune `session.timeout.ms` (default 45s)"
**Actual:** The default in Kafka 3.x is **10 seconds** (10000ms), not 45 seconds. Verified via [Kafka 3.4 consumer docs](https://kafka.apache.org/34/configuration/consumer-configs/).

The consumer-config.properties asset file also sets `session.timeout.ms=45000`, which is a valid custom value but should not be labeled as the default.

### Issue 2: Hopping window example is incorrect (SKILL.md line 144)

**Claim:** `TimeWindows.ofSizeAndGrace(Duration.ofMinutes(5), Duration.ofMinutes(1))` shown as hopping window syntax.
**Actual:** This creates a **tumbling** window with a 1-minute grace period. The second parameter is `grace`, not the advance/hop interval. A hopping window requires an additional `.advanceBy()` call:
```java
TimeWindows.ofSizeAndGrace(Duration.ofMinutes(5), Duration.ofMinutes(1))
           .advanceBy(Duration.ofMinutes(2))
```
Verified via [Kafka Streams JavaDocs](https://kafka.apache.org/30/javadoc/org/apache/kafka/streams/kstream/TimeWindows.html).

### Issue 3: Sticky partitioning attribution (SKILL.md line 57)

**Claim:** "Null keys use sticky partitioning (round-robin per batch) in Kafka 3.x+"
**Actual:** Sticky partitioning was introduced in **Kafka 2.4** (KIP-480), not 3.x+. The description "round-robin per batch" is also misleading — it sticks to one random partition per batch, not round-robin. Minor inaccuracy.

### Issue 4: Docker image version inconsistency

- `setup-kafka.sh` uses `apache/kafka:3.7.0`
- `assets/docker-compose.yml` and SKILL.md use `apache/kafka:3.9.0`

### Issue 5: Missing gotcha — KafkaJS maintenance status

The Node.js example uses KafkaJS, which is effectively unmaintained (last release 2023). Users should be warned to consider alternatives like `confluent-kafka-javascript` for new projects.

### Verified Claims (Correct)

- ✅ `enable.idempotence=true` default since Kafka 3.0 (KIP-679)
- ✅ KRaft mode supports 1.5M+ partitions
- ✅ ZooKeeper removed in Kafka 4.0
- ✅ `acks=all` default since Kafka 3.0
- ✅ KafkaJS `{ idempotent: true }` API is correct
- ✅ Schema Registry compatibility modes (BACKWARD default) correct
- ✅ `min.insync.replicas=2` with `acks=all` recommendation correct
- ✅ CooperativeStickyAssignor recommendation correct
- ✅ Debezium connector config in connect-source.json is well-formed
- ✅ Docker Compose KRaft setup is valid
- ✅ CLI tool flags in api-reference.md are accurate
- ✅ Producer/consumer config property files are thorough and correct

---

## c. Trigger Check

**Would trigger correctly:**
- ✅ "Build a Kafka producer" → yes
- ✅ "Set up event streaming with Kafka" → yes
- ✅ "Kafka Streams windowing aggregation" → yes
- ✅ "CDC with Debezium and Kafka" → yes
- ✅ "Kafka consumer lag monitoring" → yes
- ✅ "Schema Registry Avro compatibility" → yes

**False trigger risks (low):**
- ⚠️ "event-driven architectures" is broad — could trigger when user means non-Kafka event systems
- ⚠️ "real-time analytics" could trigger for Flink/Spark Streaming without Kafka context
- Mitigated by comprehensive negative trigger list

**False negative risks:**
- "confluent-kafka" / "librdkafka" not in trigger description
- "Apache Pulsar" not listed as negative trigger (close competitor)

---

## d. Summary

This is a **high-quality, comprehensive skill** with excellent breadth and depth. The reference docs, scripts, and templates are production-grade. The two factual errors (session.timeout.ms default, hopping window syntax) should be corrected but don't undermine the overall value. The Docker image version inconsistency between scripts and assets is a minor housekeeping issue.

### Recommended fixes (priority order):
1. **Fix** hopping window example — add `.advanceBy()` call
2. **Fix** `session.timeout.ms` default from 45s to 10s
3. **Fix** sticky partitioning: change "Kafka 3.x+" to "Kafka 2.4+" and clarify "random per batch" vs "round-robin"
4. **Align** Docker image versions across setup-kafka.sh and assets
5. **Add** KafkaJS deprecation warning in Node.js section
6. **Add** "confluent-kafka" / "librdkafka" to trigger description for better recall

---

**Overall: 4.5/5 — PASS**
**No GitHub issues required** (overall ≥ 4.0, no dimension ≤ 2)
