---
name: swagger-openapi
description: >
  Expert guidance for OpenAPI (formerly Swagger) specification authoring, validation, and tooling.
  TRIGGER when: user mentions "OpenAPI", "Swagger", "openapi spec", "API specification",
  "swagger-ui", "openapi-generator", "swagger-codegen", "API schema definition",
  "paths and operations", "openapi.yaml", "openapi.json", "OAS 3", "$ref in API spec",
  "API documentation generation", "Redoc", "spectral", "openapi-lint", "API design-first",
  "code-first API", "swagger editor", "operationId", "requestBody", "API components schema".
  NOT for GraphQL schemas, gRPC proto files, AsyncAPI, RAML, or general REST API design
  without OpenAPI context.
---

# OpenAPI / Swagger Skill

## Spec Structure (OpenAPI 3.1)

OpenAPI 3.1 is fully compatible with JSON Schema Draft 2020-12. A document has these top-level fields:

```yaml
openapi: "3.1.0"
info:
  title: My API
  version: "1.0.0"
  description: API for managing resources
  license:
    name: Apache 2.0
    identifier: Apache-2.0        # SPDX expression (3.1+)
jsonSchemaDialect: "https://json-schema.org/draft/2020-12/schema"  # optional, 3.1+
servers:
  - url: https://api.example.com/v1
    description: Production
  - url: https://staging.api.example.com/v1
    description: Staging
paths:
  /resources: ...
webhooks:          # 3.1+: top-level webhooks (no longer forced into callbacks)
  newResource: ...
components:
  schemas: ...
  securitySchemes: ...
  parameters: ...
  responses: ...
  requestBodies: ...
  headers: ...
  links: ...
  callbacks: ...
  pathItems: ...   # 3.1+
security: []
tags: []
externalDocs: {}
```

Key 3.1 changes from 3.0:
- `nullable: true` → `type: ["string", "null"]`
- `example` (single) → `examples` (array, JSON Schema standard)
- `format: binary` → `contentEncoding: base64` / `contentMediaType`
- `paths` is optional (spec can define only webhooks or components)
- Full JSON Schema keywords: `if/then/else`, `prefixItems`, `$dynamicRef`

## Paths & Operations

```yaml
paths:
  /users/{userId}:
    get:
      operationId: getUserById
      summary: Get a user by ID
      tags: [Users]
      parameters:
        - $ref: '#/components/parameters/UserId'
      responses:
        '200':
          description: Successful response
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
        '404':
          $ref: '#/components/responses/NotFound'
    put:
      operationId: updateUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/UserUpdate'
      responses:
        '200':
          description: Updated
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
```

## Parameters (path, query, header, cookie)

```yaml
components:
  parameters:
    UserId:
      name: userId
      in: path
      required: true
      schema:
        type: string
        format: uuid
    PageSize:
      name: pageSize
      in: query
      required: false
      schema:
        type: integer
        minimum: 1
        maximum: 100
        default: 20
    ApiVersion:
      name: X-API-Version
      in: header
      required: false
      schema:
        type: string
    SessionToken:
      name: session_id
      in: cookie
      schema:
        type: string
```

## Schema Definitions & Composition

### $ref

```yaml
components:
  schemas:
    User:
      type: object
      required: [id, email]
      properties:
        id:
          type: string
          format: uuid
        email:
          type: string
          format: email
        name:
          type: ["string", "null"]   # nullable in 3.1
        role:
          $ref: '#/components/schemas/Role'
    Role:
      type: string
      enum: [admin, editor, viewer]
```

### allOf (inheritance / merge)

```yaml
UserWithTimestamps:
  allOf:
    - $ref: '#/components/schemas/User'
    - type: object
      properties:
        createdAt:
          type: string
          format: date-time
        updatedAt:
          type: string
          format: date-time
```

### oneOf / anyOf with discriminator

```yaml
Pet:
  oneOf:
    - $ref: '#/components/schemas/Cat'
    - $ref: '#/components/schemas/Dog'
  discriminator:
    propertyName: petType
    mapping:
      cat: '#/components/schemas/Cat'
      dog: '#/components/schemas/Dog'
Cat:
  type: object
  required: [petType]
  properties:
    petType:
      type: string
    clawLength:
      type: number
Dog:
  type: object
  required: [petType]
  properties:
    petType:
      type: string
    barkVolume:
      type: integer
```

`anyOf` allows matching multiple schemas simultaneously; `oneOf` requires exactly one match.

## Security Schemes

