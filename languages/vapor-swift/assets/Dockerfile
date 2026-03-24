# ══════════════════════════════════════════════════════
# Multi-stage Dockerfile for Vapor 4.x Production
# ══════════════════════════════════════════════════════

# ── Stage 1: Build ──────────────────────────────────
FROM swift:5.9-jammy AS build

WORKDIR /build

# Resolve dependencies first for better layer caching
COPY Package.swift Package.resolved* ./
RUN swift package resolve

# Copy source code
COPY Sources/ Sources/
COPY Tests/ Tests/

# Build release binary with static linking
RUN swift build \
    -c release \
    --static-swift-stdlib \
    -Xswiftc -g

# Strip debug symbols for smaller binary (optional)
RUN strip .build/release/App

# ── Stage 2: Runtime ────────────────────────────────
FROM ubuntu:jammy AS runtime

# Labels
LABEL maintainer="your-team@example.com"
LABEL description="Vapor 4.x application"

# Create non-root user
RUN groupadd -r vapor && useradd -r -g vapor -d /app -s /sbin/nologin vapor

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 \
    libxml2 \
    tzdata \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy binary from build stage
COPY --from=build --chown=vapor:vapor /build/.build/release/App ./App

# Copy static assets (create dirs even if empty)
RUN mkdir -p Public Resources
COPY --from=build --chown=vapor:vapor /build/Public/ ./Public/
COPY --from=build --chown=vapor:vapor /build/Resources/ ./Resources/

# Switch to non-root user
USER vapor

# Expose Vapor default port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
