#!/usr/bin/env bash
# setup-vapor-project.sh — Scaffold a new Vapor 4.x project with common dependencies
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
PROJECT_NAME="${1:-MyVaporApp}"
SWIFT_VERSION="${SWIFT_VERSION:-5.9}"
DB_DRIVER="${DB_DRIVER:-postgres}"    # postgres, mysql, sqlite, mongo
INCLUDE_JWT="${INCLUDE_JWT:-true}"
INCLUDE_REDIS="${INCLUDE_REDIS:-true}"
INCLUDE_LEAF="${INCLUDE_LEAF:-false}"
INCLUDE_QUEUES="${INCLUDE_QUEUES:-false}"
SETUP_DOCKER="${SETUP_DOCKER:-true}"

echo "╔══════════════════════════════════════════════════╗"
echo "║  Vapor 4.x Project Scaffolder                   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Project:     ${PROJECT_NAME}"
echo "Swift:       ${SWIFT_VERSION}"
echo "DB Driver:   ${DB_DRIVER}"
echo "JWT:         ${INCLUDE_JWT}"
echo "Redis:       ${INCLUDE_REDIS}"
echo "Leaf:        ${INCLUDE_LEAF}"
echo "Queues:      ${INCLUDE_QUEUES}"
echo "Docker:      ${SETUP_DOCKER}"
echo ""

# ─── Check Prerequisites ────────────────────────────────────────
check_command() {
    if ! command -v "$1" &>/dev/null; then
        echo "⚠️  $1 not found. $2"
        return 1
    fi
    echo "✅ $1 found: $(command -v "$1")"
    return 0
}

echo "==> Checking prerequisites..."
check_command swift "Install Swift from https://swift.org/download/" || exit 1

# Install Vapor toolbox if not present
if ! command -v vapor &>/dev/null; then
    echo "==> Installing Vapor toolbox..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install vapor
    else
        # Linux: build from source
        git clone https://github.com/vapor/toolbox.git /tmp/vapor-toolbox
        cd /tmp/vapor-toolbox
        git checkout latest
        swift build -c release
        sudo mv .build/release/vapor /usr/local/bin/
        cd -
        rm -rf /tmp/vapor-toolbox
    fi
fi
check_command vapor "Failed to install Vapor toolbox" || exit 1

# ─── Create Project ─────────────────────────────────────────────
echo ""
echo "==> Creating Vapor project: ${PROJECT_NAME}..."
if [ -d "${PROJECT_NAME}" ]; then
    echo "❌ Directory ${PROJECT_NAME} already exists. Aborting."
    exit 1
fi

vapor new "${PROJECT_NAME}" --no-fluent --no-leaf -n
cd "${PROJECT_NAME}"

# ─── Build Package.swift ────────────────────────────────────────
echo "==> Generating Package.swift with dependencies..."

DEPS=""
TARGET_DEPS=""

# Core Vapor
DEPS+=".package(url: \"https://github.com/vapor/vapor.git\", from: \"4.89.0\"),"
TARGET_DEPS+=".product(name: \"Vapor\", package: \"vapor\"),"

# Fluent
DEPS+=".package(url: \"https://github.com/vapor/fluent.git\", from: \"4.9.0\"),"
TARGET_DEPS+=".product(name: \"Fluent\", package: \"fluent\"),"

# Database driver
case "${DB_DRIVER}" in
    postgres)
        DEPS+=".package(url: \"https://github.com/vapor/fluent-postgres-driver.git\", from: \"2.8.0\"),"
        TARGET_DEPS+=".product(name: \"FluentPostgresDriver\", package: \"fluent-postgres-driver\"),"
        ;;
    mysql)
        DEPS+=".package(url: \"https://github.com/vapor/fluent-mysql-driver.git\", from: \"4.4.0\"),"
        TARGET_DEPS+=".product(name: \"FluentMySQLDriver\", package: \"fluent-mysql-driver\"),"
        ;;
    sqlite)
        DEPS+=".package(url: \"https://github.com/vapor/fluent-sqlite-driver.git\", from: \"4.6.0\"),"
        TARGET_DEPS+=".product(name: \"FluentSQLiteDriver\", package: \"fluent-sqlite-driver\"),"
        ;;
    mongo)
        DEPS+=".package(url: \"https://github.com/vapor/fluent-mongo-driver.git\", from: \"1.3.0\"),"
        TARGET_DEPS+=".product(name: \"FluentMongoDriver\", package: \"fluent-mongo-driver\"),"
        ;;
esac

# JWT
if [ "${INCLUDE_JWT}" = "true" ]; then
    DEPS+=".package(url: \"https://github.com/vapor/jwt.git\", from: \"4.2.0\"),"
    TARGET_DEPS+=".product(name: \"JWT\", package: \"jwt\"),"
fi

# Redis
if [ "${INCLUDE_REDIS}" = "true" ]; then
    DEPS+=".package(url: \"https://github.com/vapor/redis.git\", from: \"4.10.0\"),"
    TARGET_DEPS+=".product(name: \"Redis\", package: \"redis\"),"
