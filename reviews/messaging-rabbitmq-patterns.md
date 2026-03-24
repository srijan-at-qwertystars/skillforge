# Review: rabbitmq-patterns

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **Quorum queue default delivery limit incorrect** — SKILL.md line 214 states "default 20 in 4.0" but the actual default is 16 (per official RabbitMQ docs and release notes).

2. **Khepri/Mnesia claim misleading** — SKILL.md line 358 says "Khepri replaces Mnesia as the metadata store" in 4.0. In reality, Khepri is available in 4.0 but Mnesia remains the default; Khepri is planned to become default in 4.2. Should say "Khepri is available as an alternative to Mnesia."

3. **Node.js amqplib consume example incorrect** — SKILL.md line 288: `ch.consume('tasks', ..., { prefetch: 10 })` passes `prefetch` as an option to `consume()`, but amqplib does not accept `prefetch` there. Prefetch must be set separately via `ch.prefetch(10)` before calling `ch.consume()`.

4. **6 orphaned files not linked from SKILL.md**:
   - `references/clustering-guide.md`
   - `scripts/purge-queues.sh`
   - `scripts/setup-rabbitmq-cluster.sh`
   - `scripts/rabbitmq-health-check.sh`
   - `assets/node-producer-consumer.js`
   - `assets/python-producer-consumer.py`

   These are high-quality files that would increase value if linked.

5. **Minor: missing 4.0-specific gotchas** — No mention of AMQP 1.0 becoming a core protocol in 4.0, feature flags required after upgrade, or quorum queue limitations (no exclusive/auto-delete).

## Detailed Assessment

### Structure (Pass)
- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive triggers (11 use cases) AND negative triggers (6 exclusions)
- ✅ Body is 456 lines (under 500 limit)
- ✅ Imperative voice throughout, no filler
- ✅ Examples with code in Python, Node.js, Go, Java, bash
- ⚠️ references/, scripts/, assets/ partially linked — 6 files orphaned

### Content (Strong)
- Core concepts, exchange types, message patterns, reliability — all accurate
- Docker setup, clustering, monitoring, security — comprehensive
- Client library examples in 4 languages — practical and mostly correct
- Troubleshooting section covers top real-world pitfalls
- Reference docs (troubleshooting, API reference, advanced patterns) are thorough
- Scripts are production-quality with error handling and configurability
- Web-verified: consumer_timeout 30min default ✅, mirrored queues removed in 4.0 ✅, stream filtering 3.13+ ✅

### Trigger (Excellent)
- Would trigger correctly for: RabbitMQ setup, AMQP patterns, work queues, pub/sub, DLX, quorum queues, clustering, monitoring
- Would NOT falsely trigger for: Kafka, Redis pub/sub, SQS/SNS, WebSocket, in-process queues
- Well-scoped with both positive and negative criteria

### Verdict
**PASS** — Skill is production-quality with minor factual errors. No dimension ≤ 2, overall ≥ 4.0. No GitHub issues required.
