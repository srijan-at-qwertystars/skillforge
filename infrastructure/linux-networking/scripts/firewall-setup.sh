#!/usr/bin/env bash
# =============================================================================
# firewall-setup.sh — Interactive Firewall Setup (iptables, nftables, ufw)
# =============================================================================
# Usage: sudo ./firewall-setup.sh [--backend iptables|nftables|ufw]
#                                 [--preset minimal|web|database|docker]
#                                 [--dry-run]
#
# Without arguments, presents an interactive menu.
#
# Presets:
#   minimal  — SSH only (default deny inbound)
#   web      — SSH + HTTP/HTTPS + optional mail ports
#   database — SSH + MySQL/PostgreSQL from specific subnets
#   docker   — SSH + HTTP/HTTPS + Docker-compatible rules
#
# Examples:
#   sudo ./firewall-setup.sh                              # interactive
#   sudo ./firewall-setup.sh --backend ufw --preset web   # non-interactive
#   sudo ./firewall-setup.sh --dry-run --preset minimal   # preview rules
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

BACKEND=""
PRESET=""
DRY_RUN=false
SSH_PORT=22
ALLOWED_SUBNETS=""

msg()  { echo -e "${CYAN}→${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1" >&2; }

die() { err "$1"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

detect_backend() {
    if command -v nft &>/dev/null && nft list tables &>/dev/null 2>&1; then
        echo "nftables"
    elif command -v ufw &>/dev/null; then
        echo "ufw"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        die "No supported firewall backend found (iptables, nftables, or ufw required)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Rule generators
# ─────────────────────────────────────────────────────────────────────────────

generate_iptables_minimal() {
    cat <<EOF
# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# ICMP (ping)
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT

# SSH (rate-limited)
iptables -A INPUT -p tcp --dport ${SSH_PORT} -m conntrack --ctstate NEW -m recent --set --name SSH
iptables -A INPUT -p tcp --dport ${SSH_PORT} -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 5 --name SSH -j DROP
iptables -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT

# Log and drop everything else
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "FW-DROP: " --log-level 4
iptables -A INPUT -j DROP
EOF
}

generate_iptables_web() {
    generate_iptables_minimal | sed '/# Log and drop/,$d'
    cat <<EOF

# HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Log and drop everything else
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "FW-DROP: " --log-level 4
iptables -A INPUT -j DROP
EOF
}

generate_iptables_database() {
    local subnet="${ALLOWED_SUBNETS:-10.0.0.0/8}"
    generate_iptables_minimal | sed '/# Log and drop/,$d'
    cat <<EOF

# MySQL (from internal only)
iptables -A INPUT -p tcp --dport 3306 -s ${subnet} -j ACCEPT

# PostgreSQL (from internal only)
iptables -A INPUT -p tcp --dport 5432 -s ${subnet} -j ACCEPT

# Log and drop everything else
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "FW-DROP: " --log-level 4
iptables -A INPUT -j DROP
EOF
}

generate_iptables_docker() {
    generate_iptables_web | sed '/# Log and drop/,$d'
    cat <<EOF

# Docker (allow forwarding for containers)
iptables -P FORWARD ACCEPT
iptables -A FORWARD -i docker0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o docker0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Log and drop INPUT (FORWARD is open for Docker)
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "FW-DROP: " --log-level 4
iptables -A INPUT -j DROP
EOF
}

generate_nftables_minimal() {
    cat <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iif lo accept
    ct state established,related accept
    ct state invalid drop

    # ICMP
    ip protocol icmp limit rate 5/second accept

    # SSH (rate-limited)
    tcp dport ${SSH_PORT} ct state new limit rate 5/minute burst 10 packets accept

    # Logging
    limit rate 5/minute burst 10 packets log prefix "NFT-DROP: " level warn
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF
}

generate_nftables_web() {
    generate_nftables_minimal | sed 's/# Logging/# HTTP\/HTTPS\n    tcp dport { 80, 443 } accept\n\n    # Logging/'
}

generate_nftables_database() {
    local subnet="${ALLOWED_SUBNETS:-10.0.0.0/8}"
    generate_nftables_minimal | sed "s/# Logging/# Database (internal only)\n    ip saddr ${subnet} tcp dport { 3306, 5432 } accept\n\n    # Logging/"
}

generate_nftables_docker() {
    generate_nftables_web | sed 's/policy drop;$/policy accept;/' | sed '/chain forward/,/}/ s/policy drop;/policy accept;/'
}

generate_ufw_rules() {
    local preset="$1"
    cat <<EOF
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw limit ${SSH_PORT}/tcp
EOF

    case "$preset" in
        web)
            cat <<EOF
ufw allow 80/tcp
ufw allow 443/tcp
EOF
            ;;
        database)
            local subnet="${ALLOWED_SUBNETS:-10.0.0.0/8}"
            cat <<EOF
ufw allow from ${subnet} to any port 3306
ufw allow from ${subnet} to any port 5432
EOF
            ;;
        docker)
            cat <<EOF
