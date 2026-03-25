# Netlify Troubleshooting Guide

## Table of Contents

- [Build Failures and Debugging](#build-failures-and-debugging)
  - [Common Build Errors](#common-build-errors)
  - [Node.js Version Issues](#nodejs-version-issues)
  - [Dependency Installation Failures](#dependency-installation-failures)
  - [Memory and Timeout Limits](#memory-and-timeout-limits)
  - [Build Debugging Techniques](#build-debugging-techniques)
- [Function Timeout and Memory Limits](#function-timeout-and-memory-limits)
  - [Serverless Function Limits](#serverless-function-limits)
  - [Edge Function Limits](#edge-function-limits)
  - [Optimizing Function Performance](#optimizing-function-performance)
- [Deploy Preview Not Triggering](#deploy-preview-not-triggering)
- [Redirect and Rewrite Conflicts](#redirect-and-rewrite-conflicts)
  - [Redirect Processing Order](#redirect-processing-order)
  - [Common Redirect Mistakes](#common-redirect-mistakes)
  - [Debugging Redirects](#debugging-redirects)
- [Form Submission Issues](#form-submission-issues)
  - [Forms Not Detected](#forms-not-detected)
  - [JS-Rendered Form Issues](#js-rendered-form-issues)
  - [Spam and Bot Protection](#spam-and-bot-protection)
- [Identity and GoTrue Errors](#identity-and-gotrue-errors)
- [Large Site Deployment Issues](#large-site-deployment-issues)
- [CLI Connection Problems](#cli-connection-problems)
- [DNS and Custom Domain Issues](#dns-and-custom-domain-issues)

---

## Build Failures and Debugging

### Common Build Errors

#### "Build script returned non-zero exit code: 1"

The build command failed. Check the build log for the actual error above this
message.

```bash
# Reproduce locally
netlify build                  # runs the full build pipeline locally
# OR
npm run build                  # run your build command directly
```

#### "Build exceeded maximum allowed runtime"

Free tier: 15 min. Pro: 30 min. Business: 30 min.

**Fixes:**
- Add `ignore` to skip unnecessary builds
- Optimize build steps (parallelize where possible)
- Use build cache for dependencies
- Reduce image processing during builds

```toml
[build]
  ignore = "git diff --quiet $CACHED_COMMIT_REF $COMMIT_REF -- src/"
```

#### "Failed during stage 'building site': Build script returned non-zero exit code: 137"

Exit code 137 = OOM killed. Build exceeded memory limit (8 GB).

**Fixes:**
- Set `NODE_OPTIONS=--max_old_space_size=4096` in build environment
- Reduce concurrent operations in build scripts
- Use incremental builds if your framework supports them
- Split the build into stages

```toml
[build.environment]
  NODE_OPTIONS = "--max_old_space_size=4096"
```

### Node.js Version Issues

Netlify defaults to Node.js 18. Specify your version:

```toml
# netlify.toml
[build.environment]
  NODE_VERSION = "20"
```

Or use `.node-version` / `.nvmrc` in project root:

```
20
```

**Common version issues:**
- `error:0308010C:digital envelope routines::unsupported` → Node 17+ broke OpenSSL. Fix: use `NODE_OPTIONS=--openssl-legacy-provider` or update Webpack/tools.
- `SyntaxError: Unexpected token ??` → Node version too old. Set `NODE_VERSION = "18"` or higher.
- `Cannot find module 'node:fs'` → Requires Node 16+. Update `NODE_VERSION`.

### Dependency Installation Failures

#### "npm ERR! ERESOLVE unable to resolve dependency tree"

```toml
[build.environment]
  NPM_FLAGS = "--legacy-peer-deps"
  # OR
  NPM_FLAGS = "--force"
```

#### Yarn/pnpm detection

Netlify auto-detects package manager from lock files:
- `package-lock.json` → npm
- `yarn.lock` → Yarn
- `pnpm-lock.yaml` → pnpm (requires corepack)

```toml
[build.environment]
  # For pnpm
  COREPACK_ENABLE_STRICT = "0"
  # For Yarn 2+ (Berry)
  YARN_VERSION = "3.6.0"
```

**Tip:** If switching package managers, delete the old lock file and clear the
build cache in Netlify UI (Deploys > Trigger deploy > Clear cache and deploy).

#### Private npm packages

```toml
[build.environment]
  NPM_TOKEN = "your-token-here"  # DON'T DO THIS — use env vars in UI
```

Better: Set `NPM_TOKEN` in Site Settings > Build & deploy > Environment.
Create `.npmrc`:

```
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```

### Memory and Timeout Limits

| Resource | Free | Pro | Business | Enterprise |
|----------|------|-----|----------|------------|
| Build time | 300 min/mo | 1000 min/mo | 1000 min/mo | Custom |
| Build timeout | 15 min | 30 min | 30 min | 30 min |
| Build memory | 8 GB | 8 GB | 8 GB | 8 GB |
| Deploy size | 500 MB | 500 MB | 500 MB | Custom |
| File count | — | — | — | — |

### Build Debugging Techniques

```toml
# Enable verbose build output
[build.environment]
  DEBUG = "*"                    # show all debug output
  NETLIFY_BUILD_DEBUG = "true"   # show plugin debug info
  CI = "true"                    # already set by Netlify
```

```bash
# Local debugging
netlify build --debug            # verbose local build
netlify build --dry              # dry run (show what would happen)
NETLIFY_BUILD_DEBUG=true netlify build
```

Inspect build environment:

```toml
[build]
  command = "env | sort && npm run build"
```

---

## Function Timeout and Memory Limits

### Serverless Function Limits

| Resource | Free (Level 0) | Level 1 | Level 2 |
|----------|----------------|---------|---------|
| Invocations | 125K/mo | 2M/mo | 5M/mo |
| Runtime | 10s | 26s | 26s |
| Memory | 1024 MB | 1024 MB | 1024 MB |
| Payload size | 6 MB (sync) | 6 MB | 6 MB |
| Background timeout | — | 15 min | 15 min |

#### "Task timed out after X seconds"

```typescript
// BAD: N+1 queries
for (const id of ids) {
  const item = await db.get(id); // sequential = slow
}

// GOOD: batch or parallel
const items = await Promise.all(ids.map((id) => db.get(id)));
// OR
const items = await db.batchGet(ids);
```

#### "Function invocation failed — function crashed"

Usually a memory issue or unhandled exception.

```typescript
// Always wrap handlers in try/catch
export const handler: Handler = async (event) => {
  try {
    const result = await doWork(event);
    return { statusCode: 200, body: JSON.stringify(result) };
  } catch (error) {
    console.error("Function error:", error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Internal server error" }),
    };
  }
};
```

### Edge Function Limits

| Resource | Limit |
|----------|-------|
| CPU time | 50ms per invocation |
| Memory | 512 MB |
| Response body | 20 MB |
| Subrequests | 40 per invocation |
| Script size | 20 MB |

**Edge function CPU timeout:** Edge functions have a 50ms CPU time limit (wall
clock can be longer due to I/O waits). Avoid heavy computation; offload to
serverless functions.

### Optimizing Function Performance

```typescript
// 1. Initialize clients outside handler (reuse across warm invocations)
import { Client } from "some-db";
const client = new Client(process.env.DB_URL!); // cold start only

export const handler: Handler = async (event) => {
  const data = await client.query("...");
  return { statusCode: 200, body: JSON.stringify(data) };
};

// 2. Use esbuild bundler for faster cold starts
// netlify.toml:
// [functions]
//   node_bundler = "esbuild"

// 3. Minimize dependencies — only import what you need
import { DynamoDBClient } from "@aws-sdk/client-dynamodb"; // NOT all of aws-sdk
```

---

## Deploy Preview Not Triggering

**Symptoms:** PR opened but no deploy preview appears.

**Causes and fixes:**

1. **Deploy previews disabled**: Site Settings > Build & deploy > Deploy preview → Enable.

2. **Build not linked to Git**: `netlify status` should show linked repository.
   Re-link with `netlify link`.

3. **`ignore` command returns true**: Your ignore script is skipping the build.
   Check `ignore` in `netlify.toml`:
   ```toml
   [build]
     ignore = "git diff --quiet $CACHED_COMMIT_REF $COMMIT_REF -- src/"
   ```
   If no files in `src/` changed, the build is skipped.

4. **Branch filter active**: Site Settings > Build & deploy > Branches and deploy
   contexts. If "Only production branch" is selected, previews won't trigger.
   Set to "Deploy previews for all pull/merge requests."

5. **GitHub permissions**: The Netlify GitHub App needs `pull_request` event
   access. Re-install the app at https://github.com/apps/netlify.

6. **Build minutes exhausted**: Check usage at Team > Settings > Billing.

7. **Monorepo base path changed files not detected**: Ensure `base` and `ignore`
   are consistent:
   ```toml
   [build]
     base = "apps/web"
     ignore = "git diff --quiet $CACHED_COMMIT_REF $COMMIT_REF -- apps/web/"
   ```

---

## Redirect and Rewrite Conflicts

### Redirect Processing Order

1. Netlify's own `_redirects` file and `netlify.toml` `[[redirects]]` merge.
2. `netlify.toml` rules are processed first, then `_redirects` rules.
3. Within each file, rules are processed **top to bottom, first match wins**.
4. Without `force = true`, existing files/assets take precedence over redirect rules.

### Common Redirect Mistakes

#### SPA routing broken — pages return 404

```toml
# WRONG: Too early, catches all paths before API routes
[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200

[[redirects]]
  from = "/api/*"
  to = "/.netlify/functions/:splat"
  status = 200

# CORRECT: Specific routes first, SPA catch-all last
[[redirects]]
  from = "/api/*"
  to = "/.netlify/functions/:splat"
  status = 200

[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200
```

#### Proxy redirect not working

```toml
# WRONG: Missing force — existing files prevent the rewrite
[[redirects]]
  from = "/api/*"
  to = "https://backend.example.com/:splat"
  status = 200

# CORRECT: force = true overrides static file matches
[[redirects]]
  from = "/api/*"
  to = "https://backend.example.com/:splat"
  status = 200
  force = true
```

#### Redirect loop

```toml
# CAUSES LOOP: /blog redirects to /blog/ redirects to /blog ...
[[redirects]]
  from = "/blog"
  to = "/blog/"
  status = 301

# FIX: Use pretty_urls or be explicit
[build.processing.html]
  pretty_urls = true
```

### Debugging Redirects

```bash
# Test redirects locally
netlify dev  # runs local dev server with redirect engine

# View deployed redirect rules
curl -sI https://your-site.netlify.app/old-path | grep -i location

# Check _redirects file is in publish directory
ls -la dist/_redirects  # must be in the output dir, not project root
```

**Tip:** Netlify playground for redirect testing:
https://play.netlify.com/redirects

---

## Form Submission Issues

### Forms Not Detected

Netlify's build bot scans HTML for `data-netlify="true"` during deploy.

**Symptom:** Form submissions return 404 or "Form not found."

**Fixes:**

1. Ensure `data-netlify="true"` is on the `<form>` tag:
   ```html
   <form name="contact" method="POST" data-netlify="true">
   ```

2. The `name` attribute is required and must match `form-name` hidden input.

3. If using a framework (React/Vue/Svelte), the form HTML must exist in the
   **static** build output. The build bot doesn't execute JavaScript.

### JS-Rendered Form Issues

For React/Vue/Angular SPAs, add a hidden form to the static HTML:

```html
<!-- public/index.html or equivalent -->
<form name="contact" netlify netlify-honeypot="bot-field" hidden>
  <input type="text" name="name" />
  <input type="email" name="email" />
  <textarea name="message"></textarea>
</form>
```

Then submit via JavaScript:

```typescript
const handleSubmit = async (data: FormData) => {
  const response = await fetch("/", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      "form-name": "contact",
      ...Object.fromEntries(data),
    }).toString(),
  });

  if (!response.ok) throw new Error("Form submission failed");
};
```

**Common mistakes:**
- Missing `form-name` in the POST body
- Using `multipart/form-data` for non-file forms (use `application/x-www-form-urlencoded`)
- Form `name` attribute doesn't match hidden form
- File upload forms need `enctype="multipart/form-data"` and `data-netlify="true"`

### Spam and Bot Protection

```html
<!-- Honeypot (recommended) -->
<form name="contact" method="POST" data-netlify="true" netlify-honeypot="bot-field">
  <p style="display:none">
    <label>Don't fill this out: <input name="bot-field" /></label>
  </p>
  <!-- real fields -->
</form>

<!-- reCAPTCHA 2 -->
<form name="contact" method="POST" data-netlify="true" data-netlify-recaptcha="true">
  <div data-netlify-recaptcha="true"></div>
  <button type="submit">Send</button>
</form>
```

---

## Identity and GoTrue Errors

### "Failed to load settings from /.netlify/identity"

Identity is not enabled. Enable in Site Settings > Identity.

### "User not found" or "Invalid token"

```typescript
// Ensure the Identity widget is initialized
netlifyIdentity.init({
  APIUrl: "https://your-site.netlify.app/.netlify/identity",
});
```

### Token refresh issues

```typescript
// Token expires after 1 hour. Auto-refresh:
netlifyIdentity.on("init", (user) => {
  if (user) {
    // Refresh token if expired
    netlifyIdentity.refresh().then((jwt) => {
      console.log("Token refreshed:", jwt);
    });
  }
});

// Manual token refresh in functions
export const handler: Handler = async (event, context) => {
  const { identity, user } = context.clientContext || {};

  if (!user) {
    return { statusCode: 401, body: "Not authenticated" };
  }

  // user.token is auto-verified by Netlify
  // user.email, user.sub, user.app_metadata.roles available
  return { statusCode: 200, body: JSON.stringify({ user: user.email }) };
};
```

### Role-based access not working

Roles must be set in Identity > User management, or via the admin API:

```bash
# Set user role via GoTrue admin API
curl -X PUT "https://your-site.netlify.app/.netlify/identity/admin/users/{user_id}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"app_metadata": {"roles": ["admin"]}}'
```

Then use in redirects:

```toml
[[redirects]]
  from = "/admin/*"
  to = "/login"
  status = 302
  conditions = {Role = ["admin"]}
  force = true
```

### External provider login not working

1. Enable providers in Identity > Settings > External providers
2. Set OAuth credentials (client ID + secret) for each provider
3. Callback URL must be: `https://your-site.netlify.app/.netlify/identity/callback`

---

## Large Site Deployment Issues

### "Error: Deploy did not succeed: Deploy exceeded max allowed file count"

Default file limit is ~25,000 files. Contact support for increase.

**Fixes:**
- Exclude unnecessary files from publish directory
- Remove source maps from production builds
- Don't publish `node_modules`

### "Deploy failed: Request Entity Too Large"

Individual file size limit: 50 MB. Total site size limit: 500 MB.

```bash
# Find large files
find dist/ -size +10M -exec ls -lh {} \;

# Exclude patterns in .gitignore or build config
```

### Slow deploys

```bash
# Use manual deploy with progress
netlify deploy --dir=dist --prod --message "v1.2.3"

# For large sites, use atomic deploys (default)
# Netlify only uploads changed files (content-addressable)
```

### Build cache issues

```bash
# Clear build cache when things are stale
# UI: Deploys > Trigger deploy > Clear cache and deploy site

# Or via CLI
netlify api createSiteBuild --data='{"site_id": "YOUR_SITE_ID", "clear_cache": true}'
```

---

## CLI Connection Problems

### "Not logged in. Please log in and try again."

```bash
netlify login                  # browser-based OAuth login
netlify login --new            # force new login (clears old token)
# In CI without browser:
NETLIFY_AUTH_TOKEN=<pat> netlify deploy --prod
```

### "Site not found" or "No site id found"

```bash
netlify status                 # check current link
netlify unlink                 # unlink current directory
netlify link                   # re-link interactively
netlify link --id YOUR_SITE_ID # link by site ID
netlify link --name YOUR_SITE  # link by site name
```

### "Error: ENAMETOOLONG" or path too long errors

Windows issue with deeply nested `node_modules`. Fix: use `.netlify/` in
`.gitignore` and ensure it's not deployed.

### CLI behind proxy/firewall

```bash
# Set proxy
export HTTP_PROXY=http://proxy.corp.com:8080
export HTTPS_PROXY=http://proxy.corp.com:8080

# Self-signed certs
export NODE_TLS_REJECT_UNAUTHORIZED=0  # development only!
```

### CLI version issues

```bash
netlify --version              # check current version
npm update -g netlify-cli      # update to latest
npx netlify-cli deploy         # use latest without installing
```

---

## DNS and Custom Domain Issues

### Domain not resolving

1. **Check DNS propagation** (may take up to 48 hours):
   ```bash
   dig your-domain.com +short
   dig your-domain.com CNAME +short
   nslookup your-domain.com
   ```

2. **Correct DNS records:**
   - Apex domain (example.com): A record → `75.2.60.5`
   - Subdomain (www.example.com): CNAME → `your-site.netlify.app`

3. **Using Netlify DNS (recommended):**
   Update nameservers at your registrar to Netlify's:
   ```
   dns1.p06.nsone.net
   dns2.p06.nsone.net
   dns3.p06.nsone.net
   dns4.p06.nsone.net
   ```

### SSL/TLS certificate not provisioning

**Symptom:** "Waiting for DNS propagation" or "Certificate provisioning error."

**Fixes:**
1. DNS must resolve to Netlify before cert can be issued
2. No CAA records blocking Let's Encrypt:
   ```bash
   dig your-domain.com CAA +short
   # Should be empty or include: 0 issue "letsencrypt.org"
   ```
3. Remove any AAAA records pointing elsewhere
4. Wait — auto-provisioning can take up to 24 hours after DNS propagation
5. Manual retry: Site Settings > Domain management > HTTPS > Renew certificate

### "Domain already registered with another account"

Contact Netlify support. Only one Netlify account can use a domain at a time.

### Mixed content warnings after HTTPS

```toml
# Force HTTPS in headers
[[headers]]
  for = "/*"
  [headers.values]
    Content-Security-Policy = "upgrade-insecure-requests"
    Strict-Transport-Security = "max-age=31536000; includeSubDomains"
```

### Subdomain not working

```bash
# Add in Netlify UI: Site Settings > Domain management > Add domain alias
netlify domains:add staging.example.com

# DNS: Add CNAME record
# staging.example.com → your-site.netlify.app
```

### Redirect www to apex (or vice versa)

Netlify auto-redirects if both domains are added. Add both:
1. `example.com` (primary)
2. `www.example.com` (redirects to primary)

If using external DNS, ensure both records exist.
