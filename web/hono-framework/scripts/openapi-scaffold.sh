#!/usr/bin/env bash
set -euo pipefail

# openapi-scaffold.sh — Generate OpenAPI-documented Hono routes from an OpenAPI spec
# Usage: ./openapi-scaffold.sh <spec-file> [--output <dir>] [--base-path <path>]

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SPEC_FILE=""
OUTPUT_DIR="./src/routes"
BASE_PATH=""

usage() {
  cat <<EOF
Usage: $(basename "$0") <openapi-spec.json|yaml> [options]

Generate Hono route files with @hono/zod-openapi from an OpenAPI 3.x spec.

Options:
  --output <dir>        Output directory for generated routes (default: ./src/routes)
  --base-path <path>    Base path prefix for all routes (default: none)
  -h, --help            Show this help

Examples:
  $(basename "$0") api-spec.json
  $(basename "$0") api-spec.yaml --output ./src/api --base-path /api/v1

Requirements:
  - Node.js 18+ or Bun
  - jq (for JSON processing)
  - yq (optional, for YAML specs)

The generator creates:
  - One route file per OpenAPI tag (or path group)
  - Zod schemas from JSON Schema definitions
  - Swagger UI endpoint
  - An index.ts that combines all routes
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --base-path) BASE_PATH="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) SPEC_FILE="$1"; shift ;;
  esac
done

if [[ -z "$SPEC_FILE" ]]; then
  echo -e "${RED}Error: OpenAPI spec file required${NC}"
  usage
fi

if [[ ! -f "$SPEC_FILE" ]]; then
  echo -e "${RED}Error: File not found: $SPEC_FILE${NC}"
  exit 1
fi

# Check dependencies
for cmd in jq node; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: '$cmd' is required but not installed${NC}"
    exit 1
  fi
done

