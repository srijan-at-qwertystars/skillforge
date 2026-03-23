---
name: rest-api-design
description: |
  Use when user designs REST APIs, asks about resource naming, HTTP methods/status codes,
  pagination strategies, API versioning, error response format (RFC 7807/9457), rate limiting,
  HATEOAS, or OpenAPI/Swagger spec.
  Do NOT use for GraphQL (use graphql-schema-design skill), gRPC (use grpc-protobuf skill),
  or WebSocket APIs.
---

# REST API Design Best Practices

## Resource Naming

Use plural nouns. Never use verbs in resource paths.

```
GET    /users              # collection
GET    /users/42           # single resource
GET    /users/42/orders    # sub-resource (max 2 levels deep)
POST   /users              # create
```

Rules:
- Use lowercase with hyphens: `/order-items`, not `/orderItems` or `/order_items`.
- Use plural nouns: `/users`, `/products`, `/invoices`.
- Nest only one level deep. Flatten deeper hierarchies:
  - Good: `/users/42/orders`
  - Bad:  `/users/42/orders/7/items/3/reviews`
  - Better: `/order-items/3/reviews`
- Use path parameters for identity, query parameters for filtering.
- Keep resource names consistent across the entire API.

## HTTP Methods

| Method | Purpose | Safe | Idempotent | Request Body | Typical Response |
|--------|---------|------|------------|-------------|-----------------|
| GET | Read resource(s) | Yes | Yes | No | 200 with body |
| POST | Create resource / trigger action | No | No | Yes | 201 with Location header |
| PUT | Replace entire resource | No | Yes | Yes | 200 or 204 |
| PATCH | Partial update | No | Yes* | Yes | 200 with updated resource |
| DELETE | Remove resource | No | Yes | No | 204 |

*PATCH is idempotent when using JSON Merge Patch (RFC 7396). Not idempotent with JSON Patch (RFC 6902).

```http
POST /api/v1/users HTTP/1.1
Content-Type: application/json

{"name": "Ada Lovelace", "email": "ada@example.com"}
```

```http
HTTP/1.1 201 Created
Location: /api/v1/users/42
Content-Type: application/json

{"id": 42, "name": "Ada Lovelace", "email": "ada@example.com"}
```

Use POST for non-CRUD actions that don't map to a resource:

```
POST /users/42/activate
POST /reports/generate
```

## Status Codes

### 2xx Success
| Code | When to Use |
|------|-------------|
| 200 OK | GET succeeds, PUT/PATCH returns updated resource |
| 201 Created | POST creates a new resource; include Location header |
| 202 Accepted | Request queued for async processing |
| 204 No Content | DELETE succeeds, PUT/PATCH with no response body |

### 3xx Redirection
| Code | When to Use |
|------|-------------|
| 301 Moved Permanently | Resource URL changed permanently |
| 304 Not Modified | Conditional GET; client cache is still valid |

### 4xx Client Error
| Code | When to Use |
|------|-------------|
| 400 Bad Request | Malformed syntax, invalid parameters, validation failure |
| 401 Unauthorized | Missing or invalid authentication credentials |
| 403 Forbidden | Authenticated but lacks permission |
| 404 Not Found | Resource does not exist |
| 405 Method Not Allowed | HTTP method not supported on this endpoint |
| 409 Conflict | State conflict (duplicate, concurrent edit) |
| 413 Content Too Large | Request body exceeds size limit |
| 415 Unsupported Media Type | Content-Type not accepted |
| 422 Unprocessable Content | Syntactically valid but semantically invalid |
| 429 Too Many Requests | Rate limit exceeded; include Retry-After header |

### 5xx Server Error
| Code | When to Use |
|------|-------------|
| 500 Internal Server Error | Unhandled exception; never expose stack traces |
| 502 Bad Gateway | Upstream service failure |
| 503 Service Unavailable | Maintenance or overload; include Retry-After |
| 504 Gateway Timeout | Upstream service timed out |

## Error Response Format (RFC 9457 / RFC 7807)

Use RFC 9457 Problem Details. Set `Content-Type: application/problem+json`.

```http
HTTP/1.1 422 Unprocessable Content
Content-Type: application/problem+json

{
  "type": "https://api.example.com/errors/validation",
  "title": "Validation Error",
  "status": 422,
  "detail": "Request body contains invalid fields.",
  "instance": "/api/v1/users",
  "errors": [
    {"field": "email", "message": "Must be a valid email address."},
    {"field": "name", "message": "Required. Must be 1-100 characters."}
  ]
}
```

Required fields: `type`, `title`, `status`.
Recommended fields: `detail`, `instance`.
Extend with custom fields (`errors`, `traceId`) as needed.

