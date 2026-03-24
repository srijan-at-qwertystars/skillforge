#!/usr/bin/env bash
# init-worker.sh — Initialize a new Cloudflare Worker project
#
# Usage:
#   ./init-worker.sh <project-name> [--bindings kv,d1,r2,do,queue] [--hono] [--dir <path>]
#
# Examples:
#   ./init-worker.sh my-api
#   ./init-worker.sh my-api --bindings kv,d1,r2 --hono
#   ./init-worker.sh my-api --bindings do,queue --dir ./workers
#
# Creates a Worker project with:
#   - TypeScript + ES Modules
#   - wrangler.toml configured with requested bindings
#   - Typed Env interface for all bindings
#   - vitest + @cloudflare/vitest-pool-workers
#   - Optional Hono framework setup

set -euo pipefail

# --- Defaults ---
PROJECT_NAME=""
BINDINGS=""
USE_HONO=false
TARGET_DIR="."

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --bindings) BINDINGS="$2"; shift 2 ;;
    --hono) USE_HONO=true; shift ;;
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --help|-h)
      head -14 "$0" | tail -12
      exit 0
      ;;
    *)
      if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME="$1"
      else
        echo "Error: Unknown argument '$1'" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Error: Project name required. Usage: $0 <project-name> [options]" >&2
  exit 1
fi

PROJECT_DIR="${TARGET_DIR}/${PROJECT_NAME}"

echo "🚀 Initializing Worker: ${PROJECT_NAME}"

# --- Create project directory ---
mkdir -p "${PROJECT_DIR}/src" "${PROJECT_DIR}/test"
cd "${PROJECT_DIR}"

# --- Initialize package.json ---
cat > package.json <<EOF
{
  "name": "${PROJECT_NAME}",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev",
    "dev:remote": "wrangler dev --remote",
    "deploy": "wrangler deploy",
    "deploy:staging": "wrangler deploy --env staging",
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit",
    "tail": "wrangler tail",
    "lint": "eslint src/ test/"
  }
}
EOF

# --- Install dependencies ---
echo "📦 Installing dependencies..."
npm install --save-dev wrangler typescript @cloudflare/workers-types \
  vitest @cloudflare/vitest-pool-workers 2>/dev/null

if $USE_HONO; then
  npm install hono 2>/dev/null
  npm install --save-dev @hono/zod-validator zod 2>/dev/null
fi

# --- TypeScript config ---
cat > tsconfig.json <<EOF
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ESNext"],
    "types": ["@cloudflare/workers-types/2023-07-01", "@cloudflare/vitest-pool-workers"],
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "react-jsx",
    "jsxImportSource": "hono/jsx"
  },
  "include": ["src/**/*.ts", "test/**/*.ts"],
  "exclude": ["node_modules"]
}
EOF

# --- Parse bindings ---
IFS=',' read -ra BINDING_LIST <<< "${BINDINGS}"

HAS_KV=false; HAS_D1=false; HAS_R2=false; HAS_DO=false; HAS_QUEUE=false
for b in "${BINDING_LIST[@]}"; do
  case "$b" in
    kv) HAS_KV=true ;;
    d1) HAS_D1=true ;;
    r2) HAS_R2=true ;;
    do) HAS_DO=true ;;
    queue) HAS_QUEUE=true ;;
  esac
done

# --- Generate wrangler.toml ---
cat > wrangler.toml <<EOF
name = "${PROJECT_NAME}"
main = "src/index.ts"
compatibility_date = "2024-09-23"
compatibility_flags = ["nodejs_compat"]
EOF

if $HAS_KV; then
  cat >> wrangler.toml <<'EOF'

[[kv_namespaces]]
binding = "KV"
id = "<KV_NAMESPACE_ID>"  # Run: npx wrangler kv namespace create KV
EOF
fi

if $HAS_D1; then
  cat >> wrangler.toml <<'EOF'

[[d1_databases]]
binding = "DB"
database_name = "<DB_NAME>"  # Run: npx wrangler d1 create <DB_NAME>
database_id = "<DB_ID>"
migrations_dir = "migrations"
EOF
  mkdir -p migrations
fi

if $HAS_R2; then
  cat >> wrangler.toml <<'EOF'

[[r2_buckets]]
binding = "BUCKET"
bucket_name = "<BUCKET_NAME>"  # Run: npx wrangler r2 bucket create <BUCKET_NAME>
EOF
fi

if $HAS_DO; then
  cat >> wrangler.toml <<'EOF'

[[durable_objects.bindings]]
name = "MY_OBJECT"
class_name = "MyDurableObject"

[[migrations]]
tag = "v1"
new_classes = ["MyDurableObject"]
EOF
fi

