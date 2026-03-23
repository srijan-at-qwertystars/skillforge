#!/usr/bin/env bash
# setup-testcontainers.sh — Verify Docker and install Testcontainers for a chosen language.
#
# Usage:
#   ./setup-testcontainers.sh <language>
#   Languages: java | python | node | go | dotnet
#
# Examples:
#   ./setup-testcontainers.sh python
#   ./setup-testcontainers.sh java

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ ${NC}$*"; }
ok()    { echo -e "${GREEN}✅ ${NC}$*"; }
warn()  { echo -e "${YELLOW}⚠️  ${NC}$*"; }
fail()  { echo -e "${RED}❌ ${NC}$*"; }

LANGUAGE="${1:-}"

usage() {
    echo "Usage: $0 <language>"
    echo ""
    echo "Languages:"
    echo "  java    — Maven/Gradle dependency setup"
    echo "  python  — pip install testcontainers"
    echo "  node    — npm install testcontainers"
    echo "  go      — go get testcontainers-go"
    echo "  dotnet  — dotnet add Testcontainers"
    exit 1
}

if [[ -z "$LANGUAGE" ]]; then
    usage
fi

# -------------------------------------------------------------------
# Step 1: Verify Docker
# -------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testcontainers Setup — $LANGUAGE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

info "Checking Docker..."

if ! command -v docker &>/dev/null; then
    fail "Docker CLI not found. Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker info &>/dev/null; then
    fail "Docker daemon is not running."
    echo "  Start Docker Desktop or run: sudo systemctl start docker"
    exit 1
fi

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
ok "Docker is running (version: $DOCKER_VERSION)"

# -------------------------------------------------------------------
# Step 2: Language-specific install
# -------------------------------------------------------------------

case "$LANGUAGE" in
    java)
        info "Setting up Testcontainers for Java..."

        if command -v mvn &>/dev/null; then
            ok "Maven detected"
            echo ""
            echo "Add to your pom.xml <dependencies>:"
            echo ""
            cat <<'MAVEN'
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>testcontainers</artifactId>
    <version>1.20.4</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>junit-jupiter</artifactId>
    <version>1.20.4</version>
    <scope>test</scope>
</dependency>
<!-- Add modules as needed: -->
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>postgresql</artifactId>
    <version>1.20.4</version>
    <scope>test</scope>
</dependency>
MAVEN
        elif command -v gradle &>/dev/null || [[ -f "build.gradle" ]] || [[ -f "build.gradle.kts" ]]; then
            ok "Gradle detected"
            echo ""
            echo "Add to your build.gradle(.kts):"
            echo ""
            cat <<'GRADLE'
testImplementation("org.testcontainers:testcontainers:1.20.4")
testImplementation("org.testcontainers:junit-jupiter:1.20.4")
// Add modules as needed:
testImplementation("org.testcontainers:postgresql:1.20.4")
GRADLE
        else
            warn "No Maven or Gradle detected."
            echo "  Install Maven: https://maven.apache.org/install.html"
            echo "  Install Gradle: https://gradle.org/install/"
        fi
        ;;

    python)
        info "Setting up Testcontainers for Python..."

        if ! command -v pip &>/dev/null && ! command -v pip3 &>/dev/null; then
            fail "pip not found. Install Python 3: https://www.python.org/downloads/"
            exit 1
        fi

        PIP_CMD=$(command -v pip3 || command -v pip)
        ok "Using $PIP_CMD"

        echo ""
        info "Installing testcontainers with common modules..."
        $PIP_CMD install "testcontainers[postgres,mysql,mongodb,redis,kafka]"

        ok "testcontainers installed"
        echo ""
        echo "Verify:"
        echo "  python -c 'import testcontainers; print(testcontainers.__version__)'"
        ;;

    node|nodejs|typescript|ts)
        info "Setting up Testcontainers for Node.js..."

        if ! command -v npm &>/dev/null; then
            fail "npm not found. Install Node.js: https://nodejs.org/"
            exit 1
        fi

        NODE_VERSION=$(node --version 2>/dev/null || echo "unknown")
        ok "Node.js detected ($NODE_VERSION)"

        if [[ ! -f "package.json" ]]; then
            warn "No package.json found. Run 'npm init' first or cd to your project."
        fi

        echo ""
        info "Installing testcontainers packages..."
        npm install --save-dev testcontainers @testcontainers/postgresql @testcontainers/kafka @testcontainers/mongodb

        ok "testcontainers installed"
        echo ""
        echo "Verify:"
        echo "  node -e \"require('testcontainers'); console.log('OK')\""
        ;;

    go|golang)
        info "Setting up Testcontainers for Go..."

        if ! command -v go &>/dev/null; then
            fail "Go not found. Install: https://go.dev/dl/"
            exit 1
        fi

        GO_VERSION=$(go version 2>/dev/null | awk '{print $3}')
        ok "Go detected ($GO_VERSION)"

        if [[ ! -f "go.mod" ]]; then
            warn "No go.mod found. Run 'go mod init <module>' first or cd to your project."
        fi

        echo ""
        info "Installing testcontainers-go and modules..."
        go get github.com/testcontainers/testcontainers-go
        go get github.com/testcontainers/testcontainers-go/modules/postgres
        go get github.com/testcontainers/testcontainers-go/modules/redis
        go get github.com/testcontainers/testcontainers-go/modules/kafka
        go get github.com/testcontainers/testcontainers-go/modules/mongodb

        ok "testcontainers-go installed"
        ;;

    dotnet|csharp|cs)
        info "Setting up Testcontainers for .NET..."

        if ! command -v dotnet &>/dev/null; then
            fail "dotnet CLI not found. Install: https://dotnet.microsoft.com/download"
            exit 1
        fi

        DOTNET_VERSION=$(dotnet --version 2>/dev/null || echo "unknown")
        ok ".NET SDK detected ($DOTNET_VERSION)"

        echo ""
        info "Installing Testcontainers NuGet packages..."
        dotnet add package Testcontainers --version 4.3.0
        dotnet add package Testcontainers.PostgreSql --version 4.3.0
        dotnet add package Testcontainers.Redis --version 4.3.0
        dotnet add package Testcontainers.MongoDb --version 4.3.0

        ok "Testcontainers packages installed"
        ;;

    *)
        fail "Unknown language: $LANGUAGE"
        usage
        ;;
esac

# -------------------------------------------------------------------
# Step 3: Pull common test images (optional)
# -------------------------------------------------------------------
echo ""
info "Pre-pulling common test images speeds up first test run."
echo "  Run these if desired:"
echo ""
echo "  docker pull postgres:16-alpine"
echo "  docker pull redis:7-alpine"
echo "  docker pull mongo:7"
echo "  docker pull confluentinc/cp-kafka:7.6.0"
echo "  docker pull localstack/localstack:3.4"
echo ""

ok "Setup complete for $LANGUAGE!"
echo ""
