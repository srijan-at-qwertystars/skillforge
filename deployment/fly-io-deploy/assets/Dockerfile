# Multi-stage Dockerfile optimized for Fly.io
#
# Features:
#   - Multi-stage build for minimal final image
#   - Non-root user for security
#   - Health check endpoint
#   - Fly.io-compatible port and binding
#   - Layer caching optimized for fast rebuilds
#
# Customize the base images and commands for your framework.

# ============================================================
# Stage 1: Install dependencies
# ============================================================
FROM node:20-slim AS deps
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts && npm cache clean --force

# ============================================================
# Stage 2: Build application
# ============================================================
FROM node:20-slim AS builder
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

ENV NODE_ENV=production
RUN npm run build

# ============================================================
# Stage 3: Production image
# ============================================================
FROM node:20-slim AS production
WORKDIR /app

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    dumb-init \
  && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd --system app && useradd --system --gid app app

# Copy built application
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

# Create data directory for volumes
RUN mkdir -p /data && chown app:app /data

# Environment
ENV NODE_ENV=production
ENV PORT=8080
ENV HOST=0.0.0.0

# Switch to non-root user
USER app

# Expose the port matching fly.toml internal_port
EXPOSE 8080

# Health check (used by Docker, Fly has its own checks too)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

# Use dumb-init to handle signals properly (clean shutdown on SIGTERM)
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/server.js"]
