---
name: openapi-spec
description: >
  Guide for creating, editing, and validating OpenAPI 3.0/3.1 REST API specifications.
  Covers full spec structure (info, servers, paths, components, security), schema composition
  (allOf/oneOf/anyOf/not, discriminator), parameters, request bodies, responses, authentication
  (API key, HTTP, OAuth2, OpenID Connect), links, callbacks, webhooks, code generation,
  validation, and documentation tooling. Use when user needs OpenAPI/Swagger specification,
  API documentation, REST API schema design, API-first development, or code generation from
  API spec. NOT for GraphQL schemas, NOT for gRPC/protobuf definitions, NOT for API gateway
  configuration, NOT for API testing tools like Postman or Newman.
---

# OpenAPI Specification

## Root Document Structure
```yaml
openapi: "3.1.0"  # Required. Use "3.0.3" for 3.0 track
info:              # Required
  title: My API
  version: "1.0.0"
  description: Resource management API
  contact: { name: API Team, email: api@example.com }
  license: { name: MIT, identifier: MIT }  # identifier is 3.1 only; use url in 3.0
servers:
  - url: https://api.example.com/{basePath}
    description: Production
    variables:
      basePath: { default: v1, enum: [v1, v2] }
  - url: http://localhost:3000/v1
    description: Local
paths: {}           # Endpoint definitions
components: {}      # Reusable schemas, params, responses, security
security: []        # Global security requirements
tags:               # Operation grouping
  - name: Users
    description: User management
externalDocs: { url: https://docs.example.com }
webhooks: {}        # 3.1 only
```

## Paths and Operations

Each path supports GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE. Always set `operationId`.

```yaml
paths:
  /users:
    get:
      tags: [Users]
      summary: List users
      operationId: listUsers
      parameters:
        - $ref: "#/components/parameters/Limit"
        - $ref: "#/components/parameters/Offset"
        - name: status
          in: query
          schema: { type: string, enum: [active, suspended] }
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema: { $ref: "#/components/schemas/UserList" }
        "401": { $ref: "#/components/responses/Unauthorized" }
      security:
        - bearerAuth: []
    post:
      tags: [Users]
      summary: Create user
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/CreateUser" }
            example: { name: Jane Doe, email: jane@example.com }
      responses:
        "201":
          description: Created
          headers:
            Location: { schema: { type: string }, description: URL of new resource }
          content:
            application/json:
              schema: { $ref: "#/components/schemas/User" }
          links:
            GetUser:
              operationId: getUserById
              parameters: { userId: $response.body#/id }
        "400": { $ref: "#/components/responses/BadRequest" }
        "409": { description: Email already exists }
  /users/{userId}:
    parameters:
      - $ref: "#/components/parameters/UserId"
    get:
      tags: [Users]
      summary: Get user
      operationId: getUserById
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema: { $ref: "#/components/schemas/User" }
        "404": { $ref: "#/components/responses/NotFound" }
    put:
      summary: Replace user
      operationId: replaceUser
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/CreateUser" } } } }
      responses: { "200": { description: Replaced } }
    patch:
      summary: Partial update
      operationId: patchUser
      requestBody:
        required: true
        content:
          application/merge-patch+json:
            schema: { $ref: "#/components/schemas/PatchUser" }
      responses: { "200": { description: Updated } }
    delete:
      summary: Delete user
      operationId: deleteUser
      responses: { "204": { description: Deleted } }
```

## Parameters (path, query, header, cookie)

```yaml
components:
  parameters:
    UserId:
      name: userId
      in: path
      required: true  # Path params MUST be required
      schema: { type: string, format: uuid }
    Limit:
      name: limit
      in: query
      schema: { type: integer, minimum: 1, maximum: 100, default: 20 }
    Offset:
      name: offset
      in: query
      schema: { type: integer, minimum: 0, default: 0 }
    Cursor:
      name: cursor
      in: query
      schema: { type: string }
      description: Opaque pagination cursor
    ApiVersion:
      name: X-API-Version
      in: header
      schema: { type: string, enum: ["2024-01-01", "2024-06-01"] }
    SessionId:
      name: session_id
      in: cookie
      schema: { type: string }
```

Array/object query params — use `style` and `explode`:
```yaml
- name: tags
  in: query
  explode: true  # ?tags=a&tags=b
  schema: { type: array, items: { type: string } }
- name: filter
  in: query
  style: deepObject
  explode: true  # ?filter[name]=john&filter[age]=30
  schema:
    type: object
    properties:
      name: { type: string }
      age: { type: integer }
```

## Request Bodies

**JSON with multiple examples:**
```yaml
requestBody:
  required: true
  content:
    application/json:
      schema: { $ref: "#/components/schemas/Order" }
      examples:
        standard: { summary: Standard order, value: { items: [{ id: p1, qty: 2 }] } }
        express: { summary: Express, value: { items: [{ id: p2, qty: 1 }], priority: express } }
```

