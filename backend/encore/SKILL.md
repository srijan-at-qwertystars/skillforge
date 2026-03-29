---
name: encore
description: |
  Backend development platform with automatic APIs. Use for rapid backend development.
  NOT for complex microservices requiring custom infrastructure.
---

# Encore

Backend development platform that eliminates boilerplate. Define APIs, databases, and infrastructure in Go/TypeScript—Encore generates the rest.

## When to Use

**Use Encore:**
- Rapid API development
- Services needing built-in observability
- Teams wanting infrastructure-as-code without YAML hell
- Prototypes moving to production

**Don't Use Encore:**
- Existing complex microservices (migration pain)
- Need custom Kubernetes operators
- Require specific cloud provider primitives Encore doesn't abstract

## Installation

```bash
# macOS
brew install encoredev/tap/encore

# Linux
curl -L https://encore.dev/install.sh | bash

# Verify
encore version
```

## App Structure

```
my-app/
├── encore.app          # App identifier
├── go.mod / package.json
├── .env                # Local secrets (gitignored)
└── service-name/       # One directory per service
    ├── api.go          # API endpoints
    ├── db.go           # Database definitions
    └── pubsub.go       # Pub/sub topics
```

### encore.app

```yaml
id: my-app-id
```

## API Endpoints

### Go

```go
//encore:api public method=GET path=/hello/:name
type HelloParams struct {
    Name string `json:"name"`
}

type HelloResponse struct {
    Message string `json:"message"`
}

func Hello(ctx context.Context, p *HelloParams) (*HelloResponse, error) {
    return &HelloResponse{Message: "Hello, " + p.Name}, nil
}
```

### TypeScript

```typescript
import { api } from "encore.dev/api";

interface HelloParams { name: string; }
interface HelloResponse { message: string; }

export const hello = api<HelloParams, HelloResponse>(
    { method: "GET", path: "/hello/:name", expose: true },
    async ({ name }) => ({ message: `Hello, ${name}` })
);
```

### Endpoint Options

```go
//encore:api public method=POST path=/webhook raw    // raw HTTP access
//encore:api auth method=PUT path=/profile           // requires auth
//encore:api private method=DELETE path=/cache     // service-only
```

## Databases

### Define

```go
import "encore.dev/storage/sqldb"

var DB = sqldb.NewDatabase("service-db", sqldb.DatabaseOptions{
    Migrations: "./migrations",
})
```

```typescript
import { SQLDatabase } from "encore.dev/storage/sqldb";
export const DB = new SQLDatabase("service-db", { migrations: "./migrations" });
```

### Migrations

```sql
-- migrations/001_create_users.up.sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);
```

### Query

```go
row := DB.QueryRow(ctx, `SELECT id, email FROM users WHERE id = $1`, id)
var u User
err := row.Scan(&u.ID, &u.Email)
```

```typescript
const row = await DB.queryRow`SELECT id, email FROM users WHERE id = ${id}`;
```

## Pub/Sub

### Define Topic

```go
import "encore.dev/pubsub"

type OrderEvent struct {
    OrderID string  `json:"order_id"`
    Amount  float64 `json:"amount"`
}

var OrderTopic = pubsub.NewTopic[*OrderEvent]("order-events", pubsub.TopicOptions{
    DeliveryGuarantee: pubsub.AtLeastOnce,
})
```

```typescript
import { Topic } from "encore.dev/pubsub";

interface OrderEvent { orderId: string; amount: number; }

export const OrderTopic = new Topic<OrderEvent>("order-events", {
    deliveryGuarantee: "at-least-once",
});
```

### Publish

```go
_, err := OrderTopic.Publish(ctx, &OrderEvent{OrderID: "123", Amount: 99.99})
```

```typescript
await OrderTopic.publish({ orderId: "123", amount: 99.99 });
```

### Subscribe

```go
//encore:api private
func ProcessOrder(ctx context.Context, event *OrderEvent) error {
    return nil
}

var _ = pubsub.NewSubscription(OrderTopic, "process-order", pubsub.SubscriptionOptions[*OrderEvent]{
    Handler: ProcessOrder,
})
```

```typescript
import { Subscription } from "encore.dev/pubsub";

const _ = new Subscription(OrderTopic, "process-order", {
    handler: async (event) => { /* handle */ },
});
```

## Secrets

### Define