Rules:
- Return the same error shape from every endpoint.
- Make `type` a stable, resolvable URI pointing to documentation.
- Never expose stack traces, internal paths, or SQL in `detail`.
- Include a `traceId` field for correlating with server logs.

## Pagination

### Cursor-Based (Preferred for Large/Dynamic Data)

```http
GET /api/v1/orders?limit=25&cursor=eyJpZCI6MTAwfQ== HTTP/1.1
```

```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "data": [ ... ],
  "pagination": {
    "next_cursor": "eyJpZCI6MTI1fQ==",
    "has_next": true
  }
}
```

Cursor pagination avoids offset drift and scales to millions of rows.

### Offset-Based (Simple, Allows Random Page Access)

```http
GET /api/v1/products?offset=40&limit=20 HTTP/1.1
```

```http
HTTP/1.1 200 OK

{
  "data": [ ... ],
  "pagination": {
    "offset": 40,
    "limit": 20,
    "total": 523
  }
}
```

Offset degrades on large tables. Use for admin UIs and small datasets only.

### Link Header (RFC 8288)

Include navigational links in the `Link` header or response body:

```http
Link: </api/v1/orders?cursor=abc123&limit=25>; rel="next",
      </api/v1/orders?limit=25>; rel="first"
```

Guidelines:
- Default `limit` to 25–50. Cap at 100.
- Return `total` count only if cheap to compute; omit on large tables.
- Use opaque, base64-encoded cursors so clients don't depend on internals.
- Always sort by a unique, indexed column (e.g., `id` or `created_at, id`).

## Filtering, Sorting, Field Selection

### Filtering

```http
GET /api/v1/orders?status=shipped&created_after=2025-01-01T00:00:00Z
```

- Use descriptive query parameter names.
- Support operators via suffixes for complex filters: `price_gte=10&price_lte=100`.
- Document all supported filters in OpenAPI spec.

### Sorting

```http
GET /api/v1/products?sort=-created_at,name
```

Prefix with `-` for descending. Comma-separate multiple fields.

### Field Selection (Sparse Fieldsets)

```http
GET /api/v1/users/42?fields=id,name,email
```

Reduce payload size. Useful for mobile clients and list views.

## Versioning

| Strategy | Example | Pros | Cons |
|----------|---------|------|------|
| URI path | `/api/v1/users` | Explicit, cacheable, easy routing | URL pollution, hard to sunset |
| Custom header | `Api-Version: 2` | Clean URLs | Harder to test, invisible in logs |
| Query param | `?version=2` | Easy to test | Breaks caching, clutters params |
| Content negotiation | `Accept: application/vnd.api.v2+json` | Standards-compliant | Complex, poor tooling support |

Recommend URI path versioning for most APIs. It is the most widely adopted approach.

Rules:
- Version from day one. Start at `v1`.
- Only increment for breaking changes.
- Support at most two versions concurrently.
- Announce deprecation via `Sunset` header (RFC 8594) and `Deprecation` header.

```http
HTTP/1.1 200 OK
Sunset: Sat, 01 Mar 2026 00:00:00 GMT
Deprecation: true
Link: </api/v2/users>; rel="successor-version"
```

## Authentication

| Pattern | Use Case | Notes |
|---------|----------|-------|
| Bearer token (JWT/opaque) | User-facing APIs | Send in `Authorization: Bearer <token>` |
| API key | Server-to-server, low-sensitivity | Send in header, never in URL query string |
| OAuth 2.1 + PKCE | Third-party integrations | Use authorization code flow with PKCE |

Rules:
- Always require HTTPS. Reject plain HTTP with 301 redirect or 403.
- Use short-lived access tokens + refresh tokens.
- Never accept API keys in query parameters (they leak in logs and referrer headers).
- Return 401 for missing/invalid credentials, 403 for insufficient permissions.

## Rate Limiting

Include rate limit headers on every response:

```http
HTTP/1.1 200 OK
RateLimit-Limit: 1000
RateLimit-Remaining: 847
RateLimit-Reset: 1737216000
```

When exceeded, return 429:

```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/problem+json
Retry-After: 30
RateLimit-Limit: 1000
RateLimit-Remaining: 0
RateLimit-Reset: 1737216000

{
  "type": "https://api.example.com/errors/rate-limit",
  "title": "Rate Limit Exceeded",
  "status": 429,
  "detail": "You have exceeded 1000 requests per hour. Retry after 30 seconds."
}
```

Rules:
- Use sliding window or token bucket algorithms.
- Apply limits per API key or per authenticated user.
- Use `RateLimit-*` headers (IETF draft standard) over legacy `X-RateLimit-*`.
- Always include `Retry-After` with 429 responses.
- Consider tiered limits (e.g., free: 100/hr, paid: 10000/hr).

