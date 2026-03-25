# Sentry Troubleshooting Guide

## Table of Contents

- [SDK Initialization Failures](#sdk-initialization-failures)
  - [DSN Validation Errors](#dsn-validation-errors)
  - [SDK Version Conflicts](#sdk-version-conflicts)
  - [Integration Load Failures](#integration-load-failures)
  - [Environment Variable Issues](#environment-variable-issues)
- [Source Map Upload Debugging](#source-map-upload-debugging)
  - [sentry-cli Authentication Failures](#sentry-cli-authentication-failures)
  - [Source Map Mismatch Errors](#source-map-mismatch-errors)
  - [URL Prefix Configuration](#url-prefix-configuration)
  - [Validating Uploaded Source Maps](#validating-uploaded-source-maps)
- [Missing or Incorrect Stack Traces](#missing-or-incorrect-stack-traces)
  - [Minified Stack Traces](#minified-stack-traces)
  - [Missing Frames in Node.js](#missing-frames-in-nodejs)
  - [Async Stack Trace Gaps](#async-stack-trace-gaps)
  - [Third-Party Script Errors](#third-party-script-errors)
- [High Cardinality Transaction Names](#high-cardinality-transaction-names)
  - [URL Parameterization](#url-parameterization)
  - [GraphQL Transaction Names](#graphql-transaction-names)
  - [Dynamic Route Normalization](#dynamic-route-normalization)
- [Rate Limiting and Quota Management](#rate-limiting-and-quota-management)
  - [Understanding Rate Limits](#understanding-rate-limits)
  - [Client-Side Rate Limiting](#client-side-rate-limiting)
  - [Quota Exhaustion Symptoms](#quota-exhaustion-symptoms)
  - [Spike Protection](#spike-protection)
- [CORS Issues with Browser SDK](#cors-issues-with-browser-sdk)
  - [Ad Blockers Blocking Sentry](#ad-blockers-blocking-sentry)
  - [CSP Headers Configuration](#csp-headers-configuration)
  - [Tunnel Endpoint Setup](#tunnel-endpoint-setup)
- [Webpack/Vite/esbuild Source Map Generation](#webpackviteesbuild-source-map-generation)
  - [Webpack Configuration](#webpack-configuration)
  - [Vite Configuration](#vite-configuration)
  - [esbuild Configuration](#esbuild-configuration)
  - [Next.js Source Maps](#nextjs-source-maps)
- [Docker/Containerized Deployment Gotchas](#dockercontainerized-deployment-gotchas)
  - [Missing sentry-cli in Container](#missing-sentry-cli-in-container)
  - [Multi-Stage Build Source Maps](#multi-stage-build-source-maps)
  - [Container Network Issues](#container-network-issues)
  - [Release Version from Container](#release-version-from-container)
- [Performance Monitoring Data Gaps](#performance-monitoring-data-gaps)
  - [Missing Transactions](#missing-transactions)
  - [Incomplete Distributed Traces](#incomplete-distributed-traces)
  - [Span Data Missing](#span-data-missing)
  - [High Latency Reporting Inaccuracies](#high-latency-reporting-inaccuracies)

---

## SDK Initialization Failures

### DSN Validation Errors

**Symptom**: Sentry silently fails, no events appear in dashboard.

**Diagnosis:**

```typescript
// 1. Verify DSN format
// Correct: https://<key>@<org>.ingest.sentry.io/<project-id>
// Correct (self-hosted): https://<key>@sentry.example.com/<project-id>

// 2. Enable debug mode to see initialization logs
Sentry.init({
  dsn: process.env.SENTRY_DSN,
  debug: true, // Logs to console — DISABLE in production
});

// 3. Test with a manual event
Sentry.captureMessage("Sentry test event");
```

**Common DSN problems:**
- DSN is `undefined` — env var not loaded at init time
- DSN has trailing whitespace — `SENTRY_DSN="https://...  "` (trim it)
- DSN uses wrong ingest domain — org slug changed, or self-hosted URL incorrect
- Client key has been revoked — regenerate in Project Settings → Client Keys

**Fix: Validate DSN before init:**

```typescript
const dsn = process.env.SENTRY_DSN;
if (!dsn || !dsn.startsWith("https://")) {
  console.error("Invalid or missing SENTRY_DSN");
} else {
  Sentry.init({ dsn });
}
```

### SDK Version Conflicts

**Symptom**: Runtime errors like `Cannot read property 'init' of undefined`,
`Sentry.X is not a function`, or duplicate events.

**Common causes:**
- Mixing `@sentry/node` v7 and v8 APIs (v8 removed `startTransaction`)
- Multiple Sentry SDK packages at different versions
- Both `@sentry/browser` and `@sentry/react` installed (use only one)

**Fix:**

```bash
# Check for version mismatches
npm ls @sentry/core @sentry/node @sentry/browser @sentry/react 2>/dev/null
pip show sentry-sdk 2>/dev/null

# Fix: pin all Sentry packages to same major version
npm install @sentry/node@latest @sentry/profiling-node@latest
# or
pip install --upgrade sentry-sdk
```

### Integration Load Failures

**Symptom**: `DidNotEnable` warning in Python, or missing auto-instrumentation.

```python
# Python: Integration fails silently if library not installed
# Enable debug to see which integrations loaded
sentry_sdk.init(dsn="...", debug=True)
# Look for: "Setting up integrations (with default = True)"
```

```typescript
// Node.js: check that integrations are listed
Sentry.init({
  dsn: "...",
  debug: true,
  // Log will show: "Integration installed: Http, Express, ..."
});
```

### Environment Variable Issues

**Symptom**: Sentry initializes but env/release are wrong or missing.

```bash
# Verify vars are set in the runtime environment
printenv | grep SENTRY

# Common problems:
# - .env file not loaded (dotenv not called before Sentry.init)
# - Docker build-time vs runtime args confused
# - Next.js: NEXT_PUBLIC_ prefix required for browser-side vars
# - Vite: VITE_ prefix required for client-side vars
```

**Fix order of initialization:**

```typescript
// WRONG — dotenv loads after Sentry.init
import * as Sentry from "@sentry/node";
Sentry.init({ dsn: process.env.SENTRY_DSN }); // undefined!
import "dotenv/config";

// CORRECT — dotenv loads first
import "dotenv/config";
import * as Sentry from "@sentry/node";
Sentry.init({ dsn: process.env.SENTRY_DSN }); // works
```

---

## Source Map Upload Debugging

### sentry-cli Authentication Failures

**Symptom**: `error: API request failed` or `401 Unauthorized` during upload.

```bash
# 1. Verify token is valid
sentry-cli info
# Should show your user info and org

# 2. Check token permissions
# Required scopes: project:releases, org:read
# Generate at: Settings → Auth Tokens → Create New Token

# 3. Test connectivity
sentry-cli projects list --org my-org
```

**Common fixes:**
- Token expired or revoked → regenerate
- Wrong `SENTRY_ORG` slug → check org slug in URL (not display name)
- Self-hosted: `SENTRY_URL` not set → `export SENTRY_URL=https://sentry.example.com`

### Source Map Mismatch Errors

**Symptom**: Stack traces show minified code despite uploading source maps.

**Debugging workflow:**

```bash
# 1. Check what's uploaded
sentry-cli releases files "$VERSION" list

# 2. Verify the file names match what the browser/server requests
# Browser loads: https://example.com/static/js/main.abc123.js
# Source map must be: ~/static/js/main.abc123.js (with ~/ prefix)

# 3. Validate source map content
sentry-cli sourcemaps explain --org my-org --project my-project <event-id>
# This command shows exactly why source maps failed for a specific event
```

### URL Prefix Configuration

The `--url-prefix` must match how the browser loads the file.

```bash
# If browser loads from: https://example.com/assets/js/app.js
# URL prefix should be: ~/assets/js/

# If files are at the root: https://example.com/app.js
# URL prefix should be: ~/

# If using a CDN: https://cdn.example.com/v1/app.js
# URL prefix should be: https://cdn.example.com/v1/

sentry-cli releases files "$VERSION" upload-sourcemaps ./dist \
  --url-prefix '~/assets/js/' \
  --validate
```

### Validating Uploaded Source Maps

```bash
# List all files in a release to verify
sentry-cli releases files "my-app@1.2.3" list

# Expected output should show pairs:
# ~/static/js/main.abc123.js         (source file)
# ~/static/js/main.abc123.js.map     (source map)

# Validate source maps are valid
sentry-cli sourcemaps validate ./dist

# Use explain command on a specific event
sentry-cli sourcemaps explain --org my-org --project my-proj EVENT_ID
```

---

## Missing or Incorrect Stack Traces

### Minified Stack Traces

**Symptom**: Stack frames show `e.a()` or `n(t)` instead of readable names.

**Causes:**
1. Source maps not uploaded for this release version
2. Release version mismatch between SDK and uploaded maps
3. URL prefix mismatch (see above)

**Debug:**

```typescript
// Verify the release matches in SDK
Sentry.init({
  release: "my-app@1.2.3", // Must exactly match sentry-cli release name
  debug: true,
});
```

```bash
# Verify release exists and has files
sentry-cli releases list
sentry-cli releases files "my-app@1.2.3" list
```

### Missing Frames in Node.js

**Symptom**: Stack trace only shows internal Node.js frames, not your code.

```typescript
// Ensure source map support is loaded
// For ts-node:
// tsconfig.json: { "compilerOptions": { "sourceMap": true } }

// For compiled TypeScript, upload the generated .js.map files
// and set release to match

// Common issue: Error.stackTraceLimit too low
Error.stackTraceLimit = 50; // Default is 10 in V8
```

### Async Stack Trace Gaps

**Symptom**: Stack trace starts at an event loop boundary with no caller context.

```typescript
// Node.js v16.13+: enable async stack traces
// --enable-source-maps flag helps with TS
// node --enable-source-maps dist/index.js

// Sentry automatically links async operations in v8+ SDK
// But if using manual promise chains, wrap them:
Sentry.startSpan({ name: "async-op", op: "task" }, async () => {
  await doAsyncWork(); // Span captures async context
});
```

### Third-Party Script Errors

**Symptom**: `Script error.` with no stack trace from cross-origin scripts.

```html
<!-- Fix: Add crossorigin attribute to script tags -->
<script src="https://cdn.example.com/lib.js" crossorigin="anonymous"></script>

<!-- Also configure CORS headers on the CDN -->
<!-- Access-Control-Allow-Origin: * -->
```

```typescript
// In Sentry, filter these non-actionable errors
Sentry.init({
  ignoreErrors: ["Script error.", "Script error"],
  denyUrls: [/^chrome-extension:\/\//, /^moz-extension:\/\//],
});
```

---

## High Cardinality Transaction Names

### URL Parameterization

**Symptom**: Thousands of unique transaction names like `/api/users/123`, `/api/users/456`.

```typescript
// Fix in beforeSendTransaction
Sentry.init({
  beforeSendTransaction(event) {
    // Replace UUID/numeric IDs with placeholders
    if (event.transaction) {
      event.transaction = event.transaction
        .replace(/\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "/:uuid")
        .replace(/\/\d+/g, "/:id");
    }
    return event;
  },
});
```

**Server-side fix**: Use transaction name rules in Project Settings → Performance.

### GraphQL Transaction Names

**Symptom**: All GraphQL requests show as `POST /graphql`.

```typescript
// Fix: use operation name as transaction name
Sentry.init({
  beforeSendTransaction(event) {
    if (event.transaction === "POST /graphql" && event.contexts?.graphql) {
      event.transaction = `GraphQL ${event.contexts.graphql.operationName}`;
    }
    return event;
  },
});

// Or in the GraphQL server middleware
app.use("/graphql", (req, res, next) => {
  const opName = req.body?.operationName || "anonymous";
  Sentry.getCurrentScope().setTransactionName(`GraphQL ${opName}`);
  next();
});
```

### Dynamic Route Normalization

```typescript
// Express: Sentry auto-parameterizes routes like /users/:id
// But custom middleware might bypass this — set manually:
app.use((req, res, next) => {
  // Express populates req.route after matching
  // Sentry reads this automatically via the Express integration
  next();
});

// For frameworks without auto-parameterization:
Sentry.getCurrentScope().setTransactionName("GET /api/users/:id");
```

---

## Rate Limiting and Quota Management

### Understanding Rate Limits

Sentry applies rate limits at multiple levels:
1. **Project DSN key rate limit**: Configurable per-key in Project Settings
2. **Org-level quota**: Based on your plan's event volume
3. **Server-side rate limiting**: 429 responses with `Retry-After` header

### Client-Side Rate Limiting

SDK handles 429 responses automatically — it will back off and retry.

```typescript
// Monitor dropped events
Sentry.init({
  beforeSend(event) {
    // This won't fire for rate-limited events — they're dropped by transport
    return event;
  },
});

// Use client reports to see how many events were dropped
// Check Organization Stats → Dropped Events in Sentry UI
```

### Quota Exhaustion Symptoms

- Events stop appearing in Sentry UI
- SDK logs `429 Too Many Requests` (visible with `debug: true`)
- `beforeSend` still fires but transport drops the event
- Organization Stats shows "Filtered" or "Rate Limited" events

**Fix:**
1. Increase quota (billing settings)
2. Enable spike protection (Organization Settings → Spike Protection)
3. Reduce `sampleRate` or `tracesSampleRate`
4. Add `beforeSend` filtering for non-actionable errors
5. Configure per-key rate limits to protect quota

### Spike Protection

Enable in Organization Settings → Spike Protection:
- Automatically detects event volume spikes
- Drops excess events to protect quota
- Notifies via email when activated
- Does NOT require SDK changes

---

## CORS Issues with Browser SDK

### Ad Blockers Blocking Sentry

**Symptom**: No events from some users; works fine without ad blockers.

Ad blockers commonly block requests to `*.ingest.sentry.io`. Solutions:

1. **Tunnel endpoint** (recommended):

```typescript
Sentry.init({
  dsn: "...",
  tunnel: "/api/sentry-tunnel", // Route through your server
});
```

2. **Custom transport via your domain** (alternative):

```typescript
// Use a reverse proxy: sentry.yourdomain.com → ingest.sentry.io
// Configure in your nginx/CDN config
```

### CSP Headers Configuration

If using Content-Security-Policy headers, allow Sentry domains:

```
Content-Security-Policy:
  connect-src 'self' *.ingest.sentry.io;
  script-src 'self' browser.sentry-cdn.com;
  worker-src 'self' blob:;
```

For Session Replay:

```
Content-Security-Policy:
  worker-src 'self' blob:;
  child-src 'self' blob:;
```

**Report URI for CSP violations to Sentry:**

```
Content-Security-Policy:
  ...; report-uri https://o123.ingest.sentry.io/api/456/security/?sentry_key=KEY
```

### Tunnel Endpoint Setup

Full tunnel implementation (Express):

```typescript
import express from "express";

const ALLOWED_SENTRY_HOSTS = ["o123.ingest.sentry.io"];

app.post("/api/sentry-tunnel", express.text({ type: "application/x-sentry-envelope" }), async (req, res) => {
  try {
    const envelope = req.body;
    const header = JSON.parse(envelope.split("\n")[0]);
    const dsnUrl = new URL(header.dsn);

    if (!ALLOWED_SENTRY_HOSTS.includes(dsnUrl.hostname)) {
      return res.status(400).json({ error: "Invalid DSN host" });
    }

    const projectId = dsnUrl.pathname.replace("/", "");
    const upstreamUrl = `https://${dsnUrl.hostname}/api/${projectId}/envelope/`;

    const response = await fetch(upstreamUrl, {
      method: "POST",
      body: envelope,
      headers: {
        "Content-Type": "application/x-sentry-envelope",
      },
    });

    res.status(response.status).end();
  } catch (e) {
    res.status(500).json({ error: "Tunnel error" });
  }
});
```

---

## Webpack/Vite/esbuild Source Map Generation

### Webpack Configuration

```javascript
// webpack.config.js
const { sentryWebpackPlugin } = require("@sentry/webpack-plugin");

module.exports = {
  devtool: "source-map", // MUST be 'source-map', NOT 'eval-source-map'
  plugins: [
    sentryWebpackPlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT,
      authToken: process.env.SENTRY_AUTH_TOKEN,
      release: { name: process.env.SENTRY_RELEASE },
      sourcemaps: {
        assets: "./dist/**/*.{js,map}",
        filesToDeleteAfterUpload: "./dist/**/*.map", // Remove from deploy
      },
    }),
  ],
};
```

**Common Webpack issues:**
- `devtool: "eval"` — does NOT produce uploadable source maps
- `devtool: "cheap-module-source-map"` — incomplete column info, less accurate
- `devtool: "hidden-source-map"` — produces maps but no `//# sourceMappingURL` (fine for Sentry, since maps are uploaded)

### Vite Configuration

```typescript
// vite.config.ts
import { sentryVitePlugin } from "@sentry/vite-plugin";

export default defineConfig({
  build: {
    sourcemap: true, // or "hidden" to omit sourceMappingURL comment
  },
  plugins: [
    sentryVitePlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT,
      authToken: process.env.SENTRY_AUTH_TOKEN,
      sourcemaps: {
        filesToDeleteAfterUpload: ["./dist/**/*.map"],
      },
    }),
  ],
});
```

### esbuild Configuration

```javascript
// esbuild.config.mjs
import { sentryEsbuildPlugin } from "@sentry/esbuild-plugin";
import esbuild from "esbuild";

await esbuild.build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  sourcemap: true,
  outdir: "dist",
  plugins: [
    sentryEsbuildPlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT,
      authToken: process.env.SENTRY_AUTH_TOKEN,
    }),
  ],
});
```

### Next.js Source Maps

```typescript
// next.config.mjs
import { withSentryConfig } from "@sentry/nextjs";

const nextConfig = {
  // Your Next.js config
};

export default withSentryConfig(nextConfig, {
  org: process.env.SENTRY_ORG,
  project: process.env.SENTRY_PROJECT,
  authToken: process.env.SENTRY_AUTH_TOKEN,
  silent: !process.env.CI, // Suppress logs locally
  hideSourceMaps: true,    // Delete maps after upload
  widenClientFileUpload: true, // Upload all client chunks
  disableLogger: true,     // Remove Sentry logger from bundle
});
```

**Next.js gotchas:**
- Must create `sentry.client.config.ts`, `sentry.server.config.ts`, and
  `sentry.edge.config.ts` — each runtime needs its own init
- `instrumentation.ts` is required for App Router server-side init (Next.js 13.4+)
- `NEXT_PUBLIC_SENTRY_DSN` for client, `SENTRY_DSN` for server
- `experimental.instrumentationHook = true` required in `next.config.mjs`

---

## Docker/Containerized Deployment Gotchas

### Missing sentry-cli in Container

```dockerfile
# Install sentry-cli in build stage
FROM node:20 AS build
RUN npm install -g @sentry/cli
# or
RUN curl -sL https://sentry.io/get-cli/ | bash

# Upload source maps during build
ARG SENTRY_AUTH_TOKEN
ARG SENTRY_RELEASE
RUN npm run build
RUN sentry-cli releases files "$SENTRY_RELEASE" upload-sourcemaps ./dist \
    --url-prefix '~/' --validate
```

### Multi-Stage Build Source Maps

**Problem**: Source maps generated in build stage aren't available in final stage.

```dockerfile
# Build stage
FROM node:20 AS build
WORKDIR /app
COPY . .
RUN npm ci && npm run build

# Upload source maps BEFORE copying to production image
ARG SENTRY_AUTH_TOKEN
ARG SENTRY_ORG
ARG SENTRY_PROJECT
ARG SENTRY_RELEASE
RUN npx @sentry/cli releases files "$SENTRY_RELEASE" upload-sourcemaps ./dist \
    --url-prefix '~/'

# Production stage — no source maps needed (they're in Sentry)
FROM node:20-slim AS production
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
# Delete .map files from production image
RUN find ./dist -name "*.map" -delete
```

### Container Network Issues

**Symptom**: Events not reaching Sentry from containers.

```bash
# Test connectivity from inside container
docker exec -it myapp curl -v https://o123.ingest.sentry.io/api/456/envelope/

# Common fixes:
# 1. DNS resolution — ensure container can resolve sentry.io
# 2. Proxy — set HTTP_PROXY/HTTPS_PROXY env vars
# 3. Self-hosted: ensure Sentry containers are on same Docker network
# 4. Firewall: allow outbound HTTPS (port 443) to sentry.io
```

For self-hosted Sentry in Docker:

```yaml
# docker-compose.override.yml
services:
  my-app:
    networks:
      - sentry-network
    environment:
      SENTRY_DSN: http://key@sentry-web:9000/1  # Use Docker service name
```

### Release Version from Container

```dockerfile
# Pass git SHA as build arg
ARG GIT_SHA
ENV SENTRY_RELEASE=${GIT_SHA}

# Or read from a file baked into the image
COPY .git-sha /app/.git-sha
```

```typescript
import { readFileSync } from "fs";

Sentry.init({
  release: process.env.SENTRY_RELEASE ||
    readFileSync("/app/.git-sha", "utf-8").trim(),
});
```

---

## Performance Monitoring Data Gaps

### Missing Transactions

**Symptom**: Some requests don't appear in Performance dashboard.

**Possible causes:**
1. `tracesSampleRate` is too low — increase for debugging
2. `tracesSampler` returns 0 for certain paths
3. Transaction dropped by `beforeSendTransaction`
4. Quota exhausted — check Organization Stats
5. Framework integration not installed — check `debug: true` output

```typescript
// Temporarily set to 1.0 to verify all transactions appear
Sentry.init({
  tracesSampleRate: 1.0, // For debugging only
  debug: true,
});
```

### Incomplete Distributed Traces

**Symptom**: Trace shows gaps between services, child spans appear as separate traces.

**Causes:**
1. `tracePropagationTargets` doesn't include the downstream service URL
2. Downstream service SDK not initialized with tracing enabled
3. Proxy strips `sentry-trace` and `baggage` headers
4. CORS preflight doesn't expose trace headers

```typescript
// Fix: ensure both services have matching config
// Service A (caller)
Sentry.init({
  tracesSampleRate: 1.0,
  tracePropagationTargets: [
    "localhost",
    /^https:\/\/api\.internal\.example\.com/,
  ],
});

// Service B (callee) — must also have tracing enabled
Sentry.init({
  tracesSampleRate: 1.0,
  // Express/Fastify integration auto-extracts sentry-trace header
});
```

```nginx
# Fix: don't strip Sentry headers in reverse proxy
proxy_pass_header sentry-trace;
proxy_pass_header baggage;
# Or explicitly pass them:
proxy_set_header sentry-trace $http_sentry_trace;
proxy_set_header baggage $http_baggage;
```

### Span Data Missing

**Symptom**: Transaction appears but child spans are empty or incomplete.

```typescript
// Ensure spans are properly ended
const span = Sentry.startInactiveSpan({ name: "db-query", op: "db" });
try {
  const result = await query();
  span.setStatus({ code: 1, message: "ok" });
  return result;
} catch (error) {
  span.setStatus({ code: 2, message: "internal_error" });
  throw error;
} finally {
  span.end(); // MUST call end() or span is dropped
}

// Auto-instrumented spans: ensure integrations are active
// Check debug output for: "Integration installed: Http, Express, ..."
```

### High Latency Reporting Inaccuracies

**Symptom**: Transaction duration doesn't match actual request time.

**Causes:**
1. Clock skew between services in distributed traces
2. Long-running spans not properly ended (open spans extend duration)
3. `idle` transaction timeout too long (browser SDK)

```typescript
// Browser: configure idle transaction timeout
Sentry.init({
  integrations: [
    Sentry.browserTracingIntegration({
      idleTimeout: 1000,     // Finish transaction 1s after last span
      finalTimeout: 30000,   // Hard cutoff at 30s
    }),
  ],
});

// Server: ensure all spans are ended
// Use try/finally pattern to guarantee span.end() is called
```