# Convert YAML to JSON if needed
SPEC_JSON=""
if [[ "$SPEC_FILE" == *.yaml ]] || [[ "$SPEC_FILE" == *.yml ]]; then
  if command -v yq &>/dev/null; then
    SPEC_JSON=$(yq -o=json '.' "$SPEC_FILE")
  elif command -v python3 &>/dev/null; then
    SPEC_JSON=$(python3 -c "
import sys, json, yaml
with open('$SPEC_FILE') as f:
    json.dump(yaml.safe_load(f), sys.stdout)
" 2>/dev/null || true)
  fi
  if [[ -z "$SPEC_JSON" ]]; then
    echo -e "${RED}Error: Cannot parse YAML. Install 'yq' or 'python3 + pyyaml'${NC}"
    exit 1
  fi
else
  SPEC_JSON=$(cat "$SPEC_FILE")
fi

# Extract spec info
TITLE=$(echo "$SPEC_JSON" | jq -r '.info.title // "API"')
VERSION=$(echo "$SPEC_JSON" | jq -r '.info.version // "1.0.0"')
PATHS=$(echo "$SPEC_JSON" | jq -r '.paths | keys[]' 2>/dev/null || true)

if [[ -z "$PATHS" ]]; then
  echo -e "${RED}Error: No paths found in spec${NC}"
  exit 1
fi

PATH_COUNT=$(echo "$PATHS" | wc -l | tr -d ' ')
echo -e "${BLUE}Scaffolding from: ${GREEN}$TITLE v$VERSION${NC} ($PATH_COUNT paths)"

mkdir -p "$OUTPUT_DIR"

# Generate a route file using Node.js for proper JSON processing
node --input-type=module <<NODEJS
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';

const spec = ${SPEC_JSON};
const outputDir = '${OUTPUT_DIR}';
const basePath = '${BASE_PATH}';

// Group paths by tag
const groups = {};
for (const [path, methods] of Object.entries(spec.paths || {})) {
  for (const [method, op] of Object.entries(methods)) {
    if (['get','post','put','patch','delete'].includes(method)) {
      const tag = op.tags?.[0] || 'default';
      if (!groups[tag]) groups[tag] = [];
      groups[tag].push({ path, method, op });
    }
  }
}

function jsonSchemaToZod(schema, name) {
  if (!schema) return 'z.any()';
  if (schema.\$ref) {
    const refName = schema.\$ref.split('/').pop();
    return refName + 'Schema';
  }
  switch (schema.type) {
    case 'string':
      let s = 'z.string()';
      if (schema.format === 'email') s += '.email()';
      if (schema.format === 'uuid') s += '.uuid()';
      if (schema.format === 'uri' || schema.format === 'url') s += '.url()';
      if (schema.minLength) s += \`.min(\${schema.minLength})\`;
      if (schema.maxLength) s += \`.max(\${schema.maxLength})\`;
      if (schema.enum) s = \`z.enum([\${schema.enum.map(e => \`'\${e}'\`).join(', ')}])\`;
      return s;
    case 'number':
    case 'integer':
      let n = schema.type === 'integer' ? 'z.number().int()' : 'z.number()';
      if (schema.minimum !== undefined) n += \`.min(\${schema.minimum})\`;
      if (schema.maximum !== undefined) n += \`.max(\${schema.maximum})\`;
      return n;
    case 'boolean':
      return 'z.boolean()';
    case 'array':
      return \`z.array(\${jsonSchemaToZod(schema.items)})\`;
    case 'object': {
      const props = Object.entries(schema.properties || {}).map(([key, val]) => {
        const required = schema.required?.includes(key);
        const zodType = jsonSchemaToZod(val);
        return \`  \${key}: \${zodType}\${required ? '' : '.optional()'}\`;
      });
      return \`z.object({\n\${props.join(',\\n')}\n})\`;
      }
    default:
      return 'z.any()';
  }
}

// Generate schema definitions
const schemas = spec.components?.schemas || {};
let schemaCode = '';
for (const [name, schema] of Object.entries(schemas)) {
  schemaCode += \`export const \${name}Schema = \${jsonSchemaToZod(schema, name)}.openapi('\${name}')\\n\\n\`;
}

if (schemaCode) {
  writeFileSync(join(outputDir, 'schemas.ts'), \`import { z } from '@hono/zod-openapi'\\n\\n\${schemaCode}\`);
  console.log('  Created: schemas.ts');
}

// Generate route files per tag
const routeFiles = [];

for (const [tag, endpoints] of Object.entries(groups)) {
  const fileName = tag.toLowerCase().replace(/[^a-z0-9]+/g, '-') + '.ts';
  routeFiles.push({ tag, fileName });

  let code = \`import { OpenAPIHono, createRoute, z } from '@hono/zod-openapi'\\n\`;
  if (schemaCode) code += \`import * as schemas from './schemas'\\n\`;
  code += \`\\nconst app = new OpenAPIHono()\\n\\n\`;

  for (const { path, method, op } of endpoints) {
    const operationId = op.operationId || \`\${method}\${path.replace(/[^a-zA-Z]/g, '_')}\`;
    const honoPath = path.replace(/\{([^}]+)\}/g, ':$1');

    // Build request schema
    let requestSchema = '';
    const params = (op.parameters || []).filter(p => p.in === 'path');
    const queryParams = (op.parameters || []).filter(p => p.in === 'query');

    if (params.length) {
      const paramProps = params.map(p =>
        \`    \${p.name}: z.string().openapi({ param: { name: '\${p.name}', in: 'path' } })\`
      ).join(',\\n');
      requestSchema += \`    params: z.object({\\n\${paramProps}\\n    }),\\n\`;
    }
    if (queryParams.length) {
      const qProps = queryParams.map(p =>
        \`    \${p.name}: \${jsonSchemaToZod(p.schema || { type: 'string' })}\${p.required ? '' : '.optional()'}.openapi({ param: { name: '\${p.name}', in: 'query' } })\`
      ).join(',\\n');
      requestSchema += \`    query: z.object({\\n\${qProps}\\n    }),\\n\`;
    }
    if (op.requestBody) {
      const jsonContent = op.requestBody.content?.['application/json'];
      if (jsonContent?.schema) {
        requestSchema += \`    body: { content: { 'application/json': { schema: \${jsonSchemaToZod(jsonContent.schema)} } } },\\n\`;
      }
    }

    // Build responses
    let responsesCode = '';
    for (const [status, resp] of Object.entries(op.responses || {})) {
      const jsonResp = resp.content?.['application/json'];
      if (jsonResp?.schema) {
        responsesCode += \`    \${status}: {
      content: { 'application/json': { schema: \${jsonSchemaToZod(jsonResp.schema)} } },
      description: '\${(resp.description || '').replace(/'/g, "\\\\'")}',
    },\\n\`;
      } else {
        responsesCode += \`    \${status}: { description: '\${(resp.description || 'Response').replace(/'/g, "\\\\'")}' },\\n\`;
      }
    }

    code += \`// \${op.summary || operationId}
const \${operationId}Route = createRoute({
  method: '\${method}',
  path: '\${honoPath}',
  tags: ['\${tag}'],\${requestSchema ? \`
  request: {
\${requestSchema}  },\` : ''}
  responses: {
\${responsesCode}  },
})

app.openapi(\${operationId}Route, (c) => {
  // TODO: implement \${operationId}
  return c.json({ message: 'Not implemented' } as any, 200 as any)
})

\`;
  }

  code += \`export default app\\n\`;
  writeFileSync(join(outputDir, fileName), code);
  console.log(\`  Created: \${fileName} (\${endpoints.length} endpoints)\`);
}

// Generate index.ts that mounts all route files
let indexCode = \`import { OpenAPIHono } from '@hono/zod-openapi'
import { swaggerUI } from '@hono/swagger-ui'

\`;

for (const { tag, fileName } of routeFiles) {
  const importName = tag.toLowerCase().replace(/[^a-z0-9]+/g, '_') + 'Routes';
  indexCode += \`import \${importName} from './\${fileName.replace('.ts', '')}'\n\`;
}

indexCode += \`
const app = new OpenAPIHono()
\`;

for (const { tag, fileName } of routeFiles) {
  const importName = tag.toLowerCase().replace(/[^a-z0-9]+/g, '_') + 'Routes';
  const routePath = basePath || '';
  indexCode += \`app.route('\${routePath}', \${importName})\n\`;
}

indexCode += \`
// OpenAPI spec + Swagger UI
app.doc('/doc', {
  openapi: '3.1.0',
  info: { title: '${TITLE}', version: '${VERSION}' },
})
app.get('/ui', swaggerUI({ url: '/doc' }))

export default app
\`;

writeFileSync(join(outputDir, 'index.ts'), indexCode);
console.log('  Created: index.ts (combined router)');
NODEJS

echo ""
echo -e "${GREEN}✔ Scaffolding complete!${NC}"
echo ""
echo "Generated files in: $OUTPUT_DIR"
echo ""
echo "Install dependencies:"
echo "  npm install hono @hono/zod-openapi @hono/swagger-ui zod"
echo ""
echo "Then import the router in your main app:"
echo "  import api from '${OUTPUT_DIR}/index'"
echo "  app.route('/', api)"
