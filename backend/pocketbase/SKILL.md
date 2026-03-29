---
name: pocketbase
description: |
  Open-source SQLite backend with realtime subscriptions. Use for rapid prototyping.
  NOT for large-scale multi-tenant applications needing PostgreSQL.
---

# PocketBase

Single-file backend: SQLite + realtime + auth + file storage. Deploy as binary or Docker.

## Quick Start

```bash
# Download binary
curl -L https://github.com/pocketbase/pocketbase/releases/latest/download/pocketbase_linux_amd64.zip -o pb.zip
unzip pb.zip && chmod +x pocketbase

# Start server
./pocketbase serve
# Admin UI: http://127.0.0.1:8090/_/ (create first admin)
# API: http://127.0.0.1:8090/api/
```

## Core Concepts

| Feature | Description |
|---------|-------------|
| **Collections** | Tables (SQLite) with auto-generated REST API |
| **Records** | Rows with typed fields + metadata |
| **Auth** | Built-in email/password, OAuth2, JWT tokens |
| **Realtime** | SSE subscriptions to record changes |
| **Storage** | File uploads with S3-compatible backend |
| **Rules** | Access control via Go-like expressions |

## Collections

### Create via Admin UI

1. Go to `/_/collections`
2. Click "Create new collection"
3. Define fields:
   - `name` (text, required)
   - `email` (email, unique)
   - `avatar` (file, single)
   - `status` (select: active|inactive)
   - `metadata` (json)

### API Schema

```http
GET /api/collections/posts/records
POST /api/collections/posts/records
PATCH /api/collections/posts/records/:id
DELETE /api/collections/posts/records/:id
```

## JavaScript SDK

```bash
npm install pocketbase
```

```javascript
import PocketBase from 'pocketbase';

const pb = new PocketBase('http://127.0.0.1:8090');

// Auth
await pb.collection('users').authWithPassword('user@example.com', 'password123');
console.log(pb.authStore.token);  // JWT

// CRUD
const record = await pb.collection('posts').create({
  title: 'Hello World',
  content: 'Body text',
  author: pb.authStore.model?.id
});

const records = await pb.collection('posts').getList(1, 20, {
  filter: 'status = "published"',
  sort: '-created',
  expand: 'author'
});

// Update
await pb.collection('posts').update(record.id, { title: 'Updated' });

// Delete
await pb.collection('posts').delete(record.id);
```

### Realtime Subscriptions

```javascript
// Subscribe to all changes
pb.collection('posts').subscribe('*', (e) => {
  console.log(e.action, e.record);  // create, update, delete
});

// Subscribe to specific record
pb.collection('posts').subscribe('RECORD_ID', (e) => {
  console.log('Record changed:', e.record);
});

// Filtered subscription
pb.collection('posts').subscribe('*', (e) => {
  if (e.record.author === currentUserId) {
    console.log('My post changed');
  }
});

// Unsubscribe
pb.collection('posts').unsubscribe();  // all
pb.collection('posts').unsubscribe('RECORD_ID');  // specific
```

### File Handling

```javascript
// Upload
const formData = new FormData();
formData.append('title', 'My Post');
formData.append('attachment', fileInput.files[0]);

const record = await pb.collection('posts').create(formData);

// Get file URL
const url = pb.files.getUrl(record, record.attachment);
// Output: http://127.0.0.1:8090/api/files/posts/RECORD_ID/filename.jpg

// Download with auth
const fileUrl = pb.files.getUrl(record, record.attachment, { token: pb.authStore.token });
```

## Go SDK (Custom Routes)

```go
package main

import (
    "log"
    "net/http"
    
    "github.com/pocketbase/pocketbase"
    "github.com/pocketbase/pocketbase/core"
)

func main() {
    app := pocketbase.New()
    
    // Custom route
    app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
        e.Router.GET("/api/hello", func(c echo.Context) error {
            return c.JSON(200, map[string]string{"message": "Hello"})
        })
        return nil
    })
    
    // Hook: before create
    app.OnRecordBeforeCreateRequest("posts").Add(func(e *core.RecordCreateEvent) error {
        // Auto-set slug from title
        title := e.Record.GetString("title")
        e.Record.Set("slug", slug.Make(title))
        return nil
    })
    
    // Hook: after create - send notification
    app.OnRecordAfterCreateRequest("posts").Add(func(e *core.RecordCreateEvent) error {
        go sendNotification(e.Record.GetString("author"))
        return nil
    })
    
    if err := app.Start(); err != nil {
        log.Fatal(err)
    }
}
```

