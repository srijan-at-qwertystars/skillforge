# QA Review: rabbitmq-patterns

**Skill path:** `~/skillforge/messaging/rabbitmq-patterns/`
**Reviewed:** 2025-07-16
**Reviewer:** Copilot QA

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `rabbitmq-patterns` |
| YAML frontmatter `description` | ✅ Pass | Present, multi-line |
| Positive triggers (when to use) | ✅ Pass | 15+ specific trigger scenarios listed |
| Negative triggers (when NOT to use) | ✅ Pass | 8 competing technologies explicitly excluded |
| Body under 500 lines | ✅ Pass | 471 lines |
| Imperative voice, no filler | ✅ Pass | Direct, action-oriented prose throughout |
| Examples with input/output | ✅ Pass | Python, Node.js, Go, bash, YAML, INI examples |
| `references/` linked from SKILL.md | ✅ Pass | 3 files linked with descriptions |
| `scripts/` linked from SKILL.md | ✅ Pass | 3 scripts linked with usage examples |
| `assets/` linked from SKILL.md | ✅ Pass | 5 assets linked with descriptions |
| All referenced files exist | ✅ Pass | All 11 referenced files verified present |

---

## b. Content Check

### Verified Accurate

- **Quorum queue arguments** (`x-queue-type`, `x-delivery-limit`, `x-dead-letter-strategy: at-least-once`): Verified correct against RabbitMQ docs.
- **Stream offsets** (`first`, `last`, `next`, timestamp, numeric): Verified correct. Missing the `interval` offset (e.g., `'1h'`) — minor omission.
- **Publisher confirms (pika)**: `pika.exceptions.UnroutableError` and `pika.exceptions.NackError` are the correct exception types for `BlockingConnection` with `confirm_delivery()`.
- **Exchange types and routing**: Correct. Wildcard semantics (`*` = one word, `#` = zero-or-more) accurate.
- **Quorum queue constraints**: Correct — no exclusive, no non-durable, no priority, no global QoS.
- **TLS config**: Valid `rabbitmq.conf` syntax. TLSv1.3 + TLSv1.2 is the recommended setup.
- **Kubernetes Cluster Operator**: CRD `rabbitmq.com/v1beta1 RabbitmqCluster` is the correct API.
- **Shovel/Federation CLI**: Commands verified correct.
- **Docker image tag**: `rabbitmq:3.13-management-alpine` is a valid current tag.

### Issues Found

1. **Lazy queue deprecation (Accuracy — Medium severity)**
   Line 432 in Performance Tuning Checklist item 4: _"Use lazy queues (`x-queue-mode: lazy`) for large backlogs to reduce memory pressure."_
   **Problem:** `x-queue-mode: lazy` is deprecated since RabbitMQ 3.12 (2023). All classic queues now behave as lazy by default. This argument is a no-op on 3.12+. Recommending it is misleading for anyone on a current version.
   **Fix:** Replace with: _"Classic queues are lazy by default since 3.12. For older versions, set `x-queue-mode: lazy`. For new deployments, prefer quorum queues."_

2. **Exclusive consumer vs Single Active Consumer conflation (Accuracy — Low severity)**
   Line 179: _"Exclusive consumer: Set `exclusive=True` for single-active-consumer semantics."_
   **Problem:** `exclusive=True` on `basic_consume` means only that consumer can access the queue (others get an error, queue auto-deletes on disconnect). This is NOT the same as `x-single-active-consumer`, which allows multiple registered consumers with only one active and automatic failover. The skill correctly describes SAC on the next line but the exclusive consumer description is misleading.
   **Fix:** Reword to: _"Exclusive consumer: Set `exclusive=True` to lock the queue to a single consumer (queue auto-deletes on disconnect)."_

3. **Missing stream offset option (Completeness — Low severity)**
   Line 102 lists offset options but omits the `interval` offset (e.g., `'1h'`, `'7D'`) which allows consuming from a relative time window.

### Missing Gotchas

- **Connection recovery**: No guidance on automatic reconnection. In production, connections drop — pika's `BlockingConnection` has no auto-recovery; `SelectConnection` or heartbeat-based detection + manual reconnect is essential. This is the #1 production issue for new RabbitMQ users.
- **Message ordering**: No explicit mention that ordering is guaranteed per-queue but NOT across multiple queues or with competing consumers (redelivery can reorder).
- **Memory watermark interaction with publisher confirms**: When memory alarm fires, publishers block (not nack). This distinction from NackError is not mentioned.

---

## c. Trigger Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| Triggers for RabbitMQ queries | ✅ Pass | Description mentions 15+ RabbitMQ-specific features (exchanges, quorum queues, streams, DLQ, publisher confirms, etc.) |
| False trigger: Kafka | ✅ Pass | Explicitly excluded: "Apache Kafka for log streaming or event sourcing" |
| False trigger: NATS | ✅ Pass | Explicitly excluded: "NATS for lightweight pub/sub" |
| False trigger: AWS SQS/SNS | ✅ Pass | Explicitly excluded |
| False trigger: General messaging | ✅ Pass | Explicitly excluded: "general message queue theory without RabbitMQ specifics" |
| Description specificity | ✅ Pass | Highly specific; unlikely to trigger for non-RabbitMQ messaging |

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Core AMQP model, quorum queues, streams, confirms, clustering, security all verified correct. Lazy queue deprecation and exclusive/SAC conflation are notable but non-critical errors. |
| **Completeness** | 4 | Excellent breadth: 3 languages, Docker, K8s, Shovel/Federation, monitoring, security, DLQ patterns. Missing connection recovery guidance and message ordering caveats. |
| **Actionability** | 5 | Every section has runnable code. Scripts for cluster setup, health checks, queue purging. Assets include production-ready configs and full producer/consumer implementations. |
| **Trigger quality** | 5 | Comprehensive positive triggers covering all major RabbitMQ features. Negative triggers explicitly exclude 8 competing technologies. No realistic false-trigger scenarios. |

**Overall: 4.5 / 5.0**

---

## e. Recommendation

**PASS** — Skill is production-quality with minor issues. The lazy queue deprecation should be fixed promptly as it affects anyone on RabbitMQ 3.12+ (current stable). Other issues are low severity.

### Suggested Fixes (Priority Order)

1. Update Performance Tuning item 4 re: lazy queue deprecation (3.12+)
2. Clarify exclusive consumer vs single-active-consumer distinction
3. Add connection recovery / reconnection best practices section
4. Add interval offset option to streams documentation
5. Add note on message ordering guarantees with competing consumers
