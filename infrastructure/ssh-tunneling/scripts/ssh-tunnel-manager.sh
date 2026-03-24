#!/usr/bin/env bash
#
# ssh-tunnel-manager.sh — Manage persistent SSH tunnels
#
# Usage:
#   ssh-tunnel-manager.sh create <name> -L|-R|-D <forward-spec> <user@host> [options]
#   ssh-tunnel-manager.sh list
#   ssh-tunnel-manager.sh status <name>
#   ssh-tunnel-manager.sh destroy <name>
#   ssh-tunnel-manager.sh destroy-all
#   ssh-tunnel-manager.sh install-systemd <name>    # Create systemd service for auto-reconnect
#   ssh-tunnel-manager.sh uninstall-systemd <name>  # Remove systemd service
#
# Examples:
#   ssh-tunnel-manager.sh create db-tunnel -L 5432:db.internal:5432 ops@bastion
#   ssh-tunnel-manager.sh create socks -D 1080 user@proxy-server
#   ssh-tunnel-manager.sh create reverse -R 2222:localhost:22 user@public-server
#   ssh-tunnel-manager.sh list
#   ssh-tunnel-manager.sh destroy db-tunnel
#   ssh-tunnel-manager.sh install-systemd db-tunnel
#
# Requirements: ssh, autossh (optional, for persistent tunnels)
# Config dir: ~/.ssh/tunnels/

set -euo pipefail

TUNNEL_DIR="${HOME}/.ssh/tunnels"
SYSTEMD_DIR="/etc/systemd/system"

mkdir -p "$TUNNEL_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

cmd_create() {
    local name="$1"; shift
    [ -z "$name" ] && err "Tunnel name required"
    [ -f "$TUNNEL_DIR/$name.pid" ] && err "Tunnel '$name' already exists. Destroy it first."

    local forward_type="" forward_spec="" ssh_target="" extra_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -L|-R|-D)
                forward_type="$1"
                forward_spec="$2"
                shift 2
                ;;
            -*)
                extra_args+=("$1")
                shift
                ;;
            *)
                if [ -z "$ssh_target" ]; then
                    ssh_target="$1"
                else
                    extra_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    [ -z "$forward_type" ] && err "Forward type (-L, -R, or -D) required"
    [ -z "$ssh_target" ] && err "SSH target (user@host) required"

    # Build SSH command
    local ssh_cmd
    if command -v autossh &>/dev/null; then
        ssh_cmd=(autossh -M 0)
        log "Using autossh for persistent tunnel"
    else
        ssh_cmd=(ssh)
        log "Warning: autossh not found. Tunnel won't auto-reconnect."
    fi

    ssh_cmd+=(-N -f "$forward_type" "$forward_spec"
              -o "ServerAliveInterval=30"
              -o "ServerAliveCountMax=3"
              -o "ExitOnForwardFailure=yes"
              -o "StrictHostKeyChecking=accept-new"
              "${extra_args[@]}"
              "$ssh_target")

    # Save tunnel metadata
    cat > "$TUNNEL_DIR/$name.conf" <<EOF
NAME=$name
FORWARD_TYPE=$forward_type
FORWARD_SPEC=$forward_spec
SSH_TARGET=$ssh_target
EXTRA_ARGS=${extra_args[*]:-}
CREATED=$(date -Iseconds)
EOF

    # Start the tunnel
    "${ssh_cmd[@]}"

    # Find and save PID
    sleep 1
    local pid
    pid=$(pgrep -f "ssh.*${forward_type}.*${forward_spec}.*${ssh_target}" | tail -1 || true)
    if [ -n "$pid" ]; then
        echo "$pid" > "$TUNNEL_DIR/$name.pid"
        log "Tunnel '$name' created (PID: $pid)"
        log "  Forward: $forward_type $forward_spec via $ssh_target"
    else
        err "Tunnel process not found. Check SSH connectivity."
    fi
}

