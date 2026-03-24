#!/usr/bin/env bash
#
# ssh-key-setup.sh — Automated SSH key setup for new hosts
#
# Usage:
#   ssh-key-setup.sh <user@host> [options]
#
# Options:
#   -n, --name <name>       Key name / config alias (default: derived from host)
#   -t, --type <type>       Key type: ed25519 (default), ecdsa, rsa
#   -p, --port <port>       SSH port (default: 22)
#   -j, --jump <jump-host>  Jump/bastion host for ProxyJump
#   -k, --key <path>        Use existing key instead of generating new one
#   --no-agent              Don't add key to ssh-agent
#   --no-config             Don't create ~/.ssh/config entry
#   --dry-run               Show what would be done without making changes
#
# Examples:
#   ssh-key-setup.sh deploy@prod.example.com
#   ssh-key-setup.sh ops@bastion.corp -n bastion -p 2222
#   ssh-key-setup.sh admin@internal-host -j bastion -n internal
#   ssh-key-setup.sh deploy@server -k ~/.ssh/existing_key
#
# What it does:
#   1. Generates an Ed25519 SSH key pair (or uses existing)
#   2. Copies the public key to the remote host
#   3. Adds the key to ssh-agent with optional TTL
#   4. Creates/updates ~/.ssh/config entry with best practices
#   5. Verifies the connection works
#   6. Sets correct file permissions

set -euo pipefail

# Defaults
KEY_TYPE="ed25519"
PORT=22
JUMP_HOST=""
KEY_NAME=""
EXISTING_KEY=""
ADD_AGENT=true
CREATE_CONFIG=true
DRY_RUN=false

log()  { echo -e "\033[32m[✓]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*"; }
err()  { echo -e "\033[31m[✗]\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[34m[i]\033[0m $*"; }

usage() {
    head -25 "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

parse_args() {
    [ $# -lt 1 ] && usage

    SSH_TARGET=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--name)      KEY_NAME="$2"; shift 2 ;;
            -t|--type)      KEY_TYPE="$2"; shift 2 ;;
            -p|--port)      PORT="$2"; shift 2 ;;
            -j|--jump)      JUMP_HOST="$2"; shift 2 ;;
            -k|--key)       EXISTING_KEY="$2"; shift 2 ;;
            --no-agent)     ADD_AGENT=false; shift ;;
            --no-config)    CREATE_CONFIG=false; shift ;;
            --dry-run)      DRY_RUN=true; shift ;;
            -h|--help)      usage ;;
            -*)             err "Unknown option: $1" ;;
            *)
                if [ -z "$SSH_TARGET" ]; then
                    SSH_TARGET="$1"
                else
                    err "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [ -z "$SSH_TARGET" ] && err "SSH target (user@host) required"

    # Parse user and host
    if [[ "$SSH_TARGET" == *@* ]]; then
        SSH_USER="${SSH_TARGET%%@*}"
        SSH_HOST="${SSH_TARGET#*@}"
    else
        SSH_USER="$USER"
        SSH_HOST="$SSH_TARGET"
    fi

    # Derive key name from host if not specified
    if [ -z "$KEY_NAME" ]; then
        KEY_NAME=$(echo "$SSH_HOST" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/--*/-/g' | sed 's/-$//')
    fi

    KEY_PATH="$HOME/.ssh/id_${KEY_TYPE}_${KEY_NAME}"
}

fix_permissions() {
    info "Fixing SSH directory permissions..."
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    chmod 600 "$HOME/.ssh/config" 2>/dev/null || true
    find "$HOME/.ssh" -name "id_*" ! -name "*.pub" -exec chmod 600 {} \; 2>/dev/null || true
    find "$HOME/.ssh" -name "id_*.pub" -exec chmod 644 {} \; 2>/dev/null || true
    find "$HOME/.ssh" -name "*.pem" -exec chmod 600 {} \; 2>/dev/null || true
    log "Permissions fixed"
}

generate_key() {
    if [ -n "$EXISTING_KEY" ]; then
        KEY_PATH="$EXISTING_KEY"
        if [ ! -f "$KEY_PATH" ]; then
            err "Key file not found: $KEY_PATH"
        fi
        log "Using existing key: $KEY_PATH"
        return
    fi

    if [ -f "$KEY_PATH" ]; then
        warn "Key already exists: $KEY_PATH"
        read -rp "    Overwrite? [y/N] " answer
        [ "${answer,,}" != "y" ] && { info "Keeping existing key"; return; }
    fi

    if $DRY_RUN; then
        info "[DRY RUN] Would generate $KEY_TYPE key at $KEY_PATH"
        return
    fi

    local keygen_args=(-t "$KEY_TYPE" -f "$KEY_PATH" -C "${SSH_USER}@${KEY_NAME}-$(date +%Y)")
    case "$KEY_TYPE" in
        ed25519) keygen_args+=(-a 100) ;;
        rsa)     keygen_args+=(-b 4096 -a 100) ;;
        ecdsa)   keygen_args+=(-b 521) ;;
    esac

    info "Generating $KEY_TYPE key..."
    ssh-keygen "${keygen_args[@]}"
    chmod 600 "$KEY_PATH"
    chmod 644 "${KEY_PATH}.pub"
    log "Key generated: $KEY_PATH"
}

