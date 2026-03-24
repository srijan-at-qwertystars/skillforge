#!/usr/bin/env bash
# check-dependencies.sh — Check for outdated or vulnerable Spring Boot dependencies
#
# Usage:
#   ./check-dependencies.sh                  # Auto-detect build tool in current dir
#   ./check-dependencies.sh /path/to/project # Check a specific project
#
# Features:
#   - Detects Gradle or Maven project
#   - Lists outdated dependencies
#   - Checks for known vulnerabilities (if OWASP plugin is available)
#   - Reports Spring Boot version vs latest
#
# Requires: curl, java (for Gradle/Maven wrapper)

set -euo pipefail

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR"

echo "=== Spring Boot Dependency Checker ==="
echo "  Project: $(pwd)"
echo ""

# --------------------------------------------------------------------------
# Detect build tool
# --------------------------------------------------------------------------
BUILD_TOOL=""
if [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
    BUILD_TOOL="gradle"
elif [[ -f "pom.xml" ]]; then
    BUILD_TOOL="maven"
else
    echo "Error: No build.gradle(.kts) or pom.xml found in $(pwd)"
    exit 1
fi
echo "  Build tool: $BUILD_TOOL"
echo ""

# --------------------------------------------------------------------------
# Check latest Spring Boot version
# --------------------------------------------------------------------------
echo "--- Latest Spring Boot Release ---"
LATEST_BOOT=$(curl -fsSL "https://api.github.com/repos/spring-projects/spring-boot/releases/latest" \
    2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/' || echo "unknown")
echo "  Latest GA: $LATEST_BOOT"

if [[ "$BUILD_TOOL" == "gradle" ]]; then
    CURRENT_BOOT=$(grep -oP "spring-boot.*version\s*[\"']?\K[0-9]+\.[0-9]+\.[0-9]+" \
        build.gradle* 2>/dev/null | head -1 || echo "unknown")
elif [[ "$BUILD_TOOL" == "maven" ]]; then
    CURRENT_BOOT=$(grep -A1 '<artifactId>spring-boot-starter-parent</artifactId>' pom.xml \
        2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
fi
echo "  Current:   $CURRENT_BOOT"
if [[ "$CURRENT_BOOT" != "$LATEST_BOOT" && "$CURRENT_BOOT" != "unknown" && "$LATEST_BOOT" != "unknown" ]]; then
    echo "  ⚠️  Update available: $CURRENT_BOOT → $LATEST_BOOT"
else
    echo "  ✅ Up to date"
fi
echo ""

# --------------------------------------------------------------------------
# Check outdated dependencies
# --------------------------------------------------------------------------
echo "--- Outdated Dependencies ---"
if [[ "$BUILD_TOOL" == "gradle" ]]; then
    # Check if the versions plugin is applied
    if grep -q "com.github.ben-manes.versions" build.gradle* 2>/dev/null; then
        echo "Running Gradle dependency updates report..."
        ./gradlew dependencyUpdates -q 2>/dev/null || echo "  (Could not run dependencyUpdates task)"
    else
        echo "  Tip: Add the versions plugin for automated checks:"
        echo '    plugins { id("com.github.ben-manes.versions") version "0.51.0" }'
        echo "    Then run: ./gradlew dependencyUpdates"
        echo ""
        echo "  Listing current dependencies:"
        ./gradlew dependencies --configuration runtimeClasspath -q 2>/dev/null \
            | grep -E "spring-|jakarta\." | head -30 || echo "  (Could not list dependencies)"
    fi
elif [[ "$BUILD_TOOL" == "maven" ]]; then
    echo "Running Maven versions check..."
    ./mvnw versions:display-dependency-updates -q 2>/dev/null \
        | grep -E "\->" | head -30 || echo "  (Could not check versions — add versions-maven-plugin)"
fi
echo ""

# --------------------------------------------------------------------------
# Check for vulnerabilities
# --------------------------------------------------------------------------
echo "--- Vulnerability Check ---"
if [[ "$BUILD_TOOL" == "gradle" ]]; then
    if grep -q "org.owasp.dependencycheck" build.gradle* 2>/dev/null; then
        echo "Running OWASP dependency check..."
        ./gradlew dependencyCheckAnalyze -q 2>/dev/null || echo "  (OWASP check failed)"
    else
        echo "  Tip: Add OWASP dependency-check plugin:"
        echo '    plugins { id("org.owasp.dependencycheck") version "11.1.1" }'
        echo "    Then run: ./gradlew dependencyCheckAnalyze"
    fi
elif [[ "$BUILD_TOOL" == "maven" ]]; then
    if grep -q "dependency-check-maven" pom.xml 2>/dev/null; then
        echo "Running OWASP dependency check..."
        ./mvnw org.owasp:dependency-check-maven:check -q 2>/dev/null || echo "  (OWASP check failed)"
    else
        echo "  Tip: Add OWASP dependency-check plugin to pom.xml"
        echo "    Then run: ./mvnw org.owasp:dependency-check-maven:check"
    fi
fi
echo ""

# --------------------------------------------------------------------------
# Check Java version compatibility
# --------------------------------------------------------------------------
echo "--- Java Version ---"
if command -v java &>/dev/null; then
    JAVA_VER=$(java -version 2>&1 | head -1 | awk -F'"' '{print $2}')
    echo "  Installed: $JAVA_VER"
    MAJOR_VER=$(echo "$JAVA_VER" | cut -d. -f1)
    if [[ "$MAJOR_VER" -lt 17 ]]; then
        echo "  ⚠️  Spring Boot 3.x requires Java 17+. Current: $MAJOR_VER"
    elif [[ "$MAJOR_VER" -ge 21 ]]; then
        echo "  ✅ Java $MAJOR_VER — supports virtual threads"
    else
        echo "  ✅ Java $MAJOR_VER — compatible with Spring Boot 3.x"
    fi
else
    echo "  ⚠️  Java not found on PATH"
fi
echo ""
echo "Done."
