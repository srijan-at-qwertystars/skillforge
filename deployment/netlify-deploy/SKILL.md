---
name: netlify-deploy
description: >
  Netlify deployment patterns, configuration, and platform features. Use when: deploying to Netlify,
  configuring netlify.toml, writing Netlify Functions (serverless/edge/scheduled/background),
  setting up deploy previews, branch deploys, Netlify CLI (netlify deploy, netlify dev, netlify link),
  configuring redirects/rewrites, Netlify Forms, Identity, split testing, custom domains, or
  build plugins. Do NOT use for: AWS/GCP/Azure deployment, Docker/Kubernetes orchestration,
  Vercel deployment, self-hosted servers, Cloudflare Workers/Pages, Firebase Hosting, or
  generic CI/CD pipelines unrelated to Netlify.
---

# Netlify Deployment Skill

## Project Setup

### Initialize a Netlify project

```bash
npm install -g netlify-cli
netlify login
netlify init          # interactive setup with Git provider
# OR
netlify link          # link existing directory to a Netlify site
netlify status        # verify connection
```

### Minimal `netlify.toml`

Place at project root. Settings here override the Netlify UI.

```toml
[build]
  command = "npm run build"
  publish = "dist"
  functions = "netlify/functions"

[build.environment]
  NODE_VERSION = "20"
```

Framework-specific publish directories:
- React/Vite: `dist`
- Next.js: `.next` (use `@netlify/plugin-nextjs`)
- Gatsby: `public`
- Hugo: `public`
- Astro: `dist`
- SvelteKit: `build` (use `@sveltejs/adapter-netlify`)

## netlify.toml Configuration

### Key directives

```toml
[build]
  command = "npm run build"         # build command
  publish = "dist"                  # output directory
  functions = "netlify/functions"   # serverless functions dir
  edge_functions = "netlify/edge-functions"
  ignore = "git diff --quiet $CACHED_COMMIT_REF $COMMIT_REF -- src/"
  base = ""                         # monorepo subdirectory

[build.environment]
  NODE_VERSION = "20"

[dev]
  command = "npm run dev"
  port = 3000
  targetPort = 5173

[functions]
  node_bundler = "esbuild"          # or "zisi" (default)
  included_files = ["data/**"]
  external_node_modules = ["sharp"]

[[plugins]]
  package = "@netlify/plugin-nextjs"
  [plugins.inputs]
    someOption = "value"
```

## Deploy Contexts

Override build settings per deploy context. Each context inherits from `[build]` and overrides selectively.

```toml
[context.production]
  command = "npm run build"
  environment = { API_URL = "https://api.example.com" }

[context.deploy-preview]
  command = "npm run build:preview"
  environment = { API_URL = "https://api-staging.example.com", ROBOTS = "noindex" }

[context.branch-deploy]
  command = "npm run build"
  environment = { API_URL = "https://api-staging.example.com" }

# Named branch context
[context.staging]
  command = "npm run build:staging"
  environment = { API_URL = "https://api-staging.example.com" }
```

Available contexts: `production`, `deploy-preview`, `branch-deploy`, or any branch name.

## Netlify Functions

### Serverless Functions (AWS Lambda)

Place in `netlify/functions/`. Runtime: Node.js or Go. Timeout: 10s (free) / 26s (paid).

```typescript
// netlify/functions/hello.ts
import type { Handler, HandlerEvent, HandlerContext } from "@netlify/functions";

export const handler: Handler = async (event: HandlerEvent, context: HandlerContext) => {
  const { httpMethod, queryStringParameters, body, headers } = event;

  if (httpMethod !== "GET") {
    return { statusCode: 405, body: "Method Not Allowed" };
  }

  return {
    statusCode: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message: "Hello", user: queryStringParameters?.name }),
  };
};
// Invoked at: /.netlify/functions/hello?name=World
```

### Background Functions

Suffix file with `-background`. Returns 202 immediately; runs up to 15 minutes. Pro plan required.

```typescript
// netlify/functions/process-data-background.ts
import type { Handler } from "@netlify/functions";

export const handler: Handler = async (event) => {
  const payload = JSON.parse(event.body || "{}");
  // Long-running work: batch processing, external API sync, etc.
  await heavyProcessing(payload);
  return { statusCode: 200, body: "" }; // response is ignored; caller gets 202
};
```

### Scheduled Functions

Use `@netlify/functions` schedule helper. Cron syntax.

```typescript
// netlify/functions/daily-cleanup.ts
import { schedule } from "@netlify/functions";

export const handler = schedule("0 0 * * *", async (event) => {
  // Runs daily at midnight UTC
  await cleanupStaleData();
  return { statusCode: 200 };
});
```

Register in `netlify.toml` if not using inline schedule:

```toml
[functions."daily-cleanup"]
  schedule = "0 0 * * *"
```

### Edge Functions

Run on Deno at CDN edge. Place in `netlify/edge-functions/`. Ultra-low latency.

