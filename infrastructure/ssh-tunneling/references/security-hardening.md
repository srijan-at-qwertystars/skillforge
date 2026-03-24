# SSH Security Hardening Guide

> Comprehensive security hardening for SSH infrastructure: cryptographic configuration,
> authentication hardening, access control, monitoring, and compliance. Every recommendation
> includes specific configuration with rationale.

## Table of Contents

- [Hardened sshd_config](#hardened-sshd_config)
  - [Key Exchange Algorithms](#key-exchange-algorithms)
  - [Ciphers](#ciphers)
  - [Message Authentication Codes](#message-authentication-codes)
  - [Host Key Algorithms](#host-key-algorithms)
  - [Complete Crypto Configuration](#complete-crypto-configuration)
- [Key Rotation Strategies](#key-rotation-strategies)
  - [User Key Rotation](#user-key-rotation)
  - [Host Key Rotation](#host-key-rotation)
  - [CA Key Rotation](#ca-key-rotation)
  - [Automation with Ansible](#automation-with-ansible)
- [SSH CA vs authorized_keys at Scale](#ssh-ca-vs-authorized_keys-at-scale)
  - [Comparison Matrix](#comparison-matrix)
  - [Migration Path](#migration-path)
  - [Hybrid Approach](#hybrid-approach)
- [Bastion Host Architecture](#bastion-host-architecture)
  - [Network Placement](#network-placement)
  - [Hardened Bastion Configuration](#hardened-bastion-configuration)
  - [Multi-Tier Bastion Design](#multi-tier-bastion-design)
- [Session Recording and Logging](#session-recording-and-logging)
  - [Native SSH Logging](#native-ssh-logging)
  - [Session Recording with tlog](#session-recording-with-tlog)
  - [Centralized Audit](#centralized-audit)
- [2FA with SSH](#2fa-with-ssh)
  - [Google Authenticator (TOTP)](#google-authenticator-totp)
  - [FIDO2/U2F Hardware Keys](#fido2u2f-hardware-keys)
  - [Combining Key + 2FA](#combining-key--2fa)
- [SSH Audit Tools](#ssh-audit-tools)
- [Port Knocking](#port-knocking)
  - [knockd Configuration](#knockd-configuration)
  - [fwknop (Single Packet Authorization)](#fwknop-single-packet-authorization)
- [AllowUsers/AllowGroups Patterns](#allowusersallowgroups-patterns)

---

## Hardened sshd_config

### Key Exchange Algorithms

Key exchange establishes the shared secret. Use only algorithms resistant to known attacks:

```bash
# Recommended: Curve25519-based only
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# If NIST compliance required, add:
# KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384

# NEVER use: diffie-hellman-group1-sha1, diffie-hellman-group14-sha1, diffie-hellman-group-exchange-sha1
```

**Why Curve25519:** Constant-time implementation, immune to timing side-channels, no
questionable NIST curve parameters, fast on all platforms.

### Ciphers

Use only authenticated encryption (AEAD) ciphers:

```bash
# Recommended: ChaCha20-Poly1305 preferred, AES-GCM fallback
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# NEVER use: aes*-cbc, 3des-cbc, arcfour*, blowfish-cbc, cast128-cbc
```

**Why ChaCha20-Poly1305:** Designed for SSH, constant-time, excellent performance on
systems without AES-NI hardware acceleration. AES-GCM is fast with AES-NI.

### Message Authentication Codes

With AEAD ciphers (GCM, Poly1305), MACs are handled by the cipher. Configure MACs for
non-AEAD fallback:

```bash
# Recommended: EtM (Encrypt-then-MAC) variants only
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# NEVER use: hmac-md5, hmac-sha1, umac-64, or any non-etm variant
```

**Why EtM:** Encrypt-then-MAC prevents padding oracle attacks. Non-EtM (MAC-then-encrypt)
is theoretically vulnerable.

### Host Key Algorithms

```bash
# Prefer Ed25519, accept ECDSA for compatibility
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,ecdsa-sha2-nistp256,sk-ssh-ed25519@openssh.com

# Generate only strong host keys
# Remove weak host keys:
sudo rm -f /etc/ssh/ssh_host_dsa_key* /etc/ssh/ssh_host_rsa_key*
# Regenerate Ed25519 if missing:
sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
```

### Complete Crypto Configuration

```bash
# /etc/ssh/sshd_config — Cryptographic settings block

# Protocol (OpenSSH 7.4+ only supports v2, but be explicit)
# Protocol 2  # Deprecated directive in modern OpenSSH, v2 is the only option

# Key Exchange
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# MACs
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Host Keys (order matters)
HostKey /etc/ssh/ssh_host_ed25519_key
# HostKey /etc/ssh/ssh_host_ecdsa_key     # Optional fallback

# Host Key Algorithms
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com

# Public Key Accepted Algorithms
PubkeyAcceptedKeyTypes ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com
```

**Verify your configuration:**

```bash
# Check what ciphers/kex/macs your server offers
ssh -Q cipher       # Client's supported ciphers
ssh -Q kex          # Client's supported key exchange
ssh -Q mac          # Client's supported MACs
ssh -Q key          # Client's supported key types

# Test against the server
nmap --script ssh2-enum-algos -p 22 target-host
```

---

## Key Rotation Strategies

### User Key Rotation

```bash
# 1. Generate new key pair
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519_new -C "user@host $(date +%Y)"

# 2. Deploy new public key to all servers (while old key still works)
ssh-copy-id -i ~/.ssh/id_ed25519_new.pub user@server

# 3. Test new key
ssh -i ~/.ssh/id_ed25519_new user@server

# 4. Update SSH config to use new key
# ~/.ssh/config: IdentityFile ~/.ssh/id_ed25519_new

# 5. Remove old public key from servers
ssh user@server "sed -i '/OLD_KEY_COMMENT/d' ~/.ssh/authorized_keys"

# 6. Archive or destroy old private key
shred -u ~/.ssh/id_ed25519_old
```

**Rotation schedule:**

| Key Type | Rotation Period | Trigger Events |
|----------|----------------|----------------|
| User keys | 6-12 months | Employee departure, device loss |
| Service keys | 3-6 months | Service redeployment, incident |
| CA keys | 2-5 years | Compromise suspicion |
| Host keys | 1-2 years | Server rebuild, OS upgrade |

### Host Key Rotation

```bash
# 1. Generate new host keys
sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key_new -N ""

# 2. If using SSH CA, sign the new host key
ssh-keygen -s /path/to/host_ca -I "hostname-$(date +%Y)" -h \
  -n hostname.example.com -V +52w \
  /etc/ssh/ssh_host_ed25519_key_new.pub

# 3. Add new key to sshd_config (keep old key temporarily)
# HostKey /etc/ssh/ssh_host_ed25519_key_new
# HostKey /etc/ssh/ssh_host_ed25519_key      # old, remove after transition

# 4. Restart sshd and update known_hosts/CA trust
sudo systemctl restart sshd

# 5. After transition period, remove old key
sudo rm /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub
```

### CA Key Rotation

```bash
# CA rotation is high-impact — plan carefully

# 1. Generate new CA key pair
ssh-keygen -t ed25519 -f /etc/ssh/ssh_user_ca_new -C "User CA v2"

# 2. Configure servers to trust BOTH old and new CA (transition period)
# sshd_config: TrustedUserCAKeys /etc/ssh/trusted_cas
# /etc/ssh/trusted_cas: contains both old and new CA public keys

# 3. Begin signing new certificates with new CA only

# 4. After all old certificates expire, remove old CA from trust
# Remove old CA public key from /etc/ssh/trusted_cas

# 5. Securely destroy old CA private key
```

### Automation with Ansible

```yaml
# roles/ssh-key-rotation/tasks/main.yml
- name: Deploy authorized keys from central source
  ansible.posix.authorized_key:
    user: "{{ item.user }}"
    key: "{{ lookup('file', 'keys/' + item.user + '.pub') }}"
    exclusive: yes    # Remove keys not in this list
  loop: "{{ ssh_users }}"
  notify: restart sshd

- name: Remove revoked keys
  ansible.posix.authorized_key:
    user: "{{ item.user }}"
    key: "{{ item.old_key }}"
    state: absent
  loop: "{{ revoked_keys }}"
```

---

## SSH CA vs authorized_keys at Scale

### Comparison Matrix

| Factor | authorized_keys | SSH Certificates |
|--------|----------------|-----------------|
| **Key distribution** | Push to every server | Configure CA trust once |
| **Revocation** | Remove from every server | Let certificate expire or KRL |
| **Onboarding** | Add key to N servers | Sign one certificate |
| **Offboarding** | Remove key from N servers | Stop issuing; wait for expiry |
| **Audit** | Grep authorized_keys on all hosts | Central signing logs |
| **Automation** | Config management required | CA API + short-lived certs |
| **Complexity** | Simple per-host | CA infrastructure required |
| **Access scope** | Per-host granular | Principal-based, cross-host |
| **Temporal control** | None (key is permanent) | Certificate validity period |

### Migration Path

1. **Phase 1:** Deploy CA infrastructure, configure `TrustedUserCAKeys` on all servers
2. **Phase 2:** Issue certificates to power users while keeping `authorized_keys`
3. **Phase 3:** Automate certificate issuance (Vault, BLESS, step-ca)
4. **Phase 4:** Remove `authorized_keys` for certificate-managed users
5. **Phase 5:** Keep `authorized_keys` only for emergency break-glass access

### Hybrid Approach

```bash
# sshd_config — allow both CA certificates and traditional keys
TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub
AuthorizedKeysFile .ssh/authorized_keys

# Use AuthorizedPrincipalsFile for fine-grained certificate access
AuthorizedPrincipalsFile /etc/ssh/authorized_principals/%u
```

---

## Bastion Host Architecture

### Network Placement

```
┌──────────────────────────────────────────────────────┐
│                     Internet                         │
└─────────────────────┬────────────────────────────────┘
                      │
              ┌───────▼───────┐
              │   Firewall    │ Only port 22 (or 2222) inbound
              └───────┬───────┘
                      │
         ┌────────────▼────────────┐
         │     DMZ / Public Net    │
         │  ┌──────────────────┐   │
         │  │  Bastion Host    │   │
         │  │  - No services   │   │
         │  │  - Session log   │   │
         │  │  - 2FA required  │   │
         │  └────────┬─────────┘   │
         └───────────┼─────────────┘
                     │
              ┌──────▼──────┐
              │  Firewall   │ Only from bastion IP
              └──────┬──────┘
                     │
         ┌───────────▼─────────────┐
         │    Private Network      │
         │  ┌─────┐ ┌─────┐       │
         │  │App  │ │ DB  │  ...   │
         │  └─────┘ └─────┘       │
         └─────────────────────────┘
```

### Hardened Bastion Configuration

```bash
# /etc/ssh/sshd_config on bastion

# Authentication
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey,keyboard-interactive    # Key + 2FA

# Restrict capabilities — bastion is for jumping, not working
AllowTcpForwarding yes          # Required for ProxyJump
AllowAgentForwarding no         # Use ProxyJump instead
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no

# No shell access on bastion (users jump through, not work on it)
# Per-user override:
Match Group jump-users
    ForceCommand /usr/sbin/nologin
    AllowTcpForwarding yes

# Session limits
MaxSessions 3
MaxAuthTries 2
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
LogLevel VERBOSE
# Consider: LogLevel DEBUG3 for temporary forensics

# Crypto (see Hardened sshd_config section above)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

### Multi-Tier Bastion Design

For high-security environments, use separate bastions per environment:

```ssh-config
# Developer config
Host bastion-dev
    HostName bastion-dev.example.com
    User ops
    IdentityFile ~/.ssh/id_ed25519_dev

Host bastion-prod
    HostName bastion-prod.example.com
    User ops
    IdentityFile ~/.ssh/id_ed25519_prod
    # Require hardware key for prod
    # Key type: sk-ssh-ed25519

Host *.dev.internal
    ProxyJump bastion-dev

Host *.prod.internal
    ProxyJump bastion-prod
```

---

## Session Recording and Logging

### Native SSH Logging

```bash
# /etc/ssh/sshd_config
LogLevel VERBOSE
# Logs: auth attempts, key fingerprints, session open/close, forwarding requests

# Enhanced logging with auditd
# /etc/audit/rules.d/ssh.rules
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /home/ -p wa -k ssh_authorized_keys -F name=authorized_keys
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands
```

### Session Recording with tlog

`tlog` records terminal I/O and can replay sessions for audit:

```bash
# Install tlog
sudo apt install tlog           # Debian/Ubuntu
sudo yum install tlog           # RHEL/CentOS

# Configure as login shell for recorded users
sudo usermod -s /usr/bin/tlog-rec-session recorded-user

# tlog configuration (/etc/tlog/tlog-rec-session.conf)
{
    "shell": "/bin/bash",
    "notice": "\\nATTENTION: This session is being recorded.\\n",
    "writer": "journal",
    "journal": {
        "priority": "info",
        "augment": true
    }
}

# Replay a recorded session
tlog-play -r journal -M TLOG_REC=<session-id>
```

### Centralized Audit

```bash
# Forward SSH logs to remote syslog
# /etc/rsyslog.d/ssh-audit.conf
auth,authpriv.*    @@syslog.example.com:514

# Or use journald forwarding
# /etc/systemd/journal-upload.conf
[Upload]
URL=https://log-collector.example.com
```

---

## 2FA with SSH

### Google Authenticator (TOTP)

```bash
# Install
sudo apt install libpam-google-authenticator    # Debian/Ubuntu
sudo yum install google-authenticator           # RHEL/CentOS

# Each user runs setup:
google-authenticator -t -d -f -r 3 -R 30 -w 3
# -t: time-based  -d: disallow reuse  -f: force write
# -r 3 -R 30: rate limit 3 attempts per 30 seconds
# -w 3: allow 3 window codes for clock skew

# PAM configuration (/etc/pam.d/sshd)
# Add AFTER @include common-auth (or auth requisite pam_unix.so):
auth required pam_google_authenticator.so nullok
# nullok: allow users without 2FA setup (remove after enrollment)

# sshd_config
ChallengeResponseAuthentication yes
AuthenticationMethods publickey,keyboard-interactive
UsePAM yes
```

### FIDO2/U2F Hardware Keys

```bash
# Generate a hardware-backed key (key stays on the device)
ssh-keygen -t ed25519-sk -C "yubikey-work"
# Generates: ~/.ssh/id_ed25519_sk (handle) and ~/.ssh/id_ed25519_sk.pub

# Resident key (stored on the hardware key, portable)
ssh-keygen -t ed25519-sk -O resident -C "yubikey-portable"

# Require physical touch for every use
ssh-keygen -t ed25519-sk -O verify-required -C "yubikey-touch"

# sshd_config (usually works without changes on modern OpenSSH)
PubkeyAcceptedKeyTypes ssh-ed25519,sk-ssh-ed25519@openssh.com,sk-ecdsa-sha2-nistp256@openssh.com

# Deploy the public key normally
ssh-copy-id -i ~/.ssh/id_ed25519_sk.pub user@host
```

### Combining Key + 2FA

```bash
# Require both SSH key AND TOTP/FIDO2
AuthenticationMethods publickey,keyboard-interactive

# Or: SSH key only for automated access, key+2FA for interactive
Match Group automated-services
    AuthenticationMethods publickey
Match Group interactive-users
    AuthenticationMethods publickey,keyboard-interactive
```

---

## SSH Audit Tools

### ssh-audit

Scans SSH servers for security issues in algorithms, keys, and configuration:

```bash
# Install
pip install ssh-audit
# or: sudo apt install ssh-audit

# Scan a server
ssh-audit target-host
ssh-audit -p 2222 target-host      # Non-standard port

# Output includes:
# - Server software version
# - Key exchange algorithms (with ratings)
# - Encryption algorithms (with ratings)
# - MAC algorithms (with ratings)
# - Host key types and sizes
# - Security recommendations

# Policy-based scanning (compare against a security baseline)
ssh-audit --policy=hardened target-host
```

### Other Audit Tools

| Tool | Purpose | Usage |
|------|---------|-------|
| **Lynis** | System-wide security audit including SSH | `lynis audit system --test-group ssh` |
| **OpenSCAP** | Compliance scanning against CIS benchmarks | `oscap xccdf eval --profile stig ssg-*.xml` |
| **nmap ssh scripts** | Remote SSH enumeration | `nmap --script ssh2-enum-algos -p 22 host` |
| **sshd -T** | Dump effective server config | `sudo sshd -T \| grep -i cipher` |
| **ssh-keyscan** | Discover host key types | `ssh-keyscan -t ed25519 host` |

### Automated Compliance Checks

```bash
#!/bin/bash
# Quick SSH security check script

echo "=== Checking SSH Server Security ==="

# Check for weak ciphers
weak_ciphers=$(sudo sshd -T 2>/dev/null | grep -i "^ciphers" | grep -iE "cbc|3des|arcfour|blowfish")
[ -n "$weak_ciphers" ] && echo "FAIL: Weak ciphers enabled: $weak_ciphers" || echo "PASS: No weak ciphers"

# Check for weak KEX
weak_kex=$(sudo sshd -T 2>/dev/null | grep -i "^kexalgorithms" | grep -i "sha1")
[ -n "$weak_kex" ] && echo "FAIL: Weak KEX with SHA1: $weak_kex" || echo "PASS: No weak KEX"

# Check for password auth
pass_auth=$(sudo sshd -T 2>/dev/null | grep -i "^passwordauthentication" | grep -i "yes")
[ -n "$pass_auth" ] && echo "WARN: Password authentication enabled" || echo "PASS: Password auth disabled"

# Check for root login
root_login=$(sudo sshd -T 2>/dev/null | grep -i "^permitrootlogin" | grep -iv "no")
[ -n "$root_login" ] && echo "FAIL: Root login permitted" || echo "PASS: Root login disabled"

# Check log level
log_level=$(sudo sshd -T 2>/dev/null | grep -i "^loglevel" | grep -iv "verbose\|info")
[ -n "$log_level" ] && echo "WARN: Log level may be insufficient" || echo "PASS: Log level adequate"
```

---

## Port Knocking

### knockd Configuration

Port knocking hides SSH behind a sequence of connection attempts:

```bash
# Install
sudo apt install knockd

# /etc/knockd.conf
[options]
    UseSyslog
    Interface = eth0

[openSSH]
    sequence    = 7000,8000,9000        # Knock sequence
    seq_timeout = 5                      # Seconds to complete sequence
    command     = /sbin/iptables -A INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
    tcpflags    = syn

[closeSSH]
    sequence    = 9000,8000,7000        # Reverse sequence to close
    seq_timeout = 5
    command     = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
    tcpflags    = syn

# Default: SSH port closed
sudo iptables -A INPUT -p tcp --dport 22 -j DROP

# Client usage
knock target-host 7000 8000 9000 && ssh user@target-host
```

### fwknop (Single Packet Authorization)

More secure than port knocking — uses a single encrypted packet:

```bash
# Install
sudo apt install fwknop-server fwknop-client

# Server configuration (/etc/fwknop/access.conf)
SOURCE                  ANY
OPEN_PORTS              tcp/22
KEY_BASE64              <generated-key>
HMAC_KEY_BASE64         <generated-hmac-key>
FW_ACCESS_TIMEOUT       30       # Auto-close after 30 seconds

# Client usage
fwknop -A tcp/22 -D target-host
ssh user@target-host              # Within 30-second window
```

---

## AllowUsers/AllowGroups Patterns

### User-Based Access Control

```bash
# Allow specific users only
AllowUsers alice bob deploy

# Allow from specific networks
AllowUsers alice@10.0.0.0/8 bob@192.168.1.0/24 deploy@10.0.0.5

# Deny specific users (evaluated AFTER Allow)
DenyUsers root guest

# Combine with Match blocks for per-group settings
AllowGroups ssh-users ssh-admins

Match Group ssh-admins
    AllowTcpForwarding yes
    X11Forwarding yes
    MaxSessions 10

Match Group ssh-users
    AllowTcpForwarding local
    X11Forwarding no
    MaxSessions 3
    ForceCommand /usr/local/bin/restricted-shell
```

### Service Account Patterns

```bash
# Dedicated service accounts with restrictions
Match User deploy
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    ForceCommand /usr/local/bin/deploy-script.sh

Match User backup
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    ForceCommand /usr/local/bin/backup-handler.sh
    # In authorized_keys:
    # command="/usr/local/bin/backup-handler.sh",no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA...

Match User monitoring
    AllowTcpForwarding no
    X11Forwarding no
    MaxSessions 1
    ForceCommand /usr/local/bin/health-check.sh
```

### Environment Isolation

```bash
# Different security profiles per source network
Match Address 10.0.0.0/8
    PasswordAuthentication no
    AuthenticationMethods publickey
    MaxAuthTries 3

Match Address 0.0.0.0/0
    PasswordAuthentication no
    AuthenticationMethods publickey,keyboard-interactive   # Require 2FA from internet
    MaxAuthTries 2
    LoginGraceTime 15
```
