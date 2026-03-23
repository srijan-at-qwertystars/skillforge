#!/usr/bin/env bash
#
# wg-rotate-keys.sh — Rotate WireGuard keys for a peer.
#
# Generates a new keypair, updates the local WireGuard config, and outputs
# the commands needed to update remote peers.
#
# Usage:
#   wg-rotate-keys.sh --interface <iface> [--backup] [--apply] [--config-dir <dir>]
#
# The script:
#   1. Generates a new keypair.
#   2. Backs up the current config (with --backup).
#   3. Updates the local config with the new private key.
#   4. Outputs the new public key and commands for updating peers.
#   5. Optionally applies changes (with --apply).

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_CONFIG_DIR="/etc/wireguard"
readonly BACKUP_RETAIN_DAYS=30

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Rotate WireGuard keys for a local interface.

Required:
  --interface <name>     WireGuard interface name (e.g., wg0)

Optional:
  --config-dir <dir>     Config directory (default: ${DEFAULT_CONFIG_DIR})
  --backup               Create timestamped backup before modifying
  --apply                Apply changes immediately (restart interface)
  --rotate-psk           Also rotate preshared keys (generates new PSK per peer)
  --dry-run              Show what would be done without making changes
  -h, --help             Show this help

Examples:
  # Generate new keys and show peer update commands
  ${SCRIPT_NAME} --interface wg0

  # Rotate with backup and auto-apply
  ${SCRIPT_NAME} --interface wg0 --backup --apply

  # Dry run — see what would happen
  ${SCRIPT_NAME} --interface wg0 --dry-run

Workflow:
  1. Run this script on the peer whose keys you want to rotate.
  2. Distribute the new public key to all remote peers.
  3. Update remote peer configs with the new public key.
  4. Restart or syncconf on remote peers.
  5. Verify handshakes with: wg show <interface>
EOF
    exit "${1:-0}"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root."
    fi
}

check_dependencies() {
    if ! command -v wg &>/dev/null; then
        die "wireguard-tools not installed."
    fi
}

# --- Parse arguments ---
INTERFACE=""
CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
DO_BACKUP=false
DO_APPLY=false
DO_ROTATE_PSK=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interface)    INTERFACE="$2"; shift 2 ;;
        --config-dir)   CONFIG_DIR="$2"; shift 2 ;;
        --backup)       DO_BACKUP=true; shift ;;
        --apply)        DO_APPLY=true; shift ;;
        --rotate-psk)   DO_ROTATE_PSK=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage 0 ;;
        *)              die "Unknown option: $1" ;;
    esac
done

[[ -z "$INTERFACE" ]] && die "Missing required option: --interface"

check_root
check_dependencies

readonly CONFIG_FILE="${CONFIG_DIR}/${INTERFACE}.conf"
readonly KEY_DIR="${CONFIG_DIR}"

# --- Validate config exists ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config file not found: ${CONFIG_FILE}"
fi

# --- Get current keys ---
CURRENT_PRIVKEY=$(grep -oP '(?<=^PrivateKey\s*=\s*).*' "$CONFIG_FILE" | tr -d '[:space:]')
if [[ -z "$CURRENT_PRIVKEY" ]]; then
    die "Could not find PrivateKey in ${CONFIG_FILE}"
fi

CURRENT_PUBKEY=$(echo "$CURRENT_PRIVKEY" | wg pubkey)
info "Current public key: ${CURRENT_PUBKEY}"

# --- Get list of peers from config ---
PEER_PUBKEYS=()
while IFS= read -r line; do
    key=$(echo "$line" | grep -oP '(?<=^PublicKey\s*=\s*).*' | tr -d '[:space:]')
    [[ -n "$key" ]] && PEER_PUBKEYS+=("$key")
done < "$CONFIG_FILE"

info "Found ${#PEER_PUBKEYS[@]} peer(s) in config."

# --- Generate new keypair ---
NEW_PRIVKEY=$(wg genkey)
NEW_PUBKEY=$(echo "$NEW_PRIVKEY" | wg pubkey)

info "New public key:     ${NEW_PUBKEY}"
echo ""

if $DRY_RUN; then
    echo "=== DRY RUN — No changes will be made ==="
    echo ""
    echo "Would update ${CONFIG_FILE}:"
    echo "  Old PrivateKey: ${CURRENT_PRIVKEY:0:10}...${CURRENT_PRIVKEY: -4}"
    echo "  New PrivateKey: ${NEW_PRIVKEY:0:10}...${NEW_PRIVKEY: -4}"
    echo ""