### Go: Direct Database Access

```go
// Raw SQL
results, err := app.Dao().DB().NewQuery(`
    SELECT * FROM posts WHERE status = 'published' ORDER BY created DESC
`).Execute()

// Using DAO
posts, err := app.Dao().FindRecordsByFilter("posts", "status = 'published'", "-created", 10, 0)

// Transaction
err := app.Dao().RunInTransaction(func(txDao *daos.Dao) error {
    record := models.NewRecord(collection)
    record.Set("title", "Transaction Test")
    return txDao.SaveRecord(record)
})
```

## Access Rules

Rules use Go-like syntax. Available variables: `@request.*`, `@collection.*`

### Collection-Level Rules

```
List/Search Rule:   @request.auth.id != "" && status = "published"
View Rule:          status = "published" || author = @request.auth.id
Create Rule:        @request.auth.id != ""
Update Rule:        author = @request.auth.id
Delete Rule:        author = @request.auth.id || @request.auth.role = "admin"
```

### Field-Level Rules

```
// Only author can see draft content
@request.auth.id = author || status = "published"

// Email only visible to owner
@request.auth.id = id

// Admin-only field
@request.auth.role = "admin"
```
### Common Patterns

```
# User owns record
author = @request.auth.id

# Public read, auth write
List:   true
Create: @request.auth.id != ""

# Team-based access
@request.auth.id ?= members.id

# Time-based (published posts)
status = "published" && published <= @now
```

## Auth Providers

### Email/Password

```javascript
// Register
await pb.collection('users').create({
  email: 'user@example.com',
  password: 'securepass123',
  passwordConfirm: 'securepass123',
  name: 'John Doe'
});
// Login
await pb.collection('users').authWithPassword('user@example.com', 'securepass123');

// OAuth2
await pb.collection('users').authWithOAuth2({ provider: 'google' });
```

### Custom Auth Collection

```javascript
// Create "vendors" collection with "Authenticate" option enabled
await pb.collection('vendors').authWithPassword('vendor@corp.com', 'pass123');
```

## Self-Hosting

### Binary

```bash
./pocketbase serve --http="0.0.0.0:8090" --dir="./pb_data"
```

### Docker

```dockerfile
FROM ghcr.io/m/pocketbase:latest
EXPOSE 8090
CMD ["serve", "--http=0.0.0.0:8090"]
```

```yaml
# docker-compose.yml
version: '3.8'
services:
  pocketbase:
    image: ghcr.io/m/pocketbase:latest
    ports:
      - "8090:8090"
    volumes:
      - ./pb_data:/pb/pb_data
      - ./pb_public:/pb/pb_public
    command: serve --http=0.0.0.0:8090
```

### Environment Variables

```bash
# No native env var support - use hooks
app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
    smtpHost := os.Getenv("SMTP_HOST")
    // Configure settings...
    return nil
})
```

## Scaling Considerations

| Limit | Reality |
|-------|---------|
| SQLite | Single-node only. Use Litestream for replication |
| Concurrent | ~1000-5000 concurrent connections |
| File Storage | Local filesystem or S3-compatible |
| Horizontal | Run multiple instances + shared S3 + SQLite replication |

### Litestream Replication

```bash
# litestream.yml
dbs:
  - path: /pb_data/data.db
    replicas:
      - url: s3://mybucket/pb-backup

# Run
litestream replicate -exec "./pocketbase serve"
```

### S3 Storage

