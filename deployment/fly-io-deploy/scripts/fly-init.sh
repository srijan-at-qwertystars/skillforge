#!/usr/bin/env bash
#
# fly-init.sh — Initialize a Fly.io application
#
# Usage:
#   ./fly-init.sh <app-name> [framework]
#
# Arguments:
#   app-name    Required. Name for the Fly.io app (must be globally unique).
#   framework   Optional. One of: node, rails, django, flask, go, static.
#               If omitted, auto-detects from project files.
#
# Examples:
#   ./fly-init.sh my-api node
#   ./fly-init.sh my-site              # auto-detect
#   ./fly-init.sh my-rails-app rails
#
# What it does:
#   1. Detects framework if not specified
#   2. Generates fly.toml with sensible defaults
#   3. Generates Dockerfile if not present
#   4. Configures health checks
#   5. Prints next steps
#
# Prerequisites:
#   - flyctl installed and authenticated (fly auth login)
#   - Run from the project root directory

set -euo pipefail

APP_NAME="${1:-}"
FRAMEWORK="${2:-}"

if [[ -z "$APP_NAME" ]]; then
  echo "Error: app name is required."
  echo "Usage: $0 <app-name> [framework]"
  exit 1
fi

# --- Framework Detection ---

detect_framework() {
  if [[ -f "package.json" ]]; then
    if grep -q '"next"' package.json 2>/dev/null; then
      echo "nextjs"
    elif grep -q '"remix"' package.json 2>/dev/null; then
      echo "remix"
    else
      echo "node"
    fi
  elif [[ -f "Gemfile" ]]; then
    echo "rails"
  elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]] || [[ -f "Pipfile" ]]; then
    if grep -qi "django" requirements.txt pyproject.toml Pipfile 2>/dev/null; then
      echo "django"
    elif grep -qi "flask" requirements.txt pyproject.toml Pipfile 2>/dev/null; then
      echo "flask"
    elif grep -qi "fastapi" requirements.txt pyproject.toml Pipfile 2>/dev/null; then
      echo "fastapi"
    else
      echo "python"
    fi
  elif [[ -f "go.mod" ]]; then
    echo "go"
  elif [[ -f "index.html" ]]; then
    echo "static"
  else
    echo "unknown"
  fi
}

if [[ -z "$FRAMEWORK" ]]; then
  FRAMEWORK=$(detect_framework)
  echo "Auto-detected framework: $FRAMEWORK"
else
  echo "Using specified framework: $FRAMEWORK"
fi

# --- Port and Command Defaults ---

case "$FRAMEWORK" in
  node|nextjs|remix)
    INTERNAL_PORT=3000
    CMD='["node", "server.js"]'
    DOCKERFILE_BASE="node:20-slim"
    INSTALL_CMD="npm ci --production"
    BUILD_CMD="npm run build"
    ;;
  rails)
    INTERNAL_PORT=3000
    CMD='["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]'
    DOCKERFILE_BASE="ruby:3.3-slim"
    INSTALL_CMD="bundle install --without development test"
    BUILD_CMD="bin/rails assets:precompile"
    ;;
  django)
    INTERNAL_PORT=8000
    CMD='["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000"]'
    DOCKERFILE_BASE="python:3.12-slim"
    INSTALL_CMD="pip install --no-cache-dir -r requirements.txt"
    BUILD_CMD="python manage.py collectstatic --noinput"
    ;;
  flask|fastapi|python)
    INTERNAL_PORT=8080
    CMD='["gunicorn", "app:app", "--bind", "0.0.0.0:8080"]'
    DOCKERFILE_BASE="python:3.12-slim"
    INSTALL_CMD="pip install --no-cache-dir -r requirements.txt"
    BUILD_CMD=""
    ;;
  go)
    INTERNAL_PORT=8080
    CMD='["./server"]'
    DOCKERFILE_BASE="golang:1.22-alpine"
    INSTALL_CMD=""
    BUILD_CMD="go build -o server ."
    ;;
  static)
    INTERNAL_PORT=80
    CMD=""
    DOCKERFILE_BASE="nginx:alpine"
    INSTALL_CMD=""
    BUILD_CMD=""
    ;;
  *)
    INTERNAL_PORT=8080
    CMD='["./start.sh"]'
    DOCKERFILE_BASE="debian:bookworm-slim"
    INSTALL_CMD=""
    BUILD_CMD=""
    ;;
