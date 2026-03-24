#!/usr/bin/env bash
#
# generate-proto.sh — Generate gRPC code from .proto files
#
# Supports: Go, Node.js/TypeScript, Python, Java
# Handles: well-known types, gRPC-Gateway stubs, imports
#
# Usage:
#   ./generate-proto.sh --lang go --proto-dir proto --out-dir gen/go
#   ./generate-proto.sh --lang python --proto-dir proto --out-dir gen/python
#   ./generate-proto.sh --lang node --proto-dir proto --out-dir gen/ts
#   ./generate-proto.sh --lang java --proto-dir proto --out-dir gen/java
#   ./generate-proto.sh --lang go --proto-dir proto --out-dir gen/go --gateway
#
# Prerequisites:
#   Go:     protoc-gen-go, protoc-gen-go-grpc (go install google.golang.org/...)
#   Node:   grpc_tools_node_protoc_plugin, ts-proto or @grpc/proto-loader
#   Python: grpcio-tools (pip install grpcio-tools)
#   Java:   protoc-gen-grpc-java
#   All:    protoc (or use buf)

set -euo pipefail

# --- Defaults ---
LANG=""
PROTO_DIR="proto"
OUT_DIR="gen"
GATEWAY=false
BUF_MODE=false
INCLUDE_PATHS=()
PROTO_FILES=()

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --lang LANG         Target language: go, node, python, java (required)
  --proto-dir DIR     Directory containing .proto files (default: proto)
  --out-dir DIR       Output directory for generated code (default: gen)
  --gateway           Generate gRPC-Gateway stubs (Go only)
  --buf               Use buf instead of protoc
  -I, --include DIR   Additional proto import path (can be repeated)
  --files FILES       Specific .proto files (default: all in proto-dir)
  -h, --help          Show this help

Examples:
  $(basename "$0") --lang go --proto-dir proto --out-dir gen/go
  $(basename "$0") --lang go --gateway --proto-dir proto --out-dir gen/go
  $(basename "$0") --lang python --proto-dir proto --out-dir gen/python
  $(basename "$0") --buf --lang go --out-dir gen/go
EOF
    exit 0
}

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lang)       LANG="$2"; shift 2 ;;
        --proto-dir)  PROTO_DIR="$2"; shift 2 ;;
        --out-dir)    OUT_DIR="$2"; shift 2 ;;
        --gateway)    GATEWAY=true; shift ;;
        --buf)        BUF_MODE=true; shift ;;
        -I|--include) INCLUDE_PATHS+=("$2"); shift 2 ;;
        --files)      shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do PROTO_FILES+=("$1"); shift; done ;;
        -h|--help)    usage ;;
        *)            log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$LANG" && "$BUF_MODE" == false ]]; then
    log_error "--lang is required (go, node, python, java)"
    exit 1
fi

# --- buf mode ---
if [[ "$BUF_MODE" == true ]]; then
    if ! command -v buf &>/dev/null; then
        log_error "buf is not installed. Install: https://buf.build/docs/installation"
        exit 1
    fi
    log_info "Generating code with buf..."
    buf generate
    log_info "Done. Run 'buf lint' to check for issues."
    exit 0
fi

# --- Validate ---
if ! command -v protoc &>/dev/null; then
    log_error "protoc is not installed."
    log_error "Install: https://grpc.io/docs/protoc-installation/"
    exit 1
fi

if [[ ! -d "$PROTO_DIR" ]]; then
    log_error "Proto directory not found: $PROTO_DIR"
    exit 1
fi

