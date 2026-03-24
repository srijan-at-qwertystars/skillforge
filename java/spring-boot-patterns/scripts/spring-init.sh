#!/usr/bin/env bash
# spring-init.sh — Generate a Spring Boot project via the Spring Initializr API
#
# Usage:
#   ./spring-init.sh                          # Interactive prompts
#   ./spring-init.sh myapp                    # Create project "myapp" with defaults
#   ./spring-init.sh myapp com.example        # Specify group ID
#   ./spring-init.sh myapp com.example web,data-jpa,security,postgresql
#
# Environment variables (optional overrides):
#   BOOT_VERSION    Spring Boot version (default: 3.4.1)
#   JAVA_VERSION    Java version (default: 21)
#   BUILD_TOOL      "gradle-project" or "maven-project" (default: gradle-project)
#   PACKAGING       "jar" or "war" (default: jar)
#
# Common dependency IDs (comma-separated):
#   web, data-jpa, security, actuator, validation, postgresql, mysql, h2,
#   data-redis, cache, mail, websocket, webflux, data-r2dbc, oauth2-client,
#   oauth2-resource-server, devtools, docker-compose, testcontainers,
#   flyway, liquibase, prometheus, graphql, batch, amqp, kafka
#
# Requires: curl, unzip

set -euo pipefail

INITIALIZR_URL="https://start.spring.io/starter.zip"

# Defaults
ARTIFACT="${1:-myapp}"
GROUP_ID="${2:-com.example}"
DEPS="${3:-web,data-jpa,security,actuator,validation,postgresql,devtools,testcontainers,docker-compose}"
BOOT_VERSION="${BOOT_VERSION:-3.4.1}"
JAVA_VERSION="${JAVA_VERSION:-21}"
BUILD_TOOL="${BUILD_TOOL:-gradle-project}"
PACKAGING="${PACKAGING:-jar}"

# Validate dependencies are not empty
if [[ -z "$DEPS" ]]; then
    echo "Error: No dependencies specified."
    exit 1
fi

echo "=== Spring Boot Project Generator ==="
echo "  Artifact:     $ARTIFACT"
echo "  Group:        $GROUP_ID"
echo "  Boot Version: $BOOT_VERSION"
echo "  Java:         $JAVA_VERSION"
echo "  Build Tool:   $BUILD_TOOL"
echo "  Packaging:    $PACKAGING"
echo "  Dependencies: $DEPS"
echo ""

# Check prerequisites
for cmd in curl unzip; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not installed."
        exit 1
    fi
done

# Check if directory already exists
if [[ -d "$ARTIFACT" ]]; then
    echo "Error: Directory '$ARTIFACT' already exists."
    exit 1
fi

echo "Downloading from Spring Initializr..."
curl -fsSL "$INITIALIZR_URL" \
    -d "type=$BUILD_TOOL" \
    -d "language=java" \
    -d "bootVersion=$BOOT_VERSION" \
    -d "baseDir=$ARTIFACT" \
    -d "groupId=$GROUP_ID" \
    -d "artifactId=$ARTIFACT" \
    -d "name=$ARTIFACT" \
    -d "packageName=$GROUP_ID.$ARTIFACT" \
    -d "packaging=$PACKAGING" \
    -d "javaVersion=$JAVA_VERSION" \
    -d "dependencies=$DEPS" \
    -o "${ARTIFACT}.zip"

echo "Extracting..."
unzip -q "${ARTIFACT}.zip"
rm -f "${ARTIFACT}.zip"

echo ""
echo "Project created at ./$ARTIFACT"
echo ""
echo "Next steps:"
echo "  cd $ARTIFACT"
if [[ "$BUILD_TOOL" == "gradle-project" ]]; then
    echo "  ./gradlew bootRun"
else
    echo "  ./mvnw spring-boot:run"
fi
