#!/usr/bin/env bash
# =============================================================================
# generate-client.sh — Generate a client SDK from an OpenAPI spec
#
# Usage:
#   ./generate-client.sh <spec-file> [options]
#
# Options:
#   -g, --generator     Generator name (default: typescript-axios)
#   -o, --output        Output directory (default: ./generated-client)
#   -c, --config        Configuration file (YAML or JSON)
#   -n, --name          Package/module name (default: api-client)
#   -v, --version       Package version (default: 1.0.0)
#   --models-only       Generate only model/type definitions
#   --dry-run           Preview generated files without writing
#   -h, --help          Show this help message
#
# Examples:
#   ./generate-client.sh openapi.yaml
#   ./generate-client.sh openapi.yaml -g python -o ./python-client -n my_api
#   ./generate-client.sh openapi.yaml -g java --config generator-config.yaml
#   ./generate-client.sh openapi.yaml --models-only -g typescript-axios
#   ./generate-client.sh openapi.yaml --dry-run
#
# Supported generators (common):
#   typescript-axios, typescript-fetch, python, java, go, csharp,
#   kotlin, swift5, rust, ruby, php, dart
#
# Prerequisites:
#   npm install -g @openapitools/openapi-generator-cli
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
SPEC_FILE=""
GENERATOR="typescript-axios"
OUTPUT_DIR="./generated-client"
CONFIG_FILE=""
PACKAGE_NAME="api-client"
PACKAGE_VERSION="1.0.0"
MODELS_ONLY=false
DRY_RUN=false

usage() {
  sed -n '/^# ====/,/^# ====/{ /^# ====/d; s/^# //; s/^#//; p; }' "$0" | head -n 25
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -g|--generator) GENERATOR="$2"; shift 2 ;;
    -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -n|--name) PACKAGE_NAME="$2"; shift 2 ;;
    -v|--version) PACKAGE_VERSION="$2"; shift 2 ;;
    --models-only) MODELS_ONLY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) SPEC_FILE="$1"; shift ;;
  esac
done

if [ -z "$SPEC_FILE" ]; then
  echo -e "${RED}Error: No spec file specified.${NC}"
  usage
fi

if [ ! -f "$SPEC_FILE" ]; then
  echo -e "${RED}Error: File not found: $SPEC_FILE${NC}"
  exit 2
fi

# Check for openapi-generator-cli
if ! command -v openapi-generator-cli &>/dev/null; then
  echo -e "${YELLOW}openapi-generator-cli not found. Attempting npx...${NC}"
  GENERATOR_CMD="npx --yes @openapitools/openapi-generator-cli"
else
  GENERATOR_CMD="openapi-generator-cli"
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  OpenAPI Client Generation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Spec file:   $SPEC_FILE"
echo "  Generator:   $GENERATOR"
echo "  Output:      $OUTPUT_DIR"
echo "  Package:     $PACKAGE_NAME@$PACKAGE_VERSION"
echo "  Models only: $MODELS_ONLY"
echo "  Dry run:     $DRY_RUN"
echo ""

# Build the generation command
CMD_ARGS=("generate" "-i" "$SPEC_FILE" "-g" "$GENERATOR" "-o" "$OUTPUT_DIR")

# Add config file if specified
if [ -n "$CONFIG_FILE" ]; then
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 2
  fi
  CMD_ARGS+=("-c" "$CONFIG_FILE")
fi

# Build additional properties based on generator type
ADDITIONAL_PROPS=()
case $GENERATOR in
  typescript-axios|typescript-fetch|typescript-angular|typescript-node)
    ADDITIONAL_PROPS+=(
      "supportsES6=true"
      "npmName=$PACKAGE_NAME"
      "npmVersion=$PACKAGE_VERSION"
      "withInterfaces=true"
    )
    ;;
  python)
    ADDITIONAL_PROPS+=(
      "packageName=$(echo "$PACKAGE_NAME" | tr '-' '_')"
      "projectName=$PACKAGE_NAME"
      "packageVersion=$PACKAGE_VERSION"
      "pydanticV2=true"
    )
    ;;
  java)
    ADDITIONAL_PROPS+=(
      "artifactId=$PACKAGE_NAME"
      "groupId=com.example"
      "artifactVersion=$PACKAGE_VERSION"
      "dateLibrary=java8"
      "useJakartaEe=true"
      "openApiNullable=false"
    )
    ;;
  go)
    ADDITIONAL_PROPS+=(
      "packageName=$(echo "$PACKAGE_NAME" | tr '-' '_')"
      "generateInterfaces=true"
      "isGoSubmodule=true"
    )
    ;;
  csharp)
    ADDITIONAL_PROPS+=(
      "packageName=$PACKAGE_NAME"
      "targetFramework=net8.0"
      "nullableReferenceTypes=true"
    )
    ;;
  kotlin)
    ADDITIONAL_PROPS+=(
      "artifactId=$PACKAGE_NAME"
      "groupId=com.example"
      "artifactVersion=$PACKAGE_VERSION"
    )
    ;;
  *)
    ADDITIONAL_PROPS+=("packageName=$PACKAGE_NAME")
    ;;
esac

if [ ${#ADDITIONAL_PROPS[@]} -gt 0 ]; then
  PROPS_STRING=$(IFS=,; echo "${ADDITIONAL_PROPS[*]}")
  CMD_ARGS+=("--additional-properties=$PROPS_STRING")
fi

# Models-only mode
if [ "$MODELS_ONLY" = true ]; then
  CMD_ARGS+=("--global-property" "models,modelDocs=false,modelTests=false")
fi

# Dry run mode
if [ "$DRY_RUN" = true ]; then
  CMD_ARGS+=("--dry-run")
fi

echo -e "${BLUE}Running: $GENERATOR_CMD ${CMD_ARGS[*]}${NC}"
echo ""

# Execute
$GENERATOR_CMD "${CMD_ARGS[@]}"

if [ "$DRY_RUN" = false ]; then
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  Client generated successfully!${NC}"
  echo -e "${GREEN}  Output: $OUTPUT_DIR${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Post-generation instructions
  case $GENERATOR in
    typescript-*)
      echo ""
      echo "  Next steps:"
      echo "    cd $OUTPUT_DIR && npm install && npm run build"
      ;;
    python)
      echo ""
      echo "  Next steps:"
      echo "    cd $OUTPUT_DIR && pip install -e ."
      ;;
    java|kotlin)
      echo ""
      echo "  Next steps:"
      echo "    cd $OUTPUT_DIR && mvn install"
      ;;
    go)
      echo ""
      echo "  Next steps:"
      echo "    cd $OUTPUT_DIR && go mod tidy"
      ;;
  esac
fi
