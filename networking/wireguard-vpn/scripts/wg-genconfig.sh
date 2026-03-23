#!/usr/bin/env bash
#
# wg-genconfig.sh — Generate WireGuard server and client configuration files.
#
# Usage:
#   wg-genconfig.sh --endpoint <host:port> --subnet <cidr> --clients <n> [--output-dir <dir>]
#
# Example:
#   wg-genconfig.sh --endpoint vpn.example.com:51820 --subnet 10.0.0.0/24 --clients 5
#
# Generates:
#   - server/wg0.conf          (server configuration)
#   - client-1/wg0.conf        (client 1 configuration)
#   - client-N/wg0.conf        (client N configuration)
#   - keys/                    (all generated keys)

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_PORT=51820
readonly DEFAULT_DNS="1.1.1.1, 1.0.0.1"
readonly DEFAULT_MTU=1420
readonly DEFAULT_KEEPALIVE=25
readonly DEFAULT_OUTPUT_DIR="./wg-configs"

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Generate WireGuard server and client configuration files.

Required:
  --endpoint <host[:port]>   Server endpoint (hostname or IP, port defaults to ${DEFAULT_PORT})
  --subnet <cidr>            VPN subnet in CIDR notation (e.g., 10.0.0.0/24)
  --clients <n>              Number of client configs to generate (1-253)

Optional:
  --output-dir <dir>         Output directory (default: ${DEFAULT_OUTPUT_DIR})
  --dns <servers>            DNS servers, comma-separated (default: ${DEFAULT_DNS})
  --mtu <mtu>                MTU value (default: ${DEFAULT_MTU})
  --psk                      Generate preshared keys for each peer
  --interface <name>         WireGuard interface name (default: wg0)
  --wan-interface <name>     WAN interface for NAT rules (default: eth0)
  --split-tunnel <cidrs>     Comma-separated CIDRs for split tunneling
                             (default: full tunnel 0.0.0.0/0, ::/0)
  -h, --help                 Show this help message

Examples:
  # Basic setup with 3 clients
  ${SCRIPT_NAME} --endpoint vpn.example.com --subnet 10.0.0.0/24 --clients 3

  # With preshared keys and custom DNS
  ${SCRIPT_NAME} --endpoint 203.0.113.1:51820 --subnet 10.10.0.0/24 \\
    --clients 10 --psk --dns "9.9.9.9, 149.112.112.112"

  # Split tunnel for internal network only
  ${SCRIPT_NAME} --endpoint vpn.corp.com --subnet 172.16.0.0/24 --clients 5 \\
    --split-tunnel "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
EOF
    exit "${1:-0}"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

check_dependencies() {
    if ! command -v wg &>/dev/null; then
        die "wireguard-tools not installed. Install with: apt install wireguard-tools"
    fi
}

parse_endpoint() {
    local endpoint="$1"
    if [[ "$endpoint" == *:* ]]; then
        ENDPOINT_HOST="${endpoint%:*}"
        ENDPOINT_PORT="${endpoint##*:}"
    else
        ENDPOINT_HOST="$endpoint"
        ENDPOINT_PORT="${DEFAULT_PORT}"
    fi
}

parse_subnet() {
    local subnet="$1"
    if [[ ! "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        die "Invalid subnet format: ${subnet}. Expected CIDR notation (e.g., 10.0.0.0/24)"
    fi

    SUBNET_PREFIX="${subnet%.*}"
    SUBNET_MASK="${subnet#*/}"

    if [[ "$SUBNET_MASK" -gt 30 || "$SUBNET_MASK" -lt 8 ]]; then
        die "Subnet mask /${SUBNET_MASK} too restrictive. Use /8 to /30."
    fi
}

generate_keypair() {
    local dir="$1"
    local name="$2"
    mkdir -p "${dir}"
    wg genkey | tee "${dir}/${name}.key" | wg pubkey > "${dir}/${name}.pub"
    chmod 600 "${dir}/${name}.key"
}

generate_psk() {
    local dir="$1"
    local name="$2"
    wg genpsk > "${dir}/${name}.psk"
    chmod 600 "${dir}/${name}.psk"
}

# --- Parse arguments ---
ENDPOINT=""
SUBNET=""
NUM_CLIENTS=0
OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}"
DNS="${DEFAULT_DNS}"
MTU="${DEFAULT_MTU}"
USE_PSK=false
INTERFACE="wg0"
WAN_INTERFACE="eth0"
SPLIT_TUNNEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint)     ENDPOINT="$2"; shift 2 ;;
        --subnet)       SUBNET="$2"; shift 2 ;;
        --clients)      NUM_CLIENTS="$2"; shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --dns)          DNS="$2"; shift 2 ;;
        --mtu)          MTU="$2"; shift 2 ;;
        --psk)          USE_PSK=true; shift ;;
        --interface)    INTERFACE="$2"; shift 2 ;;
        --wan-interface) WAN_INTERFACE="$2"; shift 2 ;;
        --split-tunnel) SPLIT_TUNNEL="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        *)              die "Unknown option: $1. Use --help for usage." ;;
    esac
done

# --- Validate arguments ---
[[ -z "$ENDPOINT" ]] && die "Missing required option: --endpoint"
[[ -z "$SUBNET" ]] && die "Missing required option: --subnet"
[[ "$NUM_CLIENTS" -lt 1 || "$NUM_CLIENTS" -gt 253 ]] && die "Number of clients must be between 1 and 253"

