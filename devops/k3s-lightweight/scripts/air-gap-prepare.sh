#!/usr/bin/env bash
#
# air-gap-prepare.sh — Prepare K3s air-gap installation bundle
#
# Downloads the K3s binary, air-gap images, install script, and checksums,
# then packages everything into a single tarball for offline installation.
#
# Usage:
#   ./air-gap-prepare.sh [OPTIONS]
#
# Options:
#   --version <VERSION>    K3s version (e.g., v1.30.2+k3s1). Default: latest stable
#   --arch <ARCH>          Target architecture: amd64, arm64, arm. Default: current host arch
#   --output <DIR>         Output directory. Default: ./k3s-airgap-bundle
#   --extra-images <FILE>  File with additional images to include (one per line)
#   --include-selinux      Include k3s-selinux RPM
#   --skip-verify          Skip checksum verification
#   -h, --help             Show this help
#
# Examples:
#   # Latest stable for current arch
#   ./air-gap-prepare.sh
#
#   # Specific version for ARM64
#   ./air-gap-prepare.sh --version v1.30.2+k3s1 --arch arm64
#
#   # Include extra application images
#   echo "nginx:1.25" > extra-images.txt
#   echo "redis:7" >> extra-images.txt
#   ./air-gap-prepare.sh --extra-images extra-images.txt

set -euo pipefail

# --- Defaults ---
K3S_VERSION=""
ARCH=""
OUTPUT_DIR="./k3s-airgap-bundle"
EXTRA_IMAGES_FILE=""
INCLUDE_SELINUX=false
SKIP_VERIFY=false
K3S_GITHUB="https://github.com/k3s-io/k3s/releases/download"
K3S_INSTALL_URL="https://get.k3s.io"
CHANNEL_URL="https://update.k3s.io/v1-release/channels/stable"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    sed -n '3,22p' "$0" | sed 's/^#\s\?//'
    exit 0
}

# --- Parse Args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)         K3S_VERSION="$2"; shift 2 ;;
        --arch)            ARCH="$2"; shift 2 ;;
        --output)          OUTPUT_DIR="$2"; shift 2 ;;
        --extra-images)    EXTRA_IMAGES_FILE="$2"; shift 2 ;;
        --include-selinux) INCLUDE_SELINUX=true; shift ;;
        --skip-verify)     SKIP_VERIFY=true; shift ;;
        -h|--help)         usage ;;
        *)                 log_error "Unknown option: $1"; usage ;;
    esac
done

# --- Detect Architecture ---
detect_arch() {
    if [[ -n "$ARCH" ]]; then
        return
    fi
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armhf)  ARCH="arm" ;;
        *)
            log_error "Unsupported architecture: $machine"
            exit 1
            ;;
    esac
    log_info "Detected architecture: ${ARCH}"
}

