# Sentry API Reference

## Table of Contents

- [Authentication](#authentication)
  - [Auth Tokens](#auth-tokens)
  - [DSN (Data Source Name)](#dsn-data-source-name)
  - [API Keys (Deprecated)](#api-keys-deprecated)
  - [Scopes and Permissions](#scopes-and-permissions)
- [Web API Endpoints](#web-api-endpoints)
  - [Base URL and Versioning](#base-url-and-versioning)
  - [Projects API](#projects-api)
  - [Issues API](#issues-api)
  - [Events API](#events-api)
  - [Releases API](#releases-api)
  - [Deploys API](#deploys-api)
- [Webhook Integrations](#webhook-integrations)
  - [Configuring Webhooks](#configuring-webhooks)
  - [Webhook Payload Formats](#webhook-payload-formats)
  - [Verifying Webhook Signatures](#verifying-webhook-signatures)
  - [Common Webhook Use Cases](#common-webhook-use-cases)
- [Issue and Event Management via API](#issue-and-event-management-via-api)
  - [Bulk Issue Operations](#bulk-issue-operations)
  - [Issue Assignment and Ownership](#issue-assignment-and-ownership)
  - [Event Search and Filtering](#event-search-and-filtering)
  - [Issue Merge and Unmerge](#issue-merge-and-unmerge)
- [Release and Deploy Tracking API](#release-and-deploy-tracking-api)
  - [Creating Releases](#creating-releases)
  - [Associating Commits](#associating-commits)
  - [Uploading Artifacts](#uploading-artifacts)
  - [Deploy Registration](#deploy-registration)
  - [Release Health Queries](#release-health-queries)
- [Organization and Team Management](#organization-and-team-management)
  - [Organization API](#organization-api)
  - [Team API](#team-api)
  - [Member Management](#member-management)
  - [Project Team Assignment](#project-team-assignment)
- [Rate Limits and Pagination](#rate-limits-and-pagination)
  - [Rate Limit Headers](#rate-limit-headers)
  - [Cursor-Based Pagination](#cursor-based-pagination)
  - [Best Practices for API Usage](#best-practices-for-api-usage)
- [SDK Hooks and Lifecycle Methods](#sdk-hooks-and-lifecycle-methods)
  - [Client Hooks](#client-hooks)
  - [Scope Methods](#scope-methods)
  - [Transport Interface](#transport-interface)
  - [Integration Interface](#integration-interface)

---

## Authentication

### Auth Tokens

Auth tokens are the primary authentication method for the Sentry API.
Generate tokens at **Settings → Auth Tokens** or via the `sentry-cli`.

```bash
# Using auth token with curl
curl -H "Authorization: Bearer YOUR_AUTH_TOKEN" \
  https://sentry.io/api/0/organizations/

# Using with sentry-cli (environment variable)
export SENTRY_AUTH_TOKEN="sntrys_eyJ..."

# Using with sentry-cli (.sentryclirc file)
# ~/.sentryclirc or project/.sentryclirc
[auth]
token=sntrys_eyJ...
```

**Token types:**
- **User Auth Tokens**: Scoped to your user permissions across all orgs
- **Organization Auth Tokens**: Scoped to a single org (recommended for CI/CD)
- **Internal Integration Tokens**: Created via custom Sentry integrations, scoped to
  specific resources

### DSN (Data Source Name)

DSN is used by SDKs to send events. It is NOT used for the Web API.

```
Format: https://<public_key>@<host>/<project_id>

Example: https://abc123@o456.ingest.sentry.io/789

Components:
  - public_key: abc123 (identifies the project)
  - host: o456.ingest.sentry.io (ingest endpoint)
  - project_id: 789 (numeric project identifier)
```

DSN is safe to expose in client-side code (it's a public key). Configure per-key
rate limits in Project Settings → Client Keys to prevent abuse.

### API Keys (Deprecated)

Legacy API keys are deprecated in favor of auth tokens. If you still have API keys,
migrate to auth tokens.

```bash
# Legacy API key usage (deprecated)
curl -u API_KEY: https://sentry.io/api/0/projects/

# Migrate to auth token
curl -H "Authorization: Bearer AUTH_TOKEN" https://sentry.io/api/0/projects/
```

### Scopes and Permissions

Auth tokens require specific scopes. Common scope groups:

| Scope | Purpose |
|---|---|
| `event:read` | Read events and issues |
| `event:write` | Update/resolve issues |
| `event:admin` | Delete events/issues |
| `project:read` | List and read projects |
| `project:write` | Update project settings |
| `project:releases` | Manage releases and source maps |
| `org:read` | Read org info, teams, members |
| `org:write` | Update org settings |
| `team:read` | Read team info |
| `team:write` | Create/update teams |
| `member:read` | Read member info |
| `member:write` | Invite/update members |
| `alerts:read` | Read alert rules |
| `alerts:write` | Create/update alert rules |

---

## Web API Endpoints

### Base URL and Versioning

```
Base URL: https://sentry.io/api/0/
Self-hosted: https://your-sentry.example.com/api/0/

All endpoints are prefixed with /api/0/
The "0" is the API version (currently the only version).
Content-Type: application/json (for request and response bodies)
```

### Projects API

```bash
# List all projects in an organization
GET /api/0/organizations/{org_slug}/projects/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/projects/"

# Get project details
GET /api/0/projects/{org_slug}/{project_slug}/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/my-org/my-project/"

# Update project settings
PUT /api/0/projects/{org_slug}/{project_slug}/
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "My Project", "slug": "my-project", "platform": "javascript"}' \
  "https://sentry.io/api/0/projects/my-org/my-project/"

# Delete a project
DELETE /api/0/projects/{org_slug}/{project_slug}/
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/my-org/my-project/"

# List project client keys (DSNs)
GET /api/0/projects/{org_slug}/{project_slug}/keys/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/my-org/my-project/keys/"
```

### Issues API

```bash
# List issues in a project
GET /api/0/projects/{org_slug}/{project_slug}/issues/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/my-org/my-project/issues/?query=is:unresolved"

# Query parameters:
#   query      - Search query (same syntax as Sentry UI)
#   sort       - "date", "new", "priority", "freq", "user"
#   statsPeriod - "24h", "14d", etc.

# Get issue details
GET /api/0/organizations/{org_slug}/issues/{issue_id}/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/"

# Update issue status
PUT /api/0/organizations/{org_slug}/issues/{issue_id}/
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "resolved", "statusDetails": {"inRelease": "my-app@1.2.3"}}' \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/"

# Possible status values: "resolved", "unresolved", "ignored"
# statusDetails for resolved: {"inRelease": "version"}, {"inCommit": {"commit": "sha"}}
# statusDetails for ignored: {"ignoreDuration": 30}, {"ignoreCount": 100}

# Delete an issue
DELETE /api/0/organizations/{org_slug}/issues/{issue_id}/
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/"

# List issue events
GET /api/0/organizations/{org_slug}/issues/{issue_id}/events/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/events/"

# List issue hashes (grouped events)
GET /api/0/organizations/{org_slug}/issues/{issue_id}/hashes/
```

### Events API

```bash
# Get event details
GET /api/0/organizations/{org_slug}/events/{event_id}/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/events/abc123def456/"

# Get latest event for an issue
GET /api/0/organizations/{org_slug}/issues/{issue_id}/events/latest/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/events/latest/"

# Get oldest event for an issue
GET /api/0/organizations/{org_slug}/issues/{issue_id}/events/oldest/

# Discover query (cross-project event search)
GET /api/0/organizations/{org_slug}/events/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/events/?field=title&field=count()&query=error.type:TypeError&sort=-count"

# Discover query parameters:
#   field       - Fields to return (repeatable)
#   query       - Search query
#   sort        - Sort field (prefix with - for desc)
#   statsPeriod - Time window ("1h", "24h", "7d", "14d", "30d")
#   project     - Project ID filter (repeatable)
```

### Releases API

```bash
# List releases
GET /api/0/organizations/{org_slug}/releases/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/releases/?project=my-project"

# Create a release
POST /api/0/organizations/{org_slug}/releases/
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "version": "my-app@1.2.3",
    "projects": ["my-project"],
    "refs": [{"repository": "my-org/my-repo", "commit": "abc123"}]
  }' \
  "https://sentry.io/api/0/organizations/my-org/releases/"

# Get release details
GET /api/0/organizations/{org_slug}/releases/{version}/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/"

# Update release (e.g., finalize)
PUT /api/0/organizations/{org_slug}/releases/{version}/
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"dateReleased": "2024-01-15T12:00:00Z"}' \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/"

# Delete a release
DELETE /api/0/organizations/{org_slug}/releases/{version}/

# List release files (source maps, artifacts)
GET /api/0/organizations/{org_slug}/releases/{version}/files/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/files/"

# Upload a release file
POST /api/0/organizations/{org_slug}/releases/{version}/files/
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -F "file=@./dist/app.js.map" \
  -F "name=~/static/js/app.js.map" \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/files/"
```

### Deploys API

```bash
# List deploys for a release
GET /api/0/organizations/{org_slug}/releases/{version}/deploys/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/deploys/"

# Create a deploy
POST /api/0/organizations/{org_slug}/releases/{version}/deploys/
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "environment": "production",
    "name": "Deploy #42",
    "dateStarted": "2024-01-15T11:55:00Z",
    "dateFinished": "2024-01-15T12:00:00Z"
  }' \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/deploys/"
```

---

## Webhook Integrations

### Configuring Webhooks

Set up webhooks in **Settings → Integrations → Internal Integration** or
**Settings → Developer Settings → Webhooks**.

Supported webhook resource types:
- `issue` — New issue, issue status change, issue assigned
- `error` — New error event received
- `comment` — Comment added to issue
- `alert_rule_action` — Alert rule triggered
- `installation` — Integration installed/uninstalled

### Webhook Payload Formats

**Issue webhook (issue created):**

```json
{
  "action": "created",
  "installation": { "uuid": "..." },
  "data": {
    "issue": {
      "id": "12345",
      "title": "TypeError: Cannot read property 'map' of undefined",
      "culprit": "app/components/UserList.tsx",
      "shortId": "MY-PROJECT-ABC",
      "level": "error",
      "status": "unresolved",
      "platform": "javascript",
      "project": { "id": "1", "slug": "my-project", "name": "My Project" },
      "firstSeen": "2024-01-15T12:00:00Z",
      "lastSeen": "2024-01-15T12:05:00Z",
      "count": "5",
      "metadata": {
        "type": "TypeError",
        "value": "Cannot read property 'map' of undefined"
      }
    }
  },
  "actor": { "type": "application", "id": "...", "name": "..." }
}
```

**Alert rule action webhook:**

```json
{
  "action": "triggered",
  "data": {
    "event": {
      "event_id": "abc123...",
      "title": "Error in payment processing",
      "level": "error",
      "url": "https://sentry.io/organizations/my-org/issues/12345/events/abc123/"
    },
    "triggered_rule": "P0 Payment Errors"
  }
}
```

### Verifying Webhook Signatures

Sentry signs webhook payloads with HMAC-SHA256. Verify to prevent spoofing:

```typescript
import crypto from "crypto";

function verifyWebhookSignature(
  payload: string,
  signature: string,
  secret: string
): boolean {
  const expected = crypto
    .createHmac("sha256", secret)
    .update(payload, "utf-8")
    .digest("hex");
  return crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(expected)
  );
}

// Express middleware
app.post("/webhooks/sentry", express.text({ type: "*/*" }), (req, res) => {
  const signature = req.headers["sentry-hook-signature"] as string;
  if (!verifyWebhookSignature(req.body, signature, WEBHOOK_SECRET)) {
    return res.status(401).send("Invalid signature");
  }

  const event = JSON.parse(req.body);
  // Process webhook...
  res.status(200).send("OK");
});
```

```python
import hmac
import hashlib

def verify_signature(payload: bytes, signature: str, secret: str) -> bool:
    expected = hmac.new(
        secret.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)

# Django view
from django.http import HttpResponse
from django.views.decorators.csrf import csrf_exempt

@csrf_exempt
def sentry_webhook(request):
    signature = request.headers.get("Sentry-Hook-Signature", "")
    if not verify_signature(request.body, signature, WEBHOOK_SECRET):
        return HttpResponse(status=401)

    data = json.loads(request.body)
    # Process webhook...
    return HttpResponse(status=200)
```

### Common Webhook Use Cases

1. **Slack notification for new P0 issues:**
   - Trigger: `issue` → `created` where level=`fatal`
   - Action: POST to Slack webhook URL with formatted message

2. **Auto-create Jira ticket on error spike:**
   - Trigger: `alert_rule_action` → `triggered`
   - Action: Create Jira issue via Jira API

3. **Deploy status updates:**
   - Use the Deploys API to mark deploys, then set up a webhook on `issue`
     events to detect regressions in new releases

4. **Custom dashboard metrics:**
   - Trigger: `error` events
   - Action: Forward to custom metrics pipeline (Prometheus, StatsD)

---

## Issue and Event Management via API

### Bulk Issue Operations

```bash
# Bulk update issues (resolve, ignore, assign)
PUT /api/0/projects/{org_slug}/{project_slug}/issues/
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "resolved"}' \
  "https://sentry.io/api/0/projects/my-org/my-project/issues/?id=1&id=2&id=3"

# Bulk delete issues
DELETE /api/0/projects/{org_slug}/{project_slug}/issues/
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/my-org/my-project/issues/?id=1&id=2&id=3"

# Resolve all unresolved issues matching a query
PUT /api/0/projects/{org_slug}/{project_slug}/issues/
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "resolved", "statusDetails": {"inRelease": "latest"}}' \
  "https://sentry.io/api/0/projects/my-org/my-project/issues/?query=is:unresolved+release:my-app@1.0.0"
```

### Issue Assignment and Ownership

```bash
# Assign issue to a user
PUT /api/0/organizations/{org_slug}/issues/{issue_id}/
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"assignedTo": "user:jane@example.com"}' \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/"

# Assign to team
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"assignedTo": "team:backend-team"}' \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/"

# Unassign
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"assignedTo": ""}' \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/"
```

### Event Search and Filtering

Use Discover queries for advanced event search:

```bash
# Search for events by error type
GET /api/0/organizations/{org_slug}/events/?field=title&field=count()&query=error.type:TypeError

# Search with multiple filters
GET /api/0/organizations/{org_slug}/events/?
  field=title&
  field=count()&
  field=last_seen()&
  query=release:my-app@1.2.3+environment:production&
  sort=-count&
  statsPeriod=24h

# Tag-based search
GET /api/0/organizations/{org_slug}/events/?
  field=title&
  field=count()&
  query=tags[tenant]:acme-corp&
  project=12345
```

### Issue Merge and Unmerge

```bash
# Merge issues (group multiple issues into one)
PUT /api/0/organizations/{org_slug}/issues/{primary_issue_id}/
curl -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"merge": true}' \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/?id=12346&id=12347"
# Issues 12346 and 12347 are merged into 12345

# Unmerge (via hashes)
# 1. Get hashes for the issue
GET /api/0/organizations/{org_slug}/issues/{issue_id}/hashes/
# 2. Delete specific hashes to unmerge them
DELETE /api/0/organizations/{org_slug}/issues/{issue_id}/hashes/
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/issues/12345/hashes/?id=hash1&id=hash2"
```

---

## Release and Deploy Tracking API

### Creating Releases

```bash
# Create release with full metadata
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "version": "my-app@1.2.3",
    "projects": ["my-project", "my-api"],
    "url": "https://github.com/my-org/my-repo/releases/tag/v1.2.3",
    "refs": [{
      "repository": "my-org/my-repo",
      "commit": "abc123def456",
      "previousCommit": "789xyz"
    }],
    "dateReleased": "2024-01-15T12:00:00Z"
  }' \
  "https://sentry.io/api/0/organizations/my-org/releases/"
```

### Associating Commits

```bash
# Associate commits with a release (for Suspect Commits feature)
PATCH /api/0/organizations/{org_slug}/releases/{version}/
curl -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "refs": [{
      "repository": "my-org/my-repo",
      "commit": "abc123",
      "previousCommit": "xyz789"
    }]
  }' \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/"

# Or use sentry-cli for automatic commit association
sentry-cli releases set-commits --auto "my-app@1.2.3"
```

### Uploading Artifacts

```bash
# Upload source map via API
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -F "file=@./dist/bundle.js.map" \
  -F "name=~/static/js/bundle.js.map" \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/files/"

# Upload using debug info files (for native crashes)
# Use sentry-cli for this workflow:
sentry-cli debug-files upload --org my-org --project my-project ./build/symbols/
```

### Deploy Registration

```bash
# Register a deploy after release is created
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "environment": "production",
    "name": "Deploy v1.2.3 to prod"
  }' \
  "https://sentry.io/api/0/organizations/my-org/releases/my-app@1.2.3/deploys/"

# sentry-cli equivalent
sentry-cli releases deploys "my-app@1.2.3" new \
  -e production \
  -n "Deploy v1.2.3 to prod"
```

### Release Health Queries

```bash
# Get release health stats
GET /api/0/organizations/{org_slug}/releases/{version}/
# Response includes: crashFreeUsers, crashFreeSessions, adoption

# Get session data for a release
GET /api/0/organizations/{org_slug}/sessions/?
  project=12345&
  field=sum(session)&
  field=count_unique(user)&
  field=crash_free_rate(session)&
  groupBy=release&
  query=release:my-app@1.2.3&
  statsPeriod=24h
```

---

## Organization and Team Management

### Organization API

```bash
# Get org details
GET /api/0/organizations/{org_slug}/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/"

# List orgs the token has access to
GET /api/0/organizations/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/"

# Get org stats (event counts, quota usage)
GET /api/0/organizations/{org_slug}/stats_v2/?
  field=sum(quantity)&
  groupBy=category&
  category=error&
  statsPeriod=24h
```

### Team API

```bash
# List teams
GET /api/0/organizations/{org_slug}/teams/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/teams/"

# Create team
POST /api/0/organizations/{org_slug}/teams/
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "Backend Team", "slug": "backend-team"}' \
  "https://sentry.io/api/0/organizations/my-org/teams/"

# Delete team
DELETE /api/0/teams/{org_slug}/{team_slug}/
```

### Member Management

```bash
# List org members
GET /api/0/organizations/{org_slug}/members/
curl -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/organizations/my-org/members/"

# Invite a member
POST /api/0/organizations/{org_slug}/members/
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email": "jane@example.com", "role": "member", "teams": ["backend-team"]}' \
  "https://sentry.io/api/0/organizations/my-org/members/"

# Roles: "owner", "manager", "admin", "member", "billing"

# Remove a member
DELETE /api/0/organizations/{org_slug}/members/{member_id}/
```

### Project Team Assignment

```bash
# Add team to project
POST /api/0/projects/{org_slug}/{project_slug}/teams/{team_slug}/
curl -X POST -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/my-org/my-project/teams/backend-team/"

# Remove team from project
DELETE /api/0/projects/{org_slug}/{project_slug}/teams/{team_slug}/
```

---

## Rate Limits and Pagination

### Rate Limit Headers

Every API response includes rate limit headers:

```
X-Sentry-Rate-Limit-Limit: 100       # Max requests per window
X-Sentry-Rate-Limit-Remaining: 87    # Remaining requests
X-Sentry-Rate-Limit-Reset: 1705312800 # Unix timestamp when limit resets
```

When rate limited (HTTP 429):

```json
{
  "detail": "You are being rate limited.",
  "retryAfter": 1705312800
}
```

**Handle 429 responses:**

```typescript
async function sentryApiCall(url: string, token: string): Promise<any> {
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (response.status === 429) {
    const retryAfter = parseInt(response.headers.get("Retry-After") || "60");
    await new Promise((resolve) => setTimeout(resolve, retryAfter * 1000));
    return sentryApiCall(url, token); // Retry
  }

  return response.json();
}
```

### Cursor-Based Pagination

Sentry uses cursor-based pagination via `Link` headers:

```
Link: <https://sentry.io/api/0/organizations/my-org/issues/?cursor=1705312800:0:1>;
  rel="previous"; results="false",
  <https://sentry.io/api/0/organizations/my-org/issues/?cursor=1705312800:100:0>;
  rel="next"; results="true"
```

**Parse pagination in code:**

```typescript
async function* paginateIssues(orgSlug: string, token: string) {
  let url: string | null =
    `https://sentry.io/api/0/organizations/${orgSlug}/issues/?query=is:unresolved`;

  while (url) {
    const response = await fetch(url, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const issues = await response.json();
    yield issues;

    // Parse Link header for next page
    const linkHeader = response.headers.get("Link") || "";
    const nextMatch = linkHeader.match(/<([^>]+)>;\s*rel="next";\s*results="true"/);
    url = nextMatch ? nextMatch[1] : null;
  }
}

// Usage
for await (const page of paginateIssues("my-org", token)) {
  for (const issue of page) {
    console.log(issue.title);
  }
}
```

```python
import requests

def paginate_issues(org_slug: str, token: str):
    url = f"https://sentry.io/api/0/organizations/{org_slug}/issues/"
    params = {"query": "is:unresolved"}
    headers = {"Authorization": f"Bearer {token}"}

    while url:
        response = requests.get(url, headers=headers, params=params)
        response.raise_for_status()
        yield response.json()

        # Parse Link header
        links = response.links
        if "next" in links and links["next"].get("results") == "true":
            url = links["next"]["url"]
            params = {}  # params are in the URL now
        else:
            url = None

for page in paginate_issues("my-org", token):
    for issue in page:
        print(issue["title"])
```

### Best Practices for API Usage

1. **Respect rate limits**: Implement exponential backoff on 429s
2. **Use pagination**: Never assume all results fit in one response
3. **Cache aggressively**: Issues and events don't change frequently
4. **Use webhooks for real-time**: Don't poll the API for new events
5. **Batch operations**: Use bulk endpoints instead of one-by-one updates
6. **Scope tokens tightly**: Only request the scopes you actually need
7. **Use org-scoped tokens for CI/CD**: Don't use user tokens in pipelines

---

## SDK Hooks and Lifecycle Methods

### Client Hooks

The Sentry client exposes hooks for advanced customization:

```typescript
const client = Sentry.getClient();

// Listen for envelope send events
client?.on("beforeEnvelope", (envelope) => {
  // Inspect or modify the raw envelope before network send
  // Useful for custom telemetry or debugging
});

// Listen for finished spans
client?.on("spanEnd", (span) => {
  console.log(`Span finished: ${span.name} (${span.endTimestamp - span.startTimestamp}ms)`);
});

// Listen for dropped events
client?.on("afterSendEvent", (event, sendResponse) => {
  if (sendResponse.statusCode === 429) {
    console.warn("Event rate limited by Sentry");
  }
});
```

### Scope Methods

```typescript
// Get and manipulate the current scope
const scope = Sentry.getCurrentScope();

scope.setUser({ id: "123", email: "user@example.com" });
scope.setTag("key", "value");
scope.setExtra("key", { any: "data" });
scope.setContext("contextName", { key: "value" });
scope.setLevel("warning");
scope.setFingerprint(["my-fingerprint"]);
scope.addBreadcrumb({ message: "something happened" });
scope.setTransactionName("GET /api/users");
scope.addAttachment({ filename: "log.txt", data: "log content" });

// Clear scope
scope.clear();

// Isolation scope — creates a new scope fork for request isolation
Sentry.withIsolationScope((isolationScope) => {
  isolationScope.setUser({ id: "456" }); // Only applies within this scope
  handleRequest();
});

// withScope — temporary scope modifications
Sentry.withScope((scope) => {
  scope.setTag("temporary", "true");
  Sentry.captureMessage("scoped message");
});
// Tags are reverted after withScope exits
```

### Transport Interface

The transport is responsible for sending envelopes to Sentry:

```typescript
interface Transport {
  send(envelope: Envelope): PromiseLike<TransportMakeRequestResponse>;
  flush(timeout?: number): PromiseLike<boolean>;
}

// Built-in transports:
// - makeFetchTransport (browser & Node.js 18+)
// - makeNodeTransport (Node.js, uses http/https modules)

// Create a custom transport
function makeMyTransport(options: BaseTransportOptions): Transport {
  return {
    send(envelope) {
      // Custom send logic
      const serialized = serializeEnvelope(envelope);
      return myCustomHttpClient.post(options.url, serialized);
    },
    flush(timeout) {
      return Promise.resolve(true);
    },
  };
}
```

### Integration Interface

```typescript
interface Integration {
  name: string;

  // Called once during Sentry.init()
  setupOnce?(): void;

  // Called with the client instance
  setup?(client: Client): void;

  // Process every event before beforeSend
  processEvent?(event: Event, hint: EventHint, client: Client): Event | null;

  // Called for each span that starts
  // Useful for adding data to spans
  preprocessEvent?(event: Event, hint: EventHint, client: Client): void;
}

// Example: integration that adds git info to every event
const gitIntegration: Integration = {
  name: "GitInfo",
  processEvent(event) {
    event.contexts = {
      ...event.contexts,
      git: {
        branch: process.env.GIT_BRANCH,
        commit: process.env.GIT_COMMIT,
      },
    };
    return event;
  },
};
```
