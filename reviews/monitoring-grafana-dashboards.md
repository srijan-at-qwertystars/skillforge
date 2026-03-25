# QA Review: grafana-dashboards

**Skill path:** `~/skillforge/monitoring/grafana-dashboards/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter — `name` | ✅ | `grafana-dashboards` |
| YAML frontmatter — `description` | ✅ | Comprehensive, multi-sentence description present |
| Positive triggers | ✅ | Covers: building dashboards, configuring panels, PromQL/LogQL, variables/templating, annotations, alert rules, provisioning, Grafonnet, Terraform, folders/permissions |
| Negative triggers | ✅ | Excludes: Prometheus-only, Datadog, New Relic, Kibana/OpenSearch, standalone Alertmanager |
| Body line count (≤500) | ✅ | 494 lines — just under the limit |
| Imperative voice | ✅ | Uses imperatives throughout ("Set `id: null`", "Use `$__rate_interval`", "Avoid unbounded regex") |
| Examples | ✅ | Rich, copy-pasteable JSON/YAML/PromQL/LogQL/Jsonnet examples for every major concept |
| References linked | ✅ | All three reference docs (`api-reference.md`, `advanced-patterns.md`, `troubleshooting.md`) described and linked inline |
| Scripts linked | ✅ | Both scripts (`setup-grafana.sh`, `export-dashboards.sh`) described with flag details |
| Assets linked | ✅ | All three templates described in a summary table at the bottom |

### Reference files

| File | Lines | Assessment |
|------|-------|------------|
| `references/api-reference.md` | 900 | Thorough: dashboard JSON model, panel schema, target schema, templating, annotations, provisioning YAML, HTTP API (dashboard/folder/datasource/alerting/annotation/service-account endpoints), Grafonnet library. Complete and accurate. |
| `references/advanced-patterns.md` | 730 | Excellent depth: complex PromQL, multi-datasource, variable chaining, row/panel repeating, dynamic thresholds, value mappings, field overrides, link patterns, Scenes SDK, dashboard versioning, org strategies, transformations. |
| `references/troubleshooting.md` | 433 | Well-organized by symptom: slow dashboards, missing data, variable failures, provisioning errors, panel rendering, alerting, datasource connections, permissions, version migration (9→10→11→12), diagnostics. |

### Scripts

| Script | Assessment |
|--------|------------|
| `scripts/setup-grafana.sh` | Solid. Proper `set -euo pipefail`, argument parsing, health-check wait loop, provisioning directory creation, clear summary output. Supports `--port`, `--prometheus-url`, `--loki-url`, `--admin-password`, `--grafana-version`. |
| `scripts/export-dashboards.sh` | Good. Dependency check (curl, jq), supports token and basic auth, folder filtering, `--strip-ids` for VCS, error handling per-dashboard. Minor: exported/failed counters inside a pipe subshell won't be available in the summary — cosmetic issue only. |

### Assets

| Asset | Assessment |
|-------|------------|
| `assets/dashboard.template.json` | Production-quality: datasource variable, chained job/instance variables, stat row (uptime, request rate, error rate, p99, instances, memory), time series panels (traffic by status, latency percentiles), table (top endpoints), logs panel. All panels use `$__rate_interval`, `instant: true` on stats, correct `gridPos`. |
| `assets/provisioning.template.yml` | Complete: Prometheus + Loki datasources with exemplar/derived-field config, commented Tempo and PostgreSQL examples, dashboard provider with `foldersFromFilesStructure`. Good inline comments. |
| `assets/docker-compose.template.yml` | Full stack: Grafana + Prometheus + Loki + Promtail + Node Exporter + cAdvisor. Includes healthchecks, named volumes, supporting config templates in comments. |

---

## B. Content Check (verified via web search)

### API Endpoints
- ✅ Dashboard CRUD (`GET /api/dashboards/uid/:uid`, `POST /api/dashboards/db`, `DELETE /api/dashboards/uid/:uid`) — confirmed correct per Grafana docs.
- ✅ Folder endpoints (`/api/folders`, `/api/folders/:uid`) — correct.
- ✅ Datasource endpoints (`/api/datasources`, `/api/datasources/uid/:uid`) — correct.
- ✅ Alerting provisioning API (`/api/v1/provisioning/alert-rules`) — correct.
- ⚠️ **Minor gap**: The skill documents the legacy/classic API only. Grafana 12+ introduces a new versioned API path (`/apis/dashboard.grafana.app/v1beta1/...`). Currently experimental, so omission is acceptable but worth noting.

### Panel Types
- ✅ All major panel types covered: `timeseries`, `stat`, `gauge`, `table`, `barchart`, `heatmap`, `logs`, `geomap`.
- ⚠️ **Minor gap**: Missing coverage of `state timeline`, `status history`, `pie chart`, `histogram`, `bar gauge`, `canvas`, `node graph`, `traces`, `flame graph`. These are less common but exist. The api-reference lists them in the panel type enum which is sufficient.

### Provisioning Syntax
- ✅ `apiVersion: 1` confirmed correct (still the standard in 2024/2025).
- ✅ Dashboard provider YAML schema matches official docs exactly.
- ✅ Datasource provisioning schema correct (`access: proxy`, `jsonData`, `secureJsonData`).
- ✅ Alert rule, contact point, notification policy provisioning schemas match official Grafana provisioning docs.

### PromQL Patterns
- ✅ `$__rate_interval` recommendation is correct — Grafana docs confirm it auto-adjusts to at least 4× the scrape interval.
- ✅ `histogram_quantile` pattern with `sum(rate(...)) by (le)` is the canonical form.
- ✅ Error ratio pattern `sum(rate(5xx)) / sum(rate(total))` is correct.
- ✅ Advice to use `instant: true` for stat/gauge/table panels is accurate.

### Grafonnet
- ✅ Installation via `jb init && jb install github.com/grafana/grafonnet/gen/grafonnet-latest@main` matches official README.
- ✅ Import path and API surface confirmed correct.
- ⚠️ Grafonnet is marked "experimental" by Grafana Labs — skill does not mention this caveat.

### Grafana 12 Coverage
- ✅ Troubleshooting doc covers Grafana 11→12 migration with Schema v2, tabs, dynamic dashboards.
- ⚠️ Does not mention that Schema v2 migration is **one-way/irreversible** — a significant gotcha worth adding.

### Missing Gotchas
1. **`increase()` with `$__rate_interval`**: The skill recommends `$__rate_interval` generally, but doesn't warn that `increase()` can overcount when the rate interval is much larger than the step. This is a known pitfall.
2. **Schema v2 irreversibility**: Grafana 12 schema v2 dashboards cannot be reverted to v1 — not mentioned.
3. **Grafonnet experimental status**: Should be flagged so users proceed with caution in production.
4. **Native histograms**: Prometheus native histograms (experimental) are not covered at all; this is increasingly relevant.

### Examples Correctness
- ✅ All JSON examples validated structurally (proper nesting, correct field names).
- ✅ PromQL examples use correct syntax and patterns.
- ✅ LogQL examples (filter, parse, metric queries) are correct.
- ✅ Grafonnet Jsonnet example compiles structurally.
- ✅ Provisioning YAML examples are well-formed.

---

## C. Trigger Check

### Description Quality
The description is **strong and specific**. It lists 10 positive trigger scenarios (panels, queries, variables, annotations, alerts, provisioning, Grafonnet, Terraform, folders, permissions) and 5 negative exclusions (Prometheus-only, Datadog, New Relic, Kibana, standalone Alertmanager).

### False Positive Risk
- **Low risk**. Negative triggers are well-defined. The description correctly scopes to "Grafana involvement" which avoids firing for generic Prometheus configuration or other monitoring tools.
- Potential edge case: "configuring Prometheus server without Grafana involvement" could still trigger if the user mentions dashboards in passing — acceptable.

### False Negative Risk
- **Low risk**. Key phrases like "Grafana dashboard", "Grafana panel", "PromQL for Grafana", "Grafana alerting", "Grafonnet", "Grafana provisioning" are all covered.
- Could miss: "Grafana Scenes" or "dynamic dashboards" as trigger phrases — but these are niche enough that the body content handles them via reference docs.

### Trigger Pushiness
- **Appropriate**. The description doesn't over-claim. It uses "Use when:" / "Do NOT use when:" structure clearly.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All API endpoints, panel types, provisioning schemas, PromQL/LogQL patterns, and Grafonnet usage verified correct against current Grafana documentation. No factual errors found. |
| **Completeness** | 4 | Excellent coverage of core Grafana dashboard workflows. Minor gaps: no `increase()` + `$__rate_interval` caveat, no Schema v2 irreversibility warning, no Grafonnet experimental note, missing some niche panel types (state timeline, canvas, etc.). Reference docs fill most gaps. |
| **Actionability** | 5 | Every section provides copy-pasteable examples. Templates are production-quality. Scripts are immediately usable. Best practices section is concrete and opinionated. |
| **Trigger Quality** | 5 | Clear positive/negative triggers, specific enough to avoid false positives, broad enough to catch relevant queries. Well-structured "Use when" / "Do NOT use when" format. |
| **Overall** | **4.75** | |

---

## E. Issue Filing

**No GitHub issues required.** Overall score (4.75) ≥ 4.0 and no dimension ≤ 2.

### Recommended Improvements (non-blocking)

1. Add a warning about `increase()` overcounting when used with `$__rate_interval` in the PromQL section.
2. Add a note in the troubleshooting migration section that Grafana 12 Schema v2 migration is **irreversible** (one-way).
3. Note Grafonnet's experimental status in the Grafonnet section.
4. Consider briefly mentioning Prometheus native histograms in the PromQL patterns section.
5. The `export-dashboards.sh` counter variables (`EXPORTED`/`FAILED`) are modified inside a pipe subshell and won't reflect in the summary — minor cosmetic bug.

---

## F. Test Status

**PASS** ✅

The skill is accurate, comprehensive, actionable, and well-triggered. All reference documents, scripts, and asset templates are high quality. Minor improvements noted but none are blocking.