**Multipart/file upload:**
```yaml
requestBody:
  content:
    multipart/form-data:
      schema:
        type: object
        required: [file]
        properties:
          file: { type: string, format: binary }
          description: { type: string }
      encoding:
        file: { contentType: "image/png, image/jpeg, application/pdf" }
```

## Responses

Standard HTTP status codes. Define reusable responses in components:
```yaml
components:
  responses:
    BadRequest:
      description: Invalid request
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" } } }
    Unauthorized:
      description: Missing/invalid auth
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" } } }
    Forbidden:
      description: Insufficient permissions
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" } } }
    NotFound:
      description: Resource not found
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" } } }
    TooManyRequests:
      description: Rate limited
      headers:
        Retry-After: { schema: { type: integer } }
        X-RateLimit-Limit: { schema: { type: integer } }
        X-RateLimit-Remaining: { schema: { type: integer } }
```

## Schemas and Data Models

### Core Types and Formats
```yaml
components:
  schemas:
    User:
      type: object
      required: [id, name, email, createdAt]
      properties:
        id: { type: string, format: uuid, readOnly: true }
        name: { type: string, minLength: 1, maxLength: 100 }
        email: { type: string, format: email }
        age: { type: integer, minimum: 0, maximum: 150 }
        role: { type: string, enum: [admin, editor, viewer], default: viewer }
        avatar: { type: string, format: uri, nullable: true }  # 3.0; in 3.1 use type: ["string", "null"]
        metadata: { type: object, additionalProperties: { type: string } }
        tags: { type: array, items: { type: string }, uniqueItems: true, maxItems: 10 }
        createdAt: { type: string, format: date-time, readOnly: true }
    CreateUser:
      type: object
      required: [name, email]
      properties:
        name: { type: string }
        email: { type: string, format: email }
        role: { type: string, enum: [admin, editor, viewer] }
    PatchUser:
      type: object
      minProperties: 1
      properties:
        name: { type: string }
        email: { type: string, format: email }
```

### allOf — Composition/Inheritance
```yaml
    AdminUser:
      allOf:
        - $ref: "#/components/schemas/User"
        - type: object
          required: [permissions]
          properties:
            permissions: { type: array, items: { type: string } }
            department: { type: string }
```

### oneOf — Exactly One (with Discriminator)
```yaml
    Notification:
      oneOf:
        - $ref: "#/components/schemas/EmailNotif"
        - $ref: "#/components/schemas/SmsNotif"
      discriminator:
        propertyName: channel
        mapping:
          email: "#/components/schemas/EmailNotif"
          sms: "#/components/schemas/SmsNotif"
    EmailNotif:
      type: object
      required: [channel, recipient, subject]
      properties:
        channel: { type: string }
        recipient: { type: string, format: email }
        subject: { type: string }
    SmsNotif:
      type: object
      required: [channel, phone, message]
      properties:
        channel: { type: string }
        phone: { type: string, pattern: '^\+[1-9]\d{1,14}$' }
        message: { type: string, maxLength: 160 }
```

### anyOf — At Least One Match
```yaml
    SearchResult:
      anyOf:
        - $ref: "#/components/schemas/User"
        - $ref: "#/components/schemas/Product"
```

### not — Must Not Match
```yaml
    NonEmptyString:
      type: string
      not: { maxLength: 0 }
```

## Security Schemes
```yaml
components:
  securitySchemes:
    bearerAuth: { type: http, scheme: bearer, bearerFormat: JWT }
    apiKey: { type: apiKey, in: header, name: X-API-Key }
    basicAuth: { type: http, scheme: basic }
    oauth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://auth.example.com/authorize
          tokenUrl: https://auth.example.com/token
          refreshUrl: https://auth.example.com/refresh
          scopes: { "users:read": Read users, "users:write": Modify users, admin: Full access }
        clientCredentials:
          tokenUrl: https://auth.example.com/token
          scopes: { "api:access": General access }
    oidc:
      type: openIdConnect
      openIdConnectUrl: https://auth.example.com/.well-known/openid-configuration
# Apply globally:
security:
  - bearerAuth: []
# Public endpoint override: set security: [] on the operation
```

## Links and Callbacks

**Links** connect responses to follow-up operations:
```yaml
links:
  GetCreatedUser:
    operationId: getUserById
    parameters: { userId: $response.body#/id }
```

**Callbacks** define async webhook deliveries:
```yaml
paths:
  /subscriptions:
    post:
      operationId: subscribe
      requestBody:
        content:
          application/json:
            schema:
              type: object
              required: [url, events]
              properties:
                url: { type: string, format: uri }
                events: { type: array, items: { type: string, enum: [user.created, order.placed] } }
      callbacks:
        onEvent:
          "{$request.body#/url}":
            post:
              requestBody:
                content: { application/json: { schema: { $ref: "#/components/schemas/WebhookEvent" } } }
              responses: { "200": { description: Acknowledged } }
```

## Webhooks (3.1 Only)
```yaml
webhooks:
  userCreated:
    post:
      requestBody:
        content: { application/json: { schema: { $ref: "#/components/schemas/WebhookEvent" } } }
      responses: { "200": { description: Processed } }
```

## Common Patterns

