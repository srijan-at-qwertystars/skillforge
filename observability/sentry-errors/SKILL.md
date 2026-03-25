---
name: sentry-errors
description: >
  Sentry error tracking, crash reporting, and performance monitoring integration.
  USE when: setting up Sentry SDK (JavaScript, TypeScript, Python, Go, Ruby, Java),
  capturing errors or exceptions, configuring error boundaries, performance monitoring
  and tracing, uploading source maps, managing releases with sentry-cli, configuring
  alert rules, issue grouping or fingerprinting, session replay, profiling, CI/CD
  Sentry integration, or self-hosted Sentry setup.
  DO NOT USE when: setting up log aggregation (ELK/Loki/Fluentd), configuring
  Datadog or New Relic APM, implementing uptime or synthetic monitoring, building
  application logging with Winston/Bunyan/loguru, or working with OpenTelemetry
  collectors without Sentry.
---

# Sentry Error Tracking & Performance Monitoring

## SDK Initialization

### JavaScript / TypeScript (Node.js)

```typescript
import * as Sentry from "@sentry/node";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV,
  release: process.env.SENTRY_RELEASE, // e.g., "my-app@1.2.3"
  tracesSampleRate: process.env.NODE_ENV === "production" ? 0.2 : 1.0,
  profilesSampleRate: 0.1,
  integrations: [
    Sentry.httpIntegration(),
    Sentry.expressIntegration(),
    Sentry.prismaIntegration(),
  ],
  beforeSend(event) {
    // Drop non-actionable errors
    if (event.exception?.values?.[0]?.type === "AbortError") return null;
    return event;
  },
});
```

### JavaScript (Browser / React)

```typescript
import * as Sentry from "@sentry/react";

Sentry.init({
  dsn: process.env.REACT_APP_SENTRY_DSN,
  environment: process.env.NODE_ENV,
  release: process.env.REACT_APP_SENTRY_RELEASE,
  tracesSampleRate: 0.2,
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
  integrations: [
    Sentry.browserTracingIntegration(),
    Sentry.replayIntegration({ maskAllText: true, blockAllMedia: true }),
  ],
});

// React error boundary wrapper
const SentryErrorBoundary = Sentry.ErrorBoundary;
// Usage: <SentryErrorBoundary fallback={<ErrorPage />}><App /></SentryErrorBoundary>
```

### Python (Django / Flask / FastAPI)

```python
import sentry_sdk

sentry_sdk.init(
    dsn=os.environ["SENTRY_DSN"],
    environment=os.environ.get("SENTRY_ENVIRONMENT", "production"),
    release=os.environ.get("SENTRY_RELEASE"),
    traces_sample_rate=0.2,
    profiles_sample_rate=0.1,
    send_default_pii=False,
    before_send=filter_events,
)

# Django: add "sentry_sdk.integrations.django.DjangoIntegration" — auto-detected
# Flask: add "sentry_sdk.integrations.flask.FlaskIntegration" — auto-detected
# FastAPI: add "sentry_sdk.integrations.fastapi.FastApiIntegration" — auto-detected

def filter_events(event, hint):
    """Drop health-check noise and expected errors."""
    if "exc_info" in hint:
        exc_type = hint["exc_info"][0]
        if exc_type in (KeyboardInterrupt, SystemExit):
            return None
    return event
```

### Go

```go
import "github.com/getsentry/sentry-go"

err := sentry.Init(sentry.ClientOptions{
    Dsn:              os.Getenv("SENTRY_DSN"),
    Environment:      os.Getenv("SENTRY_ENVIRONMENT"),
    Release:          os.Getenv("SENTRY_RELEASE"),
    TracesSampleRate: 0.2,
    BeforeSend: func(event *sentry.Event, hint *sentry.EventHint) *sentry.Event {
        // Scrub sensitive data or drop noisy errors
        return event
    },
})
if err != nil {
    log.Fatalf("sentry.Init: %s", err)
}
defer sentry.Flush(2 * time.Second)
// For HTTP: use sentryhttp.NewSentryHandler or sentrygin/sentryecho middleware
```

### Ruby (Rails)

```ruby
# config/initializers/sentry.rb
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = Rails.env
  config.release = ENV["SENTRY_RELEASE"]
  config.traces_sample_rate = 0.2
  config.profiles_sample_rate = 0.1
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.before_send = lambda do |event, hint|
    event # return nil to drop
  end
end
```

### Java (Spring Boot)

```xml
<!-- pom.xml -->
<dependency>
  <groupId>io.sentry</groupId>
  <artifactId>sentry-spring-boot-starter-jakarta</artifactId>
  <version>7.x.x</version>
</dependency>
```

```yaml
# application.yml
sentry:
  dsn: ${SENTRY_DSN}
  environment: ${SENTRY_ENVIRONMENT:production}
  release: ${SENTRY_RELEASE}
  traces-sample-rate: 0.2
  exception-resolver-order: -2147483647
```

