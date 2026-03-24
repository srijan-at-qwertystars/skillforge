# OpenAPI Troubleshooting Guide

## Table of Contents

- [Common Spec Errors](#common-spec-errors)
  - [Circular $ref](#circular-ref)
  - [Invalid Schema Definitions](#invalid-schema-definitions)
  - [Missing Required Fields](#missing-required-fields)
  - [3.0 vs 3.1 Incompatibilities](#30-vs-31-incompatibilities)
  - [$ref Sibling Properties Ignored](#ref-sibling-properties-ignored)
  - [Discriminator Misconfiguration](#discriminator-misconfiguration)
- [Validator Differences](#validator-differences)
  - [Spectral](#spectral)
  - [Redocly CLI](#redocly-cli)
  - [swagger-parser](#swagger-parser)
  - [Comparison Matrix](#validator-comparison-matrix)
  - [Getting Consistent Results](#getting-consistent-results)
- [Code Generator Quirks](#code-generator-quirks)
  - [General Issues](#general-issues)
  - [Java (openapi-generator)](#java-openapi-generator)
  - [TypeScript (openapi-generator)](#typescript-openapi-generator)
  - [Python (openapi-generator)](#python-openapi-generator)
  - [openapi-typescript](#openapi-typescript-quirks)
- [Swagger UI Rendering Issues](#swagger-ui-rendering-issues)
  - [Schema Not Displaying](#schema-not-displaying)
  - [Try-It-Out Failures](#try-it-out-failures)
  - [Deep Linking Not Working](#deep-linking-not-working)
  - [Large Spec Performance](#large-spec-performance)
  - [Authentication Not Persisting](#authentication-not-persisting)
- [CORS with Try-It-Out](#cors-with-try-it-out)
  - [Understanding the Problem](#understanding-the-problem)
  - [Server-Side CORS Configuration](#server-side-cors-configuration)
  - [Swagger UI CORS Workarounds](#swagger-ui-cors-workarounds)
- [Breaking Change Detection](#breaking-change-detection)
  - [What Constitutes a Breaking Change](#what-constitutes-a-breaking-change)
  - [Using oasdiff](#using-oasdiff)
  - [Using optic](#using-optic)
  - [CI Integration for Breaking Changes](#ci-integration-for-breaking-changes)

---

## Common Spec Errors

### Circular $ref

**Symptom:** Validators report "circular reference" or tools hang/crash during processing.

**Example of circular $ref:**

```yaml
components:
  schemas:
    TreeNode:
      type: object
      properties:
        value: { type: string }
        children:
          type: array
          items:
            $ref: '#/components/schemas/TreeNode'   # self-reference
```

**This is valid OpenAPI** — self-referencing schemas are allowed. The issue is usually with tooling, not the spec itself.

**Common causes of problems:**
1. **Unbounded circular refs** — A references B which references A without an array or nullable wrapper.
2. **Tool limitations** — Some code generators can't handle circular refs at all.

**Fixes:**

```yaml
# Fix 1: Break the cycle with nullable
Parent:
  type: object
  properties:
    child:
      oneOf:
        - $ref: '#/components/schemas/Child'
        - type: "null"

# Fix 2: Use maxDepth extension (generator-specific)
TreeNode:
  type: object
  properties:
    children:
      type: array
      items:
        $ref: '#/components/schemas/TreeNode'
      x-max-depth: 3

# Fix 3: Separate read model that stops recursion
TreeNodeFlat:
  type: object
  properties:
    value: { type: string }
    childIds:
      type: array
      items: { type: string, format: uuid }
```

**Tool-specific behavior:**
| Tool | Behavior |
|------|----------|
| Spectral | Handles circular refs; may warn |
| Redocly | Handles circular refs; validates correctly |
| swagger-parser | Can dereference with `circular: true` option |
| openapi-generator | Many generators fail; use `--skip-validate-spec` |
| Swagger UI | Renders with "Circular" label |

### Invalid Schema Definitions

**Problem 1: `type` must be a string (OAS 3.0) or string/array (OAS 3.1)**

```yaml
# WRONG in 3.0
property:
  type: [string, null]    # array type syntax is 3.1 only

# CORRECT in 3.0
property:
  type: string
  nullable: true

# CORRECT in 3.1
property:
  type: ["string", "null"]
```

**Problem 2: Invalid `format` values**

```yaml
# These are NOT standard formats (but may work with some tools):
property:
  type: string
  format: phone          # not standard; use pattern instead
  # Standard formats: date, date-time, password, byte, binary,
  #   email, hostname, ipv4, ipv6, uri, uuid, int32, int64, float, double
```

**Problem 3: `additionalProperties` confusion**

```yaml
# Boolean form — controls whether extra properties are allowed
strict:
  type: object
  properties:
    name: { type: string }
  additionalProperties: false    # no extra properties

# Schema form — defines the type of extra properties
flexible:
  type: object
  properties:
    name: { type: string }
  additionalProperties:          # extra properties must be strings
    type: string

# Omitted (default) — extra properties allowed with any type
```

**Problem 4: `required` at wrong level**

```yaml
# WRONG: required inside property
properties:
  name:
    type: string
    required: true         # This does NOT work in OpenAPI

# CORRECT: required is a sibling of properties
required: [name]
properties:
  name:
    type: string
```

### Missing Required Fields

**Minimum valid OpenAPI document (3.1):**

```yaml
openapi: "3.1.0"
info:
  title: My API      # REQUIRED
  version: "1.0.0"   # REQUIRED
paths: {}             # Optional in 3.1, required in 3.0
```

**Common missing fields:**

| Context | Required Field | Common Mistake |
|---------|---------------|----------------|
| Operation response | At least one response | Empty `responses: {}` |
| Path parameter | `required: true` | Omitting `required` (defaults to false) |
| Operation | None strictly, but `operationId` strongly recommended | Missing operationId breaks code gen |
| requestBody | `content` with at least one media type | Empty requestBody |
| Security scheme (oauth2) | `flows` with at least one flow type | Missing tokenUrl |
| Server | `url` | Empty servers array |

### 3.0 vs 3.1 Incompatibilities

| Feature | 3.0 | 3.1 |
|---------|-----|-----|
| Nullable | `nullable: true` | `type: ["string", "null"]` |
| Examples | `example` (singular) | `examples` (array, JSON Schema) |
| Exclusive min/max | `exclusiveMinimum: true` + `minimum: 0` | `exclusiveMinimum: 0` |
| File upload | `type: string, format: binary` | `contentMediaType: application/octet-stream` |
| JSON Schema | Subset | Full draft 2020-12 |
| Webhooks | Via `callbacks` only | Top-level `webhooks` |
| `paths` | Required | Optional |

**Migration tip:** Use `npx @redocly/cli lint --extends minimal openapi.yaml` to detect version-specific issues.

### $ref Sibling Properties Ignored

In OpenAPI 3.0, any properties alongside `$ref` are **silently ignored**:

```yaml
# 3.0: description is IGNORED
property:
  $ref: '#/components/schemas/User'
  description: This will not appear   # silently dropped

# Fix for 3.0: wrap in allOf
property:
  allOf:
    - $ref: '#/components/schemas/User'
  description: This description works now

# 3.1: sibling properties ARE allowed (per JSON Schema)
property:
  $ref: '#/components/schemas/User'
  description: This works in 3.1     # honored
```

### Discriminator Misconfiguration

**Problem 1: Discriminator property missing from schema**

```yaml
# WRONG: petType is not in Cat's properties
Pet:
  oneOf:
    - $ref: '#/components/schemas/Cat'
  discriminator:
    propertyName: petType
Cat:
  type: object
  properties:
    name: { type: string }
    # missing petType property!

# FIX: Add petType to Cat
Cat:
  type: object
  required: [petType]
  properties:
    petType: { type: string }
    name: { type: string }
```

**Problem 2: Mapping values don't match schema names**

```yaml
# WRONG: mapping key doesn't match any known value
discriminator:
  propertyName: type
  mapping:
    cat: '#/components/schemas/CatModel'    # if CatModel doesn't exist → error
```

**Problem 3: Using discriminator with allOf incorrectly**

The discriminator must be on the parent schema (with `oneOf`/`anyOf`), not on child schemas.

---

## Validator Differences

### Spectral

**Strengths:** Highly customizable rules, style guide enforcement, extensible with custom functions.

**Common issues:**

```bash
# Spectral may report issues other tools don't:
spectral lint openapi.yaml
# ⚠ operation-description — Operation "getUser" must have a description
# This is a STYLE rule, not a spec validity error
```

**Configuring strictness:**

```yaml
# .spectral.yaml — disable style rules, keep validity rules
extends: ["spectral:oas"]
rules:
  operation-description: off
  operation-tags: off
  info-description: off
  info-contact: off
  oas3-api-servers: off
```

**Custom function gotcha:**

```yaml
# Custom functions must be CommonJS (.js), not ESM
# Place in ./functions/ directory
rules:
  custom-rule:
    given: "$.paths"
    then:
      function: myCustomFunction   # must be ./functions/myCustomFunction.js
```

### Redocly CLI

**Strengths:** Bundling, splitting, preview server, configurable rule sets.

**Common issues:**

```bash
# Redocly uses different severity names than Spectral
# Redocly: error, warn, off
# Spectral: error, warn, info, hint, off

# Redocly may not catch issues Spectral does and vice versa
npx @redocly/cli lint openapi.yaml --extends recommended
```

**Configuration:**

```yaml
# redocly.yaml
extends:
  - recommended
rules:
  operation-operationId: error
  no-path-trailing-slash: error
  path-segment-plural: warn
  # Redocly-specific rules:
  no-unused-components: warn
  no-ambiguous-paths: error
```

### swagger-parser

**Strengths:** Programmatic validation in JavaScript/TypeScript, dereferencing, bundling.

**Common issues:**

```javascript
const SwaggerParser = require('@apidevtools/swagger-parser');

// swagger-parser validates structure, not style
try {
  const api = await SwaggerParser.validate('openapi.yaml');
  // Only catches structural/schema errors
  // Does NOT check operationId uniqueness in all cases
  // Does NOT enforce style rules
} catch (err) {
  console.error(err.message);
  // Common: "Token "}" must be percent-encoded" — path parameter formatting
  // Common: "can't resolve reference" — broken $ref
}

// Dereferencing with circular ref support
const api = await SwaggerParser.dereference('openapi.yaml', {
  dereference: { circular: 'ignore' }  // or 'true' to allow
});
```

### Validator Comparison Matrix

| Feature | Spectral | Redocly | swagger-parser |
|---------|----------|---------|----------------|
| OAS 2.0 (Swagger) | ✅ | ✅ | ✅ |
| OAS 3.0 | ✅ | ✅ | ✅ |
| OAS 3.1 | ✅ | ✅ | ⚠️ Partial |
| Custom rules | ✅ Rich | ✅ Plugin-based | ❌ |
| Style enforcement | ✅ | ✅ | ❌ |
| Bundling | ❌ | ✅ | ✅ |
| Dereferencing | ❌ | ✅ | ✅ |
| CI-friendly | ✅ | ✅ | ✅ (programmatic) |
| IDE integration | VS Code | VS Code | N/A |
| Performance (large specs) | Good | Excellent | Good |
| JSON Schema validation | Draft 4/7 | Draft 2020-12 | Draft 4 |

### Getting Consistent Results

Run multiple validators in CI to catch different categories of issues:

```bash
#!/bin/bash
set -e

echo "=== Structural validation ==="
npx @apidevtools/swagger-cli validate openapi.yaml

echo "=== Style and best practices ==="
spectral lint openapi.yaml --fail-severity warn

echo "=== Redocly recommended rules ==="
npx @redocly/cli lint openapi.yaml --extends recommended
```

---

## Code Generator Quirks

### General Issues

**Problem: Generated code doesn't compile**

Common causes:
1. **Reserved words** — Property names like `class`, `type`, `default` conflict with language keywords.
2. **Missing operationId** — Generators create unreadable method names.
3. **Circular $ref** — Many generators don't handle these.
4. **oneOf/anyOf without discriminator** — Generates overly complex union types.

**Fix reserved words:**

```yaml
properties:
  class:
    type: string
    x-field-extra-annotation: '@JsonProperty("class")'  # Java
    # Or rename via generator mapping:
    # --type-mappings class=ClassField
```

**Fix missing operationId:**

```yaml
# BAD: No operationId → generator creates "pathsUsersGet"
/users:
  get:
    responses: { '200': { description: OK } }

# GOOD: Meaningful operationId
/users:
  get:
    operationId: listUsers
    responses: { '200': { description: OK } }
```

### Java (openapi-generator)

**Problem 1: BigDecimal for `number` type**

```yaml
# This generates BigDecimal in Java, which may not serialize well
price:
  type: number
  format: double    # Add format to get Double instead of BigDecimal
```

**Problem 2: Date/time handling**

```yaml
# Java 8+: generates OffsetDateTime by default
createdAt:
  type: string
  format: date-time
# To use LocalDateTime instead:
# --type-mappings=DateTime=java.time.LocalDateTime
```

**Problem 3: Lombok vs getters/setters**

```bash
# Use Lombok annotations to reduce boilerplate
openapi-generator-cli generate -i openapi.yaml -g java \
  --additional-properties=additionalModelTypeAnnotations='@lombok.Data @lombok.Builder'
```

**Problem 4: allOf generates incorrect inheritance**

```bash
# Default behavior creates intermediate classes
# Use --additional-properties to control:
openapi-generator-cli generate -i openapi.yaml -g java \
  --additional-properties=useOneOfInterfaces=true
```

### TypeScript (openapi-generator)

**Problem 1: Enum generation**

```yaml
# Generates string literal union in some generators, enum in others
status:
  type: string
  enum: [active, inactive]
# typescript-axios: generates enum (StatusEnum)
# typescript-fetch: generates string union
# openapi-typescript: generates string union type
```

**Problem 2: Optional vs required fields**

```yaml
# If 'required' array is omitted, ALL properties become optional
User:
  type: object
  # Missing: required: [id, name]
  properties:
    id: { type: string }     # generated as id?: string instead of id: string
    name: { type: string }
```

**Problem 3: Date types**

```yaml
createdAt:
  type: string
  format: date-time
# typescript-axios: generates as string (not Date)
# To get Date objects, use --type-mappings=DateTime=Date
# But then serialization requires manual handling
```

**Problem 4: Namespace conflicts**

```bash
# If schema names conflict with TypeScript builtins:
# Schema named "Error" conflicts with global Error
# Fix: use x-class-name or --model-name-mappings
openapi-generator-cli generate -i openapi.yaml -g typescript-axios \
  --model-name-mappings Error=ApiError
```

### Python (openapi-generator)

**Problem 1: Pydantic v1 vs v2**

```bash
# Default may generate Pydantic v1 models
# For Pydantic v2:
openapi-generator-cli generate -i openapi.yaml -g python \
  --additional-properties=pydanticV2=true
```

**Problem 2: Snake_case conversion**

```yaml
# JSON camelCase → Python snake_case conversion
# Sometimes breaks with acronyms:
myHTTPClient:    # → my_h_t_t_p_client (wrong)
# Fix: use x-field-name or alias
myHTTPClient:
  type: string
  x-field-name: my_http_client
```

**Problem 3: Circular model imports**

```python
# Generated code may have circular imports
# from .parent import Parent  (in child.py)
# from .child import Child    (in parent.py)
# Fix: Use TYPE_CHECKING pattern or --global-properties=modelDocs=false
```

**Problem 4: FastAPI server stubs**

```bash
# FastAPI generator creates basic stubs
openapi-generator-cli generate -i openapi.yaml -g python-fastapi \
  -o server/
# Known issues:
# - Doesn't generate proper dependency injection
# - Security schemes need manual wiring
# - File uploads need manual handling
# Better alternative: write FastAPI code-first and auto-generate the spec
```

### openapi-typescript Quirks

```bash
# openapi-typescript generates type-only output (no runtime code)
npx openapi-typescript openapi.yaml -o types.ts
```

**Known issues:**
- `additionalProperties: true` generates `Record<string, unknown>` — may lose type safety.
- `oneOf` without discriminator generates a union type that can be hard to narrow.
- Deeply nested `$ref` chains can produce very long type names.
- `readOnly`/`writeOnly` fields are included in all types (no separate input/output types by default).

---

## Swagger UI Rendering Issues

### Schema Not Displaying

**Problem:** Schema section shows "No schema" or is empty.

**Causes:**
1. **Broken `$ref`:** The referenced schema doesn't exist or path is wrong.
2. **Circular reference:** Very deep circular refs may not render.
3. **Missing `content` in response:** Response has no media type defined.

```yaml
# WRONG: No content
responses:
  '200':
    description: Success
    # Missing content → schema won't show

# CORRECT:
responses:
  '200':
    description: Success
    content:
      application/json:
        schema:
          $ref: '#/components/schemas/User'
```

### Try-It-Out Failures

**Problem:** "Try it out" button sends request but gets error.

**Causes and fixes:**
1. **CORS** — See [CORS section](#cors-with-try-it-out) below.
2. **Wrong server URL** — Swagger UI uses `servers[0].url` by default.
3. **Missing security** — Token not configured in Authorize dialog.

```yaml
# Ensure the first server is accessible from the browser
servers:
  - url: http://localhost:3000/api   # development
  - url: https://api.example.com     # production
```

4. **Path parameter not in URL:** Make sure path parameter names match exactly.

```yaml
# WRONG: Parameter name mismatch
/users/{user_id}:     # underscore
  get:
    parameters:
      - name: userId   # camelCase — doesn't match path!
        in: path

# CORRECT: Must match exactly
/users/{userId}:
  get:
    parameters:
      - name: userId
        in: path
```

### Deep Linking Not Working

```javascript
// Enable deep linking in Swagger UI config
SwaggerUIBundle({
  url: "/openapi.yaml",
  dom_id: '#swagger-ui',
  deepLinking: true,         // enable URL hash navigation
  layout: "StandaloneLayout"  // required for deep linking
});
```

### Large Spec Performance

**Problem:** Swagger UI is slow or freezes with large specs (1000+ paths).

**Fixes:**
1. **Filter displayed operations:**
```javascript
SwaggerUIBundle({
  url: "/openapi.yaml",
  filter: true,              // adds search/filter bar
  maxDisplayedTags: 20,      // limit initial display
  docExpansion: "none",      // collapse all by default
});
```

2. **Split the spec:** Use tags and serve filtered views.
3. **Use Redoc:** Better performance with large specs.
4. **Bundle and inline $refs:** External refs add HTTP requests.

```bash
npx @redocly/cli bundle openapi.yaml -o bundled.yaml
# Serve bundled.yaml to Swagger UI
```

### Authentication Not Persisting

**Problem:** Auth token disappears after page reload.

```javascript
SwaggerUIBundle({
  url: "/openapi.yaml",
  persistAuthorization: true,  // saves auth in localStorage
});
```

**Problem:** OAuth2 redirect not working

```javascript
SwaggerUIBundle({
  url: "/openapi.yaml",
  oauth2RedirectUrl: "https://your-domain.com/oauth2-redirect.html",
  // The redirect HTML file must be served at this URL
  // Use the one from swagger-ui-dist/oauth2-redirect.html
});
```

---

## CORS with Try-It-Out

### Understanding the Problem

Swagger UI runs in the browser. When it sends requests to your API, the browser enforces CORS. If the API server doesn't return proper CORS headers, requests fail.

```
Browser (Swagger UI at localhost:8080)
  → OPTIONS /api/users (preflight)
  ← 403 Forbidden (no CORS headers)
  → Request blocked by browser
```

### Server-Side CORS Configuration

**Node.js (Express):**

```javascript
const cors = require('cors');
app.use(cors({
  origin: ['http://localhost:8080', 'https://docs.example.com'],
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-API-Key'],
  credentials: true,
  maxAge: 86400
}));
```

**Python (FastAPI):**

```python
from fastapi.middleware.cors import CORSMiddleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8080", "https://docs.example.com"],
    allow_methods=["*"],
    allow_headers=["*"],
    allow_credentials=True,
    max_age=86400,
)
```

**Nginx:**

```nginx
location /api/ {
    if ($request_method = 'OPTIONS') {
        add_header 'Access-Control-Allow-Origin' '$http_origin';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization, X-API-Key';
        add_header 'Access-Control-Max-Age' 86400;
        return 204;
    }
    add_header 'Access-Control-Allow-Origin' '$http_origin';
    proxy_pass http://backend;
}
```

### Swagger UI CORS Workarounds

**Option 1: Same-origin deployment** — Serve Swagger UI from the same domain as the API.

**Option 2: CORS proxy for development**

```javascript
SwaggerUIBundle({
  url: "/openapi.yaml",
  requestInterceptor: (req) => {
    // Only for development!
    req.url = req.url.replace('https://api.example.com', '/api-proxy');
    return req;
  }
});
```

**Option 3: Docker with CORS enabled**

```bash
docker run -p 8080:8080 \
  -e SWAGGER_JSON=/spec/openapi.yaml \
  -e CORS_ALLOWED_ORIGINS="*" \
  -v $(pwd):/spec \
  swaggerapi/swagger-ui
```

---

## Breaking Change Detection

### What Constitutes a Breaking Change

**Breaking changes (will break existing clients):**

| Change | Why It Breaks |
|--------|--------------|
| Removing an endpoint | Clients calling it get 404 |
| Removing a response field | Clients reading it get undefined |
| Adding a required request field | Existing requests missing it get 400 |
| Changing a field type | Deserialization fails |
| Narrowing an enum | Clients sending removed values get 400 |
| Changing a path parameter name | URLs change |
| Removing a security scheme | Auth flow breaks |
| Changing error format | Error handling breaks |

**Non-breaking changes:**

| Change | Why It's Safe |
|--------|--------------|
| Adding a new endpoint | Existing clients don't use it |
| Adding an optional request field | Existing requests still valid |
| Adding a response field | Clients ignore unknown fields |
| Widening an enum | Existing values still work |
| Adding a new media type | Content negotiation falls back |
| Making a required field optional | Existing requests still valid |

### Using oasdiff

```bash
# Install
go install github.com/tufin/oasdiff@latest
# Or: brew install oasdiff
# Or: docker pull tufin/oasdiff

# Check for breaking changes
oasdiff breaking base-openapi.yaml new-openapi.yaml

# Get detailed diff
oasdiff diff base-openapi.yaml new-openapi.yaml --format yaml

# Only breaking changes (for CI)
oasdiff breaking base-openapi.yaml new-openapi.yaml --fail-on ERR

# Check from URLs
oasdiff breaking \
  https://api.example.com/openapi.yaml \
  ./openapi.yaml

# Output as JSON (for programmatic use)
oasdiff breaking base.yaml new.yaml --format json
```

**oasdiff categories:**
- `ERR` — Definite breaking change
- `WARN` — Potentially breaking (e.g., adding a required response header)
- `INFO` — Non-breaking change

### Using optic

```bash
# Install
npm install -g @useoptic/optic

# Compare specs
optic diff base-openapi.yaml new-openapi.yaml

# CI mode with exit code
optic diff base-openapi.yaml new-openapi.yaml --check

# With custom rules
optic diff base-openapi.yaml new-openapi.yaml \
  --ruleset @useoptic/standard-rulesets/naming-convention
```

### CI Integration for Breaking Changes

```yaml
# GitHub Actions workflow for breaking change detection
name: API Breaking Change Check
on:
  pull_request:
    paths: ['openapi.yaml', 'specs/**']

jobs:
  check-breaking:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Get base spec
        run: git show origin/main:openapi.yaml > base-openapi.yaml

      - name: Check breaking changes
        uses: docker://tufin/oasdiff:latest
        with:
          args: breaking base-openapi.yaml openapi.yaml --fail-on ERR

      - name: Generate diff report
        if: failure()
        uses: docker://tufin/oasdiff:latest
        with:
          args: diff base-openapi.yaml openapi.yaml --format markdown
```

**Pre-commit hook for local development:**

```bash
#!/bin/bash
# .git/hooks/pre-commit
SPEC_FILE="openapi.yaml"
if git diff --cached --name-only | grep -q "$SPEC_FILE"; then
  echo "Checking for breaking API changes..."
  git show HEAD:$SPEC_FILE > /tmp/base-spec.yaml 2>/dev/null
  if [ -f /tmp/base-spec.yaml ]; then
    oasdiff breaking /tmp/base-spec.yaml $SPEC_FILE --fail-on ERR
    if [ $? -ne 0 ]; then
      echo "❌ Breaking API changes detected. Use --no-verify to bypass."
      exit 1
    fi
  fi
  echo "✅ No breaking API changes."
fi
```
