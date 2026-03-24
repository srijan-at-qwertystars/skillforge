# Log Stack Comparison

> Side-by-side comparison of major log management stacks: ELK (Elasticsearch + Logstash + Kibana), PLG (Promtail + Loki + Grafana), Datadog, and Splunk. Covers architecture, cost, scaling, query capabilities, and decision framework.

## Table of Contents

- [Overview](#overview)
- [Architecture Deep-Dive](#architecture-deep-dive)
  - [ELK Stack](#elk-stack)
  - [PLG Stack](#plg-stack)
  - [Datadog](#datadog)
  - [Splunk](#splunk)
- [Feature Comparison Matrix](#feature-comparison-matrix)
- [Cost Model](#cost-model)
- [Scaling Characteristics](#scaling-characteristics)
- [Query Capabilities](#query-capabilities)
- [Operational Complexity](#operational-complexity)
- [Decision Framework](#decision-framework)

---

## Overview

| Aspect | ELK | PLG (Loki) | Datadog | Splunk |
|--------|-----|------------|---------|--------|
| **Type** | Open source | Open source | SaaS | Commercial (SaaS + on-prem) |
| **Indexing** | Full-text (inverted index) | Labels only (log body not indexed) | Proprietary full-text | Full-text (inverted index) |
| **Primary storage** | Local SSD/HDD | Object storage (S3/GCS) | Cloud (managed) | Proprietary indexers |
| **Best for** | Full-text search, compliance | K8s-native, cost-efficient | Quick setup, unified platform | Enterprise, security/SIEM |
| **License** | Elastic License 2.0 / SSPL | AGPL v3 | Proprietary | Proprietary |
| **Managed option** | Elastic Cloud, AWS OpenSearch | Grafana Cloud | Native SaaS | Splunk Cloud |

---

## Architecture Deep-Dive

### ELK Stack

```
┌──────────┐    ┌───────────┐    ┌───────────────┐    ┌────────┐
│  App Logs │───▶│ Filebeat  │───▶│   Logstash    │───▶│  Elastic│
│  (stdout/ │    │ (shipper) │    │ (transform)   │    │  search │
│   files)  │    └───────────┘    └───────────────┘    └────┬───┘
└──────────┘                                                │
                                                       ┌────▼───┐
                                                       │ Kibana │
                                                       │ (UI)   │
                                                       └────────┘
```

**Components:**
- **Filebeat** — Lightweight log shipper (Go binary, ~30 MB RAM). Reads files, sends to Logstash or Elasticsearch directly.
- **Logstash** — Pipeline processor (JVM-based, ~1 GB RAM). Parses, transforms, enriches, routes. Can be skipped for simple setups using Elasticsearch ingest pipelines.
- **Elasticsearch** — Distributed search engine. Full-text indexing via Apache Lucene. Stores data in shards across nodes. Provides aggregations, alerting.
- **Kibana** — Visualization UI. Dashboards, Discover (log search), Lens (visualization builder), alerting rules.

**Strengths:** Powerful full-text search, mature ecosystem, rich aggregations, index lifecycle management, security features (document-level access control).

**Weaknesses:** Resource-intensive (JVM heap), complex cluster management, storage costs scale with data volume, requires tuning at scale.

### PLG Stack

```
┌──────────┐    ┌───────────┐    ┌───────────┐    ┌─────────┐
│  App Logs │───▶│ Promtail  │───▶│   Loki    │───▶│ Grafana │
│  (stdout) │    │ (agent)   │    │ (storage) │    │  (UI)   │
└──────────┘    └───────────┘    └───────────┘    └─────────┘
                                       │
                                  ┌────▼────┐
                                  │ S3/GCS  │
                                  │ (chunks)│
                                  └─────────┘
```

**Components:**
- **Promtail** — Log collector agent (Go, ~50 MB RAM). Discovers targets via K8s API, scrapes container logs, adds labels. Alternatives: Fluent Bit, OTEL Collector, Grafana Alloy.
- **Loki** — Log aggregation system. Indexes only labels (like Prometheus), stores compressed log chunks in object storage. Dramatically lower storage cost vs. full-text indexing.
- **Grafana** — Visualization and alerting. Same UI for logs, metrics (Prometheus), and traces (Tempo). LogQL for querying.

**Strengths:** Very low cost (S3 storage), simple operations, native K8s integration, unified observability with Prometheus/Tempo, horizontal scaling.

**Weaknesses:** No full-text index — content searches scan chunks (slower for ad-hoc text searches), limited to label-based stream selection, fewer built-in analytics features.

### Datadog

```
┌──────────┐    ┌───────────┐    ┌──────────────────────┐
│  App Logs │───▶│ DD Agent  │───▶│  Datadog Cloud       │
│  (stdout) │    │ (host)    │    │  ┌─────────────────┐ │
└──────────┘    └───────────┘    │  │ Log Management  │ │
                                  │  │ APM             │ │
                                  │  │ Infrastructure  │ │
                                  │  │ Security (SIEM) │ │
                                  │  └─────────────────┘ │
                                  └──────────────────────┘
```

**Components:**
- **Datadog Agent** — Host-level agent collects logs, metrics, traces. Auto-discovers containers, K8s pods.
- **Datadog Cloud** — Fully managed. Ingests, indexes, stores, provides UI, alerting, dashboards, notebooks, monitors.
- **Log Pipelines** — In-cloud processors for parsing, enriching, routing logs.
- **Archives** — Route logs to S3/GCS/Azure Blob for long-term retention.

**Strengths:** Zero infrastructure to manage, instant setup, best-in-class correlation between logs/APM/infra, Watchdog (ML anomaly detection), 600+ integrations, Flex Logs for cost optimization.

**Weaknesses:** Vendor lock-in, costs grow rapidly at scale, data leaves your network, limited on-prem option.

### Splunk

```
┌──────────┐    ┌──────────────┐    ┌─────────────┐    ┌─────────────┐
│  App Logs │───▶│ Universal    │───▶│  Indexers   │───▶│ Search Heads│
│  (syslog/ │    │ Forwarder   │    │ (index +    │    │ (query +    │
│   files)  │    │ (agent)     │    │  store)     │    │  UI)        │
└──────────┘    └──────────────┘    └─────────────┘    └─────────────┘
                                          │
                                    ┌─────▼─────┐
                                    │ SmartStore│
                                    │ (S3/GCS) │
                                    └───────────┘
```

**Components:**
- **Universal Forwarder** — Lightweight agent (< 30 MB RAM). Ships raw data to indexers.
- **Heavy Forwarder** — Full Splunk instance that can parse/transform before forwarding.
- **Indexers** — Index and store data. SmartStore offloads to object storage.
- **Search Heads** — Execute SPL queries, serve UI, run scheduled searches.
- **Deployment Server** — Centralized forwarder management.

**Strengths:** Industry-leading query language (SPL), enterprise SIEM features, ML toolkit (MLTK), extremely mature, vast app ecosystem (Splunkbase), compliance certifications.

**Weaknesses:** Most expensive option, complex architecture at scale, steep learning curve, heavy resource requirements.

---

## Feature Comparison Matrix

| Feature | ELK | PLG (Loki) | Datadog | Splunk |
|---------|-----|------------|---------|--------|
| **Full-text search** | ✅ Native | ⚠️ Scan-based | ✅ Native | ✅ Native |
| **Structured queries** | ✅ KQL/Lucene | ✅ LogQL | ✅ Facets | ✅ SPL |
| **Live tail** | ✅ Kibana | ✅ Grafana | ✅ Live tail | ✅ Real-time |
| **Alerting** | ✅ Watcher/Rules | ✅ Loki ruler | ✅ Monitors | ✅ Alerts |
| **Dashboards** | ✅ Kibana Lens | ✅ Grafana | ✅ Dashboards | ✅ Dashboards |
| **Log-to-trace** | ✅ APM | ✅ Tempo link | ✅ Native | ✅ APM |
| **Log-to-metric** | ✅ Transform | ✅ LogQL metrics | ✅ Generate metrics | ✅ mstats |
| **Role-based access** | ✅ Security | ✅ Multi-tenant | ✅ Teams/RBAC | ✅ RBAC |
| **Retention management** | ✅ ILM | ✅ Compactor | ✅ Archives | ✅ Index policies |
| **ML/anomaly** | ⚠️ Paid (X-Pack) | ❌ | ✅ Watchdog | ✅ MLTK |
| **SIEM capabilities** | ⚠️ Basic | ❌ | ✅ Cloud SIEM | ✅ Enterprise Security |
| **API** | ✅ REST | ✅ HTTP/gRPC | ✅ REST | ✅ REST |

---

## Cost Model

### Self-Hosted Comparison (100 GB/day ingest, 30-day hot retention)

| Component | ELK | PLG (Loki) |
|-----------|-----|------------|
| **Compute** | 6× r6g.xlarge (ES) + 2× c6g.large (Logstash) ≈ $2,500/mo | 3× c6g.large (Loki) ≈ $400/mo |
| **Storage (hot)** | 3 TB EBS gp3 ≈ $250/mo | Minimal (object store) |
| **Storage (object)** | Optional (S3 snapshots) | 3 TB S3 ≈ $70/mo |
| **Total estimate** | **$2,750–3,500/mo** | **$470–800/mo** |
| **Cost per GB ingested** | ~$0.90–1.15 | ~$0.15–0.27 |

### SaaS Comparison (100 GB/day ingest, 30-day retention)

| Provider | Pricing Model | Est. Monthly Cost | Notes |
|----------|---------------|-------------------|-------|
| **Elastic Cloud** | Per GB ingested + storage | $3,000–5,000 | Autoscaling, managed |
| **Grafana Cloud (Loki)** | Per GB ingested | $1,500–2,500 | Free tier: 50 GB/mo |
| **Datadog** | Per GB ingested ($0.10) + retention | $3,000–6,000 | 15-day default, $1.70/M events for longer |
| **Splunk Cloud** | Per GB/day indexed | $5,000–15,000 | Volume discounts available |

### Cost Reduction Strategies

| Strategy | Applicable To | Savings |
|----------|---------------|---------|
| Log sampling (1-in-10 for info) | All | 50–80% volume reduction |
| Exclude debug/trace in prod | All | 30–60% |
| Use exclusion filters (drop health checks) | All | 10–30% |
| Archive to S3 (cold tier) | ELK, Splunk | 70–90% on storage |
| Use Loki instead of ELK for K8s | Self-hosted | 60–75% |
| Datadog Flex Logs (index on demand) | Datadog | 50–70% |

---

## Scaling Characteristics

### Scaling Comparison

| Dimension | ELK | PLG (Loki) | Datadog | Splunk |
|-----------|-----|------------|---------|--------|
| **Horizontal scale** | Add ES data nodes | Add ingesters + object storage | Automatic (SaaS) | Add indexers + search heads |
| **Ingest throughput** | 10–50 GB/node/day | 50–200 GB/node/day | Unlimited (SaaS) | 10–100 GB/indexer/day |
| **Query parallelism** | Shard-level | Querier workers | Automatic | Search head cluster |
| **Storage decoupling** | ⚠️ Searchable snapshots | ✅ Native (S3/GCS) | ✅ Native | ✅ SmartStore |
| **Multi-region** | Manual (CCR) | Native (multi-zone) | ✅ Built-in | Manual clustering |
| **Bottleneck** | Disk I/O, JVM heap | Object store latency | N/A (vendor) | Indexer throughput |

### Scaling Thresholds

| Scale | Recommended Stack |
|-------|-------------------|
| < 10 GB/day | Any (Loki cheapest) |
| 10–100 GB/day | ELK or Loki (self-hosted), Datadog (SaaS) |
| 100 GB–1 TB/day | ELK cluster or Loki (dedicated), Splunk |
| > 1 TB/day | Splunk, Elastic Cloud, or custom Loki + S3 |

---

## Query Capabilities

### Query Language Comparison

**Find error logs for the user-api service in the last hour:**

**Kibana (KQL):**
```
service: "user-api" AND level: "error"
# Time picker: Last 1 hour
```

**LogQL (Loki):**
```logql
{service="user-api"} | json | level="error"
```

**Datadog:**
```
service:user-api status:error
```

**SPL (Splunk):**
```spl
index=main service="user-api" level="error" earliest=-1h
```

### Aggregation Example — Top 10 Error Messages

**Elasticsearch:**
```json
{
  "query": { "bool": { "filter": [
    { "term": { "level": "error" } },
    { "range": { "@timestamp": { "gte": "now-1h" } } }
  ]}},
  "aggs": {
    "top_errors": {
      "terms": { "field": "error.message.keyword", "size": 10 }
    }
  }
}
```

**LogQL:**
```logql
topk(10, sum(count_over_time(
  {service=~".+"} | json | level="error" [1h]
)) by (err))
```

**SPL:**
```spl
index=main level=error earliest=-1h
| top 10 error_message
```

### Query Capability Matrix

| Capability | ELK | LogQL | Datadog | SPL |
|-----------|-----|-------|---------|-----|
| Substring search | ✅ Fast | ⚠️ Scan | ✅ Fast | ✅ Fast |
| Regex | ✅ | ✅ | ✅ | ✅ |
| Field aggregation | ✅ Rich | ⚠️ Basic | ✅ Rich | ✅ Richest |
| Percentiles | ✅ | ✅ `quantile_over_time` | ✅ | ✅ `perc` |
| Join/lookup | ⚠️ Enrich processor | ❌ | ⚠️ Reference tables | ✅ `lookup` |
| Statistical functions | ✅ | ⚠️ Limited | ✅ | ✅ Extensive |
| Sub-queries | ⚠️ Limited | ❌ | ⚠️ | ✅ Full |
| Time comparison | ✅ | ✅ `offset` | ✅ | ✅ `earliest/latest` |

---

## Operational Complexity

| Task | ELK | PLG (Loki) | Datadog | Splunk |
|------|-----|------------|---------|--------|
| **Initial setup** | Medium (3–5 components) | Low (3 components) | Very Low (SaaS) | High (forwarders + indexers) |
| **Day-2 operations** | High (shard mgmt, JVM) | Low (stateless queries) | None (managed) | High (forwarder mgmt) |
| **Upgrades** | Rolling restart, breaking changes risk | Simple binary swap | Automatic | Complex cluster upgrade |
| **Backup/DR** | Snapshot to S3 | Object store = built-in | Managed | Snapshot + replication |
| **Monitoring itself** | Must build (Prometheus exporter) | Prometheus metrics built-in | Built-in | Built-in |
| **Team skill needed** | ES cluster admin | K8s + basic ops | Minimal | Splunk admin certification |

---

## Decision Framework

### Choose ELK When:
- ✅ You need powerful full-text search across log content
- ✅ Compliance requires document-level security and audit trails
- ✅ You have the team to manage Elasticsearch clusters
- ✅ You need complex aggregations and analytics
- ✅ You already have Elastic skills/infrastructure

### Choose PLG (Loki + Grafana) When:
- ✅ You're running Kubernetes and already use Prometheus/Grafana
- ✅ Cost efficiency is a primary concern
- ✅ Most queries filter by known labels (service, namespace, level)
- ✅ You want simple operations (S3 storage, stateless queries)
- ✅ You need unified metrics + logs + traces in one UI

### Choose Datadog When:
- ✅ You want zero infrastructure management
- ✅ You need quick time-to-value (days, not weeks)
- ✅ You want built-in APM + logs + infra + security in one platform
- ✅ Your team prefers UI-driven configuration over code
- ✅ Volume is moderate (< 100 GB/day) and budget allows SaaS pricing

### Choose Splunk When:
- ✅ Enterprise-grade SIEM/security analytics is required
- ✅ You need the most powerful query language (SPL)
- ✅ Compliance and audit requirements are extensive (FedRAMP, ITAR)
- ✅ You ingest from many heterogeneous sources
- ✅ Budget is not the primary constraint

### Migration Paths

| From | To | Key Consideration |
|------|----|-------------------|
| ELK → Loki | Rewrite Kibana dashboards to Grafana, adapt to label-based querying |
| ELK → Datadog | Use Datadog agent instead of Filebeat, recreate index patterns as log pipelines |
| Splunk → ELK | Convert SPL to KQL/Lucene, replicate lookups with Elasticsearch enrich processors |
| Datadog → Loki | Export pipeline configs, deploy Promtail/Alloy, build Grafana dashboards |
| Any → OTEL | Use OTEL Collector as universal shipper, route to any backend |