ufw allow 80/tcp
ufw allow 443/tcp
# Note: Docker modifies iptables directly. Consider docker-compose with
# network_mode or ufw-docker utility for proper integration.
EOF
            ;;
    esac

    cat <<EOF
ufw logging on
ufw --force enable
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Interactive menu
# ─────────────────────────────────────────────────────────────────────────────

interactive_menu() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║              Interactive Firewall Setup                      ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Backend selection
    if [[ -z "$BACKEND" ]]; then
        echo -e "${BOLD}Select firewall backend:${NC}"
        echo "  1) iptables"
        echo "  2) nftables"
        echo "  3) ufw"
        echo "  4) auto-detect"
        read -rp "Choice [4]: " choice
        case "${choice:-4}" in
            1) BACKEND="iptables" ;;
            2) BACKEND="nftables" ;;
            3) BACKEND="ufw" ;;
            4) BACKEND=$(detect_backend) ;;
            *) die "Invalid choice" ;;
        esac
        ok "Backend: $BACKEND"
    fi

    # Preset selection
    if [[ -z "$PRESET" ]]; then
        echo ""
        echo -e "${BOLD}Select preset:${NC}"
        echo "  1) minimal  — SSH only"
        echo "  2) web      — SSH + HTTP/HTTPS"
        echo "  3) database — SSH + MySQL/PostgreSQL (internal)"
        echo "  4) docker   — SSH + HTTP/HTTPS + Docker forwarding"
        read -rp "Choice [1]: " choice
        case "${choice:-1}" in
            1) PRESET="minimal" ;;
            2) PRESET="web" ;;
            3) PRESET="database" ;;
            4) PRESET="docker" ;;
            *) die "Invalid choice" ;;
        esac
        ok "Preset: $PRESET"
    fi

    # SSH port
    echo ""
    read -rp "SSH port [${SSH_PORT}]: " port
    SSH_PORT="${port:-$SSH_PORT}"

    # Subnet for database preset
    if [[ "$PRESET" == "database" ]]; then
        read -rp "Allowed subnet for DB access [10.0.0.0/8]: " subnet
        ALLOWED_SUBNETS="${subnet:-10.0.0.0/8}"
    fi

    # Confirmation
    echo ""
    echo -e "${BOLD}Configuration:${NC}"
    echo "  Backend: $BACKEND"
    echo "  Preset:  $PRESET"
    echo "  SSH:     port $SSH_PORT"
    [[ -n "$ALLOWED_SUBNETS" ]] && echo "  Subnet:  $ALLOWED_SUBNETS"
    echo ""
    read -rp "Apply these rules? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."
}

# ─────────────────────────────────────────────────────────────────────────────
# Apply rules
# ─────────────────────────────────────────────────────────────────────────────

apply_rules() {
    local rules=""

    case "$BACKEND" in
        iptables)
            case "$PRESET" in
                minimal)  rules=$(generate_iptables_minimal) ;;
                web)      rules=$(generate_iptables_web) ;;
                database) rules=$(generate_iptables_database) ;;
                docker)   rules=$(generate_iptables_docker) ;;
            esac
            ;;
        nftables)
            case "$PRESET" in
                minimal)  rules=$(generate_nftables_minimal) ;;
                web)      rules=$(generate_nftables_web) ;;
                database) rules=$(generate_nftables_database) ;;
                docker)   rules=$(generate_nftables_docker) ;;
            esac
            ;;
        ufw)
            rules=$(generate_ufw_rules "$PRESET")
            ;;
    esac

    if $DRY_RUN; then
        echo ""
        echo -e "${BOLD}${YELLOW}DRY RUN — Rules that would be applied:${NC}"
        echo "─────────────────────────────────────────"
        echo "$rules"
        echo "─────────────────────────────────────────"
        return
    fi

    msg "Applying firewall rules..."

    case "$BACKEND" in
        iptables|ufw)
            echo "$rules" | while IFS= read -r line; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                eval "$line" || warn "Failed: $line"
            done
            if [[ "$BACKEND" == "iptables" ]]; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                ok "iptables rules saved to /etc/iptables/rules.v4"
            fi
            ;;
        nftables)
            echo "$rules" > /etc/nftables.conf
            nft -f /etc/nftables.conf
            ok "nftables rules saved to /etc/nftables.conf"
            ;;
    esac

    ok "Firewall rules applied successfully!"
    echo ""
    warn "IMPORTANT: Verify you can still SSH in before closing this session!"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend)  BACKEND="$2"; shift 2 ;;
            --preset)   PRESET="$2"; shift 2 ;;
            --dry-run)  DRY_RUN=true; shift ;;
            --ssh-port) SSH_PORT="$2"; shift 2 ;;
            --subnet)   ALLOWED_SUBNETS="$2"; shift 2 ;;
            -h|--help)
                head -16 "$0" | tail -15
                exit 0
                ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    if ! $DRY_RUN; then
        check_root
    fi

    if [[ -z "$BACKEND" || -z "$PRESET" ]]; then
        interactive_menu
    fi

    apply_rules
}

main "$@"