```yaml
components:
  securitySchemes:
    BearerAuth: { type: http, scheme: bearer, bearerFormat: JWT }
    ApiKeyAuth: { type: apiKey, in: header, name: X-API-Key }
    OAuth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://auth.example.com/authorize
          tokenUrl: https://auth.example.com/token
          scopes: { read:users: Read user data, write:users: Modify user data }
        clientCredentials:
          tokenUrl: https://auth.example.com/token
          scopes: { admin: Full admin access }
    OpenIdConnect:
      type: openIdConnect
      openIdConnectUrl: https://auth.example.com/.well-known/openid-configuration

security: [{ BearerAuth: [] }, { OAuth2: [read:users] }]  # global
# Per-operation override: paths./admin.get.security: [{ ApiKeyAuth: [] }]
```

## Webhooks, Links & Callbacks

```yaml
# Webhooks (3.1+ top-level)
webhooks:
  orderStatusChanged:
    post:
      operationId: onOrderStatusChanged
      requestBody: { required: true, content: { application/json: { schema: { $ref: '#/components/schemas/OrderEvent' } } } }
      responses: { '200': { description: Webhook received } }
```

```yaml
# Links — describe relationships between operations
paths:
  /orders/{orderId}:
    get:
      operationId: getOrder
      responses:
        '200':
          description: Order details
          links:
            GetOrderItems:
              operationId: getOrderItems
              parameters: { orderId: '$response.body#/id' }

# Callbacks — runtime-registered webhooks
  /webhooks/register:
    post:
      operationId: registerWebhook
      requestBody:
        content: { application/json: { schema: { type: object, properties: { callbackUrl: { type: string, format: uri } } } } }
      callbacks:
        onEvent:
          '{$request.body#/callbackUrl}':
            post:
              requestBody: { content: { application/json: { schema: { $ref: '#/components/schemas/Event' } } } }
              responses: { '200': { description: Callback acknowledged } }
```

## Code Generation

### openapi-generator (preferred)

```bash
npm install @openapitools/openapi-generator-cli -g
# TypeScript client
openapi-generator-cli generate -i openapi.yaml -g typescript-axios -o ./generated/client \
  --additional-properties=supportsES6=true,npmName=my-api-client
# Python FastAPI server
openapi-generator-cli generate -i openapi.yaml -g python-fastapi -o ./generated/server
# Java Spring server
openapi-generator-cli generate -i openapi.yaml -g spring -o ./generated/spring-server \
  --additional-properties=useSpringBoot3=true
```

50+ generators available (`openapi-generator-cli list`). For legacy projects: `swagger-codegen generate -i openapi.yaml -l python -o ./output`

## Documentation Tools

### Swagger UI
```html
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css" />
<div id="swagger-ui"></div>
<script>SwaggerUIBundle({ url: "/openapi.yaml", dom_id: '#swagger-ui' });</script>
```
```bash
docker run -p 8080:8080 -e SWAGGER_JSON=/spec/openapi.yaml -v $(pwd):/spec swaggerapi/swagger-ui
```

### Redoc
```html
<script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
<redoc spec-url="/openapi.yaml"></redoc>
```
```bash
npx @redocly/cli build-docs openapi.yaml -o docs.html
```

## Validation & Linting

### Spectral (recommended linter)

```bash
npm install -g @stoplight/spectral-cli

# Lint with default OpenAPI ruleset
spectral lint openapi.yaml

# Custom ruleset (.spectral.yaml)
```

```yaml
# .spectral.yaml
extends: ["spectral:oas"]
rules:
  operation-operationId: error            # require operationId
  operation-description: warn             # warn if no description
  oas3-schema: error                      # validate against OAS3 schema
  info-contact: off                       # disable contact requirement
  custom-path-casing:
    given: "$.paths[*]~"
    then:
      function: pattern
      functionOptions:
        match: "^/[a-z][a-z0-9-/{}]*$"   # enforce kebab-case paths
    severity: error
    message: "Paths must be kebab-case"
```

### Redocly CLI (validation + bundling)

```bash
npx @redocly/cli lint openapi.yaml
npx @redocly/cli bundle openapi.yaml -o bundled.yaml   # resolve $ref
npx @redocly/cli split openapi.yaml --outDir ./specs    # split into files
```

## Design-First vs Code-First

| Aspect | Design-First | Code-First |
|--------|-------------|------------|
| Flow | Write spec → generate code | Write code → generate spec |
| Spec tool | Swagger Editor, Stoplight Studio | Annotations/decorators in code |
| Pros | Contract agreed before coding; parallel frontend/backend work | Spec always matches implementation |
| Cons | Spec can drift from code | Spec quality depends on annotations |
| Best for | Public APIs, multi-team | Internal APIs, rapid prototyping |

