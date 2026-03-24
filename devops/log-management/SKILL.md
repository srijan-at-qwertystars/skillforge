---
name: log-management
description: >
  Guide for structured logging, log aggregation, rotation, and centralized log management.
  Covers logging libraries (Winston, Pino, zap, slog, structlog, Log4j2), aggregation stacks
  (ELK, Loki+Grafana, Fluentd), log shipping patterns (sidecar, DaemonSet), correlation IDs,
  log rotation (logrotate, journald), syslog (rsyslog, syslog-ng), security/audit logging with
  PII redaction, retention policies, log sampling, OpenTelemetry logging, and log-based alerting.
  Use when user needs logging setup, log aggregation, ELK stack, structured logging, log rotation,
  centralized logging, log level guidance, or log pipeline architecture.
  NOT for application monitoring/metrics, NOT for distributed tracing setup, NOT for error tracking tools like Sentry.
---

# Log Management

## Structured Logging

Always emit structured logs (JSON) in production. Never use string interpolation for log messages.

Standard log schema — every entry MUST include:
```json
{"timestamp":"2024-03-24T12:34:56.789Z","level":"info","message":"Request completed","service":"user-api","environment":"production","trace_id":"abc123","span_id":"def456","request_id":"req-789","duration_ms":142}
```

Structured (JSON) vs unstructured: JSON is machine-readable with zero regex, filterable by any field. Unstructured requires brittle grok/regex parsing. Use JSON for all production services; plaintext only for local dev.

## Log Levels

Configure production to `info` and above. Use levels consistently across all services.

| Level | Use for | Alert? |
|-------|---------|--------|
| `trace` | Loop iterations, fine-grained debug | No |
| `debug` | Diagnostic detail (query timing, row counts) | No |
| `info` | Normal ops, state changes, request lifecycle | Dashboard |
| `warn` | Recoverable issues, degraded state, expected errors (404, validation) | Dashboard trends |
| `error` | Failed operations needing attention (NOT expected 404s) | Yes — alert |
| `fatal` | Unrecoverable, process exiting | Yes — page |

## Logging Libraries

### Node.js — Pino (recommended for perf)
```javascript
import pino from 'pino';
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  formatters: { level: (label) => ({ level: label }) },
  redact: ['req.headers.authorization', 'user.email', '*.password'],
  transport: process.env.NODE_ENV === 'development' ? { target: 'pino-pretty' } : undefined,
});
// Child loggers for request context
app.use((req, res, next) => {
  req.log = logger.child({ request_id: req.headers['x-request-id'] || crypto.randomUUID() });
  next();
});
req.log.info({ duration_ms: 42, status: 200 }, 'Request completed');
```

Winston — use when you need multiple transports (file + console + HTTP):
```javascript
import winston from 'winston';
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(winston.format.timestamp(), winston.format.errors({ stack: true }), winston.format.json()),
  defaultMeta: { service: 'order-service' },
  transports: [new winston.transports.File({ filename: 'error.log', level: 'error' }), new winston.transports.File({ filename: 'combined.log' })],
});
```

### Go — slog (stdlib, Go 1.21+, recommended)
```go
logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
slog.SetDefault(logger)
slog.Info("request completed", "method", r.Method, "path", r.URL.Path, "duration_ms", elapsed.Milliseconds(), "status", statusCode)
// Output: {"time":"2024-03-24T12:34:56Z","level":"INFO","msg":"request completed","method":"GET","path":"/users","duration_ms":42,"status":200}
```

zap — zero-allocation, highest throughput:
```go
logger, _ := zap.NewProduction()
defer logger.Sync()
logger.Info("request completed", zap.String("method", "GET"), zap.Int("status", 200), zap.Duration("duration", elapsed))
```

### Python — structlog (recommended)
```python
import structlog
structlog.configure(processors=[structlog.processors.TimeStamper(fmt="iso"), structlog.processors.add_log_level, structlog.processors.JSONRenderer()])
logger = structlog.get_logger()
logger.info("request_completed", method="GET", path="/users", duration_ms=42, status=200)
# {"event":"request_completed","level":"info","timestamp":"2024-03-24T12:34:56Z","method":"GET","duration_ms":42}
```

