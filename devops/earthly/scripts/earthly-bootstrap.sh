#!/bin/bash
# earthly-bootstrap.sh - Bootstrap a new Earthfile in a project

set -e

PROJECT_TYPE="${1:-generic}"

echo "Bootstrapping Earthfile for $PROJECT_TYPE project..."

if [[ -f "Earthfile" ]]; then
    echo "Earthfile already exists. Aborting."
    exit 1
fi

case "$PROJECT_TYPE" in
    go|golang)
        cat > Earthfile << 'EOF'
VERSION 0.8

deps:
    FROM golang:1.21-alpine
    WORKDIR /app
    COPY go.mod go.sum ./
    RUN --mount=type=cache,target=/go/pkg/mod go mod download

build:
    FROM +deps
    COPY . .
    RUN go build -o bin/app ./cmd/app
    SAVE ARTIFACT bin/app

test:
    FROM +deps
    COPY . .
    RUN go test -v ./...

docker:
    FROM gcr.io/distroless/static:nonroot
    COPY +build/app /usr/local/bin/
    USER nonroot:nonroot
    ENTRYPOINT ["/usr/local/bin/app"]
    SAVE IMAGE --push myapp:latest
EOF
        ;;
    node|nodejs|js)
        cat > Earthfile << 'EOF'
VERSION 0.8

deps:
    FROM node:20-alpine
    WORKDIR /app
    COPY package*.json ./
    RUN --mount=type=cache,target=/root/.npm npm ci

build:
    FROM +deps
    COPY . .
    RUN npm run build
    SAVE ARTIFACT dist/

test:
    FROM +deps
    COPY . .
    RUN npm test

docker:
    FROM node:20-alpine
    WORKDIR /app
    COPY package*.json ./
    RUN --mount=type=cache,target=/root/.npm npm ci --production
    COPY +build/dist ./dist
    EXPOSE 3000
    CMD ["node", "dist/main.js"]
    SAVE IMAGE --push myapp:latest
EOF
        ;;
    python|py)
        cat > Earthfile << 'EOF'
VERSION 0.8

deps:
    FROM python:3.11-slim
    WORKDIR /app
    COPY requirements.txt ./
    RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt

build:
    FROM +deps
    COPY . .
    RUN python -m compileall .

test:
    FROM +deps
    COPY . .
    RUN python -m pytest

docker:
    FROM python:3.11-slim
    WORKDIR /app
    COPY requirements.txt ./
    RUN pip install --no-cache-dir -r requirements.txt
    COPY . .
    EXPOSE 8000
    CMD ["python", "-m", "app"]
    SAVE IMAGE --push myapp:latest
EOF
        ;;
    *)
        cat > Earthfile << 'EOF'
VERSION 0.8

build:
    FROM alpine:3.19
    WORKDIR /app
    COPY . .
    RUN echo "Building..."
    SAVE ARTIFACT . AS LOCAL ./output

docker:
    FROM alpine:3.19
    WORKDIR /app
    COPY +build/ ./
    CMD ["echo", "Hello from Earthly!"]
    SAVE IMAGE --push myapp:latest
EOF
        ;;
esac

echo "✓ Created Earthfile for $PROJECT_TYPE project"
echo ""
echo "Available targets:"
earthly ls