if $HAS_QUEUE; then
  cat >> wrangler.toml <<'EOF'

[[queues.producers]]
binding = "MY_QUEUE"
queue = "<QUEUE_NAME>"  # Run: npx wrangler queues create <QUEUE_NAME>

[[queues.consumers]]
queue = "<QUEUE_NAME>"
max_batch_size = 10
max_batch_timeout = 5
EOF
fi

# Staging environment
cat >> wrangler.toml <<'EOF'

[env.staging]
EOF
echo "name = \"${PROJECT_NAME}-staging\"" >> wrangler.toml

# --- Generate Env types ---
{
  echo "// Auto-generated binding types — update when wrangler.toml changes"
  echo "export interface Env {"
  $HAS_KV    && echo "  KV: KVNamespace;"
  $HAS_D1    && echo "  DB: D1Database;"
  $HAS_R2    && echo "  BUCKET: R2Bucket;"
  $HAS_DO    && echo "  MY_OBJECT: DurableObjectNamespace;"
  $HAS_QUEUE && echo "  MY_QUEUE: Queue;"
  echo "}"
} > src/types.ts

# --- Generate main entry ---
if $USE_HONO; then
  cat > src/index.ts <<'EOF'
import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./types";

type AppEnv = { Bindings: Env };

const app = new Hono<AppEnv>();

app.use("*", cors());

app.get("/", (c) => c.json({ status: "ok" }));

app.get("/health", (c) =>
  c.json({ status: "healthy", timestamp: new Date().toISOString() })
);

export default app;
EOF
else
  cat > src/index.ts <<'EOF'
import type { Env } from "./types";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      return Response.json({ status: "ok" });
    }

    if (url.pathname === "/health") {
      return Response.json({ status: "healthy", timestamp: new Date().toISOString() });
    }

    return new Response("Not Found", { status: 404 });
  },
};
EOF
fi

# --- Generate Durable Object if requested ---
if $HAS_DO; then
  cat > src/durable-object.ts <<'EOF'
import type { Env } from "./types";

export class MyDurableObject extends DurableObject {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    switch (url.pathname) {
      case "/get": {
        const value = await this.ctx.storage.get("value");
        return Response.json({ value });
      }
      case "/set": {
        const body = await request.json<{ value: unknown }>();
        await this.ctx.storage.put("value", body.value);
        return Response.json({ success: true });
      }
      default:
        return new Response("Not Found", { status: 404 });
    }
  }
}
EOF
fi

# --- Generate vitest config ---
cat > vitest.config.ts <<'EOF'
import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersProject({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          compatibilityDate: "2024-09-23",
          compatibilityFlags: ["nodejs_compat"],
        },
      },
    },
  },
});
EOF

# --- Generate test file ---
if $USE_HONO; then
  cat > test/index.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import app from "../src/index";

describe("Worker", () => {
  it("GET / returns ok", async () => {
    const res = await app.request("/", {}, env);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
  });

  it("GET /health returns healthy", async () => {
    const res = await app.request("/health", {}, env);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("healthy");
  });
});
EOF
else
  cat > test/index.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import worker from "../src/index";

describe("Worker", () => {
  it("GET / returns ok", async () => {
    const req = new Request("https://example.com/");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
  });

  it("GET /health returns healthy", async () => {
    const req = new Request("https://example.com/health");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);
  });

  it("returns 404 for unknown routes", async () => {
    const req = new Request("https://example.com/unknown");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(404);
  });
});
EOF
fi

# --- Create .dev.vars ---
cat > .dev.vars <<'EOF'
# Local development secrets (do NOT commit this file)
# API_KEY=your-local-dev-key
EOF

# --- Create .gitignore ---
cat > .gitignore <<'EOF'
node_modules/
dist/
.wrangler/
.dev.vars
*.log
EOF

echo ""
echo "✅ Worker '${PROJECT_NAME}' initialized at ${PROJECT_DIR}"
echo ""
echo "📁 Structure:"
find . -type f -not -path './node_modules/*' -not -path './.git/*' | sort | sed 's|^./|  |'
echo ""
echo "🔧 Next steps:"
echo "  cd ${PROJECT_DIR}"
echo "  npx wrangler dev          # Start local dev server"
echo "  npm test                  # Run tests"
if $HAS_KV; then echo "  npx wrangler kv namespace create KV   # Create KV namespace, update wrangler.toml"; fi
if $HAS_D1; then echo "  npx wrangler d1 create <name>         # Create D1 database, update wrangler.toml"; fi
if $HAS_R2; then echo "  npx wrangler r2 bucket create <name>  # Create R2 bucket, update wrangler.toml"; fi
