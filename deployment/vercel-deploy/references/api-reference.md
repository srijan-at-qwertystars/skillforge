# Vercel API & CLI Reference

## Table of Contents
- [Vercel REST API](#vercel-rest-api)
  - [Authentication](#authentication)
  - [Deployments API](#deployments-api)
  - [Projects API](#projects-api)
  - [Domains API](#domains-api)
  - [Environment Variables API](#environment-variables-api)
  - [Teams API](#teams-api)
- [Vercel CLI Commands Reference](#vercel-cli-commands-reference)
  - [Project Management](#project-management)
  - [Deployment Commands](#deployment-commands)
  - [Environment Variables](#environment-variables-cli)
  - [Domain Management](#domain-management)
  - [DNS Management](#dns-management)
  - [Secrets and Credentials](#secrets-and-credentials)
  - [Inspection and Logs](#inspection-and-logs)
- [Deployment Hooks and Webhooks](#deployment-hooks-and-webhooks)
- [Integration with GitHub / GitLab APIs](#integration-with-github--gitlab-apis)
- [Vercel SDK for Programmatic Deployments](#vercel-sdk-for-programmatic-deployments)
- [Edge Config API](#edge-config-api)
- [Storage APIs](#storage-apis)
  - [Upstash Redis (KV)](#upstash-redis-kv)
  - [Vercel Blob](#vercel-blob)
  - [Vercel Postgres](#vercel-postgres)

---

## Vercel REST API

Base URL: `https://api.vercel.com`

All endpoints accept JSON and return JSON. Pagination uses `limit` and `until` (cursor-based) or `from` parameters.

### Authentication

**Bearer Token:**
```bash
curl -H "Authorization: Bearer <TOKEN>" https://api.vercel.com/v9/projects
```

**Token types:**
| Type | Scope | How to Create |
|------|-------|--------------|
| Personal Access Token | Full account access | vercel.com/account/tokens |
| OAuth Token | Scoped to integration | Via OAuth flow |
| Team Token | Scoped to team | Dashboard → Team Settings → Tokens |

**Create a token via CLI:**
```bash
vercel login
# Token is stored in ~/.local/share/com.vercel.cli/auth.json
```

**Scopes for tokens:**
- `deployments:read`, `deployments:write`
- `projects:read`, `projects:write`
- `domains:read`, `domains:write`
- `env:read`, `env:write`
- `logs:read`

### Deployments API

**Create a deployment:**
```bash
# Deploy from Git
curl -X POST "https://api.vercel.com/v13/deployments" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-project",
    "project": "prj_xxxxxxxxxxxx",
    "target": "production",
    "gitSource": {
      "type": "github",
      "repoId": "123456789",
      "ref": "main",
      "sha": "abc123"
    }
  }'
```

**List deployments:**
```bash
# List all deployments for a project
curl "https://api.vercel.com/v6/deployments?projectId=prj_xxx&limit=10" \
  -H "Authorization: Bearer $VERCEL_TOKEN"

# Filter by state
curl "https://api.vercel.com/v6/deployments?projectId=prj_xxx&state=READY" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Get deployment details:**
```bash
curl "https://api.vercel.com/v13/deployments/dpl_xxxxxxxxxxxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Response fields:**
```jsonc
{
  "id": "dpl_xxxxxxxxxxxx",
  "url": "my-project-abc123.vercel.app",
  "state": "READY",           // QUEUED, BUILDING, READY, ERROR, CANCELED
  "readyState": "READY",
  "target": "production",     // production, preview, or null
  "createdAt": 1234567890000,
  "buildingAt": 1234567891000,
  "ready": 1234567895000,
  "meta": {
    "githubCommitSha": "abc123",
    "githubCommitMessage": "fix: update styles",
    "githubCommitRef": "main"
  }
}
```

**Cancel a deployment:**
```bash
curl -X PATCH "https://api.vercel.com/v13/deployments/dpl_xxx/cancel" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Delete a deployment:**
```bash
curl -X DELETE "https://api.vercel.com/v13/deployments/dpl_xxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Get deployment events/logs:**
```bash
curl "https://api.vercel.com/v3/deployments/dpl_xxx/events" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

### Projects API

**List projects:**
```bash
curl "https://api.vercel.com/v9/projects?limit=20" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Create a project:**
```bash
curl -X POST "https://api.vercel.com/v10/projects" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-new-project",
    "framework": "nextjs",
    "gitRepository": {
      "type": "github",
      "repo": "username/repo-name"
    },
    "buildCommand": "npm run build",
    "outputDirectory": ".next",
    "rootDirectory": "apps/web",
    "installCommand": "npm install"
  }'
```

**Update a project:**
```bash
curl -X PATCH "https://api.vercel.com/v9/projects/prj_xxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "buildCommand": "pnpm run build",
    "framework": "nextjs",
    "nodeVersion": "22.x"
  }'
```

**Delete a project:**
```bash
curl -X DELETE "https://api.vercel.com/v9/projects/prj_xxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

### Domains API

**List domains:**
```bash
curl "https://api.vercel.com/v5/domains?limit=20" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Add a domain to project:**
```bash
curl -X POST "https://api.vercel.com/v10/projects/prj_xxx/domains" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "name": "example.com" }'
```

**Remove a domain:**
```bash
curl -X DELETE "https://api.vercel.com/v9/projects/prj_xxx/domains/example.com" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Check domain availability:**
```bash
curl "https://api.vercel.com/v4/domains/status?name=example.com" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Get domain configuration (DNS check):**
```bash
curl "https://api.vercel.com/v6/domains/example.com/config" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

Response:
```jsonc
{
  "configuredBy": "A",        // A, CNAME, or null
  "acceptedChallenges": ["dns-01"],
  "misconfigured": false
}
```

### Environment Variables API

**List env vars for a project:**
```bash
curl "https://api.vercel.com/v9/projects/prj_xxx/env" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Create an env var:**
```bash
curl -X POST "https://api.vercel.com/v10/projects/prj_xxx/env" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "DATABASE_URL",
    "value": "postgresql://...",
    "type": "encrypted",
    "target": ["production", "preview"]
  }'
```

**Type options:** `plain`, `encrypted`, `secret`, `sensitive`

**Target options:** `production`, `preview`, `development`

**Update an env var:**
```bash
curl -X PATCH "https://api.vercel.com/v9/projects/prj_xxx/env/env_xxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "value": "new-value", "target": ["production"] }'
```

**Delete an env var:**
```bash
curl -X DELETE "https://api.vercel.com/v9/projects/prj_xxx/env/env_xxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

### Teams API

**List teams:**
```bash
curl "https://api.vercel.com/v2/teams" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Get team info:**
```bash
curl "https://api.vercel.com/v2/teams/team_xxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

**Invite member:**
```bash
curl -X POST "https://api.vercel.com/v1/teams/team_xxx/members" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user@example.com",
    "role": "MEMBER"
  }'
```

**Scoping API calls to a team:**
```bash
# Add teamId query parameter to any API call
curl "https://api.vercel.com/v9/projects?teamId=team_xxx" \
  -H "Authorization: Bearer $VERCEL_TOKEN"
```

---

## Vercel CLI Commands Reference

Install: `npm i -g vercel`

### Project Management

```bash
vercel link                       # Link current directory to a Vercel project
vercel link --repo                # Link to a monorepo (team required)
vercel pull                       # Pull env vars and project settings
vercel pull --environment=preview # Pull preview env vars
vercel project ls                 # List all projects
vercel project add <name>         # Create a new project
vercel project rm <name>          # Remove a project
vercel switch                     # Switch between teams/scopes
vercel whoami                     # Show current user/team
```

### Deployment Commands

```bash
vercel                            # Deploy to preview (shorthand)
vercel deploy                     # Deploy to preview
vercel deploy --prod              # Deploy to production
vercel deploy --force             # Force rebuild (skip cache)
vercel deploy --no-wait           # Don't wait for deployment to finish
vercel deploy --archive=tgz       # Upload as tarball (faster for large projects)
vercel deploy --prebuilt          # Deploy pre-built output (.vercel/output/)
vercel build                      # Build locally (creates .vercel/output/)
vercel build --prod               # Build for production locally
vercel dev                        # Run development server with Vercel runtime
vercel dev --port 3001            # Custom dev port
vercel inspect <url>              # Show deployment details
vercel ls                         # List recent deployments
vercel rm <deployment>            # Remove a deployment
vercel promote <url>              # Promote a deployment to production
vercel rollback                   # Rollback to previous production deployment
vercel redeploy                   # Redeploy the last deployment
```

### Environment Variables (CLI)

```bash
vercel env ls                     # List all env vars
vercel env add <key>              # Add interactively (prompts for value/env)
vercel env add <key> production   # Add for specific environment
vercel env add <key> production preview  # Add for multiple environments
vercel env rm <key> production    # Remove from specific environment
vercel env pull                   # Pull to .env.local
vercel env pull .env.production   # Pull to custom file
```

### Domain Management

```bash
vercel domains ls                 # List all domains
vercel domains add <domain>       # Add a domain
vercel domains rm <domain>        # Remove a domain
vercel domains inspect <domain>   # Show domain details
vercel domains move <domain> <dest>  # Transfer domain to another account
vercel alias <url> <domain>       # Alias a deployment to a domain
vercel alias ls                   # List all aliases
vercel alias rm <alias>           # Remove an alias
```

### DNS Management

```bash
vercel dns ls <domain>            # List DNS records
vercel dns add <domain> <subdomain> A 1.2.3.4       # Add A record
vercel dns add <domain> <subdomain> CNAME target.com # Add CNAME
vercel dns add <domain> @ MX 10 mail.example.com    # Add MX
vercel dns add <domain> <subdomain> TXT "v=spf1..." # Add TXT
vercel dns rm <record-id>         # Remove DNS record
```

### Secrets and Credentials

```bash
vercel login                      # Authenticate (browser or email)
vercel login --github             # Authenticate via GitHub
vercel login --gitlab             # Authenticate via GitLab
vercel logout                     # Log out
vercel tokens ls                  # List authentication tokens (API tokens not CLI tokens)
```

### Inspection and Logs

```bash
vercel logs <url>                 # View function logs
vercel logs <url> --follow        # Stream logs in real-time
vercel logs <url> --since 1h      # Logs from last hour
vercel inspect <url>              # Deployment details (regions, routes, functions)
vercel inspect <url> --json       # Machine-readable output
```

---

## Deployment Hooks and Webhooks

### Deploy Hooks

Create a unique URL that triggers a new deployment when called with POST.

**Create in Dashboard:** Project Settings → Git → Deploy Hooks

```bash
# Trigger a deploy hook
curl -X POST "https://api.vercel.com/v1/integrations/deploy/prj_xxx/hook_xxx"

# Use in CI/CD, CMS webhooks, or scheduled tasks
# Contentful webhook example:
# URL: https://api.vercel.com/v1/integrations/deploy/prj_xxx/hook_xxx
# Method: POST
# Triggers: Entry.publish, Entry.unpublish
```

### Webhooks (Outgoing)

Receive notifications when deployment events occur.

**Create via API:**
```bash
curl -X POST "https://api.vercel.com/v1/webhooks" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://your-server.com/api/vercel-webhook",
    "events": [
      "deployment.created",
      "deployment.succeeded",
      "deployment.failed",
      "deployment.canceled",
      "deployment.error"
    ]
  }'
```

**Webhook payload structure:**
```jsonc
{
  "id": "evt_xxx",
  "type": "deployment.succeeded",
  "createdAt": 1234567890000,
  "payload": {
    "deploymentId": "dpl_xxx",
    "name": "my-project",
    "project": "prj_xxx",
    "url": "my-project-abc123.vercel.app",
    "target": "production",
    "meta": { /* git info */ }
  }
}
```

**Verify webhook signature:**
```ts
import crypto from 'crypto';

export async function POST(request: Request) {
  const body = await request.text();
  const signature = request.headers.get('x-vercel-signature');
  const secret = process.env.WEBHOOK_SECRET!;

  const hash = crypto.createHmac('sha1', secret).update(body).digest('hex');
  if (hash !== signature) {
    return Response.json({ error: 'Invalid signature' }, { status: 401 });
  }

  const event = JSON.parse(body);
  // Process event...
  return Response.json({ received: true });
}
```

**Available webhook events:**
- `deployment.created`, `deployment.succeeded`, `deployment.failed`, `deployment.canceled`, `deployment.error`
- `project.created`, `project.removed`
- `domain.created`, `domain.removed`
- `integration-configuration.removed`

---

## Integration with GitHub / GitLab APIs

### GitHub Integration

Vercel's GitHub integration auto-deploys on push. For custom workflows:

```yaml
# .github/workflows/vercel-deploy.yml
name: Vercel Deploy
on:
  push:
    branches: [main, staging]
  pull_request:
    types: [opened, synchronize]

env:
  VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}
  VERCEL_PROJECT_ID: ${{ secrets.VERCEL_PROJECT_ID }}

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Vercel CLI
        run: npm install -g vercel

      - name: Pull Vercel Environment
        run: vercel pull --yes --environment=${{ github.ref == 'refs/heads/main' && 'production' || 'preview' }} --token=${{ secrets.VERCEL_TOKEN }}

      - name: Build
        run: vercel build ${{ github.ref == 'refs/heads/main' && '--prod' || '' }} --token=${{ secrets.VERCEL_TOKEN }}

      - name: Deploy
        id: deploy
        run: |
          URL=$(vercel deploy --prebuilt ${{ github.ref == 'refs/heads/main' && '--prod' || '' }} --token=${{ secrets.VERCEL_TOKEN }})
          echo "url=$URL" >> "$GITHUB_OUTPUT"

      - name: Comment PR with Preview URL
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: `🚀 Preview: ${{ steps.deploy.outputs.url }}`
            });
```

### GitLab Integration

```yaml
# .gitlab-ci.yml
stages:
  - deploy

variables:
  VERCEL_ORG_ID: $VERCEL_ORG_ID
  VERCEL_PROJECT_ID: $VERCEL_PROJECT_ID

deploy_preview:
  stage: deploy
  image: node:22
  script:
    - npm i -g vercel
    - vercel pull --yes --environment=preview --token=$VERCEL_TOKEN
    - vercel build --token=$VERCEL_TOKEN
    - DEPLOY_URL=$(vercel deploy --prebuilt --token=$VERCEL_TOKEN)
    - echo "Preview URL - $DEPLOY_URL"
  except:
    - main

deploy_production:
  stage: deploy
  image: node:22
  script:
    - npm i -g vercel
    - vercel pull --yes --environment=production --token=$VERCEL_TOKEN
    - vercel build --prod --token=$VERCEL_TOKEN
    - vercel deploy --prebuilt --prod --token=$VERCEL_TOKEN
  only:
    - main
```

### Getting Required Secrets

```bash
# 1. Install and authenticate
npm i -g vercel
vercel login

# 2. Link project
vercel link

# 3. Get org and project IDs
cat .vercel/project.json
# {"orgId":"team_xxx","projectId":"prj_xxx"}

# 4. Create deployment token
# Go to: vercel.com/account/tokens
# Or: Team Settings → Tokens (for team-scoped token)
```

---

## Vercel SDK for Programmatic Deployments

### @vercel/sdk (Official SDK)

```bash
npm install @vercel/sdk
```

```ts
import { Vercel } from '@vercel/sdk';

const vercel = new Vercel({ bearerToken: process.env.VERCEL_TOKEN });

// List projects
const { projects } = await vercel.projects.getProjects();

// Get project details
const project = await vercel.projects.getProject({ idOrName: 'my-project' });

// Create deployment
const deployment = await vercel.deployments.createDeployment({
  requestBody: {
    name: 'my-project',
    project: 'prj_xxx',
    target: 'production',
    gitSource: {
      type: 'github',
      ref: 'main',
      repoId: '123456789',
    },
  },
});

// List deployments
const { deployments } = await vercel.deployments.getDeployments({
  projectId: 'prj_xxx',
  limit: 10,
  state: 'READY',
});

// Manage environment variables
await vercel.projects.createProjectEnv({
  idOrName: 'my-project',
  requestBody: {
    key: 'API_SECRET',
    value: 'secret-value',
    type: 'encrypted',
    target: ['production'],
  },
});

// Manage domains
await vercel.projects.addProjectDomain({
  idOrName: 'my-project',
  requestBody: { name: 'custom.example.com' },
});
```

### File-Based Deployments

Upload files directly via API (no Git):

```ts
import { Vercel } from '@vercel/sdk';
import fs from 'fs';
import crypto from 'crypto';

const vercel = new Vercel({ bearerToken: process.env.VERCEL_TOKEN });

// 1. Calculate file hashes
const files = [
  { file: 'index.html', data: fs.readFileSync('dist/index.html') },
  { file: 'styles.css', data: fs.readFileSync('dist/styles.css') },
];

const fileHashes = files.map(f => ({
  file: f.file,
  sha: crypto.createHash('sha1').update(f.data).digest('hex'),
  size: f.data.length,
}));

// 2. Upload missing files
for (const f of files) {
  await fetch('https://api.vercel.com/v2/files', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.VERCEL_TOKEN}`,
      'Content-Type': 'application/octet-stream',
      'x-vercel-digest': crypto.createHash('sha1').update(f.data).digest('hex'),
    },
    body: f.data,
  });
}

// 3. Create deployment with file references
const deployment = await fetch('https://api.vercel.com/v13/deployments', {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${process.env.VERCEL_TOKEN}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    name: 'my-static-site',
    files: fileHashes,
    target: 'production',
  }),
});
```

---

## Edge Config API

Edge Config provides ultra-low latency reads (<1ms) from the edge. Ideal for feature flags, A/B tests, maintenance mode, redirects.

### Setup

```bash
npm install @vercel/edge-config
```

The `EDGE_CONFIG` env var is auto-set when you connect an Edge Config store to your project in Dashboard → Storage.

### Read API

```ts
import { get, getAll, has, digest } from '@vercel/edge-config';

// Single value
const maintenanceMode = await get<boolean>('maintenance');

// Multiple values
const config = await getAll<{ maintenance: boolean; featureFlags: Record<string, boolean> }>();

// Check existence
const exists = await has('maintenance');

// Get digest (version hash) for cache invalidation
const hash = await digest();
```

### Write API (REST)

Edge Config is read-only from the SDK. Write via REST API:

```bash
# Get Edge Config ID from Dashboard → Storage → Edge Config

# Read all items
curl "https://api.vercel.com/v1/edge-config/ecfg_xxx/items" \
  -H "Authorization: Bearer $VERCEL_TOKEN"

# Update items (upsert)
curl -X PATCH "https://api.vercel.com/v1/edge-config/ecfg_xxx/items" \
  -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "items": [
      { "operation": "upsert", "key": "maintenance", "value": true },
      { "operation": "upsert", "key": "featureFlags", "value": { "newUI": true, "darkMode": false } },
      { "operation": "delete", "key": "deprecated-key" }
    ]
  }'
```

### Usage Patterns

```ts
// Feature flags
import { get } from '@vercel/edge-config';

export async function middleware(request: NextRequest) {
  const flags = await get<Record<string, boolean>>('featureFlags');
  if (flags?.newCheckout && request.nextUrl.pathname === '/checkout') {
    return NextResponse.rewrite(new URL('/checkout-v2', request.url));
  }
  return NextResponse.next();
}

// Maintenance mode
export async function middleware(request: NextRequest) {
  const maintenance = await get<boolean>('maintenance');
  if (maintenance && !request.nextUrl.pathname.startsWith('/api/health')) {
    return NextResponse.rewrite(new URL('/maintenance', request.url));
  }
  return NextResponse.next();
}

// Dynamic redirects
export async function middleware(request: NextRequest) {
  const redirects = await get<Record<string, string>>('redirects');
  const destination = redirects?.[request.nextUrl.pathname];
  if (destination) {
    return NextResponse.redirect(new URL(destination, request.url), 308);
  }
  return NextResponse.next();
}
```

---

## Storage APIs

### Upstash Redis (KV)

```bash
npm install @upstash/redis
```

```ts
import { Redis } from '@upstash/redis';

// Auto-reads UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN
const redis = Redis.fromEnv();

// Basic operations
await redis.set('key', 'value');
await redis.set('key', 'value', { ex: 3600 }); // TTL: 1 hour
const value = await redis.get<string>('key');
await redis.del('key');

// JSON
await redis.set('user:123', { name: 'Alice', role: 'admin' });
const user = await redis.get<{ name: string; role: string }>('user:123');

// Hash
await redis.hset('session:abc', { userId: '123', role: 'admin' });
const session = await redis.hgetall<{ userId: string; role: string }>('session:abc');

// List
await redis.lpush('queue', 'task1', 'task2');
const task = await redis.rpop('queue');

// Sorted Set
await redis.zadd('leaderboard', { score: 100, member: 'player1' });
const top10 = await redis.zrange('leaderboard', 0, 9, { rev: true });

// Pipeline (batch operations)
const pipeline = redis.pipeline();
pipeline.set('a', '1');
pipeline.set('b', '2');
pipeline.get('a');
const results = await pipeline.exec(); // [null, null, '1']

// Rate limiting
import { Ratelimit } from '@upstash/ratelimit';

const ratelimit = new Ratelimit({
  redis,
  limiter: Ratelimit.slidingWindow(10, '10 s'), // 10 requests per 10 seconds
});

const { success } = await ratelimit.limit('user_123');
```

### Vercel Blob

```bash
npm install @vercel/blob
```

```ts
import { put, del, list, head, copy } from '@vercel/blob';

// Upload (server-side)
const blob = await put('documents/report.pdf', fileBuffer, {
  access: 'public',
  contentType: 'application/pdf',
  addRandomSuffix: true, // Prevents name collisions (default: true)
});
// blob.url = https://<store>.public.blob.vercel-storage.com/documents/report-abc123.pdf

// Upload with no random suffix
const blob2 = await put('config/settings.json', jsonString, {
  access: 'public',
  addRandomSuffix: false,
  cacheControlMaxAge: 3600,
});

// List blobs
const { blobs, cursor, hasMore } = await list({
  prefix: 'documents/',
  limit: 100,
});
// Paginate
const nextPage = await list({ prefix: 'documents/', cursor });

// Get blob metadata
const metadata = await head(blob.url);
// { url, size, contentType, uploadedAt, ... }

// Copy a blob
const copied = await copy(blob.url, 'documents/report-copy.pdf', { access: 'public' });

// Delete a blob
await del(blob.url);
// Delete multiple
await del([blob1.url, blob2.url]);

// Client-side upload (requires server handler)
// Server: app/api/upload/route.ts
import { handleUpload, type HandleUploadBody } from '@vercel/blob';

export async function POST(request: Request) {
  const body = (await request.json()) as HandleUploadBody;
  const response = await handleUpload({
    body,
    request,
    onBeforeGenerateToken: async (pathname) => {
      // Validate user, check permissions
      return {
        allowedContentTypes: ['image/jpeg', 'image/png', 'image/webp'],
        maximumSizeInBytes: 10 * 1024 * 1024, // 10 MB
      };
    },
    onUploadCompleted: async ({ blob }) => {
      // Save blob.url to database
      console.log('Upload completed:', blob.url);
    },
  });
  return Response.json(response);
}

// Client component
import { upload } from '@vercel/blob/client';

const blob = await upload(file.name, file, {
  access: 'public',
  handleUploadUrl: '/api/upload',
});
```

### Vercel Postgres

```bash
npm install @vercel/postgres
```

```ts
import { sql, db } from '@vercel/postgres';

// Tagged template (auto-parameterized, prevents SQL injection)
const { rows } = await sql`SELECT * FROM users WHERE id = ${userId}`;
const user = rows[0];

// Insert
await sql`INSERT INTO users (name, email) VALUES (${name}, ${email})`;

// Update
await sql`UPDATE users SET name = ${newName} WHERE id = ${userId}`;

// Delete
await sql`DELETE FROM users WHERE id = ${userId}`;

// Transaction
const client = await db.connect();
try {
  await client.sql`BEGIN`;
  await client.sql`UPDATE accounts SET balance = balance - ${amount} WHERE id = ${from}`;
  await client.sql`UPDATE accounts SET balance = balance + ${amount} WHERE id = ${to}`;
  await client.sql`COMMIT`;
} catch (e) {
  await client.sql`ROLLBACK`;
  throw e;
} finally {
  client.release();
}

// Create tables
await sql`
  CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
  )
`;
```

**Using with ORMs:**

```ts
// Prisma — schema.prisma
// datasource db {
//   provider  = "postgresql"
//   url       = env("POSTGRES_PRISMA_URL")     // Pooled connection
//   directUrl = env("POSTGRES_URL_NON_POOLING") // For migrations
// }

// Drizzle
import { drizzle } from 'drizzle-orm/vercel-postgres';
import { sql as vercelSql } from '@vercel/postgres';

const db = drizzle(vercelSql);
const users = await db.select().from(usersTable).where(eq(usersTable.id, userId));
```

**Connection strings (auto-set by Vercel):**
| Env Var | Purpose |
|---------|---------|
| `POSTGRES_URL` | Pooled connection (use in serverless) |
| `POSTGRES_URL_NON_POOLING` | Direct connection (use for migrations) |
| `POSTGRES_PRISMA_URL` | Pooled + Prisma-compatible params |
| `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DATABASE` | Individual components |
