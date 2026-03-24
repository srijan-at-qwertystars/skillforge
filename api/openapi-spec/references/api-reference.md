# OpenAPI 3.1 Field Reference

## Table of Contents

- [Root Document Object](#root-document-object)
- [Info Object](#info-object)
- [Contact Object](#contact-object)
- [License Object](#license-object)
- [Server Object](#server-object)
- [Server Variable Object](#server-variable-object)
- [Paths Object](#paths-object)
- [Path Item Object](#path-item-object)
- [Operation Object](#operation-object)
- [External Documentation Object](#external-documentation-object)
- [Parameter Object](#parameter-object)
- [Request Body Object](#request-body-object)
- [Media Type Object](#media-type-object)
- [Encoding Object](#encoding-object)
- [Response Object](#response-object)
- [Responses Object](#responses-object)
- [Callback Object](#callback-object)
- [Example Object](#example-object)
- [Link Object](#link-object)
- [Header Object](#header-object)
- [Tag Object](#tag-object)
- [Reference Object](#reference-object)
- [Schema Object](#schema-object)
  - [Core Schema Properties](#core-schema-properties)
  - [String Validation](#string-validation)
  - [Numeric Validation](#numeric-validation)
  - [Array Validation](#array-validation)
  - [Object Validation](#object-validation)
  - [Composition Keywords](#composition-keywords)
  - [OpenAPI-Specific Extensions](#openapi-specific-extensions)
- [Discriminator Object](#discriminator-object)
- [XML Object](#xml-object)
- [Security Scheme Object](#security-scheme-object)
- [OAuth Flows Object](#oauth-flows-object)
- [OAuth Flow Object](#oauth-flow-object)
- [Components Object](#components-object)
- [Webhook Object](#webhook-object)

---

## Root Document Object

The top-level document of an OpenAPI definition.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `openapi` | `string` | ✅ | OpenAPI version. Must be `"3.1.0"` for 3.1 or `"3.0.3"` for 3.0. |
| `info` | [Info Object](#info-object) | ✅ | API metadata. |
| `jsonSchemaDialect` | `string` | ❌ | Default JSON Schema dialect URI. Default: `https://spec.openapis.org/oas/3.1/dialect/base`. 3.1 only. |
| `servers` | [[Server Object](#server-object)] | ❌ | Array of server objects. Default: `[{ url: "/" }]`. |
| `paths` | [Paths Object](#paths-object) | ❌ | Available API endpoints. At least one of `paths`, `components`, or `webhooks` must be present. |
| `webhooks` | Map[string, [Path Item Object](#path-item-object)] | ❌ | Webhook definitions. 3.1 only. |
| `components` | [Components Object](#components-object) | ❌ | Reusable components. |
| `security` | [[Security Requirement Object](#security-requirement-object)] | ❌ | Global security requirements. |
| `tags` | [[Tag Object](#tag-object)] | ❌ | Tags for operation grouping. |
| `externalDocs` | [External Documentation Object](#external-documentation-object) | ❌ | External documentation link. |

```yaml
openapi: "3.1.0"
info:
  title: Pet Store API
  version: "1.0.0"
jsonSchemaDialect: "https://spec.openapis.org/oas/3.1/dialect/base"
servers:
  - url: https://api.petstore.example.com/v1
paths:
  /pets: {}
components: {}
security:
  - bearerAuth: []
tags:
  - name: Pets
externalDocs:
  url: https://docs.petstore.example.com
```

---

## Info Object

Metadata about the API.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | `string` | ✅ | API title. |
| `summary` | `string` | ❌ | Short API summary. 3.1 only. |
| `description` | `string` | ❌ | Detailed description. Supports CommonMark/Markdown. |
| `termsOfService` | `string` | ❌ | URL to Terms of Service. Must be a URL. |
| `contact` | [Contact Object](#contact-object) | ❌ | Contact information. |
| `license` | [License Object](#license-object) | ❌ | License information. |
| `version` | `string` | ✅ | API document version (not the OpenAPI spec version). |

```yaml
info:
  title: User Management API
  summary: Manage users and roles
  description: |
    Comprehensive API for user lifecycle management.
    Supports CRUD operations, role assignment, and bulk imports.
  termsOfService: https://example.com/terms
  contact:
    name: API Support
    url: https://support.example.com
    email: api-support@example.com
  license:
    name: Apache 2.0
    identifier: Apache-2.0
  version: "2.1.0"
```

---

## Contact Object

Contact information for the API.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | `string` | ❌ | Contact name or team. |
| `url` | `string` | ❌ | URL for contact. Must be a URL. |
| `email` | `string` | ❌ | Contact email address. |

---

## License Object

License information for the API.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | `string` | ✅ | License name (e.g., "MIT", "Apache 2.0"). |
| `identifier` | `string` | ❌ | SPDX license expression. 3.1 only. Mutually exclusive with `url`. |
| `url` | `string` | ❌ | URL to the license text. Mutually exclusive with `identifier`. |

---

## Server Object

Represents an API server.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | `string` | ✅ | Server URL. May contain variables in `{braces}`. Can be relative. |
| `description` | `string` | ❌ | Server description. |
| `variables` | Map[string, [Server Variable Object](#server-variable-object)] | ❌ | Variable substitutions for the URL template. |

```yaml
servers:
  - url: https://{environment}.api.example.com/{basePath}
    description: Main server
    variables:
      environment:
        default: prod
        enum: [prod, staging, dev]
        description: Deployment environment
      basePath:
        default: v2
```

---

## Server Variable Object

Variable substitution for server URL templates.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `enum` | [`string`] | ❌ | Allowed values. If present, `default` must be one of these. |
| `default` | `string` | ✅ | Default value for substitution. |
| `description` | `string` | ❌ | Variable description. |

---

## Paths Object

Holds the relative paths to individual endpoints. Each key is a path string beginning with `/`.

```yaml
paths:
  /users:
    $ref: "./paths/users.yaml"
  /users/{userId}:
    get: ...
    put: ...
    delete: ...
  /orders:
    get: ...
    post: ...
```

**Rules:**
- Path keys must begin with `/`
- Path templating uses `{paramName}` syntax
- Paths must not be ambiguous (e.g., `/pets/{petId}` and `/pets/{name}` conflict)
- Trailing slashes are significant (`/users` ≠ `/users/`)

---

## Path Item Object

Describes operations available on a single path.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `$ref` | `string` | ❌ | Reference to an external path item definition. |
| `summary` | `string` | ❌ | Summary for all operations on this path. |
| `description` | `string` | ❌ | Description for all operations on this path. |
| `get` | [Operation Object](#operation-object) | ❌ | GET operation. |
| `put` | [Operation Object](#operation-object) | ❌ | PUT operation. |
| `post` | [Operation Object](#operation-object) | ❌ | POST operation. |
| `delete` | [Operation Object](#operation-object) | ❌ | DELETE operation. |
| `options` | [Operation Object](#operation-object) | ❌ | OPTIONS operation. |
| `head` | [Operation Object](#operation-object) | ❌ | HEAD operation. |
| `patch` | [Operation Object](#operation-object) | ❌ | PATCH operation. |
| `trace` | [Operation Object](#operation-object) | ❌ | TRACE operation. |
| `servers` | [[Server Object](#server-object)] | ❌ | Override servers for this path. |
| `parameters` | [[Parameter Object](#parameter-object) \| [Reference Object](#reference-object)] | ❌ | Parameters shared by all operations on this path. |

```yaml
/users/{userId}:
  summary: User operations
  parameters:
    - name: userId
      in: path
      required: true
      schema: { type: string, format: uuid }
  get:
    operationId: getUserById
    responses:
      "200": { description: OK }
  delete:
    operationId: deleteUser
    responses:
      "204": { description: Deleted }
```

---

## Operation Object

Describes a single API operation on a path.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `tags` | [`string`] | ❌ | Operation tags for grouping. |
| `summary` | `string` | ❌ | Short summary (< 120 chars recommended). |
| `description` | `string` | ❌ | Detailed description. Supports Markdown. |
| `externalDocs` | [External Documentation Object](#external-documentation-object) | ❌ | Link to external docs. |
| `operationId` | `string` | ❌ | Unique identifier. Must be unique across all operations. Required for codegen. |
| `parameters` | [[Parameter Object](#parameter-object) \| [Reference Object](#reference-object)] | ❌ | Operation-specific parameters. Overrides path-level params with same `name` + `in`. |
| `requestBody` | [Request Body Object](#request-body-object) \| [Reference Object](#reference-object) | ❌ | Request body definition. |
| `responses` | [Responses Object](#responses-object) | ✅ | Possible responses. |
| `callbacks` | Map[string, [Callback Object](#callback-object) \| [Reference Object](#reference-object)] | ❌ | Callback definitions. |
| `deprecated` | `boolean` | ❌ | Marks operation as deprecated. Default: `false`. |
| `security` | [[Security Requirement Object](#security-requirement-object)] | ❌ | Override global security for this operation. Use `[]` for public. |
| `servers` | [[Server Object](#server-object)] | ❌ | Override servers for this operation. |

```yaml
get:
  tags: [Users]
  summary: List all users
  description: |
    Returns a paginated list of users.
    Supports filtering by status and role.
  operationId: listUsers
  parameters:
    - $ref: "#/components/parameters/Limit"
    - $ref: "#/components/parameters/Offset"
  responses:
    "200":
      description: Successful response
      content:
        application/json:
          schema:
            $ref: "#/components/schemas/UserList"
    "401":
      $ref: "#/components/responses/Unauthorized"
  security:
    - bearerAuth: []
  deprecated: false
```

---

## External Documentation Object

Reference to external documentation.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | `string` | ❌ | Description. Supports Markdown. |
| `url` | `string` | ✅ | URL to the documentation. |

---

## Parameter Object

Describes a single operation parameter.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | `string` | ✅ | Parameter name. Case-sensitive. |
| `in` | `string` | ✅ | Location: `"query"`, `"header"`, `"path"`, or `"cookie"`. |
| `description` | `string` | ❌ | Parameter description. Supports Markdown. |
| `required` | `boolean` | ❌ | Whether required. MUST be `true` for `in: path`. Default: `false`. |
| `deprecated` | `boolean` | ❌ | Whether deprecated. Default: `false`. |
| `allowEmptyValue` | `boolean` | ❌ | Allow empty value for query params. Default: `false`. Deprecated in 3.1. |
| `style` | `string` | ❌ | Serialization style. Defaults depend on `in`. |
| `explode` | `boolean` | ❌ | Whether arrays/objects generate separate params. Default: `true` for `style: form`. |
| `allowReserved` | `boolean` | ❌ | Allow reserved characters (`:/?#[]@!$&'()*+,;=`) in query. Default: `false`. |
| `schema` | [Schema Object](#schema-object) | ❌ | Parameter schema. |
| `example` | any | ❌ | Example value. Mutually exclusive with `examples`. |
| `examples` | Map[string, [Example Object](#example-object)] | ❌ | Example values. Mutually exclusive with `example`. |
| `content` | Map[string, [Media Type Object](#media-type-object)] | ❌ | Complex parameter serialization. Mutually exclusive with `schema`. Must have exactly one entry. |

**Default `style` values by location:**

| `in` | Default `style` | Default `explode` |
|------|----------------|-------------------|
| `query` | `form` | `true` |
| `header` | `simple` | `false` |
| `path` | `simple` | `false` |
| `cookie` | `form` | `true` |

**Available styles:**

| Style | `in` | Primitive | Array | Object |
|-------|------|-----------|-------|--------|
| `matrix` | path | `;id=5` | `;id=3,4,5` | `;id=role,admin,name,Jo` |
| `label` | path | `.5` | `.3.4.5` | `.role.admin.name.Jo` |
| `form` | query, cookie | `id=5` | `id=3,4,5` | `role=admin&name=Jo` |
| `simple` | path, header | `5` | `3,4,5` | `role,admin,name,Jo` |
| `spaceDelimited` | query | n/a | `id=3%204%205` | n/a |
| `pipeDelimited` | query | n/a | `id=3\|4\|5` | n/a |
| `deepObject` | query | n/a | n/a | `id[role]=admin&id[name]=Jo` |

```yaml
parameters:
  - name: userId
    in: path
    required: true
    schema:
      type: string
      format: uuid
    example: "550e8400-e29b-41d4-a716-446655440000"

  - name: tags
    in: query
    style: form
    explode: true
    schema:
      type: array
      items: { type: string }
    examples:
      single:
        value: [admin]
      multiple:
        value: [admin, editor]

  - name: filter
    in: query
    content:
      application/json:
        schema:
          type: object
          properties:
            status: { type: string }
            minAge: { type: integer }
```

---

## Request Body Object

Describes a request body.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | `string` | ❌ | Description. Supports Markdown. |
| `content` | Map[string, [Media Type Object](#media-type-object)] | ✅ | Content by media type. |
| `required` | `boolean` | ❌ | Whether the body is required. Default: `false`. |

```yaml
requestBody:
  description: User to create
  required: true
  content:
    application/json:
      schema:
        $ref: "#/components/schemas/CreateUser"
      examples:
        basic:
          summary: Basic user
          value:
            name: Jane Doe
            email: jane@example.com
    application/xml:
      schema:
        $ref: "#/components/schemas/CreateUser"
```

---

## Media Type Object

Describes content for a specific media type.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema` | [Schema Object](#schema-object) | ❌ | Schema defining the content. |
| `example` | any | ❌ | Example value. Mutually exclusive with `examples`. |
| `examples` | Map[string, [Example Object](#example-object)] | ❌ | Named examples. Mutually exclusive with `example`. |
| `encoding` | Map[string, [Encoding Object](#encoding-object)] | ❌ | Encoding info for individual properties. Only applies to `multipart` and `application/x-www-form-urlencoded`. |

---

## Encoding Object

Applies to individual properties in `multipart` or `application/x-www-form-urlencoded` request bodies.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `contentType` | `string` | ❌ | Content type for this property. Default depends on property type. |
| `headers` | Map[string, [Header Object](#header-object)] | ❌ | Additional headers for multipart. `Content-Type` header is ignored here. |
| `style` | `string` | ❌ | Serialization style. Same options as query parameter `style`. |
| `explode` | `boolean` | ❌ | Whether to explode arrays/objects. |
| `allowReserved` | `boolean` | ❌ | Allow reserved characters. Default: `false`. |

---

## Response Object

Describes a single response from an API operation.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | `string` | ✅ | Response description. Supports Markdown. |
| `headers` | Map[string, [Header Object](#header-object) \| [Reference Object](#reference-object)] | ❌ | Response headers. `Content-Type` is excluded. |
| `content` | Map[string, [Media Type Object](#media-type-object)] | ❌ | Response body by media type. |
| `links` | Map[string, [Link Object](#link-object) \| [Reference Object](#reference-object)] | ❌ | Links to related operations. |

```yaml
responses:
  "200":
    description: User retrieved successfully
    headers:
      X-Request-Id:
        schema: { type: string, format: uuid }
        description: Unique request identifier
    content:
      application/json:
        schema:
          $ref: "#/components/schemas/User"
        example:
          id: "550e8400-e29b-41d4-a716-446655440000"
          name: Jane Doe
          email: jane@example.com
    links:
      UpdateUser:
        operationId: updateUser
        parameters:
          userId: $response.body#/id
```

---

## Responses Object

Container for expected responses of an operation. Maps HTTP status codes to Response Objects.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `default` | [Response Object](#response-object) \| [Reference Object](#reference-object) | ❌ | Default response for undeclared status codes. |
| `{HTTP status code}` | [Response Object](#response-object) \| [Reference Object](#reference-object) | ❌ | Response for specific HTTP status code. Codes must be quoted strings. |

Status codes can be exact (`"200"`) or wildcards (`"2XX"`, `"4XX"`, `"5XX"`).

```yaml
responses:
  "200":
    description: Success
    content:
      application/json:
        schema:
          $ref: "#/components/schemas/User"
  "4XX":
    description: Client error
    content:
      application/json:
        schema:
          $ref: "#/components/schemas/Error"
  default:
    description: Unexpected error
    content:
      application/json:
        schema:
          $ref: "#/components/schemas/Error"
```

---

## Callback Object

A map of runtime URL expressions to Path Item Objects for webhook callbacks.

The key is a runtime expression that identifies the callback URL. The value is a Path Item Object.

```yaml
callbacks:
  onPaymentComplete:
    "{$request.body#/callbackUrl}":
      post:
        summary: Payment completion callback
        requestBody:
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/PaymentEvent"
        responses:
          "200": { description: Acknowledged }
```

**Runtime expressions:** `$url`, `$method`, `$statusCode`, `$request.header.{name}`, `$request.query.{name}`, `$request.path.{name}`, `$request.body#/pointer`, `$response.header.{name}`, `$response.body#/pointer`.

---

## Example Object

Provides an example value.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `summary` | `string` | ❌ | Short description. |
| `description` | `string` | ❌ | Detailed description. Supports Markdown. |
| `value` | any | ❌ | Example value. Mutually exclusive with `externalValue`. |
| `externalValue` | `string` | ❌ | URL to external example. Mutually exclusive with `value`. |

```yaml
examples:
  basicUser:
    summary: A basic user
    value:
      id: "123"
      name: Jane Doe
      email: jane@example.com
  adminUser:
    summary: An admin user
    value:
      id: "456"
      name: Admin
      email: admin@example.com
      role: admin
  externalExample:
    summary: Example from file
    externalValue: https://example.com/samples/user.json
```

---

## Link Object

Represents a possible design-time link for a response.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `operationRef` | `string` | ❌ | Relative or absolute URI reference to an operation. Mutually exclusive with `operationId`. |
| `operationId` | `string` | ❌ | Name of an existing operationId. Mutually exclusive with `operationRef`. |
| `parameters` | Map[string, any \| runtime expression] | ❌ | Parameters to pass to the linked operation. |
| `requestBody` | any \| runtime expression | ❌ | Request body to pass. |
| `description` | `string` | ❌ | Link description. Supports Markdown. |
| `server` | [Server Object](#server-object) | ❌ | Override server for the linked operation. |

```yaml
links:
  GetUserById:
    operationId: getUserById
    parameters:
      userId: $response.body#/id
    description: Retrieve the user that was just created
  ListUserOrders:
    operationId: listUserOrders
    parameters:
      userId: $response.body#/id
```

---

## Header Object

Describes a single header. Identical to [Parameter Object](#parameter-object) except `name` and `in` are not allowed (determined by context).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | `string` | ❌ | Header description. |
| `required` | `boolean` | ❌ | Whether required. Default: `false`. |
| `deprecated` | `boolean` | ❌ | Whether deprecated. Default: `false`. |
| `schema` | [Schema Object](#schema-object) | ❌ | Header schema. |
| `example` | any | ❌ | Example value. |
| `examples` | Map[string, [Example Object](#example-object)] | ❌ | Named examples. |
| `content` | Map[string, [Media Type Object](#media-type-object)] | ❌ | Complex header serialization. |

```yaml
headers:
  X-Request-Id:
    description: Unique request identifier
    required: true
    schema:
      type: string
      format: uuid
    example: "550e8400-e29b-41d4-a716-446655440000"
  X-RateLimit-Remaining:
    description: Remaining API calls in current window
    schema:
      type: integer
```

---

## Tag Object

Metadata for operation grouping.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | `string` | ✅ | Tag name. Must match values used in operation `tags`. |
| `description` | `string` | ❌ | Tag description. Supports Markdown. |
| `externalDocs` | [External Documentation Object](#external-documentation-object) | ❌ | External documentation link. |

```yaml
tags:
  - name: Users
    description: User management operations
    externalDocs:
      url: https://docs.example.com/users
  - name: Orders
    description: Order processing
```

---

## Reference Object

A simple object to allow referencing other components.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `$ref` | `string` | ✅ | URI reference. |
| `summary` | `string` | ❌ | Override summary. 3.1 only. |
| `description` | `string` | ❌ | Override description. 3.1 only. |

```yaml
# Local reference
$ref: "#/components/schemas/User"

# External file reference
$ref: "./schemas/user.yaml"

# External file with JSON pointer
$ref: "./schemas/user.yaml#/User"

# URL reference
$ref: "https://example.com/schemas/common.yaml#/components/schemas/Error"

# With overrides (3.1 only)
$ref: "#/components/schemas/User"
summary: A user object with all fields
description: This returns the full user including computed fields
```

---

## Schema Object

Defines a data type. OpenAPI 3.1 uses full JSON Schema (2020-12 draft) with OpenAPI extensions.

### Core Schema Properties

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | `string` or `[string]` | — | Data type. One of: `"string"`, `"number"`, `"integer"`, `"boolean"`, `"array"`, `"object"`, `"null"`. 3.1 allows arrays: `["string", "null"]`. |
| `enum` | [any] | — | Allowed values. |
| `const` | any | — | Single allowed value. 3.1 only. |
| `default` | any | — | Default value. Must conform to schema. |
| `title` | `string` | — | Schema title. |
| `description` | `string` | — | Schema description. Supports Markdown. |
| `examples` | [any] | — | Array of example values. 3.1 only (JSON Schema). |
| `$comment` | `string` | — | Developer comments. Not for end users. 3.1 only. |

### String Validation

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `minLength` | `integer` | `0` | Minimum string length (inclusive). |
| `maxLength` | `integer` | — | Maximum string length (inclusive). |
| `pattern` | `string` | — | ECMA-262 regular expression. |
| `format` | `string` | — | Semantic format hint. Common values below. |
| `contentEncoding` | `string` | — | Encoding (e.g., `"base64"`). 3.1 only. |
| `contentMediaType` | `string` | — | Media type of content (e.g., `"image/png"`). 3.1 only. |

**Common `format` values:**

| Format | Description | Example |
|--------|-------------|---------|
| `date-time` | RFC 3339 date-time | `2024-01-15T09:30:00Z` |
| `date` | RFC 3339 date | `2024-01-15` |
| `time` | RFC 3339 time | `09:30:00Z` |
| `duration` | RFC 3339 duration | `P3D` (3 days) |
| `email` | RFC 5321 email | `user@example.com` |
| `idn-email` | RFC 6531 internationalized email | `user@例え.jp` |
| `hostname` | RFC 1123 hostname | `api.example.com` |
| `ipv4` | RFC 2673 IPv4 | `192.168.1.1` |
| `ipv6` | RFC 4291 IPv6 | `::1` |
| `uri` | RFC 3986 URI | `https://example.com` |
| `uri-reference` | RFC 3986 URI reference | `/path/to/resource` |
| `uuid` | RFC 4122 UUID | `550e8400-e29b-41d4-a716-446655440000` |
| `password` | UI hint to obscure input | — |
| `binary` | Binary data (file upload) | — |
| `byte` | Base64-encoded binary | — |
| `int32` | 32-bit signed integer | — |
| `int64` | 64-bit signed integer | — |
| `float` | Single-precision float | — |
| `double` | Double-precision float | — |

### Numeric Validation

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `minimum` | `number` | — | Inclusive minimum value. |
| `exclusiveMinimum` | `number` | — | Exclusive minimum (3.1: number; 3.0: boolean). |
| `maximum` | `number` | — | Inclusive maximum value. |
| `exclusiveMaximum` | `number` | — | Exclusive maximum (3.1: number; 3.0: boolean). |
| `multipleOf` | `number` | — | Value must be divisible by this. Must be > 0. |

```yaml
# Price in cents
price:
  type: integer
  minimum: 0
  maximum: 99999999
  description: Price in cents

# Percentage
percentage:
  type: number
  minimum: 0
  maximum: 100
  multipleOf: 0.01

# Positive non-zero
quantity:
  type: integer
  exclusiveMinimum: 0  # 3.1: must be > 0
```

### Array Validation

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `items` | [Schema Object](#schema-object) | — | Schema for array items. |
| `prefixItems` | [[Schema Object](#schema-object)] | — | Tuple validation: schemas for items by position. 3.1 only. |
| `contains` | [Schema Object](#schema-object) | — | At least one item must match. 3.1 only. |
| `minItems` | `integer` | `0` | Minimum array length. |
| `maxItems` | `integer` | — | Maximum array length. |
| `uniqueItems` | `boolean` | `false` | Whether all items must be unique. |

```yaml
# Tags array
tags:
  type: array
  items:
    type: string
    minLength: 1
  minItems: 0
  maxItems: 10
  uniqueItems: true

# Tuple: [latitude, longitude]  (3.1)
coordinates:
  type: array
  prefixItems:
    - type: number
      minimum: -90
      maximum: 90
    - type: number
      minimum: -180
      maximum: 180
  minItems: 2
  maxItems: 2
```

### Object Validation

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `properties` | Map[string, [Schema Object](#schema-object)] | — | Property definitions. |
| `required` | [`string`] | `[]` | List of required property names. |
| `additionalProperties` | `boolean` or [Schema Object](#schema-object) | `true` | Schema for undeclared properties. `false` forbids extra properties. |
| `minProperties` | `integer` | `0` | Minimum number of properties. |
| `maxProperties` | `integer` | — | Maximum number of properties. |
| `patternProperties` | Map[regex, [Schema Object](#schema-object)] | — | Schemas for properties matching regex keys. 3.1 only. |
| `propertyNames` | [Schema Object](#schema-object) | — | Schema that property names must match. 3.1 only. |
| `dependentRequired` | Map[string, [`string`]] | — | If key is present, listed properties are also required. 3.1 only. |
| `dependentSchemas` | Map[string, [Schema Object](#schema-object)] | — | If key is present, additional schema must validate. 3.1 only. |

```yaml
# Strict object
UserStrict:
  type: object
  required: [name, email]
  properties:
    name: { type: string }
    email: { type: string, format: email }
  additionalProperties: false

# Metadata map
Metadata:
  type: object
  additionalProperties:
    type: string
  maxProperties: 20
  propertyNames:
    pattern: '^[a-z][a-z0-9_]*$'

# Conditional requirements (3.1)
Address:
  type: object
  properties:
    country: { type: string }
    state: { type: string }
    province: { type: string }
  dependentRequired:
    state: [country]
    province: [country]
```

### Composition Keywords

| Field | Type | Description |
|-------|------|-------------|
| `allOf` | [[Schema Object](#schema-object)] | Must match ALL schemas. Used for composition/inheritance. |
| `oneOf` | [[Schema Object](#schema-object)] | Must match EXACTLY ONE schema. Used for polymorphism. |
| `anyOf` | [[Schema Object](#schema-object)] | Must match ONE OR MORE schemas. |
| `not` | [Schema Object](#schema-object) | Must NOT match this schema. |
| `if` | [Schema Object](#schema-object) | Conditional schema evaluation. 3.1 only. |
| `then` | [Schema Object](#schema-object) | Applied if `if` passes. 3.1 only. |
| `else` | [Schema Object](#schema-object) | Applied if `if` fails. 3.1 only. |

```yaml
# Conditional validation (3.1)
Address:
  type: object
  properties:
    country: { type: string }
    zipCode: { type: string }
    postalCode: { type: string }
  if:
    properties:
      country: { const: US }
  then:
    required: [zipCode]
    properties:
      zipCode: { pattern: '^\d{5}(-\d{4})?$' }
  else:
    required: [postalCode]
```

### OpenAPI-Specific Extensions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `nullable` | `boolean` | `false` | Whether `null` is allowed. **3.0 only**; in 3.1 use `type: ["string", "null"]`. |
| `discriminator` | [Discriminator Object](#discriminator-object) | — | For `oneOf`/`anyOf` polymorphism. |
| `xml` | [XML Object](#xml-object) | — | XML serialization metadata. |
| `externalDocs` | [External Documentation Object](#external-documentation-object) | — | External documentation link. |
| `readOnly` | `boolean` | `false` | Property only in responses. Ignored in requests. |
| `writeOnly` | `boolean` | `false` | Property only in requests. Ignored in responses. |
| `deprecated` | `boolean` | `false` | Whether this schema is deprecated. |
| `example` | any | — | Example value. Deprecated in 3.1 in favor of `examples` array. |

---

## Discriminator Object

Hints for polymorphic deserialization with `oneOf`/`anyOf`.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `propertyName` | `string` | ✅ | Name of the property that discriminates types. |
| `mapping` | Map[string, string] | ❌ | Maps property values to schema `$ref` strings or schema names. |

```yaml
discriminator:
  propertyName: petType
  mapping:
    dog: "#/components/schemas/Dog"
    cat: "#/components/schemas/Cat"
    hamster: "#/components/schemas/Hamster"
```

---

## XML Object

Metadata for XML serialization.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `string` | property name | XML element name. |
| `namespace` | `string` | — | XML namespace URI. |
| `prefix` | `string` | — | XML namespace prefix. |
| `attribute` | `boolean` | `false` | Whether to serialize as XML attribute instead of element. |
| `wrapped` | `boolean` | `false` | Whether to wrap array items in an outer element. Only for arrays. |

```yaml
Pet:
  type: object
  properties:
    id:
      type: integer
      xml:
        attribute: true
    name:
      type: string
    tags:
      type: array
      items:
        type: string
        xml:
          name: tag
      xml:
        wrapped: true
        name: tags
  xml:
    name: Pet
    namespace: "http://example.com/schema/pet"
    prefix: pet
```

---

## Security Scheme Object

Defines a security scheme that can be used by operations.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | `string` | ✅ | Type: `"apiKey"`, `"http"`, `"mutualTLS"`, `"oauth2"`, or `"openIdConnect"`. |
| `description` | `string` | ❌ | Description. Supports Markdown. |
| `name` | `string` | ✅ (apiKey) | Name of the header, query, or cookie parameter. Required for `apiKey`. |
| `in` | `string` | ✅ (apiKey) | Location: `"query"`, `"header"`, or `"cookie"`. Required for `apiKey`. |
| `scheme` | `string` | ✅ (http) | HTTP auth scheme (e.g., `"bearer"`, `"basic"`). Required for `http`. |
| `bearerFormat` | `string` | ❌ | Hint for bearer token format (e.g., `"JWT"`). Only for `http` with `scheme: bearer`. |
| `flows` | [OAuth Flows Object](#oauth-flows-object) | ✅ (oauth2) | OAuth2 flow definitions. Required for `oauth2`. |
| `openIdConnectUrl` | `string` | ✅ (oidc) | OpenID Connect discovery URL. Required for `openIdConnect`. |

```yaml
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: JWT token in Authorization header

    apiKeyHeader:
      type: apiKey
      in: header
      name: X-API-Key

    apiKeyQuery:
      type: apiKey
      in: query
      name: api_key

    basicAuth:
      type: http
      scheme: basic

    oauth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://auth.example.com/authorize
          tokenUrl: https://auth.example.com/token
          scopes:
            "read:users": Read user data
            "write:users": Create and update users

    oidc:
      type: openIdConnect
      openIdConnectUrl: https://auth.example.com/.well-known/openid-configuration

    mutualTLS:
      type: mutualTLS
      description: Client certificate authentication
```

### Security Requirement Object

Maps security scheme names to required scopes.

```yaml
# Global: any request must use one of these
security:
  - bearerAuth: []              # No scopes
  - oauth2: ["read:users"]     # Requires read:users scope
  - apiKeyHeader: []
    basicAuth: []               # AND logic: both required

# Per-operation override
paths:
  /public:
    get:
      security: []  # No auth required (public)
```

---

## OAuth Flows Object

Configuration for OAuth 2.0 flows.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `implicit` | [OAuth Flow Object](#oauth-flow-object) | ❌ | Implicit flow config. |
| `password` | [OAuth Flow Object](#oauth-flow-object) | ❌ | Resource Owner Password flow. |
| `clientCredentials` | [OAuth Flow Object](#oauth-flow-object) | ❌ | Client Credentials flow. |
| `authorizationCode` | [OAuth Flow Object](#oauth-flow-object) | ❌ | Authorization Code flow. |

---

## OAuth Flow Object

Configuration for a specific OAuth 2.0 flow.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `authorizationUrl` | `string` | ✅ * | Authorization endpoint URL. Required for `implicit` and `authorizationCode`. |
| `tokenUrl` | `string` | ✅ * | Token endpoint URL. Required for `password`, `clientCredentials`, and `authorizationCode`. |
| `refreshUrl` | `string` | ❌ | Token refresh URL. |
| `scopes` | Map[string, string] | ✅ | Available scopes. Keys are scope names, values are descriptions. |

```yaml
flows:
  authorizationCode:
    authorizationUrl: https://auth.example.com/authorize
    tokenUrl: https://auth.example.com/token
    refreshUrl: https://auth.example.com/refresh
    scopes:
      "read:users": Read access to user data
      "write:users": Write access to user data
      "admin": Full administrative access
  clientCredentials:
    tokenUrl: https://auth.example.com/token
    scopes:
      "api:access": General API access
```

---

## Components Object

Holds reusable objects for the specification.

| Field | Type | Description |
|-------|------|-------------|
| `schemas` | Map[string, [Schema Object](#schema-object)] | Reusable schema definitions. |
| `responses` | Map[string, [Response Object](#response-object)] | Reusable response definitions. |
| `parameters` | Map[string, [Parameter Object](#parameter-object)] | Reusable parameter definitions. |
| `examples` | Map[string, [Example Object](#example-object)] | Reusable example definitions. |
| `requestBodies` | Map[string, [Request Body Object](#request-body-object)] | Reusable request body definitions. |
| `headers` | Map[string, [Header Object](#header-object)] | Reusable header definitions. |
| `securitySchemes` | Map[string, [Security Scheme Object](#security-scheme-object)] | Security scheme definitions. |
| `links` | Map[string, [Link Object](#link-object)] | Reusable link definitions. |
| `callbacks` | Map[string, [Callback Object](#callback-object)] | Reusable callback definitions. |
| `pathItems` | Map[string, [Path Item Object](#path-item-object)] | Reusable path item definitions. 3.1 only. |

**Component key rules:**
- Must match regex: `^[a-zA-Z0-9\.\-_]+$`
- All objects defined here have no effect unless referenced via `$ref`

```yaml
components:
  schemas:
    User: { type: object, properties: { name: { type: string } } }
  responses:
    NotFound: { description: Not found }
  parameters:
    UserId: { name: userId, in: path, required: true, schema: { type: string } }
  examples:
    UserExample: { value: { name: Jane } }
  requestBodies:
    CreateUser: { content: { application/json: { schema: { $ref: "#/components/schemas/User" } } } }
  headers:
    RequestId: { schema: { type: string, format: uuid } }
  securitySchemes:
    bearerAuth: { type: http, scheme: bearer }
  links:
    GetUser: { operationId: getUser }
  callbacks:
    onEvent: {}
  pathItems:
    UserItem: { get: { operationId: getUser, responses: { "200": { description: OK } } } }
```

---

## Webhook Object

Webhooks are defined at the root level (3.1 only). Each webhook is a Path Item Object keyed by event name.

```yaml
webhooks:
  newUser:
    post:
      summary: New user registered
      operationId: onNewUser
      tags: [Webhooks]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [event, data]
              properties:
                event: { type: string, enum: [user.created] }
                data:
                  $ref: "#/components/schemas/User"
      responses:
        "200": { description: Webhook processed }
        "202": { description: Webhook accepted }
      security:
        - webhookSecret: []
```
