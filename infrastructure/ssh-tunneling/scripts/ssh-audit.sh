#!/usr/bin/env bash
#
# ssh-audit.sh — Audit SSH server configuration for security issues
#
# Usage:
#   ssh-audit.sh [options] <target-host>
#   ssh-audit.sh --local                    # Audit local sshd_config
#
# Options:
#   -p, --port <port>       SSH port (default: 22)
#   -l, --local             Audit local sshd configuration
#   -v, --verbose           Show detailed output
#   -o, --output <file>     Write report to file
#   --json                  Output in JSON format
#
# Examples:
#   ssh-audit.sh server.example.com
#   ssh-audit.sh -p 2222 server.example.com
#   ssh-audit.sh --local
#   ssh-audit.sh -v -o report.txt server.example.com
#
# Checks performed:
#   - Protocol version and software banner
#   - Key exchange algorithms (flags weak/deprecated)
#   - Cipher strength (flags CBC, 3DES, arcfour)
#   - MAC algorithms (flags MD5, SHA1, non-EtM)
#   - Host key types and sizes
#   - Authentication methods
#   - sshd_config settings (local mode)
#   - Security recommendations

set -euo pipefail

PORT=22
LOCAL_MODE=false
VERBOSE=false
OUTPUT=""
JSON=false
TARGET=""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0

pass() { ((PASS_COUNT++)); echo -e "${GREEN}[PASS]${NC} $*"; }
warn() { ((WARN_COUNT++)); echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { ((FAIL_COUNT++)); echo -e "${RED}[FAIL]${NC} $*"; }
info() { ((INFO_COUNT++)); echo -e "${BLUE}[INFO]${NC} $*"; }
header() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# Weak/deprecated algorithms
WEAK_KEX="diffie-hellman-group1-sha1|diffie-hellman-group14-sha1|diffie-hellman-group-exchange-sha1|ecdh-sha2-nistp256"
WEAK_CIPHERS="3des-cbc|aes128-cbc|aes192-cbc|aes256-cbc|blowfish-cbc|cast128-cbc|arcfour|arcfour128|arcfour256"
WEAK_MACS="hmac-md5|hmac-sha1(?!-)|hmac-ripemd160|umac-64(?!-etm)"

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--port)   PORT="$2"; shift 2 ;;
            -l|--local)  LOCAL_MODE=true; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -o|--output) OUTPUT="$2"; shift 2 ;;
            --json)      JSON=true; shift ;;
            -h|--help)   head -30 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
            -*)          echo "Unknown option: $1" >&2; exit 1 ;;
            *)           TARGET="$1"; shift ;;
        esac
    done

    if ! $LOCAL_MODE && [ -z "$TARGET" ]; then
        echo "Error: target host or --local required" >&2
        exit 1
    fi
}

audit_remote() {
    header "SSH Server Audit: $TARGET:$PORT"
    echo "Date: $(date -Iseconds)"
    echo ""

    # Grab the banner
    header "Server Banner"
    local banner
    banner=$(echo "" | nc -w 5 "$TARGET" "$PORT" 2>/dev/null | head -1 || echo "Could not retrieve banner")
    if [ -n "$banner" ]; then
        info "Banner: $banner"
        # Check for version disclosure
        if echo "$banner" | grep -qiE "openssh|dropbear|libssh"; then
            warn "Server software version disclosed in banner"
        fi
        # Check for old versions
        if echo "$banner" | grep -qE "OpenSSH_[1-7]\."; then
            fail "OpenSSH version appears outdated — upgrade recommended"
        fi
    else
        warn "Could not retrieve server banner"
    fi

    # Scan algorithms using ssh -Q simulation and nmap
    header "Key Exchange Algorithms"
    audit_algorithms_via_ssh "kex"

    header "Ciphers"
    audit_algorithms_via_ssh "cipher"

    header "MACs"
    audit_algorithms_via_ssh "mac"

    header "Host Key Types"
    audit_host_keys

    header "Authentication Methods"
    audit_auth_methods
}

