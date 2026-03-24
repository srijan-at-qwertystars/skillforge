# Multi-stage Dockerfile optimized for Cloud Run
#
# Features:
# - Multi-stage build (small final image)
# - Non-root user
# - Distroless base for minimal attack surface
# - Listens on $PORT (Cloud Run contract)
#
# Adapt the build stage for your language/framework.

# ============================================================
# Stage 1: Build
# ============================================================
FROM golang:1.23-alpine AS builder
# For Node.js: FROM node:22-alpine AS builder
# For Python: FROM python:3.12-slim AS builder

WORKDIR /app

# Cache dependencies
COPY go.mod go.sum ./
RUN go mod download
# Node.js: COPY package.json package-lock.json ./
#           RUN npm ci --production
# Python:  COPY requirements.txt ./
#           RUN pip install --no-cache-dir --target=/deps -r requirements.txt

# Copy source and build
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /app/server .
# Node.js: RUN npm run build (if applicable)
# Python:  (no build step needed)

# ============================================================
# Stage 2: Runtime
# ============================================================
FROM gcr.io/distroless/static-debian12:nonroot
# For Node.js: FROM gcr.io/distroless/nodejs22-debian12:nonroot
# For Python:  FROM gcr.io/distroless/python3-debian12:nonroot
# For general: FROM gcr.io/distroless/base-debian12:nonroot

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/server /app/server
# Node.js: COPY --from=builder /app/node_modules ./node_modules
#           COPY --from=builder /app/dist ./dist
#           COPY --from=builder /app/package.json .
# Python:  COPY --from=builder /deps /deps
#           COPY . .
#           ENV PYTHONPATH=/deps

# Cloud Run injects PORT env var (default 8080)
ENV PORT=8080
EXPOSE 8080

# Run as non-root (distroless nonroot UID=65534)
USER nonroot

# Start the application
ENTRYPOINT ["/app/server"]
# Node.js: CMD ["dist/index.js"]
# Python:  ENTRYPOINT ["python3", "app.py"]