```javascript
// Admin UI: Settings > File storage
app.Dao().SaveSettings(&models.Settings{
    S3: models.S3Config{
        Enabled:   true,
        Endpoint:  "s3.amazonaws.com",
        Bucket:    "my-bucket",
        Region:    "us-east-1",
        AccessKey: os.Getenv("AWS_ACCESS_KEY"),
        Secret:    os.Getenv("AWS_SECRET_KEY"),
    },
})
```

## Migrations

```bash
# Create migration
./pocketbase migrate create "add_posts_collection"

# Generated: pb_migrations/1234567890_add_posts_collection.go
```

```go
// pb_migrations/1234567890_add_posts_collection.go
package migrations

import (
    "github.com/pocketbase/pocketbase/daos"
    "github.com/pocketbase/pocketbase/models/schema"
    "github.com/pocketbase/pocketbase/tools/types"
)

func init() {
    AppMigrations.Register(func(db dbx.Builder) error {
        dao := daos.New(db)
        
        collection := &models.Collection{
            Name: "posts",
            Schema: schema.NewSchema(
                &schema.SchemaField{
                    Name:     "title",
                    Type:     schema.FieldTypeText,
                    Required: true,
                },
                &schema.SchemaField{
                    Name: "content",
                    Type: schema.FieldTypeText,
                },
            ),
        }
        
        return dao.SaveCollection(collection)
    }, nil)
}
```

## Backup & Restore

```bash
# Backup (SQLite is just a file)
cp pb_data/data.db pb_data/data.db.backup.$(date +%Y%m%d)

# Restore
systemctl stop pocketbase
cp pb_data/data.db.backup.20240101 pb_data/data.db
systemctl start pocketbase

# Automated with cron
0 2 * * * sqlite3 /pb_data/data.db ".backup /backups/pb_$(date +\%Y\%m\%d).db"
```

## Testing

```javascript
// test/setup.js
import PocketBase from 'pocketbase';
import { execSync } from 'child_process';

let pb;

beforeAll(async () => {
  execSync('./pocketbase serve --dir=./pb_test_data &');
  await new Promise(r => setTimeout(r, 2000));
  pb = new PocketBase('http://127.0.0.1:8090');
});

afterAll(() => {
  pb.authStore.clear();
  execSync('rm -rf ./pb_test_data');
});

it('creates record', async () => {
  const record = await pb.collection('posts').create({ title: 'Test' });
  expect(record.title).toBe('Test');
});
```

## Common Patterns

### Soft Delete

```javascript
// Add "deleted" boolean field
// List rule: deleted = false || @request.auth.role = "admin"
// Delete action: PATCH { deleted: true }
```

### Rate Limiting (Go hook)

```go
import "golang.org/x/time/rate"

var limiter = rate.NewLimiter(rate.Every(time.Second), 10)

app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
    e.Router.Use(func(next echo.HandlerFunc) echo.HandlerFunc {
        return func(c echo.Context) error {
            if !limiter.Allow() {
                return echo.NewHTTPError(429, "Too many requests")
            }
            return next(c)
        }
    })
    return nil
})
```

### Webhook on Change

```go
app.OnRecordAfterCreateRequest("orders").Add(func(e *core.RecordCreateEvent) error {
    go http.Post("https://api.example.com/webhook", "application/json",
        strings.NewReader(fmt.Sprintf(`{"order":"%s"}`, e.Record.Id)))
    return nil
})
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Failed to create record` | Check field validation, unique constraints |
| `403 Forbidden` | Verify access rules, auth token |
| `Realtime not working` | Check CORS, use SSE not WebSocket |
| `File upload fails` | Check max file size, storage quota |
| `Slow queries` | Add indexes, use `?fields=` to limit response |

## SDK Quick Reference

```javascript
// Pagination
const result = await pb.collection('posts').getList(1, 30, {
  filter: 'created >= "2024-01-01"',
  sort: '-created,title',
  expand: 'author',
  fields: 'id,title,expand.author.name'
});

// Full list
const all = await pb.collection('posts').getFullList({ filter: 'status = "published"' });

// Single record
const record = await pb.collection('posts').getOne('RECORD_ID', { expand: 'author' });

// First matching
const first = await pb.collection('posts').getFirstListItem('slug = "hello-world"');
```
