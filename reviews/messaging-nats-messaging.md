# Review: nats-messaging

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **Wrong Prometheus exporter name (Accuracy):** Line 361 says `nats-server-exporter` — the correct official name is `prometheus-nats-exporter` (repo: `nats-io/prometheus-nats-exporter`, Docker image: `natsio/prometheus-nats-exporter`).

2. **Node.js example uses legacy `nats` package API (Accuracy, minor):** The example imports from `"nats"` and uses `nc.jetstream()` / `nc.jetstreamManager()`. The current modular API (v3+) uses `@nats-io/jetstream` with `jetstream(nc)` / `jetstreamManager(nc)`. The v2 pattern still works but is not the recommended path for new projects.

3. **Missing `max_ack_pending` guidance (Completeness):** No mention of `max_ack_pending` on consumers, which is critical for flow control. Default is 1000; hitting this limit silently stalls delivery — a common gotcha.

4. **Missing slow consumer handling (Completeness):** No guidance on slow consumer advisories (`$SYS.SERVER.*.CLIENT.SLOW_CONSUMER`), pending message limits, or mitigation strategies (increase buffer, use pull consumers, add queue groups).

5. **Missing message headers (Completeness):** NATS supports message headers (since v2.2) for metadata, tracing, and routing. Not mentioned anywhere in the skill.

## Structure Check
- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive AND negative triggers
- ✅ Body is 463 lines (under 500 limit)
- ✅ Imperative voice, no filler
- ✅ Examples with runnable commands and code
- ✅ `references/`, `scripts/`, `assets/` properly linked with tables

## Content Check
- ✅ Core concepts (subjects, wildcards, pub/sub, request/reply, queue groups) are accurate
- ✅ JetStream defaults verified: dedup window 2min, max_payload 1MB
- ✅ Throughput claim (8M+ msgs/sec) supported by official benchmarks
- ✅ Go client uses correct new `jetstream` package API
- ✅ Python client uses correct `js.pull_subscribe` API
- ✅ CLI commands verified against NATS docs
- ✅ Production checklist is solid and actionable
- ⚠️ Prometheus exporter name incorrect
- ⚠️ Node.js imports outdated (functional but not current best practice)

## Trigger Check
- ✅ Positive triggers cover pub/sub, request/reply, JetStream, KV, object store, queue groups, clustering, security, K8s
- ✅ Negative triggers explicitly exclude Kafka, RabbitMQ, AMQP, MQTT, STOMP, Redis Streams
- ✅ No false trigger risk for adjacent messaging technologies