deploy_key() {
    if $DRY_RUN; then
        info "[DRY RUN] Would copy ${KEY_PATH}.pub to $SSH_TARGET"
        return
    fi

    info "Deploying public key to $SSH_TARGET..."

    local copy_args=(-i "${KEY_PATH}.pub" -p "$PORT")
    [ -n "$JUMP_HOST" ] && copy_args+=(-o "ProxyJump=$JUMP_HOST")

    if ssh-copy-id "${copy_args[@]}" "${SSH_USER}@${SSH_HOST}"; then
        log "Public key deployed to $SSH_TARGET"
    else
        err "Failed to deploy key. Check connectivity and credentials."
    fi
}

setup_agent() {
    if ! $ADD_AGENT; then
        info "Skipping ssh-agent setup (--no-agent)"
        return
    fi

    if $DRY_RUN; then
        info "[DRY RUN] Would add $KEY_PATH to ssh-agent"
        return
    fi

    # Start agent if not running
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        warn "ssh-agent not running. Starting..."
        eval "$(ssh-agent -s)" > /dev/null
    fi

    ssh-add "$KEY_PATH" 2>/dev/null && log "Key added to ssh-agent" || warn "Could not add key to agent"
}

create_config_entry() {
    if ! $CREATE_CONFIG; then
        info "Skipping config entry (--no-config)"
        return
    fi

    local config_file="$HOME/.ssh/config"
    touch "$config_file"
    chmod 600 "$config_file"

    # Check if entry already exists
    if grep -q "^Host ${KEY_NAME}$" "$config_file" 2>/dev/null; then
        warn "Config entry 'Host $KEY_NAME' already exists in $config_file"
        info "Skipping config entry creation"
        return
    fi

    if $DRY_RUN; then
        info "[DRY RUN] Would add config entry:"
        _build_config_entry
        return
    fi

    info "Adding SSH config entry..."

    {
        echo ""
        _build_config_entry
    } >> "$config_file"

    log "Config entry added: 'ssh $KEY_NAME' will connect to $SSH_HOST"
}

_build_config_entry() {
    echo "Host $KEY_NAME"
    echo "    HostName $SSH_HOST"
    echo "    User $SSH_USER"
    [ "$PORT" != "22" ] && echo "    Port $PORT"
    echo "    IdentityFile $KEY_PATH"
    echo "    IdentitiesOnly yes"
    [ -n "$JUMP_HOST" ] && echo "    ProxyJump $JUMP_HOST"
    echo "    ForwardAgent no"
    echo "    ServerAliveInterval 60"
    echo "    ServerAliveCountMax 3"
}

verify_connection() {
    if $DRY_RUN; then
        info "[DRY RUN] Would verify connection to $SSH_TARGET"
        return
    fi

    info "Verifying connection..."

    local ssh_args=(-i "$KEY_PATH" -p "$PORT" -o "BatchMode=yes" -o "ConnectTimeout=10")
    [ -n "$JUMP_HOST" ] && ssh_args+=(-o "ProxyJump=$JUMP_HOST")

    if ssh "${ssh_args[@]}" "${SSH_USER}@${SSH_HOST}" "echo 'Connection successful'" 2>/dev/null; then
        log "Connection verified — key-based auth working"
    else
        warn "Connection test failed. Key may not be deployed correctly."
        warn "Try manually: ssh -i $KEY_PATH -p $PORT ${SSH_USER}@${SSH_HOST}"
    fi
}

print_summary() {
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  SSH Key Setup Complete"
    echo "═══════════════════════════════════════════"
    echo "  Host alias:   $KEY_NAME"
    echo "  Target:       ${SSH_USER}@${SSH_HOST}:${PORT}"
    echo "  Key file:     $KEY_PATH"
    echo "  Key type:     $KEY_TYPE"
    [ -n "$JUMP_HOST" ] && echo "  Jump host:    $JUMP_HOST"
    echo ""
    echo "  Connect with: ssh $KEY_NAME"
    echo "═══════════════════════════════════════════"
}

# --- Main ---
parse_args "$@"
mkdir -p "$HOME/.ssh"
fix_permissions
generate_key
deploy_key
setup_agent
create_config_entry
verify_connection
print_summary