```typescript
// netlify/edge-functions/geolocation.ts
import type { Context } from "@netlify/edge-functions";

export default async (request: Request, context: Context) => {
  const country = context.geo.country?.code || "US";
  const response = await context.next();
  const html = await response.text();
  return new Response(html.replace("{{COUNTRY}}", country), response);
};

// Config block declares path matching
export const config = { path: "/localized/*" };
```

Register edge functions in `netlify.toml`:

```toml
[[edge_functions]]
  path = "/localized/*"
  function = "geolocation"

[[edge_functions]]
  path = "/api/edge/*"
  function = "edge-api"
```

Edge vs Serverless decision:
- **Edge**: geo-personalization, A/B testing, auth checks, header manipulation, low-latency transforms
- **Serverless**: database access, heavy computation, third-party API calls, background jobs

## Environment Variables

```bash
netlify env:list                              # list all vars
netlify env:get API_KEY                       # get single var
netlify env:set API_KEY "sk-abc123"           # set (all contexts)
netlify env:set API_KEY "sk-test" --context deploy-preview
netlify env:unset API_KEY                     # remove var
netlify env:import .env                       # bulk import
netlify env:clone --to <site-id>              # clone to another site
```

Scopes: `builds`, `functions`, `runtime`. Contexts: `production`, `deploy-preview`, `branch-deploy`, `dev`.

Built-in build vars: `CONTEXT`, `BRANCH`, `COMMIT_REF`, `DEPLOY_URL`, `DEPLOY_PRIME_URL`, `URL`, `REPOSITORY_URL`, `CACHED_COMMIT_REF`, `PULL_REQUEST`, `REVIEW_ID`.

**Rules:** Never store secrets in `netlify.toml` — use UI or `env:set`. Add `.env` to `.gitignore`. Use context-specific vars to isolate production secrets.

## Redirects, Rewrites, and Headers

```toml
# 301 redirect
[[redirects]]
  from = "/old-page"
  to = "/new-page"
  status = 301

# SPA fallback (rewrite, not redirect)
[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200

# Proxy to external API (hides origin from client)
[[redirects]]
  from = "/api/*"
  to = "https://api.example.com/:splat"
  status = 200
  force = true

# Geo-based redirect
[[redirects]]
  from = "/*"
  to = "/eu/:splat"
  status = 302
  conditions = {Country = ["DE", "FR", "IT", "ES"]}

# Role-gated redirect (Netlify Identity)
[[redirects]]
  from = "/admin/*"
  to = "/login"
  status = 302
  conditions = {Role = ["admin"]}
  force = true
```

`_redirects` file alternative (in publish dir, one rule per line, processed after `netlify.toml`):

```
/old   /new   301
/api/*  https://api.example.com/:splat  200
/*     /index.html  200
```

### Security and cache headers

```toml
[[headers]]
  for = "/*"
  [headers.values]
    X-Frame-Options = "DENY"
    X-Content-Type-Options = "nosniff"
    Referrer-Policy = "strict-origin-when-cross-origin"

[[headers]]
  for = "/assets/*"
  [headers.values]
    Cache-Control = "public, max-age=31536000, immutable"
```

## Netlify Forms

Add `data-netlify="true"` to HTML forms. No backend needed.

```html
<form name="contact" method="POST" data-netlify="true" netlify-honeypot="bot-field">
  <input type="hidden" name="form-name" value="contact" />
  <p class="hidden"><label>Bot trap: <input name="bot-field" /></label></p>
  <input type="text" name="name" required />
  <input type="email" name="email" required />
  <textarea name="message" required></textarea>
  <button type="submit">Send</button>
</form>
```

For JS-rendered forms (React/Vue), add a hidden HTML form in `public/index.html` and submit via fetch:

```typescript
await fetch("/", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ "form-name": "contact", name, email, message }).toString(),
});
```

## Identity and Auth

Enable in UI > Site Settings > Identity. Provides JWT-based auth with widget:

```html
<script src="https://identity.netlify.com/v1/netlify-identity-widget.js"></script>
```

Access user in serverless functions:

```typescript
export const handler: Handler = async (event, context) => {
  const { user } = context.clientContext;
  if (!user) return { statusCode: 401, body: "Unauthorized" };
  return { statusCode: 200, body: JSON.stringify({ email: user.email }) };
};
```

## Build Plugins

```toml
[[plugins]]
  package = "@netlify/plugin-nextjs"       # Next.js SSR support
[[plugins]]
  package = "@netlify/plugin-lighthouse"   # Lighthouse audits
  [plugins.inputs]
    audits = [{ path = "/", thresholds = { performance = 0.9 } }]
[[plugins]]
  package = "netlify-plugin-checklinks"    # broken link checker
[[plugins]]
  package = "netlify-plugin-submit-sitemap"
```

Local custom plugin:

```toml
[[plugins]]
  package = "./plugins/my-plugin"
```

