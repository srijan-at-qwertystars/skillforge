#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# init-fastify.sh — Scaffold a production-ready Fastify project with TypeScript
#
# Usage:
#   ./init-fastify.sh <project-name>
#   ./init-fastify.sh my-api
#
# Creates:
#   <project-name>/
#     src/
#       app.ts           — Fastify instance factory (testable, no listen)
#       server.ts        — Entry point (listen + graceful shutdown)
#       plugins/         — Autoloaded plugins (db, auth, etc.)
#         sensible.ts    — @fastify/sensible plugin
#       routes/          — Autoloaded route plugins
#         health.ts      — Health check route
#       schemas/         — Shared JSON Schema / Zod schemas
#       types/
#         fastify.d.ts   — Declaration merging for custom decorators
#     tsconfig.json
#     .eslintrc.json
#     package.json
#     .gitignore
#     .env.example
#     Dockerfile
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT_NAME="${1:?Usage: $0 <project-name>}"

if [ -d "$PROJECT_NAME" ]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Scaffolding Fastify project: $PROJECT_NAME"

mkdir -p "$PROJECT_NAME/src"/{plugins,routes,schemas,types}
cd "$PROJECT_NAME"

# ── package.json ──────────────────────────────────────────────────────────────
cat > package.json <<'PKGJSON'
{
  "name": "PLACEHOLDER_NAME",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/server.ts",
    "build": "tsc",
    "start": "node dist/server.js",
    "lint": "eslint src/",
    "test": "node --test --loader tsx 'src/**/*.test.ts'"
  },
  "engines": {
    "node": ">=20.0.0"
  }
}
PKGJSON
sed -i "s/PLACEHOLDER_NAME/$PROJECT_NAME/" package.json

# ── tsconfig.json ─────────────────────────────────────────────────────────────
cat > tsconfig.json <<'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "outDir": "dist",
    "rootDir": "src",
    "declaration": true,
    "sourceMap": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

# ── .eslintrc.json ────────────────────────────────────────────────────────────
cat > .eslintrc.json <<'ESLINT'
{
  "root": true,
  "parser": "@typescript-eslint/parser",
  "plugins": ["@typescript-eslint"],
  "extends": [
    "eslint:recommended",
    "plugin:@typescript-eslint/recommended"
  ],
  "env": { "node": true, "es2022": true },
  "rules": {
    "@typescript-eslint/no-unused-vars": ["warn", { "argsIgnorePattern": "^_" }],
    "no-console": "warn"
  }
}
ESLINT

# ── .gitignore ────────────────────────────────────────────────────────────────
cat > .gitignore <<'GITIGNORE'
node_modules/
dist/
.env
*.log
.DS_Store
GITIGNORE

# ── .env.example ──────────────────────────────────────────────────────────────
cat > .env.example <<'ENVEX'
PORT=3000
HOST=0.0.0.0
LOG_LEVEL=info
NODE_ENV=development
DATABASE_URL=postgresql://user:pass@localhost:5432/mydb
JWT_SECRET=change-me-in-production
ENVEX

# ── src/types/fastify.d.ts ───────────────────────────────────────────────────
cat > src/types/fastify.d.ts <<'TYPES'
import 'fastify';

declare module 'fastify' {
  interface FastifyInstance {
    // Add custom instance decorators here
    // db: import('pg').Pool;
    // config: { jwtSecret: string };
  }
  interface FastifyRequest {
    // Add custom request decorators here
    // user: { id: string; role: string } | null;
  }
}
TYPES

# ── src/app.ts ────────────────────────────────────────────────────────────────
cat > src/app.ts <<'APPTS'
import Fastify, { FastifyServerOptions } from 'fastify';
import autoLoad from '@fastify/autoload';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export function buildApp(opts: FastifyServerOptions = {}) {
  const app = Fastify(opts);

  // Load plugins first (db, auth, etc.)
  app.register(autoLoad, {
    dir: join(__dirname, 'plugins'),
    forceESM: true,
  });

  // Then load routes
  app.register(autoLoad, {
    dir: join(__dirname, 'routes'),
    dirNameRoutePrefix: true,
    forceESM: true,
  });

  return app;
}
APPTS

# ── src/server.ts ─────────────────────────────────────────────────────────────
cat > src/server.ts <<'SERVERTS'
import { buildApp } from './app.js';

const app = buildApp({
  logger: {
    level: process.env.LOG_LEVEL || 'info',
    transport: process.env.NODE_ENV !== 'production'
      ? { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss' } }
      : undefined,
  },
});

const port = parseInt(process.env.PORT || '3000', 10);
const host = process.env.HOST || '0.0.0.0';

await app.listen({ port, host });

// Graceful shutdown
async function shutdown(signal: string) {
  app.log.info({ signal }, 'shutting down');
  await app.close();
  process.exit(0);
}

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => shutdown(signal));
}
SERVERTS

# ── src/plugins/sensible.ts ──────────────────────────────────────────────────
cat > src/plugins/sensible.ts <<'SENSIBLE'
import fp from 'fastify-plugin';
import sensible from '@fastify/sensible';

export default fp(async (fastify) => {
  await fastify.register(sensible);
}, { name: 'sensible' });
SENSIBLE

# ── src/routes/health.ts ─────────────────────────────────────────────────────
cat > src/routes/health.ts <<'HEALTH'
import { FastifyPluginAsync } from 'fastify';

const healthRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.get('/health', {
    schema: {
      response: {
        200: {
          type: 'object',
          properties: {
            status: { type: 'string' },
            uptime: { type: 'number' },
          },
        },
      },
    },
  }, async () => ({
    status: 'ok',
    uptime: process.uptime(),
  }));
};

export default healthRoutes;
HEALTH

# ── Dockerfile ────────────────────────────────────────────────────────────────
cat > Dockerfile <<'DOCKERFILE'
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY package*.json ./
ENV NODE_ENV=production
EXPOSE 3000
USER node
CMD ["node", "dist/server.js"]
DOCKERFILE

echo ""
echo "✅ Project scaffolded: $PROJECT_NAME/"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm install"
echo "  npm install fastify @fastify/autoload @fastify/sensible fastify-plugin"
echo "  npm install -D typescript @types/node tsx pino-pretty @typescript-eslint/parser @typescript-eslint/eslint-plugin eslint"
echo "  cp .env.example .env"
echo "  npm run dev"
