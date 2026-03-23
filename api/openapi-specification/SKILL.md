---
name: openapi-specification
description: |
  Positive: "Use when user writes OpenAPI specs, asks about Swagger, API-first design, OpenAPI 3.1 features, code generation from specs, schema components, or API documentation tools (Redocly, Stoplight, SwaggerUI)."
  Negative: "Do NOT use for GraphQL schema design (use graphql-schema-design skill), gRPC protobuf (use grpc-protobuf skill), or REST API design without OpenAPI specifics (use rest-api-design skill)."
---

# OpenAPI Specification Best Practices

## Spec Structure Fundamentals

```yaml
openapi: 3.1.0
info:
  title: Acme API
  version: 1.2.0
  description: Manages widgets and orders.
  contact: { name: API Team, email: api@acme.io }
  license: { name: MIT, identifier: MIT }
servers:
  - url: https://api.acme.io/v1
    description: Production
  - url: https://staging-api.acme.io/v1
    description: Staging
paths: {}
components: {}
webhooks: {}
```

- Set `openapi` to `3.1.0` for full JSON Schema 2020-12 support.
- Include `info.contact` and `info.license` for every public API.
- Define at least production and staging `servers`.
- Use `components` to centralize reusable schemas, parameters, responses, and security schemes.

## OpenAPI 3.1 vs 3.0

| Feature | 3.0 | 3.1 |
|---|---|---|
| JSON Schema | Partial (modified draft 5/7) | Full Draft 2020-12 |
| Nullable | `nullable: true` | `type: [string, "null"]` |
| Webhooks | No native support | Top-level `webhooks` object |
| Type arrays | Not supported | `type: [string, integer]` |
| Examples | `example` (singular) | `examples` (array, JSON Schema standard) |
| Conditional schemas | Not supported | `if`/`then`/`else` supported |
| `$ref` siblings | Siblings ignored | Siblings applied alongside `$ref` |

Migration: replace `nullable: true` with type arrays. Change `example` to `examples` (array). Replace `exclusiveMinimum: true` + `minimum: 5` with `exclusiveMinimum: 5`. Move callbacks to top-level `webhooks`. Add `jsonSchemaDialect` at root if using a custom dialect.

## Paths and Operations

```yaml
paths:
  /users:
    get:
      operationId: listUsers
      summary: List all users
      tags: [Users]
      parameters:
        - $ref: '#/components/parameters/PageParam'
        - $ref: '#/components/parameters/LimitParam'
      responses:
        '200':
          description: A paginated list of users.
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/UserList'
        '401':
          $ref: '#/components/responses/Unauthorized'
    post:
      operationId: createUser
      summary: Create a new user
      tags: [Users]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateUserRequest'
            examples:
              basic:
                value: { name: Jane Doe, email: jane@example.com }
      responses:
        '201':
          description: User created.
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
        '422':
          $ref: '#/components/responses/ValidationError'
```

- Always set `operationId` — code generators use it for method names. Use camelCase.
- Use nouns for paths (`/users`), never verbs (`/getUsers`). Use plural consistently.
- Group endpoints with `tags`. Include `summary` per operation.
- Define responses for success, client error (4xx), and server error (5xx).

## Schemas and Components

```yaml
components:
  schemas:
    User:
      type: object
      required: [id, name, email]
      properties:
        id:
          type: string
          format: uuid
          readOnly: true
        name:
          type: string
          minLength: 1
          maxLength: 200
        email:
          type: string
          format: email
        role:
          $ref: '#/components/schemas/Role'
    Role:
      type: string
      enum: [admin, editor, viewer]
    CreateUserRequest:
      type: object
      required: [name, email]
      properties:
        name: { type: string, minLength: 1 }
        email: { type: string, format: email }
        role: { $ref: '#/components/schemas/Role' }
```

### Composition: allOf, oneOf, anyOf

```yaml
    OrderEvent:
      allOf:
        - $ref: '#/components/schemas/BaseEvent'
        - type: object
          required: [orderId]
          properties:
            orderId: { type: string }
    PaymentMethod:
      oneOf:
        - $ref: '#/components/schemas/CreditCard'
        - $ref: '#/components/schemas/BankTransfer'
      discriminator:
        propertyName: methodType
        mapping:
          credit_card: '#/components/schemas/CreditCard'
          bank_transfer: '#/components/schemas/BankTransfer'
```