**Paginated list (offset):**```yaml
    UserList:
      type: object
      required: [data, pagination]
      properties:
        data: { type: array, items: { $ref: "#/components/schemas/User" } }
        pagination:
          type: object
          properties:
            total: { type: integer }
            limit: { type: integer }
            offset: { type: integer }
            hasMore: { type: boolean }
```

**Cursor pagination:**
```yaml
    CursorPage:
      type: object
      properties:
        data: { type: array, items: {} }
        cursors: { type: object, properties: { before: { type: string }, after: { type: string } } }
        hasNext: { type: boolean }
```

**Error response (RFC 7807):**
```yaml
    Error:
      type: object
      required: [type, title, status]
      properties:
        type: { type: string, format: uri }
        title: { type: string }
        status: { type: integer }
        detail: { type: string }
        instance: { type: string, format: uri }
        errors:
          type: array
          items:
            type: object
            properties: { field: { type: string }, message: { type: string }, code: { type: string } }
```

**Sorting/filtering params:**
```yaml
- name: sort
  in: query
  schema: { type: string, pattern: '^[a-zA-Z_]+(:(asc|desc))?$', example: "createdAt:desc" }
- name: search
  in: query
  schema: { type: string, minLength: 2 }
```

## Specification Extensions

Prefix custom fields with `x-`: e.g. `x-internal: true`, `x-rate-limit: 100`, `x-stability: experimental`.

## Tooling

| Category | Tool | Command / Usage |
|----------|------|----------------|
| Validate | Spectral | `spectral lint openapi.yaml` |
| Validate | redocly-cli | `redocly lint openapi.yaml` |
| Bundle | redocly-cli | `redocly bundle openapi.yaml -o bundle.yaml` |
| Docs | Swagger UI | Interactive browser explorer |
| Docs | Redoc | `redocly preview-docs openapi.yaml` |
| Codegen | openapi-generator | `openapi-generator-cli generate -i spec.yaml -g typescript-axios -o ./sdk` |

## Design-First vs Code-First

- **Design-first**: Write spec YAML before code. Generate server stubs. Best for governance and contract-driven development.
- **Code-first**: Annotate code, auto-generate spec. Use SpringDoc (Java), FastAPI (Python), swaggo (Go), tsoa (TypeScript).
- **Hybrid**: Maintain spec as source of truth; validate generated code matches spec in CI.

## Key Rules

- Set `operationId` on every operation — required for codegen and links
- Use `$ref` for all reusable objects; keep definitions in `components`
- Mark `required` fields explicitly; never rely on implicit defaults
- Use `readOnly`/`writeOnly` to distinguish response vs request shapes
- Include `example`/`examples` on schemas and media types
- Set `format` on strings: uuid, email, uri, date-time, date, password, binary, byte
- Use `pattern` for string validation (phones, slugs, codes)
- Set `deprecated: true` instead of removing endpoints/fields
- Validate specs in CI with Spectral or redocly-cli before merge

## References

Deep-dive documentation in `references/`:

- **`advanced-patterns.md`** — Schema composition (allOf/oneOf/anyOf/discriminator), polymorphism, circular references, API versioning strategies (URL/header/content-type), pagination patterns (cursor/offset/keyset), filtering/sorting/field selection, HATEOAS links, webhooks/callbacks, rate limiting headers
- **`troubleshooting.md`** — Spec validation errors, code generation gotchas, breaking vs non-breaking changes, Swagger 2→OpenAPI 3 migration, security scheme misconfigurations, `$ref` resolution problems, nullable vs required confusion, `additionalProperties` pitfalls, YAML syntax gotchas
- **`api-reference.md`** — Complete field reference for every OpenAPI 3.1 object (Info, Server, PathItem, Operation, Parameter, RequestBody, Response, Schema, SecurityScheme, Discriminator, Components, etc.) with all properties, types, defaults, and examples

## Scripts

Executable helper scripts in `scripts/`:

- **`validate-spec.sh`** — Validates an OpenAPI spec using Spectral or swagger-cli. Auto-installs tools. Usage: `./scripts/validate-spec.sh openapi.yaml [--tool spectral|swagger-cli] [--ruleset .spectral.yml]`
- **`generate-client.sh`** — Generates API client/server code via openapi-generator-cli. Supports 50+ languages (TypeScript, Python, Java, Go, etc.). Usage: `./scripts/generate-client.sh openapi.yaml -l typescript-axios -o ./sdk`
- **`mock-server.sh`** — Starts a Prism mock server from an OpenAPI spec. Validates requests, returns spec examples or dynamic data. Usage: `./scripts/mock-server.sh openapi.yaml [--port 4010] [--dynamic]`

## Assets

Reusable templates and schemas in `assets/`:

- **`openapi-template.yaml`** — Complete OpenAPI 3.1 starter template with health check, CRUD endpoints, cursor pagination, RFC 7807 errors, rate limiting headers, and security schemes pre-configured
- **`error-response.yaml`** — Reusable RFC 7807 error components for 400, 401, 403, 404, 409, 422, 500

<!-- tested: pass -->