cmd_list() {
    local found=0
    printf "%-20s %-8s %-6s %-25s %s\n" "NAME" "STATUS" "PID" "FORWARD" "TARGET"
    printf "%-20s %-8s %-6s %-25s %s\n" "----" "------" "---" "-------" "------"

    for conf in "$TUNNEL_DIR"/*.conf 2>/dev/null; do
        [ -f "$conf" ] || continue
        found=1
        source "$conf"
        local pid_file="$TUNNEL_DIR/$NAME.pid"
        local pid="" status="DEAD"

        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                status="RUNNING"
            else
                status="DEAD"
                pid="—"
            fi
        fi

        printf "%-20s %-8s %-6s %-25s %s\n" "$NAME" "$status" "${pid:-—}" "$FORWARD_TYPE $FORWARD_SPEC" "$SSH_TARGET"
    done

    [ "$found" -eq 0 ] && echo "No tunnels configured."
}

cmd_status() {
    local name="$1"
    [ -z "$name" ] && err "Tunnel name required"
    [ ! -f "$TUNNEL_DIR/$name.conf" ] && err "Tunnel '$name' not found"

    source "$TUNNEL_DIR/$name.conf"
    echo "Tunnel: $NAME"
    echo "  Forward: $FORWARD_TYPE $FORWARD_SPEC"
    echo "  Target:  $SSH_TARGET"
    echo "  Created: $CREATED"
    echo "  Extra:   ${EXTRA_ARGS:-none}"

    if [ -f "$TUNNEL_DIR/$name.pid" ]; then
        local pid
        pid=$(cat "$TUNNEL_DIR/$name.pid")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Status:  RUNNING (PID: $pid)"
        else
            echo "  Status:  DEAD (stale PID: $pid)"
        fi
    else
        echo "  Status:  NO PID FILE"
    fi
}

cmd_destroy() {
    local name="$1"
    [ -z "$name" ] && err "Tunnel name required"
    [ ! -f "$TUNNEL_DIR/$name.conf" ] && err "Tunnel '$name' not found"

    if [ -f "$TUNNEL_DIR/$name.pid" ]; then
        local pid
        pid=$(cat "$TUNNEL_DIR/$name.pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log "Stopped tunnel process (PID: $pid)"
        fi
        rm -f "$TUNNEL_DIR/$name.pid"
    fi

    rm -f "$TUNNEL_DIR/$name.conf"
    log "Tunnel '$name' destroyed"
}

cmd_destroy_all() {
    for conf in "$TUNNEL_DIR"/*.conf 2>/dev/null; do
        [ -f "$conf" ] || continue
        source "$conf"
        cmd_destroy "$NAME"
    done
    log "All tunnels destroyed"
}

cmd_install_systemd() {
    local name="$1"
    [ -z "$name" ] && err "Tunnel name required"
    [ ! -f "$TUNNEL_DIR/$name.conf" ] && err "Tunnel '$name' not found"

    command -v autossh &>/dev/null || err "autossh required for systemd service"

    source "$TUNNEL_DIR/$name.conf"

    local service_file="$SYSTEMD_DIR/ssh-tunnel-${name}.service"
    sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=SSH Tunnel: $NAME ($FORWARD_TYPE $FORWARD_SPEC -> $SSH_TARGET)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N $FORWARD_TYPE $FORWARD_SPEC \\
  -o "ServerAliveInterval=30" \\
  -o "ServerAliveCountMax=3" \\
  -o "ExitOnForwardFailure=yes" \\
  $EXTRA_ARGS \\
  $SSH_TARGET
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now "ssh-tunnel-${name}"
    log "Systemd service 'ssh-tunnel-${name}' installed and started"
    log "  Manage: systemctl {start|stop|status|restart} ssh-tunnel-${name}"
    log "  Logs:   journalctl -u ssh-tunnel-${name} -f"
}

cmd_uninstall_systemd() {
    local name="$1"
    [ -z "$name" ] && err "Tunnel name required"

    local service="ssh-tunnel-${name}"
    if systemctl is-active "$service" &>/dev/null; then
        sudo systemctl stop "$service"
    fi
    sudo systemctl disable "$service" 2>/dev/null || true
    sudo rm -f "$SYSTEMD_DIR/${service}.service"
    sudo systemctl daemon-reload
    log "Systemd service '$service' uninstalled"
}

# --- Main ---
[ $# -lt 1 ] && { echo "Usage: $0 {create|list|status|destroy|destroy-all|install-systemd|uninstall-systemd} [args]"; exit 1; }

command="$1"; shift
case "$command" in
    create)           cmd_create "$@" ;;
    list)             cmd_list ;;
    status)           cmd_status "${1:-}" ;;
    destroy)          cmd_destroy "${1:-}" ;;
    destroy-all)      cmd_destroy_all ;;
    install-systemd)  cmd_install_systemd "${1:-}" ;;
    uninstall-systemd) cmd_uninstall_systemd "${1:-}" ;;
    *)                err "Unknown command: $command" ;;
esac
