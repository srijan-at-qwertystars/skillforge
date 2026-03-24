# Review: opentelemetry-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **Loki exporter deprecated (Accuracy, Actionability)** — SKILL.md line 258 and `assets/otel-collector-config.template.yaml` use the `loki` exporter (`lokiexporter`), which was deprecated and removed from the OTel Collector contrib distribution as of late 2024. Loki 3.0+ supports native OTLP ingestion; the correct approach is to use `otlphttp` exporter pointing at `http://loki:3100/otlp`. Configs using the old exporter will fail on current Collector builds. The `docker-compose.template.yml` env var `OTEL_BACKEND_LOGS_ENDPOINT` also references the deprecated `/loki/api/v1/push` path.

2. **Go semconv version slightly dated** — The Go SDK example references `semconv/v1.26.0`. While valid, the latest semconv version is v1.40.0+. A comment noting users should check for the latest version would help.

3. **TypeScript template SensitiveDataRedactor is a no-op** — `tracing-setup.template.ts` defines a `SensitiveDataRedactor` span processor whose `onEnd` method contains an empty if-block with a comment. While the comment explains the limitation (attributes are read-only on `ReadableSpan`), an AI following this template would deploy a non-functional redactor, creating a false sense of security. Should either implement actual redaction via the `onStart` hook or remove the class and document Collector-side redaction only.

4. **Minor: `OTEL_LOG_LEVEL` portability** — The troubleshooting section references `OTEL_LOG_LEVEL=debug` as a universal env var, but this is not standardized across all SDKs (Node.js uses `diag.setLogger()` programmatically; Python uses `logging` module). The skill does show the programmatic approach too, so this is minor.

## Structure Assessment

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive triggers (USE when) AND negative triggers (DO NOT USE when)
- ✅ Body is 429 lines (under 500 limit)
- ✅ Imperative voice, no filler — extremely dense and direct
- ✅ Examples with input/output across 4 languages
- ✅ references/ (3 files) and scripts/ (2 files) properly linked from SKILL.md
- ✅ assets/ (3 templates) documented with usage instructions

## Content Assessment

- SDK setup examples for Node.js, Python, Go, Java are accurate against current APIs
- `ATTR_SERVICE_NAME` from `@opentelemetry/semantic-conventions` confirmed correct for JS SDK 2.x
- Python `SERVICE_NAME` import from `opentelemetry.sdk.resources` still valid
- Collector `tail_sampling` processor YAML syntax matches official docs
- Semantic conventions (HTTP, DB, RPC, Messaging) use current stable attribute names
- Sampling strategies table is practical and accurate
- Performance rules are reasonable (BatchSpanProcessor, head-sampling ranges, Collector sizing)
- Troubleshooting reference is excellent — decision trees, step-by-step diagnosis, common fixes
- Collector reference is comprehensive — all major component categories covered
- Scripts are well-structured with proper argument parsing and error handling

## Trigger Assessment

- Positive triggers cover 20+ specific OTel use cases — very thorough
- Negative triggers correctly exclude vendor-specific agents (Datadog, NewRelic, AppDynamics, Dynatrace), Prometheus-only, StatsD/Graphite
- Low false-positive risk — highly specific to OpenTelemetry ecosystem
- Would reliably trigger for real observability/OTel queries
