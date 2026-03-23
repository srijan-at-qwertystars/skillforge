#!/usr/bin/env bash
set -euo pipefail

# create-hono-app.sh — Scaffold a Hono project with runtime choice, TypeScript, and common middleware
# Usage: ./create-hono-app.sh [project-name] [--runtime <runtime>] [--with-openapi] [--with-auth]

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_NAME=""
RUNTIME=""
WITH_OPENAPI=false
WITH_AUTH=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [project-name] [options]

Options:
  --runtime <runtime>   Target runtime: cloudflare-workers | bun | deno | nodejs | aws-lambda | vercel
  --with-openapi        Include @hono/zod-openapi + Swagger UI setup
  --with-auth           Include JWT authentication middleware
  -h, --help            Show this help

Examples:
  $(basename "$0") my-api --runtime bun
  $(basename "$0") my-api --runtime cloudflare-workers --with-openapi --with-auth
  $(basename "$0") my-api  # interactive runtime selection
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) RUNTIME="$2"; shift 2 ;;
    --with-openapi) WITH_OPENAPI=true; shift ;;
    --with-auth) WITH_AUTH=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) PROJECT_NAME="$1"; shift ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  read -rp "Project name: " PROJECT_NAME
fi

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Error: project name required"
  exit 1
fi

RUNTIMES=("cloudflare-workers" "bun" "deno" "nodejs" "aws-lambda" "vercel")

if [[ -z "$RUNTIME" ]]; then
  echo -e "${BLUE}Select a runtime:${NC}"
  select rt in "${RUNTIMES[@]}"; do
    if [[ -n "$rt" ]]; then
      RUNTIME="$rt"
      break
    fi
  done
fi

# Validate runtime
VALID=false
for rt in "${RUNTIMES[@]}"; do
  [[ "$rt" == "$RUNTIME" ]] && VALID=true
done
if [[ "$VALID" != "true" ]]; then
  echo "Error: invalid runtime '$RUNTIME'. Choose from: ${RUNTIMES[*]}"
  exit 1
fi

echo -e "${BLUE}Creating Hono project: ${GREEN}$PROJECT_NAME${NC} (runtime: ${YELLOW}$RUNTIME${NC})"

mkdir -p "$PROJECT_NAME/src"
cd "$PROJECT_NAME"

# --- package.json ---
cat > package.json <<PKGJSON
{
  "name": "$PROJECT_NAME",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "$(case "$RUNTIME" in
      cloudflare-workers) echo "wrangler dev" ;;
      bun) echo "bun run --hot src/index.ts" ;;
      deno) echo "deno run --watch --allow-net --allow-read --allow-env src/index.ts" ;;
      nodejs) echo "npx tsx --watch src/index.ts" ;;
      aws-lambda) echo "npx tsx src/local.ts" ;;
      vercel) echo "npx vercel dev" ;;
    esac)",
    "build": "$(case "$RUNTIME" in
      cloudflare-workers) echo "wrangler deploy --dry-run" ;;
      bun) echo "bun build src/index.ts --target=bun --outdir=./dist" ;;
      nodejs|aws-lambda) echo "npx tsc" ;;
      deno) echo "echo 'No build step needed for Deno'" ;;
      vercel) echo "npx vercel build" ;;
    esac)",
    "test": "vitest run"
  }
}
PKGJSON

# --- tsconfig.json ---
cat > tsconfig.json <<TSCONFIG
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "./dist",
    "rootDir": "./src",
    "jsx": "react-jsx",
    "jsxImportSource": "hono/jsx",
    "types": [$(case "$RUNTIME" in
      cloudflare-workers) echo '"@cloudflare/workers-types"' ;;
      bun) echo '"bun-types"' ;;
      *) echo "" ;;
    esac)]
  },
  "include": ["src/**/*"]
}
TSCONFIG

# --- .gitignore ---
cat > .gitignore <<GITIGNORE
node_modules/
dist/
.wrangler/
.vercel/
*.log
GITIGNORE