### Java — SLF4J + Logback with JSON
```xml
<configuration>
  <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
      <customFields>{"service":"payment-api","env":"prod"}</customFields>
    </encoder>
  </appender>
  <root level="INFO"><appender-ref ref="JSON"/></root>
</configuration>
```
```java
MDC.put("trace_id", traceId);
MDC.put("request_id", requestId);
logger.info("Payment processed amount={} currency={}", amount, currency);
// MDC fields automatically included in JSON output
```

## Correlation IDs

Generate UUID at ingress if `X-Correlation-ID` header missing. Propagate through all downstream calls.

1. Generate at API gateway/load balancer
2. Store in request context (thread-local, async context, middleware)
3. Include in every log entry via child logger or MDC
4. Pass in outgoing HTTP headers, MQ metadata, gRPC metadata
5. Standardize field name (`correlation_id` or `trace_id`) across all services

## Log Aggregation

### ELK Stack (Elasticsearch + Logstash + Kibana)
Best for: full-text search, complex queries, compliance. `App → Filebeat → Logstash → Elasticsearch → Kibana`

Filebeat config:
```yaml
filebeat.inputs:
  - type: log
    paths: ["/var/log/app/*.json"]
    json.keys_under_root: true
output.logstash:
  hosts: ["logstash:5044"]
```
Logstash pipeline:
```ruby
input { beats { port => 5044 } }
filter { json { source => "message" } date { match => ["timestamp", "ISO8601"] } }
output { elasticsearch { hosts => ["es:9200"] index => "app-logs-%{+YYYY.MM.dd}" } }
```

### Loki + Grafana
Best for: K8s-native, cost-effective (indexes labels only, not content). `App → Promtail (DaemonSet) → Loki → Grafana`

Promtail scrape config:
```yaml
scrape_configs:
  - job_name: kubernetes
    kubernetes_sd_configs: [{ role: pod }]
    pipeline_stages:
      - json: { expressions: { level: level, service: service } }
      - labels: { level: null, service: null }
```
LogQL queries:
```
{namespace="production", service="user-api"} | json | level="error"
{service="payment"} | json | duration_ms > 1000
sum(rate({service="api"} | json | level="error" [5m])) by (service)
```

### Fluent Bit (lightweight K8s collector)
```ini
[INPUT]
    Name tail
    Path /var/log/containers/*.log
    Parser docker
[FILTER]
    Name kubernetes
    Match kube.*
    Merge_Log On
[OUTPUT]
    Name es
    Match *
    Host elasticsearch
    Index app-logs
```

## Log Shipping Patterns

| Pattern | How | Pros | Cons | Use when |
|---------|-----|------|------|----------|
| **DaemonSet** | 1 agent/node reads `/var/log/containers/` | Resource-efficient | Shared config for all pods | Default for K8s (Fluent Bit, Filebeat) |
| **Sidecar** | 1 agent/pod co-located with app | Per-app parsing, isolation | Higher resource use | App writes files, needs custom parsing |
| **Direct ship** | App sends via SDK/HTTP to backend | No file I/O, immediate | Tight coupling, retry in app | Serverless/Lambda, low-volume |

## Log Rotation

### logrotate (`/etc/logrotate.d/myapp`)
```
/var/log/myapp/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 appuser appgroup
    sharedscripts
    postrotate
        systemctl reload myapp 2>/dev/null || true
    endscript
}
```
Key: use `create` + `postrotate` (preferred) over `copytruncate` (may lose lines). Add `maxsize 100M` to rotate by size. Test: `logrotate -d /etc/logrotate.d/myapp`. Force: `logrotate -f /etc/logrotate.d/myapp`.

### journald (`/etc/systemd/journald.conf`)
```ini
[Journal]
Storage=persistent
SystemMaxUse=2G
SystemKeepFree=1G
MaxRetentionSec=30day
Compress=yes
```
```bash
journalctl -u myservice --since "1 hour ago" -o json-pretty   # query with JSON
journalctl -u myservice -p err                                  # errors only
journalctl --vacuum-size=1G                                     # trim to 1GB
journalctl --vacuum-time=2weeks                                 # remove old entries
```

## Syslog