**Design-first tools:** Swagger Editor, Stoplight Studio, Redocly VS Code extension
**Code-first frameworks:**
- **Java:** springdoc-openapi (Spring Boot → OAS3 at `/v3/api-docs`)
- **Python:** FastAPI (auto-generates at `/openapi.json`), drf-spectacular (Django REST)
- **Node.js:** tsoa, express-openapi-validator, nestjs/swagger
- **.NET:** Swashbuckle, NSwag

## Examples

### Example 1: CRUD spec skeleton

**Input:** "Write an OpenAPI spec for a TODO API with CRUD"

**Output:** (abbreviated — full spec includes components/schemas)

```yaml
openapi: "3.1.0"
info: { title: TODO API, version: "1.0.0" }
servers: [{ url: https://api.example.com }]
paths:
  /todos:
    get:
      operationId: listTodos
      parameters: [{ name: completed, in: query, schema: { type: boolean } }]
      responses:
        '200':
          description: List of todos
          content: { application/json: { schema: { type: array, items: { $ref: '#/components/schemas/Todo' } } } }
    post:
      operationId: createTodo
      requestBody: { required: true, content: { application/json: { schema: { $ref: '#/components/schemas/TodoCreate' } } } }
      responses: { '201': { description: Created, content: { application/json: { schema: { $ref: '#/components/schemas/Todo' } } } } }
  /todos/{todoId}:
    parameters: [{ name: todoId, in: path, required: true, schema: { type: string, format: uuid } }]
    get:
      operationId: getTodo
      responses: { '200': { description: A todo, content: { application/json: { schema: { $ref: '#/components/schemas/Todo' } } } }, '404': { description: Not found } }
    put:
      operationId: updateTodo
      requestBody: { required: true, content: { application/json: { schema: { $ref: '#/components/schemas/TodoCreate' } } } }
      responses: { '200': { description: Updated, content: { application/json: { schema: { $ref: '#/components/schemas/Todo' } } } } }
    delete:
      operationId: deleteTodo
      responses: { '204': { description: Deleted } }
components:
  schemas:
    Todo:
      type: object
      required: [id, title, completed]
      properties:
        id: { type: string, format: uuid }
        title: { type: string }
        completed: { type: boolean }
        dueDate: { type: ["string", "null"], format: date }
    TodoCreate:
      type: object
      required: [title]
      properties:
        title: { type: string, minLength: 1, maxLength: 255 }
        completed: { type: boolean, default: false }
        dueDate: { type: ["string", "null"], format: date }
  securitySchemes:
    BearerAuth: { type: http, scheme: bearer }
security: [{ BearerAuth: [] }]
```

### Example 2: Add OAuth2 + webhook

**Input:** "Add OAuth2 with read/write scopes and a webhook for item updates"

**Output:**

```yaml
# Add to components.securitySchemes:
OAuth2:
  type: oauth2
  flows:
    authorizationCode:
      authorizationUrl: https://auth.example.com/authorize
      tokenUrl: https://auth.example.com/token
      scopes: { read:todos: Read todos, write:todos: Create and modify todos }
# Top-level security: [{ OAuth2: [read:todos] }]
# Per-operation: paths./todos.post.security: [{ OAuth2: [write:todos] }]

# Add to top-level webhooks:
webhooks:
  todoUpdated:
    post:
      operationId: onTodoUpdated
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                event: { type: string, enum: [created, updated, deleted] }
                todo: { $ref: '#/components/schemas/Todo' }
      responses: { '200': { description: Acknowledged } }
```

### Example 3: Validate and generate client

**Input:** "Lint my spec then generate a TypeScript client"

**Output:**

```bash
spectral lint openapi.yaml                                    # 1. Lint
npx @redocly/cli bundle openapi.yaml -o bundled.yaml          # 2. Bundle $refs
openapi-generator-cli generate -i bundled.yaml \
  -g typescript-axios -o ./src/api-client \
  --additional-properties=supportsES6=true                    # 3. Generate
cd ./src/api-client && npm install                            # 4. Install
```

## Quick Reference: Common Patterns

- **Pagination:** Use `query` params `page`/`pageSize` or `cursor`; return `Link` header or `nextCursor` in body
- **Error responses:** Reuse `components/responses` with RFC 7807 Problem Details schema
- **File upload:** `requestBody.content.multipart/form-data` with `type: string, contentMediaType: application/octet-stream`
- **Versioning:** Use `servers[].url` path prefix (`/v1`) or `header` parameter
- **Polymorphism:** Prefer `oneOf` + `discriminator` over untyped objects
- **Spec splitting:** Use `$ref: './schemas/User.yaml'` for large specs; bundle before publishing