# Find proto files if not specified
if [[ ${#PROTO_FILES[@]} -eq 0 ]]; then
    while IFS= read -r -d '' file; do
        PROTO_FILES+=("$file")
    done < <(find "$PROTO_DIR" -name '*.proto' -print0)
fi

if [[ ${#PROTO_FILES[@]} -eq 0 ]]; then
    log_error "No .proto files found in $PROTO_DIR"
    exit 1
fi

# Build include path flags
INCLUDE_FLAGS=("-I" "$PROTO_DIR")
for inc in "${INCLUDE_PATHS[@]+"${INCLUDE_PATHS[@]}"}"; do
    INCLUDE_FLAGS+=("-I" "$inc")
done

# Add well-known types include path (common locations)
WELL_KNOWN_PATHS=(
    "/usr/local/include"
    "/usr/include"
    "$(brew --prefix 2>/dev/null)/include" 2>/dev/null || true
    "$HOME/.local/include"
)
for wkp in "${WELL_KNOWN_PATHS[@]}"; do
    if [[ -d "$wkp/google/protobuf" ]]; then
        INCLUDE_FLAGS+=("-I" "$wkp")
        break
    fi
done

mkdir -p "$OUT_DIR"

log_info "Language: $LANG"
log_info "Proto dir: $PROTO_DIR"
log_info "Output dir: $OUT_DIR"
log_info "Files: ${PROTO_FILES[*]}"

# --- Generate by language ---
case "$LANG" in
    go)
        # Check plugins
        for plugin in protoc-gen-go protoc-gen-go-grpc; do
            if ! command -v "$plugin" &>/dev/null; then
                log_error "$plugin not found. Install with:"
                log_error "  go install google.golang.org/protobuf/cmd/protoc-gen-go@latest"
                log_error "  go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest"
                exit 1
            fi
        done

        GATEWAY_FLAGS=()
        if [[ "$GATEWAY" == true ]]; then
            if ! command -v protoc-gen-grpc-gateway &>/dev/null; then
                log_error "protoc-gen-grpc-gateway not found. Install with:"
                log_error "  go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway@latest"
                exit 1
            fi
            GATEWAY_FLAGS=(
                "--grpc-gateway_out=$OUT_DIR"
                "--grpc-gateway_opt=paths=source_relative"
                "--grpc-gateway_opt=generate_unbound_methods=true"
            )
            log_info "gRPC-Gateway stubs enabled"
        fi

        protoc "${INCLUDE_FLAGS[@]}" \
            --go_out="$OUT_DIR" \
            --go_opt=paths=source_relative \
            --go-grpc_out="$OUT_DIR" \
            --go-grpc_opt=paths=source_relative \
            "${GATEWAY_FLAGS[@]+"${GATEWAY_FLAGS[@]}"}" \
            "${PROTO_FILES[@]}"
        ;;

    node|typescript|ts)
        log_info "Generating Node.js/TypeScript gRPC code..."

        # Option 1: grpc_tools_node_protoc_plugin (if available)
        if command -v grpc_tools_node_protoc_plugin &>/dev/null; then
            GRPC_NODE_PLUGIN="$(command -v grpc_tools_node_protoc_plugin)"
            protoc "${INCLUDE_FLAGS[@]}" \
                --js_out="import_style=commonjs,binary:$OUT_DIR" \
                --grpc_out="grpc_js:$OUT_DIR" \
                --plugin="protoc-gen-grpc=$GRPC_NODE_PLUGIN" \
                "${PROTO_FILES[@]}"

        # Option 2: ts-proto (TypeScript-first)
        elif command -v protoc-gen-ts_proto &>/dev/null; then
            protoc "${INCLUDE_FLAGS[@]}" \
                --ts_proto_out="$OUT_DIR" \
                --ts_proto_opt=outputServices=grpc-js \
                --ts_proto_opt=esModuleInterop=true \
                --ts_proto_opt=snakeToCamel=true \
                "${PROTO_FILES[@]}"
        else
            log_error "No Node.js proto plugin found. Install one of:"
            log_error "  npm install -g grpc_tools_node_protoc_plugin"
            log_error "  npm install -g ts-proto"
            exit 1
        fi
        ;;

    python|py)
        if ! python3 -c "import grpc_tools" 2>/dev/null; then
            log_error "grpcio-tools not installed. Install with:"
            log_error "  pip install grpcio-tools"
            exit 1
        fi

        python3 -m grpc_tools.protoc "${INCLUDE_FLAGS[@]}" \
            --python_out="$OUT_DIR" \
            --grpc_python_out="$OUT_DIR" \
            --pyi_out="$OUT_DIR" \
            "${PROTO_FILES[@]}"

        # Fix relative imports in generated Python files
        log_info "Fixing Python imports..."
        find "$OUT_DIR" -name '*_pb2_grpc.py' -exec sed -i.bak \
            's/^import \(.*\)_pb2 as/from . import \1_pb2 as/' {} +
        find "$OUT_DIR" -name '*.bak' -delete
        ;;

    java)
        if ! command -v protoc-gen-grpc-java &>/dev/null; then
            log_warn "protoc-gen-grpc-java not found — generating messages only."
            log_warn "For gRPC stubs, install protoc-gen-grpc-java or use the Gradle/Maven plugin."
            protoc "${INCLUDE_FLAGS[@]}" \
                --java_out="$OUT_DIR" \
                "${PROTO_FILES[@]}"
        else
            protoc "${INCLUDE_FLAGS[@]}" \
                --java_out="$OUT_DIR" \
                --grpc-java_out="$OUT_DIR" \
                "${PROTO_FILES[@]}"
        fi
        ;;

    *)
        log_error "Unsupported language: $LANG"
        log_error "Supported: go, node, python, java"
        exit 1
        ;;
esac

# Count generated files
GENERATED_COUNT=$(find "$OUT_DIR" -type f -newer "$0" 2>/dev/null | wc -l || echo "?")
log_info "Generation complete. Files in $OUT_DIR: $GENERATED_COUNT"