### rsyslog — forward to central server
Client (`/etc/rsyslog.d/50-forward.conf`):
```
# TCP (reliable)
*.* @@logserver.example.com:514
# TLS
$DefaultNetstreamDriverCAFile /etc/ssl/certs/ca.pem
$ActionSendStreamDriver gtls
$ActionSendStreamDriverMode 1
*.* @@logserver.example.com:6514
```
Server — per-host log files:
```
module(load="imtcp")
input(type="imtcp" port="514")
template(name="PerHostLog" type="string" string="/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log")
*.* ?PerHostLog
```

### syslog-ng — structured forwarding to Elasticsearch
```
source s_local { system(); internal(); };
destination d_elastic { elasticsearch-http(url("http://es:9200/_bulk") index("syslog-${YEAR}.${MONTH}.${DAY}")); };
log { source(s_local); destination(d_elastic); };
```

## Security & Audit Logging

Log these events for security audits:
- Authentication: login success/failure, MFA, token refresh
- Authorization: access granted/denied, role changes
- Data access: reads/writes to sensitive records, with actor identity
- Admin actions: config changes, deployments, user management

### PII Redaction — implement at logger level

**Pino:**
```javascript
const logger = pino({ redact: { paths: ['user.email', 'user.ssn', '*.password', 'req.headers.authorization'], censor: '[REDACTED]' } });
```
**OTEL Collector:**
```yaml
processors:
  attributes:
    actions:
      - { key: user.email, action: update, value: "[REDACTED]" }
      - { key: auth.token, action: delete }
      - { key: client.ip, action: hash }
```
**Python structlog:**
```python
def redact_pii(_, __, event_dict):
    for key in ('email', 'ssn', 'password', 'token'):
        if key in event_dict:
            event_dict[key] = '[REDACTED]'
    return event_dict
structlog.configure(processors=[redact_pii, structlog.processors.JSONRenderer()])
```

## Log Retention & Storage

| Tier | Retention | Storage | Access |
|------|-----------|---------|--------|
| Hot | 7–30d | Elasticsearch / Loki | Real-time queries |
| Warm | 30–90d | Reduced replicas | Investigation |
| Cold | 90d–7yr | S3/GCS Glacier (compressed) | Compliance/audit |

Elasticsearch ILM policy:
```json
{"policy":{"phases":{
  "hot":{"actions":{"rollover":{"max_size":"50GB","max_age":"7d"}}},
  "warm":{"min_age":"30d","actions":{"shrink":{"number_of_shards":1},"forcemerge":{"max_num_segments":1}}},
  "cold":{"min_age":"90d","actions":{"searchable_snapshot":{"snapshot_repository":"s3-repo"}}},
  "delete":{"min_age":"365d","actions":{"delete":{}}}
}}}
```

S3 lifecycle for cold archives:
```json
{"Rules":[{"ID":"log-archive","Status":"Enabled","Transitions":[{"Days":90,"StorageClass":"GLACIER"},{"Days":365,"StorageClass":"DEEP_ARCHIVE"}],"Expiration":{"Days":2555}}]}
```

## Log-Based Alerting

Loki alerting rule:
```yaml
groups:
  - name: log-alerts
    rules:
      - alert: HighErrorRate
        expr: sum(rate({service="api"} | json | level="error" [5m])) by (service) > 10
        for: 2m
        labels: { severity: critical }
      - alert: AuthFailureSpike
        expr: sum(rate({service="auth"} |= "login_failed" [5m])) > 50
        for: 1m
        labels: { severity: warning }
```

Elasticsearch Watcher: trigger on >100 errors in 5m, send Slack webhook. Define `trigger.schedule.interval: 1m`, search `level:error` with `range @timestamp gte now-5m`, condition `hits.total.value > 100`.

## Log Sampling

For high-volume services (>10k req/s), sample to control cost. Always log `error`+ at 100%.

| Strategy | How | Best for |
|----------|-----|----------|
| Rate-based | Log 1-in-N at info | Predictable reduction |
| Probabilistic | Random % sample | Simple, stateless |
| Tail-based | Decide after request; 100% errors, 1% success | Best signal-to-noise |
| Dynamic | Adjust rate by error rate / traffic | Adaptive cost control |