## HATEOAS and Hypermedia

Include navigational links in responses so clients discover actions dynamically:

```json
{
  "id": 42,
  "status": "pending",
  "_links": {
    "self": {"href": "/api/v1/orders/42"},
    "cancel": {"href": "/api/v1/orders/42/cancel", "method": "POST"},
    "items": {"href": "/api/v1/orders/42/items"}
  }
}
```

Guidelines:
- Use `_links` with standard relation types (`self`, `next`, `prev`, `collection`).
- Only include links for actions the current user is authorized to perform.
- Use HAL+JSON or JSON:API for standardized hypermedia formats.
- HATEOAS is most valuable for complex workflows and public APIs.
- For internal/simple CRUD APIs, basic `self` links are sufficient.

## OpenAPI / Swagger Specification

Write an OpenAPI 3.1 spec as the single source of truth:

```yaml
openapi: "3.1.0"
info:
  title: Orders API
  version: "1.0.0"
paths:
  /api/v1/orders:
    get:
      summary: List orders
      parameters:
        - name: limit
          in: query
          schema:
            type: integer
            default: 25
            maximum: 100
        - name: cursor
          in: query
          schema:
            type: string
      responses:
        "200":
          description: Paginated list of orders
        "401":
          description: Unauthorized
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/ProblemDetail"
```

Rules:
- Define reusable schemas in `components/schemas` for resources, errors, pagination.
- Document every status code each endpoint can return.
- Add `example` values to schemas and parameters.
- Use spec-driven development: write spec first, generate server stubs and client SDKs.
- Validate spec in CI with tools like `spectral` or `redocly lint`.
- Serve interactive docs via Swagger UI or Redoc.

## Bulk Operations

For creating or updating multiple resources in one request:

```http
POST /api/v1/users/bulk HTTP/1.1
Content-Type: application/json

{
  "operations": [
    {"method": "create", "body": {"name": "User A", "email": "a@x.com"}},
    {"method": "create", "body": {"name": "User B", "email": "b@x.com"}}
  ]
}
```

```http
HTTP/1.1 207 Multi-Status
Content-Type: application/json

{
  "results": [
    {"status": 201, "id": 43},
    {"status": 409, "error": {"title": "Conflict", "detail": "Email already exists."}}
  ]
}
```

Rules:
- Cap batch size (e.g., 100 items per request).
- Return per-item status using 207 Multi-Status.
- Process atomically (all-or-nothing) or return individual results — document which.
- For large imports, prefer async: accept with 202 and provide a status polling endpoint.

## Caching

### ETags

```http
GET /api/v1/products/42 HTTP/1.1
```

```http
HTTP/1.1 200 OK
ETag: "a1b2c3d4"
Cache-Control: private, max-age=60

{"id": 42, "name": "Widget", "price": 9.99}
```

Conditional request:

```http
GET /api/v1/products/42 HTTP/1.1
If-None-Match: "a1b2c3d4"
```

```http
HTTP/1.1 304 Not Modified
```

### Cache-Control for APIs

- Use `Cache-Control: no-store` for user-specific or sensitive data.
- Use `Cache-Control: public, max-age=300` for shared, infrequently changing data.
- Use `private, max-age=60` for per-user data that tolerates short staleness.
- Combine ETags with `Cache-Control` for optimal performance.
- Use `Last-Modified` / `If-Modified-Since` as a fallback when ETags are expensive.

### Optimistic Concurrency with ETags

```http
PUT /api/v1/products/42 HTTP/1.1
If-Match: "a1b2c3d4"
Content-Type: application/json

{"name": "Widget Pro", "price": 14.99}
```

Return 412 Precondition Failed if the ETag no longer matches. This prevents lost updates.

## Common Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| Verbs in URLs (`/getUsers`) | Breaks REST semantics | Use nouns: `GET /users` |
| Inconsistent naming (`/user` vs `/Products`) | Confuses consumers | Pick one convention; enforce via linter |
| Missing pagination | Unbounded responses crash clients | Always paginate collections |
| Returning 200 for errors | Clients can't distinguish success/failure | Use proper 4xx/5xx codes |
| Exposing DB schema in responses | Couples clients to implementation | Use a DTO/view model layer |
| Nested URLs 3+ levels deep | Hard to maintain, ambiguous | Flatten with top-level resources |
| Ignoring idempotency | Retries cause duplicates | Use idempotency keys for POST |
| No versioning | Breaking changes break clients | Version from day one |
| API keys in query strings | Keys leak in logs and referrers | Use Authorization header |
| Inconsistent error format | Every endpoint returns different shapes | Adopt RFC 9457 globally |

<!-- tested: pass -->