## Error Capturing & Context Enrichment

### Manual Error Capture

```typescript
// JS/TS
try {
  await riskyOperation();
} catch (error) {
  Sentry.captureException(error, {
    tags: { module: "payments", severity: "critical" },
    extra: { orderId: order.id, amount: order.total },
    fingerprint: ["payments", "charge-failed", String(error.code)],
  });
}

// Python
try:
    risky_operation()
except Exception as e:
    sentry_sdk.capture_exception(e)

// Go
if err != nil {
    sentry.CaptureException(err)
}
```

### User & Scope Context

```typescript
// Set user on login — applies to all subsequent events
Sentry.setUser({ id: user.id, email: user.email, segment: user.plan });

// Set tags for filtering in Sentry UI
Sentry.setTag("tenant", tenantId);
Sentry.setTag("feature_flag", "new-checkout");

// Scoped context for a specific operation
Sentry.withScope((scope) => {
  scope.setLevel("warning");
  scope.setContext("order", { id: orderId, items: itemCount });
  Sentry.captureMessage("Payment retried after timeout");
});
```

```python
# Python equivalent
sentry_sdk.set_user({"id": user.id, "email": user.email})
sentry_sdk.set_tag("tenant", tenant_id)

with sentry_sdk.push_scope() as scope:
    scope.set_context("order", {"id": order_id})
    sentry_sdk.capture_message("Payment retried")
```

### Breadcrumbs

```typescript
Sentry.addBreadcrumb({
  category: "auth",
  message: `User ${userId} logged in via ${provider}`,
  level: "info",
  data: { provider, mfaUsed: true },
});
```

## Performance Monitoring & Tracing

### Automatic Instrumentation

Most SDKs auto-instrument HTTP requests, database queries, and framework routes when
`tracesSampleRate > 0`. Configure sampling dynamically for cost control:

```typescript
Sentry.init({
  tracesSampler: (samplingContext) => {
    if (samplingContext.name?.includes("/health")) return 0;       // Drop health checks
    if (samplingContext.name?.includes("/api/payments")) return 1.0; // Always trace payments
    return 0.2; // Default 20%
  },
});
```

### Custom Spans

```typescript
const span = Sentry.startInactiveSpan({ name: "process-invoice", op: "task" });
try {
  await processInvoice(invoiceId);
  span.setStatus({ code: 1, message: "ok" });
} catch (error) {
  span.setStatus({ code: 2, message: "internal_error" });
  throw error;
} finally {
  span.end();
}
```

```python
with sentry_sdk.start_span(op="task", name="process-invoice") as span:
    span.set_data("invoice_id", invoice_id)
    process_invoice(invoice_id)
```

## Source Maps & Release Management

### Upload Source Maps (JS/TS)

Preferred: use the Sentry bundler plugin (Webpack, Vite, esbuild, Rollup):

```typescript
// vite.config.ts
import { sentryVitePlugin } from "@sentry/vite-plugin";

export default defineConfig({
  build: { sourcemap: true },
  plugins: [
    sentryVitePlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT,
      authToken: process.env.SENTRY_AUTH_TOKEN,
    }),
  ],
});
```

Manual upload with sentry-cli:

```bash
sentry-cli releases new "$VERSION"
sentry-cli releases files "$VERSION" upload-sourcemaps ./dist \
  --url-prefix '~/static/js' --validate
sentry-cli releases set-commits --auto "$VERSION"
sentry-cli releases finalize "$VERSION"
```

## CI/CD Integration

### GitHub Actions

```yaml
- name: Create Sentry release
  uses: getsentry/action-release@v3
  env:
    SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}
    SENTRY_ORG: my-org
    SENTRY_PROJECT: my-project
  with:
    environment: production
    version: ${{ github.sha }}
    sourcemaps: ./dist
    url_prefix: "~/static/js"
    set_commits: auto
```

### Generic CI (GitLab, CircleCI, Jenkins)

```bash
curl -sL https://sentry.io/get-cli/ | bash
export SENTRY_AUTH_TOKEN="$SENTRY_AUTH_TOKEN"
export SENTRY_ORG="my-org" SENTRY_PROJECT="my-project"
VERSION=$(sentry-cli releases propose-version)
sentry-cli releases new "$VERSION"
sentry-cli releases set-commits --auto "$VERSION"
sentry-cli releases files "$VERSION" upload-sourcemaps ./build --validate
sentry-cli releases finalize "$VERSION"
sentry-cli releases deploys "$VERSION" new -e "$CI_ENVIRONMENT"
```

## Alert Configuration & Issue Grouping

### Alert Rules (Configure via Sentry UI or API)

Set up tiered alerts to avoid fatigue:

- **P0 Critical**: New issue in `payments` or `auth` module → PagerDuty/Slack immediately
- **P1 High**: Error count > 100 in 5 min for any release → Slack channel
- **P2 Medium**: New issue spike > 10 events in 1 hour → Email digest
- **Ignore**: Known noisy errors → Inbound filter or `beforeSend` drop