```javascript
// Pino sampling middleware — 10% of healthy requests, 100% of errors
app.use((req, res, next) => {
  const sampled = Math.random() < 0.1;
  req.log = logger.child({ request_id: crypto.randomUUID(), sampled });
  req.log.level = sampled ? 'info' : 'warn';
  next();
});
```

## OpenTelemetry Logging

Bridge existing loggers to OTEL for unified observability (logs + traces + metrics).

```yaml
receivers:
  filelog:
    include: ["/var/log/app/*.json"]
    operators:
      - type: json_parser
        timestamp: { parse_from: attributes.timestamp, layout: '%Y-%m-%dT%H:%M:%S.%LZ' }
processors:
  batch: { timeout: 5s }
  resource:
    attributes:
      - { key: service.name, value: my-service, action: upsert }
      - { key: deployment.environment, value: production, action: upsert }
exporters:
  otlp: { endpoint: "otel-collector:4317" }
  loki: { endpoint: "http://loki:3100/loki/api/v1/push" }
service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [batch, resource]
      exporters: [otlp, loki]
```

OTEL log record maps: `Timestamp` (when), `SeverityNumber`+`SeverityText` (level), `Body` (message), `Attributes` (structured KV), `TraceId`/`SpanId` (correlation), `Resource` (service identity).

## Stack Selection

| Need | Recommended |
|------|-------------|
| Small team, K8s | Loki + Promtail + Grafana |
| Full-text search, compliance | ELK (Elasticsearch + Filebeat + Kibana) |
| Multi-backend routing | Fluent Bit → ES / Loki / S3 |
| Managed, low ops | Datadog or Splunk Cloud |
| Unified observability | OTEL Collector → any backend |
| Security/audit | ELK or Splunk with immutable indices |

## Additional Resources

### References

In-depth guides in `references/`:

- **[Advanced Patterns](references/advanced-patterns.md)** — Distributed tracing correlation, OpenTelemetry Log Bridge API, log-based metrics extraction, structured logging schema design, contextual logging (MDC/context propagation per language), log enrichment pipelines, multi-tenant logging isolation, audit log compliance (SOC2/HIPAA/GDPR), and log analytics query patterns.

- **[Troubleshooting](references/troubleshooting.md)** — Elasticsearch performance (shard sizing, mapping explosions, JVM tuning, slow queries, cluster health), Loki LogQL optimization, Fluent Bit backpressure handling, log loss diagnosis flowchart, timestamp parsing issues, multiline log handling (Java/Python stack traces), high-cardinality label problems, and storage capacity planning with cost estimation.

- **[Stack Comparison](references/stack-comparison.md)** — ELK vs PLG (Loki) vs Datadog vs Splunk: architecture deep-dive, feature matrix, cost models (self-hosted and SaaS), scaling characteristics, query language comparison with examples, operational complexity, and a decision framework for choosing the right stack.

### Scripts

Executable tools in `scripts/`:

| Script | Purpose | Usage |
|--------|---------|-------|
| `log-setup-elk.sh` | Generate Docker Compose ELK stack with index templates and ILM | `./scripts/log-setup-elk.sh --start` |
| `log-analyzer.py` | Analyze JSON log files: error rates, top errors, latency percentiles, pattern detection | `./scripts/log-analyzer.py app.log` |
| `logrotate-setup.sh` | Configure logrotate for apps, Nginx, Docker, journald | `sudo ./scripts/logrotate-setup.sh --nginx --docker` |

### Assets

Ready-to-use configurations in `assets/`:

| Asset | Description |
|-------|-------------|
| `fluent-bit.conf` | Fluent Bit config: tail + K8s inputs, Elasticsearch/Loki outputs, filesystem buffering, Prometheus metrics |
| `docker-compose-elk.yml` | Production-ready ELK Docker Compose with resource limits, health checks, persistent volumes |
| `logging-config-examples/nodejs-pino.js` | Pino logger with JSON output, PII redaction, request context middleware |
| `logging-config-examples/python-structlog.py` | structlog with contextvars, PII redaction, OpenTelemetry injection |
| `logging-config-examples/go-slog.go` | slog with context handler, PII redaction, HTTP middleware |
| `logging-config-examples/java-log4j2.xml` | Log4j2 with JsonTemplateLayout, async appenders, MDC filter pattern |
<!-- tested: pass -->