fi

# Leaf
if [ "${INCLUDE_LEAF}" = "true" ]; then
    DEPS+=".package(url: \"https://github.com/vapor/leaf.git\", from: \"4.3.0\"),"
    TARGET_DEPS+=".product(name: \"Leaf\", package: \"leaf\"),"
fi

# Queues
if [ "${INCLUDE_QUEUES}" = "true" ]; then
    DEPS+=".package(url: \"https://github.com/vapor/queues.git\", from: \"1.13.0\"),"
    TARGET_DEPS+=".product(name: \"Queues\", package: \"queues\"),"
    DEPS+=".package(url: \"https://github.com/vapor/queues-redis-driver.git\", from: \"1.1.0\"),"
    TARGET_DEPS+=".product(name: \"QueuesRedisDriver\", package: \"queues-redis-driver\"),"
fi

# Remove trailing commas for valid Swift array syntax
DEPS=$(echo "$DEPS" | sed 's/,$//')
TARGET_DEPS=$(echo "$TARGET_DEPS" | sed 's/,$//')

cat > Package.swift << SWIFT
// swift-tools-version:${SWIFT_VERSION}
import PackageDescription

let package = Package(
    name: "${PROJECT_NAME}",
    platforms: [.macOS(.v13)],
    dependencies: [
        ${DEPS}
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                ${TARGET_DEPS}
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
SWIFT

echo "✅ Package.swift generated"

# ─── Create Directory Structure ─────────────────────────────────
echo "==> Creating project structure..."
mkdir -p Sources/App/{Controllers,Models,Migrations,DTOs,Middleware}
mkdir -p Tests/AppTests
mkdir -p Public
mkdir -p Resources/Views

# ─── Create .env File ───────────────────────────────────────────
cat > .env << 'ENV'
# Database
DB_HOST=localhost
DB_PORT=5432
DB_USER=vapor
DB_PASS=vapor
DB_NAME=vapor_db

# JWT
JWT_SECRET=change-me-in-production-use-a-long-random-string

# Redis
REDIS_URL=redis://127.0.0.1:6379

# App
LOG_LEVEL=info
ENV

cat > .env.testing << 'ENV'
DB_HOST=localhost
DB_PORT=5432
DB_USER=vapor
DB_PASS=vapor
DB_NAME=vapor_test_db
LOG_LEVEL=debug
ENV

echo "✅ Environment files created"

# ─── Docker Setup ───────────────────────────────────────────────
if [ "${SETUP_DOCKER}" = "true" ]; then
    echo "==> Setting up Docker development environment..."

    cat > Dockerfile << 'DOCKERFILE'
# ── Build Stage ──
FROM swift:5.9-jammy AS build
WORKDIR /app
COPY Package.swift Package.resolved* ./
RUN swift package resolve
COPY . .
RUN swift build -c release --static-swift-stdlib

# ── Runtime Stage ──
FROM ubuntu:jammy
RUN useradd --create-home --shell /bin/bash vapor
RUN apt-get update && apt-get install -y \
    libcurl4 libxml2 tzdata ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/.build/release/App .
COPY --from=build /app/Public ./Public
COPY --from=build /app/Resources ./Resources
USER vapor
EXPOSE 8080
ENTRYPOINT ["./App", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
DOCKERFILE

    cat > docker-compose.yml << 'COMPOSE'
version: "3.8"
services:
  app:
    build: .
    ports:
      - "8080:8080"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    environment:
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: vapor
      DB_PASS: vapor
      DB_NAME: vapor_db
      REDIS_URL: redis://redis:6379
    env_file:
      - .env

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: vapor
      POSTGRES_PASSWORD: vapor
      POSTGRES_DB: vapor_db
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U vapor -d vapor_db"]
      interval: 5s
      timeout: 3s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redisdata:/data

volumes:
  pgdata:
  redisdata:
COMPOSE

    cat > .dockerignore << 'IGNORE'
.build
.git
*.o
*.swp
.DS_Store
Packages
Tests
IGNORE

    echo "✅ Docker files created"
fi

# ─── Create .gitignore ──────────────────────────────────────────
cat > .gitignore << 'GITIGNORE'
.DS_Store
.build/
Packages/
*.xcodeproj
xcuserdata/
DerivedData/
.swiftpm/
Package.resolved
.env
.env.testing
GITIGNORE

# ─── Resolve Dependencies ───────────────────────────────────────
echo ""
echo "==> Resolving Swift package dependencies..."
swift package resolve

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✅ Project ${PROJECT_NAME} created!             "
echo "╠══════════════════════════════════════════════════╣"
echo "║  Next steps:                                    ║"
echo "║  1. cd ${PROJECT_NAME}                           "
echo "║  2. docker compose up -d db redis               ║"
echo "║  3. swift run App serve                         ║"
echo "║  4. Visit http://localhost:8080                 ║"
echo "╚══════════════════════════════════════════════════╝"