- Use `allOf` for inheritance. Use `oneOf` + `discriminator` for polymorphism (always include `mapping`). Use `anyOf` when multiple schemas may match simultaneously.
- Separate request and response schemas — use `readOnly`/`writeOnly` or distinct types (`CreateUserRequest` vs `User`).

## Parameters

```yaml
components:
  parameters:
    PageParam:
      name: page
      in: query
      schema: { type: integer, minimum: 1, default: 1 }
    LimitParam:
      name: limit
      in: query
      schema: { type: integer, minimum: 1, maximum: 100, default: 20 }
    UserIdPath:
      name: userId
      in: path
      required: true
      schema: { type: string, format: uuid }
    CorrelationHeader:
      name: X-Correlation-ID
      in: header
      schema: { type: string, format: uuid }
```

- Path parameters are always `required: true`.
- Set `default` for optional query params. Add `minimum`/`maximum`/`maxLength` constraints.
- Use `in: query` for filtering, `in: header` for metadata, `in: cookie` for sessions.
- Define in `components/parameters` and `$ref` them.

## Request/Response Bodies

### File upload

```yaml
paths:
  /documents:
    post:
      operationId: uploadDocument
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [file, title]
              properties:
                file: { type: string, format: binary }
                title: { type: string }
            encoding:
              file:
                contentType: application/pdf, image/png
      responses:
        '201':
          description: Document uploaded.
          headers:
            Location: { schema: { type: string, format: uri } }
```

### Error responses — use RFC 9457

```yaml
components:
  responses:
    Unauthorized:
      description: Authentication required.
      content:
        application/problem+json:
          schema: { $ref: '#/components/schemas/ProblemDetail' }
  schemas:
    ProblemDetail:
      type: object
      required: [type, title, status]
      properties:
        type: { type: string, format: uri }
        title: { type: string }
        status: { type: integer }
        detail: { type: string }
        errors:
          type: array
          items:
            type: object
            properties:
              field: { type: string }
              message: { type: string }
```

- Use `application/problem+json` for all error responses.
- Define reusable responses in `components/responses`.
- Provide concrete `examples` for every content type.

## Security Schemes

```yaml
components:
  securitySchemes:
    BearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
    OAuth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://auth.acme.io/authorize
          tokenUrl: https://auth.acme.io/token
          scopes:
            users:read: Read user profiles
            users:write: Create and update users
    OpenIdConnect:
      type: openIdConnect
      openIdConnectUrl: https://auth.acme.io/.well-known/openid-configuration
security:
  - BearerAuth: []
```

- Apply `security` at root for global auth. Override per-operation with `security: []` for public endpoints.
- Define granular OAuth2 scopes; reference per operation: `security: [{OAuth2: [users:read]}]`.

## API-First Design Workflow

1. **Design** — Write the OpenAPI spec before implementation. Use Swagger Editor, Stoplight Studio, or editor plugins.
2. **Lint** — Run `redocly lint openapi.yaml` or Spectral to catch issues.
3. **Review** — Share rendered docs with stakeholders. Iterate on the contract.
4. **Mock** — Generate mock servers (Prism) so frontend teams develop in parallel.
5. **Generate** — Produce server stubs and client SDKs from the spec.
6. **Implement** — Build against generated interfaces. Spec is the single source of truth.
7. **Test** — Run contract tests (Schemathesis, Dredd) to verify implementation matches spec.
8. **Publish** — Deploy interactive documentation. Regenerate clients on spec changes.

Never hand-edit generated code — regenerate it.

## Code Generation

