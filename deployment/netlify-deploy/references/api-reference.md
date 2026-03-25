# Netlify API Reference

## Table of Contents

- [Authentication](#authentication)
  - [Personal Access Tokens](#personal-access-tokens)
  - [OAuth2 Flow](#oauth2-flow)
- [REST API Endpoints](#rest-api-endpoints)
  - [Sites API](#sites-api)
  - [Deploys API](#deploys-api)
  - [Functions API](#functions-api)
  - [Forms API](#forms-api)
  - [Submissions API](#submissions-api)
  - [Files API](#files-api)
- [Deploy Hooks and Build Hooks](#deploy-hooks-and-build-hooks)
- [Webhook Events](#webhook-events)
- [DNS API](#dns-api)
- [Split Testing API](#split-testing-api)
- [Identity API (GoTrue)](#identity-api-gotrue)
  - [User Management](#user-management)
  - [Token Operations](#token-operations)
  - [Admin Endpoints](#admin-endpoints)
- [Netlify CLI Commands Reference](#netlify-cli-commands-reference)
  - [Site Management](#site-management)
  - [Deploy Commands](#deploy-commands)
  - [Environment Variables](#environment-variables)
  - [Functions Commands](#functions-commands)
  - [Dev Server](#dev-server)
  - [Addons and Plugins](#addons-and-plugins)

---

## Authentication

Base URL: `https://api.netlify.com/api/v1`

### Personal Access Tokens

Generate at https://app.netlify.com/user/applications#personal-access-tokens.

```bash
# Header-based auth (recommended)
curl -H "Authorization: Bearer $NETLIFY_AUTH_TOKEN" \
  https://api.netlify.com/api/v1/sites

# Query parameter auth (less secure)
curl "https://api.netlify.com/api/v1/sites?access_token=$NETLIFY_AUTH_TOKEN"
```

### OAuth2 Flow

For apps authenticating on behalf of users:

```
1. Register app at https://app.netlify.com/user/applications
2. Redirect user to:
   https://app.netlify.com/authorize?
     response_type=ticket&
     client_id=YOUR_CLIENT_ID

3. User approves, receives ticket
4. Exchange ticket for access token:

   POST https://api.netlify.com/oauth/token
   Content-Type: application/x-www-form-urlencoded

   grant_type=authorization_code&
   code=TICKET&
   client_id=YOUR_CLIENT_ID&
   client_secret=YOUR_CLIENT_SECRET
```

```typescript
// OAuth token exchange
const response = await fetch("https://api.netlify.com/oauth/token", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({
    grant_type: "authorization_code",
    code: ticket,
    client_id: process.env.NETLIFY_CLIENT_ID!,
    client_secret: process.env.NETLIFY_CLIENT_SECRET!,
  }),
});
const { access_token } = await response.json();
```

---

## REST API Endpoints

### Sites API

```bash
# List all sites
GET /sites
GET /sites?filter=all&page=1&per_page=100

# Get specific site
GET /sites/{site_id}

# Create site
POST /sites
{
  "name": "my-new-site",
  "custom_domain": "example.com",
  "repo": {
    "provider": "github",
    "repo_path": "user/repo",
    "branch": "main",
    "cmd": "npm run build",
    "dir": "dist"
  }
}

# Update site settings
PATCH /sites/{site_id}
{
  "build_settings": {
    "cmd": "npm run build",
    "dir": "dist",
    "env": {
      "NODE_VERSION": "20"
    }
  }
}

# Delete site
DELETE /sites/{site_id}
```

```typescript
// List sites with fetch
const API = "https://api.netlify.com/api/v1";
const headers = { Authorization: `Bearer ${process.env.NETLIFY_AUTH_TOKEN}` };

const sites = await fetch(`${API}/sites`, { headers }).then((r) => r.json());
console.log(sites.map((s: any) => ({ name: s.name, url: s.ssl_url })));
```

### Deploys API

```bash
# List deploys for a site
GET /sites/{site_id}/deploys
GET /sites/{site_id}/deploys?page=1&per_page=20

# Get specific deploy
GET /deploys/{deploy_id}

# Create deploy (start)
POST /sites/{site_id}/deploys
{
  "title": "Deploy via API",
  "branch": "main",
  "draft": false
}

# Upload file to deploy
PUT /deploys/{deploy_id}/files/{path}
Content-Type: application/octet-stream
# Body: raw file content

# Lock deploy (prevent auto-publishing)
POST /deploys/{deploy_id}/lock

# Unlock deploy
POST /deploys/{deploy_id}/unlock

# Restore (rollback) to a previous deploy
POST /sites/{site_id}/rollback
{ "deploy_id": "previous_deploy_id" }

# Cancel deploy
POST /deploys/{deploy_id}/cancel
```

#### Programmatic Deploy (Upload Files)

```typescript
// Step 1: Create deploy with file digests
const deploy = await fetch(`${API}/sites/${siteId}/deploys`, {
  method: "POST",
  headers: { ...headers, "Content-Type": "application/json" },
  body: JSON.stringify({
    files: {
      "/index.html": sha1OfIndexHtml,
      "/styles.css": sha1OfStylesCss,
    },
    draft: false,
  }),
}).then((r) => r.json());

// Step 2: Upload only files Netlify doesn't already have
for (const filePath of deploy.required) {
  const content = readFileSync(`.${filePath}`);
  await fetch(`${API}/deploys/${deploy.id}/files${filePath}`, {
    method: "PUT",
    headers: { ...headers, "Content-Type": "application/octet-stream" },
    body: content,
  });
}
// Deploy auto-publishes when all required files are uploaded
```

### Functions API

```bash
# List functions for a site
GET /sites/{site_id}/functions

# Get function metadata
GET /sites/{site_id}/functions/{function_name}

# Get function log (recent invocations)
GET /sites/{site_id}/functions/{function_name}/log

# Invoke function
POST https://{site_name}.netlify.app/.netlify/functions/{function_name}
Content-Type: application/json
{ "key": "value" }
```

### Forms API

```bash
# List forms for a site
GET /sites/{site_id}/forms

# Get specific form
GET /forms/{form_id}

# Delete form
DELETE /forms/{form_id}

# List form submissions
GET /forms/{form_id}/submissions
GET /forms/{form_id}/submissions?page=1&per_page=100

# Get specific submission
GET /submissions/{submission_id}

# Delete submission
DELETE /submissions/{submission_id}
```

```typescript
// Fetch all form submissions
const forms = await fetch(`${API}/sites/${siteId}/forms`, { headers })
  .then((r) => r.json());

for (const form of forms) {
  const submissions = await fetch(`${API}/forms/${form.id}/submissions`, { headers })
    .then((r) => r.json());
  console.log(`Form "${form.name}": ${submissions.length} submissions`);
}
```

### Submissions API

```bash
# List submissions for a site (all forms)
GET /sites/{site_id}/submissions

# Get specific submission with file URLs
GET /submissions/{submission_id}

# Export submissions as CSV
GET /sites/{site_id}/submissions?page=1&per_page=100
# Process response as CSV client-side
```

### Files API

```bash
# List files in a deploy
GET /deploys/{deploy_id}/files

# Get specific file metadata
GET /deploys/{deploy_id}/files/{path}

# Upload file
PUT /deploys/{deploy_id}/files/{path}
Content-Type: application/octet-stream
```

---

## Deploy Hooks and Build Hooks

### Build Hooks (Incoming)

Create at Site Settings > Build & deploy > Build hooks.

```bash
# Trigger production build
curl -X POST https://api.netlify.com/build_hooks/{hook_id}

# Trigger specific branch
curl -X POST "https://api.netlify.com/build_hooks/{hook_id}?trigger_branch=staging"

# Trigger with title
curl -X POST -d '{}' \
  "https://api.netlify.com/build_hooks/{hook_id}?trigger_title=CMS+update"

# Trigger with clear cache
curl -X POST -d '{"clear_cache": true}' \
  -H "Content-Type: application/json" \
  "https://api.netlify.com/build_hooks/{hook_id}"
```

### Deploy Hooks (API)

```bash
# List deploy hooks
GET /sites/{site_id}/deploy_hooks

# Create deploy hook
POST /sites/{site_id}/deploy_hooks
{
  "title": "CMS Publish Hook",
  "branch": "main"
}

# Delete deploy hook
DELETE /deploy_hooks/{hook_id}
```

### Outgoing Webhooks (Notification Hooks)

```bash
# List notification hooks
GET /sites/{site_id}/notifications

# Create notification hook
POST /sites/{site_id}/notifications
{
  "type": "url",
  "event": "deploy_created",
  "data": {
    "url": "https://your-app.com/webhook/netlify"
  }
}

# Events: deploy_building, deploy_created, deploy_failed,
#          deploy_locked, deploy_unlocked, submission_created
```

---

## Webhook Events

When configuring outgoing webhooks, Netlify sends POST requests with these
payloads:

### Deploy Events

```json
// POST to your webhook URL
// Event: deploy_created
{
  "id": "deploy_id",
  "site_id": "site_id",
  "build_id": "build_id",
  "state": "ready",
  "name": "my-site",
  "url": "https://my-site.netlify.app",
  "ssl_url": "https://my-site.netlify.app",
  "deploy_url": "https://deploy-id--my-site.netlify.app",
  "deploy_ssl_url": "https://deploy-id--my-site.netlify.app",
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:32:00Z",
  "published_at": "2024-01-15T10:32:00Z",
  "branch": "main",
  "commit_ref": "abc123",
  "commit_url": "https://github.com/user/repo/commit/abc123",
  "review_url": "",
  "title": "Deploy via push",
  "context": "production",
  "deploy_time": 120,
  "framework": "next",
  "locked": false,
  "log_access_attributes": { "type": "firebase", "url": "...", "endpoint": "..." }
}
```

### Form Submission Events

```json
// Event: submission_created
{
  "id": "submission_id",
  "form_id": "form_id",
  "form_name": "contact",
  "site_url": "https://my-site.netlify.app",
  "data": {
    "name": "Jane Doe",
    "email": "jane@example.com",
    "message": "Hello!"
  },
  "created_at": "2024-01-15T10:30:00Z",
  "human_fields": {
    "Name": "Jane Doe",
    "Email": "jane@example.com",
    "Message": "Hello!"
  }
}
```

---

## DNS API

Requires Netlify DNS (nameservers pointed to Netlify).

```bash
# List DNS zones
GET /dns_zones
GET /dns_zones?account_slug={account_slug}

# Get DNS zone
GET /dns_zones/{zone_id}

# Create DNS zone
POST /dns_zones
{ "account_slug": "my-team", "name": "example.com" }

# Delete DNS zone
DELETE /dns_zones/{zone_id}

# List DNS records
GET /dns_zones/{zone_id}/dns_records

# Create DNS record
POST /dns_zones/{zone_id}/dns_records
{
  "type": "A",
  "hostname": "example.com",
  "value": "75.2.60.5",
  "ttl": 3600
}

# Create CNAME
POST /dns_zones/{zone_id}/dns_records
{
  "type": "CNAME",
  "hostname": "www.example.com",
  "value": "my-site.netlify.app",
  "ttl": 3600
}

# Create MX record
POST /dns_zones/{zone_id}/dns_records
{
  "type": "MX",
  "hostname": "example.com",
  "value": "mail.example.com",
  "priority": 10,
  "ttl": 3600
}

# Delete DNS record
DELETE /dns_zones/{zone_id}/dns_records/{record_id}
```

---

## Split Testing API

```bash
# Get split test status
GET /sites/{site_id}/traffic_splits

# Create/update split test
POST /sites/{site_id}/traffic_splits
{
  "branch_tests": {
    "main": 80,
    "experiment-branch": 20
  }
}

# Enable split test
POST /sites/{site_id}/traffic_splits/{split_id}/publish

# Disable split test
POST /sites/{site_id}/traffic_splits/{split_id}/unpublish

# Update split ratios
PUT /sites/{site_id}/traffic_splits/{split_id}
{
  "branch_tests": {
    "main": 50,
    "experiment-branch": 50
  }
}
```

---

## Identity API (GoTrue)

Base URL: `https://{site}.netlify.app/.netlify/identity`

### User Management

```bash
# Get settings (public)
GET /.netlify/identity/settings

# Sign up
POST /.netlify/identity/signup
{
  "email": "user@example.com",
  "password": "securepassword",
  "data": {
    "full_name": "Jane Doe"
  }
}

# Confirm signup (from email link)
POST /.netlify/identity/verify
{ "token": "confirmation_token" }

# Log in
POST /.netlify/identity/token
Content-Type: application/x-www-form-urlencoded
grant_type=password&username=user@example.com&password=securepassword

# Response:
{
  "access_token": "eyJ...",
  "token_type": "bearer",
  "expires_in": 3600,
  "refresh_token": "refresh_token_value"
}
```

### Token Operations

```bash
# Refresh token
POST /.netlify/identity/token
Content-Type: application/x-www-form-urlencoded
grant_type=refresh_token&refresh_token=REFRESH_TOKEN

# Get user info
GET /.netlify/identity/user
Authorization: Bearer ACCESS_TOKEN

# Update user
PUT /.netlify/identity/user
Authorization: Bearer ACCESS_TOKEN
{
  "data": {
    "full_name": "Jane Smith"
  }
}

# Request password recovery
POST /.netlify/identity/recover
{ "email": "user@example.com" }

# Logout (invalidate refresh token)
POST /.netlify/identity/logout
Authorization: Bearer ACCESS_TOKEN
```

### Admin Endpoints

Require admin token (generated in Identity settings).

```bash
# List users
GET /.netlify/identity/admin/users
Authorization: Bearer ADMIN_TOKEN

# Get user by ID
GET /.netlify/identity/admin/users/{user_id}
Authorization: Bearer ADMIN_TOKEN

# Create user (skip confirmation)
POST /.netlify/identity/admin/users
Authorization: Bearer ADMIN_TOKEN
{
  "email": "admin@example.com",
  "password": "securepassword",
  "confirm": true,
  "app_metadata": {
    "roles": ["admin"]
  },
  "user_metadata": {
    "full_name": "Admin User"
  }
}

# Update user (set roles)
PUT /.netlify/identity/admin/users/{user_id}
Authorization: Bearer ADMIN_TOKEN
{
  "app_metadata": {
    "roles": ["admin", "editor"]
  }
}

# Delete user
DELETE /.netlify/identity/admin/users/{user_id}
Authorization: Bearer ADMIN_TOKEN
```

---

## Netlify CLI Commands Reference

### Site Management

```bash
netlify login                           # authenticate with Netlify
netlify login --new                     # force re-authentication
netlify logout                          # clear stored credentials
netlify status                          # show current user and linked site
netlify switch                          # switch active account
netlify sites:list                      # list all sites
netlify sites:create                    # create new site interactively
netlify sites:create --name my-site     # create with specific name
netlify sites:delete <site_id>          # delete a site
netlify link                            # link directory to site
netlify link --id <site_id>             # link by site ID
netlify link --name <site_name>         # link by name
netlify unlink                          # unlink directory from site
netlify open                            # open site admin in browser
netlify open --site                     # open deployed site in browser
netlify open --admin                    # open admin panel
netlify api <endpoint>                  # raw API call
netlify api listSites --data '{}'       # API with data
```

### Deploy Commands

```bash
netlify deploy                          # draft deploy (preview URL)
netlify deploy --prod                   # production deploy
netlify deploy --dir=dist               # specify publish directory
netlify deploy --dir=dist --prod        # production with dir
netlify deploy --alias=feature-x        # custom subdomain alias
netlify deploy --branch=staging         # deploy as branch deploy
netlify deploy --message "v1.2.3"       # deploy with message
netlify deploy --json                   # output as JSON
netlify deploy --timeout 1200           # set upload timeout (seconds)
netlify build                           # run build locally
netlify build --dry                     # dry run (show steps)
netlify build --debug                   # verbose build output
netlify build --context deploy-preview  # build with specific context
```

### Environment Variables

```bash
netlify env:list                        # list all variables
netlify env:get VAR_NAME                # get variable value
netlify env:set VAR_NAME "value"        # set variable (all contexts)
netlify env:set VAR_NAME "val" --context production
netlify env:set VAR_NAME "val" --context deploy-preview
netlify env:set VAR_NAME "val" --scope builds
netlify env:set VAR_NAME "val" --scope functions
netlify env:set VAR_NAME "val" --scope runtime
netlify env:unset VAR_NAME              # remove variable
netlify env:import .env                 # import from .env file
netlify env:clone --to <site_id>        # clone vars to another site
```

### Functions Commands

```bash
netlify functions:list                  # list deployed functions
netlify functions:create               # scaffold a new function
netlify functions:create --name hello  # scaffold with name
netlify functions:invoke hello         # invoke locally
netlify functions:invoke hello --payload '{"key":"val"}'
netlify functions:invoke hello --identity  # with mock identity
netlify functions:serve                # serve functions locally
```

### Dev Server

```bash
netlify dev                             # start local dev server
netlify dev --port 8888                 # custom port
netlify dev --targetPort 3000           # proxy to framework dev server
netlify dev --live                      # shareable tunnel URL
netlify dev --context production        # use production env vars
netlify dev --command "npm run dev"     # custom dev command
netlify dev --framework react           # specify framework
netlify dev --functions ./functions     # custom functions dir
netlify dev --edgeInspect               # enable edge function debugging
netlify dev --edgeInspect=127.0.0.1:9229
```

### Addons and Plugins

```bash
netlify addons:list                     # list active addons
netlify addons:create <addon>           # add addon to site
netlify addons:auth <addon>             # authenticate addon
netlify addons:config <addon>           # configure addon
netlify addons:delete <addon>           # remove addon

# Logs
netlify watch                           # watch deploy progress
netlify logs:function <name>            # stream function logs
netlify logs:function                   # stream all function logs

# Domains
netlify domains:list                    # list custom domains
netlify domains:add <domain>            # add custom domain

# Blobs (key-value store)
netlify blobs:list <store>              # list blobs in store
netlify blobs:get <store> <key>         # get blob value
netlify blobs:set <store> <key> <val>   # set blob value
netlify blobs:delete <store> <key>      # delete blob
```
