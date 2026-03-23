#!/usr/bin/env bash
# xcaddy-build.sh — Build custom Caddy with plugins using xcaddy
# Usage: ./xcaddy-build.sh [plugin_module_path...]
#
# Examples:
#   ./xcaddy-build.sh github.com/caddy-dns/cloudflare
#   ./xcaddy-build.sh github.com/caddy-dns/cloudflare github.com/mholt/caddy-ratelimit
#   ./xcaddy-build.sh --version v2.11.2 github.com/caddy-dns/cloudflare@v0.2.1
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BOLD}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }

CADDY_VERSION=""
PLUGINS=()
OUTPUT="./caddy"

# Popular plugin presets
declare -A PRESETS=(
    [dns-cloudflare]="github.com/caddy-dns/cloudflare"
    [dns-route53]="github.com/caddy-dns/route53"
    [dns-digitalocean]="github.com/caddy-dns/digitalocean"
    [dns-duckdns]="github.com/caddy-dns/duckdns"
    [ratelimit]="github.com/mholt/caddy-ratelimit"
    [security]="github.com/greenpau/caddy-security"
    [replace-response]="github.com/caddyserver/replace-response"
    [layer4]="github.com/mholt/caddy-l4"
    [maxmind-geoip]="github.com/porech/caddy-maxmind-geolocation"
    [storage-consul]="github.com/pteich/caddy-tlsconsul"
    [storage-redis]="github.com/pberkel/caddy-storage-redis"
    [storage-s3]="github.com/ss098/certmagic-s3"
    [transform-encoder]="github.com/caddyserver/transform-encoder"
)

usage() {
    echo -e "${BOLD}Usage:${NC} $0 [options] <plugin_module_paths...>"
    echo ""
    echo "Options:"
    echo "  --version <version>   Caddy version to build (e.g., v2.11.2)"
    echo "  --output <path>       Output binary path (default: ./caddy)"
    echo "  --list-presets        List available plugin presets"
    echo "  --preset <name>       Use a preset plugin (can repeat)"
    echo "  --help                Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 github.com/caddy-dns/cloudflare"
    echo "  $0 --preset dns-cloudflare --preset ratelimit"
    echo "  $0 --version v2.11.2 github.com/caddy-dns/cloudflare@v0.2.1"
    echo ""
    echo "Common plugins:"
    for key in "${!PRESETS[@]}"; do
        printf "  %-25s %s\n" "--preset $key" "${PRESETS[$key]}"
    done | sort
}

list_presets() {
    echo -e "${BOLD}Available Presets:${NC}"
    echo ""
    printf "  %-25s %s\n" "PRESET NAME" "MODULE PATH"
    printf "  %-25s %s\n" "-----------" "-----------"
    for key in $(echo "${!PRESETS[@]}" | tr ' ' '\n' | sort); do
        printf "  %-25s %s\n" "$key" "${PRESETS[$key]}"
    done
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            CADDY_VERSION="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --preset)
            if [[ -n "${PRESETS[$2]+x}" ]]; then
                PLUGINS+=("${PRESETS[$2]}")
            else
                fail "Unknown preset: $2 (run --list-presets to see available presets)"
            fi
            shift 2
            ;;
        --list-presets)
            list_presets
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            fail "Unknown option: $1"
            ;;
        *)
            PLUGINS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#PLUGINS[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No plugins specified${NC}"
    echo ""
    usage
    exit 1
fi

echo -e "${BOLD}=== xcaddy Custom Build ===${NC}"
echo ""

# --- Step 1: Check Go installation ---
info "Checking Go installation..."
if ! command -v go &>/dev/null; then
    warn "Go not found. Attempting to install..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq golang-go
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q golang
    elif command -v brew &>/dev/null; then
        brew install go
    else
        fail "Go is required but not installed. Install from https://go.dev/dl/"
    fi
fi

GO_VERSION="$(go version)"
success "Go found: $GO_VERSION"

# --- Step 2: Install xcaddy ---
info "Installing xcaddy..."
if ! command -v xcaddy &>/dev/null; then
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
    export PATH="$PATH:$(go env GOPATH)/bin"
    if ! command -v xcaddy &>/dev/null; then
        fail "xcaddy installation failed"
    fi
fi
success "xcaddy available: $(xcaddy version 2>/dev/null || echo 'installed')"

# --- Step 3: Build ---
echo ""
info "Building custom Caddy binary..."

BUILD_ARGS=()
if [[ -n "$CADDY_VERSION" ]]; then
    BUILD_ARGS+=("$CADDY_VERSION")
    info "Caddy version: $CADDY_VERSION"
fi

for plugin in "${PLUGINS[@]}"; do
    BUILD_ARGS+=("--with" "$plugin")
    info "  + $plugin"
done

BUILD_ARGS+=("--output" "$OUTPUT")

echo ""
info "Running: xcaddy build ${BUILD_ARGS[*]}"
echo ""

xcaddy build "${BUILD_ARGS[@]}"

echo ""
success "Build complete: $OUTPUT"

# --- Step 4: Verify ---
info "Verifying build..."
BUILT_VERSION="$("$OUTPUT" version 2>/dev/null)"
success "Caddy version: $BUILT_VERSION"

echo ""
info "Loaded modules:"
"$OUTPUT" list-modules 2>/dev/null | grep -v '^$' | head -30
echo "  ... (run '$OUTPUT list-modules' for full list)"

# --- Step 5: Installation guidance ---
echo ""
info "Next steps:"
echo "  1. Test: $OUTPUT validate --config Caddyfile"
echo "  2. Install: sudo install -m 0755 $OUTPUT /usr/local/bin/caddy"
echo "  3. Set capabilities: sudo setcap cap_net_bind_service=+ep /usr/local/bin/caddy"
echo "  4. Restart service: sudo systemctl restart caddy"
