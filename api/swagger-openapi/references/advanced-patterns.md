# Advanced OpenAPI Patterns

## Table of Contents

- [Schema Composition](#schema-composition)
  - [Discriminator Deep Dive](#discriminator-deep-dive)
  - [Polymorphism Patterns](#polymorphism-patterns)
  - [Composition with allOf](#composition-with-allof)
  - [Conditional Schemas (if/then/else)](#conditional-schemas-ifthenelse)
- [Content Negotiation](#content-negotiation)
  - [Multiple Response Media Types](#multiple-response-media-types)
  - [Request Content Negotiation](#request-content-negotiation)
  - [Vendor-Specific Media Types](#vendor-specific-media-types)
- [Multipart Uploads](#multipart-uploads)
  - [Simple File Upload](#simple-file-upload)
  - [Mixed Content Multipart](#mixed-content-multipart)
  - [Multiple Files](#multiple-files)
  - [Encoding Object](#encoding-object)
- [Pagination Patterns](#pagination-patterns)
  - [Offset-Based Pagination](#offset-based-pagination)
  - [Cursor-Based Pagination](#cursor-based-pagination)
  - [Keyset Pagination](#keyset-pagination)
  - [Link Header Pagination](#link-header-pagination)
  - [HATEOAS Pagination](#hateoas-pagination)
- [API Versioning Strategies](#api-versioning-strategies)
  - [URL Path Versioning](#url-path-versioning)
  - [Header Versioning](#header-versioning)
  - [Query Parameter Versioning](#query-parameter-versioning)
  - [Content Negotiation Versioning](#content-negotiation-versioning)
  - [Multi-Spec Versioning](#multi-spec-versioning)
- [Vendor Extensions (x-)](#vendor-extensions-x-)
  - [Common Extension Patterns](#common-extension-patterns)
  - [Code Generation Extensions](#code-generation-extensions)
  - [Documentation Extensions](#documentation-extensions)
  - [Gateway/Infrastructure Extensions](#gatewayinfrastructure-extensions)
- [OAS Overlay Specification](#oas-overlay-specification)
  - [Overlay Structure](#overlay-structure)
  - [Use Cases](#overlay-use-cases)
  - [Targeted Overlays](#targeted-overlays)
- [Arazzo Specification](#arazzo-specification)
  - [Workflow Structure](#workflow-structure)
  - [Steps and Dependencies](#steps-and-dependencies)
  - [Expressions and Runtime Values](#expressions-and-runtime-values)
- [Reusable Components Organization](#reusable-components-organization)
  - [File Structure for Large APIs](#file-structure-for-large-apis)
  - [Shared Components Library](#shared-components-library)
  - [Cross-API Component Reuse](#cross-api-component-reuse)

---

## Schema Composition

### Discriminator Deep Dive

The `discriminator` object tells parsers which schema variant to use based on a property value. It is only meaningful with `oneOf` or `anyOf`.

```yaml
components:
  schemas:
    Payment:
      oneOf:
        - $ref: '#/components/schemas/CreditCardPayment'
        - $ref: '#/components/schemas/BankTransferPayment'
        - $ref: '#/components/schemas/CryptoPayment'
      discriminator:
        propertyName: paymentMethod
        mapping:
          credit_card: '#/components/schemas/CreditCardPayment'
          bank_transfer: '#/components/schemas/BankTransferPayment'
          crypto: '#/components/schemas/CryptoPayment'

    PaymentBase:
      type: object
      required: [paymentMethod, amount, currency]
      properties:
        paymentMethod:
          type: string
        amount:
          type: number
          format: double
          minimum: 0.01
        currency:
          type: string
          pattern: '^[A-Z]{3}$'

    CreditCardPayment:
      allOf:
        - $ref: '#/components/schemas/PaymentBase'
        - type: object
          required: [cardNumber, expiryMonth, expiryYear]
          properties:
            cardNumber:
              type: string
              pattern: '^\d{13,19}$'
            expiryMonth:
              type: integer
              minimum: 1
              maximum: 12
            expiryYear:
              type: integer
            cvv:
              type: string
              pattern: '^\d{3,4}$'
              writeOnly: true

    BankTransferPayment:
      allOf:
        - $ref: '#/components/schemas/PaymentBase'
        - type: object
          required: [iban]
          properties:
            iban:
              type: string
            bic:
              type: string

    CryptoPayment:
      allOf:
        - $ref: '#/components/schemas/PaymentBase'
        - type: object
          required: [walletAddress, network]
          properties:
            walletAddress:
              type: string
            network:
              type: string
              enum: [ethereum, bitcoin, solana]
```

**Discriminator rules:**
- The discriminator property must be a required string field in every variant schema.
- The `mapping` keys are the literal values of the discriminator property.
- Without explicit `mapping`, the schema name from the `$ref` is used as the mapping key.
- Discriminators speed up validation and improve code generation (generates proper switch/match on the discriminator field).

### Polymorphism Patterns

**Pattern 1: Closed polymorphism (known set of types)**

Use `oneOf` + `discriminator` when the set of types is fixed. Code generators produce sealed/union types.

```yaml
Shape:
  oneOf:
    - $ref: '#/components/schemas/Circle'
    - $ref: '#/components/schemas/Rectangle'
    - $ref: '#/components/schemas/Triangle'
  discriminator:
    propertyName: shapeType
```

**Pattern 2: Open polymorphism (extensible)**

Use `anyOf` without a discriminator when consumers may encounter unknown variants. Typically paired with `additionalProperties: true`.

```yaml
Notification:
  anyOf:
    - $ref: '#/components/schemas/EmailNotification'
    - $ref: '#/components/schemas/SmsNotification'
  description: >
    May include additional notification types in the future.
    Consumers should handle unknown types gracefully.
```

**Pattern 3: Mixin composition**

Use `allOf` to compose traits/mixins into concrete types:

```yaml
Auditable:
  type: object
  properties:
    createdAt: { type: string, format: date-time }
    updatedAt: { type: string, format: date-time }
    createdBy: { type: string }

SoftDeletable:
  type: object
  properties:
    deletedAt: { type: ["string", "null"], format: date-time }
    isDeleted: { type: boolean, default: false }

User:
  allOf:
    - $ref: '#/components/schemas/Auditable'
    - $ref: '#/components/schemas/SoftDeletable'
    - type: object
      required: [id, email]
      properties:
        id: { type: string, format: uuid }
        email: { type: string, format: email }
```

### Composition with allOf

`allOf` merges all listed schemas. Every schema must validate. Watch for conflicts:

```yaml
# GOOD: Non-overlapping properties merge cleanly
MergedSchema:
  allOf:
    - type: object
      properties:
        name: { type: string }
    - type: object
      properties:
        age: { type: integer }

# BAD: Conflicting types — will fail validation
ConflictSchema:
  allOf:
    - type: object
      properties:
        value: { type: string }
    - type: object
      properties:
        value: { type: integer }   # conflict with string above
```

**Tip:** When using `allOf` with `$ref`, the inline schema overrides/extends the referenced schema. Use this for request vs response variants:

```yaml
UserCreate:
  allOf:
    - $ref: '#/components/schemas/UserBase'
    - type: object
      required: [password]
      properties:
        password: { type: string, writeOnly: true }

UserResponse:
  allOf:
    - $ref: '#/components/schemas/UserBase'
    - type: object
      properties:
        id: { type: string, format: uuid, readOnly: true }
        createdAt: { type: string, format: date-time, readOnly: true }
```

### Conditional Schemas (if/then/else)

OpenAPI 3.1 supports JSON Schema conditional keywords:

```yaml
Address:
  type: object
  required: [country]
  properties:
    country: { type: string }
    state: { type: string }
    postalCode: { type: string }
  if:
    properties:
      country: { const: "US" }
  then:
    required: [state, postalCode]
    properties:
      state:
        type: string
        pattern: '^[A-Z]{2}$'
      postalCode:
        type: string
        pattern: '^\d{5}(-\d{4})?$'
  else:
    if:
      properties:
        country: { const: "CA" }
    then:
      required: [postalCode]
      properties:
        postalCode:
          type: string
          pattern: '^[A-Z]\d[A-Z] \d[A-Z]\d$'
```

> **Caution:** `if/then/else` is OAS 3.1 only and not all code generators support it. Prefer `oneOf` + `discriminator` for broader tooling compatibility.

---

## Content Negotiation

### Multiple Response Media Types

```yaml
paths:
  /reports/{id}:
    get:
      operationId: getReport
      parameters:
        - name: id
          in: path
          required: true
          schema: { type: string }
      responses:
        '200':
          description: Report in the requested format
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Report'
            application/pdf:
              schema:
                type: string
                format: binary
            text/csv:
              schema:
                type: string
            application/xml:
              schema:
                $ref: '#/components/schemas/Report'
```

The server uses the `Accept` header to determine which format to return.

### Request Content Negotiation

```yaml
paths:
  /data/import:
    post:
      operationId: importData
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/DataImport'
          text/csv:
            schema:
              type: string
          application/xml:
            schema:
              $ref: '#/components/schemas/DataImport'
```

### Vendor-Specific Media Types

Use vendor media types for API versioning or custom formats:

```yaml
content:
  application/vnd.mycompany.user.v2+json:
    schema:
      $ref: '#/components/schemas/UserV2'
  application/vnd.mycompany.user.v1+json:
    schema:
      $ref: '#/components/schemas/UserV1'
```

---

## Multipart Uploads

### Simple File Upload

```yaml
paths:
  /files:
    post:
      operationId: uploadFile
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [file]
              properties:
                file:
                  type: string
                  format: binary
                description:
                  type: string
```

### Mixed Content Multipart

```yaml
/users/{userId}/profile:
  put:
    operationId: updateProfile
    requestBody:
      content:
        multipart/form-data:
          schema:
            type: object
            properties:
              metadata:
                type: object
                properties:
                  displayName: { type: string }
                  bio: { type: string }
              avatar:
                type: string
                format: binary
              coverPhoto:
                type: string
                format: binary
          encoding:
            metadata:
              contentType: application/json
            avatar:
              contentType: image/png, image/jpeg
              headers:
                X-Custom-Header:
                  schema: { type: string }
            coverPhoto:
              contentType: image/png, image/jpeg
```

### Multiple Files

```yaml
/documents/batch:
  post:
    requestBody:
      content:
        multipart/form-data:
          schema:
            type: object
            properties:
              files:
                type: array
                items:
                  type: string
                  format: binary
                maxItems: 10
              tags:
                type: array
                items:
                  type: string
```

### Encoding Object

The `encoding` object controls how multipart fields are serialized:

```yaml
encoding:
  profileImage:
    contentType: image/png, image/jpeg, image/gif
    headers:
      X-Rate-Limit:
        schema: { type: integer }
  metadata:
    contentType: application/json
    # For non-binary parts, `style` and `explode` control serialization
  tags:
    style: form
    explode: true
    # tags=a&tags=b vs tags=a,b
```

---

## Pagination Patterns

### Offset-Based Pagination

```yaml
paths:
  /items:
    get:
      operationId: listItems
      parameters:
        - name: offset
          in: query
          schema: { type: integer, minimum: 0, default: 0 }
        - name: limit
          in: query
          schema: { type: integer, minimum: 1, maximum: 100, default: 20 }
      responses:
        '200':
          description: Paginated list
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/PaginatedItems'

components:
  schemas:
    PaginatedItems:
      type: object
      required: [data, pagination]
      properties:
        data:
          type: array
          items:
            $ref: '#/components/schemas/Item'
        pagination:
          type: object
          required: [total, offset, limit]
          properties:
            total: { type: integer }
            offset: { type: integer }
            limit: { type: integer }
            hasMore: { type: boolean }
```

### Cursor-Based Pagination

Preferred for large datasets and real-time feeds. Stable under concurrent writes.

```yaml
parameters:
  - name: cursor
    in: query
    description: Opaque cursor from previous response
    schema: { type: string }
  - name: limit
    in: query
    schema: { type: integer, minimum: 1, maximum: 100, default: 20 }

components:
  schemas:
    CursorPaginatedItems:
      type: object
      required: [data]
      properties:
        data:
          type: array
          items:
            $ref: '#/components/schemas/Item'
        nextCursor:
          type: ["string", "null"]
          description: Null when no more results
        previousCursor:
          type: ["string", "null"]
        hasMore:
          type: boolean
```

### Keyset Pagination

Uses the last record's sort key as the next page boundary:

```yaml
parameters:
  - name: after_id
    in: query
    description: Return results after this ID
    schema: { type: string, format: uuid }
  - name: sort_by
    in: query
    schema: { type: string, enum: [created_at, name, updated_at], default: created_at }
  - name: sort_order
    in: query
    schema: { type: string, enum: [asc, desc], default: desc }
  - name: limit
    in: query
    schema: { type: integer, minimum: 1, maximum: 100, default: 20 }
```

### Link Header Pagination

Use response headers to indicate navigation URIs (GitHub API style):

```yaml
responses:
  '200':
    description: List of items
    headers:
      Link:
        schema: { type: string }
        description: >
          RFC 8288 Link header.
          Example: <https://api.example.com/items?page=3>; rel="next",
                   <https://api.example.com/items?page=1>; rel="prev"
      X-Total-Count:
        schema: { type: integer }
      X-Page:
        schema: { type: integer }
      X-Per-Page:
        schema: { type: integer }
```

### HATEOAS Pagination

Embed navigation links in the response body:

```yaml
PaginatedResponse:
  type: object
  properties:
    data:
      type: array
      items:
        $ref: '#/components/schemas/Item'
    _links:
      type: object
      properties:
        self: { type: string, format: uri }
        next: { type: ["string", "null"], format: uri }
        prev: { type: ["string", "null"], format: uri }
        first: { type: string, format: uri }
        last: { type: string, format: uri }
    _meta:
      type: object
      properties:
        totalItems: { type: integer }
        totalPages: { type: integer }
        currentPage: { type: integer }
        perPage: { type: integer }
```

---

## API Versioning Strategies

### URL Path Versioning

Most common. Each version is a separate path prefix.

```yaml
servers:
  - url: https://api.example.com/v1
    description: Version 1 (current)
  - url: https://api.example.com/v2
    description: Version 2 (beta)
```

Manage separate spec files per major version, or use overlays to produce versioned specs from a single source.

### Header Versioning

```yaml
components:
  parameters:
    ApiVersion:
      name: X-API-Version
      in: header
      required: false
      schema:
        type: string
        enum: ["2024-01-15", "2024-06-01", "2024-12-01"]
        default: "2024-01-15"
      description: >
        Date-based API version. Defaults to oldest supported version.
        Use the latest date for newest features.
```

### Query Parameter Versioning

```yaml
parameters:
  - name: api_version
    in: query
    required: false
    schema:
      type: string
      enum: ["v1", "v2"]
      default: "v1"
```

### Content Negotiation Versioning

Use the `Accept` header with vendor media types:

```yaml
responses:
  '200':
    description: User data
    content:
      application/vnd.myapi.v1+json:
        schema:
          $ref: '#/components/schemas/UserV1'
      application/vnd.myapi.v2+json:
        schema:
          $ref: '#/components/schemas/UserV2'
```

### Multi-Spec Versioning

For large version differences, maintain separate specs and use CI to validate both:

```
specs/
├── v1/
│   ├── openapi.yaml
│   └── schemas/
├── v2/
│   ├── openapi.yaml
│   └── schemas/
└── shared/
    └── common-schemas.yaml   # $ref from both versions
```

---

## Vendor Extensions (x-)

Extensions must start with `x-`. They can appear at any level in the spec.

### Common Extension Patterns

```yaml
paths:
  /internal/metrics:
    get:
      x-internal: true                    # mark as internal-only
      x-stability: experimental           # lifecycle stage
      x-since: "2024-06-01"               # when this was added
      x-deprecated-at: "2025-01-01"       # when deprecation started
      x-sunset: "2025-06-01"              # when it will be removed
      x-rate-limit:
        requests: 100
        window: 60s
      x-permissions:
        - admin:read
        - metrics:read
```

### Code Generation Extensions

```yaml
components:
  schemas:
    User:
      type: object
      x-class-name: UserModel            # override generated class name
      x-implements:
        - Serializable
        - Auditable
      properties:
        status:
          type: string
          enum: [active, inactive, banned]
          x-enum-varnames:               # control enum constant names
            - ACTIVE
            - INACTIVE
            - BANNED
          x-enum-descriptions:
            - User is active and can log in
            - User account is deactivated
            - User is permanently banned
```

### Documentation Extensions

```yaml
info:
  x-logo:
    url: https://example.com/logo.png
    altText: Company Logo
    backgroundColor: "#FFFFFF"
  x-api-id: 550e8400-e29b-41d4-a716-446655440000

paths:
  /users:
    get:
      x-code-samples:
        - lang: curl
          source: |
            curl -H "Authorization: Bearer $TOKEN" \
              https://api.example.com/v1/users
        - lang: python
          source: |
            import requests
            resp = requests.get(
                "https://api.example.com/v1/users",
                headers={"Authorization": f"Bearer {token}"}
            )
        - lang: javascript
          source: |
            const resp = await fetch('https://api.example.com/v1/users', {
              headers: { 'Authorization': `Bearer ${token}` }
            });
```

### Gateway/Infrastructure Extensions

```yaml
paths:
  /users:
    get:
      x-amazon-apigateway-integration:
        uri: arn:aws:lambda:us-east-1:123456789:function:getUsers
        httpMethod: POST
        type: aws_proxy

      x-kong-plugin-rate-limiting:
        config:
          minute: 100
          policy: local

      x-google-backend:
        address: https://users-service-abc123.run.app
```

---

## OAS Overlay Specification

Overlays allow non-destructive modifications to an OpenAPI document. They are defined in separate files and applied during build time.

### Overlay Structure

```yaml
overlay: 1.0.0
info:
  title: Production API Overlay
  version: 1.0.0
actions:
  - target: "$.info"
    update:
      x-environment: production
      contact:
        email: api-support@example.com

  - target: "$.servers"
    update:
      - url: https://api.example.com/v1
        description: Production

  - target: "$.paths['/internal/*']"
    remove: true

  - target: "$.paths.*.*.x-internal"
    remove: true
```

### Overlay Use Cases

1. **Environment-specific servers:** Different servers for dev/staging/prod
2. **Removing internal endpoints:** Strip `x-internal: true` operations for public docs
3. **Adding vendor extensions:** Inject gateway config for specific deployments
4. **Localization:** Override descriptions in different languages
5. **Partner customization:** Expose different subsets of the API to different partners

### Targeted Overlays

```yaml
overlay: 1.0.0
info:
  title: Gateway Configuration Overlay
  version: 1.0.0
actions:
  # Add rate limiting to all GET operations
  - target: "$.paths.*.get"
    update:
      x-rate-limit:
        requests: 1000
        window: 60s

  # Add stricter rate limiting to write operations
  - target: "$.paths.*.post"
    update:
      x-rate-limit:
        requests: 100
        window: 60s

  # Add caching headers to list endpoints
  - target: "$.paths['/users'].get.responses['200']"
    update:
      headers:
        Cache-Control:
          schema: { type: string }
          example: "max-age=300"

  # Remove deprecated endpoints from public docs
  - target: "$.paths[?@.get.deprecated == true]"
    remove: true
```

Apply overlays with tooling:

```bash
# Redocly supports overlays natively
npx @redocly/cli bundle openapi.yaml --overlay production-overlay.yaml -o public-api.yaml

# Or use the overlay CLI
npx oas-overlay apply openapi.yaml production-overlay.yaml -o output.yaml
```

---

## Arazzo Specification

Arazzo (formerly OpenAPI Workflows) describes sequences of API calls, enabling testing, documentation, and orchestration of multi-step API interactions.

### Workflow Structure

```yaml
arazzo: 1.0.1
info:
  title: E-Commerce Order Workflow
  version: 1.0.0
  description: Complete order lifecycle from cart to delivery

sourceDescriptions:
  - name: shopApi
    url: ./openapi.yaml
    type: openapi

workflows:
  - workflowId: place-order
    summary: Place a new order from cart items
    inputs:
      type: object
      required: [customerId, paymentMethodId]
      properties:
        customerId: { type: string }
        paymentMethodId: { type: string }
    steps:
      - stepId: get-cart
        operationId: shopApi.getCart
        parameters:
          - name: customerId
            in: path
            value: $inputs.customerId
        successCriteria:
          - condition: $statusCode == 200
        outputs:
          cartId: $response.body#/id
          cartTotal: $response.body#/total

      - stepId: create-order
        operationId: shopApi.createOrder
        requestBody:
          contentType: application/json
          payload:
            cartId: $steps.get-cart.outputs.cartId
            paymentMethodId: $inputs.paymentMethodId
        successCriteria:
          - condition: $statusCode == 201
        outputs:
          orderId: $response.body#/id

      - stepId: confirm-payment
        operationId: shopApi.confirmPayment
        parameters:
          - name: orderId
            in: path
            value: $steps.create-order.outputs.orderId
        successCriteria:
          - condition: $statusCode == 200
          - condition: $response.body#/status == 'confirmed'
        outputs:
          paymentStatus: $response.body#/status

    outputs:
      orderId: $steps.create-order.outputs.orderId
      paymentStatus: $steps.confirm-payment.outputs.paymentStatus
```

### Steps and Dependencies

Steps execute sequentially by default. Use `dependsOn` for explicit ordering:

```yaml
steps:
  - stepId: validate-inventory
    operationId: shopApi.checkInventory
    # ...

  - stepId: validate-payment
    operationId: shopApi.validatePaymentMethod
    # These two can run in parallel (no dependency)
    # ...

  - stepId: create-order
    operationId: shopApi.createOrder
    dependsOn:
      - validate-inventory
      - validate-payment
    # Runs only after both validations succeed
```

**Failure handling:**

```yaml
steps:
  - stepId: charge-payment
    operationId: shopApi.chargePayment
    onFailure:
      - name: payment-failed
        type: goto
        stepId: cancel-order
        criteria:
          - condition: $statusCode == 402
      - name: retry-on-timeout
        type: retry
        retryAfter: 5
        retryLimit: 3
        criteria:
          - condition: $statusCode == 504
```

### Expressions and Runtime Values

Arazzo uses JSONPath-like expressions:

| Expression | Description |
|---|---|
| `$inputs.customerId` | Workflow input parameter |
| `$steps.stepId.outputs.field` | Output from a previous step |
| `$response.body#/path/to/field` | Field from the response body |
| `$response.header.X-Request-Id` | Response header value |
| `$statusCode` | HTTP status code |
| `$url` | Resolved request URL |

---

## Reusable Components Organization

### File Structure for Large APIs

```
api/
├── openapi.yaml                    # Root document (paths + $refs)
├── paths/
│   ├── users.yaml                  # /users operations
│   ├── users_{userId}.yaml         # /users/{userId} operations
│   ├── orders.yaml
│   └── orders_{orderId}.yaml
├── schemas/
│   ├── User.yaml
│   ├── UserCreate.yaml
│   ├── Order.yaml
│   ├── _common/
│   │   ├── Pagination.yaml
│   │   ├── ErrorResponse.yaml
│   │   └── AuditFields.yaml
│   └── _enums/
│       ├── OrderStatus.yaml
│       └── UserRole.yaml
├── parameters/
│   ├── PathUserId.yaml
│   ├── QueryPagination.yaml
│   └── HeaderApiVersion.yaml
├── responses/
│   ├── NotFound.yaml
│   ├── Unauthorized.yaml
│   ├── ValidationError.yaml
│   └── InternalError.yaml
├── security/
│   └── schemes.yaml
├── examples/
│   ├── UserExample.yaml
│   └── OrderExample.yaml
└── overlays/
    ├── production.yaml
    ├── internal.yaml
    └── partner-acme.yaml
```

Root document:

```yaml
openapi: "3.1.0"
info:
  title: My API
  version: "2.0.0"
paths:
  /users:
    $ref: './paths/users.yaml'
  /users/{userId}:
    $ref: './paths/users_{userId}.yaml'
  /orders:
    $ref: './paths/orders.yaml'
components:
  schemas:
    User:
      $ref: './schemas/User.yaml'
    Pagination:
      $ref: './schemas/_common/Pagination.yaml'
  parameters:
    UserId:
      $ref: './parameters/PathUserId.yaml'
  responses:
    NotFound:
      $ref: './responses/NotFound.yaml'
```

### Shared Components Library

For organizations with multiple APIs, extract shared components into a package:

```
@myorg/api-components/
├── package.json
├── schemas/
│   ├── ErrorResponse.yaml
│   ├── Pagination.yaml
│   ├── Address.yaml
│   └── Money.yaml
├── parameters/
│   ├── Pagination.yaml
│   └── Correlation.yaml
├── responses/
│   ├── StandardErrors.yaml
│   └── HealthCheck.yaml
└── security/
    └── schemes.yaml
```

Reference from other specs:

```yaml
components:
  schemas:
    Error:
      $ref: 'https://raw.githubusercontent.com/myorg/api-components/main/schemas/ErrorResponse.yaml'
    # Or with npm/local path after install:
    Pagination:
      $ref: './node_modules/@myorg/api-components/schemas/Pagination.yaml'
```

### Cross-API Component Reuse

Use `$ref` with URL references for shared schemas across services:

```yaml
# In the orders service spec
components:
  schemas:
    OrderWithUser:
      type: object
      properties:
        order:
          $ref: '#/components/schemas/Order'
        user:
          $ref: 'https://api.example.com/specs/users/v2/openapi.yaml#/components/schemas/User'
```

**Best practices for shared components:**
1. Version the shared components library independently.
2. Use Redocly `bundle` to resolve all `$ref` into a single file for distribution.
3. Avoid deep `$ref` chains (A → B → C → D) — they slow down tooling and confuse generators.
4. Keep shared schemas minimal and stable; put service-specific extensions in the consuming spec.
5. Use CI to validate that all cross-references resolve correctly.
