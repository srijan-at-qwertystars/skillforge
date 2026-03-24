# QA Review: prometheus-monitoring

**Skill path:** `~/skillforge/observability/prometheus-monitoring/`
**Reviewed:** 2026-03-24
**Reviewer:** Copilot QA

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `prometheus-monitoring` |
| YAML frontmatter `description` | ✅ | Present, multi-line |
| Positive triggers | ✅ | Lists PromQL, prometheus.yml, alertmanager.yml, client libraries, etc. |
| Negative triggers | ✅ | Excludes Datadog, New Relic, CloudWatch, Splunk, vendor APM, general logging, Grafana-only |
| Body under 500 lines | ✅ | 496 lines (tight but passing) |
| Imperative voice, no filler | ✅ | Direct and concise throughout |
| Examples with input/output | ✅ | PromQL examples, YAML configs, Go/Python/Node.js instrumentation |
| `references/` linked | ✅ | 3 files referenced: promql-cookbook.md, troubleshooting.md, alerting-patterns.md |
| `scripts/` linked | ✅ | 3 scripts referenced: setup-prometheus-stack.sh, check-cardinality.sh, validate-rules.sh |
| `assets/` linked | ✅ | 5 asset files referenced with descriptions |

## B. Content Check — Accuracy Issues

### Issue 1 (ERROR): `rate()` vs `irate()` guidance is inverted

**Line 181:**
> Set range ≥ 4× scrape interval for `rate()`. Use `rate()` for dashboards, `irate()` for volatile alerting.

The second sentence is **wrong**. Per Prometheus best practices and community consensus:
- `rate()` → use for **both** dashboards **and** alerting (stable, smoothed)
- `irate()` → use for **volatile dashboards** needing spike visibility; **avoid for alerting** (causes flapping due to sensitivity to last two samples)

Recommended fix:
> Use `rate()` for dashboards and alerting. Use `irate()` only when instantaneous spike visibility matters (e.g., high-resolution dashboards). Avoid `irate()` in alert expressions — it causes flapping.

### Issue 2 (ERROR): Kubernetes relabel_configs replacement pattern is broken

**Lines 397–406:**
```yaml
relabel_configs:
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
    action: replace
    target_label: __address__
    regex: (.+)
    replacement: ${1}:$1
```

This is **incorrect**. The replacement `${1}:$1` references only the port, losing the host entirely. The correct pattern requires **two source labels** and a semicolon-separated regex:

```yaml
- source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
  action: replace
  regex: ([^:]+)(?::\d+)?;(\d+)
  replacement: $1:$2
  target_label: __address__
```

An SRE copying this config would get broken pod scraping.

### Issue 3 (WARNING): Alertmanager uses deprecated `match`/`source_match` syntax

**Lines 300–306 and 326–330** use `match:` and `source_match:`/`target_match:` which are deprecated since Alertmanager 0.22+. The current recommended syntax uses `matchers:`, `source_matchers:`, and `target_matchers:` with string-based matcher lists.

Deprecated:
```yaml
match:
  severity: critical
```
Current:
```yaml
matchers:
  - severity = critical
```

### Items verified as correct

- ✅ `predict_linear(node_filesystem_avail_bytes[1h], 4 * 3600) < 0` — correct syntax and semantics
- ✅ `histogram_quantile` usage — correct `by (le)` grouping
- ✅ Counter/Gauge/Histogram/Summary descriptions — accurate
- ✅ Recording rule naming convention `level:metric:operations` — correct
- ✅ `rate()` range ≥ 4× scrape interval advice — correct
- ✅ Naming conventions (`_total`, `_seconds`, `_bytes`) — correct
- ✅ Federation config with `honor_labels` — correct
- ✅ Remote write/read config structure — correct
- ✅ Apdex score formula — correct
- ✅ Instrumentation code (Go, Python, Node.js) — all runnable

### Missing gotchas an SRE would hit

1. **No mention of `absent()` in main body** — critical for detecting disappeared metrics. Covered in `references/promql-cookbook.md` but deserves at least a one-liner in the main PromQL section.
2. **No staleness timeout mention** — Prometheus marks series stale after 5 minutes with no scrape. This trips up many users with intermittent targets.
3. **No `promtool test rules` mention** — the skill mentions `promtool check rules` and `promtool check config` but not unit testing alerting rules with `promtool test rules`, which is essential for CI pipelines.
4. **No native histograms** — newer Prometheus (2.40+) supports native histograms. Not critical but worth a brief mention for forward-compatibility.

## C. Trigger Check

| Question | Assessment |
|----------|------------|
| Triggers for Prometheus queries? | ✅ Yes — description lists PromQL, prometheus.yml, alertmanager.yml, scrape targets, client libraries |
| False trigger for Datadog? | ✅ No — explicitly excluded |
| False trigger for CloudWatch? | ✅ No — explicitly excluded |
| False trigger for general monitoring? | ✅ No — scoped to Prometheus context, excludes general logging |
| False trigger for Grafana-only work? | ✅ No — explicitly excluded Grafana-only dashboard design |

The description is well-crafted with specific positive and negative triggers. No false-trigger risk identified.

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 | Two factual errors: inverted rate/irate guidance (line 181) and broken K8s relabel_configs (lines 397–406). Deprecated Alertmanager syntax is a minor concern. |
| **Completeness** | 4 | Excellent breadth: architecture, metric types, instrumentation (3 languages), PromQL, recording/alerting rules, Alertmanager, service discovery, storage, federation, Grafana. References (2,936 lines) provide deep coverage. Minor gaps: absent(), staleness, promtool test rules. |
| **Actionability** | 4 | Most examples are copy-paste ready and correct. Go/Python/Node.js instrumentation is runnable. K8s relabel_configs would break in production. Scripts and assets add significant practical value. |
| **Trigger quality** | 5 | Precise positive triggers covering all Prometheus contexts. Clear negative triggers for vendor tools, logging, and Grafana-only work. No false-trigger risk. |

**Overall: 4.0** (average)

## E. Verdict

**`needs-fix`** — Two errors must be corrected before the skill is production-ready:

1. Fix rate/irate guidance (line 181) — misleading advice causes alert flapping
2. Fix Kubernetes relabel_configs (lines 397–406) — broken replacement pattern
3. (Recommended) Update Alertmanager config to use `matchers:` syntax
4. (Recommended) Add one-liner for `absent()` in PromQL section

## F. GitHub Issues

No GitHub issues filed — overall score is 4.0 (not < 4.0) and no dimension ≤ 2.
