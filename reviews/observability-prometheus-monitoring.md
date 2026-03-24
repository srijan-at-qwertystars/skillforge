# Review: prometheus-monitoring

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.8/5

Issues:

- **Minor: Unlisted script.** `scripts/setup-prometheus-stack.sh` exists but is not documented in the SKILL.md Helper Scripts table. Only `setup-prometheus.sh` is listed. The two scripts overlap in functionality (both deploy Prometheus stacks via Docker Compose), which could confuse an AI choosing between them.
- **Minor: Trigger description could mention Prometheus Operator / ServiceMonitor / PodMonitor CRDs** as positive triggers, since these are common Kubernetes-era query topics covered extensively in `references/kubernetes-monitoring.md`.

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `prometheus-monitoring` |
| YAML frontmatter `description` | ✅ | Multi-line with clear scope |
| Positive triggers | ✅ | PromQL, alerting rules, scrape config, recording rules, service discovery, relabeling, histogram_quantile, Alertmanager routing |
| Negative triggers | ✅ | Datadog/New Relic/Splunk, log aggregation (ELK/Loki), distributed tracing (Jaeger/Tempo), Grafana-without-Prometheus |
| Body under 500 lines | ✅ | 416 lines |
| Imperative voice | ✅ | Direct throughout ("Use for:", "Default to histograms", "Always use rate", "Never use unbounded label values") |
| Examples with input/output | ✅ | PromQL queries, YAML configs, Go/Python/Java/Node.js instrumentation code |
| `references/` linked | ✅ | All 5 reference docs listed in table with topic descriptions |
| `scripts/` linked | ⚠️ | 4 of 5 scripts listed; `setup-prometheus-stack.sh` undocumented |
| `assets/` linked | ✅ | All 5 asset templates listed with descriptions |

## B. Content Check (web-verified)

All key technical claims verified against current Prometheus documentation and community sources:

- ✅ Metric types — counter (monotonically increasing), gauge (up/down), histogram (buckets, aggregatable), summary (client-side quantiles, NOT aggregatable)
- ✅ TSDB storage — 15-day default retention, 2-hour blocks, compaction into larger blocks
- ✅ rate() vs irate() — rate averages over window (use for alerting), irate uses last two points (volatile dashboards). "Always use rate in alert rules" — correct
- ✅ histogram_quantile — must rate() buckets first, must include `le` in `by` clause — correct
- ✅ Exporter ports — node:9100, blackbox:9115, mysqld:9104, postgres:9187, redis:9121 — all confirmed
- ✅ 14.4x burn rate = budget exhausted in ~2h for 99.9% SLO — confirmed per Google SRE Workbook
- ✅ Recording rule naming convention `level:metric:operations` — correct
- ✅ relabel_configs (before scrape) vs metric_relabel_configs (after scrape) — correct
- ✅ K8s relabel_configs for pod annotation-based discovery — correct two-source-label pattern with semicolon regex
- ✅ Alertmanager uses current `matchers:` / `source_matchers:` syntax in assets
- ✅ `absent()` covered in PromQL Fundamentals section
- ✅ Native histograms covered in `references/advanced-patterns.md`
- ✅ All instrumentation code (Go, Python, Java, Node.js) is syntactically correct and runnable
- ✅ Docker Compose, alerting rules, recording rules, and Alertmanager configs are production-quality
- ✅ Scripts have proper error handling, dependency checks, and usage documentation

No factual errors found. Previous review's issues (rate/irate inversion, broken K8s relabel, deprecated Alertmanager syntax) have all been fixed.

## C. Trigger Check

| Query | Triggers? | Correct? |
|-------|-----------|----------|
| "Write a PromQL query for error rate" | ✅ Yes | ✅ |
| "Set up Prometheus monitoring for K8s" | ✅ Yes | ✅ |
| "Configure Alertmanager routing" | ✅ Yes | ✅ |
| "Instrument Go app with Prometheus metrics" | ✅ Yes | ✅ |
| "histogram_quantile help" | ✅ Yes | ✅ |
| "Set up Datadog monitoring" | ❌ No | ✅ (correctly excluded) |
| "ELK stack for log aggregation" | ❌ No | ✅ (correctly excluded) |
| "Set up Jaeger tracing" | ❌ No | ✅ (correctly excluded) |
| "Create a ServiceMonitor CRD" | ⚠️ Maybe | Could be stronger — not in trigger description but covered in references |

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All claims verified correct. No factual errors. All previous issues resolved. |
| **Completeness** | 5 | Exceptional breadth: architecture, 4 metric types, instrumentation in 4 languages, PromQL fundamentals+advanced, 6 service discovery methods, relabeling, recording/alerting rules, Alertmanager, storage+remote write, K8s monitoring, RED/USE/SLO patterns, exporters, best practices. 3,928 lines of reference docs, 1,741 lines of scripts, production asset templates. |
| **Actionability** | 5 | All examples are copy-paste ready. Production configs, runnable scripts with Docker/local modes, Helm chart guidance, CI-ready validation. An AI could execute any Prometheus task from this skill. |
| **Trigger quality** | 4 | Strong positive and negative triggers with low false-trigger risk. Deducted 1 point: missing Prometheus Operator/ServiceMonitor/PodMonitor in trigger keywords; undocumented overlapping script could cause confusion. |

**Overall: 4.8/5**

## E. Verdict

**`pass`** — Skill is production-ready. All previous issues have been resolved. Content is accurate, comprehensive, and highly actionable. Only minor documentation gaps remain (unlisted script, trigger keywords).

## F. GitHub Issues

No issues filed — overall 4.8 ≥ 4.0 and no dimension ≤ 2.
