# syntax=docker/dockerfile:1

# =============================================================================
# Production-Ready Java / Spring Boot Dockerfile
# =============================================================================
# Multi-stage build with JLink custom runtime image:
#
#   1. Builder   — compile with Maven and create a fat JAR
#   2. Layers    — extract Spring Boot layered JAR for optimal caching
#   3. JRE       — build a minimal custom JRE with jlink (only needed modules)
#   4. Runtime   — assemble the final image with custom JRE + app layers
#
# WHY jlink?
#   A full JDK is ~300 MB+. jlink creates a custom JRE containing only the
#   Java modules your app actually uses, typically 50–80 MB.
#
# WHY layered JARs?
#   Spring Boot's layered JAR format separates dependencies, snapshots,
#   and application code into distinct layers. Since dependencies change
#   less often, Docker can cache those layers across builds.
#
# Build with BuildKit enabled:
#   DOCKER_BUILDKIT=1 docker build -t myapp .
#
# Pin your base image digest for reproducibility:
#   eclipse-temurin:21-jdk-jammy@sha256:<digest>
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Builder — compile the application with Maven
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk-jammy AS builder
# Pin digest: @sha256:<paste-digest-here>

WORKDIR /app

# Copy Maven wrapper and POM first for dependency layer caching
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./

# Download dependencies (cached unless pom.xml changes)
RUN --mount=type=cache,target=/root/.m2/repository \
    ./mvnw dependency:go-offline -B

# Copy source code and build
COPY src/ src/
RUN --mount=type=cache,target=/root/.m2/repository \
    ./mvnw package -B -DskipTests && \
    mv target/*.jar target/app.jar

# ---------------------------------------------------------------------------
# Stage 2: Layers — extract Spring Boot layered JAR
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk-jammy AS layers

WORKDIR /app
COPY --from=builder /app/target/app.jar app.jar

# Extract the layered JAR into separate directories
# Order (bottom to top): dependencies → spring-boot-loader → snapshot-dependencies → application
RUN java -Djarmode=layertools -jar app.jar extract

# ---------------------------------------------------------------------------
# Stage 3: JRE — build a minimal custom Java runtime with jlink
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk-jammy AS jre-builder

WORKDIR /app
COPY --from=builder /app/target/app.jar app.jar

# Use jdeps to discover which Java modules the application needs
# Then use jlink to create a custom minimal JRE with only those modules
RUN jdeps \
      --ignore-missing-deps \
      --print-module-deps \
      --multi-release 21 \
      --class-path 'BOOT-INF/lib/*' \
      app.jar > modules.txt && \
    jlink \
      --add-modules $(cat modules.txt),jdk.crypto.ec \
      --strip-debug \
      --compress zip-6 \
      --no-header-files \
      --no-man-pages \
      --output /opt/custom-jre

# ---------------------------------------------------------------------------
# Stage 4: Runtime — minimal image with custom JRE and app layers
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# Metadata labels following OCI image spec
LABEL org.opencontainers.image.source="https://github.com/your-org/your-repo" \
      org.opencontainers.image.description="Production Java/Spring Boot application" \
      org.opencontainers.image.licenses="MIT"

# Install only essential runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Copy the custom minimal JRE
COPY --from=jre-builder /opt/custom-jre /opt/java
ENV JAVA_HOME=/opt/java \
    PATH="/opt/java/bin:$PATH"

WORKDIR /app

# Copy Spring Boot layers in order of change frequency (least → most)
# This maximizes Docker layer caching
COPY --from=layers /app/dependencies/ ./
COPY --from=layers /app/spring-boot-loader/ ./
COPY --from=layers /app/snapshot-dependencies/ ./
COPY --from=layers /app/application/ ./

# Create a non-root user with a fixed UID/GID
RUN groupadd --gid 1001 appuser && \
    useradd --uid 1001 --gid appuser --shell /bin/false --create-home appuser && \
    chown -R appuser:appuser /app

# Drop to non-root user
USER 1001

# Expose the application port
EXPOSE 8080

# JVM tuning for containers:
#   -XX:+UseContainerSupport       — respect container memory/CPU limits
#   -XX:MaxRAMPercentage=75.0      — use at most 75% of container memory for heap
#   -XX:+ExitOnOutOfMemoryError    — crash fast on OOM instead of running degraded
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"

# Health check against Spring Boot Actuator
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["curl", "-f", "http://localhost:8080/actuator/health", "||", "exit", "1"]

# Use exec form with shell expansion for JAVA_OPTS
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