esac

# --- Generate fly.toml ---

if [[ -f "fly.toml" ]]; then
  echo "fly.toml already exists. Skipping generation."
else
  cat > fly.toml <<EOF
app = "${APP_NAME}"
primary_region = "iad"

[build]
  dockerfile = "Dockerfile"

[deploy]
  strategy = "rolling"

[http_service]
  internal_port = ${INTERNAL_PORT}
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1

  [http_service.concurrency]
    type = "requests"
    soft_limit = 200
    hard_limit = 250

  [[http_service.checks]]
    grace_period = "30s"
    interval = "15s"
    method = "GET"
    timeout = "5s"
    path = "/health"

[env]
  PORT = "${INTERNAL_PORT}"

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
EOF
  echo "Created fly.toml"
fi

# --- Generate Dockerfile ---

if [[ -f "Dockerfile" ]]; then
  echo "Dockerfile already exists. Skipping generation."
else
  case "$FRAMEWORK" in
    node|nextjs|remix)
      cat > Dockerfile <<'DEOF'
FROM node:20-slim AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup --system app && adduser --system --ingroup app app
COPY --from=builder /app/package*.json ./
RUN npm ci --production && npm cache clean --force
COPY --from=builder /app/dist ./dist
USER app
EXPOSE 3000
CMD ["node", "dist/server.js"]
DEOF
      ;;
    rails)
      cat > Dockerfile <<'DEOF'
FROM ruby:3.3-slim AS builder
WORKDIR /app
RUN apt-get update -qq && apt-get install -y build-essential libpq-dev
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test
COPY . .
RUN SECRET_KEY_BASE=placeholder bin/rails assets:precompile

FROM ruby:3.3-slim
WORKDIR /app
RUN apt-get update -qq && apt-get install -y libpq5 curl && rm -rf /var/lib/apt/lists/*
RUN addgroup --system app && adduser --system --ingroup app app
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /app /app
USER app
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
DEOF
      ;;
    django)
      cat > Dockerfile <<'DEOF'
FROM python:3.12-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y build-essential libpq-dev && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN python manage.py collectstatic --noinput

FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y libpq5 curl && rm -rf /var/lib/apt/lists/*
RUN addgroup --system app && adduser --system --ingroup app app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /app /app
USER app
EXPOSE 8000
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "2"]
DEOF
      ;;
    go)
      cat > Dockerfile <<'DEOF'
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o server .

FROM alpine:3.19
WORKDIR /app
RUN apk --no-cache add ca-certificates curl
RUN addgroup -S app && adduser -S app -G app
COPY --from=builder /app/server ./
USER app
EXPOSE 8080
CMD ["./server"]
DEOF
      ;;
    static)
      cat > Dockerfile <<'DEOF'
FROM nginx:alpine
COPY . /usr/share/nginx/html
COPY <<'NGINX' /etc/nginx/conf.d/default.conf
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    location /health { return 200 'ok'; add_header Content-Type text/plain; }
    location / { try_files $uri $uri/ /index.html; }
}
NGINX
EXPOSE 80
DEOF
      ;;
    *)
      cat > Dockerfile <<DEOF
FROM ${DOCKERFILE_BASE}
WORKDIR /app
COPY . .
EXPOSE ${INTERNAL_PORT}
CMD ${CMD}
DEOF
      ;;
  esac
  echo "Created Dockerfile"
fi

# --- Generate .dockerignore ---

if [[ ! -f ".dockerignore" ]]; then
  cat > .dockerignore <<'EOF'
.git
node_modules
.env
.env.*
*.log
tmp/
.cache/
coverage/
.fly/
EOF
  echo "Created .dockerignore"
fi

# --- Summary ---

echo ""
echo "============================================"
echo "  Fly.io app initialized: ${APP_NAME}"
echo "  Framework: ${FRAMEWORK}"
echo "  Internal port: ${INTERNAL_PORT}"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Review fly.toml and Dockerfile"
echo "  2. Ensure your app has a GET /health endpoint returning 200"
echo "  3. Run: fly launch --name ${APP_NAME} --no-deploy --copy-config"
echo "  4. Run: fly deploy"
echo "  5. Run: fly status"
