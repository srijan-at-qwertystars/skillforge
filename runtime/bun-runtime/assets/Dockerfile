# Multi-stage Bun Dockerfile — Production optimized
#
# Usage:
#   docker build -t my-bun-app .
#   docker run -p 3000:3000 my-bun-app
#
# Build args:
#   BUN_VERSION — Bun version (default: 1)
#   NODE_ENV    — Environment (default: production)

ARG BUN_VERSION=1

# ─── Stage 1: Base ───────────────────────────────────────────────
FROM oven/bun:${BUN_VERSION} AS base
WORKDIR /app
ENV NODE_ENV=production

# ─── Stage 2: Install production dependencies ────────────────────
FROM base AS deps
COPY package.json bun.lock ./

# Install production-only dependencies
RUN bun install \
    --frozen-lockfile \
    --production \
    --ignore-scripts

# ─── Stage 3: Install all dependencies and build ─────────────────
FROM base AS build
COPY package.json bun.lock ./

# Install all dependencies (including devDependencies for build)
RUN bun install --frozen-lockfile

# Copy source code
COPY . .

# Type check (optional — remove if not using TypeScript strictly)
# RUN bunx tsc --noEmit

# Build the application
RUN bun build \
    ./src/index.ts \
    --outdir ./dist \
    --target bun \
    --minify \
    --sourcemap=external

# ─── Stage 4: Production image ───────────────────────────────────
FROM base AS production

# Copy production node_modules from deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy built application from build stage
COPY --from=build /app/dist ./dist

# Copy static assets if needed (uncomment as needed)
# COPY --from=build /app/public ./public

# Don't run as root
USER bun

# Expose the application port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD bun -e "fetch('http://localhost:3000/health').then(r=>{if(!r.ok)throw 1}).catch(()=>process.exit(1))"

# Start the application
CMD ["bun", "run", "dist/index.js"]
