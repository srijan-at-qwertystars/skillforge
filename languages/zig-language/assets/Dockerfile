# Zig Development Dockerfile
# Multi-stage build for development and CI
#
# Usage:
#   docker build -t zig-dev .
#   docker run --rm -v $(pwd):/app zig-dev build
#   docker run --rm -v $(pwd):/app zig-dev test
#   docker run --rm -it -v $(pwd):/app zig-dev sh

# ── Build Stage ──
FROM alpine:3.20 AS builder

ARG ZIG_VERSION=0.14.0
ARG TARGETARCH

RUN apk add --no-cache curl xz

# Download and install Zig
RUN case "${TARGETARCH}" in \
        amd64) ZIG_ARCH="x86_64" ;; \
        arm64) ZIG_ARCH="aarch64" ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt && \
    mv /opt/zig-linux-*-${ZIG_VERSION} /opt/zig

# ── Development Image ──
FROM alpine:3.20 AS dev

RUN apk add --no-cache \
    bash \
    git \
    gdb \
    musl-dev \
    # Common C libraries for interop
    sqlite-dev \
    zlib-dev \
    openssl-dev \
    curl-dev

COPY --from=builder /opt/zig /opt/zig
ENV PATH="/opt/zig:${PATH}"

# Verify installation
RUN zig version

WORKDIR /app

# Cache Zig's global cache
ENV XDG_CACHE_HOME=/tmp/zig-cache
RUN mkdir -p /tmp/zig-cache

# Default entrypoint: run zig build
ENTRYPOINT ["zig"]
CMD ["build"]

# ── CI Image (minimal) ──
FROM alpine:3.20 AS ci

RUN apk add --no-cache musl-dev

COPY --from=builder /opt/zig /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /app

ENTRYPOINT ["zig"]
CMD ["build", "test"]