```go
import "encore.dev/config"

var secrets struct {
    StripeKey config.String `encore:"stripe_key"`
}
```

```typescript
import { secret } from "encore.dev/config";
export const stripeKey = secret("STRIPE_KEY");
```

### Set

```bash
encore secret set --local STRIPE_KEY sk_test_...
encore secret set --dev STRIPE_KEY sk_test_...
encore secret set --prod STRIPE_KEY sk_live_...
```

### Use

```go
apiKey := secrets.StripeKey.Get()
```

```typescript
const apiKey = stripeKey.value();
```

## Authentication

### Auth Handler

```go
import "encore.dev/beta/auth"
import "encore.dev/beta/errs"

type AuthData struct {
    UserID string `json:"user_id"`
}

//encore:api public method=POST path=/auth/login
func Login(ctx context.Context, p *LoginParams) (*AuthData, error) {
    // Validate, return auth data
}

func AuthHandler(ctx context.Context, token string) (*AuthData, error) {
    // Validate JWT, return AuthData or error
    return nil, errs.B().Code(errs.Unauthenticated).Msg("invalid token").Err()
}
```

### Protected Endpoint

```go
//encore:api auth method=GET path=/profile
func GetProfile(ctx context.Context) (*Profile, error) {
    data := auth.Data().(*AuthData)
    return loadProfile(ctx, data.UserID)
}
```

## Cron Jobs

```go
import "encore.dev/cron"

//encore:api private
func Cleanup(ctx context.Context) error { return nil }

var _ = cron.NewJob("cleanup", cron.JobOptions{
    Title:    "Cleanup",
    Every:    cron.Hour,
    Endpoint: Cleanup,
})
```

```typescript
import { CronJob } from "encore.dev/cron";

const _ = new CronJob("cleanup", {
    title: "Cleanup",
    every: "1h",
    endpoint: cleanup,
});
```

## Caching

```go
import "encore.dev/storage/cache"

var Cluster = cache.NewCluster("cache", cache.ClusterOptions{
    EvictionPolicy: cache.AllKeysLRU,
})

var UserCache = cache.NewKeyspace[string, *User](Cluster, cache.KeyspaceOptions{
    KeyPattern: "user:{id}",
    TTL: cache.Minute * 5,
})

// Use
err := UserCache.Set(ctx, userID, user)
user, err := UserCache.Get(ctx, userID)
```

## Local Development

```bash
encore run              # Start dev server with hot reload
encore test             # Run tests
encore check            # Validate app
encore db reset         # Reset local database
encore db shell         # Access psql
```

Dashboard: `http://localhost:9400`

## Testing

```go
import "encore.dev/et"

func TestHello(t *testing.T) {
    ctx := context.Background()
    resp, err := Hello(ctx, &HelloParams{Name: "World"})
    // Assert...
}
```

```typescript
import { describe, expect, test } from "vitest";
import { hello } from "./api";

describe("hello", () => {
    test("returns greeting", async () => {
        const result = await hello({ name: "World" });
        expect(result.message).toBe("Hello, World");
    });
});
```

## Deployment

```bash
# Encore Cloud
encore cloud login
encore cloud apps create my-app
encore cloud deploy --env=prod
encore cloud logs --env=prod

# Self-hosted
encore build docker my-app:latest
encore build k8s --env=prod ./k8s/
```

## Best Practices

### Error Handling

```go
import "encore.dev/beta/errs"

return nil, errs.B().
    Code(errs.NotFound).
    Msg("user not found").
    Meta("user_id", userID).
    Err()
```

### Logging

```go
import "encore.dev/rlog"

rlog.Info("order processed", "order_id", id, "amount", amount)
rlog.Error("payment failed", err, "order_id", id)
```

### Service Boundaries

- Define database in same service that owns it
- Don't query another service's database directly
- Use APIs or pub/sub for cross-service communication

## Quick Reference

| Task | Command |
|------|---------|
| Dev server | `encore run` |
| Test | `encore test` |
| Set secret | `encore secret set --local KEY value` |
| Deploy | `encore cloud deploy --env=prod` |
| Logs | `encore cloud logs --env=prod` |
| Gen client | `encore gen client --lang=typescript` |
| Build Docker | `encore build docker my-app:latest` |

## Resources

- Docs: https://encore.dev/docs
- Examples: https://github.com/encoredev/examples