### Custom Fingerprinting

Control how Sentry groups events into issues:

```typescript
// SDK-level fingerprinting
Sentry.captureException(error, {
  fingerprint: ["database-connection", dbHost],
});
```

Server-side fingerprint rules (Project Settings → Issue Grouping):

```
# Group all ChunkLoadError by module
type:ChunkLoadError -> chunk-load-error

# Group API timeouts by endpoint
message:"timeout *" tags.endpoint:* -> timeout-{{ tags.endpoint }}

# Separate errors by customer for multi-tenant
tags.tenant:* -> {{ default }}-{{ tags.tenant }}
```

### Stack Trace Rules

```
# Collapse noisy third-party frames
family:javascript stack.abs_path:**/node_modules/** -group
family:python stack.module:celery.* -group
```

## Session Replay & Profiling

### Session Replay (Browser)

```typescript
Sentry.init({
  replaysSessionSampleRate: 0.1,  // 10% of all sessions
  replaysOnErrorSampleRate: 1.0,  // 100% of error sessions
  integrations: [
    Sentry.replayIntegration({
      maskAllText: true, blockAllMedia: true, maskAllInputs: true,
      networkDetailAllowUrls: ["/api/"],
    }),
  ],
});
```

### Profiling

Enable via `profilesSampleRate` in any SDK init (shown above). Add
`Sentry.nodeProfilingIntegration()` for Node.js. Python and Ruby auto-detect.

## Environment & Configuration Management

### Environment Variables (all SDKs)

| Variable | Purpose |
|---|---|
| `SENTRY_DSN` | Project data source name (required) |
| `SENTRY_ENVIRONMENT` | `production`, `staging`, `development` |
| `SENTRY_RELEASE` | Version string, e.g., `my-app@1.2.3` or git SHA |
| `SENTRY_AUTH_TOKEN` | CI/CD auth for sentry-cli |
| `SENTRY_ORG` / `SENTRY_PROJECT` | Organization and project slugs for sentry-cli |

Create `.sentryclirc` in project root with `[defaults]` org/project. Never commit tokens;
use `SENTRY_AUTH_TOKEN` env var.

## Self-Hosted vs SaaS

| Aspect | SaaS (sentry.io) | Self-Hosted |
|---|---|---|
| Setup | Instant, managed | Docker Compose, ~16GB RAM minimum |
| Features | All features, first access to new ones | Core features, some lag on new releases |
| Scaling | Automatic | Manual (Kafka, PostgreSQL, ClickHouse, Redis) |
| Cost | Per-event pricing, expensive at scale | Infrastructure cost only, cheaper at high volume |
| Support | Official support included | Community only, no official support |
| Data residency | Sentry-managed regions (US/EU) | Full control, any region |
| Upgrades | Automatic | Manual, monthly calendar versioning (YY.MM.PATCH) |
| Best for | Most teams, fast iteration | Data sovereignty, regulatory, very high volume |

Self-hosted install:

```bash
git clone https://github.com/getsentry/self-hosted.git
cd self-hosted
./install.sh
docker compose up -d
```

## Noise Reduction Best Practices

### SDK-Level Filtering

```typescript
Sentry.init({
  ignoreErrors: [
    /ResizeObserver loop/,
    /Network request failed/,
    /Load failed/,
    "Non-Error promise rejection captured",
  ],
  denyUrls: [
    /extensions\//i,
    /^chrome:\/\//i,
    /^moz-extension:\/\//i,
  ],
  beforeSend(event, hint) {
    const error = hint?.originalException;
    // Drop browser extension errors
    if (error?.stack?.match(/extension\//)) return null;
    // Drop 4xx client errors from fetch
    if (error?.status >= 400 && error?.status < 500) return null;
    return event;
  },
});
```

### Server-Side Inbound Filters (Sentry UI)

Enable under Project Settings → Inbound Filters:
- Filter legacy browsers (IE, old Safari)
- Filter known web crawlers/bots
- Filter localhost events
- Set rate limits per-key to cap burst events

### Sampling Strategy

```
Production:  tracesSampleRate=0.1-0.2, replaySampleRate=0.1
Staging:     tracesSampleRate=1.0, replaySampleRate=0.5
Development: tracesSampleRate=1.0, replaySampleRate=1.0
```

Use `tracesSampler` function for endpoint-specific rates. Always trace critical paths
(payments, auth) at 100%. Drop health checks and static assets at 0%.

### Operational Hygiene

- Review and resolve/archive stale issues weekly
- Use Sentry's "Suspect Commits" and "Suggested Assignees" for ownership
- Set up CODEOWNERS-based auto-assignment via Sentry's ownership rules
- Tag releases in CI so regressions are immediately visible
- Configure issue alert cooldowns to prevent notification storms
- Use metric alerts for aggregate trends (error rate, p95 latency) rather than per-event
