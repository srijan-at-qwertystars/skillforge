# Language-Specific Dockerfile Patterns

Optimized Dockerfile patterns for Rust, Java, .NET, PHP, Ruby, and Elixir. Each section provides a complete, production-ready Dockerfile with annotations.

## Table of Contents

- [Rust](#rust)
- [Java](#java)
- [.NET](#net)
- [PHP](#php)
- [Ruby](#ruby)
- [Elixir](#elixir)

---

## Rust

### Challenge

Rust builds are slow. `cargo build` recompiles all dependencies when any source file changes because Cargo doesn't separate dependency compilation from application compilation by default.

### Solution: cargo-chef Pattern

[cargo-chef](https://github.com/LukeMathWalker/cargo-chef) extracts a dependency-only build plan, enabling cached dependency compilation.

```dockerfile
# syntax=docker/dockerfile:1

# --- Stage 1: Generate a recipe.json that captures dependency info ---
FROM rust:1.83-slim AS chef
RUN cargo install cargo-chef --locked
WORKDIR /app

FROM chef AS planner
COPY . .
# Analyze the project and produce a recipe (like a lockfile for build caching)
RUN cargo chef prepare --recipe-path recipe.json

# --- Stage 2: Build dependencies (cached unless Cargo.toml/Cargo.lock change) ---
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# Build ONLY dependencies — this layer is cached until deps change
RUN cargo chef cook --release --recipe-path recipe.json
# Now copy source and build the application
COPY . .
RUN cargo build --release --bin myapp

# --- Stage 3: Minimal runtime image ---
FROM debian:bookworm-slim AS runtime
RUN groupadd -r app && useradd -r -g app -u 1001 app
# Install runtime dependencies only (OpenSSL, CA certs if needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libssl3 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/myapp /usr/local/bin/myapp
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD ["/usr/local/bin/myapp", "--healthcheck"]
ENTRYPOINT ["/usr/local/bin/myapp"]
```

### Static Binary Variant (musl, scratch image)

```dockerfile
# syntax=docker/dockerfile:1

FROM rust:1.83-slim AS chef
RUN cargo install cargo-chef --locked
RUN rustup target add x86_64-unknown-linux-musl
RUN apt-get update && apt-get install -y --no-install-recommends musl-tools && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --target x86_64-unknown-linux-musl --recipe-path recipe.json
COPY . .
RUN cargo build --release --target x86_64-unknown-linux-musl --bin myapp

# Fully static binary — scratch image, ~5MB total
FROM scratch
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/myapp /myapp
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
USER 1001:1001
ENTRYPOINT ["/myapp"]
```

### Cache Mounts Alternative (Simpler, No cargo-chef)

```dockerfile
# syntax=docker/dockerfile:1
FROM rust:1.83-slim AS builder
WORKDIR /app
COPY . .
RUN --mount=type=cache,target=/app/target \
    --mount=type=cache,target=/usr/local/cargo/registry \
    cargo build --release && \
    cp target/release/myapp /usr/local/bin/myapp
```

This caches the Cargo registry and the `target/` directory across builds. Simpler than cargo-chef but the cache is local to the builder (not portable across CI runners without external cache backends).

---

## Java

### Maven with JLink Custom Runtime

```dockerfile
# syntax=docker/dockerfile:1

# --- Stage 1: Build with Maven ---
FROM eclipse-temurin:21-jdk-jammy AS builder
WORKDIR /app

# Copy only POM first for dependency caching
COPY pom.xml .
COPY .mvn/ .mvn/
COPY mvnw .
RUN --mount=type=cache,target=/root/.m2/repository \
    chmod +x mvnw && ./mvnw dependency:go-offline -B

# Copy source and build
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2/repository \
    ./mvnw package -DskipTests -B && \
    mv target/*.jar target/app.jar

# Analyze dependencies to find required JDK modules
RUN jdeps --ignore-missing-deps --print-module-deps \
    --multi-release 21 target/app.jar > deps.txt

# --- Stage 2: Create a custom minimal JRE with jlink ---
FROM eclipse-temurin:21-jdk-jammy AS jre-builder
COPY --from=builder /app/deps.txt /deps.txt
RUN jlink \
    --add-modules $(cat /deps.txt) \
    --strip-debug \
    --compress zip-6 \
    --no-header-files \
    --no-man-pages \
    --output /custom-jre

# --- Stage 3: Minimal runtime with custom JRE ---
FROM debian:bookworm-slim
RUN groupadd -r app && useradd -r -g app -u 1001 app
COPY --from=jre-builder /custom-jre /opt/java
COPY --from=builder /app/target/app.jar /app/app.jar
ENV JAVA_HOME=/opt/java
ENV PATH="${JAVA_HOME}/bin:${PATH}"
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD java -cp /app/app.jar com.example.HealthCheck || exit 1
ENTRYPOINT ["java", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=75.0", \
  "-jar", "/app/app.jar"]
```

Key JVM flags for containers:
- `-XX:+UseContainerSupport` — respects container memory/CPU limits (default since JDK 10).
- `-XX:MaxRAMPercentage=75.0` — use 75% of container memory for heap (leave room for off-heap, metaspace).

### Gradle Variant

```dockerfile
# syntax=docker/dockerfile:1

FROM eclipse-temurin:21-jdk-jammy AS builder
WORKDIR /app
COPY build.gradle.kts settings.gradle.kts gradle.properties ./
COPY gradle/ gradle/
COPY gradlew .
RUN --mount=type=cache,target=/root/.gradle \
    chmod +x gradlew && ./gradlew dependencies --no-daemon
COPY src/ src/
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew bootJar --no-daemon && \
    mv build/libs/*.jar build/libs/app.jar
```

### Spring Boot Layered JAR (Optimal Caching)

Spring Boot 2.3+ produces layered JARs that separate dependencies from application code. This maximizes Docker layer reuse.

```dockerfile
# syntax=docker/dockerfile:1

FROM eclipse-temurin:21-jdk-jammy AS builder
WORKDIR /app
COPY . .
RUN --mount=type=cache,target=/root/.m2/repository \
    ./mvnw package -DskipTests -B && \
    mv target/*.jar target/app.jar

# Extract layers from the Spring Boot JAR
RUN java -Djarmode=layertools -jar target/app.jar extract --destination extracted

FROM eclipse-temurin:21-jre-jammy
RUN groupadd -r app && useradd -r -g app -u 1001 app
WORKDIR /app

# Copy layers in order of change frequency (least → most)
# Dependencies change rarely — cached layer
COPY --from=builder /app/extracted/dependencies/ ./
COPY --from=builder /app/extracted/spring-boot-loader/ ./
COPY --from=builder /app/extracted/snapshot-dependencies/ ./
# Application code changes most often — only this layer rebuilds
COPY --from=builder /app/extracted/application/ ./

USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD curl -f http://localhost:8080/actuator/health || exit 1
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "org.springframework.boot.loader.launch.JarLauncher"]
```

---

## .NET

### Multi-Stage with SDK vs Runtime Images

```dockerfile
# syntax=docker/dockerfile:1

# --- Stage 1: Restore dependencies (cached layer) ---
FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS restore
WORKDIR /src
# Copy only project files for dependency restoration
COPY *.sln .
COPY src/MyApp.Api/*.csproj src/MyApp.Api/
COPY src/MyApp.Core/*.csproj src/MyApp.Core/
COPY tests/MyApp.Tests/*.csproj tests/MyApp.Tests/
RUN dotnet restore --runtime linux-musl-x64

# --- Stage 2: Build and publish ---
FROM restore AS build
COPY src/ src/
COPY tests/ tests/
RUN dotnet publish src/MyApp.Api/MyApp.Api.csproj \
    --configuration Release \
    --runtime linux-musl-x64 \
    --self-contained true \
    --no-restore \
    -p:PublishTrimmed=true \
    -p:PublishSingleFile=true \
    -o /app/publish

# --- Stage 3: Minimal runtime ---
FROM mcr.microsoft.com/dotnet/runtime-deps:9.0-alpine
RUN addgroup -S app && adduser -S app -G app -u 1001
WORKDIR /app
COPY --from=build /app/publish .
USER app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
ENV DOTNET_EnableDiagnostics=0
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://localhost:8080/health || exit 1
ENTRYPOINT ["./MyApp.Api"]
```

### Key .NET Docker Concepts

| Image | Size | Use Case |
|---|---|---|
| `dotnet/sdk` | ~800MB | Build/restore only |
| `dotnet/aspnet` | ~220MB | ASP.NET apps (framework-dependent) |
| `dotnet/runtime` | ~190MB | Console apps (framework-dependent) |
| `dotnet/runtime-deps` | ~12MB (Alpine) | Self-contained/trimmed apps |

### Trimming and AOT Compilation

```dockerfile
# Native AOT — even smaller, faster startup, no JIT
RUN dotnet publish src/MyApp.Api/MyApp.Api.csproj \
    --configuration Release \
    --runtime linux-musl-x64 \
    -p:PublishAot=true \
    -o /app/publish

# Final image can use scratch if fully static
FROM scratch
COPY --from=build /app/publish/MyApp.Api /app
ENTRYPOINT ["/app"]
```

### NuGet Cache Mount

```dockerfile
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore --runtime linux-musl-x64
```

---

## PHP

### PHP-FPM with Nginx

```dockerfile
# syntax=docker/dockerfile:1

# --- Stage 1: Install Composer dependencies ---
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN --mount=type=cache,target=/root/.composer/cache \
    composer install \
      --no-dev \
      --no-scripts \
      --no-autoloader \
      --prefer-dist

COPY . .
RUN composer dump-autoload --optimize --classmap-authoritative

# --- Stage 2: Build frontend assets (if applicable) ---
FROM node:22-alpine AS assets
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY resources/ resources/
COPY vite.config.js ./
RUN npm run build

# --- Stage 3: Production PHP-FPM image ---
FROM php:8.4-fpm-alpine AS app
WORKDIR /var/www/html

# Install required PHP extensions
RUN apk add --no-cache \
      icu-libs \
      libpq \
      libzip && \
    apk add --no-cache --virtual .build-deps \
      icu-dev \
      postgresql-dev \
      libzip-dev && \
    docker-php-ext-install \
      intl \
      pdo_pgsql \
      zip \
      opcache && \
    apk del .build-deps

# OPcache configuration for production
RUN { \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.interned_strings_buffer=16'; \
    echo 'opcache.max_accelerated_files=20000'; \
    echo 'opcache.revalidate_freq=0'; \
    echo 'opcache.validate_timestamps=0'; \
    echo 'opcache.enable_cli=1'; \
    echo 'opcache.jit=1255'; \
    echo 'opcache.jit_buffer_size=128M'; \
  } > /usr/local/etc/php/conf.d/opcache.ini

# PHP-FPM tuning
RUN { \
    echo '[www]'; \
    echo 'pm = dynamic'; \
    echo 'pm.max_children = 50'; \
    echo 'pm.start_servers = 5'; \
    echo 'pm.min_spare_servers = 5'; \
    echo 'pm.max_spare_servers = 35'; \
  } > /usr/local/etc/php-fpm.d/zz-tuning.conf

# Copy application
COPY --from=vendor /app/vendor/ vendor/
COPY --from=assets /app/public/build/ public/build/
COPY . .

RUN chown -R www-data:www-data storage bootstrap/cache
USER www-data

EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=5s \
  CMD php-fpm-healthcheck || exit 1

# --- Stage 4: Nginx reverse proxy ---
FROM nginx:1.27-alpine AS web
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=app /var/www/html/public /var/www/html/public
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost/health || exit 1
```

### Nginx Config (docker/nginx/default.conf)

```nginx
server {
    listen 80;
    server_name _;
    root /var/www/html/public;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass app:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location /health {
        access_log off;
        return 200 "OK";
    }
}
```

### Compose for PHP + Nginx

```yaml
services:
  app:
    build:
      context: .
      target: app
    volumes:
      - storage:/var/www/html/storage
    networks: [backend]

  web:
    build:
      context: .
      target: web
    ports: ["80:80"]
    depends_on:
      app:
        condition: service_healthy
    networks: [backend]

volumes:
  storage:
networks:
  backend:
```

---

## Ruby

### Rails with Bundler and Asset Precompilation

```dockerfile
# syntax=docker/dockerfile:1

# --- Stage 1: Install gems ---
FROM ruby:3.3-slim AS gems
WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpq-dev \
      git && \
    rm -rf /var/lib/apt/lists/*

# Install bundler and gems (cached unless Gemfile changes)
COPY Gemfile Gemfile.lock ./
RUN --mount=type=cache,target=/root/.bundle/cache \
    bundle config set --local deployment true && \
    bundle config set --local without 'development test' && \
    bundle config set --local path vendor/bundle && \
    bundle install --jobs=$(nproc)

# --- Stage 2: Precompile assets ---
FROM gems AS assets
COPY . .
# Secret key base needed for asset precompilation but not used at runtime
RUN SECRET_KEY_BASE=precompile-placeholder \
    RAILS_ENV=production \
    bundle exec rails assets:precompile

# --- Stage 3: Production runtime ---
FROM ruby:3.3-slim AS production
WORKDIR /app

# Install runtime-only dependencies (no build tools)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libpq5 \
      curl \
      libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

# Use jemalloc for better memory management
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
ENV MALLOC_CONF="dirty_decay_ms:1000,narenas:2"

RUN groupadd -r app && useradd -r -g app -u 1001 -m app

# Copy gems (without build artifacts)
COPY --from=gems /app/vendor/bundle vendor/bundle
COPY --from=gems /app/Gemfile /app/Gemfile.lock ./

# Copy application + precompiled assets
COPY --from=assets /app/public/assets public/assets
COPY --from=assets /app/public/packs public/packs
COPY . .

# Configure bundler to find installed gems
RUN bundle config set --local deployment true && \
    bundle config set --local path vendor/bundle && \
    bundle config set --local without 'development test'

# Precompiled bootsnap cache for faster boot
RUN RAILS_ENV=production bundle exec bootsnap precompile --gemfile app/ lib/

RUN chown -R app:app tmp log storage db
USER app

ENV RAILS_ENV=production
ENV RAILS_LOG_TO_STDOUT=true
ENV RAILS_SERVE_STATIC_FILES=true

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD curl -f http://localhost:3000/up || exit 1
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
```

### Key Ruby Docker Tips

- **jemalloc**: Reduces memory fragmentation in long-running Ruby processes. Always use it in production containers.
- **bootsnap**: Precompile the bootsnap cache in the Dockerfile to speed up startup.
- `RAILS_SERVE_STATIC_FILES=true`: Lets Puma serve assets directly. Use Nginx in front for higher traffic.
- `bundle config deployment true`: Ensures exact Gemfile.lock versions, similar to `npm ci`.

---

## Elixir

### Mix Release with Multi-Stage Build

```dockerfile
# syntax=docker/dockerfile:1

# --- Stage 1: Build dependencies ---
FROM hexpm/elixir:1.17.3-erlang-27.2-alpine-3.21.0 AS deps
WORKDIR /app

RUN apk add --no-cache git build-base

ENV MIX_ENV=prod

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Install dependencies first (cached layer)
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex/packages \
    mix deps.get --only prod
RUN mix deps.compile

# --- Stage 2: Compile and build release ---
FROM deps AS builder

# Copy config first (changes less often than source)
COPY config/config.exs config/prod.exs config/runtime.exs config/
COPY priv/ priv/
COPY lib/ lib/

# Compile assets (if Phoenix)
COPY assets/ assets/
RUN mix assets.deploy

# Compile application
RUN mix compile

# Build the OTP release
RUN mix release

# --- Stage 3: Minimal runtime image ---
FROM alpine:3.21 AS production
WORKDIR /app

# Install runtime dependencies only
RUN apk add --no-cache \
      libstdc++ \
      openssl \
      ncurses-libs \
      libgcc \
      ca-certificates

RUN addgroup -S app && adduser -S app -G app -u 1001

# Copy the release from the build stage
COPY --from=builder --chown=app:app /app/_build/prod/rel/my_app ./

USER app

ENV PHX_SERVER=true
ENV MIX_ENV=prod

EXPOSE 4000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://localhost:4000/health || exit 1
CMD ["bin/my_app", "start"]
```

### Key Elixir Docker Concepts

- **OTP releases** (`mix release`): Self-contained packages with the Erlang runtime, your app, and all dependencies. No Elixir/Erlang installation needed at runtime.
- **Runtime config** (`config/runtime.exs`): Use this for environment-variable-based configuration instead of compile-time config. Critical for Docker where env vars are set at runtime.
- **Alpine compatibility**: Elixir/Erlang releases need `libstdc++`, `ncurses-libs`, and `libgcc` at runtime on Alpine.
- **Hot upgrades**: OTP supports hot code upgrades, but in containers, just deploy a new container instead.

### With Umbrella Projects (Monorepo)

```dockerfile
# syntax=docker/dockerfile:1

FROM hexpm/elixir:1.17.3-erlang-27.2-alpine-3.21.0 AS deps
WORKDIR /app
RUN apk add --no-cache git build-base
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

# Copy all mix files from umbrella
COPY mix.exs mix.lock ./
COPY apps/app_web/mix.exs apps/app_web/
COPY apps/app_core/mix.exs apps/app_core/
COPY apps/app_mailer/mix.exs apps/app_mailer/
RUN mix deps.get --only prod && mix deps.compile

FROM deps AS builder
COPY config/ config/
COPY apps/ apps/
RUN mix compile
RUN mix release app_web

FROM alpine:3.21
RUN apk add --no-cache libstdc++ openssl ncurses-libs libgcc
RUN addgroup -S app && adduser -S app -G app -u 1001
WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/app_web ./
USER app
EXPOSE 4000
CMD ["bin/app_web", "start"]
```

### Database Migrations in Container

Don't run migrations in the Dockerfile. Run them as a separate command before starting the app:

```bash
# Run migrations before starting (in entrypoint script or init container)
docker run --rm myapp bin/my_app eval "MyApp.Release.migrate()"

# Or use an entrypoint script
```

```dockerfile
COPY --chmod=755 docker/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bin/my_app", "start"]
```

```bash
#!/bin/sh
# docker/entrypoint.sh
set -e

# Run migrations if MIGRATE=true
if [ "${MIGRATE}" = "true" ]; then
  bin/my_app eval "MyApp.Release.migrate()"
fi

exec "$@"
```