```javascript
// plugins/my-plugin/index.js
module.exports = {
  onPreBuild: ({ utils }) => { console.log("Pre-build"); },
  onPostBuild: ({ utils, constants }) => {
    console.log(`Published: ${constants.PUBLISH_DIR}`);
  },
  onError: ({ utils }) => { utils.build.failBuild("Build failed"); },
};
```

## CLI Deployment

```bash
netlify deploy                    # draft deploy (preview URL)
netlify deploy --prod             # production deploy
netlify deploy --dir=dist --prod  # specify output dir
netlify deploy --alias=feature-x  # → https://feature-x--site.netlify.app
netlify dev                       # local dev server (mirrors prod)
netlify dev --live                # shareable tunnel URL
netlify dev --context production  # use production env vars
netlify open                      # open admin panel
netlify open --site               # open deployed site
```

## Monorepo and Custom Domains

Set `base` for monorepo subdirectory:

```toml
[build]
  base = "packages/frontend"
  command = "npm run build"
  publish = "packages/frontend/dist"
  ignore = "git diff --quiet $CACHED_COMMIT_REF $COMMIT_REF -- packages/frontend/"
```

Custom domains: add via UI or `netlify domains:add example.com`. Point A record to `75.2.60.5` or CNAME to `your-site.netlify.app`. Netlify auto-provisions Let's Encrypt TLS.

## Split Testing

Configure in UI under Split Testing — assign traffic percentages to branches. Cookie-based sticky sessions.

For programmatic A/B via Edge Functions:

```typescript
// netlify/edge-functions/ab-test.ts
export default async (request: Request, context: Context) => {
  const cookie = request.headers.get("cookie") || "";
  const variant = cookie.includes("ab=B") ? "B" : Math.random() < 0.5 ? "A" : "B";
  const response = await context.next();
  const html = await response.text();
  return new Response(html.replace("{{VARIANT}}", variant), {
    headers: { ...Object.fromEntries(response.headers), "Set-Cookie": `ab=${variant}; Path=/; Max-Age=86400` },
  });
};
export const config = { path: "/" };
```

## Performance

```toml
[build.processing.css]
  bundle = true
  minify = true
[build.processing.js]
  bundle = true
  minify = true
[build.processing.html]
  pretty_urls = true
[build.processing.images]
  compress = true
```

## Common Patterns

### SPA with function API proxy

```toml
[build]
  command = "npm run build"
  publish = "dist"
  functions = "netlify/functions"

[[redirects]]
  from = "/api/*"
  to = "/.netlify/functions/:splat"
  status = 200

[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200
```

### CI/CD with GitHub

Netlify auto-deploys when linked to a Git provider. PRs create deploy previews with unique URLs. Use `ignore` to skip unnecessary builds. GitHub commit status checks show deploy state on PRs.

## Additional Resources

### References

- **`references/advanced-patterns.md`** — Edge Functions patterns (geolocation, auth, personalization, rate limiting), scheduled/background function patterns, build plugin development (lifecycle hooks, utilities, publishing), deploy notifications/hooks, Netlify Large Media, Netlify Connect data layer, split testing strategies (branch-based, edge A/B, feature flags), enterprise features (SSO, audit logs, log drains).

- **`references/troubleshooting.md`** — Build failures (OOM, timeouts, Node.js versions, dependency issues), function limits and optimization, deploy preview debugging, redirect/rewrite conflicts and processing order, form detection issues for JS frameworks, Identity/GoTrue errors, large site deployment, CLI connection problems, DNS and SSL/TLS certificate troubleshooting.

- **`references/api-reference.md`** — Netlify REST API (sites, deploys, functions, forms, files, DNS), authentication (PAT, OAuth2), deploy hooks and build hooks, webhook event payloads, Split Testing API, Identity/GoTrue API (signup, login, token refresh, admin endpoints), comprehensive CLI command reference.

### Scripts

- **`scripts/setup-netlify.sh`** — Project initializer. Auto-detects framework (Next.js, Gatsby, Astro, Hugo, SvelteKit, etc.), generates optimized `netlify.toml`, creates functions directory with example, generates `_redirects`, `.env.example`, and updates `.gitignore`. Usage: `./scripts/setup-netlify.sh [--framework <name>]`

- **`scripts/netlify-functions-scaffold.sh`** — Function scaffolding. Creates serverless, edge, scheduled, or background function boilerplate in TypeScript or JavaScript with CORS, error handling, and types. Usage: `./scripts/netlify-functions-scaffold.sh <type> <name> [--js] [--path "/route/*"] [--schedule "0 * * * *"]`

### Assets (Templates)

- **`assets/netlify.toml`** — Comprehensive `netlify.toml` template covering all contexts (production, deploy-preview, branch-deploy), redirects, security headers, cache headers, build processing, and plugin configuration.

- **`assets/serverless-function.ts`** — Production-ready TypeScript serverless function template with CORS, JSON helpers, auth guards, error handling, and typed request/response patterns.

- **`assets/github-actions-netlify.yml`** — GitHub Actions workflow for Netlify: production deploys on push, preview deploys on PRs with comment URL, and optional Lighthouse auditing.
