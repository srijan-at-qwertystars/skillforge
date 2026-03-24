# Review: grafana-dashboards

Accuracy: 5/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Minor — No mention of Grafana v12 Schema v2 (experimental).** Grafana v12 introduces a new JSON schema with `TabsLayout`, `AutoGridLayout`, and `elements`-based structure. While experimental, a brief note in the advanced-patterns reference would future-proof the skill.
2. **Minor — Alerting timeline slightly imprecise.** SKILL.md says "replaces legacy alerting since Grafana 9+" which is broadly correct (unified alerting became default in v9), but legacy alerting was only fully removed in Grafana 11 (May 2024). A clarifying note would help users on v9/v10 who may still have legacy alerts.
3. **Minor — PromQL scope overlap.** Description says "Do NOT use for Prometheus query writing (use prometheus-monitoring skill)" yet includes `references/promql-logql-guide.md` with deep PromQL coverage. This is pragmatic (PromQL-in-Grafana context) but could confuse trigger routing. Consider noting "PromQL as used within Grafana panel queries" in the description.

## Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name` + `description` present |
| Positive triggers | ✅ Pass | Dashboards, panels, visualizations, provisioning, data sources, templating, alerting, Grafonnet, Terraform, RBAC, plugins |
| Negative triggers | ✅ Pass | Excludes Prometheus query writing, Kibana, Datadog, general monitoring without Grafana |
| Body length | ✅ Pass | 499 lines (under 500 limit) |
| Imperative voice | ✅ Pass | "Choose the right visualization", "Set uid explicitly", "Define variables" |
| Examples | ✅ Pass | Multiple JSON, HCL, Jsonnet, YAML, bash code blocks with full context |
| References linked | ✅ Pass | 4 reference docs in table with descriptions |
| Scripts linked | ✅ Pass | 6 scripts in table with purpose and key flags |
| Assets linked | ✅ Pass | docker-compose, provisioning configs, dashboard templates, alert rule template |

## Content Verification (web-searched)

| Claim | Verdict |
|-------|---------|
| `graphTooltip` 1=shared crosshair, 2=shared tooltip | ✅ Correct |
| `gridPos` max width = 24 columns | ✅ Correct |
| `schemaVersion: 39` valid for current Grafana | ✅ Correct (37-42 typical for v9-v11) |
| Unified alerting replaces legacy since Grafana 9+ | ✅ Correct (default in v9, removed in v11) |
| Variable `refresh: 2` = on time range change | ✅ Correct |
| `npx @grafana/create-plugin@latest` for plugin scaffolding | ✅ Correct |
| Panel types (timeseries, stat, gauge, heatmap, histogram, etc.) | ✅ All valid |
| Terraform `grafana_dashboard` / `grafana_folder` resources | ✅ Correct |
| Grafonnet import path | ✅ Correct |
| Dashboard API: `POST /api/dashboards/db` | ✅ Correct |

## Trigger Analysis

**Would trigger for:** "create a Grafana dashboard", "set up Grafana alerts", "provision Grafana data sources", "Grafonnet dashboard-as-code", "Grafana panel configuration", "dashboard JSON model"

**Would NOT trigger for:** "write Prometheus recording rules", "set up Datadog monitoring", "create Kibana dashboard" — correctly excluded

**No false trigger risk identified.**

## Asset Quality

- `golden-signals-dashboard.json`: Production-ready, proper `$__rate_interval`, templated datasource, all 4 golden signals
- `dashboard-template.json`: Comprehensive with chained variables, namespace→job→instance, logs panel, collapsed rows
- `alert-rule-template.json`: Complete unified alerting with math expressions, Slack + PagerDuty contact points, notification policies
- `docker-compose.yml`: Proper health checks, named volumes, network isolation, depends_on conditions
- Scripts: All use `set -euo pipefail`, have usage docs, proper argument parsing

## Recommended Improvements (non-blocking)

1. Add `bar gauge` and `state-timeline` to panel types table
2. Note API keys are deprecated since Grafana 10.x (service accounts are the replacement)
3. Add brief mention of Grafana v12 Schema v2 in advanced-patterns reference
4. Clarify alerting timeline: default in v9, removed in v11

## Result: PASS ✅

No GitHub issues filed — overall 4.8/5, no dimension ≤ 2.
