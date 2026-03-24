#!/usr/bin/env bash
# =============================================================================
# generate-client.sh — Generate API client code from an OpenAPI specification
#
# Uses openapi-generator-cli to generate client SDKs, server stubs, or
# documentation from an OpenAPI spec file. Supports 50+ languages/frameworks.
#
# Usage:
#   ./generate-client.sh <spec-file> [options]
#
# Examples:
#   ./generate-client.sh openapi.yaml -l typescript-axios
#   ./generate-client.sh openapi.yaml -l python -o ./sdk/python
#   ./generate-client.sh openapi.yaml -l go -o ./sdk/go --additional-properties packageName=myapi
#   ./generate-client.sh openapi.yaml -l spring -o ./server --type server
#   ./generate-client.sh --list-languages
#
# Requirements:
#   - Java 11+ (for openapi-generator-cli JAR) OR
#   - Node.js 18+ and npm (for npx @openapitools/openapi-generator-cli) OR
#   - Docker (for openapitools/openapi-generator-cli image)
#
# Exit codes:
#   0 — Generation succeeded
#   1 — Generation failed
#   2 — Usage error or missing dependencies
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Defaults ---
SPEC_FILE=""
LANGUAGE=""
OUTPUT_DIR=""
GEN_TYPE="client"
ADDITIONAL_PROPS=""
LIST_LANGS=false
RUNNER=""

# --- Popular languages quick reference ---
POPULAR_LANGS="
  Client SDKs:
    typescript-axios    TypeScript with Axios HTTP client
    typescript-fetch    TypeScript with Fetch API
    python              Python client (urllib3)
    java                Java client (various HTTP libs)
    go                  Go client
    ruby                Ruby client
    csharp              C# / .NET client
    swift5              Swift 5 client (iOS/macOS)
    kotlin              Kotlin client
    rust                Rust client
    dart                Dart client (Flutter)
    php                 PHP client

  Server Stubs:
    spring              Java Spring Boot server
    python-flask        Python Flask server
    python-fastapi      Python FastAPI server
    go-server           Go server (net/http)
    nodejs-express      Node.js Express server
    aspnetcore          ASP.NET Core server

  Documentation:
    html2               Static HTML documentation
    markdown            Markdown documentation
    openapi-yaml        Bundled OpenAPI YAML
"

# --- Usage ---
usage() {
    echo "Usage: $0 <spec-file> [options]"
    echo ""
    echo "Options:"
    echo "  <spec-file>              Path to OpenAPI spec (YAML or JSON)"
    echo "  -l, --language <lang>    Target language/framework (required)"
    echo "  -o, --output <dir>       Output directory (default: ./generated/<language>)"
    echo "  -t, --type <type>        Generator type: client (default), server, docs"
    echo "  -p, --additional-properties <props>"
    echo "                           Comma-separated key=value pairs for generator"
    echo "  --list-languages         List all available generators and exit"
    echo "  --runner <runner>        Force runner: npx, docker, or java"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Popular languages:"
    echo "$POPULAR_LANGS"
    exit 2
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--language)
            LANGUAGE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -t|--type)
            GEN_TYPE="$2"
            shift 2
            ;;
        -p|--additional-properties)
            ADDITIONAL_PROPS="$2"
            shift 2
            ;;
        --list-languages)
            LIST_LANGS=true
            shift
            ;;
        --runner)
            RUNNER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}Error: Unknown option $1${NC}" >&2
            usage
            ;;
        *)
            if [[ -z "$SPEC_FILE" ]]; then
                SPEC_FILE="$1"
            else
                echo -e "${RED}Error: Unexpected argument '$1'${NC}" >&2
                usage
            fi
            shift
            ;;
    esac
done

# --- Detect runner ---
detect_runner() {
    if [[ -n "$RUNNER" ]]; then
        return
    fi
    if command -v npx &>/dev/null; then
        RUNNER="npx"
    elif command -v docker &>/dev/null; then
        RUNNER="docker"
    elif command -v java &>/dev/null; then
        RUNNER="java"
    else
        echo -e "${RED}Error: No suitable runner found.${NC}" >&2
        echo "Install one of: Node.js (npx), Docker, or Java 11+." >&2
        exit 2
    fi
    echo -e "${BLUE}  Runner: $RUNNER${NC}"
}