audit_algorithms_via_ssh() {
    local algo_type="$1"
    local output

    # Use ssh -vvv to discover negotiated algorithms
    output=$(ssh -vvv -o "BatchMode=yes" -o "ConnectTimeout=5" \
             -o "StrictHostKeyChecking=no" -p "$PORT" \
             "audit-probe@${TARGET}" 2>&1 || true)

    case "$algo_type" in
        kex)
            local kex_line
            kex_line=$(echo "$output" | grep "kex_input_kexinit: " | head -1 | sed 's/.*kex_input_kexinit: //' || true)
            if [ -z "$kex_line" ]; then
                # Try alternate parsing
                kex_line=$(echo "$output" | grep -o "peer server KEXINIT proposal.*" | head -1 || true)
            fi

            # Check individual algorithms from debug output
            local offered
            offered=$(echo "$output" | grep "kex: algorithm:" | awk '{print $NF}' || true)
            if [ -n "$offered" ]; then
                info "Negotiated KEX: $offered"
            fi

            # Check for weak KEX in the full output
            local weak_found
            weak_found=$(echo "$output" | grep -oiE "$WEAK_KEX" || true)
            if [ -n "$weak_found" ]; then
                for w in $weak_found; do
                    fail "Weak key exchange offered: $w"
                done
            else
                pass "No weak key exchange algorithms detected"
            fi
            ;;
        cipher)
            local cipher
            cipher=$(echo "$output" | grep "cipher:" | grep "ctos:" | awk '{print $NF}' | head -1 || true)
            if [ -n "$cipher" ]; then
                info "Negotiated cipher: $cipher"
                if echo "$cipher" | grep -qiE "chacha20|gcm"; then
                    pass "AEAD cipher in use: $cipher"
                elif echo "$cipher" | grep -qiE "cbc|3des|arcfour"; then
                    fail "Weak cipher negotiated: $cipher"
                fi
            fi

            local weak_ciphers
            weak_ciphers=$(echo "$output" | grep -oiE "$WEAK_CIPHERS" | sort -u || true)
            if [ -n "$weak_ciphers" ]; then
                for c in $weak_ciphers; do
                    fail "Weak cipher offered: $c"
                done
            else
                pass "No weak ciphers detected"
            fi
            ;;
        mac)
            local mac
            mac=$(echo "$output" | grep "MAC:" | grep "ctos:" | awk '{print $NF}' | head -1 || true)
            if [ -n "$mac" ]; then
                info "Negotiated MAC: $mac"
                if echo "$mac" | grep -q "etm"; then
                    pass "Encrypt-then-MAC in use: $mac"
                fi
            fi

            if echo "$output" | grep -qiE "hmac-md5|hmac-sha1[^-]"; then
                fail "Weak MAC algorithms offered (MD5 or SHA1)"
            else
                pass "No weak MAC algorithms detected"
            fi
            ;;
    esac
}

audit_host_keys() {
    # Use ssh-keyscan to enumerate host key types
    local keys
    keys=$(ssh-keyscan -p "$PORT" -T 5 "$TARGET" 2>/dev/null || true)

    if [ -z "$keys" ]; then
        warn "Could not scan host keys"
        return
    fi

    echo "$keys" | while IFS= read -r line; do
        local key_type
        key_type=$(echo "$line" | awk '{print $2}')
        case "$key_type" in
            ssh-ed25519)
                pass "Host key type: $key_type (recommended)"
                ;;
            ecdsa-sha2-*)
                info "Host key type: $key_type (acceptable)"
                ;;
            ssh-rsa)
                warn "Host key type: $key_type (consider removing, SHA-1 signatures deprecated)"
                ;;
            ssh-dss)
                fail "Host key type: $key_type (DSA is deprecated and weak)"
                ;;
            *)
                info "Host key type: $key_type"
                ;;
        esac
    done
}

