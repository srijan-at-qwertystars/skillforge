# QA Review: grafana-dashboards

**Skill path:** `~/skillforge/observability/grafana-dashboards/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-22

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter present | ✅ Pass | Has `name` and `description` fields |
| Positive triggers in description | ✅ Pass | 8 USE-WHEN clauses covering dashboards, panels, queries, data sources, alerting, provisioning, LGTM stack, variables/transformations |
| Negative triggers in description | ✅ Pass | 5 DO-NOT-USE clauses: OTel SDK instrumentation, standalone Prometheus rules, standalone Loki/Tempo/Mimir, non-Grafana UIs (Datadog, New Relic, Kibana), unrelated K8s/Helm |
| Body under 500 lines | ✅ Pass | 496 lines (just under limit — tight) |
| Imperative voice | ✅ Pass | "Use `$__rate_interval`", "Set `graphTooltip`", "Limit ≤20 panels" |
| Examples with input/output | ✅ Pass | 3 examples with clear "Input:" prompts and full JSON/YAML output |
| References linked from SKILL.md | ✅ Pass | Table links `references/advanced-patterns.md`, `references/troubleshooting.md`, `references/promql-logql-guide.md` |
| Scripts linked from SKILL.md | ✅ Pass | Table links all 3 scripts with usage examples |
| Assets linked from SKILL.md | ✅ Pass | Table describes all 5 asset files |

**Structure verdict:** All structural criteria met.

---

## B. Content Check — Fact Verification (Grafana 11.x)

### Panel Types
- **Verified ✅**: All 14 listed panel `type` values (`timeseries`, `stat`, `gauge`, `barchart`, `table`, `logs`, `traces`, `heatmap`, `geomap`, `canvas`, `piechart`, `histogram`, `text`, `nodeGraph`) are valid in Grafana 11.x.
- **Minor gap**: Missing several GA panel types: `bargauge`, `state-timeline`, `status-history`, `flamegraph`, `xychart`, `candlestick`, `datagrid`, `dashlist`, `alertlist`, `annolist`, `news`. These are less commonly used but `bargauge` and `state-timeline` are popular enough to warrant mention.

### Alerting Syntax
- **Verified ✅**: Unified alerting provisioning YAML with `apiVersion: 1`, `groups`, `rules`, `condition`, `data`, `for`, `labels`, `annotations` — all confirmed correct for Grafana 11.x.
- **Verified ✅**: Contact point types, notification policies with `matchers`, `group_by`, `mute_time_intervals` — correct.
- **Minor note**: The SKILL.md alert YAML example uses `conditions` nested under `model` for `datasourceUid: __expr__` — this is correct for the `math` expression type. The `alert-rule-template.json` asset uses the more modern `threshold` type with proper `evaluator`/`reducer` — both are valid.

### Provisioning Format
- **Verified ✅**: Data source provisioning YAML (`apiVersion: 1`, `datasources` array with `type`, `access`, `url`, `jsonData`) is correct.
- **Verified ✅**: Dashboard provisioning with `providers` array, `type: file`, `foldersFromFilesStructure` — correct.

### PromQL/LogQL Syntax
- **Verified ✅**: `$__rate_interval` recommendation is current best practice (confirmed by Grafana docs and community consensus).
- **Verified ✅**: PromQL examples (`rate()`, `histogram_quantile()`, `sum by`) are syntactically correct.
- **Verified ✅**: LogQL pipeline syntax (`|=`, `| json`, `| pattern`, `| line_format`) is correct.
- **Verified ✅**: TraceQL syntax for Tempo is correct.
- **Verified ✅**: SQL macros (`$__timeFilter`, `$__timeGroup`, etc.) are correct.

### Subfolders
- **Verified ✅**: "subfolders GA in 11.x" is confirmed — nested folders reached GA with Grafana 11.0 (Feb 2024).

### LGTM Stack
- **Verified ✅**: Component list, default ports, and signal mapping are accurate.
- **Minor issue**: Lists "Alloy" as the collection/routing component, which is correct for Grafana 11.x (Alloy replaced Grafana Agent in April 2024). However, the skill doesn't mention this is a recent replacement or provide Alloy-specific configuration guidance.

### Missing Gotchas
1. **Native histograms**: Grafana 11 supports Prometheus native histograms — not mentioned.
2. **Correlations feature**: Grafana 11 introduced cross-data-source correlations as GA — only briefly mentioned in the description's `advanced-patterns.md` reference, not in the main body.
3. **Service accounts vs API keys**: Correctly recommends service accounts, but should note API keys are deprecated since Grafana 10.x.
4. **Scenes API**: Referenced in `advanced-patterns.md` but could benefit from a brief mention in the main body as it's the future of dashboard development.

### Examples Correctness
- **HTTP Service Health dashboard** ✅: Valid JSON model, correct PromQL, proper use of `$__rate_interval`, appropriate panel types.
- **Loki error log panel** ✅: Correct LogQL with pipeline, valid `logs` panel options.
- **High memory alert** ✅: Valid alert rule YAML, correct PromQL expression for memory percentage.

---

## C. Trigger Check

### True Positive Triggers (should activate)

| User Request | Would Trigger? | Confidence |
|-------------|---------------|------------|
| "Create a Grafana dashboard for my API" | ✅ Yes | High |
| "Write a PromQL query for Grafana" | ✅ Yes | High |
| "Set up Grafana alerting rules" | ✅ Yes | High |
| "Configure Prometheus data source in Grafana" | ✅ Yes | High |
| "Build a Grafana dashboard with Terraform" | ✅ Yes | High |
| "Write LogQL for Loki in Grafana" | ✅ Yes | High |
| "Set up LGTM observability stack" | ✅ Yes | High |
| "Provision Grafana dashboards as code" | ✅ Yes | High |

### False Positive Check (should NOT activate)

| User Request | Would Trigger? | Correct? |
|-------------|---------------|----------|
| "Set up Datadog dashboard" | ❌ No | ✅ Correct — explicitly excluded |
| "Create New Relic alert" | ❌ No | ✅ Correct — explicitly excluded |
| "Configure Kibana visualizations" | ❌ No | ✅ Correct — explicitly excluded |
| "Instrument Python app with OpenTelemetry SDK" | ❌ No | ✅ Correct — explicitly excluded |
| "Write Prometheus recording rules" | ⚠️ Edge case | Acceptable — excluded when "without Grafana context" |
| "Deploy Loki in Kubernetes" | ⚠️ Edge case | Acceptable — excluded when "without Grafana dashboards" |

### Trigger Quality Assessment
The positive/negative trigger descriptions are **well-crafted**. The negative triggers are specific enough to avoid false positives for competing monitoring tools and related-but-different tasks. The edge cases (Prometheus rules, Loki deployment) have reasonable scoping language.

---

## D. Scoring

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 5 | All technical claims verified correct. Panel types, query syntax, alerting format, provisioning YAML, and architecture details are accurate for Grafana 11.x. |
| **Completeness** | 4 | Excellent coverage of core topics. Minor gaps: missing `bargauge`/`state-timeline` panel types, no native histogram mention, no Alloy migration context, API key deprecation not flagged. Reference files add substantial depth. |
| **Actionability** | 5 | Three full worked examples with input/output. Production-ready templates in assets. Executable scripts for common workflows. Clear performance guidelines and pitfalls section. |
| **Trigger Quality** | 5 | Positive triggers cover all primary use cases. Negative triggers correctly exclude Datadog, New Relic, Kibana, standalone Prometheus/Loki, and OTel instrumentation. No false-trigger risk identified. |

### Overall Score: **4.75** (average of 5 + 4 + 5 + 5)

---

## E. Issues

No GitHub issues required — overall score (4.75) ≥ 4.0 and no dimension ≤ 2.

### Recommended Improvements (non-blocking)

1. **Add `bargauge` and `state-timeline`** to the panel types table — both are commonly used.
2. **Note API key deprecation** in the Authentication section — service accounts are not just "preferred," API keys are deprecated.
3. **Add brief Alloy context** in the LGTM Stack section — note it replaced Grafana Agent in 2024.
4. **Mention native histograms** support in PromQL section — relevant for Grafana 11.x + Prometheus 2.50+.
5. **Line count at 496/500** — very tight. Consider moving the "Additional Resources" linking tables to a separate index file if content grows.

---

## F. Test Status

**Result: PASS ✅**

The skill is accurate, comprehensive, well-structured, and has precise trigger descriptions. Minor gaps are non-blocking and relate to completeness of panel type coverage and recently-changed component names.

---

*Review generated by Copilot CLI automated QA process.*