# --- Run openapi-generator command ---
run_generator() {
    local args=("$@")
    case "$RUNNER" in
        npx)
            npx --yes @openapitools/openapi-generator-cli "${args[@]}"
            ;;
        docker)
            local spec_dir
            spec_dir="$(cd "$(dirname "$SPEC_FILE")" && pwd)"
            local spec_name
            spec_name="$(basename "$SPEC_FILE")"
            local out_dir
            out_dir="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")"

            # Remap paths for Docker
            local docker_args=()
            for arg in "${args[@]}"; do
                if [[ "$arg" == "$SPEC_FILE" ]]; then
                    docker_args+=("/spec/$spec_name")
                elif [[ "$arg" == "$OUTPUT_DIR" ]]; then
                    docker_args+=("/output")
                else
                    docker_args+=("$arg")
                fi
            done

            docker run --rm \
                -v "$spec_dir:/spec" \
                -v "$out_dir:/output" \
                openapitools/openapi-generator-cli:latest \
                "${docker_args[@]}"
            ;;
        java)
            if [[ ! -f openapi-generator-cli.jar ]]; then
                echo -e "${YELLOW}Downloading openapi-generator-cli...${NC}"
                curl -sL -o openapi-generator-cli.jar \
                    "https://repo1.maven.org/maven2/org/openapitools/openapi-generator-cli/7.4.0/openapi-generator-cli-7.4.0.jar"
            fi
            java -jar openapi-generator-cli.jar "${args[@]}"
            ;;
    esac
}

# --- List languages ---
list_languages() {
    detect_runner
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Available Generators${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    run_generator list
}

# --- Generate ---
generate() {
    detect_runner

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  OpenAPI Code Generator${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BLUE}  Spec:     $SPEC_FILE${NC}"
    echo -e "${BLUE}  Language: $LANGUAGE${NC}"
    echo -e "${BLUE}  Type:     $GEN_TYPE${NC}"
    echo -e "${BLUE}  Output:   $OUTPUT_DIR${NC}"

    if [[ -n "$ADDITIONAL_PROPS" ]]; then
        echo -e "${BLUE}  Props:    $ADDITIONAL_PROPS${NC}"
    fi
    echo ""

    # Build command
    local cmd_args=(generate -i "$SPEC_FILE" -g "$LANGUAGE" -o "$OUTPUT_DIR")

    if [[ -n "$ADDITIONAL_PROPS" ]]; then
        cmd_args+=(--additional-properties "$ADDITIONAL_PROPS")
    fi

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    echo -e "${CYAN}Generating $GEN_TYPE code...${NC}"
    echo ""

    if run_generator "${cmd_args[@]}"; then
        echo ""
        echo -e "${GREEN}✅ Code generated successfully!${NC}"
        echo -e "${GREEN}   Output: $OUTPUT_DIR${NC}"
        echo ""

        # Show generated file count
        local file_count
        file_count=$(find "$OUTPUT_DIR" -type f | wc -l)
        echo -e "${BLUE}   Files generated: $file_count${NC}"
        return 0
    else
        echo ""
        echo -e "${RED}❌ Code generation failed — see errors above.${NC}"
        return 1
    fi
}

# --- Main ---
main() {
    if [[ "$LIST_LANGS" == "true" ]]; then
        list_languages
        exit 0
    fi

    if [[ -z "$SPEC_FILE" ]]; then
        echo -e "${RED}Error: No spec file specified${NC}" >&2
        usage
    fi

    if [[ ! -f "$SPEC_FILE" ]]; then
        echo -e "${RED}Error: File not found: $SPEC_FILE${NC}" >&2
        exit 2
    fi

    if [[ -z "$LANGUAGE" ]]; then
        echo -e "${RED}Error: No language specified. Use -l <language>.${NC}" >&2
        echo ""
        echo "Popular options: typescript-axios, python, java, go, ruby, csharp"
        echo "Run with --list-languages to see all available generators."
        exit 2
    fi

    # Default output directory
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="./generated/$LANGUAGE"
    fi

    generate
}

main