audit_auth_methods() {
    local output
    output=$(ssh -vvv -o "BatchMode=yes" -o "ConnectTimeout=5" \
             -o "StrictHostKeyChecking=no" -o "PreferredAuthentications=none" \
             -p "$PORT" "audit-probe@${TARGET}" 2>&1 || true)

    local methods
    methods=$(echo "$output" | grep "Authentications that can continue:" | tail -1 | sed 's/.*: //' || true)

    if [ -n "$methods" ]; then
        info "Available auth methods: $methods"

        if echo "$methods" | grep -q "password"; then
            warn "Password authentication is enabled (prefer key-only)"
        else
            pass "Password authentication disabled"
        fi

        if echo "$methods" | grep -q "publickey"; then
            pass "Public key authentication available"
        else
            fail "Public key authentication not available"
        fi
    else
        warn "Could not determine authentication methods"
    fi
}

audit_local() {
    header "Local SSH Server Audit"
    echo "Date: $(date -Iseconds)"
    echo "Host: $(hostname)"
    echo ""

    # Check if sshd is installed and running
    if ! command -v sshd &>/dev/null; then
        fail "sshd not found"
        return
    fi

    if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
        pass "SSH server is running"
    else
        warn "SSH server does not appear to be running"
    fi

    # Get effective configuration
    local config
    config=$(sudo sshd -T 2>/dev/null || true)
    if [ -z "$config" ]; then
        fail "Cannot read sshd configuration (need sudo?)"
        return
    fi

    header "Protocol & Authentication"

    # Root login
    local root_login
    root_login=$(echo "$config" | grep "^permitrootlogin " | awk '{print $2}')
    case "$root_login" in
        no) pass "Root login disabled" ;;
        prohibit-password|forced-commands-only) warn "Root login: $root_login (consider 'no')" ;;
        yes) fail "Root login is permitted" ;;
    esac

    # Password auth
    local pass_auth
    pass_auth=$(echo "$config" | grep "^passwordauthentication " | awk '{print $2}')
    [ "$pass_auth" = "no" ] && pass "Password authentication disabled" || fail "Password authentication enabled"

    # Empty passwords
    local empty_pass
    empty_pass=$(echo "$config" | grep "^permitemptypasswords " | awk '{print $2}')
    [ "$empty_pass" = "no" ] && pass "Empty passwords denied" || fail "Empty passwords permitted"

    # Pubkey auth
    local pubkey_auth
    pubkey_auth=$(echo "$config" | grep "^pubkeyauthentication " | awk '{print $2}')
    [ "$pubkey_auth" = "yes" ] && pass "Public key authentication enabled" || fail "Public key authentication disabled"

    # MaxAuthTries
    local max_auth
    max_auth=$(echo "$config" | grep "^maxauthtries " | awk '{print $2}')
    if [ "$max_auth" -le 3 ] 2>/dev/null; then
        pass "MaxAuthTries: $max_auth"
    else
        warn "MaxAuthTries: $max_auth (recommend ≤ 3)"
    fi

    header "Cryptographic Settings"

    # Ciphers
    local ciphers
    ciphers=$(echo "$config" | grep "^ciphers " | sed 's/^ciphers //')
    if echo "$ciphers" | grep -qiE "cbc|3des|arcfour|blowfish"; then
        fail "Weak ciphers enabled: $(echo "$ciphers" | grep -oiE '[^,]*(cbc|3des|arcfour|blowfish)[^,]*' | tr '\n' ', ')"
    else
        pass "No weak ciphers configured"
    fi
    $VERBOSE && info "Ciphers: $ciphers"

    # KEX
    local kex
    kex=$(echo "$config" | grep "^kexalgorithms " | sed 's/^kexalgorithms //')
    if echo "$kex" | grep -qiE "sha1|group1"; then
        fail "Weak key exchange algorithms: $(echo "$kex" | grep -oiE '[^,]*(sha1|group1)[^,]*' | tr '\n' ', ')"
    else
        pass "No weak key exchange algorithms"
    fi
    $VERBOSE && info "KEX: $kex"

    # MACs
    local macs
    macs=$(echo "$config" | grep "^macs " | sed 's/^macs //')
    if echo "$macs" | grep -qiE "md5|hmac-sha1[^-]"; then
        fail "Weak MAC algorithms enabled"
    else
        pass "No weak MAC algorithms"
    fi
    if echo "$macs" | grep -q "etm"; then
        pass "Encrypt-then-MAC variants available"
    else
        warn "No EtM MAC variants configured"
    fi
    $VERBOSE && info "MACs: $macs"

    header "Network & Access Control"

    # Port
    local port
    port=$(echo "$config" | grep "^port " | awk '{print $2}')
    [ "$port" = "22" ] && info "Listening on default port 22" || info "Listening on port $port"

    # AllowUsers/AllowGroups
    local allow_users allow_groups
    allow_users=$(echo "$config" | grep "^allowusers " || true)
    allow_groups=$(echo "$config" | grep "^allowgroups " || true)
    if [ -n "$allow_users" ] || [ -n "$allow_groups" ]; then
        pass "Access restricted with AllowUsers/AllowGroups"
    else
        warn "No AllowUsers or AllowGroups set (all users can attempt login)"
    fi

    # TCP forwarding
    local tcp_fwd
    tcp_fwd=$(echo "$config" | grep "^allowtcpforwarding " | awk '{print $2}')
    [ "$tcp_fwd" = "no" ] && pass "TCP forwarding disabled" || info "TCP forwarding: $tcp_fwd"

    # Agent forwarding
    local agent_fwd
    agent_fwd=$(echo "$config" | grep "^allowagentforwarding " | awk '{print $2}')
    [ "$agent_fwd" = "no" ] && pass "Agent forwarding disabled" || warn "Agent forwarding enabled"

    # X11 forwarding
    local x11_fwd
    x11_fwd=$(echo "$config" | grep "^x11forwarding " | awk '{print $2}')
    [ "$x11_fwd" = "no" ] && pass "X11 forwarding disabled" || warn "X11 forwarding enabled"

    header "Logging & Session"

    # Log level
    local log_level
    log_level=$(echo "$config" | grep "^loglevel " | awk '{print $2}')
    case "$log_level" in
        VERBOSE|DEBUG*) pass "Log level: $log_level" ;;
        INFO) info "Log level: INFO (VERBOSE recommended)" ;;
        *) warn "Log level: $log_level (VERBOSE recommended)" ;;
    esac

    # Session limits
    local max_sessions
    max_sessions=$(echo "$config" | grep "^maxsessions " | awk '{print $2}')
    info "MaxSessions: $max_sessions"

    # LoginGraceTime
    local grace_time
    grace_time=$(echo "$config" | grep "^logingracetime " | awk '{print $2}')
    if [ "$grace_time" -le 30 ] 2>/dev/null; then
        pass "LoginGraceTime: ${grace_time}s"
    else
        warn "LoginGraceTime: ${grace_time}s (recommend ≤ 30s)"
    fi

    # Keepalive
    local alive_interval alive_count
    alive_interval=$(echo "$config" | grep "^clientaliveinterval " | awk '{print $2}')
    alive_count=$(echo "$config" | grep "^clientalivecountmax " | awk '{print $2}')
    if [ "$alive_interval" -gt 0 ] 2>/dev/null; then
        pass "Client keepalive: every ${alive_interval}s, max ${alive_count} failures"
    else
        warn "Client keepalive not configured (idle sessions won't be terminated)"
    fi
}

print_summary() {
    header "Audit Summary"
    echo -e "  ${GREEN}PASS: $PASS_COUNT${NC}"
    echo -e "  ${YELLOW}WARN: $WARN_COUNT${NC}"
    echo -e "  ${RED}FAIL: $FAIL_COUNT${NC}"
    echo -e "  ${BLUE}INFO: $INFO_COUNT${NC}"
    echo ""

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo -e "${RED}Action required: $FAIL_COUNT critical issues found${NC}"
    elif [ "$WARN_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}Review recommended: $WARN_COUNT warnings${NC}"
    else
        echo -e "${GREEN}SSH configuration looks good!${NC}"
    fi
}

# --- Main ---
parse_args "$@"

# Redirect output to file if specified
if [ -n "$OUTPUT" ]; then
    exec > >(tee "$OUTPUT")
fi

if $LOCAL_MODE; then
    audit_local
else
    audit_remote
fi

print_summary
