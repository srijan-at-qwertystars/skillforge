# Netlify Advanced Patterns

## Table of Contents

- [Edge Functions Patterns](#edge-functions-patterns)
  - [Geolocation](#geolocation)
  - [Authentication at the Edge](#authentication-at-the-edge)
  - [Personalization](#personalization)
  - [Response Transforms](#response-transforms)
  - [Rate Limiting](#rate-limiting)
- [Scheduled and Background Functions](#scheduled-and-background-functions)
  - [Scheduled Function Patterns](#scheduled-function-patterns)
  - [Background Function Patterns](#background-function-patterns)
  - [Chaining Functions](#chaining-functions)
- [Netlify Graph and API Connections](#netlify-graph-and-api-connections)
- [Build Plugins Development](#build-plugins-development)
  - [Plugin Lifecycle Hooks](#plugin-lifecycle-hooks)
  - [Custom Plugin Template](#custom-plugin-template)
  - [Plugin Utilities](#plugin-utilities)
  - [Publishing Plugins](#publishing-plugins)
- [Deploy Notifications and Hooks](#deploy-notifications-and-hooks)
  - [Deploy Hooks (Incoming)](#deploy-hooks-incoming)
  - [Outgoing Notifications](#outgoing-notifications)
  - [Deploy Events in Functions](#deploy-events-in-functions)
- [Large Media Handling](#large-media-handling)
- [Netlify Connect (Data Layer)](#netlify-connect-data-layer)
- [Split Testing Strategies](#split-testing-strategies)
  - [Branch-Based Split Testing](#branch-based-split-testing)
  - [Edge Function A/B Testing](#edge-function-ab-testing)
  - [Feature Flags with Edge Functions](#feature-flags-with-edge-functions)
- [Enterprise Features](#enterprise-features)

---

## Edge Functions Patterns

Edge Functions run on Deno at the CDN edge (globally distributed). They execute
before or after the origin response and use Web Standard APIs.

### Geolocation

```typescript
// netlify/edge-functions/geo-redirect.ts
import type { Context } from "@netlify/edge-functions";

export default async (request: Request, context: Context) => {
  const { country, city, subdivision, latitude, longitude, timezone } = context.geo;

  // Redirect to country-specific subdomain
  if (country?.code === "DE") {
    return Response.redirect("https://de.example.com" + new URL(request.url).pathname, 302);
  }

  // Inject geo data as headers for downstream consumption
  const response = await context.next();
  const cloned = new Response(response.body, response);
  cloned.headers.set("x-geo-country", country?.code || "unknown");
  cloned.headers.set("x-geo-city", city || "unknown");
  cloned.headers.set("x-geo-timezone", timezone || "UTC");
  return cloned;
};

export const config = { path: "/*" };
```

#### Geo-Based Content Injection

```typescript
// netlify/edge-functions/geo-content.ts
import type { Context } from "@netlify/edge-functions";

const CURRENCY_MAP: Record<string, { symbol: string; code: string }> = {
  US: { symbol: "$", code: "USD" },
  GB: { symbol: "£", code: "GBP" },
  EU: { symbol: "€", code: "EUR" },
  JP: { symbol: "¥", code: "JPY" },
};

export default async (request: Request, context: Context) => {
  const country = context.geo.country?.code || "US";
  const currency = CURRENCY_MAP[country] || CURRENCY_MAP["US"];

  const response = await context.next();
  const html = await response.text();

  return new Response(
    html
      .replace("{{CURRENCY_SYMBOL}}", currency.symbol)
      .replace("{{CURRENCY_CODE}}", currency.code)
      .replace("{{COUNTRY_CODE}}", country),
    { headers: response.headers }
  );
};

export const config = { path: "/shop/*" };
```

### Authentication at the Edge

```typescript
// netlify/edge-functions/auth-guard.ts
import type { Context } from "@netlify/edge-functions";
import { jwtVerify, importSPKI } from "jose";

const PUBLIC_KEY = Netlify.env.get("JWT_PUBLIC_KEY") || "";

export default async (request: Request, context: Context) => {
  const token = request.headers.get("authorization")?.replace("Bearer ", "");

  if (!token) {
    return new Response(JSON.stringify({ error: "No token provided" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const key = await importSPKI(PUBLIC_KEY, "RS256");
    const { payload } = await jwtVerify(token, key);

    // Inject user info as headers for downstream functions
    const headers = new Headers(request.headers);
    headers.set("x-user-id", payload.sub || "");
    headers.set("x-user-role", (payload.role as string) || "user");

    const modifiedRequest = new Request(request.url, {
      method: request.method,
      headers,
      body: request.body,
    });

    return context.next(modifiedRequest);
  } catch {
    return new Response(JSON.stringify({ error: "Invalid token" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }
};

export const config = { path: "/api/protected/*" };
```

#### Cookie-Based Session Auth

```typescript
// netlify/edge-functions/session-auth.ts
import type { Context } from "@netlify/edge-functions";

export default async (request: Request, context: Context) => {
  const cookies = request.headers.get("cookie") || "";
  const sessionId = cookies.match(/session_id=([^;]+)/)?.[1];

  if (!sessionId) {
    return Response.redirect(new URL("/login", request.url).toString(), 302);
  }

  // Verify session against KV store or external API
  const sessionValid = await verifySession(sessionId);
  if (!sessionValid) {
    return new Response("Session expired", {
      status: 302,
      headers: {
        Location: "/login",
        "Set-Cookie": "session_id=; Path=/; Max-Age=0",
      },
    });
  }

  return context.next();
};

async function verifySession(id: string): Promise<boolean> {
  const resp = await fetch(`${Netlify.env.get("AUTH_API")}/sessions/${id}`);
  return resp.ok;
}

export const config = { path: "/dashboard/*" };
```

### Personalization

```typescript
// netlify/edge-functions/personalize.ts
import type { Context } from "@netlify/edge-functions";

interface UserSegment {
  variant: string;
  features: string[];
}

function getUserSegment(request: Request, context: Context): UserSegment {
  const cookies = request.headers.get("cookie") || "";
  const returningUser = cookies.includes("visited=true");
  const country = context.geo.country?.code || "US";
  const isEU = ["DE", "FR", "IT", "ES", "NL", "BE", "AT", "PT", "IE"].includes(country);

  if (isEU) return { variant: "eu", features: ["gdpr-banner", "eu-pricing"] };
  if (returningUser) return { variant: "returning", features: ["welcome-back", "recommendations"] };
  return { variant: "new", features: ["onboarding", "trial-offer"] };
}

export default async (request: Request, context: Context) => {
  const segment = getUserSegment(request, context);
  const response = await context.next();
  const html = await response.text();

  const personalized = html
    .replace("{{USER_SEGMENT}}", segment.variant)
    .replace("{{FEATURES}}", JSON.stringify(segment.features));

  return new Response(personalized, {
    headers: {
      ...Object.fromEntries(response.headers),
      "Set-Cookie": "visited=true; Path=/; Max-Age=2592000",
      "x-segment": segment.variant,
    },
  });
};

export const config = { path: "/" };
```

### Response Transforms

```typescript
// netlify/edge-functions/html-transform.ts
import type { Context } from "@netlify/edge-functions";
import { HTMLRewriter } from "https://ghuc.cc/nickytonline/deno-html-rewriter/index.ts";

export default async (request: Request, context: Context) => {
  const response = await context.next();
  const contentType = response.headers.get("content-type") || "";

  if (!contentType.includes("text/html")) return response;

  // Inject analytics snippet before </head>
  return new HTMLRewriter()
    .on("head", {
      element(element) {
        element.append(
          `<script defer src="https://analytics.example.com/script.js"></script>`,
          { html: true }
        );
      },
    })
    .on('img[loading="lazy"]', {
      element(element) {
        // Add LQIP data attribute
        const src = element.getAttribute("src");
        if (src) element.setAttribute("data-full-src", src);
      },
    })
    .transform(response);
};

export const config = { path: "/*", excludedPath: ["/api/*", "/_next/*"] };
```

### Rate Limiting

```typescript
// netlify/edge-functions/rate-limit.ts
import type { Context } from "@netlify/edge-functions";

// In-memory store (per-edge-node, resets on deploy)
const requestCounts = new Map<string, { count: number; resetAt: number }>();

const WINDOW_MS = 60_000; // 1 minute
const MAX_REQUESTS = 60;

export default async (request: Request, context: Context) => {
  const ip = context.ip;
  const now = Date.now();
  const entry = requestCounts.get(ip);

  if (!entry || now > entry.resetAt) {
    requestCounts.set(ip, { count: 1, resetAt: now + WINDOW_MS });
  } else {
    entry.count++;
    if (entry.count > MAX_REQUESTS) {
      return new Response("Too Many Requests", {
        status: 429,
        headers: {
          "Retry-After": String(Math.ceil((entry.resetAt - now) / 1000)),
          "X-RateLimit-Limit": String(MAX_REQUESTS),
          "X-RateLimit-Remaining": "0",
        },
      });
    }
  }

  const response = await context.next();
  const remaining = MAX_REQUESTS - (requestCounts.get(ip)?.count || 0);
  response.headers.set("X-RateLimit-Limit", String(MAX_REQUESTS));
  response.headers.set("X-RateLimit-Remaining", String(Math.max(0, remaining)));
  return response;
};

export const config = { path: "/api/*" };
```

---

## Scheduled and Background Functions

### Scheduled Function Patterns

```typescript
// netlify/functions/cache-warmup.ts
import { schedule } from "@netlify/functions";

// Run every 6 hours to warm caches
export const handler = schedule("0 */6 * * *", async (event) => {
  const urls = ["/", "/products", "/about", "/blog"];
  const siteUrl = process.env.URL || "https://example.netlify.app";

  const results = await Promise.allSettled(
    urls.map((path) => fetch(`${siteUrl}${path}`))
  );

  const failed = results.filter((r) => r.status === "rejected");
  if (failed.length > 0) {
    console.error(`Failed to warm ${failed.length} URLs`);
  }

  return { statusCode: 200 };
});
```

```typescript
// netlify/functions/stale-data-cleanup.ts
import { schedule } from "@netlify/functions";

// Every day at 3 AM UTC — clean up expired entries
export const handler = schedule("0 3 * * *", async () => {
  const response = await fetch(`${process.env.API_URL}/admin/cleanup`, {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.ADMIN_TOKEN}` },
  });

  if (!response.ok) {
    console.error("Cleanup failed:", await response.text());
  }

  return { statusCode: response.ok ? 200 : 500 };
});
```

### Background Function Patterns

Background functions return 202 immediately. They run up to 15 minutes (Pro+).

```typescript
// netlify/functions/generate-report-background.ts
import type { Handler } from "@netlify/functions";

export const handler: Handler = async (event) => {
  const { reportType, dateRange, email } = JSON.parse(event.body || "{}");

  // Fetch data from multiple sources
  const [sales, users, analytics] = await Promise.all([
    fetchSalesData(dateRange),
    fetchUserData(dateRange),
    fetchAnalytics(dateRange),
  ]);

  // Generate and upload report
  const report = buildReport(reportType, { sales, users, analytics });
  await uploadToS3(report);

  // Notify user
  await sendEmail(email, "Your report is ready", report.downloadUrl);

  return { statusCode: 200, body: "" }; // Response ignored by Netlify
};

// Invoke from another function or client:
// POST /.netlify/functions/generate-report-background
// Body: { "reportType": "monthly", "dateRange": "2024-01", "email": "..." }
```

### Chaining Functions

```typescript
// netlify/functions/webhook-receiver.ts — receives webhook, triggers background
import type { Handler } from "@netlify/functions";

export const handler: Handler = async (event) => {
  const payload = JSON.parse(event.body || "{}");

  // Validate webhook signature
  const signature = event.headers["x-webhook-signature"];
  if (!verifySignature(payload, signature)) {
    return { statusCode: 401, body: "Invalid signature" };
  }

  // Trigger background function for heavy processing
  const siteUrl = process.env.URL || "";
  await fetch(`${siteUrl}/.netlify/functions/process-webhook-background`, {
    method: "POST",
    body: JSON.stringify(payload),
    headers: { "Content-Type": "application/json" },
  });

  // Return 200 immediately to webhook sender
  return { statusCode: 200, body: JSON.stringify({ received: true }) };
};
```

---

## Netlify Graph and API Connections

Netlify Graph provides a unified GraphQL layer to connect third-party APIs
(GitHub, Stripe, Salesforce, etc.) through the Netlify dashboard. It handles
OAuth tokens and provides auto-generated query helpers.

```typescript
// Using auto-generated Netlify Graph handlers
import NetlifyGraph from "./netlifyGraph";

export const handler = async (event, context) => {
  const { errors, data } = await NetlifyGraph.fetchGitHubUserRepos(
    { username: "octocat" },
    { accessToken: context.clientContext?.identity?.token }
  );

  if (errors) {
    return { statusCode: 500, body: JSON.stringify(errors) };
  }

  return { statusCode: 200, body: JSON.stringify(data) };
};
```

### Manual API Authentication Pattern

When Netlify Graph doesn't cover your API, manage tokens manually:

```typescript
// netlify/functions/stripe-webhook.ts
import type { Handler } from "@netlify/functions";
import Stripe from "stripe";

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, { apiVersion: "2023-10-16" });

export const handler: Handler = async (event) => {
  const sig = event.headers["stripe-signature"]!;
  let stripeEvent: Stripe.Event;

  try {
    stripeEvent = stripe.webhooks.constructEvent(
      event.body!,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET!
    );
  } catch (err) {
    return { statusCode: 400, body: `Webhook Error: ${(err as Error).message}` };
  }

  switch (stripeEvent.type) {
    case "checkout.session.completed":
      await handleCheckoutCompleted(stripeEvent.data.object);
      break;
    case "invoice.payment_failed":
      await handlePaymentFailed(stripeEvent.data.object);
      break;
  }

  return { statusCode: 200, body: JSON.stringify({ received: true }) };
};
```

---

## Build Plugins Development

### Plugin Lifecycle Hooks

Hooks execute in this order:

1. `onPreBuild` — Before build command runs
2. `onBuild` — During build (after build command)
3. `onPostBuild` — After build, before deploy
4. `onSuccess` — After successful deploy
5. `onError` — On build failure
6. `onEnd` — Always runs (finally)

### Custom Plugin Template

```javascript
// plugins/my-plugin/index.js
module.exports = {
  onPreBuild: async ({ inputs, utils, constants, netlifyConfig }) => {
    // inputs: values from netlify.toml [plugins.inputs]
    // utils: build helpers (status, cache, run, functions)
    // constants: PUBLISH_DIR, FUNCTIONS_SRC, etc.
    // netlifyConfig: mutable netlify config

    console.log(`Building to: ${constants.PUBLISH_DIR}`);
    console.log(`Plugin input: ${inputs.myOption}`);

    // Cache node_modules across builds
    const success = await utils.cache.restore("./node_modules");
    if (success) {
      console.log("Cache restored");
    }
  },

  onBuild: async ({ utils }) => {
    // Run shell command
    await utils.run("echo", ["Build step"]);

    // Run with options
    await utils.run("npm", ["run", "generate-data"], {
      cwd: "./scripts",
      env: { CUSTOM_VAR: "value" },
    });
  },

  onPostBuild: async ({ utils, constants }) => {
    // Validate build output
    const fs = require("fs");
    const indexPath = `${constants.PUBLISH_DIR}/index.html`;

    if (!fs.existsSync(indexPath)) {
      utils.build.failBuild("Missing index.html in publish directory");
    }

    // Save cache for next build
    await utils.cache.save("./node_modules");
  },

  onSuccess: async ({ utils }) => {
    // Post-deploy actions (e.g., purge CDN, notify)
    utils.status.show({
      title: "Deploy successful",
      summary: "All checks passed",
      text: "Site is live!",
    });
  },

  onError: async ({ utils, error }) => {
    console.error("Build failed:", error.message);
    // Send alert to Slack, PagerDuty, etc.
  },

  onEnd: async () => {
    // Cleanup — always runs
  },
};

// plugins/my-plugin/manifest.yml
// name: my-plugin
// inputs:
//   - name: myOption
//     description: An example input
//     required: false
//     default: "hello"
```

### Plugin Utilities

| Utility | Method | Purpose |
|---------|--------|---------|
| Build | `utils.build.failBuild(msg)` | Fail the build |
| Build | `utils.build.failPlugin(msg)` | Fail the plugin only |
| Build | `utils.build.cancelBuild(msg)` | Cancel the build |
| Status | `utils.status.show({title, summary, text})` | Show status in UI |
| Cache | `utils.cache.save(paths)` | Save files to build cache |
| Cache | `utils.cache.restore(paths)` | Restore cached files |
| Cache | `utils.cache.remove(paths)` | Remove cached files |
| Cache | `utils.cache.has(path)` | Check if cached |
| Cache | `utils.cache.list()` | List cached paths |
| Run | `utils.run(cmd, args, opts)` | Run shell commands |
| Functions | `utils.functions.add(path)` | Inject functions |
| Git | `utils.git.fileMatch(pattern)` | Match changed files |
| Git | `utils.git.modifiedFiles` | List modified files |
| Git | `utils.git.createdFiles` | List created files |
| Git | `utils.git.deletedFiles` | List deleted files |

### Publishing Plugins

```bash
# plugins/my-plugin/package.json
{
  "name": "netlify-plugin-my-plugin",
  "version": "1.0.0",
  "main": "index.js",
  "keywords": ["netlify", "netlify-plugin"]
}

# Publish to npm, then submit to Netlify Plugin Directory
npm publish
# Visit https://app.netlify.com/plugins to submit
```

---

## Deploy Notifications and Hooks

### Deploy Hooks (Incoming)

Deploy hooks trigger builds via POST request. Create in Site Settings > Build & deploy > Build hooks.

```bash
# Trigger a build from CI, webhook, or script
curl -X POST https://api.netlify.com/build_hooks/YOUR_HOOK_ID

# Trigger with a specific branch
curl -X POST https://api.netlify.com/build_hooks/YOUR_HOOK_ID?trigger_branch=staging

# Trigger with custom title (appears in deploy log)
curl -X POST -d '{}' \
  -H "Content-Type: application/json" \
  "https://api.netlify.com/build_hooks/YOUR_HOOK_ID?trigger_title=CMS+publish"
```

### Outgoing Notifications

Configure in Site Settings > Build & deploy > Deploy notifications:

| Event | Trigger |
|-------|---------|
| Deploy started | Build begins |
| Deploy succeeded | Successful production deploy |
| Deploy failed | Build/deploy error |
| Deploy request pending | Deploy preview created |
| Deploy request accepted | Deploy preview merged |

Notification targets: Slack webhook, Email, generic HTTP POST.

### Deploy Events in Functions

```typescript
// netlify/functions/deploy-succeeded.ts
// Netlify auto-triggers functions named after deploy events
import type { Handler } from "@netlify/functions";

export const handler: Handler = async (event) => {
  const payload = JSON.parse(event.body || "{}");
  const { id, url, branch, deploy_time, published_at } = payload;

  // Notify Slack on deploy
  await fetch(process.env.SLACK_WEBHOOK_URL!, {
    method: "POST",
    body: JSON.stringify({
      text: `✅ Deploy succeeded!\nURL: ${url}\nBranch: ${branch}\nDeploy time: ${deploy_time}s`,
    }),
  });

  return { statusCode: 200, body: "" };
};
// Also: deploy-building.ts, deploy-failed.ts
```

---

## Large Media Handling

Netlify Large Media uses Git LFS to handle large files (images, videos, PDFs).

```bash
# Setup
netlify lm:setup
git lfs track "*.jpg" "*.png" "*.gif" "*.mp4" "*.pdf"
git add .lfsconfig .gitattributes
git commit -m "Setup Netlify Large Media"
git push

# Image transformations via URL parameters (no build step)
# Original:  /images/hero.jpg
# Resized:   /images/hero.jpg?nf_resize=fit&w=800&h=600
# Cropped:   /images/hero.jpg?nf_resize=smartcrop&w=400&h=400
```

Transformation parameters:
- `nf_resize=fit` — Fit within dimensions, maintain aspect ratio
- `nf_resize=smartcrop` — Crop to exact dimensions, focus on subject
- `w=WIDTH` — Target width
- `h=HEIGHT` — Target height

---

## Netlify Connect (Data Layer)

Netlify Connect provides a unified data layer that syncs content from multiple
sources (CMS, databases, APIs) into a single GraphQL API.

### Configuration

```yaml
# netlify-connect.yaml
data_sources:
  - name: contentful
    type: contentful
    space_id: ${CONTENTFUL_SPACE_ID}
    access_token: ${CONTENTFUL_ACCESS_TOKEN}
    content_types:
      - blogPost
      - author
      - category

  - name: shopify
    type: shopify
    store_url: ${SHOPIFY_STORE_URL}
    access_token: ${SHOPIFY_ACCESS_TOKEN}

  - name: custom_api
    type: rest
    base_url: https://api.example.com
    endpoints:
      - path: /products
        name: products
        schedule: "*/15 * * * *"  # sync every 15 min
```

### Querying the Data Layer

```typescript
// In your framework data-fetching layer
const response = await fetch(process.env.NETLIFY_CONNECT_URL!, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    Authorization: `Bearer ${process.env.NETLIFY_CONNECT_TOKEN}`,
  },
  body: JSON.stringify({
    query: `
      query {
        allBlogPost(sort: { publishedAt: DESC }, limit: 10) {
          nodes {
            title
            slug
            author { name }
            publishedAt
          }
        }
      }
    `,
  }),
});
```

---

## Split Testing Strategies

### Branch-Based Split Testing

Netlify's built-in split testing routes traffic between branches.

1. Create branches with different implementations
2. Enable in Site Settings > Split Testing
3. Assign traffic percentages to each branch
4. Netlify uses cookies for sticky sessions (`nf_ab` cookie)

Limitations: requires separate branches, not ideal for small changes.

### Edge Function A/B Testing

More flexible — test within a single branch:

```typescript
// netlify/edge-functions/ab-test.ts
import type { Context } from "@netlify/edge-functions";

interface Experiment {
  name: string;
  variants: { id: string; weight: number }[];
}

const experiments: Experiment[] = [
  {
    name: "hero-cta",
    variants: [
      { id: "control", weight: 50 },
      { id: "variant-a", weight: 25 },
      { id: "variant-b", weight: 25 },
    ],
  },
];

function selectVariant(experiment: Experiment, existingVariant?: string): string {
  if (existingVariant && experiment.variants.some((v) => v.id === existingVariant)) {
    return existingVariant;
  }
  const rand = Math.random() * 100;
  let cumulative = 0;
  for (const v of experiment.variants) {
    cumulative += v.weight;
    if (rand < cumulative) return v.id;
  }
  return experiment.variants[0].id;
}

export default async (request: Request, context: Context) => {
  const cookies = request.headers.get("cookie") || "";
  const response = await context.next();
  const html = await response.text();
  const setCookies: string[] = [];
  let result = html;

  for (const exp of experiments) {
    const cookieMatch = cookies.match(new RegExp(`exp_${exp.name}=([^;]+)`));
    const variant = selectVariant(exp, cookieMatch?.[1]);
    result = result.replace(`{{EXP_${exp.name.toUpperCase().replace(/-/g, "_")}}}`, variant);
    if (!cookieMatch) {
      setCookies.push(`exp_${exp.name}=${variant}; Path=/; Max-Age=2592000; SameSite=Lax`);
    }
  }

  const headers = new Headers(response.headers);
  setCookies.forEach((c) => headers.append("Set-Cookie", c));
  return new Response(result, { status: response.status, headers });
};

export const config = { path: "/*" };
```

### Feature Flags with Edge Functions

```typescript
// netlify/edge-functions/feature-flags.ts
import type { Context } from "@netlify/edge-functions";

const FLAGS: Record<string, { enabled: boolean; rolloutPercent: number }> = {
  "new-checkout": { enabled: true, rolloutPercent: 25 },
  "dark-mode": { enabled: true, rolloutPercent: 100 },
  "beta-search": { enabled: false, rolloutPercent: 0 },
};

function evaluateFlags(userId: string): Record<string, boolean> {
  const result: Record<string, boolean> = {};
  for (const [flag, config] of Object.entries(FLAGS)) {
    if (!config.enabled) {
      result[flag] = false;
      continue;
    }
    // Deterministic hash for consistent assignment
    const hash = Array.from(userId + flag).reduce((h, c) => (h * 31 + c.charCodeAt(0)) | 0, 0);
    result[flag] = Math.abs(hash % 100) < config.rolloutPercent;
  }
  return result;
}

export default async (request: Request, context: Context) => {
  const cookies = request.headers.get("cookie") || "";
  const userId = cookies.match(/uid=([^;]+)/)?.[1] || context.ip;
  const flags = evaluateFlags(userId);

  const response = await context.next();
  const html = await response.text();

  return new Response(
    html.replace(
      "</head>",
      `<script>window.__FF=${JSON.stringify(flags)}</script></head>`
    ),
    { headers: response.headers }
  );
};

export const config = { path: "/*" };
```

---

## Enterprise Features

### SSO / SAML

Enterprise plans support SAML SSO. Configure in Team Settings > Identity Providers:

- Okta, Azure AD, OneLogin, PingFederate, generic SAML 2.0
- SCIM provisioning for automated user management
- Role mapping from IdP groups to Netlify roles

### Audit Logs

Enterprise audit logs track all team activity:

```bash
# API access to audit logs
curl -H "Authorization: Bearer $NETLIFY_TOKEN" \
  "https://api.netlify.com/api/v1/accounts/{account_slug}/audit?per_page=100"
```

Events logged: deploys, site settings changes, team member changes, environment
variable modifications, DNS changes, build plugin installations.

### High-Performance Edge

Enterprise features include:
- **High-Performance Edge**: Guaranteed edge node capacity
- **Log Drains**: Stream build/function logs to Datadog, Splunk, S3
- **DDoS Protection**: Enterprise-grade traffic scrubbing
- **SLA**: 99.99% uptime guarantee
- **Priority Support**: Dedicated support engineer
- **IP Allowlisting**: Restrict dashboard access to corporate IPs

### Log Drains Configuration

```bash
# Configure log drain via API
curl -X POST \
  -H "Authorization: Bearer $NETLIFY_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.netlify.com/api/v1/accounts/{account_slug}/log_drains" \
  -d '{
    "destination": "datadog",
    "log_type": "traffic",
    "config": {
      "api_key": "YOUR_DATADOG_API_KEY",
      "site": "datadoghq.com"
    }
  }'
```
