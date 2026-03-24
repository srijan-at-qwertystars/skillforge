# OpenAPI Troubleshooting Guide

## Table of Contents

- [Spec Validation Errors](#spec-validation-errors)
  - [Structural Validation Errors](#structural-validation-errors)
  - [Semantic Validation Errors](#semantic-validation-errors)
  - [Common Spectral Rule Violations](#common-spectral-rule-violations)
- [Code Generation Gotchas](#code-generation-gotchas)
  - [Missing operationId](#missing-operationid)
  - [Inconsistent Naming](#inconsistent-naming)
  - [Schema Composition Problems](#schema-composition-problems)
  - [Generator-Specific Issues](#generator-specific-issues)
- [Breaking vs Non-Breaking Changes](#breaking-vs-non-breaking-changes)
  - [Non-Breaking Changes (Safe)](#non-breaking-changes-safe)
  - [Breaking Changes (Dangerous)](#breaking-changes-dangerous)
  - [Detecting Breaking Changes](#detecting-breaking-changes)
- [Migration: Swagger 2.0 to OpenAPI 3.x](#migration-swagger-20-to-openapi-3x)
  - [Key Structural Differences](#key-structural-differences)
  - [Migration Checklist](#migration-checklist)
  - [Common Migration Pitfalls](#common-migration-pitfalls)
  - [Automated Migration Tools](#automated-migration-tools)
- [Security Scheme Misconfigurations](#security-scheme-misconfigurations)
  - [Common Security Mistakes](#common-security-mistakes)
  - [OAuth2 Configuration Issues](#oauth2-configuration-issues)
  - [Security Override Patterns](#security-override-patterns)
- [$ref Resolution Problems](#ref-resolution-problems)
  - [Common $ref Errors](#common-ref-errors)
  - [Sibling Properties with $ref](#sibling-properties-with-ref)
  - [External $ref Files](#external-ref-files)
  - [Circular $ref Handling](#circular-ref-handling)
- [Nullable vs Required Confusion](#nullable-vs-required-confusion)
  - [OpenAPI 3.0 (nullable keyword)](#openapi-30-nullable-keyword)
  - [OpenAPI 3.1 (JSON Schema type arrays)](#openapi-31-json-schema-type-arrays)
  - [Required vs Optional vs Nullable Matrix](#required-vs-optional-vs-nullable-matrix)
  - [Common Mistakes](#common-mistakes)
- [additionalProperties Pitfalls](#additionalproperties-pitfalls)
  - [Default Behavior](#default-behavior)
  - [Strict vs Permissive Schemas](#strict-vs-permissive-schemas)
  - [Code Generation Impact](#code-generation-impact)
  - [Common Patterns](#common-patterns)
- [Response Content Type Issues](#response-content-type-issues)
- [Parameter Serialization Issues](#parameter-serialization-issues)
- [YAML Syntax Gotchas](#yaml-syntax-gotchas)

---

## Spec Validation Errors

### Structural Validation Errors

**Missing required fields:**

```yaml
# ❌ ERROR: Missing 'info' and 'paths' (required at root)
openapi: "3.1.0"
# No info object
# No paths object

# ✅ FIX:
openapi: "3.1.0"
info:
  title: My API
  version: "1.0.0"
paths: {}
```

**Invalid version string:**

```yaml
# ❌ ERROR: openapi must be a string
openapi: 3.1.0  # YAML interprets this as a float (3.1)

# ✅ FIX: Always quote the version
openapi: "3.1.0"
```

**Path parameters not declared:**

```yaml
# ❌ ERROR: Path parameter 'userId' not found in path template
paths:
  /users/{userId}:
    get:
      parameters: []  # userId not declared
      responses:
        "200": { description: OK }

# ✅ FIX: Declare all path template variables
paths:
  /users/{userId}:
    get:
      parameters:
        - name: userId
          in: path
          required: true
          schema: { type: string }
      responses:
        "200": { description: OK }
```

**Path parameter not marked required:**

```yaml
# ❌ ERROR: Path parameters MUST have 'required: true'
- name: userId
  in: path
  schema: { type: string }

# ✅ FIX:
- name: userId
  in: path
  required: true  # Mandatory for path params
  schema: { type: string }
```

**Missing response for operation:**

```yaml
# ❌ ERROR: Operation must have at least one response
paths:
  /health:
    get:
      summary: Health check

# ✅ FIX:
paths:
  /health:
    get:
      summary: Health check
      responses:
        "200": { description: Healthy }
```

### Semantic Validation Errors

**Duplicate operationId:**

```yaml
# ❌ ERROR: operationId must be unique across all operations
paths:
  /users:
    get:
      operationId: getUser     # duplicate!
  /users/{id}:
    get:
      operationId: getUser     # duplicate!

# ✅ FIX: Use unique, descriptive operationIds
paths:
  /users:
    get:
      operationId: listUsers
  /users/{id}:
    get:
      operationId: getUserById
```

**Invalid $ref target:**

```yaml
# ❌ ERROR: $ref target not found
schema:
  $ref: "#/components/schemas/Usr"  # Typo in schema name

# ✅ FIX: Verify the target exists
schema:
  $ref: "#/components/schemas/User"
```

**Unused components warning:**

```yaml
# ⚠️ WARNING: Schema 'LegacyUser' is defined but never referenced
# Not an error, but indicates dead code
# Remove unused schemas to keep the spec clean
```

### Common Spectral Rule Violations

| Rule | Description | Fix |
|------|-------------|-----|
| `oas3-api-servers` | No servers defined | Add at least one `servers` entry |
| `operation-operationId` | Missing operationId | Add unique operationId to every operation |
| `operation-description` | No operation description | Add `description` or `summary` |
| `oas3-valid-media-example` | Example doesn't match schema | Fix example to match schema types |
| `no-$ref-siblings` | Properties alongside $ref | Move sibling props into allOf (3.0) |
| `oas3-unused-component` | Unused schema/parameter | Remove or reference the component |
| `path-keys-no-trailing-slash` | Path ends with / | Remove trailing slash |
| `info-contact` | Missing contact info | Add `info.contact` object |

---

## Code Generation Gotchas

### Missing operationId

Without `operationId`, generators create method names from the path and HTTP method, leading to ugly or conflicting names.

```yaml
# ❌ Generated method: getUsersUserIdOrders (confusing)
paths:
  /users/{userId}/orders:
    get:
      # no operationId

# ✅ Clean generated method: listUserOrders
paths:
  /users/{userId}/orders:
    get:
      operationId: listUserOrders
```

**Convention:** Use camelCase verbs: `listUsers`, `getUserById`, `createOrder`, `updateUser`, `deleteUser`.

### Inconsistent Naming

```yaml
# ❌ Mixed naming styles break generated code
components:
  schemas:
    user-response:      # kebab-case
    UserRequest:        # PascalCase
    create_user_input:  # snake_case

# ✅ Pick one convention (PascalCase for schemas is standard)
components:
  schemas:
    UserResponse:
    UserRequest:
    CreateUserInput:
```

### Schema Composition Problems

**allOf with conflicting required fields:**

```yaml
# ❌ PROBLEM: Both schemas define 'name' with different constraints
AllOf:
  allOf:
    - type: object
      properties:
        name: { type: string, maxLength: 50 }
    - type: object
      properties:
        name: { type: string, maxLength: 100 }
# Generators may pick either constraint or fail

# ✅ FIX: Use a single definition, extend via allOf only for new fields
```

**oneOf without discriminator:**

```yaml
# ❌ PROBLEM: Generator can't determine which type to deserialize
Response:
  oneOf:
    - $ref: "#/components/schemas/Cat"
    - $ref: "#/components/schemas/Dog"
  # No discriminator — runtime ambiguity

# ✅ FIX: Add a discriminator
Response:
  oneOf:
    - $ref: "#/components/schemas/Cat"
    - $ref: "#/components/schemas/Dog"
  discriminator:
    propertyName: petType
    mapping:
      cat: "#/components/schemas/Cat"
      dog: "#/components/schemas/Dog"
```

### Generator-Specific Issues

**TypeScript/JavaScript:**
- `enum` with numeric strings: `enum: ["1", "2"]` may generate numeric constants
- Deeply nested `allOf` creates complex intersection types
- `additionalProperties: true` creates `Record<string, unknown>` catch-all

**Python:**
- Snake_case conversion from camelCase properties may cause collisions
- `date-time` format generates `datetime` — ensure proper import
- Pydantic v1 vs v2 differences in generated validators

**Java:**
- `oneOf` without discriminator may generate wrapper classes with `isX()` methods
- BigDecimal vs Double for `number` type depends on generator config
- `readOnly`/`writeOnly` may not generate separate request/response classes

**Go:**
- Pointer types for optional fields can be cumbersome
- Embedded structs from `allOf` may have field name conflicts
- `interface{}` for `anyOf` makes type assertions necessary

---

## Breaking vs Non-Breaking Changes

### Non-Breaking Changes (Safe)

These changes are backward-compatible for existing clients:

```yaml
# ✅ SAFE: Adding a new optional field to a response
User:
  properties:
    name: { type: string }
    avatarUrl: { type: string }  # NEW — clients ignore unknown fields

# ✅ SAFE: Adding a new optional query parameter
parameters:
  - name: includeDeleted  # NEW
    in: query
    schema: { type: boolean, default: false }

# ✅ SAFE: Adding a new endpoint
paths:
  /users/{id}/preferences:  # NEW endpoint
    get: ...

# ✅ SAFE: Adding a new enum value to a response field
# (Clients should handle unknown values gracefully)
role:
  type: string
  enum: [admin, editor, viewer, moderator]  # 'moderator' added

# ✅ SAFE: Widening a numeric range
age:
  type: integer
  minimum: 0
  maximum: 200  # Was 150, now 200 — accepts more values

# ✅ SAFE: Making a required request field optional
# (Old clients still send it; new clients don't have to)

# ✅ SAFE: Adding a new response content type
content:
  application/json: { schema: ... }
  application/xml: { schema: ... }  # NEW — clients request via Accept header

# ✅ SAFE: Deprecating (not removing) an endpoint or field
deprecated: true
```

### Breaking Changes (Dangerous)

These changes will break existing clients:

```yaml
# ❌ BREAKING: Removing a field from a response
User:
  properties:
    name: { type: string }
    # 'email' was here — clients depending on it will fail

# ❌ BREAKING: Renaming a field
User:
  properties:
    fullName: { type: string }  # Was 'name' — clients look for 'name'

# ❌ BREAKING: Adding a new required field to a request body
CreateUser:
  required: [name, email, phone]  # 'phone' added — old clients don't send it

# ❌ BREAKING: Removing an endpoint
# /users/{id}/avatar  — was here, now gone

# ❌ BREAKING: Changing a field type
age:
  type: string  # Was integer — clients sending integers will fail

# ❌ BREAKING: Removing an enum value from a request field
status:
  enum: [active, inactive]  # 'pending' removed — clients sending 'pending' get 400

# ❌ BREAKING: Narrowing a numeric range on a request field
age:
  minimum: 18  # Was 0 — clients sending age < 18 now get validation errors

# ❌ BREAKING: Changing a URL path
/api/users → /api/v2/members  # Clients using old URL get 404

# ❌ BREAKING: Making authentication required on a previously public endpoint
security:
  - bearerAuth: []  # Was security: [] (public)
```

### Detecting Breaking Changes

Use automated tools in CI:

```bash
# oasdiff — purpose-built for OpenAPI diff
oasdiff breaking old-spec.yaml new-spec.yaml

# openapi-diff
openapi-diff old-spec.yaml new-spec.yaml --fail-on-incompatible

# optic
optic diff old-spec.yaml new-spec.yaml
```

---

## Migration: Swagger 2.0 to OpenAPI 3.x

### Key Structural Differences

| Swagger 2.0 | OpenAPI 3.0/3.1 |
|-------------|-----------------|
| `swagger: "2.0"` | `openapi: "3.0.3"` / `"3.1.0"` |
| `host`, `basePath`, `schemes` | `servers` array with URL templates |
| `definitions` | `components/schemas` |
| `parameters` (top-level) | `components/parameters` |
| `responses` (top-level) | `components/responses` |
| `securityDefinitions` | `components/securitySchemes` |
| `produces`, `consumes` | Per-operation `content` in request/response |
| `body` parameter | `requestBody` object |
| `formData` parameter | `requestBody` with `multipart/form-data` |
| File upload via `type: file` | `type: string, format: binary` |

### Migration Checklist

**1. Root-level changes:**

```yaml
# BEFORE (Swagger 2.0)
swagger: "2.0"
host: api.example.com
basePath: /v1
schemes: [https]
consumes: [application/json]
produces: [application/json]

# AFTER (OpenAPI 3.0)
openapi: "3.0.3"
servers:
  - url: https://api.example.com/v1
```

**2. Request bodies:**

```yaml
# BEFORE: body parameter
parameters:
  - name: user
    in: body
    schema:
      $ref: "#/definitions/User"

# AFTER: requestBody
requestBody:
  required: true
  content:
    application/json:
      schema:
        $ref: "#/components/schemas/User"
```

**3. Form data:**

```yaml
# BEFORE: formData parameters
parameters:
  - name: name
    in: formData
    type: string
  - name: avatar
    in: formData
    type: file

# AFTER: requestBody with multipart
requestBody:
  content:
    multipart/form-data:
      schema:
        type: object
        properties:
          name: { type: string }
          avatar: { type: string, format: binary }
```

**4. Responses with content:**

```yaml
# BEFORE: schema directly in response
responses:
  200:
    description: OK
    schema:
      $ref: "#/definitions/User"

# AFTER: content wrapper
responses:
  "200":
    description: OK
    content:
      application/json:
        schema:
          $ref: "#/components/schemas/User"
```

**5. Security definitions:**

```yaml
# BEFORE
securityDefinitions:
  api_key:
    type: apiKey
    name: X-API-Key
    in: header

# AFTER
components:
  securitySchemes:
    api_key:
      type: apiKey
      name: X-API-Key
      in: header
```

**6. Component $ref paths:**

```yaml
# BEFORE
$ref: "#/definitions/User"
$ref: "#/parameters/UserId"

# AFTER
$ref: "#/components/schemas/User"
$ref: "#/components/parameters/UserId"
```

### Common Migration Pitfalls

1. **Forgetting to update $ref paths** — all `#/definitions/X` must become `#/components/schemas/X`
2. **Response status codes must be strings** in YAML: `"200"` not `200`
3. **`type: file` no longer exists** — use `type: string, format: binary`
4. **Global `produces`/`consumes` removed** — set content types per-operation
5. **`body` and `formData` parameters eliminated** — use `requestBody`
6. **`allowEmptyValue` deprecated** — rethink empty parameter handling
7. **`collectionFormat` replaced** by `style` and `explode` on parameters

### Automated Migration Tools

```bash
# swagger2openapi (Node.js)
npx swagger2openapi swagger.yaml -o openapi.yaml

# api-spec-converter
npx api-spec-converter --from=swagger_2 --to=openapi_3 --syntax=yaml swagger.yaml > openapi.yaml

# Redocly CLI
redocly bundle swagger.yaml --dereferenced -o openapi.yaml
```

Always validate the output after automated conversion.

---

## Security Scheme Misconfigurations

### Common Security Mistakes

**1. Defining schemes but not applying them:**

```yaml
# ❌ Security scheme defined but never used
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
# No 'security' at root or on any operation

# ✅ FIX: Apply globally or per-operation
security:
  - bearerAuth: []
```

**2. Wrong security scope format:**

```yaml
# ❌ ERROR: Scopes must be an array, even if empty
security:
  - oauth2: "read:users"

# ✅ FIX:
security:
  - oauth2: ["read:users", "write:users"]
  - bearerAuth: []  # No scopes → empty array
```

**3. Forgetting to make public endpoints public:**

```yaml
# With global security, ALL endpoints require auth unless overridden
security:
  - bearerAuth: []

paths:
  /health:
    get:
      # ❌ This inherits global security — health check requires auth!
      responses:
        "200": { description: OK }

  /docs:
    get:
      # ✅ Override with empty security for public endpoints
      security: []
      responses:
        "200": { description: API docs }
```

**4. AND vs OR in security requirements:**

```yaml
# OR logic — client needs apiKey OR bearerAuth (separate items)
security:
  - apiKey: []
  - bearerAuth: []

# AND logic — client needs BOTH apiKey AND bearerAuth (same item)
security:
  - apiKey: []
    bearerAuth: []
```

### OAuth2 Configuration Issues

```yaml
# ❌ Missing required URLs for authorization code flow
oauth2:
  type: oauth2
  flows:
    authorizationCode:
      # authorizationUrl: MISSING — required!
      tokenUrl: https://auth.example.com/token
      scopes: {}

# ✅ All required URLs present
oauth2:
  type: oauth2
  flows:
    authorizationCode:
      authorizationUrl: https://auth.example.com/authorize
      tokenUrl: https://auth.example.com/token
      refreshUrl: https://auth.example.com/refresh  # optional but recommended
      scopes:
        "users:read": Read user data
        "users:write": Modify user data
```

### Security Override Patterns

```yaml
# Global default: bearer auth required
security:
  - bearerAuth: []

paths:
  # Public endpoint (no auth)
  /public/status:
    get:
      security: []

  # Stricter: requires both API key AND bearer token
  /admin/settings:
    put:
      security:
        - apiKey: []
          bearerAuth: []

  # Flexible: accepts either method
  /data:
    get:
      security:
        - bearerAuth: []
        - apiKey: []

  # OAuth with specific scopes
  /users:
    delete:
      security:
        - oauth2: [admin, "users:delete"]
```

---

## $ref Resolution Problems

### Common $ref Errors

**1. Wrong JSON Pointer path:**

```yaml
# ❌ ERROR: 'definitions' is Swagger 2.0; OpenAPI 3.x uses 'components/schemas'
$ref: "#/definitions/User"

# ✅ FIX:
$ref: "#/components/schemas/User"
```

**2. Typos in schema names:**

```yaml
# ❌ ERROR: Case-sensitive — 'user' ≠ 'User'
$ref: "#/components/schemas/user"

# ✅ FIX: Match exact casing
$ref: "#/components/schemas/User"
```

**3. Missing hash for local references:**

```yaml
# ❌ ERROR: Local refs must start with #
$ref: "components/schemas/User"

# ✅ FIX:
$ref: "#/components/schemas/User"
```

**4. $ref to non-existent component:**

```yaml
# ❌ ERROR: Schema 'UserProfile' doesn't exist in components
$ref: "#/components/schemas/UserProfile"

# ✅ FIX: Define it first, then reference it
components:
  schemas:
    UserProfile:
      type: object
      properties:
        bio: { type: string }
```

### Sibling Properties with $ref

In OpenAPI 3.0, properties alongside `$ref` are ignored. This is a major gotcha.

```yaml
# ❌ In OpenAPI 3.0: 'description' and 'required' are IGNORED
schema:
  $ref: "#/components/schemas/User"
  description: "This description is ignored in 3.0!"

# ✅ FIX for 3.0: Use allOf wrapper
schema:
  allOf:
    - $ref: "#/components/schemas/User"
  description: "Now this description works"

# ✅ In OpenAPI 3.1: Sibling properties ARE allowed (JSON Schema compatible)
# But some tools may still not support this
schema:
  $ref: "#/components/schemas/User"
  description: "Works in 3.1"
```

### External $ref Files

```yaml
# Reference schema in external file
$ref: "./schemas/user.yaml"

# Reference specific component in external file
$ref: "./schemas/user.yaml#/User"

# Reference from URL (some tools support this)
$ref: "https://api.example.com/schemas/common.yaml#/components/schemas/Error"

# Directory structure for multi-file specs:
# openapi/
# ├── openapi.yaml          (root document)
# ├── paths/
# │   ├── users.yaml
# │   └── orders.yaml
# ├── schemas/
# │   ├── user.yaml
# │   └── order.yaml
# └── parameters/
#     └── common.yaml
```

**Bundling external refs for tools that don't support them:**

```bash
# Use redocly to bundle into a single file
redocly bundle openapi.yaml -o bundled.yaml

# Or swagger-cli
swagger-cli bundle openapi.yaml -o bundled.yaml -t yaml
```

### Circular $ref Handling

```yaml
# Circular reference — valid but may cause issues
Employee:
  type: object
  properties:
    name: { type: string }
    manager:
      $ref: "#/components/schemas/Employee"  # circular!

# Tools handle this differently:
# - Validators: Usually accept circular refs
# - Swagger UI: Renders with depth limit
# - Code generators: May fail or generate infinite types
# - JSON Schema validators: Handle lazily

# MITIGATION: Make circular properties optional or nullable
Employee:
  type: object
  required: [name]
  properties:
    name: { type: string }
    manager:
      oneOf:
        - $ref: "#/components/schemas/Employee"
        - type: "null"  # OpenAPI 3.1
```

---

## Nullable vs Required Confusion

### OpenAPI 3.0 (nullable keyword)

```yaml
# OpenAPI 3.0: Use the nullable keyword
properties:
  middleName:
    type: string
    nullable: true    # Value can be null or a string

  # NOT the same as omitting 'required':
  # - nullable: true → field can be present with value null
  # - not in required → field can be absent entirely
  # - both → field can be absent OR present with null OR present with string
```

### OpenAPI 3.1 (JSON Schema type arrays)

```yaml
# OpenAPI 3.1: Use JSON Schema type arrays (nullable keyword removed)
properties:
  middleName:
    type: ["string", "null"]    # Value can be null or a string

  # For $ref types:
  manager:
    oneOf:
      - $ref: "#/components/schemas/Employee"
      - type: "null"
```

### Required vs Optional vs Nullable Matrix

| `required` | `nullable` | Absent OK? | `null` OK? | Must have value? |
|-----------|-----------|-----------|-----------|-----------------|
| Yes | No | ❌ | ❌ | ✅ |
| Yes | Yes | ❌ | ✅ | ❌ |
| No | No | ✅ | ❌ | Only if present |
| No | Yes | ✅ | ✅ | ❌ |

### Common Mistakes

```yaml
# ❌ MISTAKE: Confusing nullable with optional
# This field is required AND nullable — it MUST be present, but can be null
required: [name, middleName]
properties:
  name: { type: string }
  middleName:
    type: string
    nullable: true  # Required but can be null

# ❌ MISTAKE: Using nullable on a $ref in 3.0
# This does NOT work in 3.0 (nullable is ignored on $ref)
address:
  $ref: "#/components/schemas/Address"
  nullable: true  # IGNORED in 3.0!

# ✅ FIX for nullable $ref in 3.0:
address:
  allOf:
    - $ref: "#/components/schemas/Address"
  nullable: true

# ✅ FIX in 3.1:
address:
  oneOf:
    - $ref: "#/components/schemas/Address"
    - type: "null"

# ❌ MISTAKE: Thinking 'default: null' implies nullable
age:
  type: integer
  default: null  # ERROR: null is not a valid integer

# ✅ FIX:
age:
  type: integer
  nullable: true  # 3.0
  default: null
```

---

## additionalProperties Pitfalls

### Default Behavior

```yaml
# When additionalProperties is NOT specified:
# - JSON Schema default: true (any extra properties allowed)
# - Some code generators assume: false (strict mode)
# - Behavior varies by tool!

User:
  type: object
  properties:
    name: { type: string }
  # additionalProperties not specified — ambiguous!
```

### Strict vs Permissive Schemas

```yaml
# STRICT: Only declared properties allowed
UserStrict:
  type: object
  properties:
    name: { type: string }
    email: { type: string }
  additionalProperties: false
  # { "name": "Jo", "extra": 1 } → INVALID

# PERMISSIVE: Any extra properties with any type
UserPermissive:
  type: object
  properties:
    name: { type: string }
  additionalProperties: true
  # { "name": "Jo", "extra": 1, "anything": [1,2] } → VALID

# TYPED: Extra properties must be strings
UserWithMetadata:
  type: object
  properties:
    name: { type: string }
  additionalProperties:
    type: string
  # { "name": "Jo", "tag1": "val1", "tag2": "val2" } → VALID
  # { "name": "Jo", "count": 42 } → INVALID (42 not a string)
```

### Code Generation Impact

```yaml
# additionalProperties: false
# → Java: class with only declared fields
# → TypeScript: interface with exact properties
# → Python: Pydantic model with Config.extra = "forbid"

# additionalProperties: true
# → Java: class with Map<String, Object> for extras
# → TypeScript: interface with [key: string]: unknown
# → Python: Pydantic model with Config.extra = "allow"

# additionalProperties: { type: string }
# → Java: class with Map<String, String> for extras
# → TypeScript: interface with [key: string]: string
# → Python: Pydantic model with Dict[str, str] field
```

### Common Patterns

```yaml
# Free-form key-value metadata
metadata:
  type: object
  additionalProperties:
    type: string
  description: Arbitrary string key-value pairs
  example:
    env: production
    region: us-east-1

# Map of typed objects
usersByRegion:
  type: object
  additionalProperties:
    $ref: "#/components/schemas/UserList"

# Dictionary with constrained keys (3.1 + patternProperties)
headers:
  type: object
  patternProperties:
    "^X-Custom-":
      type: string
  additionalProperties: false
```

---

## Response Content Type Issues

```yaml
# ❌ PROBLEM: Response has no content type — what format is the body?
responses:
  "200":
    description: User data
    schema:  # This is Swagger 2.0 syntax!
      $ref: "#/components/schemas/User"

# ✅ FIX: Wrap in content with media type
responses:
  "200":
    description: User data
    content:
      application/json:
        schema:
          $ref: "#/components/schemas/User"

# ❌ PROBLEM: No-content responses with content
responses:
  "204":
    description: Deleted
    content:
      application/json:
        schema: { type: object }
  # 204 means NO content — don't define a body

# ✅ FIX:
responses:
  "204":
    description: Deleted
    # No content block
```

---

## Parameter Serialization Issues

```yaml
# ❌ PROBLEM: Array query parameter with default serialization
# Default: style=form, explode=true → ?id=1&id=2&id=3
# But some backends expect: ?id=1,2,3
- name: id
  in: query
  schema:
    type: array
    items: { type: integer }

# ✅ FIX: Specify style explicitly
- name: id
  in: query
  style: form
  explode: false  # → ?id=1,2,3
  schema:
    type: array
    items: { type: integer }

# Common serialization styles:
# Query params:
#   style: form, explode: true  → ?color=blue&color=black (default)
#   style: form, explode: false → ?color=blue,black
#   style: spaceDelimited      → ?color=blue%20black
#   style: pipeDelimited       → ?color=blue|black
#   style: deepObject          → ?color[r]=100&color[g]=200

# Path params:
#   style: simple (default)    → /users/1,2,3
#   style: label               → /users/.1.2.3
#   style: matrix              → /users/;id=1,2,3

# Header params:
#   style: simple (only option) → X-IDs: 1,2,3
```

---

## YAML Syntax Gotchas

```yaml
# ❌ GOTCHA: Unquoted values that YAML interprets as non-strings
on: true        # YAML boolean, not the string "on"
yes: true       # YAML boolean
no: false       # YAML boolean
off: false      # YAML boolean
null: null      # YAML null
1.0: 1.0        # YAML float
3.1.0: ???      # YAML... who knows

# ✅ FIX: Always quote values that should be strings
"on": "true"
openapi: "3.1.0"

# ❌ GOTCHA: Response codes as integers
responses:
  200:           # YAML treats this as integer 200
    description: OK

# ✅ FIX: Quote response codes
responses:
  "200":
    description: OK

# ❌ GOTCHA: Multiline strings
description: This is a long description
  that continues on the next line
  # YAML may or may not join these lines depending on indentation

# ✅ FIX: Use block scalar indicators
description: |
  This is a long description
  that preserves line breaks.

description: >
  This is a long description
  that folds into a single line.

# ❌ GOTCHA: Special characters in strings
pattern: ^[a-z]+$  # May cause YAML parsing issues

# ✅ FIX: Quote strings with special characters
pattern: '^[a-z]+$'

# ❌ GOTCHA: Anchors and aliases in OpenAPI
# YAML anchors (&anchor / *alias) are NOT part of OpenAPI
# Use $ref instead for reusability
```
