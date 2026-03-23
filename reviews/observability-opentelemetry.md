# QA Review: observability/opentelemetry

**Reviewer:** Copilot CLI QA  
**Date:** 2025-07-17  
**Skill path:** `~/skillforge/observability/opentelemetry/`

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter has `name` | ✅ | `name: opentelemetry` |
| YAML frontmatter has `description` | ✅ | Multi-line description present |
| Positive triggers (USE when) | ✅ | Covers imports, keywords: distributed tracing, spans, OTLP, Collector, auto-instrumentation, sampling, exporters, etc. |
| Negative triggers (DO NOT USE when) | ✅ | Excludes logging-only frameworks, vendor-specific SDKs (dd-trace, New Relic agent), browser RUM |
| Body under 500 lines | ✅ | 488 lines |
| Imperative voice, no filler | ✅ | Direct, terse, no hedging language |
| Examples with input/output | ✅ | Two worked examples: "Add tracing to Express app" and "Set up tail sampling" |
| references/ linked from SKILL.md | ✅ | Table with 3 reference files, all hyperlinked |
| scripts/ linked from SKILL.md | ✅ | Table with 3 scripts, all hyperlinked with usage |
| assets/ linked from SKILL.md | ✅ | Table with 4 asset files, all hyperlinked |

**Structure verdict:** All checks pass.

---

## b. Content Check — Web-Verified Technical Accuracy

### OTel SDK APIs
- ✅ `NodeSDK` from `@opentelemetry/sdk-node` — confirmed correct
- ✅ `TracerProvider` from `@opentelemetry/sdk-trace` — correct
- ✅ `PeriodicExportingMetricReader` from `@opentelemetry/sdk-metrics` — correct
- ✅ `ATTR_SERVICE_NAME` from `@opentelemetry/semantic-conventions` — correct (current stable API)
- ✅ `getNodeAutoInstrumentations` from `@opentelemetry/auto-instrumentations-node` — correct
- ✅ Python: `TracerProvider`, `BatchSpanProcessor`, `OTLPSpanExporter` — all correct module paths
- ✅ Go: `go.opentelemetry.io/otel`, `sdktrace.NewTracerProvider`, `otlptracehttp.New` — correct
- ⚠️ Go semconv `v1.26.0` is valid but dated; latest is v1.34.0+. Functional since Go uses versioned import paths.

### Collector Configuration
- ✅ receivers/processors/exporters/service/pipelines structure — correct per spec
- ✅ `memory_limiter` config: `check_interval`, `limit_mib`, `spike_limit_mib` — correct params
- ✅ `batch` processor: `send_batch_size`, `timeout`, `send_batch_max_size` — correct
- ✅ `tail_sampling`: `decision_wait`, `num_traces`, `policies` — correct structure
- ✅ `groupbytrace` before `tail_sampling` guidance — correct and important
- ✅ Pipeline ordering: memory_limiter first, batch last — matches best practices

### Environment Variables
- ✅ `OTEL_SERVICE_NAME` — correct per spec
- ✅ `OTEL_EXPORTER_OTLP_ENDPOINT` — correct
- ✅ `OTEL_EXPORTER_OTLP_PROTOCOL` — correct values: `grpc`, `http/protobuf`
- ✅ `OTEL_TRACES_SAMPLER` — correct values: `always_on`, `traceidratio`, `parentbased_traceidratio`
- ✅ `OTEL_TRACES_SAMPLER_ARG` — correct
- ✅ `OTEL_PROPAGATORS` — correct default: `tracecontext,baggage`
- ✅ Per-signal endpoint overrides (`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`) — correct
- ✅ `OTEL_EXPORTER_OTLP_COMPRESSION=gzip` — correct
- ✅ BSP env vars (`OTEL_BSP_SCHEDULE_DELAY`, etc.) in otel-env.sh — correct per spec

### Package Names
- ✅ Node.js packages all verified on npm (sdk-node, api, auto-instrumentations-node, exporter-trace-otlp-http, exporter-metrics-otlp-http, sdk-metrics)
- ✅ Python: `opentelemetry-distro[otlp]`, `opentelemetry-bootstrap`, `opentelemetry-instrument` — all current
- ✅ Go: `go.opentelemetry.io/otel`, `go.opentelemetry.io/otel/sdk`, `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` — correct
- ✅ Java agent approach and `GlobalOpenTelemetry` API — correct

