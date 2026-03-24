#!/usr/bin/env bash
# wasm-build.sh — Build and optimize WASM modules
#
# Usage: wasm-build.sh <source-dir> [optimization-level]
#   source-dir          Project root directory
#   optimization-level  0-4 or "s"/"z" (default: "s")
#                       0=none, 1=basic, 2=moderate, 3=aggressive, 4=max, s=size, z=min-size
#
# Detects language (Rust/Go/C++) from project files, runs the appropriate
# build command, then applies wasm-opt if available.
#
# Environment variables:
#   WASM_BUILD_RELEASE=1    Force release build (default for opt > 0)
#   WASM_SKIP_OPT=1         Skip wasm-opt post-processing
#   WASM_TARGET=browser     Override auto-detected target (browser/wasi)

set -euo pipefail

SRC_DIR="${1:?Usage: $0 <source-dir> [optimization-level]}"
OPT_LEVEL="${2:-s}"
RELEASE="${WASM_BUILD_RELEASE:-}"
SKIP_OPT="${WASM_SKIP_OPT:-}"
TARGET_OVERRIDE="${WASM_TARGET:-}"

# Resolve to absolute path
SRC_DIR="$(cd "$SRC_DIR" && pwd)"

# Detect language
detect_language() {
    if [[ -f "$SRC_DIR/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$SRC_DIR/go.mod" ]] || ls "$SRC_DIR"/*.go &>/dev/null 2>&1; then
        echo "go"
    elif [[ -f "$SRC_DIR/CMakeLists.txt" ]] || [[ -f "$SRC_DIR/Makefile" ]]; then
        echo "cpp"
    elif [[ -f "$SRC_DIR/package.json" ]] && grep -q "assemblyscript" "$SRC_DIR/package.json" 2>/dev/null; then
        echo "assemblyscript"
    else
        echo "unknown"
    fi
}

# Map optimization level to tool-specific flags
rust_opt_flag() {
    case "$OPT_LEVEL" in
        0) echo "0" ;;
        1) echo "1" ;;
        2) echo "2" ;;
        3) echo "3" ;;
        4) echo "3" ;;  # Rust max is 3; wasm-opt handles 4
        s) echo "s" ;;
        z) echo "z" ;;
        *) echo "s" ;;
    esac
}

wasm_opt_flag() {
    case "$OPT_LEVEL" in
        0) echo "-O0" ;;
        1) echo "-O1" ;;
        2) echo "-O2" ;;
        3) echo "-O3" ;;
        4) echo "-O4" ;;
        s) echo "-Os" ;;
        z) echo "-Oz" ;;
        *) echo "-Os" ;;
    esac
}

# Determine if release build
if [[ -z "$RELEASE" ]]; then
    [[ "$OPT_LEVEL" != "0" ]] && RELEASE=1 || RELEASE=0
fi

LANG=$(detect_language)
echo "==> Detected language: $LANG"
echo "==> Optimization level: $OPT_LEVEL"
echo "==> Source directory: $SRC_DIR"

OUTPUT_WASM=""

case "$LANG" in
    rust)
        cd "$SRC_DIR"
        IS_COMPONENT=0
        grep -q "cargo-component" Cargo.toml 2>/dev/null && IS_COMPONENT=1
        grep -q 'cargo_component' Cargo.toml 2>/dev/null && IS_COMPONENT=1

        # Detect target
        if [[ -n "$TARGET_OVERRIDE" && "$TARGET_OVERRIDE" == "browser" ]]; then
            RUST_TARGET="wasm32-unknown-unknown"
        elif grep -q "wasm32-wasip2" .cargo/config.toml 2>/dev/null; then
            RUST_TARGET="wasm32-wasip2"
        elif grep -q "wasm32-wasip1" .cargo/config.toml 2>/dev/null || [[ $IS_COMPONENT -eq 1 ]]; then
            RUST_TARGET="wasm32-wasip1"
        elif grep -q "wasm-bindgen" Cargo.toml 2>/dev/null; then
            RUST_TARGET="wasm32-unknown-unknown"
        else
            RUST_TARGET="wasm32-wasip1"
        fi

        echo "==> Rust target: $RUST_TARGET"

        PROFILE_FLAG=""
        PROFILE_DIR="debug"
        if [[ "$RELEASE" == "1" ]]; then
            PROFILE_FLAG="--release"
            PROFILE_DIR="release"
        fi

        if [[ $IS_COMPONENT -eq 1 ]]; then
            echo "==> Building with cargo-component..."
            CARGO_PROFILE_RELEASE_OPT_LEVEL="$(rust_opt_flag)" \
                cargo component build $PROFILE_FLAG
        elif command -v wasm-pack &>/dev/null && [[ "$RUST_TARGET" == "wasm32-unknown-unknown" ]]; then
            echo "==> Building with wasm-pack..."
            if [[ "$RELEASE" == "1" ]]; then
                wasm-pack build --target web --release
            else
                wasm-pack build --target web --dev
            fi
        else
            echo "==> Building with cargo..."
            CARGO_PROFILE_RELEASE_OPT_LEVEL="$(rust_opt_flag)" \
                cargo build --target "$RUST_TARGET" $PROFILE_FLAG
        fi

        # Find output WASM
        CRATE_NAME=$(grep '^name' Cargo.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/' | tr '-' '_')
        OUTPUT_WASM=$(find "target/$RUST_TARGET/$PROFILE_DIR" -name "*.wasm" -maxdepth 1 2>/dev/null | head -1)
        if [[ -z "$OUTPUT_WASM" ]]; then
            OUTPUT_WASM=$(find target -name "*.wasm" -newer Cargo.toml 2>/dev/null | head -1)
        fi
        ;;

    go)
        cd "$SRC_DIR"
        if command -v tinygo &>/dev/null; then
            echo "==> Building with TinyGo..."
            if [[ "$TARGET_OVERRIDE" == "browser" ]]; then
                tinygo build -o app.wasm -target=wasm -opt="$(rust_opt_flag)" .
            else
                tinygo build -o app.wasm -target=wasip1 -opt="$(rust_opt_flag)" .
            fi
        else
            echo "==> Building with standard Go (browser target)..."
            GOOS=js GOARCH=wasm go build -o app.wasm .
        fi
        OUTPUT_WASM="$SRC_DIR/app.wasm"
        ;;

    cpp)
        cd "$SRC_DIR"
        if command -v emcc &>/dev/null; then
            echo "==> Building with Emscripten..."
            SOURCES=$(find . -name "*.c" -o -name "*.cpp" -o -name "*.cc" | head -20)
            emcc $SOURCES -o app.wasm \
                -O"$(rust_opt_flag)" \
                -s STANDALONE_WASM=1 \
                -s EXPORTED_FUNCTIONS='["_main"]' \
                --no-entry
            OUTPUT_WASM="$SRC_DIR/app.wasm"
        elif [[ -n "${WASI_SDK_PATH:-}" ]]; then
            echo "==> Building with WASI SDK..."
            SOURCES=$(find . -name "*.c" -o -name "*.cpp" -o -name "*.cc" | head -20)
            "$WASI_SDK_PATH/bin/clang" \
                --sysroot="$WASI_SDK_PATH/share/wasi-sysroot" \
                -O"$(rust_opt_flag)" \
                $SOURCES -o app.wasm
            OUTPUT_WASM="$SRC_DIR/app.wasm"
        else
            echo "Error: Neither emcc nor WASI_SDK_PATH found for C/C++ build" >&2
            exit 1
        fi
        ;;

    assemblyscript)
        cd "$SRC_DIR"
        echo "==> Building with AssemblyScript..."
        npx asc assembly/index.ts -o build/module.wasm --optimize
        OUTPUT_WASM="$SRC_DIR/build/module.wasm"
        ;;

    *)
        echo "Error: Could not detect project language in $SRC_DIR" >&2
        echo "Expected: Cargo.toml (Rust), go.mod (Go), CMakeLists.txt/Makefile (C++), or package.json with assemblyscript" >&2
        exit 1
        ;;
esac

if [[ -z "$OUTPUT_WASM" ]] || [[ ! -f "$OUTPUT_WASM" ]]; then
    echo "Error: Build succeeded but no .wasm output found" >&2
    exit 1
fi

ORIGINAL_SIZE=$(wc -c < "$OUTPUT_WASM")
echo "==> Build output: $OUTPUT_WASM ($ORIGINAL_SIZE bytes)"

# Apply wasm-opt if available and not skipped
if [[ "$SKIP_OPT" != "1" ]] && [[ "$OPT_LEVEL" != "0" ]] && command -v wasm-opt &>/dev/null; then
    OPT_FLAG=$(wasm_opt_flag)
    OPT_OUTPUT="${OUTPUT_WASM%.wasm}.opt.wasm"
    echo "==> Running wasm-opt $OPT_FLAG..."
    wasm-opt "$OPT_FLAG" --strip-debug --strip-producers \
        -o "$OPT_OUTPUT" "$OUTPUT_WASM" 2>&1 || {
        echo "Warning: wasm-opt failed, using unoptimized binary" >&2
        OPT_OUTPUT="$OUTPUT_WASM"
    }

    if [[ -f "$OPT_OUTPUT" ]] && [[ "$OPT_OUTPUT" != "$OUTPUT_WASM" ]]; then
        OPT_SIZE=$(wc -c < "$OPT_OUTPUT")
        SAVINGS=$(( (ORIGINAL_SIZE - OPT_SIZE) * 100 / ORIGINAL_SIZE ))
        echo "==> Optimized: $OPT_OUTPUT ($OPT_SIZE bytes, ${SAVINGS}% reduction)"
        mv "$OPT_OUTPUT" "$OUTPUT_WASM"
    fi
elif [[ "$SKIP_OPT" != "1" ]] && [[ "$OPT_LEVEL" != "0" ]]; then
    echo "==> wasm-opt not found — skipping post-optimization (install binaryen)"
fi

FINAL_SIZE=$(wc -c < "$OUTPUT_WASM")
echo ""
echo "✅ Build complete: $OUTPUT_WASM"
echo "   Size: $FINAL_SIZE bytes ($(( FINAL_SIZE / 1024 )) KiB)"
