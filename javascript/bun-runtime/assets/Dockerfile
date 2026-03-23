# ──────────────────────────────────────────────────────────────────
# Dockerfile — Optimized multi-stage build for Bun applications
#
# Usage:
#   docker build -t my-bun-app .
#   docker run -p 3000:3000 my-bun-app
#
# Build args:
#   BUN_VERSION — Bun version tag (default: 1)
# ──────────────────────────────────────────────────────────────────

# ── Stage 1: Install dependencies ────────────────────────────────
FROM oven/bun:${BUN_VERSION:-1} AS deps

WORKDIR /app

# Copy only dependency files for layer caching
COPY package.json bun.lockb ./

# Install production dependencies only
RUN bun install --frozen-lockfile --production

# ── Stage 2: Build (if needed) ───────────────────────────────────
FROM oven/bun:${BUN_VERSION:-1} AS build

WORKDIR /app

# Copy all deps (including devDependencies for build tools)
COPY package.json bun.lockb ./
RUN bun install --frozen-lockfile

# Copy source code
COPY . .

# Build step (uncomment if your app has a build step)
# RUN bun run build

# ── Stage 3: Production runtime ─────────────────────────────────
FROM oven/bun:${BUN_VERSION:-1}-alpine AS runtime

WORKDIR /app

# Don't run as root
USER bun

# Copy production deps from stage 1
COPY --from=deps --chown=bun:bun /app/node_modules ./node_modules

# Copy application code
# Option A: Copy source (runs TypeScript directly)
COPY --chown=bun:bun package.json ./
COPY --chown=bun:bun src ./src

# Option B: Copy build output (uncomment if using build step)
# COPY --from=build --chown=bun:bun /app/dist ./dist

EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bun -e "fetch('http://localhost:3000/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

# Run the application
CMD ["bun", "run", "src/index.ts"]