### Missing Gotchas Assessment
- ✅ 10 pitfalls covered comprehensively (missing span.end, context propagation, high cardinality, SDK in library, memory_limiter, sync exporters, service.name, init order, baggage leakage, graceful shutdown)
- ✅ Troubleshooting doc covers ESM vs CJS, context loss in async, gRPC vs HTTP
- ✅ Framework-specific issues table (Next.js, NestJS, FastAPI, Spring Boot) — excellent
- ⚠️ Minor: `OTEL_TRACES_EXPORTER=jaeger` in env var table — Jaeger exporter is deprecated; OTLP is now preferred. The backends table correctly notes "Jaeger natively accepts OTLP since v1.35" but the env var table could confuse users.
- ⚠️ Minor: No .NET/C# coverage (popular OTel language), no mention of OTel Operator for Kubernetes auto-injection.

---

## c. Trigger Check

| Query | Should Trigger? | Would Trigger? | Verdict |
|---|---|---|---|
| "add tracing" | Yes | ✅ Yes — matches "distributed tracing", "auto-instrumentation" | Pass |
| "OpenTelemetry setup" | Yes | ✅ Yes — matches import patterns `@opentelemetry/*` | Pass |
| "distributed tracing" | Yes | ✅ Yes — explicitly listed | Pass |
| "set up OTel Collector" | Yes | ✅ Yes — "OTel Collector" explicitly listed | Pass |
| "add spans to my Go service" | Yes | ✅ Yes — matches `go.opentelemetry.io/otel`, "spans" | Pass |
| "configure Datadog dd-trace" | No | ✅ No — explicitly excluded: "APM-vendor-specific SDKs (Datadog dd-trace)" | Pass |
| "New Relic agent setup" | No | ✅ No — explicitly excluded: "New Relic agent without OTel" | Pass |
| "set up winston logging" | No | ✅ No — excluded: "logging frameworks only without OTel integration" | Pass |
| "export traces to Honeycomb" | Yes | ✅ Yes — "exporter configuration for...Honeycomb" | Pass |
| "browser analytics/RUM" | No | ✅ No — explicitly excluded | Pass |

**Trigger verdict:** Excellent precision and recall. Positive triggers are comprehensive. Negative triggers properly exclude vendor-specific and logging-only queries.

---

## d. Scoring

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 5 | All SDK APIs, env vars, Collector options, package names verified correct against official docs. Go semconv version is valid (though not latest). No factual errors found. |
| **Completeness** | 4 | Covers 4 languages, all 3 signals, Collector architecture, deployment patterns, troubleshooting, and advanced patterns. Docked 1 for: no .NET coverage, Go semconv slightly dated, deprecated jaeger exporter value in env table, no OTel Operator mention. |
| **Actionability** | 5 | Copy-paste code for all languages, working scripts (local stack, Node instrumentation, config validation), production-ready asset templates, input/output examples, troubleshooting decision trees. An engineer can go from zero to instrumented in minutes. |
| **Trigger Quality** | 5 | Exhaustive positive triggers covering imports, concepts, and backend names. Clear negative triggers preventing false activation on vendor-specific or unrelated queries. |

**Overall: 4.75 / 5.0**

---

## e. Issue Filing

Overall ≥ 4.0 and no dimension ≤ 2. **No issues required.**

---

## f. SKILL.md Annotation

`<!-- tested: pass -->` appended to SKILL.md.

---

## Summary

This is an exceptionally well-crafted skill. The architecture is clean (SKILL.md as overview, references/ for depth, scripts/ for automation, assets/ for templates). Technical content is verified accurate. The trigger description is precise with proper positive/negative boundaries. Minor improvement opportunities:

1. Update Go semconv import to a more recent version (e.g., v1.34.0)
2. Remove or annotate `jaeger` as deprecated in the `OTEL_TRACES_EXPORTER` env var table
3. Consider adding .NET/C# coverage in a future iteration
4. Mention OTel Operator for Kubernetes auto-injection in deployment patterns
