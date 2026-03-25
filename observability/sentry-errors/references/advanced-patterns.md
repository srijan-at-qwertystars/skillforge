# Sentry Advanced Patterns

## Table of Contents

- [Custom Integrations and Hooks](#custom-integrations-and-hooks)
  - [Writing a Custom Integration](#writing-a-custom-integration)
  - [SDK Hooks Lifecycle](#sdk-hooks-lifecycle)
  - [beforeSend / beforeSendTransaction](#beforesend--beforesendtransaction)
  - [eventProcessor Chains](#eventprocessor-chains)
- [Error Grouping and Fingerprinting](#error-grouping-and-fingerprinting)
  - [SDK-Level Fingerprinting](#sdk-level-fingerprinting)
  - [Server-Side Fingerprint Rules](#server-side-fingerprint-rules)
  - [Stack Trace Grouping Rules](#stack-trace-grouping-rules)
  - [Grouping Enhancements](#grouping-enhancements)
- [Breadcrumb Customization](#breadcrumb-customization)
  - [Custom Breadcrumbs](#custom-breadcrumbs)
  - [beforeBreadcrumb Hook](#beforebreadcrumb-hook)
  - [Breadcrumb Limits and Pruning](#breadcrumb-limits-and-pruning)
- [Transaction-Based Performance Monitoring](#transaction-based-performance-monitoring)
  - [Custom Transactions](#custom-transactions)
  - [Nested Spans](#nested-spans)
  - [Distributed Tracing](#distributed-tracing)
  - [Trace Propagation Targets](#trace-propagation-targets)
- [Custom Measurements and Metrics](#custom-measurements-and-metrics)
  - [Transaction Measurements](#transaction-measurements)
  - [Custom Metrics API](#custom-metrics-api)
  - [Metric Aggregation Strategies](#metric-aggregation-strategies)
- [SDK Transport Customization](#sdk-transport-customization)
  - [Custom Transport](#custom-transport)
  - [Offline Caching / Queuing](#offline-caching--queuing)
  - [Proxy and Tunnel Configuration](#proxy-and-tunnel-configuration)
- [Sampling Strategies](#sampling-strategies)
  - [Error Sampling](#error-sampling)
  - [Trace Sampling (tracesSampler)](#trace-sampling-tracessampler)
  - [Profile Sampling](#profile-sampling)
  - [Replay Sampling](#replay-sampling)
  - [Dynamic / Adaptive Sampling](#dynamic--adaptive-sampling)
- [Session Tracking and Release Health](#session-tracking-and-release-health)
  - [How Sessions Work](#how-sessions-work)
  - [Crash-Free Rate](#crash-free-rate)
  - [Release Health Thresholds](#release-health-thresholds)
  - [Adoption Tracking](#adoption-tracking)
- [Multi-Project and Multi-Org Patterns](#multi-project-and-multi-org-patterns)
  - [Micro-Frontend Sentry Setup](#micro-frontend-sentry-setup)
  - [Monorepo Multi-Project](#monorepo-multi-project)
  - [Cross-Org Data Sharing](#cross-org-data-sharing)

---

## Custom Integrations and Hooks

### Writing a Custom Integration

Integrations are the primary extension point for Sentry SDKs. A custom integration
implements `setupOnce` (called once per `Sentry.init`) and can hook into event
processing, add breadcrumbs, or instrument libraries.

```typescript
import * as Sentry from "@sentry/node";

const myIntegration: Sentry.Integration = {
  name: "MyCustomIntegration",
  setupOnce() {
    // Runs once when Sentry initializes
    // Patch libraries, register global handlers, etc.
  },
  setup(client) {
    // Access the Sentry client instance
    client.on("beforeEnvelope", (envelope) => {
      // Inspect or modify envelopes before they're sent
    });
  },
  processEvent(event, hint, client) {
    // Modify every event before it's sent
    event.tags = { ...event.tags, custom: "value" };
    return event;
  },
};

Sentry.init({
  dsn: "...",
  integrations: [myIntegration],
});
```

**Python custom integration:**

```python
from sentry_sdk.integrations import Integration, DidNotEnable

class MyIntegration(Integration):
    identifier = "my_integration"

    @staticmethod
    def setup_once():
        # Monkey-patch, register signal handlers, etc.
        import my_library
        original_fn = my_library.do_work

        def patched_fn(*args, **kwargs):
            with sentry_sdk.start_span(op="my_library", name="do_work"):
                return original_fn(*args, **kwargs)

        my_library.do_work = patched_fn

sentry_sdk.init(dsn="...", integrations=[MyIntegration()])
```

### SDK Hooks Lifecycle

Order of hook execution for a captured event:

1. `beforeBreadcrumb` — filters/modifies each breadcrumb as it's added
2. Event captured (captureException / captureMessage / unhandled)
3. `eventProcessors` (scope-level) — modify event in scope order
4. Integration `processEvent` — each integration's processor runs
5. `beforeSend` / `beforeSendTransaction` — final gate before network
6. Transport `send` — envelope serialized and transmitted

```typescript
Sentry.init({
  beforeSend(event, hint) {
    // LAST chance to modify or drop an error event
    // Return null to drop, return event to send
    // hint.originalException has the raw error object
    return event;
  },
  beforeSendTransaction(event) {
    // Same for transaction events (performance data)
    // Drop noisy transactions
    if (event.transaction?.includes("/health")) return null;
    return event;
  },
  beforeBreadcrumb(breadcrumb, hint) {
    // Scrub PII from breadcrumbs
    if (breadcrumb.category === "xhr") {
      delete breadcrumb.data?.requestBody;
    }
    return breadcrumb;
  },
});
```

### beforeSend / beforeSendTransaction

Use these for last-mile filtering. They receive the fully-processed event.

**Common patterns:**

```typescript
beforeSend(event, hint) {
  const error = hint.originalException;

  // 1. Drop known non-actionable errors
  if (error instanceof AbortError) return null;
  if (error?.message?.match(/ResizeObserver loop/)) return null;

  // 2. Scrub PII from event data
  if (event.request?.cookies) {
    delete event.request.cookies;
  }
  if (event.user?.email) {
    event.user.email = "[REDACTED]";
  }

  // 3. Add dynamic tags based on error type
  if (error?.code === "ECONNREFUSED") {
    event.tags = { ...event.tags, error_class: "network" };
  }

  // 4. Modify fingerprint conditionally
  if (error?.code === "RATE_LIMITED") {
    event.fingerprint = ["rate-limited", error.endpoint];
  }

  return event;
}
```

### eventProcessor Chains

Event processors run at the scope level and can be stacked. They execute in
registration order and each receives the output of the previous.

```typescript
Sentry.getCurrentScope().addEventProcessor((event, hint) => {
  // Add request metadata from async context
  const requestId = asyncLocalStorage.getStore()?.requestId;
  if (requestId) {
    event.tags = { ...event.tags, request_id: requestId };
  }
  return event;
});

// Isolation scope processors — apply to a request boundary
Sentry.withIsolationScope((isolationScope) => {
  isolationScope.addEventProcessor((event) => {
    event.contexts = {
      ...event.contexts,
      tenant: { id: tenantId, plan: tenantPlan },
    };
    return event;
  });
  handleRequest(req, res);
});
```

**Python event processors:**

```python
def add_request_context(event, hint):
    """Add Flask/Django request info."""
    from flask import request
    if request:
        event.setdefault("tags", {})["endpoint"] = request.endpoint
    return event

with sentry_sdk.new_scope() as scope:
    scope.add_event_processor(add_request_context)
```

---

## Error Grouping and Fingerprinting

### SDK-Level Fingerprinting

Override Sentry's default grouping by setting `fingerprint` on the event scope
or in `captureException` options.

```typescript
// Group all timeout errors by endpoint regardless of stack trace
Sentry.captureException(error, {
  fingerprint: ["timeout", endpoint],
});

// Use {{ default }} to extend rather than replace default grouping
Sentry.captureException(error, {
  fingerprint: ["{{ default }}", tenantId],
  // Creates sub-groups: default grouping + per-tenant separation
});

// Group by error message pattern (ignore variable parts)
Sentry.withScope((scope) => {
  scope.setFingerprint(["db-connection-failed", dbHost]);
  Sentry.captureException(error);
});
```

### Server-Side Fingerprint Rules

Configure in **Project Settings → Issue Grouping → Fingerprint Rules**.
These apply to ALL incoming events without SDK changes.

```
# Syntax: matchers -> fingerprint values

# Group all ChunkLoadError events together
type:ChunkLoadError -> chunk-load-error

# Group API errors by endpoint and status code
tags.endpoint:* tags.status_code:* -> api-error-{{ tags.endpoint }}-{{ tags.status_code }}

# Group by error message template (strip variable parts)
message:"User * not found" -> user-not-found

# Multi-tenant: separate issues per tenant
tags.tenant:* -> {{ default }}-{{ tags.tenant }}

# Group database errors by query type, not exact query
error.type:DatabaseError tags.query_type:* -> db-{{ tags.query_type }}

# Combine timeout errors across services
message:"timeout*" OR message:"ETIMEDOUT" -> network-timeout
```

### Stack Trace Grouping Rules

Configure in **Project Settings → Issue Grouping → Stack Trace Rules**.
Controls which frames are considered for grouping.

```
# Mark all node_modules frames as non-contributing
family:javascript stack.abs_path:**/node_modules/** -group

# Mark specific internal helpers as non-contributing
family:javascript stack.function:__webpack_require__* -group

# Mark Celery worker frames as non-contributing
family:python stack.module:celery.* -group

# Mark Django middleware as non-contributing
family:python stack.module:django.middleware.* -group

# Mark all frames in a vendored directory as non-contributing
stack.abs_path:**/vendor/** -group

# Force a frame to always contribute (override defaults)
stack.function:processPayment +group
```

### Grouping Enhancements

Sentry's "enhanced grouping" can be tuned via **Project Settings → Issue Grouping →
Grouping Config**. Key settings:

- **Grouping strategy**: Choose between `newstyle:2023-01-11` (latest), or pin to an
  older strategy to avoid re-grouping existing issues.
- **Custom grouping enhancements**: Write rules that strip variable frames, merge
  similar stack traces, or force specific function names to be the grouping root.
- When upgrading grouping config, Sentry will show "potential duplicates" — review
  and merge as needed.

---

## Breadcrumb Customization

### Custom Breadcrumbs

Add context about what happened before an error:

```typescript
// Navigation breadcrumb
Sentry.addBreadcrumb({
  type: "navigation",
  category: "route",
  data: { from: previousRoute, to: currentRoute },
  level: "info",
});

// User action breadcrumb
Sentry.addBreadcrumb({
  type: "user",
  category: "ui.click",
  message: `Clicked ${buttonName}`,
  level: "info",
  data: { component: "CheckoutForm", buttonId: "submit-order" },
});

// State change breadcrumb
Sentry.addBreadcrumb({
  category: "state",
  message: "Cart updated",
  level: "info",
  data: { itemCount: cart.items.length, total: cart.total },
});
```

### beforeBreadcrumb Hook

Filter or modify breadcrumbs before they're stored:

```typescript
Sentry.init({
  beforeBreadcrumb(breadcrumb, hint) {
    // Drop noisy console breadcrumbs
    if (breadcrumb.category === "console" && breadcrumb.level === "debug") {
      return null;
    }

    // Redact auth tokens from XHR breadcrumbs
    if (breadcrumb.category === "xhr" && breadcrumb.data?.url) {
      breadcrumb.data.url = breadcrumb.data.url.replace(
        /token=[^&]+/g,
        "token=[REDACTED]"
      );
    }

    // Enrich fetch breadcrumbs with response size
    if (breadcrumb.category === "fetch" && hint?.response) {
      breadcrumb.data = {
        ...breadcrumb.data,
        responseSize: hint.response.headers.get("content-length"),
      };
    }

    return breadcrumb;
  },
});
```

### Breadcrumb Limits and Pruning

- Default max breadcrumbs: 100 (configurable via `maxBreadcrumbs`)
- Oldest breadcrumbs are dropped when limit is reached (FIFO)
- Keep breadcrumbs focused — noisy breadcrumbs push out useful context

```typescript
Sentry.init({
  maxBreadcrumbs: 50, // Reduce if events are too large
});
```

---

## Transaction-Based Performance Monitoring

### Custom Transactions

Wrap business-critical operations in custom transactions when automatic
instrumentation doesn't cover them:

```typescript
// Start a manual transaction for a background job
Sentry.startSpan(
  { name: "process-batch-job", op: "queue.process", attributes: { batchSize: 100 } },
  async (span) => {
    for (const item of batch) {
      await Sentry.startSpan(
        { name: `process-item-${item.type}`, op: "queue.process.item" },
        async () => {
          await processItem(item);
        }
      );
    }
  }
);
```

```python
# Python: manual transaction
with sentry_sdk.start_transaction(op="queue.process", name="process-batch-job") as txn:
    txn.set_tag("batch_size", len(batch))
    for item in batch:
        with txn.start_child(op="queue.process.item", name=f"process-{item.type}"):
            process_item(item)
```

### Nested Spans

Create parent-child span relationships for detailed trace trees:

```typescript
Sentry.startSpan({ name: "checkout", op: "commerce" }, async () => {
  // Child spans automatically nest under the parent
  await Sentry.startSpan({ name: "validate-cart", op: "validation" }, async () => {
    await validateCart(cart);
  });

  await Sentry.startSpan({ name: "charge-payment", op: "payment" }, async () => {
    const result = await chargeCard(paymentInfo);

    // Grandchild span
    await Sentry.startSpan({ name: "save-receipt", op: "db" }, async () => {
      await saveReceipt(result);
    });
  });

  await Sentry.startSpan({ name: "send-confirmation", op: "email" }, async () => {
    await sendConfirmationEmail(order);
  });
});
```

### Distributed Tracing

Trace context propagates automatically across HTTP boundaries when SDKs
are configured. Ensure both services have Sentry initialized:

```typescript
// Service A — outgoing request (trace context auto-injected into headers)
Sentry.init({
  dsn: "...",
  tracesSampleRate: 1.0,
  tracePropagationTargets: ["api.internal.example.com", /^https:\/\/api\./],
});
// fetch("https://api.internal.example.com/process") — sentry-trace header added

// Service B — incoming request (trace context auto-extracted from headers)
Sentry.init({
  dsn: "...",  // Can be a different DSN / project
  tracesSampleRate: 1.0,
});
// Express/Fastify/etc. middleware auto-extracts sentry-trace header
```

### Trace Propagation Targets

Control which outgoing requests receive trace headers to avoid leaking
internal context to third-party services:

```typescript
Sentry.init({
  tracePropagationTargets: [
    "localhost",
    /^https:\/\/api\.mycompany\.com/,
    /^https:\/\/internal\./,
  ],
  // Requests to other domains will NOT receive sentry-trace headers
});
```

---

## Custom Measurements and Metrics

### Transaction Measurements

Attach numerical measurements to transactions for custom performance tracking:

```typescript
Sentry.startSpan({ name: "image-processing", op: "task" }, (span) => {
  const startMem = process.memoryUsage().heapUsed;
  const result = processImage(input);
  const endMem = process.memoryUsage().heapUsed;

  // Attach custom measurements to the current transaction
  Sentry.setMeasurement("image.file_size", input.size, "byte");
  Sentry.setMeasurement("image.processing_time", result.duration, "millisecond");
  Sentry.setMeasurement("image.memory_delta", endMem - startMem, "byte");
});
```

### Custom Metrics API

Sentry's metrics API provides counters, distributions, gauges, and sets
independent of transactions:

```typescript
// Counter — track occurrences
Sentry.metrics.increment("payment.attempted", 1, {
  tags: { gateway: "stripe", plan: "enterprise" },
});

// Distribution — track value distributions (histograms)
Sentry.metrics.distribution("image.render_time", renderTimeMs, {
  tags: { format: "webp" },
  unit: "millisecond",
});

// Gauge — track current values (last, min, max, sum, count)
Sentry.metrics.gauge("queue.depth", queueLength, {
  tags: { queue: "email" },
});

// Set — track unique values
Sentry.metrics.set("users.active", userId, {
  tags: { feature: "new-dashboard" },
});
```

```python
# Python metrics
from sentry_sdk import metrics

metrics.incr("payment.attempted", tags={"gateway": "stripe"})
metrics.distribution("image.render_time", render_time_ms, unit="millisecond")
metrics.gauge("queue.depth", queue_length)
metrics.set("users.active", user_id)
```

### Metric Aggregation Strategies

- **Counters**: Use for event rates, error counts, feature usage tracking
- **Distributions**: Use for latency percentiles, payload sizes, batch sizes
- **Gauges**: Use for queue depths, connection pool sizes, memory usage
- **Sets**: Use for unique user counts, unique error counts per window
- Tags on metrics are high-cardinality safe — Sentry aggregates server-side
- Metrics are independent of error/transaction quota — separate billing

---

## SDK Transport Customization

### Custom Transport

Replace the default HTTP transport for special network requirements:

```typescript
import * as Sentry from "@sentry/node";

function makeCustomTransport(options: Sentry.BaseTransportOptions) {
  // Use the default fetch-based transport as a base
  const transport = Sentry.makeFetchTransport(options);

  return {
    send: async (envelope: Sentry.Envelope) => {
      // Add custom headers, modify envelope, implement retry logic
      console.log(`Sending envelope with ${envelope[1].length} items`);
      return transport.send(envelope);
    },
    flush: (timeout?: number) => transport.flush(timeout),
  };
}

Sentry.init({
  dsn: "...",
  transport: makeCustomTransport,
});
```

### Offline Caching / Queuing

For mobile or unreliable network environments, buffer events and send when online:

```typescript
import * as Sentry from "@sentry/node";
import { makeFetchTransport } from "@sentry/node";

function makeOfflineTransport(options: Sentry.BaseTransportOptions) {
  const onlineTransport = makeFetchTransport(options);
  const queue: Sentry.Envelope[] = [];
  let isOnline = navigator.onLine;

  window.addEventListener("online", async () => {
    isOnline = true;
    while (queue.length > 0) {
      const envelope = queue.shift()!;
      await onlineTransport.send(envelope);
    }
  });

  window.addEventListener("offline", () => { isOnline = false; });

  return {
    send: async (envelope: Sentry.Envelope) => {
      if (isOnline) {
        return onlineTransport.send(envelope);
      }
      queue.push(envelope);
      return { statusCode: 200 }; // Pretend success, will retry
    },
    flush: (timeout?: number) => onlineTransport.flush(timeout),
  };
}
```

### Proxy and Tunnel Configuration

Route Sentry events through your own backend to avoid ad blockers and CORS:

```typescript
// Browser SDK — point to your tunnel endpoint
Sentry.init({
  dsn: "https://key@o123.ingest.sentry.io/456",
  tunnel: "/api/sentry-tunnel", // Your backend endpoint
});
```

```typescript
// Express tunnel endpoint
app.post("/api/sentry-tunnel", async (req, res) => {
  const envelope = req.body;
  const piece = envelope.split("\n")[0];
  const header = JSON.parse(piece);
  const dsn = new URL(header.dsn);
  const projectId = dsn.pathname.replace("/", "");

  // Validate the project ID is yours
  if (projectId !== "456") {
    return res.status(400).json({ error: "Invalid project" });
  }

  const upstream = `https://${dsn.hostname}/api/${projectId}/envelope/`;
  await fetch(upstream, {
    method: "POST",
    body: envelope,
    headers: { "Content-Type": "application/x-sentry-envelope" },
  });

  res.status(200).end();
});
```

---

## Sampling Strategies

### Error Sampling

By default, all errors are captured. Use `sampleRate` (0.0–1.0) to sample
errors if volume is too high. Prefer `beforeSend` filtering for selective drops.

```typescript
Sentry.init({
  sampleRate: 1.0, // Capture 100% of errors (default)
  beforeSend(event) {
    // Better approach: targeted filtering instead of random sampling
    if (isNonActionableError(event)) return null;
    return event;
  },
});
```

### Trace Sampling (tracesSampler)

Dynamic per-transaction sampling based on context:

```typescript
Sentry.init({
  tracesSampler(samplingContext) {
    const { name, attributes, parentSampled } = samplingContext;

    // Honor parent sampling decision for distributed traces
    if (parentSampled !== undefined) return parentSampled;

    // Never trace health checks and static assets
    if (name?.match(/\/(health|ready|live|favicon|static)/)) return 0;

    // Always trace payment flows
    if (name?.match(/\/api\/(payments|checkout|billing)/)) return 1.0;

    // High sample rate for auth flows
    if (name?.match(/\/api\/(auth|login|signup)/)) return 0.5;

    // Low rate for high-volume read endpoints
    if (name?.match(/\/api\/search/)) return 0.01;

    // Default
    return 0.1;
  },
});
```

### Profile Sampling

Profiling is sampled relative to traces — `profilesSampleRate` is the probability
that a sampled transaction also collects a profile.

```typescript
Sentry.init({
  tracesSampleRate: 0.2,       // 20% of requests create a transaction
  profilesSampleRate: 0.5,     // 50% of those transactions also profile
  // Effective profile rate: 0.2 * 0.5 = 10% of requests
});
```

### Replay Sampling

```typescript
Sentry.init({
  replaysSessionSampleRate: 0.1,  // 10% of all sessions get replays
  replaysOnErrorSampleRate: 1.0,  // 100% of sessions WITH errors get replays
});
```

### Dynamic / Adaptive Sampling

Use server-side dynamic sampling rules (Organization Settings → Dynamic Sampling)
to adjust rates without SDK redeployment:

- **Uniform rule**: Apply a base rate to all transactions
- **Custom rules**: Boost/reduce rate for specific environments, releases, or
  transaction names
- Rules are evaluated top-to-bottom; first match wins
- Changes take effect within minutes without app restart

---

## Session Tracking and Release Health

### How Sessions Work

Sessions are automatically tracked by most SDKs. A session represents a user's
interaction window and has three possible outcomes:

- **Healthy**: Session ended without any errors
- **Errored**: At least one handled error occurred during the session
- **Crashed**: An unhandled error / crash occurred
- **Abnormal**: Session didn't end properly (killed, OOM, network loss)

```typescript
// Browser: sessions tracked automatically with page lifecycle
// Node.js: must explicitly enable for server apps
Sentry.init({
  dsn: "...",
  release: "my-app@1.2.3",
  autoSessionTracking: true, // Default true for browser, configure for Node.js
});
```

### Crash-Free Rate

**Crash-Free Sessions** = (1 - crashed_sessions / total_sessions) × 100

- Monitor crash-free rate per release on the Releases dashboard
- Target: ≥99.5% for production apps, ≥99.9% for critical services
- Set up alert when crash-free rate drops below threshold

### Release Health Thresholds

Configure alerts on release health metrics:

```
Alert: Crash-free session rate < 99% for release in last 1 hour
Action: Notify #incidents Slack channel
Severity: Critical
```

### Adoption Tracking

Sentry tracks what percentage of your user base is on each release:

- **Adoption %**: Sessions on this release / total sessions
- Use to determine when it's safe to deprecate old versions
- Identify slow rollouts or stuck deployments
- Available via Releases API: `GET /api/0/organizations/{org}/releases/`

---

## Multi-Project and Multi-Org Patterns

### Micro-Frontend Sentry Setup

Each micro-frontend can report to its own Sentry project while sharing trace
context for distributed tracing:

```typescript
// Shell app
Sentry.init({
  dsn: "https://shell-key@sentry.io/shell-project",
  release: "shell@1.0.0",
  tracesSampleRate: 0.2,
  tracePropagationTargets: [/^https:\/\/app\.example\.com/],
});

// Micro-frontend A (loaded as module federation remote)
// Initialize with its own DSN but inherit trace context
const sentryA = Sentry.init({
  dsn: "https://mfe-a-key@sentry.io/mfe-a-project",
  release: "mfe-a@2.1.0",
  tracesSampleRate: 0.2,
});
```

### Monorepo Multi-Project

Map each package or service in a monorepo to a Sentry project.
Use `sentry-cli` with per-project configuration:

```bash
# .sentryclirc at repo root
[defaults]
org = my-org

# Per-service source map uploads in CI
# packages/api
sentry-cli releases --project api-service files "$VERSION" \
  upload-sourcemaps ./packages/api/dist

# packages/web
sentry-cli releases --project web-app files "$VERSION" \
  upload-sourcemaps ./packages/web/dist

# packages/worker
sentry-cli releases --project worker-service files "$VERSION" \
  upload-sourcemaps ./packages/worker/dist
```

In code, each service initializes with its own DSN and project:

```typescript
// packages/api/src/sentry.ts
Sentry.init({
  dsn: process.env.SENTRY_DSN_API,
  release: `api@${version}`,
  environment: process.env.NODE_ENV,
});
```

### Cross-Org Data Sharing

When separate teams or orgs need shared visibility:

- Use **Sentry's Discover** queries across projects within one org
- For cross-org: share issue links, or use the API to sync issue status
- Set up cross-project issue alerts that notify shared channels
- Use a shared `trace_id` tag to correlate events across orgs manually
- Consider a single org with team-scoped project access for simpler management

```typescript
// Add a shared correlation ID for cross-org tracing
Sentry.setTag("correlation_id", globalCorrelationId);
Sentry.setTag("upstream_org", "partner-org-slug");
```
