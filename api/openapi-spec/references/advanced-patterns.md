# Advanced OpenAPI Patterns

## Table of Contents

- [Schema Composition](#schema-composition)
  - [allOf — Composition and Inheritance](#allof--composition-and-inheritance)
  - [oneOf — Exactly One Match](#oneof--exactly-one-match)
  - [anyOf — One or More Matches](#anyof--one-or-more-matches)
  - [Combining Composition Keywords](#combining-composition-keywords)
- [Discriminators](#discriminators)
  - [Basic Discriminator Usage](#basic-discriminator-usage)
  - [Discriminator with Mapping](#discriminator-with-mapping)
  - [Nested Discriminators](#nested-discriminators)
- [Polymorphism](#polymorphism)
  - [Inheritance Hierarchies](#inheritance-hierarchies)
  - [Interface-Style Polymorphism](#interface-style-polymorphism)
  - [Sealed vs Open Hierarchies](#sealed-vs-open-hierarchies)
- [Circular References](#circular-references)
  - [Self-Referencing Schemas](#self-referencing-schemas)
  - [Mutual References](#mutual-references)
  - [Code Generation Considerations](#code-generation-considerations)
- [API Versioning Strategies](#api-versioning-strategies)
  - [URL Path Versioning](#url-path-versioning)
  - [Header-Based Versioning](#header-based-versioning)
  - [Content-Type Versioning](#content-type-versioning)
  - [Query Parameter Versioning](#query-parameter-versioning)
  - [Comparison Matrix](#comparison-matrix)
- [Pagination Patterns](#pagination-patterns)
  - [Offset-Based Pagination](#offset-based-pagination)
  - [Cursor-Based Pagination](#cursor-based-pagination)
  - [Keyset Pagination](#keyset-pagination)
  - [Page-Based Pagination](#page-based-pagination)
  - [Pagination Comparison](#pagination-comparison)
- [Filtering, Sorting, and Field Selection](#filtering-sorting-and-field-selection)
  - [Query-Based Filtering](#query-based-filtering)
  - [Deep Object Filtering](#deep-object-filtering)
  - [Sorting](#sorting)
  - [Sparse Fieldsets / Field Selection](#sparse-fieldsets--field-selection)
- [HATEOAS and Links](#hateoas-and-links)
  - [OpenAPI Links Object](#openapi-links-object)
  - [HAL-Style Links in Responses](#hal-style-links-in-responses)
  - [JSON:API Links](#jsonapi-links)
- [Webhooks and Callbacks](#webhooks-and-callbacks)
  - [Webhooks (OpenAPI 3.1)](#webhooks-openapi-31)
  - [Callbacks (OpenAPI 3.0+)](#callbacks-openapi-30)
  - [Webhook Security Patterns](#webhook-security-patterns)
  - [Webhook Retry and Delivery](#webhook-retry-and-delivery)
- [Rate Limiting Headers](#rate-limiting-headers)
  - [Standard Rate Limit Headers](#standard-rate-limit-headers)
  - [IETF RateLimit Header Fields](#ietf-ratelimit-header-fields)
  - [Modeling in OpenAPI](#modeling-in-openapi)

---

## Schema Composition

### allOf — Composition and Inheritance

Use `allOf` to combine multiple schemas. Every sub-schema must validate. This is the primary tool for DRY schema design and inheritance.

```yaml
components:
  schemas:
    # Base schema with common fields
    BaseResource:
      type: object
      required: [id, createdAt, updatedAt]
      properties:
        id:
          type: string
          format: uuid
          readOnly: true
        createdAt:
          type: string
          format: date-time
          readOnly: true
        updatedAt:
          type: string
          format: date-time
          readOnly: true

    # Extend base with domain-specific fields
    User:
      allOf:
        - $ref: "#/components/schemas/BaseResource"
        - type: object
          required: [email, name]
          properties:
            email:
              type: string
              format: email
            name:
              type: string
              minLength: 1
              maxLength: 200
            role:
              type: string
              enum: [admin, editor, viewer]
              default: viewer

    # Multi-level inheritance
    AdminUser:
      allOf:
        - $ref: "#/components/schemas/User"
        - type: object
          required: [permissions]
          properties:
            permissions:
              type: array
              items:
                type: string
            department:
              type: string
```

**Composition for request/response split:**

```yaml
    # Write model (no readOnly fields)
    CreateUser:
      type: object
      required: [email, name]
      properties:
        email: { type: string, format: email }
        name: { type: string }
        role: { type: string, enum: [admin, editor, viewer] }

    # Read model = base + write fields + read-only fields
    User:
      allOf:
        - $ref: "#/components/schemas/CreateUser"
        - $ref: "#/components/schemas/BaseResource"
        - type: object
          properties:
            lastLoginAt:
              type: string
              format: date-time
              readOnly: true
```

### oneOf — Exactly One Match

Use `oneOf` when the payload must match exactly one sub-schema. Pair with `discriminator` for reliable code generation.

```yaml
    Payment:
      oneOf:
        - $ref: "#/components/schemas/CreditCardPayment"
        - $ref: "#/components/schemas/BankTransferPayment"
        - $ref: "#/components/schemas/CryptoPayment"
      discriminator:
        propertyName: method
        mapping:
          credit_card: "#/components/schemas/CreditCardPayment"
          bank_transfer: "#/components/schemas/BankTransferPayment"
          crypto: "#/components/schemas/CryptoPayment"

    CreditCardPayment:
      type: object
      required: [method, cardNumber, expiryMonth, expiryYear, cvv]
      properties:
        method: { type: string, enum: [credit_card] }
        cardNumber: { type: string, pattern: '^\d{13,19}$' }
        expiryMonth: { type: integer, minimum: 1, maximum: 12 }
        expiryYear: { type: integer, minimum: 2024 }
        cvv: { type: string, pattern: '^\d{3,4}$' }

    BankTransferPayment:
      type: object
      required: [method, iban, bic]
      properties:
        method: { type: string, enum: [bank_transfer] }
        iban: { type: string, pattern: '^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$' }
        bic: { type: string, pattern: '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$' }

    CryptoPayment:
      type: object
      required: [method, walletAddress, currency]
      properties:
        method: { type: string, enum: [crypto] }
        walletAddress: { type: string }
        currency: { type: string, enum: [BTC, ETH, USDC] }
```

### anyOf — One or More Matches

Use `anyOf` when the payload can match one or more sub-schemas simultaneously.

```yaml
    # A search result that could be a user, product, or both-like entity
    SearchResult:
      anyOf:
        - $ref: "#/components/schemas/UserResult"
        - $ref: "#/components/schemas/ProductResult"

    # A value that accepts multiple input types
    MetricValue:
      anyOf:
        - type: number
        - type: string
          pattern: '^\d+(\.\d+)?%$'
        - type: object
          properties:
            value: { type: number }
            unit: { type: string }
```

### Combining Composition Keywords

You can combine `allOf` with `oneOf`/`anyOf` for complex schemas:

```yaml
    # Base event with polymorphic payload
    Event:
      allOf:
        - type: object
          required: [id, timestamp, type]
          properties:
            id: { type: string, format: uuid }
            timestamp: { type: string, format: date-time }
            type: { type: string }
        - oneOf:
            - $ref: "#/components/schemas/UserEvent"
            - $ref: "#/components/schemas/OrderEvent"
          discriminator:
            propertyName: type
```

---

## Discriminators

### Basic Discriminator Usage

The `discriminator` object tells validators and code generators which property determines the sub-schema type.

```yaml
    Shape:
      oneOf:
        - $ref: "#/components/schemas/Circle"
        - $ref: "#/components/schemas/Rectangle"
        - $ref: "#/components/schemas/Triangle"
      discriminator:
        propertyName: shapeType
```

**Rules:**
- The discriminator property must exist in every sub-schema
- The property must be a `string` type
- Without `mapping`, the property value must match the schema name exactly

### Discriminator with Mapping

Use `mapping` to decouple property values from schema names:

```yaml
      discriminator:
        propertyName: type
        mapping:
          circle: "#/components/schemas/CircleShape"
          rect: "#/components/schemas/RectangleShape"
          tri: "#/components/schemas/TriangleShape"
```

### Nested Discriminators

For multi-level hierarchies, use discriminators at each level:

```yaml
    Vehicle:
      oneOf:
        - $ref: "#/components/schemas/Car"
        - $ref: "#/components/schemas/Truck"
        - $ref: "#/components/schemas/Motorcycle"
      discriminator:
        propertyName: vehicleType

    Car:
      allOf:
        - type: object
          required: [vehicleType, fuelType]
          properties:
            vehicleType: { type: string, enum: [car] }
            fuelType: { type: string }
      oneOf:
        - $ref: "#/components/schemas/ElectricCar"
        - $ref: "#/components/schemas/GasCar"
      discriminator:
        propertyName: fuelType
```

---

## Polymorphism

### Inheritance Hierarchies

Model class hierarchies using `allOf` + `discriminator`:

```yaml
    # Abstract base
    Animal:
      type: object
      required: [species, name]
      properties:
        species: { type: string }
        name: { type: string }
      discriminator:
        propertyName: species
      oneOf:
        - $ref: "#/components/schemas/Dog"
        - $ref: "#/components/schemas/Cat"

    Dog:
      allOf:
        - $ref: "#/components/schemas/Animal"
        - type: object
          properties:
            breed: { type: string }
            trained: { type: boolean }

    Cat:
      allOf:
        - $ref: "#/components/schemas/Animal"
        - type: object
          properties:
            indoor: { type: boolean }
            declawed: { type: boolean }
```

### Interface-Style Polymorphism

Model interface-like contracts without inheritance:

```yaml
    Printable:
      type: object
      required: [contentType, content]
      properties:
        contentType:
          type: string
          enum: [text/plain, text/html, application/pdf]
        content:
          type: string

    # Multiple schemas can independently satisfy Printable
    Invoice:
      allOf:
        - $ref: "#/components/schemas/Printable"
        - type: object
          properties:
            invoiceNumber: { type: string }
            total: { type: number }
```

### Sealed vs Open Hierarchies

**Sealed** — only declared sub-schemas are valid (use `oneOf`):

```yaml
    PaymentMethod:
      oneOf:
        - $ref: "#/components/schemas/CreditCard"
        - $ref: "#/components/schemas/DebitCard"
      # No additional types allowed
```

**Open** — allow extensions via `anyOf` or `additionalProperties`:

```yaml
    Plugin:
      type: object
      required: [name, version]
      properties:
        name: { type: string }
        version: { type: string }
      additionalProperties: true
      # Consumers can add arbitrary fields
```

---

## Circular References

### Self-Referencing Schemas

Common for tree structures, linked lists, and recursive data:

```yaml
    TreeNode:
      type: object
      required: [value]
      properties:
        value:
          type: string
        children:
          type: array
          items:
            $ref: "#/components/schemas/TreeNode"

    # Comment thread
    Comment:
      type: object
      required: [id, text, author]
      properties:
        id: { type: string, format: uuid }
        text: { type: string }
        author: { type: string }
        replies:
          type: array
          items:
            $ref: "#/components/schemas/Comment"

    # Folder structure
    Folder:
      type: object
      properties:
        name: { type: string }
        subfolders:
          type: array
          items:
            $ref: "#/components/schemas/Folder"
        files:
          type: array
          items:
            $ref: "#/components/schemas/File"
```

### Mutual References

Two schemas referencing each other:

```yaml
    Employee:
      type: object
      properties:
        name: { type: string }
        manager:
          $ref: "#/components/schemas/Employee"
        department:
          $ref: "#/components/schemas/Department"

    Department:
      type: object
      properties:
        name: { type: string }
        head:
          $ref: "#/components/schemas/Employee"
        members:
          type: array
          items:
            $ref: "#/components/schemas/Employee"
```

### Code Generation Considerations

- Most generators handle self-references correctly via lazy/forward references
- Set `maxDepth` or use wrapper types to avoid infinite recursion in serialization
- Some generators (especially for statically typed languages) may need manual intervention
- Test generated models with deeply nested circular data
- Consider using `nullable` or optional on circular properties to allow termination

---

## API Versioning Strategies

### URL Path Versioning

```yaml
servers:
  - url: https://api.example.com/v1
    description: Version 1
  - url: https://api.example.com/v2
    description: Version 2

# Or with server variables:
servers:
  - url: https://api.example.com/{version}
    variables:
      version:
        default: v2
        enum: [v1, v2, v3]
```

**Pros:** Simple, visible, easy to route, cache-friendly.
**Cons:** Breaks URI permanence, harder to share reusable components.

### Header-Based Versioning

```yaml
# Custom header parameter
components:
  parameters:
    ApiVersion:
      name: X-API-Version
      in: header
      required: false
      schema:
        type: string
        default: "2024-01-01"
        enum: ["2023-01-01", "2024-01-01", "2024-06-01"]
      description: API version date. Defaults to latest stable.

# Apply to all operations
paths:
  /users:
    get:
      parameters:
        - $ref: "#/components/parameters/ApiVersion"
```

**Pros:** Clean URLs, fine-grained version control per request.
**Cons:** Less discoverable, harder to test in browser.

### Content-Type Versioning

```yaml
# Vendor-specific media type
paths:
  /users:
    get:
      responses:
        "200":
          description: OK
          content:
            application/vnd.myapi.v1+json:
              schema:
                $ref: "#/components/schemas/UserV1"
            application/vnd.myapi.v2+json:
              schema:
                $ref: "#/components/schemas/UserV2"
```

**Pros:** RESTful, uses content negotiation properly.
**Cons:** Complex to implement, hard to test, poor tooling support.

### Query Parameter Versioning

```yaml
components:
  parameters:
    VersionParam:
      name: api-version
      in: query
      schema:
        type: string
        default: "2024-01-01"
```

**Pros:** Easy to test in browser. **Cons:** Pollutes query string, caching issues.

### Comparison Matrix

| Strategy | URL Clean | Cache | Discovery | Tooling | Best For |
|----------|-----------|-------|-----------|---------|----------|
| URL path | No | Great | Great | Great | Public APIs |
| Header | Yes | OK | Poor | Good | Internal APIs |
| Content-type | Yes | Good | Poor | Poor | Strict REST |
| Query param | No | Poor | Good | Great | Quick prototyping |

---

## Pagination Patterns

### Offset-Based Pagination

```yaml
components:
  parameters:
    OffsetParam:
      name: offset
      in: query
      schema: { type: integer, minimum: 0, default: 0 }
      description: Number of items to skip
    LimitParam:
      name: limit
      in: query
      schema: { type: integer, minimum: 1, maximum: 100, default: 20 }
      description: Maximum number of items to return

  schemas:
    OffsetPaginatedResponse:
      type: object
      required: [data, pagination]
      properties:
        data:
          type: array
          items: {}
        pagination:
          type: object
          required: [total, limit, offset]
          properties:
            total: { type: integer, description: Total number of items }
            limit: { type: integer }
            offset: { type: integer }
            hasMore: { type: boolean }

paths:
  /users:
    get:
      parameters:
        - $ref: "#/components/parameters/OffsetParam"
        - $ref: "#/components/parameters/LimitParam"
      responses:
        "200":
          content:
            application/json:
              schema:
                allOf:
                  - $ref: "#/components/schemas/OffsetPaginatedResponse"
                  - type: object
                    properties:
                      data:
                        type: array
                        items:
                          $ref: "#/components/schemas/User"
```

### Cursor-Based Pagination

```yaml
  parameters:
    CursorParam:
      name: cursor
      in: query
      schema: { type: string }
      description: Opaque cursor from previous response
    CursorLimitParam:
      name: limit
      in: query
      schema: { type: integer, minimum: 1, maximum: 100, default: 20 }

  schemas:
    CursorPaginatedResponse:
      type: object
      required: [data, pageInfo]
      properties:
        data:
          type: array
          items: {}
        pageInfo:
          type: object
          required: [hasNextPage]
          properties:
            hasNextPage: { type: boolean }
            hasPreviousPage: { type: boolean }
            startCursor: { type: string }
            endCursor: { type: string }
```

### Keyset Pagination

```yaml
  # Uses the last item's sort key as the pagination anchor
  parameters:
    AfterIdParam:
      name: after_id
      in: query
      schema: { type: string, format: uuid }
      description: Return items after this ID
    BeforeIdParam:
      name: before_id
      in: query
      schema: { type: string, format: uuid }
      description: Return items before this ID

  schemas:
    KeysetPaginatedResponse:
      type: object
      required: [data]
      properties:
        data:
          type: array
          items: {}
        hasMore: { type: boolean }
        firstId: { type: string, format: uuid }
        lastId: { type: string, format: uuid }
```

### Page-Based Pagination

```yaml
  parameters:
    PageParam:
      name: page
      in: query
      schema: { type: integer, minimum: 1, default: 1 }
    PageSizeParam:
      name: pageSize
      in: query
      schema: { type: integer, minimum: 1, maximum: 100, default: 20 }

  schemas:
    PagePaginatedResponse:
      type: object
      properties:
        data: { type: array, items: {} }
        page: { type: integer }
        pageSize: { type: integer }
        totalPages: { type: integer }
        totalItems: { type: integer }
```

### Pagination Comparison

| Pattern | Consistency | Performance | Deep Pages | Use Case |
|---------|------------|-------------|------------|----------|
| Offset | Unstable on inserts/deletes | Degrades at depth | Slow | Simple UIs, small datasets |
| Cursor | Stable | Constant time | Fast | Feeds, real-time data, large sets |
| Keyset | Stable | Constant time | Fast | Sorted datasets, DB-backed APIs |
| Page | Unstable on mutations | Degrades at depth | Slow | Traditional web UIs |

---

## Filtering, Sorting, and Field Selection

### Query-Based Filtering

```yaml
parameters:
  - name: status
    in: query
    schema:
      type: string
      enum: [active, inactive, pending, suspended]
  - name: role
    in: query
    schema:
      type: array
      items:
        type: string
        enum: [admin, editor, viewer]
    explode: true
    # ?role=admin&role=editor
  - name: createdAfter
    in: query
    schema:
      type: string
      format: date-time
  - name: createdBefore
    in: query
    schema:
      type: string
      format: date-time
  - name: search
    in: query
    schema:
      type: string
      minLength: 2
      maxLength: 100
    description: Full-text search across name and email
```

### Deep Object Filtering

```yaml
  - name: filter
    in: query
    style: deepObject
    explode: true
    # ?filter[status]=active&filter[role]=admin&filter[age][gte]=18
    schema:
      type: object
      properties:
        status:
          type: string
          enum: [active, inactive]
        role:
          type: string
        age:
          type: object
          properties:
            gte: { type: integer }
            lte: { type: integer }
        createdAt:
          type: object
          properties:
            after: { type: string, format: date-time }
            before: { type: string, format: date-time }
```

### Sorting

```yaml
  - name: sort
    in: query
    schema:
      type: string
      pattern: '^-?[a-zA-Z_]+(,-?[a-zA-Z_]+)*$'
      example: "-createdAt,name"
    description: |
      Comma-separated fields. Prefix with - for descending.
      Allowed fields: name, email, createdAt, updatedAt

  # Alternative: separate sort and order params
  - name: sortBy
    in: query
    schema:
      type: string
      enum: [name, email, createdAt, updatedAt]
      default: createdAt
  - name: sortOrder
    in: query
    schema:
      type: string
      enum: [asc, desc]
      default: desc
```

### Sparse Fieldsets / Field Selection

```yaml
  - name: fields
    in: query
    schema:
      type: string
      example: "id,name,email"
    description: |
      Comma-separated list of fields to include.
      Reduces payload size. Omit for all fields.

  # JSON:API style
  - name: "fields[users]"
    in: query
    schema:
      type: string
      example: "name,email"
  - name: "fields[posts]"
    in: query
    schema:
      type: string
      example: "title,createdAt"
```

---

## HATEOAS and Links

### OpenAPI Links Object

OpenAPI's `links` define relationships between operations:

```yaml
paths:
  /orders:
    post:
      operationId: createOrder
      responses:
        "201":
          description: Order created
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
          links:
            GetOrder:
              operationId: getOrder
              parameters:
                orderId: $response.body#/id
              description: Get the created order
            GetOrderItems:
              operationId: listOrderItems
              parameters:
                orderId: $response.body#/id
            CancelOrder:
              operationId: cancelOrder
              parameters:
                orderId: $response.body#/id

  /orders/{orderId}:
    get:
      operationId: getOrder
      responses:
        "200":
          description: OK
          links:
            ListItems:
              operationId: listOrderItems
              parameters:
                orderId: $response.body#/id
            GetCustomer:
              operationId: getCustomer
              parameters:
                customerId: $response.body#/customerId
```

### HAL-Style Links in Responses

```yaml
    HalLink:
      type: object
      required: [href]
      properties:
        href: { type: string, format: uri }
        templated: { type: boolean, default: false }
        type: { type: string }
        title: { type: string }

    UserWithLinks:
      type: object
      properties:
        id: { type: string }
        name: { type: string }
        _links:
          type: object
          properties:
            self: { $ref: "#/components/schemas/HalLink" }
            orders: { $ref: "#/components/schemas/HalLink" }
            edit: { $ref: "#/components/schemas/HalLink" }
          example:
            self: { href: "/users/123" }
            orders: { href: "/users/123/orders" }
            edit: { href: "/users/123", type: "application/json" }
```

### JSON:API Links

```yaml
    JsonApiLinks:
      type: object
      properties:
        self: { type: string, format: uri }
        related: { type: string, format: uri }
        first: { type: string, format: uri }
        last: { type: string, format: uri }
        prev:
          type: ["string", "null"]
          format: uri
        next:
          type: ["string", "null"]
          format: uri
```

---

## Webhooks and Callbacks

### Webhooks (OpenAPI 3.1)

Top-level `webhooks` object for events your API sends to subscribers:

```yaml
webhooks:
  order.created:
    post:
      summary: Order created event
      operationId: onOrderCreated
      tags: [Webhooks]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/OrderCreatedEvent"
      responses:
        "200": { description: Event acknowledged }
        "202": { description: Event accepted for processing }
      security:
        - webhookSignature: []

  order.shipped:
    post:
      summary: Order shipped event
      operationId: onOrderShipped
      requestBody:
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/OrderShippedEvent"
      responses:
        "200": { description: Acknowledged }

components:
  schemas:
    WebhookEnvelope:
      type: object
      required: [id, type, timestamp, data]
      properties:
        id: { type: string, format: uuid }
        type: { type: string }
        timestamp: { type: string, format: date-time }
        version: { type: string, example: "1.0" }
        data: { type: object }

    OrderCreatedEvent:
      allOf:
        - $ref: "#/components/schemas/WebhookEnvelope"
        - type: object
          properties:
            type: { type: string, enum: [order.created] }
            data:
              type: object
              properties:
                orderId: { type: string }
                customerId: { type: string }
                total: { type: number }
```

### Callbacks (OpenAPI 3.0+)

Callbacks define runtime webhook URLs provided by the client:

```yaml
paths:
  /webhooks:
    post:
      operationId: registerWebhook
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [callbackUrl, events, secret]
              properties:
                callbackUrl: { type: string, format: uri }
                events:
                  type: array
                  items:
                    type: string
                    enum: [order.created, order.updated, order.cancelled]
                secret:
                  type: string
                  minLength: 32
                  description: Shared secret for HMAC signature verification
      callbacks:
        orderEvent:
          "{$request.body#/callbackUrl}":
            post:
              summary: Webhook delivery
              requestBody:
                required: true
                content:
                  application/json:
                    schema:
                      $ref: "#/components/schemas/WebhookEnvelope"
              responses:
                "200": { description: Acknowledged }
                "410": { description: Webhook endpoint removed }
              security: []
      responses:
        "201":
          description: Webhook registered
```

### Webhook Security Patterns

```yaml
components:
  securitySchemes:
    webhookSignature:
      type: apiKey
      in: header
      name: X-Webhook-Signature
      description: HMAC-SHA256 signature of the payload

  schemas:
    WebhookHeaders:
      type: object
      properties:
        X-Webhook-Id:
          type: string
          format: uuid
          description: Unique delivery ID for idempotency
        X-Webhook-Timestamp:
          type: string
          format: date-time
          description: When the webhook was sent
        X-Webhook-Signature:
          type: string
          description: "HMAC-SHA256: hex(hmac_sha256(secret, timestamp.payload))"
```

### Webhook Retry and Delivery

Document retry behavior in descriptions and extensions:

```yaml
webhooks:
  payment.completed:
    post:
      description: |
        Delivery policy:
        - Retries: 5 attempts with exponential backoff (1s, 5s, 30s, 2m, 15m)
        - Timeout: 30 seconds per attempt
        - Success: HTTP 2xx response
        - Failure: HTTP 4xx/5xx or timeout
        - After all retries exhausted, webhook is disabled
      x-webhook-retry-policy:
        maxRetries: 5
        backoffMultiplier: 5
        initialDelaySeconds: 1
```

---

## Rate Limiting Headers

### Standard Rate Limit Headers

```yaml
components:
  headers:
    X-RateLimit-Limit:
      schema: { type: integer }
      description: Maximum requests per window
      example: 1000
    X-RateLimit-Remaining:
      schema: { type: integer }
      description: Remaining requests in current window
      example: 997
    X-RateLimit-Reset:
      schema: { type: integer }
      description: Unix epoch timestamp when window resets
      example: 1719849600
    Retry-After:
      schema: { type: integer }
      description: Seconds to wait before retrying (on 429)
      example: 30
```

### IETF RateLimit Header Fields

Following the draft IETF standard (RFC 9110 compatible):

```yaml
  headers:
    RateLimit:
      schema: { type: string }
      description: "Rate limit info: limit=100, remaining=95, reset=50"
      example: "limit=100, remaining=95, reset=50"
    RateLimit-Policy:
      schema: { type: string }
      description: "Policy: 100;w=3600 (100 requests per 3600 seconds)"
      example: "100;w=3600"
```

### Modeling in OpenAPI

Apply rate limit headers to responses:

```yaml
  responses:
    RateLimited:
      description: Rate limit exceeded
      headers:
        X-RateLimit-Limit:
          $ref: "#/components/headers/X-RateLimit-Limit"
        X-RateLimit-Remaining:
          $ref: "#/components/headers/X-RateLimit-Remaining"
        X-RateLimit-Reset:
          $ref: "#/components/headers/X-RateLimit-Reset"
        Retry-After:
          $ref: "#/components/headers/Retry-After"
      content:
        application/json:
          schema:
            $ref: "#/components/schemas/Error"
          example:
            type: "https://api.example.com/errors/rate-limited"
            title: "Rate Limit Exceeded"
            status: 429
            detail: "You have exceeded the rate limit of 1000 requests per hour."

    # Apply headers to success responses too
    SuccessWithRateLimit:
      description: OK
      headers:
        X-RateLimit-Limit:
          $ref: "#/components/headers/X-RateLimit-Limit"
        X-RateLimit-Remaining:
          $ref: "#/components/headers/X-RateLimit-Remaining"
        X-RateLimit-Reset:
          $ref: "#/components/headers/X-RateLimit-Reset"

# Usage in paths:
paths:
  /api/resource:
    get:
      responses:
        "200":
          $ref: "#/components/responses/SuccessWithRateLimit"
        "429":
          $ref: "#/components/responses/RateLimited"
```