# --- Resolve Version ---
resolve_version() {
    if [[ -n "$K3S_VERSION" ]]; then
        log_info "Using specified version: ${K3S_VERSION}"
        return
    fi

    log_info "Resolving latest stable K3s version..."
    K3S_VERSION=$(curl -sfL "$CHANNEL_URL" -o /dev/null -w '%{redirect_url}' 2>/dev/null | \
        grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' || true)

    if [[ -z "$K3S_VERSION" ]]; then
        # Fallback: query GitHub API
        K3S_VERSION=$(curl -sfL "https://api.github.com/repos/k3s-io/k3s/releases/latest" | \
            grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    fi

    if [[ -z "$K3S_VERSION" ]]; then
        log_error "Could not determine latest K3s version. Use --version to specify."
        exit 1
    fi

    log_info "Latest stable version: ${K3S_VERSION}"
}

# --- Preflight ---
preflight() {
    local missing=()
    for cmd in curl sha256sum tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 1
    fi

    # Check for docker/nerdctl if extra images requested
    if [[ -n "$EXTRA_IMAGES_FILE" ]]; then
        if ! command -v docker &>/dev/null && ! command -v nerdctl &>/dev/null; then
            log_warn "docker or nerdctl not found — cannot pull extra images"
        fi
    fi

    # Check disk space (estimate ~500MB needed)
    local avail_mb
    avail_mb=$(df -m "$(dirname "$OUTPUT_DIR")" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$avail_mb" && "$avail_mb" -lt 500 ]]; then
        log_warn "Low disk space: ${avail_mb} MB available (500+ MB recommended)"
    fi
}

# --- Download ---
download_file() {
    local url="$1" dest="$2" description="$3"

    if [[ -f "$dest" ]]; then
        log_info "Already exists: $(basename "$dest")"
        return 0
    fi

    log_info "Downloading ${description}..."
    if curl -fSL --progress-bar "$url" -o "${dest}.tmp"; then
        mv "${dest}.tmp" "$dest"
        log_info "Downloaded: $(basename "$dest") ($(du -h "$dest" | awk '{print $1}'))"
    else
        rm -f "${dest}.tmp"
        log_error "Failed to download: $url"
        return 1
    fi
}

# --- Main Download ---
download_components() {
    mkdir -p "$OUTPUT_DIR"

    local version_urlsafe="${K3S_VERSION}"
    local base_url="${K3S_GITHUB}/${version_urlsafe}"

    # K3s binary
    local binary_name="k3s"
    if [[ "$ARCH" == "arm64" ]]; then
        binary_name="k3s-arm64"
    elif [[ "$ARCH" == "arm" ]]; then
        binary_name="k3s-armhf"
    fi
    download_file "${base_url}/${binary_name}" "${OUTPUT_DIR}/k3s" "K3s binary (${ARCH})"
    chmod +x "${OUTPUT_DIR}/k3s"

    # Air-gap images (try zst first, fall back to gz, then tar)
    local images_downloaded=false
    for ext in tar.zst tar.gz tar; do
        local images_name="k3s-airgap-images-${ARCH}.${ext}"
        if curl -sfL --head "${base_url}/${images_name}" > /dev/null 2>&1; then
            download_file "${base_url}/${images_name}" "${OUTPUT_DIR}/${images_name}" "Air-gap images (${ext})"
            images_downloaded=true
            break
        fi
    done
    if [[ "$images_downloaded" == "false" ]]; then
        log_error "Could not find air-gap images for ${ARCH}"
        exit 1
    fi

    # Install script
    download_file "$K3S_INSTALL_URL" "${OUTPUT_DIR}/install.sh" "Install script"
    chmod +x "${OUTPUT_DIR}/install.sh"

    # Checksums
    download_file "${base_url}/sha256sum-${ARCH}.txt" "${OUTPUT_DIR}/sha256sum-${ARCH}.txt" "Checksums"

    # SELinux RPM (optional)
    if [[ "$INCLUDE_SELINUX" == "true" ]]; then
        log_info "Downloading k3s-selinux RPM..."
        local selinux_url="https://rpm.rancher.io/k3s/stable/common/centos/8/noarch"
        local rpm_name
        rpm_name=$(curl -sfL "$selinux_url/" 2>/dev/null | grep -oP 'k3s-selinux-[0-9][^"]*\.rpm' | sort -V | tail -1 || true)
        if [[ -n "$rpm_name" ]]; then
            download_file "${selinux_url}/${rpm_name}" "${OUTPUT_DIR}/${rpm_name}" "k3s-selinux RPM"
        else
            log_warn "Could not find k3s-selinux RPM"
        fi
    fi
}

# --- Verify Checksums ---
verify_checksums() {
    if [[ "$SKIP_VERIFY" == "true" ]]; then
        log_warn "Skipping checksum verification"
        return
    fi

    local checksum_file="${OUTPUT_DIR}/sha256sum-${ARCH}.txt"
    if [[ ! -f "$checksum_file" ]]; then
        log_warn "Checksum file not found, skipping verification"
        return
    fi

    log_info "Verifying checksums..."
    cd "$OUTPUT_DIR"

    local verified=0 failed=0
    while IFS= read -r line; do
        local expected_hash file_name
        expected_hash=$(echo "$line" | awk '{print $1}')
        file_name=$(echo "$line" | awk '{print $2}')

        # Map binary name to local filename
        local local_file="$file_name"
        if [[ "$file_name" == "k3s-arm64" || "$file_name" == "k3s-armhf" ]]; then
            local_file="k3s"
        fi

        if [[ -f "$local_file" ]]; then
            local actual_hash
            actual_hash=$(sha256sum "$local_file" | awk '{print $1}')
            if [[ "$actual_hash" == "$expected_hash" ]]; then
                verified=$((verified + 1))
            else
                log_error "Checksum mismatch: $local_file"
                failed=$((failed + 1))
            fi
        fi
    done < "$checksum_file"

    cd - > /dev/null

    if [[ $failed -gt 0 ]]; then
        log_error "$failed file(s) failed checksum verification"
        exit 1
    fi
    log_info "Verified ${verified} file(s)"
}

# --- Extra Images ---
pull_extra_images() {
    if [[ -z "$EXTRA_IMAGES_FILE" || ! -f "$EXTRA_IMAGES_FILE" ]]; then
        return
    fi

    log_info "Pulling extra images from ${EXTRA_IMAGES_FILE}..."

    local runtime="docker"
    if ! command -v docker &>/dev/null; then
        if command -v nerdctl &>/dev/null; then
            runtime="nerdctl"
        else
            log_warn "No container runtime found, skipping extra images"
            return
        fi
    fi

    local images=()
    while IFS= read -r img; do
        img=$(echo "$img" | xargs)  # trim whitespace
        [[ -z "$img" || "$img" == \#* ]] && continue
        images+=("$img")
        log_info "Pulling: $img"
        $runtime pull "$img" || log_warn "Failed to pull: $img"
    done < "$EXTRA_IMAGES_FILE"

    if [[ ${#images[@]} -gt 0 ]]; then
        local extra_tar="${OUTPUT_DIR}/extra-images.tar"
        log_info "Saving ${#images[@]} extra images to ${extra_tar}..."
        $runtime save "${images[@]}" -o "$extra_tar"
        log_info "Extra images saved ($(du -h "$extra_tar" | awk '{print $1}'))"
    fi
}

# --- Generate Install Instructions ---
generate_instructions() {
    cat > "${OUTPUT_DIR}/INSTALL-INSTRUCTIONS.md" << 'INSTALL_EOF'
# Air-Gap K3s Installation Instructions

## Prerequisites
- Linux host (x86_64, ARM64, or ARMv7)
- Root or sudo access
- Systemd-based init system

## Server Installation

```bash
# 1. Extract the bundle
tar xzf k3s-airgap-bundle-*.tar.gz
cd k3s-airgap-bundle/

# 2. Install the K3s binary
sudo cp k3s /usr/local/bin/k3s
sudo chmod +x /usr/local/bin/k3s

# 3. Place air-gap images
sudo mkdir -p /var/lib/rancher/k3s/agent/images/
sudo cp k3s-airgap-images-*.tar* /var/lib/rancher/k3s/agent/images/

# 4. (Optional) Place extra application images
# sudo cp extra-images.tar /var/lib/rancher/k3s/agent/images/

# 5. (Optional) Create config file
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml << EOF
write-kubeconfig-mode: "0644"
# Add your configuration here
EOF

# 6. Run the install script
INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh

# 7. Verify
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
```

## Agent Installation

```bash
# Same steps 1-3 as above, then:
INSTALL_K3S_SKIP_DOWNLOAD=true K3S_URL=https://<SERVER_IP>:6443 \
  K3S_TOKEN=<TOKEN> ./install.sh
```

## HA Cluster (Embedded etcd)

```bash
# First server
INSTALL_K3S_SKIP_DOWNLOAD=true K3S_TOKEN=<SHARED_TOKEN> \
  INSTALL_K3S_EXEC="server --cluster-init --tls-san=<LB_IP>" ./install.sh

# Additional servers
INSTALL_K3S_SKIP_DOWNLOAD=true K3S_TOKEN=<SHARED_TOKEN> \
  INSTALL_K3S_EXEC="server --server https://<FIRST_SERVER>:6443 --tls-san=<LB_IP>" ./install.sh
```
INSTALL_EOF

    log_info "Install instructions written to ${OUTPUT_DIR}/INSTALL-INSTRUCTIONS.md"
}

# --- Create Final Bundle ---
create_bundle() {
    local bundle_name="k3s-airgap-bundle-${K3S_VERSION}-${ARCH}"
    local tarball="${bundle_name}.tar.gz"

    log_info "Creating bundle: ${tarball}"

    # Create manifest
    {
        echo "K3s Air-Gap Bundle"
        echo "=================="
        echo "Version: ${K3S_VERSION}"
        echo "Architecture: ${ARCH}"
        echo "Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Host: $(hostname)"
        echo ""
        echo "Contents:"
        ls -lh "$OUTPUT_DIR"/ | tail -n +2
    } > "${OUTPUT_DIR}/MANIFEST.txt"

    tar czf "$tarball" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"

    local bundle_size
    bundle_size=$(du -h "$tarball" | awk '{print $1}')

    echo ""
    log_info "============================================"
    log_info "Air-gap bundle created: ${tarball} (${bundle_size})"
    log_info "Version: ${K3S_VERSION}"
    log_info "Architecture: ${ARCH}"
    log_info "============================================"
    echo ""
    log_info "Transfer this file to your air-gapped systems and follow"
    log_info "the instructions in INSTALL-INSTRUCTIONS.md"
}

# --- Main ---
main() {
    echo -e "${BOLD}K3s Air-Gap Bundle Preparation${NC}"
    echo ""

    detect_arch
    resolve_version
    preflight
    download_components
    verify_checksums
    pull_extra_images
    generate_instructions
    create_bundle

    log_info "Done."
}

main
