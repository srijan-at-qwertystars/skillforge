# OpenAPI Code Generation Guide

## Table of Contents

- [openapi-generator Overview](#openapi-generator-overview)
  - [Installation](#installation)
  - [Supported Languages and Frameworks](#supported-languages-and-frameworks)
  - [Basic Usage](#basic-usage)
  - [Global Properties](#global-properties)
  - [Generator-Specific Options](#generator-specific-options)
- [Client SDK Generation](#client-sdk-generation)
  - [TypeScript Client](#typescript-client)
  - [Python Client](#python-client)
  - [Java Client](#java-client)
  - [Go Client](#go-client)
  - [C# Client](#c-client)
  - [Swift Client](#swift-client)
- [Server Stub Generation](#server-stub-generation)
  - [Node.js / Express](#nodejs--express)
  - [Python / FastAPI](#python--fastapi)
  - [Java / Spring Boot](#java--spring-boot)
  - [Go / Gin](#go--gin)
- [Model-Only Generation](#model-only-generation)
  - [Generating Just Models](#generating-just-models)
  - [Use Cases for Model-Only](#use-cases-for-model-only)
- [Custom Templates](#custom-templates)
  - [Template Engine (Mustache)](#template-engine-mustache)
  - [Extracting Default Templates](#extracting-default-templates)
  - [Modifying Templates](#modifying-templates)
  - [Template Variables](#template-variables)
- [Configuration Files](#configuration-files)
  - [YAML Configuration](#yaml-configuration)
  - [JSON Configuration](#json-configuration)
  - [Configuration Priority](#configuration-priority)
- [Post-Processing Hooks](#post-processing-hooks)
  - [Built-in Formatters](#built-in-formatters)
  - [Custom Post-Processing](#custom-post-processing)
- [Custom Generators](#custom-generators)
  - [Creating a Generator Project](#creating-a-generator-project)
  - [Generator Extension Points](#generator-extension-points)
- [Alternatives to openapi-generator](#alternatives-to-openapi-generator)
  - [swagger-codegen](#swagger-codegen)
  - [autorest](#autorest)
  - [openapi-typescript](#openapi-typescript)
  - [orval](#orval)
  - [hey-api](#hey-api)
  - [kiota](#kiota)
  - [Comparison Matrix](#comparison-matrix)

---

## openapi-generator Overview

openapi-generator is the most widely-used tool for generating API client libraries, server stubs, documentation, and configuration from OpenAPI specs.

### Installation

```bash
# NPM (recommended for JS/TS projects)
npm install @openapitools/openapi-generator-cli -g

# Homebrew (macOS)
brew install openapi-generator

# Docker
docker pull openapitools/openapi-generator-cli

# JAR (requires Java 11+)
wget https://repo1.maven.org/maven2/org/openapitools/openapi-generator-cli/7.12.0/openapi-generator-cli-7.12.0.jar \
  -O openapi-generator-cli.jar
java -jar openapi-generator-cli.jar help
```

**Pin the version in your project:**

```json
// openapitools.json (created automatically, or create manually)
{
  "$schema": "node_modules/@openapitools/openapi-generator-cli/config.schema.json",
  "spaces": 2,
  "generator-cli": {
    "version": "7.12.0"
  }
}
```

### Supported Languages and Frameworks

**Client generators (50+):**

| Language | Generators |
|----------|-----------|
| TypeScript | typescript-axios, typescript-fetch, typescript-angular, typescript-node, typescript-rxjs, typescript-inversify |
| Python | python, python-pydantic-v1 |
| Java | java, java-micronaut-client, java-helidon-client |
| Kotlin | kotlin, kotlin-coroutines |
| Go | go |
| C# | csharp, csharp-functions |
| Swift | swift5, swift6 |
| Rust | rust |
| Ruby | ruby |
| PHP | php, php-nextgen |
| Dart | dart, dart-dio |
| Elixir | elixir |

**Server generators (40+):**

| Language | Generators |
|----------|-----------|
| Java | spring, jaxrs-jersey, jaxrs-resteasy, java-micronaut-server, java-helidon-server |
| Python | python-flask, python-fastapi, python-aiohttp |
| Node.js | nodejs-express-server |
| Go | go-server, go-gin-server, go-echo-server |
| C# | aspnetcore |
| Kotlin | kotlin-spring, kotlin-server |
| PHP | php-laravel, php-slim4 |
| Ruby | ruby-on-rails, ruby-sinatra |

```bash
# List all available generators
openapi-generator-cli list

# Get help for a specific generator
openapi-generator-cli config-help -g typescript-axios
```

### Basic Usage

```bash
openapi-generator-cli generate \
  -i openapi.yaml \           # input spec
  -g typescript-axios \        # generator name
  -o ./generated/client \      # output directory
  -c config.yaml \             # configuration file (optional)
  --additional-properties=key=value   # generator-specific options
```

**Key flags:**

| Flag | Description |
|------|-------------|
| `-i` | Input spec file or URL |
| `-g` | Generator name |
| `-o` | Output directory |
| `-c` | Configuration file (YAML or JSON) |
| `--additional-properties` | Comma-separated key=value pairs |
| `--type-mappings` | Override type mappings (e.g., DateTime=string) |
| `--import-mappings` | Override import mappings |
| `--model-name-mappings` | Rename models (e.g., Error=ApiError) |
| `--reserved-words-mappings` | Handle reserved words |
| `--skip-validate-spec` | Skip spec validation |
| `--global-property` | Control what gets generated |
| `-t` | Custom template directory |
| `--git-user-id` | Git user ID for generated package |
| `--git-repo-id` | Git repo name for generated package |
| `--dry-run` | Preview files without generating |

### Global Properties

Control which files are generated:

```bash
# Generate only models
openapi-generator-cli generate -i openapi.yaml -g java \
  --global-property models,modelDocs=false,modelTests=false

# Generate only APIs
openapi-generator-cli generate -i openapi.yaml -g java \
  --global-property apis,apiDocs=false,apiTests=false

# Generate models + APIs without docs/tests
openapi-generator-cli generate -i openapi.yaml -g java \
  --global-property models,apis,supportingFiles=false

# Generate only specific models
openapi-generator-cli generate -i openapi.yaml -g java \
  --global-property models=User:Order:Product
```

### Generator-Specific Options

Each generator has its own set of `additionalProperties`. Discover them with:

```bash
openapi-generator-cli config-help -g typescript-axios
```

Common options across generators:

| Property | Description | Default |
|----------|-------------|---------|
| `npmName` | NPM package name (TS generators) | — |
| `npmVersion` | NPM package version | 1.0.0 |
| `supportsES6` | Generate ES6 code | false |
| `withInterfaces` | Generate interfaces | false |
| `useSingleRequestParameter` | Combine params into single object | false |
| `enumPropertyNaming` | Enum naming style | PascalCase |
| `modelPropertyNaming` | Property naming style | camelCase |
| `artifactId` | Maven artifact ID (Java) | — |
| `groupId` | Maven group ID (Java) | — |
| `packageName` | Output package name | — |

---

## Client SDK Generation

### TypeScript Client

**typescript-axios (most popular):**

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g typescript-axios \
  -o ./src/api-client \
  --additional-properties=\
supportsES6=true,\
npmName=@myorg/api-client,\
npmVersion=1.0.0,\
withInterfaces=true,\
useSingleRequestParameter=true,\
enumPropertyNaming=UPPERCASE
```

**Usage of generated client:**

```typescript
import { Configuration, UsersApi } from '@myorg/api-client';

const config = new Configuration({
  basePath: 'https://api.example.com',
  accessToken: 'your-bearer-token',
});

const usersApi = new UsersApi(config);
const user = await usersApi.getUserById({ userId: '123' });
```

**typescript-fetch (no axios dependency):**

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g typescript-fetch \
  -o ./src/api-client \
  --additional-properties=\
typescriptThreePlus=true,\
npmName=@myorg/api-client
```

### Python Client

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g python \
  -o ./python-client \
  --additional-properties=\
packageName=my_api_client,\
projectName=my-api-client,\
packageVersion=1.0.0,\
pydanticV2=true
```

**Usage:**

```python
import my_api_client
from my_api_client.api import users_api

configuration = my_api_client.Configuration(
    host="https://api.example.com",
    access_token="your-bearer-token"
)

with my_api_client.ApiClient(configuration) as api_client:
    api = users_api.UsersApi(api_client)
    user = api.get_user_by_id(user_id="123")
```

### Java Client

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g java \
  -o ./java-client \
  --additional-properties=\
library=okhttp-gson,\
groupId=com.example,\
artifactId=api-client,\
artifactVersion=1.0.0,\
dateLibrary=java8,\
useJakartaEe=true,\
openApiNullable=false
```

**Available Java HTTP libraries:**

| Library | Description |
|---------|-------------|
| `okhttp-gson` | OkHttp + Gson (default) |
| `jersey2` | Jersey2 + Jackson |
| `jersey3` | Jersey3 + Jackson (Jakarta) |
| `native` | Java 11 HttpClient |
| `resttemplate` | Spring RestTemplate |
| `webclient` | Spring WebClient (reactive) |
| `retrofit2` | Retrofit2 + OkHttp |
| `apache-httpclient` | Apache HttpClient 5 |
| `microprofile` | MicroProfile Rest Client |

### Go Client

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g go \
  -o ./go-client \
  --additional-properties=\
packageName=apiclient,\
isGoSubmodule=true,\
generateInterfaces=true
```

### C# Client

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g csharp \
  -o ./csharp-client \
  --additional-properties=\
packageName=MyApi.Client,\
targetFramework=net8.0,\
library=httpclient,\
nullableReferenceTypes=true
```

### Swift Client

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g swift5 \
  -o ./swift-client \
  --additional-properties=\
projectName=MyAPIClient,\
library=urlsession,\
useJsonEncodable=true,\
useSPMFileStructure=true
```

---

## Server Stub Generation

### Node.js / Express

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g nodejs-express-server \
  -o ./server \
  --additional-properties=\
serverPort=3000
```

> **Note:** The Express generator is basic. For production Node.js APIs, consider writing code-first with `tsoa` or `express-openapi-validator`.

### Python / FastAPI

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g python-fastapi \
  -o ./server \
  --additional-properties=\
packageName=my_api_server,\
serverPort=8000
```

Generated structure:

```
server/
├── src/my_api_server/
│   ├── apis/
│   │   └── users_api.py          # Route definitions
│   ├── models/
│   │   └── user.py               # Pydantic models
│   └── main.py                   # FastAPI app
├── requirements.txt
└── setup.py
```

### Java / Spring Boot

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g spring \
  -o ./server \
  --additional-properties=\
useSpringBoot3=true,\
useTags=true,\
interfaceOnly=true,\
delegatePattern=true,\
useJakartaEe=true,\
documentationProvider=springdoc,\
groupId=com.example,\
artifactId=api-server,\
basePackage=com.example.api,\
apiPackage=com.example.api.controller,\
modelPackage=com.example.api.model
```

**Key Spring options:**

| Property | Description |
|----------|-------------|
| `interfaceOnly=true` | Generate interfaces only (recommended) |
| `delegatePattern=true` | Use delegate pattern for implementation |
| `useSpringBoot3=true` | Spring Boot 3 + Jakarta EE |
| `useTags=true` | Group by tags into separate controller interfaces |
| `reactive=true` | Generate reactive (WebFlux) endpoints |
| `documentationProvider=springdoc` | Use springdoc for Swagger UI |

### Go / Gin

```bash
openapi-generator-cli generate \
  -i openapi.yaml \
  -g go-gin-server \
  -o ./server \
  --additional-properties=\
packageName=api,\
serverPort=8080
```

---

## Model-Only Generation

### Generating Just Models

Use `--global-property models` to generate only data models:

```bash
# TypeScript interfaces only
openapi-generator-cli generate \
  -i openapi.yaml \
  -g typescript-axios \
  -o ./src/types \
  --global-property models,modelTests=false,modelDocs=false \
  --additional-properties=withInterfaces=true

# Python Pydantic models only
openapi-generator-cli generate \
  -i openapi.yaml \
  -g python \
  -o ./src/models \
  --global-property models,modelTests=false,modelDocs=false \
  --additional-properties=pydanticV2=true

# Java models only
openapi-generator-cli generate \
  -i openapi.yaml \
  -g java \
  -o ./src/models \
  --global-property models,modelTests=false,modelDocs=false \
  --additional-properties=\
library=jackson,\
dateLibrary=java8,\
useJakartaEe=true

# Specific models only
openapi-generator-cli generate \
  -i openapi.yaml \
  -g java \
  -o ./src/models \
  --global-property models=User:Order:Product
```

### Use Cases for Model-Only

1. **Shared types** between client and server in monorepos.
2. **Event schemas** for message queues (generate model from schema, serialize/deserialize).
3. **Database models** as a starting point (then add ORM annotations).
4. **Cross-language consistency** — same schema generates matching models in each language.

---

## Custom Templates

### Template Engine (Mustache)

openapi-generator uses Mustache templates. Each generator has a set of templates that control output.

### Extracting Default Templates

```bash
# Extract templates for a specific generator
openapi-generator-cli author template \
  -g typescript-axios \
  -o ./templates/typescript-axios

# This creates files like:
# templates/typescript-axios/
# ├── api.mustache
# ├── apiInner.mustache
# ├── configuration.mustache
# ├── modelGeneric.mustache
# └── ...
```

### Modifying Templates

```bash
# 1. Extract templates
openapi-generator-cli author template -g java -o ./my-templates

# 2. Edit templates (e.g., add logging to all API methods)
# Edit ./my-templates/api.mustache

# 3. Generate with custom templates
openapi-generator-cli generate \
  -i openapi.yaml \
  -g java \
  -o ./output \
  -t ./my-templates    # use custom template directory
```

**Example: Adding a custom header to TypeScript API calls:**

```mustache
{{! In apiInner.mustache, find the request method and add: }}
// Auto-generated - do not edit
// Generated from: {{appName}} v{{appVersion}}
// Spec version: {{openAPI.info.version}}

{{#operations}}
{{#operation}}
    /**
     * {{summary}}
     {{#notes}}
     * {{.}}
     {{/notes}}
     */
    public {{operationIdCamelCase}}({{#allParams}}{{paramName}}{{^required}}?{{/required}}: {{{dataType}}}, {{/allParams}}options?: AxiosRequestConfig) {
        return {{classname}}Fp(this.configuration).{{operationIdCamelCase}}({{#allParams}}{{paramName}}, {{/allParams}}options).then((request) => request(this.axios, this.basePath));
    }
{{/operation}}
{{/operations}}
```

### Template Variables

Common variables available in templates:

| Variable | Description |
|----------|-------------|
| `{{classname}}` | Generated class name |
| `{{operationId}}` | Operation ID from spec |
| `{{httpMethod}}` | HTTP method (GET, POST, etc.) |
| `{{path}}` | API path |
| `{{allParams}}` | All parameters |
| `{{bodyParam}}` | Request body parameter |
| `{{returnType}}` | Response type |
| `{{#hasParams}}...{{/hasParams}}` | Conditional: has parameters |
| `{{#required}}...{{/required}}` | Conditional: parameter is required |
| `{{vendorExtensions.x-*}}` | Custom x- extensions from spec |

---

## Configuration Files

### YAML Configuration

```yaml
# openapi-generator-config.yaml
generatorName: typescript-axios
inputSpec: ./openapi.yaml
outputDir: ./src/api-client
additionalProperties:
  supportsES6: true
  npmName: "@myorg/api-client"
  npmVersion: "1.0.0"
  withInterfaces: true
  useSingleRequestParameter: true
typeMappings:
  DateTime: string
  date: string
importMappings:
  DateTime: null
modelNameMappings:
  Error: ApiError
reservedWordsMappings:
  class: classField
globalProperties:
  models: ""
  apis: ""
  modelDocs: "false"
  apiDocs: "false"
  modelTests: "false"
  apiTests: "false"
```

```bash
openapi-generator-cli generate -c openapi-generator-config.yaml
```

### JSON Configuration

```json
{
  "generatorName": "typescript-axios",
  "inputSpec": "./openapi.yaml",
  "outputDir": "./src/api-client",
  "additionalProperties": {
    "supportsES6": true,
    "npmName": "@myorg/api-client",
    "npmVersion": "1.0.0",
    "withInterfaces": true
  },
  "typeMappings": {
    "DateTime": "string"
  },
  "modelNameMappings": {
    "Error": "ApiError"
  }
}
```

### Configuration Priority

When the same option is set in multiple places, this is the precedence (highest to lowest):

1. CLI flags (`--additional-properties`)
2. Configuration file (`-c config.yaml`)
3. Generator defaults

---

## Post-Processing Hooks

### Built-in Formatters

openapi-generator can run formatters after generation:

```bash
# Enable post-processing
export JAVA_POST_PROCESS_FILE="google-java-format -i"
export PYTHON_POST_PROCESS_FILE="black"
export GO_POST_PROCESS_FILE="gofmt -w"
export TS_POST_PROCESS_FILE="prettier --write"

# Or in config
# In config.yaml:
# enablePostProcessFile: true
```

### Custom Post-Processing

**Script-based post-processing:**

```bash
#!/bin/bash
# post-generate.sh

GENERATED_DIR="./src/api-client"

# Run the generator
openapi-generator-cli generate -c config.yaml

# Post-processing steps:
# 1. Format code
npx prettier --write "$GENERATED_DIR/**/*.ts"

# 2. Remove unwanted files
rm -f "$GENERATED_DIR/.openapi-generator-ignore"
rm -rf "$GENERATED_DIR/.openapi-generator"

# 3. Add license header
for f in "$GENERATED_DIR"/**/*.ts; do
  if ! head -1 "$f" | grep -q "Copyright"; then
    echo "// Copyright $(date +%Y) MyOrg. Auto-generated, do not edit." | cat - "$f" > temp && mv temp "$f"
  fi
done

# 4. Fix known issues
# Replace deprecated imports
sed -i 's/from "url"/from "node:url"/g' "$GENERATED_DIR"/**/*.ts 2>/dev/null || true

# 5. Compile to verify
cd "$GENERATED_DIR" && npx tsc --noEmit
```

**Using `.openapi-generator-ignore`:**

Place in the output directory to prevent overwriting custom files:

```
# .openapi-generator-ignore
# Don't overwrite manual customizations
src/custom/**
README.md
package.json
```

---

## Custom Generators

### Creating a Generator Project

```bash
# Scaffold a new generator project
openapi-generator-cli meta \
  -o ./my-generator \
  -n my-custom-generator \
  -p com.example.codegen

# Structure:
# my-generator/
# ├── pom.xml
# ├── src/main/java/com/example/codegen/
# │   ├── MyCustomGeneratorGenerator.java
# │   └── ...
# └── src/main/resources/
#     └── my-custom-generator/
#         ├── api.mustache
#         ├── model.mustache
#         └── ...
```

### Generator Extension Points

```java
public class MyCustomGeneratorGenerator extends DefaultCodegen implements CodegenConfig {

    @Override
    public String getName() {
        return "my-custom-generator";
    }

    @Override
    public CodegenType getTag() {
        return CodegenType.CLIENT;
    }

    @Override
    public String toModelName(String name) {
        // Customize model naming
        return super.toModelName(name) + "Model";
    }

    @Override
    public String toApiName(String name) {
        // Customize API class naming
        return name + "Service";
    }

    @Override
    public Map<String, Object> postProcessModels(Map<String, Object> objs) {
        // Add custom data to template context
        Map<String, Object> results = super.postProcessModels(objs);
        // Custom logic here
        return results;
    }

    @Override
    public void processOpts() {
        super.processOpts();
        // Configure file generation
        supportingFiles.add(new SupportingFile("README.mustache", "", "README.md"));
        modelTemplateFiles.put("model.mustache", ".ts");
        apiTemplateFiles.put("api.mustache", ".ts");
    }
}
```

```bash
# Build and use the custom generator
cd my-generator && mvn package
openapi-generator-cli generate \
  -i openapi.yaml \
  -g my-custom-generator \
  -o ./output \
  --classpath ./my-generator/target/my-custom-generator-1.0.0.jar
```

---

## Alternatives to openapi-generator

### swagger-codegen

The original code generator, now maintained by SmartBear. openapi-generator is a fork that has surpassed it.

```bash
# Install
brew install swagger-codegen
# Or
docker pull swaggerapi/swagger-codegen-cli

# Generate
swagger-codegen generate -i openapi.yaml -l python -o ./output

# Key difference from openapi-generator:
# - Uses -l (language) instead of -g (generator)
# - Fewer generators and less active development
# - Still useful for Swagger 2.0 specs
```

**When to use swagger-codegen:**
- Legacy projects locked to specific swagger-codegen versions.
- Swagger 2.0 specs that have issues with openapi-generator.
- Corporate environments where swagger-codegen is the approved tool.

### autorest

Microsoft's code generator, strong for Azure and C#/.NET projects.

```bash
# Install
npm install -g autorest

# Generate C# client
autorest --input-file=openapi.yaml \
  --csharp \
  --output-folder=./csharp-client \
  --namespace=MyApi.Client

# Generate TypeScript
autorest --input-file=openapi.yaml \
  --typescript \
  --output-folder=./ts-client

# Generate Python
autorest --input-file=openapi.yaml \
  --python \
  --output-folder=./python-client \
  --package-name=my_api_client
```

**Strengths:**
- Best-in-class C#/.NET generation.
- Azure API integration.
- Extension system for customization.

**Weaknesses:**
- Fewer language targets than openapi-generator.
- Configuration can be complex.
- Primarily Microsoft-focused ecosystem.

### openapi-typescript

Type-only generation for TypeScript — no runtime dependencies, just types.

```bash
# Install and run
npx openapi-typescript openapi.yaml -o ./src/types/api.ts

# Or install globally
npm install -g openapi-typescript
openapi-typescript openapi.yaml -o types.ts
```

**Generated output:**

```typescript
export interface paths {
  "/users/{userId}": {
    get: operations["getUserById"];
    put: operations["updateUser"];
  };
}

export interface components {
  schemas: {
    User: {
      id: string;
      email: string;
      name: string | null;
    };
  };
}

export interface operations {
  getUserById: {
    parameters: {
      path: { userId: string };
    };
    responses: {
      200: {
        content: {
          "application/json": components["schemas"]["User"];
        };
      };
    };
  };
}
```

**Using with openapi-fetch (companion library):**

```typescript
import createClient from 'openapi-fetch';
import type { paths } from './types/api';

const client = createClient<paths>({ baseUrl: 'https://api.example.com' });

const { data, error } = await client.GET('/users/{userId}', {
  params: { path: { userId: '123' } },
});
// data is fully typed as components["schemas"]["User"]
```

**Strengths:**
- Zero runtime overhead (types only).
- Excellent TypeScript inference.
- Works with any HTTP client via openapi-fetch.
- Fast and simple.

**Weaknesses:**
- TypeScript only.
- No runtime validation.
- Types-only output requires manual API call implementation (unless using openapi-fetch).

### orval

React/Vue-focused TypeScript client generator with built-in hooks.

```bash
# Install
npm install -D orval

# Configure (orval.config.ts)
export default defineConfig({
  petstore: {
    input: './openapi.yaml',
    output: {
      target: './src/api/endpoints',
      schemas: './src/api/models',
      client: 'react-query',       # or 'swr', 'vue-query', 'axios', 'fetch'
      mode: 'tags-split',
    },
  },
});

# Generate
npx orval
```

**Strengths:**
- First-class React Query / SWR / Vue Query support.
- Generates custom hooks per operation.
- Mock service worker (MSW) handler generation.
- Zod schema generation for runtime validation.

### hey-api

Modern TypeScript-first code generator.

```bash
npm install -D @hey-api/openapi-ts

# Configure (hey-api.config.ts)
export default {
  input: './openapi.yaml',
  output: './src/api',
  plugins: [
    '@hey-api/client-fetch',
    '@hey-api/schemas',
    '@hey-api/types',
  ],
};

npx @hey-api/openapi-ts
```

**Strengths:**
- Tree-shakeable output.
- Multiple HTTP client options (fetch, axios).
- Plugin architecture.
- Zod schema generation.

### kiota

Microsoft's next-generation API client generator.

```bash
# Install
dotnet tool install --global Microsoft.OpenApi.Kiota

# Generate TypeScript client
kiota generate -l typescript \
  -d openapi.yaml \
  -o ./src/api-client \
  -c ApiClient \
  -n MyApi

# Generate Python client
kiota generate -l python \
  -d openapi.yaml \
  -o ./api_client

# Generate C# client
kiota generate -l csharp \
  -d openapi.yaml \
  -o ./ApiClient \
  -n MyApi.Client
```

**Strengths:**
- Language-agnostic design.
- Incremental generation (only regenerate changed parts).
- First-class support for Microsoft Graph-style APIs.
- Small, focused output (no monolithic SDK).

**Supported languages:** C#, Go, Java, PHP, Python, Ruby, Swift, TypeScript.

### Comparison Matrix

| Feature | openapi-generator | swagger-codegen | autorest | openapi-typescript | orval | kiota |
|---------|:---:|:---:|:---:|:---:|:---:|:---:|
| Languages | 50+ | 40+ | ~10 | TS only | TS only | 8 |
| OAS 3.1 | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ |
| OAS 3.0 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Swagger 2.0 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Custom templates | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| React hooks | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| Runtime types | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Tree-shaking | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| Mock generation | ❌ | ❌ | ❌ | ❌ | ✅ (MSW) | ❌ |
| Active maintenance | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ |
| Config complexity | Medium | Medium | High | Low | Low | Medium |

**Recommendations:**
- **Multi-language needs:** openapi-generator (widest language support).
- **TypeScript type safety:** openapi-typescript + openapi-fetch.
- **React/Vue with hooks:** orval (best DX for frontend frameworks).
- **C#/.NET:** kiota or autorest (Microsoft ecosystem integration).
- **Maximum customization:** openapi-generator with custom templates.
- **Simplest setup:** openapi-typescript (zero config, types only).
