#!/usr/bin/env bash
# native-build.sh — Build a GraalVM native image for a Spring Boot application
#
# Usage:
#   ./native-build.sh                    # Build native image with defaults
#   ./native-build.sh --container        # Build as container image (Buildpacks)
#   ./native-build.sh --test             # Run native tests only
#   ./native-build.sh --tracing-agent    # Run with tracing agent to discover hints
#
# Environment variables (optional):
#   NATIVE_MEMORY     Max memory for native-image (default: 8g)
#   EXTRA_ARGS        Additional native-image arguments
#   IMAGE_NAME        Container image name (default: project name)
#
# Prerequisites:
#   - GraalVM JDK 21+ (or container build via Buildpacks)
#   - Gradle with org.graalvm.buildtools.native plugin
#     OR Maven with spring-boot-starter-parent 3.x (includes native profile)
#
# Requires: java (GraalVM), or Docker for container builds

set -euo pipefail

NATIVE_MEMORY="${NATIVE_MEMORY:-8g}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
MODE="${1:---compile}"

# --------------------------------------------------------------------------
# Detect build tool
# --------------------------------------------------------------------------
BUILD_TOOL=""
if [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
    BUILD_TOOL="gradle"
elif [[ -f "pom.xml" ]]; then
    BUILD_TOOL="maven"
else
    echo "Error: No build.gradle(.kts) or pom.xml found."
    exit 1
fi

echo "=== Spring Boot Native Image Builder ==="
echo "  Build tool: $BUILD_TOOL"
echo "  Mode:       $MODE"
echo "  Memory:     $NATIVE_MEMORY"
echo ""

# --------------------------------------------------------------------------
# Check GraalVM (unless container build)
# --------------------------------------------------------------------------
check_graalvm() {
    if ! command -v native-image &>/dev/null; then
        echo "Warning: 'native-image' not found on PATH."
        echo "  Install GraalVM: https://www.graalvm.org/downloads/"
        echo "  Or use --container for Docker-based builds."
        echo ""
        if java -version 2>&1 | grep -qi graalvm; then
            echo "  GraalVM JDK detected. Installing native-image component..."
            gu install native-image 2>/dev/null || true
        else
            echo "  Current JDK is not GraalVM. Container build recommended."
            exit 1
        fi
    fi
    echo "  GraalVM: $(native-image --version 2>/dev/null || echo 'unknown')"
    echo ""
}

# --------------------------------------------------------------------------
# Build modes
# --------------------------------------------------------------------------
case "$MODE" in
    --compile)
        check_graalvm
        echo "Building native image..."
        if [[ "$BUILD_TOOL" == "gradle" ]]; then
            ./gradlew nativeCompile \
                -Porg.gradle.jvmargs="-Xmx${NATIVE_MEMORY}" \
                ${EXTRA_ARGS}
            BINARY=$(find build/native/nativeCompile -type f -executable 2>/dev/null | head -1)
        else
            ./mvnw -Pnative native:compile \
                -Dorg.gradle.jvmargs="-Xmx${NATIVE_MEMORY}" \
                ${EXTRA_ARGS}
            BINARY=$(find target -name "*-native" -o -name "*.exe" 2>/dev/null | head -1)
        fi
        echo ""
        echo "✅ Native image built successfully!"
        if [[ -n "${BINARY:-}" ]]; then
            echo "  Binary: $BINARY"
            echo "  Size:   $(du -h "$BINARY" | cut -f1)"
            echo ""
            echo "Run with:"
            echo "  $BINARY"
        fi
        ;;

    --container)
        echo "Building container image with Cloud Native Buildpacks..."
        if ! command -v docker &>/dev/null; then
            echo "Error: Docker is required for container builds."
            exit 1
        fi
        IMAGE_NAME="${IMAGE_NAME:-$(basename "$(pwd)")}"
        if [[ "$BUILD_TOOL" == "gradle" ]]; then
            ./gradlew bootBuildImage \
                --imageName="$IMAGE_NAME:native" \
                -Porg.gradle.jvmargs="-Xmx${NATIVE_MEMORY}" \
                ${EXTRA_ARGS}
        else
            ./mvnw -Pnative spring-boot:build-image \
                -Dspring-boot.build-image.imageName="$IMAGE_NAME:native" \
                ${EXTRA_ARGS}
        fi
        echo ""
        echo "✅ Container image built: $IMAGE_NAME:native"
        echo ""
        echo "Run with:"
        echo "  docker run --rm -p 8080:8080 $IMAGE_NAME:native"
        ;;

    --test)
        check_graalvm
        echo "Running native tests..."
        if [[ "$BUILD_TOOL" == "gradle" ]]; then
            ./gradlew nativeTest \
                -Porg.gradle.jvmargs="-Xmx${NATIVE_MEMORY}" \
                ${EXTRA_ARGS}
        else
            ./mvnw -PnativeTest test ${EXTRA_ARGS}
        fi
        echo ""
        echo "✅ Native tests passed!"
        ;;

    --tracing-agent)
        echo "Running with GraalVM tracing agent to discover reflection/resource hints..."
        echo "Perform all operations, then stop the app (Ctrl+C)."
        echo ""
        HINTS_DIR="src/main/resources/META-INF/native-image"
        mkdir -p "$HINTS_DIR"

        if [[ "$BUILD_TOOL" == "gradle" ]]; then
            ./gradlew bootJar -q
            JAR=$(find build/libs -name "*.jar" ! -name "*-plain.jar" 2>/dev/null | head -1)
        else
            ./mvnw package -DskipTests -q
            JAR=$(find target -name "*.jar" ! -name "*-sources.jar" 2>/dev/null | head -1)
        fi

        if [[ -z "${JAR:-}" ]]; then
            echo "Error: Could not find JAR file."
            exit 1
        fi

        echo "Running: $JAR"
        echo "Hints will be written to: $HINTS_DIR"
        echo ""
        java -agentlib:native-image-agent=config-output-dir="$HINTS_DIR" -jar "$JAR"
        echo ""
        echo "✅ Tracing agent hints written to $HINTS_DIR"
        echo "  Files: $(ls "$HINTS_DIR"/*.json 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')"
        ;;

    *)
        echo "Unknown mode: $MODE"
        echo "Usage: $0 [--compile|--container|--test|--tracing-agent]"
        exit 1
        ;;
esac