fi

# --- Backup ---
if $DO_BACKUP && ! $DRY_RUN; then
    BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    info "Backup created: ${BACKUP_FILE}"

    # Clean old backups
    find "${CONFIG_DIR}" -name "${INTERFACE}.conf.bak.*" -mtime +"${BACKUP_RETAIN_DAYS}" -delete 2>/dev/null || true
fi

# --- Update config ---
if ! $DRY_RUN; then
    # Replace private key in config
    sed -i "s|^PrivateKey\s*=\s*.*|PrivateKey = ${NEW_PRIVKEY}|" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    info "Updated PrivateKey in ${CONFIG_FILE}"

    # Save keys to files
    echo "$NEW_PRIVKEY" > "${KEY_DIR}/${INTERFACE}.key"
    echo "$NEW_PUBKEY" > "${KEY_DIR}/${INTERFACE}.pub"
    chmod 600 "${KEY_DIR}/${INTERFACE}.key"
    info "Saved new keypair to ${KEY_DIR}/${INTERFACE}.{key,pub}"
fi

# --- Rotate PSKs ---
if $DO_ROTATE_PSK; then
    echo ""
    info "Generating new preshared keys..."
    for peer_pub in "${PEER_PUBKEYS[@]}"; do
        NEW_PSK=$(wg genpsk)
        peer_short="${peer_pub:0:16}..."

        if $DRY_RUN; then
            echo "  Would generate new PSK for peer ${peer_short}"
        else
            echo "  New PSK for peer ${peer_short}: ${NEW_PSK}"
            echo "  (Update PresharedKey in both local and remote configs)"
        fi
    done
fi

# --- Apply changes ---
if $DO_APPLY && ! $DRY_RUN; then
    echo ""
    info "Applying changes..."

    if systemctl is-active --quiet "wg-quick@${INTERFACE}"; then
        # Try syncconf first (less disruptive)
        if wg syncconf "$INTERFACE" <(wg-quick strip "$INTERFACE") 2>/dev/null; then
            info "Applied via wg syncconf (no downtime)."
        else
            warn "syncconf failed, performing full restart..."
            systemctl restart "wg-quick@${INTERFACE}"
            info "Restarted wg-quick@${INTERFACE}."
        fi
    else
        wg-quick up "$INTERFACE" 2>/dev/null || systemctl start "wg-quick@${INTERFACE}"
        info "Started ${INTERFACE}."
    fi
fi

# --- Output peer update commands ---
echo ""
echo "============================================================"
echo "  PEER UPDATE INSTRUCTIONS"
echo "============================================================"
echo ""
echo "The local key has been rotated. All remote peers must update"
echo "their config to use the new public key."
echo ""
echo "New public key: ${NEW_PUBKEY}"
echo "Old public key: ${CURRENT_PUBKEY}"
echo ""

if [[ ${#PEER_PUBKEYS[@]} -gt 0 ]]; then
    echo "Run the following on each remote peer:"
    echo ""

    for peer_pub in "${PEER_PUBKEYS[@]}"; do
        peer_short="${peer_pub:0:16}..."
        echo "  # Update peer ${peer_short}'s config:"
        echo "  # In their WireGuard config, find the [Peer] block with:"
        echo "  #   PublicKey = ${CURRENT_PUBKEY}"
        echo "  # And replace with:"
        echo "  #   PublicKey = ${NEW_PUBKEY}"
        echo ""
        echo "  # Or update at runtime (on the remote peer):"
        echo "  wg set <interface> peer ${CURRENT_PUBKEY} remove"
        echo "  wg set <interface> peer ${NEW_PUBKEY} \\"
        echo "    allowed-ips <this_peer_allowed_ips> \\"
        echo "    endpoint <this_peer_endpoint>"
        echo ""
    done
fi

echo "After updating all peers, verify handshakes:"
echo "  wg show ${INTERFACE}"
echo ""
echo "Rollback (if needed):"
if $DO_BACKUP && ! $DRY_RUN; then
    echo "  cp ${BACKUP_FILE} ${CONFIG_FILE}"
else
    echo "  Replace PrivateKey in ${CONFIG_FILE} with:"
    echo "  ${CURRENT_PRIVKEY}"
fi
echo "  systemctl restart wg-quick@${INTERFACE}"
echo ""
echo "IMPORTANT: Keep the old private key available for 24-48h as rollback."