check_dependencies
parse_endpoint "$ENDPOINT"
parse_subnet "$SUBNET"

# --- Set AllowedIPs for clients ---
if [[ -n "$SPLIT_TUNNEL" ]]; then
    CLIENT_ALLOWED_IPS="$SPLIT_TUNNEL"
else
    CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
fi

# --- Create output directory ---
mkdir -p "${OUTPUT_DIR}/keys"
echo "Generating WireGuard configuration..."
echo "  Endpoint:    ${ENDPOINT_HOST}:${ENDPOINT_PORT}"
echo "  Subnet:      ${SUBNET}"
echo "  Clients:     ${NUM_CLIENTS}"
echo "  Output:      ${OUTPUT_DIR}"
echo ""

# --- Generate server keypair ---
generate_keypair "${OUTPUT_DIR}/keys" "server"
SERVER_PRIVKEY=$(cat "${OUTPUT_DIR}/keys/server.key")
SERVER_PUBKEY=$(cat "${OUTPUT_DIR}/keys/server.pub")

# --- Generate client keypairs ---
declare -a CLIENT_PUBKEYS
declare -a CLIENT_PRIVKEYS
declare -a CLIENT_PSKS

for i in $(seq 1 "$NUM_CLIENTS"); do
    generate_keypair "${OUTPUT_DIR}/keys" "client-${i}"
    CLIENT_PRIVKEYS+=("$(cat "${OUTPUT_DIR}/keys/client-${i}.key")")
    CLIENT_PUBKEYS+=("$(cat "${OUTPUT_DIR}/keys/client-${i}.pub")")

    if $USE_PSK; then
        generate_psk "${OUTPUT_DIR}/keys" "client-${i}"
        CLIENT_PSKS+=("$(cat "${OUTPUT_DIR}/keys/client-${i}.psk")")
    fi
done

# --- Generate server config ---
SERVER_DIR="${OUTPUT_DIR}/server"
mkdir -p "${SERVER_DIR}"

cat > "${SERVER_DIR}/${INTERFACE}.conf" <<EOF
[Interface]
Address = ${SUBNET_PREFIX}.1/${SUBNET_MASK}
ListenPort = ${ENDPOINT_PORT}
PrivateKey = ${SERVER_PRIVKEY}
MTU = ${MTU}

# NAT and forwarding rules
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_INTERFACE} -j MASQUERADE
EOF

for i in $(seq 1 "$NUM_CLIENTS"); do
    idx=$((i - 1))
    CLIENT_IP="${SUBNET_PREFIX}.$((i + 1))"

    cat >> "${SERVER_DIR}/${INTERFACE}.conf" <<EOF

[Peer]
# Client ${i}
PublicKey = ${CLIENT_PUBKEYS[$idx]}
AllowedIPs = ${CLIENT_IP}/32
EOF

    if $USE_PSK; then
        echo "PresharedKey = ${CLIENT_PSKS[$idx]}" >> "${SERVER_DIR}/${INTERFACE}.conf"
    fi
done

chmod 600 "${SERVER_DIR}/${INTERFACE}.conf"
echo "  Created: ${SERVER_DIR}/${INTERFACE}.conf"

# --- Generate client configs ---
for i in $(seq 1 "$NUM_CLIENTS"); do
    idx=$((i - 1))
    CLIENT_IP="${SUBNET_PREFIX}.$((i + 1))"
    CLIENT_DIR="${OUTPUT_DIR}/client-${i}"
    mkdir -p "${CLIENT_DIR}"

    cat > "${CLIENT_DIR}/${INTERFACE}.conf" <<EOF
[Interface]
Address = ${CLIENT_IP}/${SUBNET_MASK}
PrivateKey = ${CLIENT_PRIVKEYS[$idx]}
DNS = ${DNS}
MTU = ${MTU}

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${ENDPOINT_HOST}:${ENDPOINT_PORT}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = ${DEFAULT_KEEPALIVE}
EOF

    if $USE_PSK; then
        # Insert PresharedKey in [Peer] section before PersistentKeepalive
        sed -i "/^Endpoint = /a PresharedKey = ${CLIENT_PSKS[$idx]}" "${CLIENT_DIR}/${INTERFACE}.conf"
    fi

    chmod 600 "${CLIENT_DIR}/${INTERFACE}.conf"
    echo "  Created: ${CLIENT_DIR}/${INTERFACE}.conf"
done

echo ""
echo "Configuration generated successfully."
echo ""
echo "Server public key: ${SERVER_PUBKEY}"
echo ""
echo "Next steps:"
echo "  1. Copy ${SERVER_DIR}/${INTERFACE}.conf to /etc/wireguard/ on the server"
echo "  2. Copy each client-N/${INTERFACE}.conf to /etc/wireguard/ on client N"
echo "  3. Enable IP forwarding on the server: sysctl -w net.ipv4.ip_forward=1"
echo "  4. Start: systemctl enable --now wg-quick@${INTERFACE}"
echo ""
echo "Key files are in: ${OUTPUT_DIR}/keys/"
echo "IMPORTANT: Protect private keys. Never share them or commit to version control."