# --- Entry point ---
generate_entry() {
  local imports=""
  local middleware=""
  local entry_suffix=""

  imports+="import { Hono } from 'hono'
import { logger } from 'hono/logger'
import { cors } from 'hono/cors'
import { secureHeaders } from 'hono/secure-headers'
import { prettyJSON } from 'hono/pretty-json'
import { timing } from 'hono/timing'
"

  if $WITH_AUTH; then
    imports+="import { jwt } from 'hono/jwt'
"
  fi

  if $WITH_OPENAPI; then
    imports+="import { OpenAPIHono, createRoute, z } from '@hono/zod-openapi'
import { swaggerUI } from '@hono/swagger-ui'

const app = new OpenAPIHono()
"
  else
    imports+="
const app = new Hono()
"
  fi

  middleware+="
// Global middleware
app.use('*', logger())
app.use('*', cors())
app.use('*', secureHeaders())
app.use('*', prettyJSON())
app.use('*', timing())
"

  if $WITH_AUTH; then
    middleware+="
// JWT auth on /api/* routes (set JWT_SECRET env var)
// app.use('/api/*', jwt({ secret: process.env.JWT_SECRET ?? 'dev-secret' }))
"
  fi

  # Routes
  local routes=""
  if $WITH_OPENAPI; then
    routes+="
// OpenAPI route example
const healthRoute = createRoute({
  method: 'get',
  path: '/health',
  responses: {
    200: {
      content: { 'application/json': { schema: z.object({ status: z.string(), uptime: z.number() }) } },
      description: 'Health check',
    },
  },
})

app.openapi(healthRoute, (c) => {
  return c.json({ status: 'ok', uptime: process.uptime?.() ?? 0 }, 200)
})

// Swagger UI
app.doc('/doc', { openapi: '3.1.0', info: { title: '$PROJECT_NAME', version: '0.1.0' } })
app.get('/ui', swaggerUI({ url: '/doc' }))
"
  else
    routes+="
// Routes
app.get('/', (c) => c.json({ message: 'Hello Hono!', runtime: '${RUNTIME}' }))
app.get('/health', (c) => c.json({ status: 'ok' }))
"
  fi

  # Error handling
  local errors="
// Error handling
app.onError((err, c) => {
  console.error(err)
  return c.json({ error: 'Internal Server Error' }, 500)
})
app.notFound((c) => c.json({ error: 'Not Found' }, 404))
"

  # Runtime-specific export
  case "$RUNTIME" in
    cloudflare-workers)
      entry_suffix="
export default app
" ;;
    bun)
      entry_suffix="
export default {
  fetch: app.fetch,
  port: parseInt(process.env.PORT ?? '3000'),
}

console.log('Server running on http://localhost:\${process.env.PORT ?? 3000}')
" ;;
    deno)
      entry_suffix="
Deno.serve({ port: 3000 }, app.fetch)
console.log('Server running on http://localhost:3000')
" ;;
    nodejs)
      imports="import { serve } from '@hono/node-server'
${imports}"
      entry_suffix="
const port = parseInt(process.env.PORT ?? '3000')
serve({ fetch: app.fetch, port }, () => {
  console.log(\`Server running on http://localhost:\${port}\`)
})
" ;;
    aws-lambda)
      imports="import { handle } from 'hono/aws-lambda'
${imports}"
      entry_suffix="
export const handler = handle(app)
" ;;
    vercel)
      imports="import { handle } from 'hono/vercel'
${imports}"
      entry_suffix="
export const GET = handle(app)
export const POST = handle(app)
export const PUT = handle(app)
export const DELETE = handle(app)
" ;;
  esac

  echo "${imports}${middleware}${routes}${errors}${entry_suffix}"
}

generate_entry > src/index.ts

# --- wrangler.toml for Cloudflare ---
if [[ "$RUNTIME" == "cloudflare-workers" ]]; then
  cat > wrangler.toml <<WRANGLER
name = "$PROJECT_NAME"
main = "src/index.ts"
compatibility_date = "2024-01-01"

# [vars]
# MY_VAR = "value"

# [[kv_namespaces]]
# binding = "MY_KV"
# id = "<kv-namespace-id>"

# [[d1_databases]]
# binding = "DB"
# database_name = "my-db"
# database_id = "<d1-database-id>"
WRANGLER
fi

# --- Test file ---
mkdir -p src/__tests__
cat > src/__tests__/index.test.ts <<TEST
import { describe, it, expect } from 'vitest'
import app from '../index'

describe('Health check', () => {
  it('GET /health returns ok', async () => {
    const res = await app.request('/health')
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.status).toBe('ok')
  })

  it('unknown route returns 404', async () => {
    const res = await app.request('/nonexistent')
    expect(res.status).toBe(404)
  })
})
TEST

echo ""
echo -e "${GREEN}✔ Project created: $PROJECT_NAME${NC}"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"

if [[ "$RUNTIME" == "deno" ]]; then
  echo "  # Add deno.json with import map for 'hono' → 'npm:hono'"
else
  echo "  npm install hono"
  [[ "$RUNTIME" == "nodejs" ]] && echo "  npm install @hono/node-server"
  [[ "$RUNTIME" == "aws-lambda" ]] && echo "  npm install @hono/aws-lambda"
  [[ "$RUNTIME" == "vercel" ]] && echo "  npm install @hono/vercel"
  [[ "$RUNTIME" == "cloudflare-workers" ]] && echo "  npm install -D wrangler @cloudflare/workers-types"
  $WITH_OPENAPI && echo "  npm install @hono/zod-openapi @hono/swagger-ui zod"
  echo "  npm install -D vitest tsx typescript"
fi

echo "  npm run dev"