| Tool | Languages | Best for |
|---|---|---|
| openapi-generator | 50+ (Java, Go, Python, TS, Rust, C#) | Multi-language SDKs, server stubs |
| oapi-codegen | Go | Idiomatic Go servers/clients (Chi, Echo, Gin, Fiber) |
| Orval | TypeScript | React Query hooks, Axios clients |
| openapi-typescript | TypeScript | Type-only generation (no runtime) |

```bash
# TypeScript Axios client
openapi-generator-cli generate -i openapi.yaml -g typescript-axios \
  -o ./generated/client --additional-properties=supportsES6=true

# Spring Boot server (interface only)
openapi-generator-cli generate -i openapi.yaml -g spring \
  -o ./generated/server --additional-properties=useSpringBoot3=true,interfaceOnly=true
```

- Pin generator versions in CI. Use `interfaceOnly=true` for server stubs.
- Store specs in VCS; generate code in CI. Use `.openapi-generator-ignore` to protect custom files.

## Linting and Validation

### Spectral config

```yaml
# .spectral.yaml
extends: ["spectral:oas"]
rules:
  operation-operationId: error
  operation-tags: error
  oas3-schema: error
  info-contact: warn
```

### Redocly config

```yaml
# redocly.yaml
extends: [recommended]
rules:
  no-unresolved-refs: error
  operation-operationId-unique: error
  no-server-trailing-slash: warn
  path-not-include-query: error
```

### CI integration

```yaml
# .github/workflows/openapi-lint.yml
name: OpenAPI Lint
on: [pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npx @redocly/cli lint openapi.yaml
      - run: npx @stoplight/spectral-cli lint openapi.yaml --fail-severity warn
```

Run linting on every PR. Block merges on errors. Use `redocly bundle` to combine multi-file specs. Use `redocly preview-docs` for local preview.

## Documentation

| Tool | Strengths |
|---|---|
| Redocly | Three-panel layout, search, custom themes, Markdown extensions |
| SwaggerUI | Try-it-out console, widely adopted, embeddable |
| Stoplight Elements | React component, embed in existing apps |
| RapiDoc | Single HTML file, highly customizable |

```bash
redocly build-docs openapi.yaml -o docs/index.html
```

```html
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>
  SwaggerUIBundle({ url: "/openapi.yaml", dom_id: '#swagger-ui' });
</script>
```

- Provide examples — doc tools render them as sample requests/responses.
- Use `x-tagGroups` (Redocly) to organize large APIs into sections.

## Multi-File Specs

```
api/
├── openapi.yaml           # Root document
├── paths/
│   ├── users.yaml
│   └── orders.yaml
├── schemas/
│   ├── User.yaml
│   └── Order.yaml
└── responses/
    └── errors.yaml
```

```yaml
# Root document with external $ref
openapi: 3.1.0
info: { title: Acme API, version: 2.0.0 }
paths:
  /users: { $ref: './paths/users.yaml' }
  /orders: { $ref: './paths/orders.yaml' }
components:
  schemas:
    User: { $ref: './schemas/User.yaml' }
    Order: { $ref: './schemas/Order.yaml' }
```

- Split when root file exceeds ~500 lines. Group by domain (paths, schemas), not HTTP method.
- Bundle before publishing or code generation: `redocly bundle openapi.yaml -o bundled.yaml`.

## Versioning Strategies

```yaml
# URL path versioning (most common)
servers:
  - url: https://api.acme.io/v2
info:
  version: 2.3.1

# Header versioning
parameters:
  - name: X-API-Version
    in: header
    schema: { type: string, default: "2" }

# Content negotiation
responses:
  '200':
    content:
      application/vnd.acme.v2+json:
        schema: { $ref: '#/components/schemas/UserV2' }
```

- Use semantic versioning in `info.version`. Maintain one spec file per major version.
- Mark deprecated operations with `deprecated: true` and migration notes.
- Use oasdiff or Redocly to detect breaking changes in CI.

## Webhooks (3.1)

```yaml
webhooks:
  orderCompleted:
    post:
      operationId: onOrderCompleted
      summary: Fired when an order is fulfilled.
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/OrderEvent' }
      responses:
        '200':
          description: Webhook received.
```

- Define webhooks at the top level, not inside `paths`.
- Document expected consumer response and include retry/signature guidance in `description`.

## Anti-Patterns

- **Inline schemas everywhere** — Extract to `components/schemas`. Inline schemas break code generation.
- **Missing examples** — Every request/response needs at least one example for docs and mock servers.
- **Incomplete error responses** — Define 400, 401, 403, 404, 422, 500. Use shared `ProblemDetail`.
- **Verbs in paths** — Use `/users` not `/getUsers`.
- **Over-referencing** — Don't `$ref` trivial one-field schemas. Reference complex, reused types only.
- **No operationId** — Code generators produce unusable method names without it.
- **Unbounded collections** — Set `maxItems` on arrays, `maxLength` on strings in requests.
- **Single schema for request and response** — Separate `CreateX` from `X` (with server-generated fields).
- **No validation constraints** — Add `minimum`, `maximum`, `pattern`, `format`, `enum`.
- **Ignoring readOnly/writeOnly** — Mark `id`, `createdAt` as `readOnly`; `password` as `writeOnly`.
- **Trailing slashes on server URLs** — Causes double-slash issues.
- **No tags** — Endpoints render as flat, unorganized lists in documentation.

<!-- tested: pass -->
